{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A private, prepared execution whose approval and controls share one pipe.
module Agentic.Cli.Frontend
  ( FrontendPreparation (..),
    FrontendParent (..),
    FrontendEdit (..),
    runFrontendCapabilities,
    runFrontendSession,
    frontendDigest,
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Agentic.Runtime
import Agentic.Runtime.PrivateFile (readConfinedFile)
import Control.Concurrent (myThreadId, threadDelay)
import Control.Concurrent.Async (race_)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally, throwTo)
import Control.Monad (foldM, forever, unless, when)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', encode, object, toJSON, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Read as TextRead
import Data.Word (Word64)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (getCurrentDirectory, withCurrentDirectory)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (exitWith)
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (Handle, hClose, hFlush, stdout)
import System.Posix.Files (getFdStatus, isNamedPipe, isSocket)
import System.Posix.IO (fdToHandle)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (Catch), installHandler, sigTERM)
import System.Posix.Types (Fd (Fd))
import System.Process (CreateProcess (env, std_in, std_out, std_err), StdStream (Inherit), proc)

-- | One frozen program, its public review, and its existing runtime invocation.
data FrontendPreparation = FrontendPreparation
  { preparationPlan :: !Value,
    preparationProgramHash :: !Text,
    preparationPolicy :: !Value,
    preparationArguments :: ![Text],
    preparationTargetKind :: !Text,
    preparationPersona :: !(Maybe Text),
    preparationPolicyDigest :: !(Maybe Text),
    preparationRun :: RunId -> Handle -> BS.ByteString -> IO ()
  }

-- | An immutable parent selected for a new, separately owned execution.
data FrontendParent = FrontendParent
  { parentRecord :: !RunRecord,
    parentOperation :: !LineageOperation,
    parentEdits :: ![FrontendEdit]
  }

data FrontendEdit = DropAnswer !OccurrenceId | ReplaceAnswer !OccurrenceId !Value

data SetupRequest
  = RootSetup !Setup
  | DerivedSetup !FilePath !RunId !LineageOperation ![FrontendEdit] !PersonAnswering !(Maybe FrontendInvocation)

data InputSource = Literal !Text | File !FilePath | Transport !Text

data Setup = Setup
  { setupWorkflow :: !Text,
    setupDirectory :: !FilePath,
    setupArguments :: ![Text],
    setupTargetKind :: !(Maybe Text),
    setupPerson :: !PersonAnswering,
    setupInputs :: ![(Text, InputSource)],
    setupInvocation :: !(Maybe FrontendInvocation)
  }

-- | Report process interfaces without consulting workflows, state, or providers.
runFrontendCapabilities :: Text -> Text -> IO ()
runFrontendCapabilities runnerId runnerVersion = do
  executable <- getExecutablePath
  send $ object
    [ "version" .= (1 :: Int),
      "operation" .= ("capabilities" :: Text),
      "server" .= serverValue runnerId executable runnerVersion,
      "session" .= object
        [ "versions" .= ([1] :: [Int]),
          "operations" .= (["prepare", "prepare-lineage", "start", "discard"] :: [Text]),
          "inputSources" .= (["literal", "file", "transport"] :: [Text]),
          "invocationVersions" .= ([1] :: [Int]),
          "maxRequestBytes" .= maxFrontendQueryBytes
        ],
      "io" .= object
        [ "versions" .= ([1] :: [Int]),
          "operations" .= (["open-root", "read-question", "read-result", "list-runs", "read-run"] :: [Text])
        ],
      "export" .= object
        [ "versions" .= ([1] :: [Int]),
          "operations" .= (["export-result"] :: [Text]),
          "format" .= ("result-json" :: Text),
          "destination" .= ("state-exports" :: Text)
        ],
      "frontendManifestVersions" .= ([frontendManifestVersion, frontendManifestVersionWithInvocation] :: [Int]),
      "legacyFrontendManifests" .= True
    ]

-- | Supervise one prepared worker, retaining the group leader until sole reap.
runFrontendSession ::
  Text ->
  Text ->
  (String -> Bool) ->
  (Text -> IO WorkflowDescriptor) ->
  (Maybe FrontendParent -> Text -> [Text] -> PersonAnswering -> [(Text, BS.ByteString)] -> IO FrontendPreparation) ->
  IO ()
