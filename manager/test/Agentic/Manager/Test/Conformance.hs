{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The store side of the manager conformance lane.
--
-- 'readStored' reads the logical rows of a coordination database of schema
-- version 12 inside one Store read transaction. 'projectStored' maps those
-- rows to the coordination state of the pinned encoding of
-- "Agentic.Manager.Test.Oracle", and 'encodeHistory' encodes the same rows,
-- with the approval arguments of the manager log, as a history of model
-- transitions and run observations with the evidence table that the stored
-- facts support. Each mapping choice is a named function, and its comment
-- states the representation assumption. @bisim/manager/README.md@ documents
-- the mapping, the history and each evidence derivation.
--
-- The model has no transition for authoring, enqueueing, preparing or
-- associating a request, for supervision or for acknowledgements. The
-- history supplies those facts as environment steps between the
-- transitions, and 'comparedView' removes the fields that only the
-- environment writes before the final state is compared.
module Agentic.Manager.Test.Conformance
  ( -- * Stored rows
    Stored (..),
    readStored,
    withRetainedRoot,
    retainedRoots,

    -- * Projection
    projectCoordination,
    projectStored,

    -- * History
    ApprovalArguments (..),
    approvalArguments,
    HistoryItem (..),
    ItemKind (..),
    History (..),
    encodeHistory,

    -- * The storage square
    comparedView,
    comparedDimensions,
    excludedFields,
  )
where

import Agentic.Manager.Configuration (closeConfiguration, installConfiguration, loadConfiguration)
import Agentic.Manager.Flow (CommandBody (..), ManagerLogReport (..), ManagerValue (CommandValue))
import Agentic.Manager.Profile (Diagnostic (InvalidConfiguration, InvalidReply))
import Agentic.Manager.Protocol.Command (Operation (Approve), encoded)
import Agentic.Manager.Store (CoordinationStore, query, runRead, transactionGeneration, withInspectingStore)
import Agentic.Manager.Test.Oracle
import Agentic.Runtime (About (..), FlowEntry (..), Record (..))
import Control.DeepSeq (NFData)
import Control.Exception (finally, throwIO)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Trans.State.Strict (State, execState, gets, modify')
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Time.Clock (UTCTime)
import qualified Database.SQLite3 as SQL
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.Directory (copyFile, createDirectory, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Stored rows
-- ---------------------------------------------------------------------------

-- | One SQLite value, without its column type.
data Cell = CellText !Text | CellInteger !Int64 | CellBlob !BS.ByteString | CellNull
  deriving (Eq, Show, Generic, NFData)

data RequestRow = RequestRow
  { rqId, rqRevision, rqProfile, rqProfileRevision, rqPhase :: !Text,
    rqQueueOrdinal :: !(Maybe Text),
    rqValidation :: !BS.ByteString
  }
  deriving (Eq, Show, Generic, NFData)

data InputRow = InputRow
  { inRequest, inName :: !Text,
    inSource, inLiteralDigest, inCapture :: !(Maybe Text)
  }
  deriving (Eq, Show, Generic, NFData)

data ReservationRow = ReservationRow
  { rsRowid :: !Int64,
    rsId, rsRequest :: !Text,
    rsSlot :: !(Maybe Int64),
    rsState :: !Text,
    rsRequestRevision, rsProfileRevision, rsQueueOrdinal :: !(Maybe Text)
  }
  deriving (Eq, Show, Generic, NFData)

data ResourceRow = ResourceRow {rrReservation, rrKind, rrKey :: !Text}
  deriving (Eq, Show, Generic, NFData)

data PreparationRow = PreparationRow
  { ppId, ppRevision, ppRequest, ppRequestRevision, ppProfileRevision, ppReservation,
    ppGeneration, ppWorker, ppNativeRun, ppExpires, ppDigest :: !Text,
    ppReview :: !BS.ByteString,
    ppState :: !Text
  }
  deriving (Eq, Show, Generic, NFData)

data RunRow = RunRow
  { rnId :: !Text,
    rnRequest, rnPreparation :: !(Maybe Text),
    rnSupervision :: !Text
  }
  deriving (Eq, Show, Generic, NFData)

data CommandRow = CommandRow
  { cmRowid :: !Int64,
    cmId, cmOperation, cmClient, cmEpoch :: !Text,
    cmPrecondition, cmRequest, cmRun, cmPreparation, cmDecision :: !(Maybe Text),
    cmAcceptedAt, cmState :: !Text,
    cmBodySha :: !(Maybe Text),
    cmAcknowledgement, cmEffect :: !(Maybe BS.ByteString)
  }
  deriving (Eq, Show, Generic, NFData)

data DecisionRow = DecisionRow
  { dcId, dcRun, dcOccurrence :: !Text,
    dcAttempt :: !(Maybe Text),
    dcGeneration, dcSequence, dcState :: !Text,
    dcCommand :: !(Maybe Text)
  }
  deriving (Eq, Show, Generic, NFData)

data ArtifactRow = ArtifactRow {arId, arRun :: !Text, arReference :: !BS.ByteString, arVerification :: !Text, arExportSha :: !(Maybe Text)}
  deriving (Eq, Show, Generic, NFData)

data StartRow = StartRow {stCommand, stRequest, stPreparation, stRun, stReservation, stGeneration :: !Text}
  deriving (Eq, Show, Generic, NFData)

data ControlRow = ControlRow {ctCommand, ctRun :: !Text, ctDecision :: !(Maybe Text), ctNative :: !Text}
  deriving (Eq, Show, Generic, NFData)

-- | The logical rows of one coordination database, read in one transaction.
data Stored = Stored
  { storedGeneration, storedAuthority, storedStream :: !Text,
    storedRequests :: ![RequestRow],
    storedInputs :: ![InputRow],
    storedCaptures :: ![(Text, Text)],
    storedReservations :: ![ReservationRow],
    storedResources :: ![ResourceRow],
    storedPreparations :: ![PreparationRow],
    storedRuns :: ![RunRow],
    storedCommands :: ![CommandRow],
    storedDecisions :: ![DecisionRow],
    storedArtifacts :: ![ArtifactRow],
    storedStarts :: ![StartRow],
    storedControls :: ![ControlRow]
  }
  deriving (Eq, Show, Generic, NFData)

cell :: SQL.SQLData -> Cell
cell = \case
  SQL.SQLText t -> CellText t
  SQL.SQLInteger n -> CellInteger n
  SQL.SQLBlob b -> CellBlob b
  SQL.SQLNull -> CellNull
  SQL.SQLFloat d -> CellText (T.pack (show d))

-- | Read the rows that the projection and the history use, inside one Store
-- read transaction. The result is decoded after the transaction, so a
-- decoding failure names its table.
readStored :: CoordinationStore -> IO Stored
readStored store = do
  tables <- runRead store $ do
    generation <- transactionGeneration
    rows <- forM statements $ \sql -> map (map cell) <$> query sql []
    pure (generation, rows)
  either (throwIO . userError . ("manager-conformance store rows: " <>)) pure (decodeStored tables)
  where
    statements =
      [ "SELECT authority_epoch,stream_id FROM service_metadata WHERE singleton=1",
        "SELECT id,revision,profile_id,profile_revision,phase,queue_ordinal,validation_errors FROM requests ORDER BY rowid",
        "SELECT request_id,name,source,hex(literal_digest),capture_id FROM request_inputs ORDER BY request_id,declaration_ordinal",
        "SELECT id,sha256 FROM captures ORDER BY id",
        "SELECT rowid,id,request_id,slot,state,request_revision,profile_revision,queue_ordinal FROM reservations ORDER BY rowid",
        "SELECT reservation_id,kind,resource_key FROM reservation_resources ORDER BY reservation_id,kind,resource_key",
        "SELECT id,revision,request_id,request_revision,profile_revision,reservation_id,process_generation,worker_identity,native_run_id,expires_at,review_digest,review,state FROM preparations ORDER BY rowid",
        "SELECT id,request_id,preparation_id,supervision FROM runs ORDER BY rowid",
        "SELECT rowid,id,operation,client_id,authority_epoch,precondition,request_id,run_id,preparation_id,decision_id,accepted_at,state,lower(hex(body_sha256)),acknowledgement,effect_evidence FROM commands ORDER BY rowid",
        "SELECT id,run_id,occurrence_id,attempt_id,generation,observed_sequence,state,command_id FROM decisions ORDER BY run_id,length(observed_sequence),observed_sequence",
        "SELECT a.id,a.run_id,a.private_reference,a.verification,(SELECT e.expected_sha256 FROM exports e WHERE e.artifact_id=a.id) FROM artifacts a ORDER BY a.rowid",
        "SELECT command_id,request_id,preparation_id,run_id,reservation_id,process_generation FROM start_intents",
        "SELECT command_id,run_id,decision_id,native_sha256 FROM control_intents"
      ]

type Decode a = Either String a

decodeStored :: (Text, [[[Cell]]]) -> Decode Stored
decodeStored (generation, tables) = case tables of
  [meta, requests, inputs, captures, reservations, resources, preparations, runs, commands, decisions, artifacts, starts, controls] -> do
    (authority, stream) <- case meta of
      [[CellText a, CellText s]] -> Right (a, s)
      _ -> Left "service_metadata"
    Stored generation authority stream
      <$> table "requests" requestRow requests
      <*> table "request_inputs" inputRow inputs
      <*> table "captures" (\case [i, s] -> (,) <$> txt i <*> txt s; _ -> Left "arity") captures
      <*> table "reservations" reservationRow reservations
      <*> table "reservation_resources" (\case [a, b, c] -> ResourceRow <$> txt a <*> txt b <*> txt c; _ -> Left "arity") resources
      <*> table "preparations" preparationRow preparations
      <*> table "runs" (\case [a, b, c, d] -> RunRow <$> txt a <*> opt b <*> opt c <*> txt d; _ -> Left "arity") runs
      <*> table "commands" commandRow commands
      <*> table "decisions" decisionRow decisions
      <*> table "artifacts" (\case [a, b, c, d, e] -> ArtifactRow <$> txt a <*> txt b <*> bytes c <*> txt d <*> opt e; _ -> Left "arity") artifacts
      <*> table "start_intents" (\case [a, b, c, d, e, f] -> StartRow <$> txt a <*> txt b <*> txt c <*> txt d <*> txt e <*> txt f; _ -> Left "arity") starts
      <*> table "control_intents" (\case [a, b, c, d] -> ControlRow <$> txt a <*> txt b <*> opt c <*> txt d; _ -> Left "arity") controls
  _ -> Left "table count"
  where
    table name row = traverse (either (\e -> Left (name <> ": " <> e)) Right . row)
    requestRow = \case
      [a, b, c, d, e, f, g] -> RequestRow <$> txt a <*> txt b <*> txt c <*> txt d <*> txt e <*> opt f <*> bytes g
      _ -> Left "arity"
    inputRow = \case
      [a, b, c, d, e] -> InputRow <$> txt a <*> txt b <*> opt c <*> optNonEmpty d <*> opt e
      _ -> Left "arity"
    reservationRow = \case
      [a, b, c, d, e, f, g, h] -> ReservationRow <$> int a <*> txt b <*> txt c <*> optInt d <*> txt e <*> opt f <*> opt g <*> opt h
      _ -> Left "arity"
    preparationRow = \case
      [a, b, c, d, e, f, g, h, i, j, k, l, m] ->
        PreparationRow <$> txt a <*> txt b <*> txt c <*> txt d <*> txt e <*> txt f <*> txt g <*> txt h <*> txt i <*> txt j <*> txt k <*> bytes l <*> txt m
      _ -> Left "arity"
    commandRow = \case
      [a, b, c, d, e, f, g, h, i, j, k, l, m, n, o] ->
        CommandRow <$> int a <*> txt b <*> txt c <*> txt d <*> txt e <*> opt f <*> opt g <*> opt h <*> opt i <*> opt j
          <*> txt k <*> txt l <*> optNonEmpty m <*> optBytes n <*> optBytes o
      _ -> Left "arity"
    decisionRow = \case
      [a, b, c, d, e, f, g, h] -> DecisionRow <$> txt a <*> txt b <*> txt c <*> opt d <*> txt e <*> txt f <*> txt g <*> opt h
      _ -> Left "arity"
    txt = \case CellText t -> Right t; other -> Left ("expected text, found " <> show other)
    opt = \case CellNull -> Right Nothing; other -> Just <$> txt other
    optNonEmpty = \case CellNull -> Right Nothing; CellText "" -> Right Nothing; other -> Just <$> txt other
    int = \case CellInteger n -> Right n; other -> Left ("expected integer, found " <> show other)
    optInt = \case CellNull -> Right Nothing; other -> Just <$> int other
    bytes = \case CellBlob b -> Right b; CellText t -> Right (TE.encodeUtf8 t); other -> Left ("expected bytes, found " <> show other)
    optBytes = \case CellNull -> Right Nothing; other -> Just <$> bytes other

-- | The manager roots at or below a path: the path itself when it holds a
-- coordination database, else every directory below it that holds one, in
-- path order.
retainedRoots :: FilePath -> IO [FilePath]
retainedRoots path = do
  here <- doesFileExist (path </> databaseName)
  if here
    then pure [path]
    else do
      directory <- doesDirectoryExist path
      if not directory
        then pure []
        else do
          names <- listDirectory path
          concat <$> mapM (\name -> do
            sub <- doesDirectoryExist (path </> name)
            if sub then retainedRoots (path </> name) else pure []) (sort names)

databaseName :: FilePath
databaseName = "coordination.sqlite3"

-- | Run an action with a Store lifetime over a private copy of a retained
-- manager root. The copy holds the database with its companion files, the
-- root role and the manager log. A private configuration with no profile
-- names the copy, and 'withInspectingStore' opens it, so the check neither
-- migrates, reconciles nor writes to the retained root or to its copy's
-- rows. The action receives the path of the copied flow directory when the
-- root has one. The copy is removed when the action ends.
withRetainedRoot :: FilePath -> (CoordinationStore -> Maybe FilePath -> IO a) -> IO a
withRetainedRoot root action = do
  temporary <- getTemporaryDirectory
  base <- mkdtemp (temporary </> "manager-conformance-")
  flip finally (removeDirectoryRecursive base) $ do
    let copy = base </> "manager"
        configuration = base </> "configuration.json"
    privateDirectory copy
    forM_ [databaseName, databaseName <> "-wal", databaseName <> "-shm", ".agentic-root-role.json"] $ \name -> do
      present <- doesFileExist (root </> name)
      when present (privateFile (root </> name) (copy </> name))
    hasFlow <- doesDirectoryExist (root </> "flow")
    when hasFlow (copyTree (root </> "flow") (copy </> "flow"))
    BS.writeFile configuration (encoded (inspectionConfiguration copy))
    setFileMode configuration 0o600
    loaded <- loadConfiguration (const (Left InvalidConfiguration)) (\_ _ -> Left InvalidReply) (const False) configuration
    config <- either (throwIO . userError . ("manager-conformance configuration: " <>) . show) pure loaded
    installed <- installConfiguration config >>= either (throwIO . userError . ("manager-conformance install: " <>) . show) pure
    flip finally (closeConfiguration installed) $
      withInspectingStore installed $ \store ->
        action store (if hasFlow then Just (copy </> "flow") else Nothing)
  where
    privateDirectory path = createDirectory path >> setFileMode path 0o700
    privateFile from to = copyFile from to >> setFileMode to 0o600
    copyTree from to = do
      privateDirectory to
      names <- listDirectory from
      forM_ names $ \name -> do
        directory <- doesDirectoryExist (from </> name)
        if directory then copyTree (from </> name) (to </> name) else privateFile (from </> name) (to </> name)

-- | A configuration with no runner and no profile. The inspection reads rows
-- only, so it names no executable and starts no worker.
inspectionConfiguration :: FilePath -> Value
inspectionConfiguration root =
  object
    [ "version" .= (1 :: Int),
      "managerRoot" .= root,
      "localRetentionRoots" .= ([] :: [FilePath]),
      "runners" .= ([] :: [Value]),
      "profiles" .= ([] :: [Value]),
      "limits"
        .= object
          [ "drafts" .= (10 :: Int), "globalDrafts" .= (20 :: Int), "globalCaptureBytes" .= (67108864 :: Int),
            "globalPageSets" .= (2 :: Int), "globalConnections" .= (8 :: Int), "globalDatabaseReaders" .= (2 :: Int),
            "globalMutationLedgerBytes" .= (8388608 :: Int), "safetyControlsPerMinute" .= (20 :: Int),
            "executionReservations" .= (16 :: Int) ]
    ]

-- ---------------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------------

-- | Read the final rows of a Store in one read transaction and project them.
projectCoordination :: CoordinationStore -> IO Coordination
projectCoordination store = projectStored <$> readStored store

-- | The coordination state of the stored rows.
projectStored :: Stored -> Coordination
projectStored stored =
  Coordination
    { coordinationGeneration = storedGeneration stored,
      coordinationAuthority = storedAuthority stored,
      coordinationSlots = schemaSlots,
      coordinationProfiles = Map.empty,
      coordinationRequests = Map.fromList [(rqId r, projectRequest stored r) | r <- storedRequests stored],
      coordinationReservations =
        Map.fromList [(rsRequest r, reservationLease stored r) | r <- storedReservations stored, reservationKept r],
      coordinationPreparations =
        Map.fromList [(ppId p, preparedOf stored p (preparationPhase (ppState p))) | p <- storedPreparations stored],
      coordinationRuns = Map.fromList [(rnId r, request) | r <- storedRuns stored, Just request <- [rnRequest r]],
      coordinationSupervision = Map.fromList [(rnId r, supervisionOf (rnSupervision r)) | r <- storedRuns stored],
      coordinationDecisions =
        Map.fromListWith (flip (<>))
          [(dcRun d, [Decision (keyOf d) (pendingCommand d)]) | d <- storedDecisions stored, dcState d `elem` ["pending", "submitting"]],
      coordinationCommands = Map.fromList (mapMaybe (\c -> (,) (cmId c) <$> receiptOf stored c) (storedCommands stored)),
      coordinationCaptures = Map.fromList (storedCaptures stored),
      coordinationArtifacts = Map.fromList [(arId a, artifactOf a) | a <- storedArtifacts stored]
    }

-- | The generation of the projection is the process generation of the Store
-- lifetime that reads the rows. The rows hold no current process generation,
-- because it identifies a live process. A retained root that is read after
-- its manager stopped therefore has a newer generation than its
-- preparations, as a restart would give it. The authority is
-- @service_metadata.authority_epoch@.
--
-- The slots are the slot numbers 0 to 15 that the schema admits, as
-- @slot-<n>@. The configured capacity is configuration, not a stored row.
schemaSlots :: Set.Set Text
schemaSlots = Set.fromList [slotName n | n <- [0 .. 15]]

slotName :: Int64 -> Text
slotName n = "slot-" <> T.pack (show n)

-- | An operator key is @key:<key>@ and the unclassified cohort is
-- @unclassified@, as in the admission lane. The two kinds of
-- @reservation_resources@ cannot then share a string.
resourceName :: Text -> Text -> Text
resourceName "operator" key = "key:" <> key
resourceName _ _ = "unclassified"

-- | The phase names of the schema, with @start-pending@ as @startPending@.
phaseOf :: Text -> RequestPhase
phaseOf = \case
  "draft" -> PhaseDraft
  "queued" -> PhaseQueued
  "preparing" -> PhasePreparing
  "review" -> PhaseReview
  "start-pending" -> PhaseStartPending
  "associated" -> PhaseAssociated
  "withdrawn" -> PhaseWithdrawn
  "refused" -> PhaseRefused
  other -> error ("manager-conformance: unknown request phase " <> T.unpack other)

-- | A stored queue ordinal is the decimal text of a natural number.
queueOrdinal :: Maybe Text -> Maybe Natural
queueOrdinal = (>>= readMaybe . T.unpack)

-- | A request maps to the request of the model. The revision, the profile
-- and its revision, the phase and the queue ordinal are the stored columns.
-- 'requestReadiness' gives the inputs, 'currentPreparation' the preparation,
-- and the run is the run row that names the request.
projectRequest :: Stored -> RequestRow -> Request
projectRequest stored r =
  Request
    { requestRevision = rqRevision r,
      requestProfile = rqProfile r,
      requestProfileRevision = rqProfileRevision r,
      requestPhase = phaseOf (rqPhase r),
      requestQueueOrdinal = queueOrdinal (rqQueueOrdinal r),
      requestInputs = requestReadiness stored r,
      requestPreparation = currentPreparation stored (rqId r),
      requestRun = listToMaybe [rnId run | run <- storedRuns stored, rnRequest run == Just (rqId r)]
    }

-- | The required inputs are the declared inputs of @request_inputs@. A bound
-- input is supplied: a capture binds the capture identity, and a literal
-- binds @literal:<digest>@, the hexadecimal digest of its bytes. The invalid
-- inputs are the names of the stored validation errors.
requestReadiness :: Stored -> RequestRow -> Readiness
requestReadiness stored r =
  Readiness
    { readinessRequired = Set.fromList (map inName inputs),
      readinessSupplied = Map.fromList [(inName i, value) | i <- inputs, Just value <- [inputValue i]],
      readinessInvalid = validationNames (rqValidation r)
    }
  where
    inputs = [i | i <- storedInputs stored, inRequest i == rqId r]

inputValue :: InputRow -> Maybe Text
inputValue i = case inSource i of
  Just "capture" -> inCapture i
  Just "literal" -> ("literal:" <>) . T.toLower <$> inLiteralDigest i
  _ -> Nothing

-- | A validation error names an input by a string or by an object with the
-- field @name@. Any other element names itself by its JSON text.
validationNames :: BS.ByteString -> Set.Set Text
validationNames bytes = case eitherDecodeStrict' bytes of
  Right (Array items) -> Set.fromList (map name (foldr (:) [] items))
  _ -> Set.singleton (TE.decodeUtf8 bytes)
  where
    name = \case
      String t -> t
      Object o | Just (String t) <- KM.lookup "name" o -> t
      other -> TE.decodeUtf8 (encodeLine other)

-- | The preparation of a request is the preparation of its run when a run
-- names the request, else its live preparation, else none. An invalidated
-- preparation that no run uses is not the current preparation of a request.
currentPreparation :: Stored -> Text -> Maybe Text
currentPreparation stored request =
  case [p | run <- storedRuns stored, rnRequest run == Just request, Just p <- [rnPreparation run]] of
    p : _ -> Just p
    [] -> listToMaybe [ppId p | p <- storedPreparations stored, ppRequest p == request, ppState p == "live"]

-- | Held, cleanup-pending and quarantined reservations hold their slot and
-- their keys, so they are kept. A released reservation holds neither and is
-- dropped. The model keys a reservation by its owner, the request.
reservationKept :: ReservationRow -> Bool
reservationKept r = rsState r /= "released"

-- | The lease of a reservation: its slot and the names of its claimed
-- resources. A released reservation has no stored slot and no claim, and
-- its lease has the slot @released@ and no key. The history replaces that
-- slot, as 'encodeHistory' states.
reservationLease :: Stored -> ReservationRow -> Reservation
reservationLease stored r =
  Reservation
    (maybe "released" slotName (rsSlot r))
    (Set.fromList [resourceName (rrKind k) (rrKey k) | k <- storedResources stored, rrReservation k == rsId r])

preparationPhase :: Text -> PreparationPhase
preparationPhase = \case
  "live" -> PreparationLive
  "consumed" -> PreparationConsumed
  "invalidated" -> PreparationInvalidated
  other -> error ("manager-conformance: unknown preparation state " <> T.unpack other)

-- | A preparation maps to a prepared review with the given phase. The
-- profile is the profile of its request. The run is the manager run that
-- names the preparation, else the native run identity, because the store
-- creates the manager run only at approval. The authority, the revision and
-- the review follow 'authorityOf', 'revisionOf' and
-- 'reviewOf'.
preparedOf :: Stored -> PreparationRow -> PreparationPhase -> Prepared
preparedOf stored p phase =
  Prepared
    { preparedRequest = ppRequest p,
      preparedRequestRevision = ppRequestRevision p,
      preparedProfile = maybe "" rqProfile (listToMaybe [r | r <- storedRequests stored, rqId r == ppRequest p]),
      preparedProfileRevision = ppProfileRevision p,
      preparedRun = fromMaybe (ppNativeRun p) (listToMaybe [rnId r | r <- storedRuns stored, rnPreparation r == Just (ppId p)]),
      preparedNativeRun = ppNativeRun p,
      preparedWorker = ppWorker p,
      preparedGeneration = ppGeneration p,
      preparedAuthority = authorityOf stored p,
      preparedRevision = revisionOf stored p,
      preparedDigest = ppDigest p,
      preparedReview = reviewOf p,
      preparedPhase = phase
    }

-- | The command that consumed a preparation: the command of its start
-- intent.
consumingCommand :: Stored -> PreparationRow -> Maybe CommandRow
consumingCommand stored p =
  listToMaybe [c | s <- storedStarts stored, stPreparation s == ppId p, c <- storedCommands stored, cmId c == stCommand s]

-- | A preparation row has no authority epoch. A consumed preparation has the
-- epoch of the approve command that consumed it. Any other preparation has
-- the current epoch, because a restoration, which changes the epoch,
-- invalidates every preparation.
authorityOf :: Stored -> PreparationRow -> Text
authorityOf stored p = maybe (storedAuthority stored) cmEpoch (consumingCommand stored p)

-- | The store changes the revision of a preparation when it consumes it. The
-- revision that the approval named survives only as the precondition of the
-- approve command. A consumed preparation therefore has that precondition
-- as its revision, and any other preparation has its row revision.
revisionOf :: Stored -> PreparationRow -> Text
revisionOf stored p = case consumingCommand stored p >>= cmPrecondition of
  Just precondition -> unquote precondition
  Nothing -> ppRevision p

unquote :: Text -> Text
unquote t = fromMaybe t (T.stripPrefix "\"" t >>= T.stripSuffix "\"")

-- | The review value is the hexadecimal SHA-256 of the stored review bytes.
reviewOf :: PreparationRow -> Text
reviewOf = sha256 . ppReview

sha256 :: BS.ByteString -> Text
sha256 bytes = T.pack (show (hash bytes :: Digest SHA256))

supervisionOf :: Text -> Supervision
supervisionOf = \case
  "owned" -> SupervisionOwned
  "cleanup-pending" -> SupervisionCleanupPending
  "lost" -> SupervisionLost
  "observer" -> SupervisionObserver
  other -> error ("manager-conformance: unknown supervision " <> T.unpack other)

-- | The key of a decision. Its revision is the observed sequence, the
-- runtime sequence of the event that opened the decision, because the row
-- revision changes with the state of the decision.
keyOf :: DecisionRow -> DecisionKey
keyOf d = DecisionKey (dcId d) (dcSequence d) (dcOccurrence d) (dcAttempt d) (dcGeneration d)

-- | A submitting decision is reserved by its command. A pending decision is
-- not reserved, even when it still names a command that did not take
-- effect.
pendingCommand :: DecisionRow -> Maybe Text
pendingCommand d = if dcState d == "submitting" then dcCommand d else Nothing

-- | The decision that a command answers: the decision of the command row,
-- else of its control intent, else the decision that names the command.
decisionOf :: Stored -> CommandRow -> Maybe DecisionRow
decisionOf stored c = listToMaybe [d | d <- storedDecisions stored, Just (dcId d) == linked]
  where
    linked = case cmDecision c of
      Just d -> Just d
      Nothing -> case [d | ctl <- storedControls stored, ctCommand ctl == cmId c, Just d <- [ctDecision ctl]] of
        d : _ -> Just d
        [] -> listToMaybe [dcId d | d <- storedDecisions stored, dcCommand d == Just (cmId c)]

-- | The preparation that an approve command consumed: the preparation of its
-- start intent, else the preparation that the command row names.
approvedPreparation :: Stored -> CommandRow -> Maybe PreparationRow
approvedPreparation stored c = listToMaybe [p | p <- storedPreparations stored, Just (ppId p) == named]
  where
    named = case [stPreparation s | s <- storedStarts stored, stCommand s == cmId c] of
      p : _ -> Just p
      [] -> cmPreparation c

-- | The model has a receipt for an approve command and for a command that
-- answers a decision, which is an answer or a recovery choice. Any other
-- operation, and a refused command, has no intent of the model.
receiptOf :: Stored -> CommandRow -> Maybe Receipt
receiptOf stored c = do
  delivery <- commandDelivery (cmState c)
  intent <- intentOf stored c
  pure (Receipt (cmClient c) intent delivery (commandAcknowledgements (cmAcknowledgement c)) (sha256 <$> cmEffect c))

-- | The intent of an approve command is the start of the prepared review in
-- the live phase that the approval consumed. The intent of an answer is the
-- run, the key and the value of the decision.
intentOf :: Stored -> CommandRow -> Maybe Intent
intentOf stored c
  | cmOperation c == "approve" = (\p -> IntentStart (preparedOf stored p PreparationLive)) <$> approvedPreparation stored c
  | otherwise = (\d -> IntentAnswer (dcRun d) (keyOf d) (answerValue stored c)) <$> decisionOf stored c

-- | The value of an answer is the SHA-256 of the native control bytes that
-- the manager recorded, else the SHA-256 of the command body.
answerValue :: Stored -> CommandRow -> Text
answerValue stored c =
  case [ctNative ctl | ctl <- storedControls stored, ctCommand ctl == cmId c] of
    native : _ -> native
    [] -> fromMaybe "" (cmBodySha c)

-- | The delivery knowledge of a command state. An accepted command is not
-- attempted. A dispatched, acknowledged or effect-observed command is
-- attempted. An unresolved command is uncertain. A refused command has no
-- receipt in the model.
commandDelivery :: Text -> Maybe Delivery
commandDelivery = \case
  "accepted" -> Just DeliveryNotAttempted
  "dispatch-attempted" -> Just DeliveryAttempted
  "acknowledged" -> Just DeliveryAttempted
  "effect-observed" -> Just DeliveryAttempted
  "unresolved" -> Just DeliveryUncertain
  "refused" -> Nothing
  other -> error ("manager-conformance: unknown command state " <> T.unpack other)

-- | The store keeps the newest native acknowledgement of a command. Its
-- state names one acknowledgement of the model, and @failed@ is
-- @controlFailed@.
commandAcknowledgements :: Maybe BS.ByteString -> [Acknowledgement]
commandAcknowledgements Nothing = []
commandAcknowledgements (Just bytes) = case eitherDecodeStrict' bytes of
  Right (Object o) | Just (String state) <- KM.lookup "state" o -> [acknowledgement state]
  _ -> error "manager-conformance: an acknowledgement without a state"
  where
    acknowledgement = \case
      "accepted" -> AcknowledgementAccepted
      "queued" -> AcknowledgementQueued
      "delivered" -> AcknowledgementDelivered
      "rejected-stale" -> AcknowledgementRejectedStale
      "unsupported" -> AcknowledgementUnsupported
      "failed" -> AcknowledgementControlFailed
      other -> error ("manager-conformance: unknown acknowledgement " <> T.unpack other)

-- | The reference of an artifact is its stored private reference text. A
-- verified artifact has the value of the SHA-256 in that reference, which
-- the manager verified the bytes against.
artifactOf :: ArtifactRow -> Artifact
artifactOf a = case arVerification a of
  "verified" -> ArtifactVerified reference (artifactSha256 a)
  "unavailable" -> ArtifactUnavailable reference
  _ -> ArtifactReferenced reference
  where
    reference = artifactReference a

artifactReference :: ArtifactRow -> Text
artifactReference = TE.decodeUtf8 . arReference

-- | The SHA-256 that the manager verified an artifact against. A result
-- reference names it in its field @sha256@. The receipt artifact of an
-- export names the body of its command instead, and its verified content
-- is the exported document, whose SHA-256 is @exports.expected_sha256@. A
-- verified artifact without either stops the lane.
artifactSha256 :: ArtifactRow -> Text
artifactSha256 a = case eitherDecodeStrict' (arReference a) of
  Right (Object o) | Just (String value) <- KM.lookup "sha256" o -> value
  _ | Just value <- arExportSha a -> value
  _ -> error ("manager-conformance: artifact " <> T.unpack (arId a) <> " has no SHA-256 in its reference")

-- ---------------------------------------------------------------------------
-- Approval arguments from the manager log
-- ---------------------------------------------------------------------------

-- | The arguments of an approve command that its ask in the manager log
-- carries. The rows keep the precondition only.
data ApprovalArguments = ApprovalArguments
  { approvalDigest, approvalRequestRevision, approvalProfileRevision, approvalGeneration :: !Text }
  deriving (Eq, Show)

-- | The approval arguments of each approve ask of a manager log, by command.
approvalArguments :: ManagerLogReport -> Map.Map Text ApprovalArguments
approvalArguments report =
  Map.fromList
    [ (command, arguments)
      | entry <- managerLogEntries report,
        Just record <- [entryRecord entry],
        Just command <- [aboutCommand (recAbout record)],
        Just (CommandValue body) <- [Map.lookup (entryPosition entry) (managerLogValues report)],
        commandBodyOperation body == Approve,
        Just (Object o) <- [commandBodyValue body],
        Just arguments <- [ApprovalArguments <$> field o "reviewDigest" <*> field o "requestRevision" <*> field o "profileRevision" <*> field o "processGeneration"]
    ]
  where
    field o name = case KM.lookup (Key.fromText name) o of
      Just (String t) -> Just t
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

-- | The source of a submitted entry.
data ItemKind
  = -- | An accepted command of the ledger with a model intent.
    LedgerTransition !Text
  | -- | An accepted command of the ledger without a model intent, as an
    -- observation.
    LedgerObservation !Text
  | -- | A transition that other stored facts imply: an admission, a decision
    -- opening, a resolution, a delivery, a release or a verification.
    StoredTransition !Text
  deriving (Eq, Show)

data HistoryItem
  = -- | A fact outside the model, applied to the state before the next entry.
    Environment !Text !(Coordination -> Coordination)
  | Submit !ItemKind !Entry
  | -- | Stored facts that the encoding cannot express. The lane reports a
    -- mismatch.
    Unencodable !Text

data History = History
  { historyInitial :: !Coordination,
    historyEvidence :: !Evidence,
    historyItems :: ![HistoryItem],
    historyLedger :: !Int,
    historyRefused :: !Int,
    historyApprovalsFromLog :: !Int,
    historyApprovalsFromRows :: !Int
  }

data Encoder = Encoder
  { encItems :: ![HistoryItem],
    -- | The reservation of each request in the fold: reservation, lease and request.
    encHeld :: !(Map.Map Text (Text, Reservation, Request)),
    encDone :: !(Set.Set Text),
    encOpened :: !(Set.Set Text),
    -- | The pending FIFO of each run in the fold, as decision and reserving command.
    encFifo :: !(Map.Map Text [(Text, Maybe Text)]),
    encCleaned :: ![(Text, Reservation)],
    encResolutions :: ![(Text, DecisionKey, Text, Resolution)],
    encFromLog :: !Int,
    encFromRows :: !Int
  }

emit :: HistoryItem -> State Encoder ()
emit item = modify' (\e -> e {encItems = item : encItems e})

-- | Encode the stored rows as a history from the initial state.
--
-- The initial state has the authority and the generation of the projection,
-- the schema slots, the captures, and no other entry. The ledger is read in
-- its accepted order, the rowid order of @commands@. An approve command is
-- preceded by the admission of its reservation and by environment steps that
-- make its preparation live for review. A command that answers a decision is
-- preceded by the openings of the decisions of its run up to that decision,
-- and followed by its resolution when the decision row records one. A
-- command with a model intent is followed by its delivery knowledge. Any
-- other accepted command is an observation. After the ledger, the
-- remaining reservations are admitted, the remaining decisions are opened,
-- and each verified artifact is verified.
encodeHistory :: Map.Map Text ApprovalArguments -> Stored -> History
encodeHistory arguments stored =
  History
    { historyInitial = initial,
      historyEvidence = evidence,
      historyItems = reverse (encItems final),
      historyLedger = length (storedCommands stored),
      historyRefused = length [() | c <- storedCommands stored, cmState c == "refused"],
      historyApprovalsFromLog = encFromLog final,
      historyApprovalsFromRows = encFromRows final
    }
  where
    projection = projectStored stored
    initial =
      (emptyCoordination (storedGeneration stored) (storedAuthority stored))
        { coordinationSlots = schemaSlots,
          coordinationCaptures = coordinationCaptures projection
        }
    final = execState run (Encoder [] Map.empty Set.empty Set.empty Map.empty [] [] 0 0)
    run = do
      forM_ (storedCommands stored) ledgerEntry
      forM_ (storedReservations stored) $ \r -> do
        done <- gets (Set.member (rsId r) . encDone)
        unless done (admitReservation r)
      forM_ (Map.keys runsDecisions) $ \run' -> do
        openUpTo run' Nothing
        closeByEnvironment run' Nothing
      forM_ [a | a <- storedArtifacts stored, arVerification a == "verified"] $ \a ->
        emit (Submit (StoredTransition "verify") (EntryStep (StepVerify (arId a) (artifactReference a) (artifactSha256 a))))
    evidence =
      Evidence
        { evidenceLive = approvedPrepared,
          evidenceUnexpired = [p | (c, row, p) <- approvals, unexpired c row],
          evidenceCleaned = reverse (encCleaned final),
          evidenceOpened = [(dcRun d, keyOf d) | d <- storedDecisions stored],
          evidenceResolutions = reverse (encResolutions final),
          evidenceVerified = [(artifactReference a, artifactSha256 a) | a <- storedArtifacts stored, arVerification a == "verified"]
        }
    approvals = [(c, p, preparedOf stored p PreparationLive) | c <- storedCommands stored, cmOperation c == "approve", cmState c /= "refused", Just p <- [approvedPreparation stored c], isStarted c]
    approvedPrepared = [p | (_, _, p) <- approvals]
    isStarted c = any ((== cmId c) . stCommand) (storedStarts stored)
    unexpired c row = case (parseTime (cmAcceptedAt c), parseTime (ppExpires row)) of
      (Just accepted, Just expires) -> accepted < expires
      _ -> False
    parseTime :: Text -> Maybe UTCTime
    parseTime = iso8601ParseM . T.unpack
    requestOf ident = listToMaybe [r | r <- storedRequests stored, rqId r == ident]
    runsDecisions = Map.fromListWith (flip (<>)) [(dcRun d, [d]) | d <- storedDecisions stored]
    usedByApproval = Set.fromList [ppReservation p | (_, p, _) <- approvals]
    finalHeldSlots = Set.fromList [slotName n | r <- storedReservations stored, reservationKept r, Just n <- [rsSlot r]]
    released r = rsState r == "released"

    ledgerEntry c
      | cmState c == "refused" = pure ()
      | cmOperation c == "approve" = approveEntry c
      | Just d <- decisionOf stored c = answerEntry c d
      | otherwise =
          emit
            ( Submit
                (LedgerObservation (cmOperation c))
                (EntryObservation (fromMaybe "service" (cmRun c <|> cmRequest c)) ("command " <> cmOperation c <> " " <> cmId c))
            )

    deliveryEntry c = case commandDelivery (cmState c) of
      Just knowledge | knowledge /= DeliveryNotAttempted ->
        emit (Submit (StoredTransition "delivery") (EntryStep (StepDelivery (cmId c) knowledge)))
      _ -> pure ()

    approveEntry c = case approvedPreparation stored c of
      Nothing -> emit (Unencodable ("approve command " <> cmId c <> " names no stored preparation"))
      Just p -> case (requestOf (ppRequest p), [r | r <- storedReservations stored, rsId r == ppReservation p]) of
        (Just rq, [reservation]) -> do
          ensureAdmitted reservation
          held <- gets (Map.lookup (rqId rq) . encHeld)
          case held of
            Just (owner, lease, admitted) | owner == rsId reservation -> do
              let given = Map.lookup (cmId c) arguments
                  livePrepared = preparedOf stored p PreparationLive
                  digest = maybe (ppDigest p) approvalDigest given
                  requestRevision = maybe (ppRequestRevision p) approvalRequestRevision given
                  profileRevision = maybe (ppProfileRevision p) approvalProfileRevision given
                  generation = maybe (startGeneration c) approvalGeneration given
                  request = admitted {requestRevision = requestRevision, requestPhase = PhaseReview, requestPreparation = Just (ppId p)}
                  profile = Profile profileRevision True (reservationExclusive lease)
              modify' (\e -> if isJust given then e {encFromLog = encFromLog e + 1} else e {encFromRows = encFromRows e + 1})
              emit $
                Environment ("preparation " <> ppId p <> " is live for review") $ \s ->
                  s
                    { coordinationGeneration = generation,
                      coordinationAuthority = cmEpoch c,
                      coordinationRequests = Map.insert (rqId rq) request (coordinationRequests s),
                      coordinationProfiles = Map.insert (rqProfile rq) profile (coordinationProfiles s),
                      coordinationPreparations = Map.insert (ppId p) livePrepared (coordinationPreparations s),
                      coordinationRuns = Map.insert (preparedRun livePrepared) (rqId rq) (coordinationRuns s)
                    }
              emit $
                Submit (LedgerTransition "approve") $
                  EntryStep (StepApprove (cmId c) (cmClient c) (ppId p) (unquote (fromMaybe "" (cmPrecondition c))) digest livePrepared request profile)
              deliveryEntry c
              emit $
                Environment ("run " <> preparedRun livePrepared <> " is owned") $ \s ->
                  s {coordinationSupervision = Map.insert (preparedRun livePrepared) SupervisionOwned (coordinationSupervision s)}
              modify' (\e -> e {encHeld = Map.insert (rqId rq) (owner, lease, request {requestPhase = PhaseStartPending, requestRun = Just (preparedRun livePrepared)}) (encHeld e)})
              when (released reservation) (releaseHeld (rqId rq))
            _ -> emit (Unencodable ("the reservation of approve command " <> cmId c <> " is not held in the fold"))
        _ -> emit (Unencodable ("approve command " <> cmId c <> " has no single request and reservation"))

    startGeneration c = fromMaybe "" (listToMaybe [stGeneration s | s <- storedStarts stored, stCommand s == cmId c])

    -- Admit the reservation, after every earlier reservation of its request.
    ensureAdmitted r = do
      done <- gets (Set.member (rsId r) . encDone)
      unless done $ do
        forM_ [o | o <- storedReservations stored, rsRequest o == rsRequest r, rsRowid o < rsRowid r] $ \o -> do
          earlier <- gets (Set.member (rsId o) . encDone)
          unless earlier (admitReservation o)
        admitReservation r

    admitReservation r = case requestOf (rsRequest r) of
      Nothing -> emit (Unencodable ("reservation " <> rsId r <> " names no stored request"))
      Just rq -> do
        modify' (\e -> e {encDone = Set.insert (rsId r) (encDone e)})
        existing <- gets (Map.lookup (rqId rq) . encHeld)
        forM_ existing $ \(owner, _, _) ->
          if maybe False released (listToMaybe [o | o <- storedReservations stored, rsId o == owner])
            then releaseHeld (rqId rq)
            else emit (Unencodable ("request " <> rqId rq <> " holds two reservations"))
        occupied <- gets (Set.fromList . map (\(_, lease, _) -> reservationSlot lease) . Map.elems . encHeld)
        let stored' = reservationLease stored r
            free = [slotName n | n <- [0 .. 15], slotName n `Set.notMember` (finalHeldSlots <> occupied)]
        case (released r, listToMaybe free) of
          (True, Nothing) -> emit (Unencodable ("no free slot for released reservation " <> rsId r))
          (_, chosen) -> do
            let lease = case chosen of
                  Just slot | released r -> stored' {reservationSlot = slot}
                  _ -> stored'
                profileRevision = fromMaybe (rqProfileRevision rq) (rsProfileRevision r)
                request =
                  (projectRequest stored rq)
                    { requestRevision = fromMaybe (rqRevision rq) (rsRequestRevision r),
                      requestProfileRevision = profileRevision,
                      requestPhase = PhaseQueued,
                      requestQueueOrdinal = queueOrdinal (rsQueueOrdinal r <|> rqQueueOrdinal rq),
                      requestPreparation = Nothing,
                      requestRun = Nothing
                    }
                profile = Profile profileRevision True (reservationExclusive lease)
            emit $
              Environment ("request " <> rqId rq <> " is queued") $ \s ->
                s
                  { coordinationRequests = Map.insert (rqId rq) request (coordinationRequests s),
                    coordinationProfiles = Map.insert (rqProfile rq) profile (coordinationProfiles s)
                  }
            emit (Submit (StoredTransition "admit") (EntryStep (StepAdmit (rqId rq) request profile lease)))
            modify' (\e -> e {encHeld = Map.insert (rqId rq) (rsId r, lease, request {requestPhase = PhasePreparing}) (encHeld e)})
            when (released r && rsId r `Set.notMember` usedByApproval) (releaseHeld (rqId rq))

    releaseHeld owner = do
      held <- gets (Map.lookup owner . encHeld)
      forM_ held $ \(_, lease, _) -> do
        modify' (\e -> e {encHeld = Map.delete owner (encHeld e), encCleaned = (owner, lease) : encCleaned e})
        emit (Submit (StoredTransition "release") (EntryStep (StepRelease owner)))

    decisionsOf run' = Map.findWithDefault [] run' runsDecisions

    -- Open the decisions of a run in observed order, up to and including the
    -- given decision, or all of them.
    openUpTo run' target = do
      let ordered = decisionsOf run'
          wanted = case target of
            Nothing -> ordered
            Just d -> takeThrough ((== dcId d) . dcId) ordered
      forM_ wanted $ \d -> do
        opened <- gets (Set.member (dcId d) . encOpened)
        unless opened $ do
          modify' (\e -> e {encOpened = Set.insert (dcId d) (encOpened e), encFifo = Map.insertWith (flip (<>)) run' [(dcId d, Nothing)] (encFifo e)})
          emit (Submit (StoredTransition "openDecision") (EntryStep (StepOpenDecision run' (keyOf d))))

    -- Remove from the FIFO of a run each decision, before the given one, that
    -- the store closed without a correlated resolution: a resolved or
    -- invalidated decision that no command of the fold reserves.
    closeByEnvironment run' target = do
      fifo <- gets (Map.findWithDefault [] run' . encFifo)
      let before = case target of
            Nothing -> fifo
            Just d -> takeWhile ((/= dcId d) . fst) fifo
          closed =
            [ ident
              | (ident, Nothing) <- before,
                Just row <- [listToMaybe [d | d <- decisionsOf run', dcId d == ident]],
                dcState row `elem` ["resolved", "invalidated"]
            ]
      unless (null closed) $ do
        let keep = filter ((`notElem` closed) . fst) fifo
        modify' (\e -> e {encFifo = Map.insert run' keep (encFifo e)})
        emit $
          Environment ("the runtime closed " <> T.intercalate ", " closed) $ \s ->
            s {coordinationDecisions = Map.adjust (filter ((`notElem` closed) . keyId . decisionKey)) run' (coordinationDecisions s)}

    answerEntry c d = do
      let run' = dcRun d
          key = keyOf d
      openUpTo run' (Just d)
      closeByEnvironment run' (Just d)
      emit (Submit (LedgerTransition (cmOperation c)) (EntryStep (StepAnswer (cmId c) (cmClient c) run' key (answerValue stored c))))
      modify' (\e -> e {encFifo = Map.adjust (map (\(i, m) -> if i == dcId d then (i, Just (cmId c)) else (i, m))) run' (encFifo e)})
      deliveryEntry c
      let resolve resolution = do
            modify' (\e -> e {encResolutions = (run', key, cmId c, resolution) : encResolutions e})
            emit (Submit (StoredTransition "resolve") (EntryStep (StepResolve run' (cmId c) key resolution)))
      case () of
        _
          | dcCommand d == Just (cmId c) && dcState d == "resolved" -> do
              resolve ResolutionResolved
              modify' (\e -> e {encFifo = Map.adjust (filter ((/= dcId d) . fst)) run' (encFifo e)})
          | dcCommand d == Just (cmId c) && dcState d == "submitting" -> pure ()
          | dcState d == "invalidated" -> do
              -- The runtime closed the decision while the command reserved it.
              modify' (\e -> e {encFifo = Map.adjust (filter ((/= dcId d) . fst)) run' (encFifo e)})
              emit $
                Environment ("the runtime closed " <> dcId d) $ \s ->
                  s {coordinationDecisions = Map.adjust (filter ((/= dcId d) . keyId . decisionKey)) run' (coordinationDecisions s)}
          | otherwise -> do
              resolve ResolutionNotEffective
              modify' (\e -> e {encFifo = Map.adjust (map (\(i, m) -> if i == dcId d then (i, Nothing) else (i, m))) run' (encFifo e)})

takeThrough :: (a -> Bool) -> [a] -> [a]
takeThrough p xs = case break p xs of
  (before, x : _) -> before <> [x]
  (before, []) -> before

(<|>) :: Maybe a -> Maybe a -> Maybe a
Just a <|> _ = Just a
Nothing <|> b = b

-- ---------------------------------------------------------------------------
-- The storage square
-- ---------------------------------------------------------------------------

-- | The dimensions that the comparison covers. Only model transitions of
-- the history write them.
comparedDimensions :: [Text]
comparedDimensions =
  [ "reservations",
    "preparations (consumed)",
    "requests.run",
    "decisions",
    "commands (client, intent, delivery)",
    "artifacts (verified)"
  ]

-- | The fields that only the environment writes, or that the rows do not
-- hold. The comparison removes them from both states.
excludedFields :: [Text]
excludedFields =
  [ "generation",
    "authority",
    "slots",
    "profiles",
    "runs",
    "supervision",
    "captures",
    "requests.revision",
    "requests.profile",
    "requests.profileRevision",
    "requests.phase",
    "requests.queueOrdinal",
    "requests.inputs",
    "requests.preparation",
    "requests without a run",
    "preparations that are live or invalidated",
    "commands.acknowledgements",
    "commands.effect",
    "artifacts that are referenced or unavailable",
    "decisions with an empty FIFO"
  ]

-- | The state restricted to 'comparedDimensions'. An empty FIFO and an
-- absent FIFO are the same pending sequence, because the model reads the
-- FIFO of a run with a default of the empty list.
comparedView :: Coordination -> Coordination
comparedView s =
  (emptyCoordination "" "")
    { coordinationReservations = coordinationReservations s,
      coordinationPreparations = Map.filter ((== PreparationConsumed) . preparedPhase) (coordinationPreparations s),
      coordinationRequests = Map.map runOnly (Map.filter (isJust . requestRun) (coordinationRequests s)),
      coordinationDecisions = Map.filter (not . null) (coordinationDecisions s),
      coordinationCommands = Map.map (\r -> r {receiptAcknowledgements = [], receiptEffect = Nothing}) (coordinationCommands s),
      coordinationArtifacts = Map.filter verified (coordinationArtifacts s)
    }
  where
    runOnly r = Request "" "" "" PhaseDraft Nothing (Readiness Set.empty Map.empty Set.empty) Nothing (requestRun r)
    verified = \case
      ArtifactVerified _ _ -> True
      _ -> False
