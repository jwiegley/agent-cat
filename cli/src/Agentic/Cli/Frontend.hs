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
import Data.Aeson (Value, eitherDecodeStrict', encode, object, toJSON, (.=))
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (getCurrentDirectory, withCurrentDirectory)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (exitWith)
import System.FilePath (takeDirectory, takeFileName, (</>))
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

-- | Report process interfaces without consulting workflows, state, or providers.
runFrontendCapabilities :: Text -> Text -> IO ()
runFrontendCapabilities runnerId runnerVersion = do
  executable <- getExecutablePath
  send . toJSON $ frontendCapabilities (FrontendServer runnerId executable runnerVersion)

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
                let setup = FrontendSetup (frontendWorkflow manifest) directory (frontendTargetArgs manifest) (Just (frontendTargetKind manifest)) answering [] invocation
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
      send . toJSON $ FrontendPrepared
        { preparedApprovalId = approval,
          preparedRunId = runId,
          preparedRootIdentity = T.pack (privateRootIdentity root),
          preparedCwd = cwd,
          preparedDescriptor = descriptor,
          preparedPlan = preparationPlan prepared,
          preparedProgramHash = preparationProgramHash prepared,
          preparedTargetKind = kind,
          preparedTargetArguments = preparationArguments prepared,
          preparedPolicy = preparationPolicy prepared,
          preparedPersonAnswering = setupPerson setup,
          preparedServer = FrontendServer runnerId executable runnerVersion,
          preparedInvocation = setupInvocation setup,
          preparedInputs = [FrontendPreparedInput name (toInteger (BS.length bytes)) (frontendDigest bytes) | (name, bytes) <- inputs],
          preparedLineage = (\selected -> FrontendPreparedLineage
            (frontendRunId (recordManifest (parentRecord selected)))
            (parentOperation selected) (map editMetadata (parentEdits selected))) <$> parent
        }
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
                frontendLineageEdits = maybe [] (map (toJSON . editMetadata) . parentEdits) parent,
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
  when (toInteger (BS.length bytes) > maxFrontendReplyBytes) (refuse "frontend preview exceeds its byte bound")
  BS.hPut stdout bytes
  hFlush stdout

jsonBytes :: Value -> BS.ByteString
jsonBytes value = BL.toStrict (encode value <> "\n")

parsed :: (Value -> Parser a) -> Value -> IO a
parsed parser = either (refuse . T.pack) pure . parseEither parser

refuse :: Text -> IO a
refuse = ioError . userError . T.unpack

editMetadata :: FrontendEdit -> FrontendEditMetadata
editMetadata (DropAnswer occurrence) = DroppedAnswer occurrence
editMetadata (ReplaceAnswer occurrence answer) =
  ReplacedAnswer occurrence (frontendDigest (BL.toStrict (encode answer)))

lineageName :: LineageOperation -> Text
lineageName RestartRun = "restart"
lineageName ResumeRun = "resume"
lineageName ForkRun = "fork"
lineageName RootRun = "root"

captureInputs :: WorkflowDescriptor -> [(Text, FrontendInputSource)] -> IO [(Text, BS.ByteString)]
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