runFrontendSession runnerId runnerVersion credentialArgument describe prepare = withTermination $ do
  worker <- lookupEnv "AGENT_CAT_FRONTEND_WORKER"
  case worker of
    Just "1" -> do
      unsetEnv "AGENT_CAT_FRONTEND_WORKER"
      control <- lookupEnv "AGENT_CAT_CONTROL_FD"
      unless (control == Just "3") (refuse "frontend worker requires its private fd-3 channel")
      status <- getFdStatus (Fd 3)
      unless (isNamedPipe status || isSocket status) (refuse "frontend preparation requires a pipe or socket")
      bracket (fdToHandle (Fd 3)) hClose $ \handle -> do
        (request, buffered) <- receive handle BS.empty
        requested <- parsed parseSetupRequest request
        case requested of
          RootSetup setup -> do
            validateInvocationCredentials credentialArgument (setupInvocation setup)
            descriptor <- describe (setupWorkflow setup)
            inputs <- captureInputs descriptor (setupInputs setup)
            withPrivateRoot "frontend state" (setupDirectory setup) $ \root -> do
              prepared <- prepare Nothing (setupWorkflow setup) (setupArguments setup) (setupPerson setup) inputs
              serve root handle buffered setup descriptor inputs Nothing (pure ()) prepared
          DerivedSetup directory parentId operation edits answering requestedInvocation -> do
            validateInvocationCredentials credentialArgument requestedInvocation
            bracket (openPrivateRoot "frontend state" directory) closePrivateRoot $ \root -> do
              let components = ["runs", T.unpack (runIdText parentId)]
              bracket (openPrivateSubroot root components) closePrivateRoot $ \parentRoot -> do
                now <- getCurrentTime
                record <- withPrivateDirectoryAt parentRoot [] $ \descriptor ->
                  readRunRecordAt (privateRootPath parentRoot) descriptor Nothing now
                let manifest = recordManifest record
                    revalidate = do
                      assertPrivateRoot parentRoot
                      withPrivateDirectoryAt parentRoot [] (revalidateLineageParentAt record)
                    parent = FrontendParent record operation edits
                invocation <- retainLineageInvocation manifest requestedInvocation
                let setup = Setup (frontendWorkflow manifest) directory (frontendTargetArgs manifest) (Just (frontendTargetKind manifest)) answering [] invocation
                revalidate
                descriptor <- describe (frontendWorkflow manifest)
                let names = map workflowInputName (workflowInputs descriptor)
                captured <- withPrivateDirectoryAt parentRoot [] $ \fd -> readFrontendInputBytesBoundedAt maxArtifactBytes record fd names
                let inputs = [(name, captured Map.! name) | name <- names]
                setEnv "AGENT_CAT_STATE_ANCHOR" (privateRootIdentity root)
                withCurrentDirectory (frontendCwd manifest) $ do
                  prepared <- prepare (Just parent) (setupWorkflow setup) (setupArguments setup) answering inputs
                  serve root handle buffered setup descriptor inputs (Just parent) revalidate prepared
    _ -> do
      executable <- getExecutablePath
      ambient <- filter ((`notElem` ownedEnvironment) . fst) <$> getEnvironment
      let childEnvironment =
            [("AGENT_CAT_FRONTEND_WORKER", "1"), ("AGENT_CAT_TUI_BOOTSTRAP_FD3", "1"), ("AGENT_CAT_CONTROL_FD", "3")] <> ambient
          command = (proc executable ["frontend"])
            { env = Just childEnvironment, std_in = Inherit, std_out = Inherit, std_err = Inherit }
      bracket (createProcessGroup command) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group ->
        waitProcessGroup group >>= exitWith
  where
    serve root handle buffered setup descriptor inputs parent revalidate prepared = do
      pid <- getProcessID
      stamp <- getMonotonicTimeNSec
      runId <- either refuse pure (mkRunId ("native-" <> T.pack (show pid) <> "-" <> T.pack (show stamp)))
      let approval = runIdText runId
          owner = "frontend:" <> approval
          runComponents = ["runs", T.unpack (runIdText runId)]
          directory = privateRootPath root </> "runs" </> T.unpack (runIdText runId)
          hashes = Map.fromList [(name, frontendDigest bytes) | (name, bytes) <- inputs]
      executable <- getExecutablePath
      cwd <- getCurrentDirectory
      kind <- case setupTargetKind setup of
        Nothing -> pure (preparationTargetKind prepared)
        Just requested
          | requested == preparationTargetKind prepared -> pure requested
          | preparationTargetKind prepared == "acp" && requested `elem` ["current", "child", "remote"] -> pure requested
          | otherwise -> refuse "frontend target kind disagrees with the resolved backend"
      send $ object $
        [ "version" .= (1 :: Int), "operation" .= ("prepared" :: Text), "approvalId" .= approval,
          "runId" .= runIdText runId, "rootIdentity" .= privateRootIdentity root,
          "cwd" .= cwd, "descriptor" .= descriptor, "plan" .= preparationPlan prepared,
          "programHash" .= preparationProgramHash prepared, "targetKind" .= kind,
          "targetArguments" .= preparationArguments prepared, "policy" .= preparationPolicy prepared,
          "personAnswering" .= setupPerson setup,
          "server" .= serverValue runnerId executable runnerVersion,
          "invocation" .= setupInvocation setup,
          "inputs" .= [object ["name" .= name, "bytes" .= T.pack (show (BS.length bytes)), "sha256" .= frontendDigest bytes] | (name, bytes) <- inputs]
        ] <> case parent of
          Nothing -> []
          Just selected ->
            [ "parentRunId" .= runIdText (frontendRunId (recordManifest (parentRecord selected))),
              "lineage" .= lineageName (parentOperation selected),
              "lineageEdits" .= map editMetadata (parentEdits selected)
            ]
      (decision, controls) <- receive handle buffered
      start <- parsed (parseDecision approval) decision
      when start $ do
        assertPrivateRoot root
        _ <- revalidate
        ensurePrivateDirectoryAt root ["runs"]
        createPrivateDirectoryAt root runComponents
        createPrivateDirectoryAt root (runComponents <> ["inputs"])
        mapM_ (\(index, (_, bytes)) -> writePrivateExclusiveAt root (runComponents <> ["inputs", show index <> ".txt"]) bytes) (zip [(0 :: Int) ..] inputs)
        created <- timestamp
        let invocation = setupInvocation setup
            manifest = FrontendManifest
              { frontendVersion = maybe frontendManifestVersion (const frontendManifestVersionWithInvocation) invocation,
                frontendRunId = runId,
                frontendRunnerId = runnerId,
                frontendRunnerExecutable = Just executable,
                frontendRunnerVersion = Just runnerVersion,
                frontendInvocation = invocation,
                frontendWorkflow = setupWorkflow setup,
                frontendCwd = cwd,
                frontendTargetKind = kind,
                frontendTargetArgs = preparationArguments prepared,
                frontendInputHashes = hashes,
                frontendProgramHash = preparationProgramHash prepared,
                frontendCreatedAt = created,
                frontendParentRunId = frontendRunId . recordManifest . parentRecord <$> parent,
                frontendLineage = lineageName . parentOperation <$> parent,
                frontendLineageEdits = maybe [] (map editMetadata . parentEdits) parent,
                frontendPersona = preparationPersona prepared,
                frontendPolicyDigest = preparationPolicyDigest prepared,
                frontendPersonAnswering = Just (setupPerson setup),
                frontendOwnerId = Just owner,
                frontendRuntimeStore = "runtime"
              }
            heartbeat = do
              now <- timestamp
              writePrivateAtomicAt root (runComponents <> ["owner.json"]) . jsonBytes $ object
                ["version" .= (1 :: Int), "ownerId" .= owner, "pid" .= (fromIntegral pid :: Integer), "heartbeat" .= now]
        writePrivateExclusiveAt root (runComponents <> ["supervisor-manifest.json"]) (jsonBytes (toJSON manifest))
        heartbeat
        setEnv "AGENT_CAT_STATE_ANCHOR" (privateRootIdentity root)
        setEnv "AGENT_CAT_RUN_STORE" (directory </> "runtime")
        setEnv "AGENT_CAT_RUN_OWNER" (T.unpack owner)
        race_ (forever (threadDelay 2000000 >> heartbeat)) (preparationRun prepared runId handle controls)

