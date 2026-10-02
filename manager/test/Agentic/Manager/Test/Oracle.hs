{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Haskell client of the manager oracle.
--
-- The executable @manager-oracle@ of @bisim/manager@ reads one request per
-- line and writes one response per line. A request and a response use the
-- pinned encoding @agent-cat-manager-conformance/1@, which
-- @bisim/manager/README.md@ states. This module holds that encoding as typed
-- records with 'ToJSON' and 'FromJSON' instances, and the connection to one
-- oracle process. It makes no judgment about a response. The lanes of
-- @manager-conformance-check@ make that judgment.
--
-- The encoder writes the fields of each object in increasing order of their
-- names, and writes each set and each map in strictly increasing order of
-- its elements or keys. The decoder refuses a missing field, an unknown
-- field, an unknown tag, an unknown enumeration value, and a set or a map that
-- is not strictly increasing, as the decoder of the oracle does.
module Agentic.Manager.Test.Oracle
  ( -- * The encoding
    conformanceVersion,
    RequestPhase (..),
    PreparationPhase (..),
    Supervision (..),
    Delivery (..),
    Acknowledgement (..),
    Resolution (..),
    Readiness (..),
    Request (..),
    Profile (..),
    Reservation (..),
    Prepared (..),
    DecisionKey (..),
    Decision (..),
    Intent (..),
    Receipt (..),
    Artifact (..),
    Coordination (..),
    emptyCoordination,
    Evidence (..),
    emptyEvidence,
    Step (..),
    Entry (..),
    Query (..),
    Response (..),
    encodeLine,

    -- * The connection
    Oracle,
    OracleError (..),
    defaultOraclePath,
    resolveOraclePath,
    withOracle,
    exchangeLine,
    submit,
  )
where

import Control.Exception (Exception, IOException, bracket, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value (..),
    eitherDecodeStrict',
    encode,
    object,
    withArray,
    withObject,
    withText,
    (.:),
    (.=),
  )
import Data.Aeson.Key (Key)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Pair, Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Numeric.Natural (Natural)
import System.Directory (doesFileExist, executable, getPermissions)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Timeout (timeout)

-- | The version string of the pinned encoding.
conformanceVersion :: Text
conformanceVersion = "agent-cat-manager-conformance/1"

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------

data RequestPhase
  = PhaseDraft
  | PhaseQueued
  | PhasePreparing
  | PhaseReview
  | PhaseStartPending
  | PhaseAssociated
  | PhaseWithdrawn
  | PhaseRefused
  deriving (Eq, Ord, Show, Enum, Bounded)

data PreparationPhase = PreparationLive | PreparationConsumed | PreparationInvalidated
  deriving (Eq, Ord, Show, Enum, Bounded)

data Supervision = SupervisionOwned | SupervisionCleanupPending | SupervisionLost | SupervisionObserver
  deriving (Eq, Ord, Show, Enum, Bounded)

data Delivery = DeliveryNotAttempted | DeliveryAttempted | DeliveryUncertain | DeliveryFailed
  deriving (Eq, Ord, Show, Enum, Bounded)

data Acknowledgement
  = AcknowledgementAccepted
  | AcknowledgementQueued
  | AcknowledgementDelivered
  | AcknowledgementRejectedStale
  | AcknowledgementUnsupported
  | AcknowledgementControlFailed
  deriving (Eq, Ord, Show, Enum, Bounded)

data Resolution = ResolutionResolved | ResolutionNotEffective
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The name of each constructor of an enumeration in the encoding.
class (Enum a, Bounded a) => Named a where
  nameOf :: a -> Text
  kindOf :: a -> String

instance Named RequestPhase where
  kindOf _ = "RequestPhase"
  nameOf = \case
    PhaseDraft -> "draft"
    PhaseQueued -> "queued"
    PhasePreparing -> "preparing"
    PhaseReview -> "review"
    PhaseStartPending -> "startPending"
    PhaseAssociated -> "associated"
    PhaseWithdrawn -> "withdrawn"
    PhaseRefused -> "refused"

instance Named PreparationPhase where
  kindOf _ = "PreparationPhase"
  nameOf = \case
    PreparationLive -> "live"
    PreparationConsumed -> "consumed"
    PreparationInvalidated -> "invalidated"

instance Named Supervision where
  kindOf _ = "Supervision"
  nameOf = \case
    SupervisionOwned -> "owned"
    SupervisionCleanupPending -> "cleanupPending"
    SupervisionLost -> "lost"
    SupervisionObserver -> "observer"

instance Named Delivery where
  kindOf _ = "Delivery"
  nameOf = \case
    DeliveryNotAttempted -> "notAttempted"
    DeliveryAttempted -> "attempted"
    DeliveryUncertain -> "uncertain"
    DeliveryFailed -> "failed"

instance Named Acknowledgement where
  kindOf _ = "Acknowledgement"
  nameOf = \case
    AcknowledgementAccepted -> "accepted"
    AcknowledgementQueued -> "queued"
    AcknowledgementDelivered -> "delivered"
    AcknowledgementRejectedStale -> "rejectedStale"
    AcknowledgementUnsupported -> "unsupported"
    AcknowledgementControlFailed -> "controlFailed"

instance Named Resolution where
  kindOf _ = "Resolution"
  nameOf = \case
    ResolutionResolved -> "resolved"
    ResolutionNotEffective -> "notEffective"

encodeNamed :: Named a => a -> Value
encodeNamed = String . nameOf

decodeNamed :: forall a. Named a => Value -> Parser a
decodeNamed = withText (kindOf (minBound :: a)) $ \given ->
  case [a | a <- [minBound .. maxBound], nameOf a == given] of
    [a] -> pure a
    _ -> fail (kindOf (minBound :: a) <> ": unknown value " <> T.unpack given)

instance ToJSON RequestPhase where toJSON = encodeNamed
instance FromJSON RequestPhase where parseJSON = decodeNamed
instance ToJSON PreparationPhase where toJSON = encodeNamed
instance FromJSON PreparationPhase where parseJSON = decodeNamed
instance ToJSON Supervision where toJSON = encodeNamed
instance FromJSON Supervision where parseJSON = decodeNamed
instance ToJSON Delivery where toJSON = encodeNamed
instance FromJSON Delivery where parseJSON = decodeNamed
instance ToJSON Acknowledgement where toJSON = encodeNamed
instance FromJSON Acknowledgement where parseJSON = decodeNamed
instance ToJSON Resolution where toJSON = encodeNamed
instance FromJSON Resolution where parseJSON = decodeNamed

-- ---------------------------------------------------------------------------
-- Sets, maps and exact objects
-- ---------------------------------------------------------------------------

encodeSet :: Set Text -> Value
encodeSet = toJSON . Set.toAscList

decodeSet :: Value -> Parser (Set Text)
decodeSet value = do
  items <- parseJSON value
  unless (increasing items) (fail "elements are not strictly increasing")
  pure (Set.fromDistinctAscList items)

encodeMap :: (v -> Value) -> Map Text v -> Value
encodeMap f m = toJSON [Array (V.fromList [String k, f v]) | (k, v) <- Map.toAscList m]

decodeMap :: (Value -> Parser v) -> Value -> Parser (Map Text v)
decodeMap f = withArray "map" $ \items -> do
  pairs <- mapM pair (V.toList items)
  unless (increasing (map fst pairs)) (fail "keys are not strictly increasing")
  pure (Map.fromDistinctAscList pairs)
  where
    pair = withArray "[key, value]" $ \kv -> case V.toList kv of
      [key, value] -> (,) <$> parseJSON key <*> f value
      _ -> fail "expected a [key, value] pair"

increasing :: [Text] -> Bool
increasing items = and (zipWith (<) items (drop 1 items))

-- | Refuse an object that does not have exactly the named fields.
exactly :: [Key] -> Object -> Parser ()
exactly names o = do
  case [k | k <- KM.keys o, k `notElem` names] of
    [] -> pure ()
    k : _ -> fail ("unknown field " <> Key.toString k)
  case [n | n <- names, not (KM.member n o)] of
    [] -> pure ()
    n : _ -> fail ("missing field " <> Key.toString n)

-- | The tag of an alternative, read before its other fields are checked.
tagOf :: Object -> Parser Text
tagOf o = o .: "tag"

-- | An object with a tag and exactly the named fields besides the tag.
tagged :: Text -> [Pair] -> Value
tagged tag fields = object (("tag" .= tag) : fields)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

data Readiness = Readiness
  { readinessRequired :: !(Set Text),
    readinessSupplied :: !(Map Text Text),
    readinessInvalid :: !(Set Text)
  }
  deriving (Eq, Show)

instance ToJSON Readiness where
  toJSON r =
    object
      [ "required" .= encodeSet (readinessRequired r),
        "supplied" .= encodeMap String (readinessSupplied r),
        "invalid" .= encodeSet (readinessInvalid r)
      ]

instance FromJSON Readiness where
  parseJSON = withObject "Readiness" $ \o -> do
    exactly ["required", "supplied", "invalid"] o
    Readiness
      <$> (o .: "required" >>= decodeSet)
      <*> (o .: "supplied" >>= decodeMap parseJSON)
      <*> (o .: "invalid" >>= decodeSet)

data Request = Request
  { requestRevision :: !Text,
    requestProfile :: !Text,
    requestProfileRevision :: !Text,
    requestPhase :: !RequestPhase,
    requestQueueOrdinal :: !(Maybe Natural),
    requestInputs :: !Readiness,
    requestPreparation :: !(Maybe Text),
    requestRun :: !(Maybe Text)
  }
  deriving (Eq, Show)

instance ToJSON Request where
  toJSON r =
    object
      [ "revision" .= requestRevision r,
        "profile" .= requestProfile r,
        "profileRevision" .= requestProfileRevision r,
        "phase" .= requestPhase r,
        "queueOrdinal" .= requestQueueOrdinal r,
        "inputs" .= requestInputs r,
        "preparation" .= requestPreparation r,
        "run" .= requestRun r
      ]

instance FromJSON Request where
  parseJSON = withObject "Request" $ \o -> do
    exactly ["revision", "profile", "profileRevision", "phase", "queueOrdinal", "inputs", "preparation", "run"] o
    Request
      <$> o .: "revision"
      <*> o .: "profile"
      <*> o .: "profileRevision"
      <*> o .: "phase"
      <*> o .: "queueOrdinal"
      <*> o .: "inputs"
      <*> o .: "preparation"
      <*> o .: "run"

data Profile = Profile
  { profileRevision :: !Text,
    profileEnabled :: !Bool,
    profileResources :: !(Set Text)
  }
  deriving (Eq, Show)

instance ToJSON Profile where
  toJSON p =
    object
      [ "revision" .= profileRevision p,
        "enabled" .= profileEnabled p,
        "resources" .= encodeSet (profileResources p)
      ]

instance FromJSON Profile where
  parseJSON = withObject "Profile" $ \o -> do
    exactly ["revision", "enabled", "resources"] o
    Profile <$> o .: "revision" <*> o .: "enabled" <*> (o .: "resources" >>= decodeSet)

-- | One global slot and the exclusive keys. The model keeps the two domains
-- separate, so a slot and a key with the same text do not conflict.
data Reservation = Reservation
  { reservationSlot :: !Text,
    reservationExclusive :: !(Set Text)
  }
  deriving (Eq, Show)

instance ToJSON Reservation where
  toJSON r = object ["slot" .= reservationSlot r, "exclusive" .= encodeSet (reservationExclusive r)]

instance FromJSON Reservation where
  parseJSON = withObject "Reservation" $ \o -> do
    exactly ["slot", "exclusive"] o
    Reservation <$> o .: "slot" <*> (o .: "exclusive" >>= decodeSet)

data Prepared = Prepared
  { preparedRequest :: !Text,
    preparedRequestRevision :: !Text,
    preparedProfile :: !Text,
    preparedProfileRevision :: !Text,
    preparedRun :: !Text,
    preparedNativeRun :: !Text,
    preparedWorker :: !Text,
    preparedGeneration :: !Text,
    preparedAuthority :: !Text,
    preparedRevision :: !Text,
    preparedDigest :: !Text,
    preparedReview :: !Text,
    preparedPhase :: !PreparationPhase
  }
  deriving (Eq, Show)

instance ToJSON Prepared where
  toJSON p =
    object
      [ "request" .= preparedRequest p,
        "requestRevision" .= preparedRequestRevision p,
        "profile" .= preparedProfile p,
        "profileRevision" .= preparedProfileRevision p,
        "run" .= preparedRun p,
        "nativeRun" .= preparedNativeRun p,
        "worker" .= preparedWorker p,
        "generation" .= preparedGeneration p,
        "authority" .= preparedAuthority p,
        "revision" .= preparedRevision p,
        "digest" .= preparedDigest p,
        "review" .= preparedReview p,
        "phase" .= preparedPhase p
      ]

instance FromJSON Prepared where
  parseJSON = withObject "Prepared" $ \o -> do
    exactly
      [ "request", "requestRevision", "profile", "profileRevision", "run", "nativeRun", "worker",
        "generation", "authority", "revision", "digest", "review", "phase" ]
      o
    Prepared
      <$> o .: "request"
      <*> o .: "requestRevision"
      <*> o .: "profile"
      <*> o .: "profileRevision"
      <*> o .: "run"
      <*> o .: "nativeRun"
      <*> o .: "worker"
      <*> o .: "generation"
      <*> o .: "authority"
      <*> o .: "revision"
      <*> o .: "digest"
      <*> o .: "review"
      <*> o .: "phase"

data DecisionKey = DecisionKey
  { keyId :: !Text,
    keyRevision :: !Text,
    keyOccurrence :: !Text,
    keyAttempt :: !(Maybe Text),
    keyGeneration :: !Text
  }
  deriving (Eq, Show)

instance ToJSON DecisionKey where
  toJSON k =
    object
      [ "id" .= keyId k,
        "revision" .= keyRevision k,
        "occurrence" .= keyOccurrence k,
        "attempt" .= keyAttempt k,
        "generation" .= keyGeneration k
      ]

instance FromJSON DecisionKey where
  parseJSON = withObject "DecisionKey" $ \o -> do
    exactly ["id", "revision", "occurrence", "attempt", "generation"] o
    DecisionKey <$> o .: "id" <*> o .: "revision" <*> o .: "occurrence" <*> o .: "attempt" <*> o .: "generation"

data Decision = Decision
  { decisionKey :: !DecisionKey,
    decisionCommand :: !(Maybe Text)
  }
  deriving (Eq, Show)

instance ToJSON Decision where
  toJSON d = object ["key" .= decisionKey d, "command" .= decisionCommand d]

instance FromJSON Decision where
  parseJSON = withObject "Decision" $ \o -> do
    exactly ["key", "command"] o
    Decision <$> o .: "key" <*> o .: "command"

data Intent
  = IntentStart !Prepared
  | IntentAnswer !Text !DecisionKey !Text
  deriving (Eq, Show)

instance ToJSON Intent where
  toJSON = \case
    IntentStart p -> tagged "start" ["prepared" .= p]
    IntentAnswer run key value -> tagged "answer" ["run" .= run, "decision" .= key, "value" .= value]

instance FromJSON Intent where
  parseJSON = withObject "Intent" $ \o ->
    tagOf o >>= \case
      "start" -> do
        exactly ["tag", "prepared"] o
        IntentStart <$> o .: "prepared"
      "answer" -> do
        exactly ["tag", "run", "decision", "value"] o
        IntentAnswer <$> o .: "run" <*> o .: "decision" <*> o .: "value"
      tag -> fail ("Intent: unknown tag " <> T.unpack tag)

data Receipt = Receipt
  { receiptClient :: !Text,
    receiptIntent :: !Intent,
    receiptDelivery :: !Delivery,
    receiptAcknowledgements :: ![Acknowledgement],
    receiptEffect :: !(Maybe Text)
  }
  deriving (Eq, Show)

instance ToJSON Receipt where
  toJSON r =
    object
      [ "client" .= receiptClient r,
        "intent" .= receiptIntent r,
        "delivery" .= receiptDelivery r,
        "acknowledgements" .= receiptAcknowledgements r,
        "effect" .= receiptEffect r
      ]

instance FromJSON Receipt where
  parseJSON = withObject "Receipt" $ \o -> do
    exactly ["client", "intent", "delivery", "acknowledgements", "effect"] o
    Receipt <$> o .: "client" <*> o .: "intent" <*> o .: "delivery" <*> o .: "acknowledgements" <*> o .: "effect"

data Artifact
  = ArtifactReferenced !Text
  | ArtifactVerified !Text !Text
  | ArtifactUnavailable !Text
  deriving (Eq, Show)

instance ToJSON Artifact where
  toJSON = \case
    ArtifactReferenced reference -> tagged "referenced" ["reference" .= reference]
    ArtifactVerified reference value -> tagged "verified" ["reference" .= reference, "value" .= value]
    ArtifactUnavailable reference -> tagged "unavailable" ["reference" .= reference]

instance FromJSON Artifact where
  parseJSON = withObject "Artifact" $ \o ->
    tagOf o >>= \case
      "referenced" -> exactly ["tag", "reference"] o >> ArtifactReferenced <$> o .: "reference"
      "verified" -> exactly ["tag", "reference", "value"] o >> ArtifactVerified <$> o .: "reference" <*> o .: "value"
      "unavailable" -> exactly ["tag", "reference"] o >> ArtifactUnavailable <$> o .: "reference"
      tag -> fail ("Artifact: unknown tag " <> T.unpack tag)

-- | Every field of @Coordination String String@ of the model.
data Coordination = Coordination
  { coordinationGeneration :: !Text,
    coordinationAuthority :: !Text,
    coordinationSlots :: !(Set Text),
    coordinationProfiles :: !(Map Text Profile),
    coordinationRequests :: !(Map Text Request),
    coordinationReservations :: !(Map Text Reservation),
    coordinationPreparations :: !(Map Text Prepared),
    coordinationRuns :: !(Map Text Text),
    coordinationSupervision :: !(Map Text Supervision),
    -- | The pending FIFO of each run, head first.
    coordinationDecisions :: !(Map Text [Decision]),
    coordinationCommands :: !(Map Text Receipt),
    coordinationCaptures :: !(Map Text Text),
    coordinationArtifacts :: !(Map Text Artifact)
  }
  deriving (Eq, Show)

-- | The state with the given generation and authority and no other entry.
emptyCoordination :: Text -> Text -> Coordination
emptyCoordination generation authority =
  Coordination generation authority Set.empty Map.empty Map.empty Map.empty Map.empty Map.empty
    Map.empty Map.empty Map.empty Map.empty Map.empty

instance ToJSON Coordination where
  toJSON s =
    object
      [ "generation" .= coordinationGeneration s,
        "authority" .= coordinationAuthority s,
        "slots" .= encodeSet (coordinationSlots s),
        "profiles" .= encodeMap toJSON (coordinationProfiles s),
        "requests" .= encodeMap toJSON (coordinationRequests s),
        "reservations" .= encodeMap toJSON (coordinationReservations s),
        "preparations" .= encodeMap toJSON (coordinationPreparations s),
        "runs" .= encodeMap String (coordinationRuns s),
        "supervision" .= encodeMap toJSON (coordinationSupervision s),
        "decisions" .= encodeMap toJSON (coordinationDecisions s),
        "commands" .= encodeMap toJSON (coordinationCommands s),
        "captures" .= encodeMap String (coordinationCaptures s),
        "artifacts" .= encodeMap toJSON (coordinationArtifacts s)
      ]

instance FromJSON Coordination where
  parseJSON = withObject "Coordination" $ \o -> do
    exactly
      [ "generation", "authority", "slots", "profiles", "requests", "reservations", "preparations",
        "runs", "supervision", "decisions", "commands", "captures", "artifacts" ]
      o
    Coordination
      <$> o .: "generation"
      <*> o .: "authority"
      <*> (o .: "slots" >>= decodeSet)
      <*> (o .: "profiles" >>= decodeMap parseJSON)
      <*> (o .: "requests" >>= decodeMap parseJSON)
      <*> (o .: "reservations" >>= decodeMap parseJSON)
      <*> (o .: "preparations" >>= decodeMap parseJSON)
      <*> (o .: "runs" >>= decodeMap parseJSON)
      <*> (o .: "supervision" >>= decodeMap parseJSON)
      <*> (o .: "decisions" >>= decodeMap parseJSON)
      <*> (o .: "commands" >>= decodeMap parseJSON)
      <*> (o .: "captures" >>= decodeMap parseJSON)
      <*> (o .: "artifacts" >>= decodeMap parseJSON)

-- | The evidence table. A fact holds exactly when the table lists it.
data Evidence = Evidence
  { evidenceLive :: ![Prepared],
    evidenceUnexpired :: ![Prepared],
    -- | Confirmed cleanups as (owner, lease).
    evidenceCleaned :: ![(Text, Reservation)],
    -- | Opened decisions as (run, key).
    evidenceOpened :: ![(Text, DecisionKey)],
    -- | Correlated resolutions as (run, key, command, resolution).
    evidenceResolutions :: ![(Text, DecisionKey, Text, Resolution)],
    -- | Verified contents as (reference, value).
    evidenceVerified :: ![(Text, Text)]
  }
  deriving (Eq, Show)

-- | The table with no evidence.
emptyEvidence :: Evidence
emptyEvidence = Evidence [] [] [] [] [] []

instance ToJSON Evidence where
  toJSON t =
    object
      [ "live" .= evidenceLive t,
        "unexpired" .= evidenceUnexpired t,
        "cleaned" .= [object ["owner" .= owner, "lease" .= lease] | (owner, lease) <- evidenceCleaned t],
        "opened" .= [object ["run" .= run, "key" .= key] | (run, key) <- evidenceOpened t],
        "resolutions"
          .= [ object ["run" .= run, "key" .= key, "command" .= command, "resolution" .= resolution]
               | (run, key, command, resolution) <- evidenceResolutions t
             ],
        "verified" .= [object ["reference" .= reference, "value" .= value] | (reference, value) <- evidenceVerified t]
      ]

instance FromJSON Evidence where
  parseJSON = withObject "Evidence" $ \o -> do
    exactly ["live", "unexpired", "cleaned", "opened", "resolutions", "verified"] o
    Evidence
      <$> o .: "live"
      <*> o .: "unexpired"
      <*> (o .: "cleaned" >>= mapM (withObject "cleaned" $ \c -> exactly ["owner", "lease"] c >> (,) <$> c .: "owner" <*> c .: "lease"))
      <*> (o .: "opened" >>= mapM (withObject "opened" $ \c -> exactly ["run", "key"] c >> (,) <$> c .: "run" <*> c .: "key"))
      <*> (o .: "resolutions" >>= mapM resolution)
      <*> (o .: "verified" >>= mapM (withObject "verified" $ \c -> exactly ["reference", "value"] c >> (,) <$> c .: "reference" <*> c .: "value"))
    where
      resolution = withObject "resolution" $ \c -> do
        exactly ["run", "key", "command", "resolution"] c
        (,,,) <$> c .: "run" <*> c .: "key" <*> c .: "command" <*> c .: "resolution"

-- | A tagged coordination transition with its arguments.
data Step
  = -- | id, request, profile, lease
    StepAdmit !Text !Request !Profile !Reservation
  | -- | command, client, preparation, revision, digest, prepared, request, profile
    StepApprove !Text !Text !Text !Text !Text !Prepared !Request !Profile
  | -- | run, key
    StepOpenDecision !Text !DecisionKey
  | -- | command, client, run, key, value
    StepAnswer !Text !Text !Text !DecisionKey !Text
  | -- | run, command, key, resolution
    StepResolve !Text !Text !DecisionKey !Resolution
  | -- | command, knowledge
    StepDelivery !Text !Delivery
  | -- | owner
    StepRelease !Text
  | -- | artifact, reference, value
    StepVerify !Text !Text !Text
  deriving (Eq, Show)

-- | One history entry: a transition, or an observation of an opaque event of a run.
data Entry
  = EntryStep !Step
  | EntryObservation !Text !Text
  deriving (Eq, Show)

instance ToJSON Entry where
  toJSON = \case
    EntryStep step -> case step of
      StepAdmit i r p l -> tagged "admit" ["id" .= i, "request" .= r, "profile" .= p, "lease" .= l]
      StepApprove command client preparation revision digest prepared r p ->
        tagged
          "approve"
          [ "command" .= command, "client" .= client, "preparation" .= preparation,
            "revision" .= revision, "digest" .= digest, "prepared" .= prepared, "request" .= r,
            "profile" .= p ]
      StepOpenDecision run key -> tagged "openDecision" ["run" .= run, "key" .= key]
      StepAnswer command client run key value ->
        tagged "answer" ["command" .= command, "client" .= client, "run" .= run, "key" .= key, "value" .= value]
      StepResolve run command key resolution ->
        tagged "resolve" ["run" .= run, "command" .= command, "key" .= key, "resolution" .= resolution]
      StepDelivery command knowledge -> tagged "delivery" ["command" .= command, "knowledge" .= knowledge]
      StepRelease owner -> tagged "release" ["owner" .= owner]
      StepVerify artifact reference value ->
        tagged "verify" ["artifact" .= artifact, "reference" .= reference, "value" .= value]
    EntryObservation run event -> tagged "observation" ["run" .= run, "event" .= event]

instance FromJSON Entry where
  parseJSON = withObject "Entry" $ \o ->
    tagOf o >>= \case
      "admit" -> do
        exactly ["tag", "id", "request", "profile", "lease"] o
        fmap EntryStep (StepAdmit <$> o .: "id" <*> o .: "request" <*> o .: "profile" <*> o .: "lease")
      "approve" -> do
        exactly ["tag", "command", "client", "preparation", "revision", "digest", "prepared", "request", "profile"] o
        fmap EntryStep $
          StepApprove <$> o .: "command" <*> o .: "client" <*> o .: "preparation" <*> o .: "revision"
            <*> o .: "digest" <*> o .: "prepared" <*> o .: "request" <*> o .: "profile"
      "openDecision" -> do
        exactly ["tag", "run", "key"] o
        fmap EntryStep (StepOpenDecision <$> o .: "run" <*> o .: "key")
      "answer" -> do
        exactly ["tag", "command", "client", "run", "key", "value"] o
        fmap EntryStep (StepAnswer <$> o .: "command" <*> o .: "client" <*> o .: "run" <*> o .: "key" <*> o .: "value")
      "resolve" -> do
        exactly ["tag", "run", "command", "key", "resolution"] o
        fmap EntryStep (StepResolve <$> o .: "run" <*> o .: "command" <*> o .: "key" <*> o .: "resolution")
      "delivery" -> do
        exactly ["tag", "command", "knowledge"] o
        fmap EntryStep (StepDelivery <$> o .: "command" <*> o .: "knowledge")
      "release" -> do
        exactly ["tag", "owner"] o
        fmap EntryStep (StepRelease <$> o .: "owner")
      "verify" -> do
        exactly ["tag", "artifact", "reference", "value"] o
        fmap EntryStep (StepVerify <$> o .: "artifact" <*> o .: "reference" <*> o .: "value")
      "observation" -> do
        exactly ["tag", "run", "event"] o
        EntryObservation <$> o .: "run" <*> o .: "event"
      tag -> fail ("Entry: unknown tag " <> T.unpack tag)

-- | One oracle request. The encoding adds the version field.
data Query = Query
  { queryState :: !Coordination,
    queryEvidence :: !Evidence,
    queryEntry :: !Entry
  }
  deriving (Eq, Show)

instance ToJSON Query where
  toJSON q =
    object
      [ "version" .= conformanceVersion,
        "state" .= queryState q,
        "evidence" .= queryEvidence q,
        "entry" .= queryEntry q
      ]

-- | The version is checked before any other field, as the oracle checks it.
instance FromJSON Query where
  parseJSON = withObject "Query" $ \o -> do
    given <- o .: "version"
    when (given /= conformanceVersion) (fail ("unknown version " <> T.unpack given))
    exactly ["version", "state", "evidence", "entry"] o
    Query <$> o .: "state" <*> o .: "evidence" <*> o .: "entry"

-- | The response of the oracle to one request.
data Response
  = -- | The entry is accepted, with the next state.
    ResponseAccepted !Coordination
  | -- | The model refuses the entry.
    ResponseRefused
  | -- | The request is not valid JSON, or the decoder of the oracle refuses it.
    ResponseError !Text
  deriving (Eq, Show)

instance ToJSON Response where
  toJSON = \case
    ResponseAccepted s -> object ["accepted" .= True, "state" .= s]
    ResponseRefused -> object ["accepted" .= False]
    ResponseError message -> object ["error" .= message]

instance FromJSON Response where
  parseJSON = withObject "Response" $ \o ->
    case KM.lookup "error" o of
      Just _ -> exactly ["error"] o >> ResponseError <$> o .: "error"
      Nothing ->
        o .: "accepted" >>= \case
          True -> exactly ["accepted", "state"] o >> ResponseAccepted <$> o .: "state"
          False -> exactly ["accepted"] o >> pure ResponseRefused

-- | The compact encoding of a value as one line, without the line break.
encodeLine :: ToJSON a => a -> BS.ByteString
encodeLine = BL.toStrict . encode

-- ---------------------------------------------------------------------------
-- The connection
-- ---------------------------------------------------------------------------

-- | One running oracle process. One request is in flight at a time.
data Oracle = Oracle
  { oracleTo :: !Handle,
    oracleFrom :: !Handle,
    oracleProcess :: !ProcessHandle,
    oraclePath :: !FilePath
  }

-- | A failure of the transport. It is not a conformance result, and a lane
-- stops at the first one.
data OracleError
  = -- | The binary is absent or not executable.
    OracleMissing !FilePath
  | -- | The oracle wrote no response within the reply timeout.
    OracleTimeout !FilePath
  | -- | The oracle closed its output or the pipe failed.
    OracleClosed !FilePath !String
  | -- | The oracle wrote a line that is not a response of the encoding.
    OracleUnreadable !FilePath !BS.ByteString !String
  deriving (Show)

instance Exception OracleError

-- | The oracle that @lake --dir bisim build manager-oracle@ writes, relative
-- to the root of the repository.
defaultOraclePath :: FilePath
defaultOraclePath = "bisim/.lake/build/bin/manager-oracle"

-- | The path of the oracle: the given path, else the environment variable
-- @ORACLE@, else 'defaultOraclePath'.
resolveOraclePath :: Maybe FilePath -> IO FilePath
resolveOraclePath (Just path) = pure path
resolveOraclePath Nothing = fromMaybe defaultOraclePath <$> lookupEnv "ORACLE"

-- | The longest wait for one response line. The oracle answers one request in
-- milliseconds, so the limit detects only an oracle that has stopped.
replySeconds :: Int
replySeconds = 60

-- | Run an action with one oracle process. A missing or non-executable binary
-- throws 'OracleMissing' before any process starts. The process ends when the
-- action ends: its input is closed and the process is awaited.
withOracle :: FilePath -> (Oracle -> IO a) -> IO a
withOracle path action = do
  present <- doesFileExist path
  runnable <- if present then executable <$> getPermissions path else pure False
  unless runnable (throwIO (OracleMissing path))
  bracket start stop action
  where
    start = do
      (Just to, Just from, _, handle) <-
        createProcess (proc path []) {std_in = CreatePipe, std_out = CreatePipe, std_err = Inherit}
      mapM_ (`hSetBinaryMode` True) [to, from]
      hSetBuffering to (BlockBuffering Nothing)
      pure (Oracle to from handle path)
    stop oracle = do
      closed <- try (hClose (oracleTo oracle)) :: IO (Either IOException ())
      case closed of
        Right () -> pure ()
        Left _ -> terminateProcess (oracleProcess oracle)
      _ <- waitForProcess (oracleProcess oracle)
      pure ()

-- | Send one line and read the response line, both without the line break.
exchangeLine :: Oracle -> BS.ByteString -> IO BS.ByteString
exchangeLine oracle line = do
  sent <- try (BS.hPut (oracleTo oracle) (line <> "\n") >> hFlush (oracleTo oracle))
  case sent of
    Left e -> throwIO (OracleClosed (oraclePath oracle) (show (e :: IOException)))
    Right () -> pure ()
  reply <- try (timeout (replySeconds * 1000000) (BSC.hGetLine (oracleFrom oracle)))
  case reply of
    Left e -> throwIO (OracleClosed (oraclePath oracle) (show (e :: IOException)))
    Right Nothing -> throwIO (OracleTimeout (oraclePath oracle))
    Right (Just bytes) -> pure (BSC.dropWhileEnd (== '\r') bytes)

-- | Submit one request and decode the response. A response line outside the
-- encoding throws 'OracleUnreadable'.
submit :: Oracle -> Query -> IO (BS.ByteString, Response)
submit oracle query = do
  reply <- exchangeLine oracle (encodeLine query)
  case eitherDecodeStrict' reply of
    Left message -> throwIO (OracleUnreadable (oraclePath oracle) reply message)
    Right response -> pure (reply, response)
