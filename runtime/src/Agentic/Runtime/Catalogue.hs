{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Versioned frontend manifests and fail-closed local run discovery.
module Agentic.Runtime.Catalogue
  ( FrontendManifest (..),
    OwnerLease (..),
    RunOwnership (..),
    RunRecord (..),
    CatalogueEntry (..),
    frontendManifestVersion,
    encodeFrontendManifest,
    decodeFrontendManifest,
    readFrontendManifest,
    readFrontendInputBytes,
    readFrontendInputBytesAt,
    revalidateLineageParentAt,
    listRunCatalogue,
    listRunCatalogueAt,
  )
where

import Agentic.Runtime.Protocol
  ( PersonAnswering (..),
    RunId (..),
    maxArtifactBytes,
    mkRunId,
  )
import Agentic.Runtime.Snapshot
  ( RunSnapshot,
    RunStatus (..),
    initialRunSnapshot,
    snapshotRunStatus,
    stepRunSnapshot,
  )
import Agentic.Runtime.PrivateFile (listConfinedDirectoryAt, readConfinedFileAt, withConfinedDirectory, withConfinedDirectoryAt, withConfinedDirectoryIfPresentAt)
import Agentic.Runtime.Store
  ( RunManifest (manifestPolicy, manifestRunId),
    readRunStoreAt,
  )
import Control.Exception (IOException, SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (foldM, unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Key (toText)
import Data.Aeson.KeyMap (keys)
import Data.Aeson.Types (Object, Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.FilePath ((</>), isAbsolute, normalise, takeFileName)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Types (Fd)

-- | Current private supervisor-manifest format.
frontendManifestVersion :: Int
frontendManifestVersion = 2

-- | Non-secret launch facts shared by local frontends.
data FrontendManifest = FrontendManifest
  { frontendVersion :: !Int,
    frontendRunId :: !RunId,
    frontendRunnerId :: !Text,
    frontendRunnerExecutable :: !(Maybe FilePath),
    frontendRunnerVersion :: !(Maybe Text),
    frontendWorkflow :: !Text,
    frontendCwd :: !FilePath,
    frontendTargetKind :: !Text,
    frontendTargetArgs :: ![Text],
    frontendInputHashes :: !(Map Text Text),
    frontendProgramHash :: !Text,
    frontendCreatedAt :: !Text,
    frontendParentRunId :: !(Maybe RunId),
    frontendLineage :: !(Maybe Text),
    frontendLineageEdits :: ![Value],
    frontendPersona :: !(Maybe Text),
    frontendPolicyDigest :: !(Maybe Text),
    frontendPersonAnswering :: !(Maybe PersonAnswering),
    frontendOwnerId :: !(Maybe Text),
    frontendRuntimeStore :: !FilePath
  }
  deriving (Eq, Show)

-- | One frontend owner heartbeat.
data OwnerLease = OwnerLease
  { ownerLeaseVersion :: !Int,
    ownerLeaseId :: !Text,
    ownerLeasePid :: !Integer,
    ownerLeaseHeartbeat :: !Text
  }
  deriving (Eq, Show)

-- | Whether this process may control a nonterminal record.
data RunOwnership
  = RunOwnedHere
  | RunOwnedElsewhere
  | RunOwnerStale
  | RunNotStarted
  | RunTerminal
  deriving (Eq, Ord, Show)

-- | One healthy catalogue record reconstructed from manifest and runtime store.
data RunRecord = RunRecord
  { recordDirectory :: !FilePath,
    recordManifest :: !FrontendManifest,
    recordOwnerLease :: !(Maybe OwnerLease),
    recordOwnership :: !RunOwnership,
    -- | Non-secret frozen routing policy from the authenticated runtime manifest.
    recordPolicy :: !(Maybe Value),
    recordSnapshot :: !(Maybe RunSnapshot)
  }
  deriving (Eq, Show)

-- | A corrupt entry remains visible without hiding healthy siblings.
data CatalogueEntry
  = CatalogueRun !RunRecord
  | CatalogueCorrupt !FilePath !Text
  deriving (Eq, Show)

encodeFrontendManifest :: FrontendManifest -> BS.ByteString
encodeFrontendManifest = BL.toStrict . encode

decodeFrontendManifest :: BS.ByteString -> Either Text FrontendManifest
decodeFrontendManifest bytes = case eitherDecodeStrict' bytes of
  Left why -> Left (T.pack why)
  Right value -> Right value

readFrontendManifest :: FilePath -> IO FrontendManifest
readFrontendManifest runDirectory =
  withConfinedDirectory runDirectory [] $ \descriptor ->
    readFrontendManifestAt descriptor

-- | Read and authenticate the ordered private inputs retained by a frontend.
--
-- Returned bytes are copies; callers should install them into a new private run
-- directory rather than passing the old path across a lineage launch.
readFrontendInputBytes :: RunRecord -> [Text] -> IO (Map Text BS.ByteString)
readFrontendInputBytes record names =
  withConfinedDirectory (recordDirectory record) [] $ \descriptor -> readFrontendInputBytesAt record descriptor names

readFrontendInputBytesAt :: RunRecord -> Fd -> [Text] -> IO (Map Text BS.ByteString)
readFrontendInputBytesAt record runDescriptor names = do
  let manifest = recordManifest record
      expected = frontendInputHashes manifest
  unless (length names == length (nub names) && sort names == sort (Map.keys expected)) $
    ioError (userError "workflow descriptor inputs do not match the frontend manifest")
  withConfinedDirectoryAt runDescriptor ["inputs"] $ \inputDescriptor ->
    Map.fromList <$> traverse (readOne inputDescriptor expected) (zip [0 :: Int ..] names)
  where
    readOne inputDescriptor expected (index, name) = do
      let component = show index <> ".txt"
      (bytes, _) <- readConfinedFileAt inputDescriptor [component] maxArtifactBytes
      unless (Map.lookup name expected == Just (digestText bytes)) $
        ioError (userError ("frontend input digest mismatch for " <> T.unpack name))
      pure (name, bytes)

digestText :: BS.ByteString -> Text
digestText bytes = T.pack (show (hash bytes :: Digest SHA256))

readFrontendManifestAt :: Fd -> IO FrontendManifest
readFrontendManifestAt descriptor = do
  (bytes, _) <- readConfinedFileAt descriptor ["supervisor-manifest.json"] (4 * 1024 * 1024)
  either (throwIO . userError . T.unpack) pure (decodeFrontendManifest bytes)

-- | List every child of @STATE/runs@. One corrupt record never hides another.
listRunCatalogue :: FilePath -> Maybe Text -> UTCTime -> IO [CatalogueEntry]
listRunCatalogue stateRoot localOwner now =
  withConfinedDirectory stateRoot [] $ \descriptor -> listRunCatalogueAt stateRoot descriptor localOwner now

listRunCatalogueAt :: FilePath -> Fd -> Maybe Text -> UTCTime -> IO [CatalogueEntry]
listRunCatalogueAt stateRoot stateDescriptor localOwner now = do
  let runs = stateRoot </> "runs"
  entries <- withConfinedDirectoryIfPresentAt stateDescriptor "runs" $ \runsDescriptor -> do
    names <- sort <$> listConfinedDirectoryAt runsDescriptor 1000
    mapM (readEntry runs runsDescriptor) names
  pure (fromMaybe [] entries)
  where
    readEntry runs runsDescriptor name = do
      let directory = runs </> name
      outcome <-
        try @SomeException $
          withConfinedDirectoryAt runsDescriptor [name] $ \runDescriptor ->
            readRecordAt directory name runDescriptor localOwner now
      case outcome of
        Right record -> pure (CatalogueRun record)
        Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
        Left failure -> pure (CatalogueCorrupt directory (boundedFailure failure))

readRecordAt :: FilePath -> FilePath -> Fd -> Maybe Text -> UTCTime -> IO RunRecord
readRecordAt directory directoryName descriptor localOwner now = do
  manifest <- readFrontendManifestAt descriptor
  unless (runIdText (frontendRunId manifest) == T.pack directoryName) $
    ioError (userError "frontend manifest run id does not match its directory")
  let runtimeName = frontendRuntimeStore manifest
      runtimeDirectory = directory </> runtimeName
  runtime <- withConfinedDirectoryIfPresentAt descriptor runtimeName $ \runtimeDescriptor -> do
    (runtimeManifest, events, _) <- readRunStoreAt runtimeDirectory runtimeDescriptor
    unless (manifestRunId runtimeManifest == frontendRunId manifest) $
      ioError (userError "runtime and frontend manifests name different run ids")
    reduced <- case events of
      [] -> pure Nothing
      _ ->
        Just
          <$> either
            (ioError . userError . T.unpack . snapshotErrorText)
            pure
            (foldM stepRunSnapshot (initialRunSnapshot (frontendRunId manifest)) events)
    pure (Just (manifestPolicy runtimeManifest), reduced)
  let (policy, snapshot) = fromMaybe (Nothing, Nothing) runtime
  lease <- readOwnerLeaseAt descriptor
  let ownership = ownershipFor localOwner now snapshot lease
  pure
    RunRecord
      { recordDirectory = directory,
        recordManifest = manifest,
        recordOwnerLease = lease,
        recordOwnership = ownership,
        recordPolicy = policy,
        recordSnapshot = snapshot
      }

-- | Recheck the current parent identity and ownership rather than browser facts.
revalidateLineageParentAt :: RunRecord -> Fd -> IO ()
revalidateLineageParentAt expected descriptor = do
  started <- getCurrentTime
  let directory = recordDirectory expected
  current <- readRecordAt directory (takeFileName directory) descriptor Nothing started
  unless (recordManifest current == recordManifest expected) $
    ioError (userError "the selected parent manifest changed before lineage launch")
  lease <- readOwnerLeaseAt descriptor
  now <- getCurrentTime
  unless (ownershipFor Nothing now (recordSnapshot current) lease /= RunOwnedElsewhere) $
    ioError (userError "the selected nonterminal run has another live owner")

readOwnerLeaseAt :: Fd -> IO (Maybe OwnerLease)
readOwnerLeaseAt descriptor = do
  outcome <- try @IOException $ do
    (bytes, _) <- readConfinedFileAt descriptor ["owner.json"] (4 * 1024 * 1024)
    case eitherDecodeStrict' bytes of
      Left why -> ioError (userError why)
      Right lease -> pure lease
  case outcome of
    Left failure | isDoesNotExistError failure -> pure Nothing
    Left failure -> throwIO failure
    Right lease -> pure (Just lease)

ownershipFor :: Maybe Text -> UTCTime -> Maybe RunSnapshot -> Maybe OwnerLease -> RunOwnership
ownershipFor localOwner now snapshot lease
  | maybe False (terminal . snapshotRunStatus) snapshot = RunTerminal
  | snapshot == Nothing && lease == Nothing = RunNotStarted
  | otherwise = case lease of
      Just owner
        | leaseFresh now owner,
          Just (ownerLeaseId owner) == localOwner -> RunOwnedHere
        | leaseFresh now owner -> RunOwnedElsewhere
      _ -> RunOwnerStale

terminal :: RunStatus -> Bool
terminal status = status `elem` [RunSucceeded, RunFailedStatus, RunCancelledStatus]

leaseFresh :: UTCTime -> OwnerLease -> Bool
leaseFresh now lease =
  case parseUtc (ownerLeaseHeartbeat lease) of
    Nothing -> False
    Just heartbeat -> abs (diffUTCTime now heartbeat) <= 10

instance ToJSON FrontendManifest where
  toJSON manifest =
    object
      [ "frontendManifestVersion" .= frontendVersion manifest,
        "runId" .= runIdText (frontendRunId manifest),
        "runnerId" .= frontendRunnerId manifest,
        "runnerExecutable" .= fmap T.pack (frontendRunnerExecutable manifest),
        "runnerVersion" .= frontendRunnerVersion manifest,
        "workflow" .= frontendWorkflow manifest,
        "cwd" .= T.pack (frontendCwd manifest),
        "targetKind" .= frontendTargetKind manifest,
        "targetArgs" .= frontendTargetArgs manifest,
        "inputHashes" .= frontendInputHashes manifest,
        "programHash" .= frontendProgramHash manifest,
        "createdAt" .= frontendCreatedAt manifest,
        "parentRunId" .= fmap runIdText (frontendParentRunId manifest),
        "lineage" .= frontendLineage manifest,
        "lineageEdits" .= frontendLineageEdits manifest,
        "persona" .= frontendPersona manifest,
        "policyDigest" .= frontendPolicyDigest manifest,
        "personAnswering" .= frontendPersonAnswering manifest,
        "ownerId" .= frontendOwnerId manifest,
        "runtimeStore" .= T.pack (frontendRuntimeStore manifest)
      ]

instance FromJSON FrontendManifest where
  parseJSON = withObject "frontend manifest" $ \o -> do
    version <- o .:? "frontendManifestVersion"
    case version of
      Nothing -> parseLegacyManifest o
      Just current
        | current == frontendManifestVersion -> parseVersion2Manifest o
        | otherwise -> fail ("unsupported frontend manifest version " <> show (current :: Int))

parseLegacyManifest :: Object -> Parser FrontendManifest
parseLegacyManifest o = do
  runId <- o .: "runId" >>= parsedRunId
  created <- o .: "createdAt" >>= parsedTimestamp "createdAt"
  target <- o .: "targetKind" >>= parsedTargetKind
  hashes <- o .: "inputHashes" >>= validateHashes "inputHashes"
  programHash <- o .: "programHash" >>= parsedDigest "programHash"
  lineage <- o .:? "lineage" >>= traverse parsedLineage
  FrontendManifest
    1
    runId
    <$> o .: "runnerId"
    <*> pure Nothing
    <*> pure Nothing
    <*> o .: "workflow"
    <*> (T.unpack <$> o .: "cwd")
    <*> pure target
    <*> o .: "targetArgs"
    <*> pure hashes
    <*> pure programHash
    <*> pure created
    <*> (traverse parsedRunId =<< o .:? "parentRunId")
    <*> pure lineage
    <*> (fromMaybe [] <$> o .:? "lineageEdits")
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure Nothing
    <*> pure "runtime"

parseVersion2Manifest :: Object -> Parser FrontendManifest
parseVersion2Manifest o = do
  onlyKeys "frontend manifest" version2Keys o
  runId <- o .: "runId" >>= parsedRunId
  runnerId <- o .: "runnerId" >>= parsedName "runner"
  executable <- T.unpack <$> o .: "runnerExecutable"
  unless (isAbsolute executable) (fail "frontend runner executable is not absolute")
  workflow <- o .: "workflow" >>= parsedName "workflow"
  cwd <- T.unpack <$> o .: "cwd"
  unless (isAbsolute cwd) (fail "frontend cwd is not absolute")
  target <- o .: "targetKind" >>= parsedTargetKind
  hashes <- o .: "inputHashes" >>= validateHashes "inputHashes"
  programHash <- o .: "programHash" >>= parsedDigest "programHash"
  created <- o .: "createdAt" >>= parsedTimestamp "createdAt"
  parent <- traverse parsedRunId =<< o .:? "parentRunId"
  lineage <- o .:? "lineage" >>= traverse parsedLineage
  runtimeStore <- T.unpack <$> o .: "runtimeStore"
  unless (normalise runtimeStore == "runtime" && not (isAbsolute runtimeStore)) $
    fail "frontend runtime store is not the fixed relative path runtime"
  personAnswering <- o .: "personAnswering"
  owner <- o .: "ownerId" >>= parsedName "owner"
  runnerVersion <- o .: "runnerVersion"
  targetArgs <- fromMaybe [] <$> o .:? "targetArgs"
  lineageEdits <- fromMaybe [] <$> o .:? "lineageEdits"
  persona <- o .:? "persona"
  policyDigest <- o .:? "policyDigest"
  pure
    FrontendManifest
      { frontendVersion = frontendManifestVersion,
        frontendRunId = runId,
        frontendRunnerId = runnerId,
        frontendRunnerExecutable = Just executable,
        frontendRunnerVersion = Just runnerVersion,
        frontendWorkflow = workflow,
        frontendCwd = cwd,
        frontendTargetKind = target,
        frontendTargetArgs = targetArgs,
        frontendInputHashes = hashes,
        frontendProgramHash = programHash,
        frontendCreatedAt = created,
        frontendParentRunId = parent,
        frontendLineage = lineage,
        frontendLineageEdits = lineageEdits,
        frontendPersona = persona,
        frontendPolicyDigest = policyDigest,
        frontendPersonAnswering = Just personAnswering,
        frontendOwnerId = Just owner,
        frontendRuntimeStore = runtimeStore
      }

instance FromJSON OwnerLease where
  parseJSON = withObject "owner lease" $ \o -> do
    onlyKeys "owner lease" ["version", "ownerId", "pid", "heartbeat"] o
    lease <-
      OwnerLease
        <$> o .: "version"
        <*> (o .: "ownerId" >>= parsedName "owner")
        <*> o .: "pid"
        <*> (o .: "heartbeat" >>= parsedTimestamp "heartbeat")
    unless (ownerLeaseVersion lease == 1) (fail "unsupported owner lease version")
    unless (ownerLeasePid lease > 0) (fail "owner lease pid is not positive")
    pure lease

version2Keys :: [Text]
version2Keys =
  [ "frontendManifestVersion",
    "runId",
    "runnerId",
    "runnerExecutable",
    "runnerVersion",
    "workflow",
    "cwd",
    "targetKind",
    "targetArgs",
    "inputHashes",
    "programHash",
    "createdAt",
    "parentRunId",
    "lineage",
    "lineageEdits",
    "persona",
    "policyDigest",
    "personAnswering",
    "ownerId",
    "runtimeStore"
  ]

parsedRunId :: Text -> Parser RunId
parsedRunId = either (fail . T.unpack) pure . mkRunId

parsedName :: String -> Text -> Parser Text
parsedName label value
  | T.null value || T.length value > 256 || T.any (`elem` ['\NUL', '\n', '\r']) value = fail ("invalid " <> label <> " name")
  | otherwise = pure value

parsedTargetKind :: Text -> Parser Text
parsedTargetKind target
  | target `elem` ["scripted", "routing", "acp", "deck", "current", "child", "remote"] = pure target
  | otherwise = fail ("unknown target kind " <> T.unpack target)

parsedLineage :: Text -> Parser Text
parsedLineage lineage
  | lineage `elem` ["restart", "resume", "fork"] = pure lineage
  | otherwise = fail ("unknown lineage operation " <> T.unpack lineage)

parsedDigest :: String -> Text -> Parser Text
parsedDigest label digest
  | T.length digest == 64 && T.all (\c -> isDigit c || c `elem` ['a' .. 'f']) digest = pure digest
  | otherwise = fail (label <> " is not a lowercase SHA-256")

validateHashes :: String -> Map Text Text -> Parser (Map Text Text)
validateHashes label hashes = do
  mapM_ (parsedName "input" . fst) (Map.toList hashes)
  mapM_ (parsedDigest label . snd) (Map.toList hashes)
  pure hashes

parsedTimestamp :: String -> Text -> Parser Text
parsedTimestamp label timestamp =
  case parseUtc timestamp of
    Just _ -> pure timestamp
    Nothing -> fail (label <> " is not canonical UTC ISO-8601")

parseUtc :: Text -> Maybe UTCTime
parseUtc timestamp =
  parseTimeM True defaultTimeLocale "%FT%T%QZ" (T.unpack timestamp)

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed object' =
  case filter (`notElem` allowed) (map toText (keys object')) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))


snapshotErrorText :: Show a => a -> Text
snapshotErrorText = T.pack . show

boundedFailure :: SomeException -> Text
boundedFailure = T.take 500 . T.unwords . T.words . T.pack . displayException