serverValue :: Text -> FilePath -> Text -> Value
serverValue runnerId executable runnerVersion =
  toJSON (FrontendServer runnerId executable runnerVersion)

validateInvocationCredentials :: (String -> Bool) -> Maybe FrontendInvocation -> IO ()
validateInvocationCredentials credentialArgument invocation =
  when (maybe False (any (credentialArgument . T.unpack) . frontendInvocationPrefixArgs) invocation) $
    refuse "frontend invocation prefix arguments cannot carry credentials"

retainLineageInvocation :: FrontendManifest -> Maybe FrontendInvocation -> IO (Maybe FrontendInvocation)
retainLineageInvocation manifest requested = case frontendInvocation manifest of
  Nothing -> pure requested
  Just expected -> case requested of
    Nothing -> refuse "frontend lineage from manifest version 3 requires its configured invocation"
    Just actual
      | actual == expected -> pure (Just expected)
      | otherwise -> refuse "frontend lineage configured invocation does not match its parent"

ownedEnvironment :: [String]
ownedEnvironment =
  [ "AGENT_CAT_FRONTEND_WORKER", "AGENT_CAT_TUI_BOOTSTRAP_FD3", "AGENT_CAT_CONTROL_FD", "AGENT_CAT_CONTROL_STDIN",
    "AGENT_CAT_RUN_STORE", "AGENT_CAT_RUN_OWNER", "AGENT_CAT_STATE_ANCHOR"
  ]

