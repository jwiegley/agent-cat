{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Versioned frontend manifests and fail-closed local run discovery.
module Agentic.Runtime.Catalogue
  ( FrontendServer (..),
    FrontendInvocation (..),
    FrontendManifest (..),
    OwnerLease (..),
    RunOwnership (..),
    RunRecord (..),
    CatalogueEntry (..),
    frontendManifestVersion,
    frontendManifestVersionWithInvocation,
    encodeFrontendManifest,
    decodeFrontendManifest,
    readFrontendManifest,
    readFrontendManifestAt,
    retainLineageInvocation,
    readFrontendInputBytes,
    readFrontendInputBytesAt,
    readFrontendInputBytesBoundedAt,
    revalidateLineageParentAt,
    listRunCatalogue,
    listRunCatalogueAt,
    listRunCatalogueBoundedAt,
    foldRunCatalogueBoundedAt,
    readRunRecordAt,
    readRunRecordWithEnvelopesAt,
  )
where

import Agentic.Runtime.Protocol
  ( Envelope,
    PersonAnswering (..),
    RunId (..),
    maxArtifactBytes,
    mkRunId,
  )
import Agentic.Runtime.Snapshot
  ( RunSnapshot,
    RunStatus (..),
    initialRunSnapshot,
    snapshotRunStatus,
    snapshotWorkflow,
    stepRunSnapshot,
  )
import Agentic.Runtime.PrivateFile (listConfinedDirectoryAt, readConfinedFileAt, withConfinedDirectory, withConfinedDirectoryAt, withConfinedDirectoryIfPresentAt)
import Agentic.Runtime.Store
  ( RunManifest (manifestPolicy, manifestRunId, manifestWorkflow),
    StoreHealth,
    readRunStoreAt,
    readRunStoreBoundedAt,
  )
import Control.Exception (IOException, SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (foldM, unless, when)
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
import qualified Data.Aeson.KeyMap as KeyMap
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
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.FilePath ((</>), isAbsolute, normalise, takeFileName)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Types (Fd)

-- | The supervisor-manifest format emitted when no configured invocation is supplied.
frontendManifestVersion :: Int
frontendManifestVersion = 2

-- | The supervisor-manifest format emitted with a configured invocation.
frontendManifestVersionWithInvocation :: Int
frontendManifestVersionWithInvocation = 3

-- | One server's process identity reported by capability discovery.
data FrontendServer = FrontendServer
  { frontendServerRunnerId :: !Text,
    frontendServerExecutable :: !FilePath,
    frontendServerRunnerVersion :: !Text
  }
  deriving (Eq, Show)

-- | One client's exact, non-secret configured process invocation.
data FrontendInvocation = FrontendInvocation
  { frontendInvocationVersion :: !Int,
    frontendInvocationRunnerAlias :: !Text,
    frontendInvocationExecutable :: !Text,
    frontendInvocationPrefixArgs :: ![Text]
  }
  deriving (Eq, Show)

-- | Non-secret launch facts shared by local frontends.
data FrontendManifest = FrontendManifest
  { frontendVersion :: !Int,
    frontendRunId :: !RunId,
    frontendRunnerId :: !Text,
    frontendRunnerExecutable :: !(Maybe FilePath),
    frontendRunnerVersion :: !(Maybe Text),
    frontendInvocation :: !(Maybe FrontendInvocation),
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
readFrontendInputBytesAt record descriptor names =
  readFrontendInputBytesBoundedAt (toInteger (length names) * maxArtifactBytes) record descriptor names

-- | Authenticate ordered inputs while enforcing an aggregate allocation bound.
readFrontendInputBytesBoundedAt :: Integer -> RunRecord -> Fd -> [Text] -> IO (Map Text BS.ByteString)
readFrontendInputBytesBoundedAt limit record runDescriptor names = do
  let manifest = recordManifest record
      expected = frontendInputHashes manifest
  unless (length names == length (nub names) && sort names == sort (Map.keys expected)) $
    ioError (userError "workflow descriptor inputs do not match the frontend manifest")
  withConfinedDirectoryAt runDescriptor ["inputs"] $ \inputDescriptor ->
    fst <$> foldM (readOne inputDescriptor expected) (Map.empty, limit) (zip [0 :: Int ..] names)
  where
    readOne inputDescriptor expected (inputs, remaining) (index, name) = do
      let component = show index <> ".txt"
      (bytes, _) <- readConfinedFileAt inputDescriptor [component] (min maxArtifactBytes remaining)
      unless (Map.lookup name expected == Just (digestText bytes)) $
        ioError (userError ("frontend input digest mismatch for " <> T.unpack name))
      pure (Map.insert name bytes inputs, remaining - toInteger (BS.length bytes))

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
listRunCatalogueAt = listCatalogueWith readRunRecordAt 1000

-- | A complete catalogue within explicit entry and journal byte bounds.
-- Overflow refuses the whole observation rather than silently hiding a suffix.
listRunCatalogueBoundedAt :: Int -> FilePath -> Fd -> Maybe Text -> UTCTime -> IO [CatalogueEntry]
listRunCatalogueBoundedAt = listCatalogueWith (\directory descriptor owner now ->
  fst <$> readRunRecordWithEnvelopesAt directory descriptor owner now)

listCatalogueWith :: (FilePath -> Fd -> Maybe Text -> UTCTime -> IO RunRecord) -> Int -> FilePath -> Fd -> Maybe Text -> UTCTime -> IO [CatalogueEntry]
listCatalogueWith readRecord limit stateRoot stateDescriptor localOwner now =
  reverse <$> foldCatalogueWith readRecord limit stateRoot stateDescriptor localOwner now (\entries entry -> pure (entry:entries)) []

-- | Fold one bounded journal at a time. The consumer can enforce an aggregate
-- public-byte ceiling without retaining every run's full snapshot.
foldRunCatalogueBoundedAt :: Int -> FilePath -> Fd -> Maybe Text -> UTCTime -> (a -> CatalogueEntry -> IO a) -> a -> IO a
foldRunCatalogueBoundedAt = foldCatalogueWith (\directory descriptor owner now ->
  fst <$> readRunRecordWithEnvelopesAt directory descriptor owner now)

foldCatalogueWith :: (FilePath -> Fd -> Maybe Text -> UTCTime -> IO RunRecord) -> Int -> FilePath -> Fd -> Maybe Text -> UTCTime -> (a -> CatalogueEntry -> IO a) -> a -> IO a
foldCatalogueWith readRecord limit stateRoot stateDescriptor localOwner now consume initial = do
  let runs = stateRoot </> "runs"
  entries <- withConfinedDirectoryIfPresentAt stateDescriptor "runs" $ \runsDescriptor -> do
    names <- sort <$> listConfinedDirectoryAt runsDescriptor limit
    foldM (\current name -> readEntry runs runsDescriptor name >>= consume current) initial names
  pure (fromMaybe initial entries)
  where
    readEntry runs runsDescriptor name = do
      let directory = runs </> name
      outcome <-
        try @SomeException $
          withConfinedDirectoryAt runsDescriptor [name] $ \runDescriptor ->
            readRecord directory runDescriptor localOwner now
      case outcome of
        Right record -> pure (CatalogueRun record)
        Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
        Left failure -> pure (CatalogueCorrupt directory (boundedFailure failure))

-- | Reconstruct one run through its retained directory descriptor.
readRunRecordAt :: FilePath -> Fd -> Maybe Text -> UTCTime -> IO RunRecord
readRunRecordAt directory descriptor localOwner now =
  fst <$> readRunRecordWithStoreAt readRunStoreAt directory descriptor localOwner now

-- | One observed record and its exact prefix from the same verified store read.
-- The complete observation path tightens journal reads to 64 MiB before parsing.
readRunRecordWithEnvelopesAt :: FilePath -> Fd -> Maybe Text -> UTCTime -> IO (RunRecord, [Envelope])
readRunRecordWithEnvelopesAt = readRunRecordWithStoreAt (readRunStoreBoundedAt maxArtifactBytes)

readRunRecordWithStoreAt :: (FilePath -> Fd -> IO (RunManifest, [Envelope], StoreHealth)) -> FilePath -> Fd -> Maybe Text -> UTCTime -> IO (RunRecord, [Envelope])
readRunRecordWithStoreAt readStore directory descriptor localOwner now = do
  manifest <- readFrontendManifestAt descriptor
  unless (runIdText (frontendRunId manifest) == T.pack (takeFileName directory)) $
    ioError (userError "frontend manifest run id does not match its directory")
  let runtimeName = frontendRuntimeStore manifest
      runtimeDirectory = directory </> runtimeName
  runtime <- withConfinedDirectoryIfPresentAt descriptor runtimeName $ \runtimeDescriptor -> do
    (runtimeManifest, events, _) <- readStore runtimeDirectory runtimeDescriptor
    unless (manifestRunId runtimeManifest == frontendRunId manifest) $
      ioError (userError "runtime and frontend manifests name different run ids")
    unless (manifestWorkflow runtimeManifest == frontendWorkflow manifest) $
      ioError (userError "runtime and frontend manifests name different workflows")
    reduced <- case events of
      [] -> pure Nothing
      _ ->
        Just
          <$> either
            (ioError . userError . T.unpack . snapshotErrorText)
            pure
            (foldM stepRunSnapshot (initialRunSnapshot (frontendRunId manifest)) events)
    unless (all ((== Just (manifestWorkflow runtimeManifest)) . snapshotWorkflow) reduced) $
      ioError (userError "runtime journal and manifest name different workflows")
    pure (Just (manifestPolicy runtimeManifest), reduced, events)
  let (policy, snapshot, events) = fromMaybe (Nothing, Nothing, []) runtime
  lease <- readOwnerLeaseAt descriptor
  let ownership = ownershipFor localOwner now snapshot lease
      record = RunRecord
        { recordDirectory = directory,
          recordManifest = manifest,
          recordOwnerLease = lease,
          recordOwnership = ownership,
          recordPolicy = policy,
          recordSnapshot = snapshot
        }
  pure (record, events)

-- | Current configured invocation must equal v3 provenance, never stored argv authority.
retainLineageInvocation :: FrontendManifest -> Maybe FrontendInvocation -> Either Text (Maybe FrontendInvocation)
retainLineageInvocation manifest requested = case frontendInvocation manifest of
  Nothing -> Right requested
  Just expected -> case requested of
    Nothing -> Left "frontend lineage from manifest version 3 requires its configured invocation"
    Just actual
      | actual == expected -> Right (Just expected)
      | otherwise -> Left "frontend lineage configured invocation does not match its parent"

-- | Recheck the current parent identity and ownership rather than browser facts.
revalidateLineageParentAt :: RunRecord -> Fd -> IO ()
revalidateLineageParentAt expected descriptor = do
  started <- getCurrentTime
  let directory = recordDirectory expected
  current <- readRunRecordAt directory descriptor Nothing started
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

instance ToJSON FrontendServer where
  toJSON server =
    object
      [ "runnerId" .= frontendServerRunnerId server,
        "executable" .= T.pack (frontendServerExecutable server),
        "runnerVersion" .= frontendServerRunnerVersion server
      ]

instance FromJSON FrontendServer where
  parseJSON = withObject "frontend server" $ \o -> do
    onlyKeys "frontend server" ["runnerId", "executable", "runnerVersion"] o
    runnerId <- o .: "runnerId" >>= parsedName "runner"
    executable <- T.unpack <$> o .: "executable"
    unless (isAbsolute executable && '\NUL' `notElem` executable) $
      fail "frontend server executable is not an absolute NUL-free path"
    runnerVersion <- o .: "runnerVersion"
    unless (not (T.null runnerVersion) && not (T.any (== '\NUL') runnerVersion)) $
      fail "frontend server version is empty or contains NUL"
    pure (FrontendServer runnerId executable runnerVersion)

instance ToJSON FrontendInvocation where
  toJSON invocation =
    object
      [ "version" .= frontendInvocationVersion invocation,
        "runnerAlias" .= frontendInvocationRunnerAlias invocation,
        "executable" .= frontendInvocationExecutable invocation,
        "prefixArgs" .= frontendInvocationPrefixArgs invocation
      ]

instance FromJSON FrontendInvocation where
  parseJSON = withObject "frontend invocation" $ \o -> do
    onlyKeys "frontend invocation" invocationKeys o
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "unsupported frontend invocation version")
    alias <- o .: "runnerAlias" >>= boundedNonWhitespace "runner alias" 256
    executable <- o .: "executable" >>= boundedNonWhitespace "invocation executable" 4096
    arguments <- o .: "prefixArgs"
    when (length arguments > 4096) (fail "frontend invocation has more than 4096 prefix arguments")
    when (any (T.any (== '\NUL')) arguments) (fail "frontend invocation prefix argument contains NUL")
    when (sum (map (toInteger . BS.length . TE.encodeUtf8) arguments) > 65536) $
      fail "frontend invocation prefix arguments exceed 65536 UTF-8 bytes"
    pure (FrontendInvocation version alias executable arguments)

instance ToJSON FrontendManifest where
  toJSON manifest = case frontendVersion manifest of
    1 -> object legacyFields
    current
      | current == frontendManifestVersionWithInvocation ->
          object (versionedFields <> ["invocation" .= frontendInvocation manifest])
      | otherwise -> object versionedFields
    where
      legacyFields =
        [ "runId" .= runIdText (frontendRunId manifest),
          "runnerId" .= frontendRunnerId manifest,
          "workflow" .= frontendWorkflow manifest,
          "cwd" .= T.pack (frontendCwd manifest),
          "targetKind" .= frontendTargetKind manifest,
          "targetArgs" .= frontendTargetArgs manifest,
          "inputHashes" .= frontendInputHashes manifest,
          "programHash" .= frontendProgramHash manifest,
          "createdAt" .= frontendCreatedAt manifest
        ]
          <> maybe [] (\parent -> ["parentRunId" .= runIdText parent]) (frontendParentRunId manifest)
          <> maybe [] (\lineage -> ["lineage" .= lineage]) (frontendLineage manifest)
          <> ["lineageEdits" .= frontendLineageEdits manifest | not (null (frontendLineageEdits manifest))]
      versionedFields =
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
  parseJSON = withObject "frontend manifest" $ \o ->
    case KeyMap.lookup "frontendManifestVersion" o of
      Nothing -> parseLegacyManifest o
      Just encodedVersion -> do
        current <- parseJSON encodedVersion
        if current == frontendManifestVersion
          then parseVersion2Manifest o
          else if current == frontendManifestVersionWithInvocation
            then parseVersion3Manifest o
            else fail ("unsupported frontend manifest version " <> show (current :: Int))

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
  parseVersionedManifest frontendManifestVersion Nothing False o

parseVersion3Manifest :: Object -> Parser FrontendManifest
parseVersion3Manifest o = do
  onlyKeys "frontend manifest" version3Keys o
  requireKeys "frontend manifest" version3Keys o
  invocation <- o .: "invocation"
  parseVersionedManifest frontendManifestVersionWithInvocation (Just invocation) True o

parseVersionedManifest :: Int -> Maybe FrontendInvocation -> Bool -> Object -> Parser FrontendManifest
parseVersionedManifest version invocation strictFields o = do
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
  parentText <- if strictFields then o .: "parentRunId" else o .:? "parentRunId"
  parent <- traverse parsedRunId parentText
  lineageText <- if strictFields then o .: "lineage" else o .:? "lineage"
  lineage <- traverse parsedLineage lineageText
  runtimeStore <- T.unpack <$> o .: "runtimeStore"
  unless (normalise runtimeStore == "runtime" && not (isAbsolute runtimeStore)) $
    fail "frontend runtime store is not the fixed relative path runtime"
  personAnswering <- o .: "personAnswering"
  owner <- o .: "ownerId" >>= parsedName "owner"
  runnerVersion <- o .: "runnerVersion"
  targetArgs <- if strictFields then o .: "targetArgs" else fromMaybe [] <$> o .:? "targetArgs"
  lineageEdits <- if strictFields then o .: "lineageEdits" else fromMaybe [] <$> o .:? "lineageEdits"
  persona <- if strictFields then o .: "persona" else o .:? "persona"
  policyDigest <- if strictFields then o .: "policyDigest" else o .:? "policyDigest"
  pure
    FrontendManifest
      { frontendVersion = version,
        frontendRunId = runId,
        frontendRunnerId = runnerId,
        frontendRunnerExecutable = Just executable,
        frontendRunnerVersion = Just runnerVersion,
        frontendInvocation = invocation,
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

invocationKeys :: [Text]
invocationKeys = ["version", "runnerAlias", "executable", "prefixArgs"]

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

version3Keys :: [Text]
version3Keys = version2Keys <> ["invocation"]

boundedNonWhitespace :: String -> Int -> Text -> Parser Text
boundedNonWhitespace label limit value
  | T.null (T.strip value) = fail ("frontend " <> label <> " is whitespace")
  | T.any (== '\NUL') value = fail ("frontend " <> label <> " contains NUL")
  | BS.length (TE.encodeUtf8 value) > limit = fail ("frontend " <> label <> " exceeds " <> show limit <> " UTF-8 bytes")
  | otherwise = pure value

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

requireKeys :: String -> [Text] -> Object -> Parser ()
requireKeys label required object' =
  case filter (`notElem` map toText (keys object')) required of
    [] -> pure ()
    missing -> fail (label <> " is missing field(s): " <> T.unpack (T.intercalate ", " missing))


snapshotErrorText :: Show a => a -> Text
snapshotErrorText = T.pack . show

boundedFailure :: SomeException -> Text
boundedFailure = T.take 500 . T.unwords . T.words . T.pack . displayException