withTermination :: IO a -> IO a
withTermination action = do
  owner <- myThreadId
  bracket
    (installHandler sigTERM (Catch (throwTo owner UserInterrupt)) Nothing)
    (\previous -> installHandler sigTERM previous Nothing)
    (const action)

receive :: Handle -> BS.ByteString -> IO (Value, BS.ByteString)
receive handle buffered = do
  framed <- readNdjsonFrame maxFrontendQueryBytes "frontend request" handle buffered >>= either refuse pure
  case framed of
    Nothing -> refuse "frontend request channel closed before a decision"
    Just (bytes, rest) -> do
      value <- either (const (refuse "frontend request is not valid JSON")) pure (eitherDecodeStrict' bytes)
      pure (value, rest)

send :: Value -> IO ()
send value = do
  let bytes = jsonBytes value
  when (toInteger (BS.length bytes) > maxArtifactBytes + 4096) (refuse "frontend preview exceeds its byte bound")
  BS.hPut stdout bytes
  hFlush stdout

jsonBytes :: Value -> BS.ByteString
jsonBytes value = BL.toStrict (encode value <> "\n")

parsed :: (Value -> Parser a) -> Value -> IO a
parsed parser = either (refuse . T.pack) pure . parseEither parser

refuse :: Text -> IO a
refuse = ioError . userError . T.unpack

parseSetupRequest :: Value -> Parser SetupRequest
parseSetupRequest value = withObject "frontend preparation" (\o -> do
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  operation <- o .: "operation"
  case operation :: Text of
    "prepare" -> RootSetup <$> parseSetup value
    "prepare-lineage" -> do
      onlyKeys ["version", "operation", "stateDirectory", "parentRunId", "lineage", "edits", "personAnswering", "invocation"] o
      directory <- o .: "stateDirectory"
      unless (isAbsolute directory && not ('\0' `elem` directory) && BS.length (Text.encodeUtf8 (T.pack directory)) <= 4096) (fail "frontend state directory must be an absolute bounded path")
      parent <- o .: "parentRunId" >>= either (fail . T.unpack) pure . mkRunId
      lineage <- o .: "lineage" >>= \caseName -> case caseName :: Text of
        "restart" -> pure RestartRun
        "resume" -> pure ResumeRun
        "fork" -> pure ForkRun
        _ -> fail "frontend lineage must be restart, resume, or fork"
      edits <- o .:? "edits" >>= maybe (pure []) (traverse parseEdit)
      unless (null edits || lineage == ForkRun) (fail "answer edits require fork lineage")
      person <- o .:? "personAnswering"
      invocation <- optionalInvocation o
      pure (DerivedSetup directory parent lineage edits (maybe PersonAnswerLocalControl id person) invocation)
    _ -> fail "frontend requires preparation before a decision") value

parseEdit :: Value -> Parser FrontendEdit
parseEdit = withObject "frontend answer edit" $ \o -> do
  text <- o .: "occurrenceId"
  occurrence <- case TextRead.decimal text :: Either String (Integer, Text) of
    Right (number, rest) | T.null rest && T.length text <= 20 && number <= toInteger (maxBound :: Word64) -> pure (OccurrenceId (fromInteger number))
    _ -> fail "frontend edit occurrence must be a Word64 decimal string"
  operation <- o .: "operation"
  case operation :: Text of
    "drop" -> onlyKeys ["occurrenceId", "operation"] o >> pure (DropAnswer occurrence)
    "replace" -> onlyKeys ["occurrenceId", "operation", "answer"] o >> ReplaceAnswer occurrence <$> o .: "answer"
    _ -> fail "frontend edit must drop or replace an answer"

editMetadata :: FrontendEdit -> Value
editMetadata (DropAnswer occurrence) = object
  ["operation" .= ("drop" :: Text), "occurrenceId" .= T.pack (show (occurrenceNumber occurrence))]
editMetadata (ReplaceAnswer occurrence answer) = object
  ["operation" .= ("replace" :: Text), "occurrenceId" .= T.pack (show (occurrenceNumber occurrence)),
   "sha256" .= frontendDigest (BL.toStrict (encode answer))]

lineageName :: LineageOperation -> Text
lineageName RestartRun = "restart"
lineageName ResumeRun = "resume"
lineageName ForkRun = "fork"
lineageName RootRun = "root"

parseSetup :: Value -> Parser Setup
parseSetup = withObject "frontend preparation" $ \o -> do
  onlyKeys ["version", "operation", "workflow", "stateDirectory", "targetArguments", "targetKind", "personAnswering", "inputs", "invocation"] o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  operation <- o .: "operation"
  unless (operation == ("prepare" :: Text)) (fail "frontend requires preparation before a decision")
  workflow <- o .: "workflow"
  directory <- o .: "stateDirectory"
  unless (isAbsolute directory && not ('\0' `elem` directory) && BS.length (Text.encodeUtf8 (T.pack directory)) <= 4096) (fail "frontend state directory must be an absolute bounded path")
  arguments <- o .: "targetArguments"
  when (length arguments > 4096 || sum (map (BS.length . Text.encodeUtf8) arguments) > 65536 || any (T.any (== '\0')) arguments) (fail "frontend target arguments must be bounded and NUL-free")
  kind <- o .:? "targetKind"
  person <- o .:? "personAnswering"
  inputs <- o .: "inputs" >>= traverse parseInput
  invocation <- optionalInvocation o
  pure (Setup workflow directory arguments kind (maybe PersonAnswerLocalControl id person) inputs invocation)

parseInput :: Value -> Parser (Text, InputSource)
parseInput = withObject "frontend input" $ \o -> do
  name <- o .: "name"
  source <- o .: "source"
  case source :: Text of
    "literal" -> do
      onlyKeys ["name", "source", "value"] o
      value <- o .: "value"
      pure (name, Literal value)
    "file" -> do
      onlyKeys ["name", "source", "path"] o
      path <- o .: "path"
      unless (isAbsolute path && not ('\0' `elem` path) && BS.length (Text.encodeUtf8 (T.pack path)) <= 4096) (fail "frontend input file must be an absolute bounded path")
      pure (name, File path)
    "transport" -> do
      onlyKeys ["name", "source", "value"] o
      value <- o .: "value"
      pure (name, Transport value)
    _ -> fail "frontend input source must be literal, file, or transport"

parseDecision :: Text -> Value -> Parser Bool
parseDecision expected = withObject "frontend decision" $ \o -> do
  onlyKeys ["version", "operation", "approvalId"] o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  approval <- o .: "approvalId"
  unless (approval == expected) (fail "frontend approval does not name this prepared execution")
  operation <- o .: "operation"
  case operation :: Text of
    "start" -> pure True
    "discard" -> pure False
    _ -> fail "frontend decision must be start or discard"

onlyKeys :: [Text] -> Object -> Parser ()
onlyKeys allowed object' =
  unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys object')) (fail "frontend request has unknown fields")

optionalInvocation :: Object -> Parser (Maybe FrontendInvocation)
optionalInvocation object' = traverse parseJSON (KeyMap.lookup "invocation" object')

captureInputs :: WorkflowDescriptor -> [(Text, InputSource)] -> IO [(Text, BS.ByteString)]
captureInputs descriptor supplied = do
  let names = map workflowInputName (workflowInputs descriptor)
      sources = Map.fromList supplied
  unless (length supplied == Map.size sources && Map.keysSet sources == Map.keysSet (Map.fromList [(name, ()) | name <- names])) $
    refuse "frontend inputs must supply each declared name exactly once"
  (reversed, _) <- foldM (capture sources) ([], fromInteger maxArtifactBytes) (workflowInputs descriptor)
  pure (reverse reversed)
  where
    capture sources (collected, remaining) input = do
      bytes <- case sources Map.! workflowInputName input of
        Literal text -> pure (Text.encodeUtf8 text <> if workflowInputSource input == DescriptorPrompt then "\n" else "")
        File path -> fst <$> readConfinedFile (takeDirectory path) [takeFileName path] (fromIntegral remaining)
        Transport text -> pure (Text.encodeUtf8 text)
      unless (BS.length bytes <= remaining) (refuse "frontend input snapshots exceed their byte bound")
      pure ((workflowInputName input, bytes) : collected, remaining - BS.length bytes)

frontendDigest :: BS.ByteString -> Text
frontendDigest bytes = T.pack (show (hash bytes :: Digest SHA256))

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%FT%T%QZ" <$> getCurrentTime
