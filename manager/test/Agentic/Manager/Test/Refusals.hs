{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The refused variants of the refusals lane of @manager-conformance-check@.
--
-- 'deriveVariants' derives refused variants from one accepted entry of the
-- history of a retained root. Each variant names a state, the entries that
-- must be accepted from it, and the entry that the oracle must refuse. A
-- variant of a class with an implementation guard also names the probes of
-- that guard. 'runProbe' runs a probe: a pure probe calls the guard of the
-- manager on inputs from the history, and a store probe calls the guard of
-- the manager inside a writable transaction on the private copy of the
-- retained root. That transaction always rolls back, so the copy keeps the
-- rows that the manager committed. @bisim/manager/README.md@ documents each
-- class and each guard.
module Agentic.Manager.Test.Refusals
  ( VariantClass (..),
    className,
    classGuard,
    Visit (..),
    Variant (..),
    Probe (..),
    AdmissionExpectation (..),
    Stale (..),
    deriveVariants,
    runProbe,
  )
where

import Agentic.Manager.Admission.Policy (Candidate (..), Held (..), Resource (..), oldestEligible)
import Agentic.Manager.Protocol.Command (CommandFailure (DecisionNotHead, StaleRevision))
import qualified Agentic.Manager.Protocol.Preparation as P
import Agentic.Manager.State (RunAssociation (..), decisionHeadIds, decisionHeadRefusal, decisionQueueIds)
import Agentic.Manager.Store (CoordinationStore, execute, query, refuseTransaction, runRead, runTransaction)
import Agentic.Manager.Test.Conformance (HistoryItem (..))
import Agentic.Manager.Test.Oracle
import Agentic.Runtime (RunId (..))
import Control.Exception (Exception, throwIO, try)
import Control.Monad (forM_)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (eitherDecodeStrict', object, (.=))
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Classes
-- ---------------------------------------------------------------------------

data VariantClass
  = -- | An answer to a decision that is not the head of its pending FIFO.
    AnswerNotHead
  | -- | An answer while a command with uncertain delivery reserves the head.
    AnswerUncertain
  | -- | A second approval of a consumed preparation.
    ApproveConsumed
  | -- | An approval of a review whose request has a newer revision.
    ApproveStaleRequest
  | -- | An approval of a review whose profile has a newer revision.
    ApproveStaleProfile
  | -- | An admission whose keys overlap the keys of a held reservation.
    AdmitKeyOverlap
  | -- | An admission at the slot of a held reservation.
    AdmitSlotOverlap
  deriving (Eq, Ord, Show, Enum, Bounded)

className :: VariantClass -> Text
className = \case
  AnswerNotHead -> "answer-not-head"
  AnswerUncertain -> "answer-uncertain"
  ApproveConsumed -> "approve-consumed"
  ApproveStaleRequest -> "approve-stale-request-revision"
  ApproveStaleProfile -> "approve-stale-profile-revision"
  AdmitKeyOverlap -> "admit-key-overlap"
  AdmitSlotOverlap -> "admit-slot-overlap"

-- | The implementation guard of a class, or the reason that the class is
-- compared with the oracle only.
classGuard :: VariantClass -> Either Text Text
classGuard = \case
  AnswerNotHead -> Right decisionGuard
  AnswerUncertain -> Right decisionGuard
  ApproveConsumed ->
    Left
      "the stored preparation check of Approval.acceptApproval runs inside the start command of the original live preparation, which only a worker holds"
  ApproveStaleRequest -> Right approvalGuard
  ApproveStaleProfile -> Right approvalGuard
  AdmitKeyOverlap -> Right admissionGuard
  AdmitSlotOverlap -> Right admissionGuard
  where
    decisionGuard = "State.decisionQueueIds, State.decisionHeadIds and State.decisionHeadRefusal on the store copy"
    approvalGuard =
      "the selector comparison of Approval.acceptApproval (Protocol.Preparation.approvalSelectors) between the stored preparation of the store copy and the submitted selectors"
    admissionGuard = "Admission.Policy.oldestEligible over the held reservations of the history state"

-- ---------------------------------------------------------------------------
-- Variants
-- ---------------------------------------------------------------------------

-- | One accepted entry of the history fold: its item index, the state before
-- it, the entry, the state after it, and the items that follow it.
data Visit = Visit
  { visitIndex :: !Int,
    visitBefore :: !Coordination,
    visitEntry :: !Entry,
    visitAfter :: !Coordination,
    visitRest :: ![HistoryItem]
  }

-- | A refused variant. From 'variantState', the oracle must accept each
-- entry of 'variantPrefix' in order and must then refuse 'variantEntry'.
-- When 'variantControl' is present, the oracle must accept that entry at
-- that state, which shows that the refusal comes from the variation. Every
-- probe must meet its expectation.
data Variant = Variant
  { variantClass :: !VariantClass,
    variantLabel :: !Text,
    variantState :: !Coordination,
    variantPrefix :: ![Entry],
    variantEntry :: !Entry,
    variantControl :: !(Maybe (Coordination, Entry)),
    variantProbes :: ![Probe]
  }

-- | The selector that a stale approval body changes.
data Stale = StaleRequest | StaleProfile
  deriving (Eq, Show)

data AdmissionExpectation
  = -- | The policy chooses the candidate at some slot.
    ChoosesCandidate
  | -- | The policy chooses nothing.
    ChoosesNothing
  | -- | The policy does not choose the candidate at this slot.
    AvoidsSlot !Int
  deriving (Eq, Show)

data Probe
  = -- | The pending FIFO of a run as (decision, stored state), head first,
    -- the addressed decision, and the expected refusal of the guard.
    DecisionProbe !Text ![(Text, Text)] !Text !(Maybe CommandFailure)
  | -- | The admission policy over the reservations of a state with the
    -- extra held leases, for one request, its profile and the expectation.
    AdmissionProbe !Coordination ![Reservation] !Text !Request !Profile !AdmissionExpectation
  | -- | The selector comparison of an approve command and its preparation.
    -- With a stale selector the comparison must refuse, and without one it
    -- must agree.
    ApprovalProbe !Text !Text !(Maybe Stale)

-- | The suffixes that make a fresh identity or a newer revision. They keep
-- the characters of a valid identity.
fresh :: Text -> Text -> Text
fresh base suffix = base <> "_" <> suffix

-- | The refused variants of one accepted entry.
deriveVariants :: Visit -> [Variant]
deriveVariants visit@Visit {..} = case visitEntry of
  EntryStep (StepAnswer command client run key value) -> answerVariants visit command client run key value
  EntryStep (StepApprove command client preparation revision digest prepared request profile) ->
    approveVariants visit command client preparation revision digest prepared request profile
  EntryStep (StepAdmit ident request profile lease) -> admitVariants visit ident request profile lease
  _ -> []

answerVariants :: Visit -> Text -> Text -> Text -> DecisionKey -> Text -> [Variant]
answerVariants Visit {..} command client run key value =
  notHead <> [uncertain]
  where
    fifo = fifoOf visitBefore
    fifoOf s = Map.findWithDefault [] run (coordinationDecisions s)
    queueOf ds = [(keyId (decisionKey d), maybe "pending" (const "submitting") (decisionCommand d)) | d <- ds]
    label suffix = command <> "/" <> suffix
    -- The second decision of the FIFO, else the next decision of the run
    -- that the history opens later, after an opening of that decision.
    target = case drop 1 fifo of
      second : _ -> Just ([], decisionKey second, fifo)
      [] ->
        listToMaybe
          [ ([EntryStep (StepOpenDecision run later)], later, fifo <> [Decision later Nothing])
            | Submit _ (EntryStep (StepOpenDecision opened later)) <- visitRest,
              opened == run,
              keyId later `notElem` map (keyId . decisionKey) fifo
          ]
    notHead =
      [ Variant
          { variantClass = AnswerNotHead,
            variantLabel = label ("not-head/" <> keyId other),
            variantState = visitBefore,
            variantPrefix = prefix,
            variantEntry = EntryStep (StepAnswer (fresh command "not_head") client run other value),
            variantControl = Nothing,
            variantProbes =
              [ DecisionProbe run (queueOf queue) (keyId other) (Just DecisionNotHead),
                DecisionProbe run (queueOf queue) (keyId key) Nothing
              ]
          }
        | Just (prefix, other, queue) <- [target]
      ]
    uncertain =
      Variant
        { variantClass = AnswerUncertain,
          variantLabel = label "uncertain",
          variantState = visitAfter,
          variantPrefix = [EntryStep (StepDelivery command DeliveryUncertain)],
          variantEntry = EntryStep (StepAnswer (fresh command "while_uncertain") client run key value),
          variantControl = Nothing,
          variantProbes =
            [ DecisionProbe run (queueOf (fifoOf visitAfter)) (keyId key) (Just StaleRevision),
              DecisionProbe run (queueOf fifo) (keyId key) Nothing
            ]
        }

approveVariants :: Visit -> Text -> Text -> Text -> Text -> Text -> Prepared -> Request -> Profile -> [Variant]
approveVariants Visit {..} command client preparation revision digest prepared request profile =
  [ Variant
      { variantClass = ApproveConsumed,
        variantLabel = command <> "/consumed",
        variantState = visitAfter,
        variantPrefix = [],
        variantEntry = EntryStep (StepApprove (fresh command "second") client preparation revision digest prepared request profile),
        variantControl = Nothing,
        variantProbes = []
      },
    Variant
      { variantClass = ApproveStaleRequest,
        variantLabel = command <> "/stale-request",
        variantState =
          visitBefore {coordinationRequests = Map.insert (preparedRequest prepared) staleRequest (coordinationRequests visitBefore)},
        variantPrefix = [],
        variantEntry = EntryStep (StepApprove command client preparation revision digest prepared staleRequest profile),
        variantControl = Nothing,
        variantProbes = [ApprovalProbe command preparation (Just StaleRequest), ApprovalProbe command preparation Nothing]
      },
    Variant
      { variantClass = ApproveStaleProfile,
        variantLabel = command <> "/stale-profile",
        variantState =
          visitBefore {coordinationProfiles = Map.insert (preparedProfile prepared) staleProfile (coordinationProfiles visitBefore)},
        variantPrefix = [],
        variantEntry = EntryStep (StepApprove command client preparation revision digest prepared request staleProfile),
        variantControl = Nothing,
        variantProbes = [ApprovalProbe command preparation (Just StaleProfile), ApprovalProbe command preparation Nothing]
      }
  ]
  where
    staleRequest = request {requestRevision = fresh (requestRevision request) "stale"}
    staleProfile = profile {profileRevision = fresh (profileRevision profile) "stale"}

-- | The owner of the held reservation that an admission variant adds. No
-- request of the store has this identity.
holderOwner :: Text
holderOwner = "conformance-holder"

admitVariants :: Visit -> Text -> Request -> Profile -> Reservation -> [Variant]
admitVariants Visit {..} ident request profile lease =
  [ Variant
      { variantClass = AdmitKeyOverlap,
        variantLabel = ident <> "/key-overlap",
        variantState = keyedState {coordinationReservations = Map.insert holderOwner keyHolder (coordinationReservations keyedState)},
        variantPrefix = [],
        variantEntry = keyedEntry,
        variantControl = if keyed == reservationExclusive lease then Nothing else Just (keyedState, keyedEntry),
        variantProbes =
          [ AdmissionProbe keyedState [] ident request keyedProfile ChoosesCandidate,
            AdmissionProbe keyedState [keyHolder] ident request keyedProfile ChoosesNothing
          ]
      }
    | Just holderSlot <- [freeSlot]
    , let keyHolder = Reservation holderSlot keyed
  ]
    <> [ Variant
           { variantClass = AdmitSlotOverlap,
             variantLabel = ident <> "/slot-overlap",
             variantState = visitBefore {coordinationReservations = Map.insert holderOwner slotHolder (coordinationReservations visitBefore)},
             variantPrefix = [],
             variantEntry = EntryStep (StepAdmit ident request profile lease),
             variantControl = Nothing,
             variantProbes =
               [ AdmissionProbe visitBefore [] ident request profile ChoosesCandidate,
                 AdmissionProbe visitBefore [slotHolder] ident request profile (AvoidsSlot slot)
               ]
           }
         | Just slot <- [slotNumber (reservationSlot lease)]
       ]
  where
    slotHolder = Reservation (reservationSlot lease) Set.empty
    -- A lease of a released reservation has no stored key. The key variant
    -- then gives the lease and the profile the unclassified cohort, which a
    -- profile without an operator key has, and requires that the oracle
    -- still accepts that admission without the holder.
    keyed = if Set.null (reservationExclusive lease) then Set.singleton "unclassified" else reservationExclusive lease
    keyedProfile = profile {profileResources = keyed}
    keyedState = visitBefore {coordinationProfiles = Map.insert (requestProfile request) keyedProfile (coordinationProfiles visitBefore)}
    keyedEntry = EntryStep (StepAdmit ident request keyedProfile lease {reservationExclusive = keyed})
    used = Set.fromList (reservationSlot lease : map reservationSlot (Map.elems (coordinationReservations visitBefore)))
    freeSlot =
      listToMaybe
        [ name
          | (_, name) <- Map.toAscList (Map.fromList [(n, name) | name <- Set.toList (coordinationSlots visitBefore), Just n <- [slotNumber name]]),
            name `Set.notMember` used
        ]

-- | The slot @slot-<n>@ is the policy slot @n@.
slotNumber :: Text -> Maybe Int
slotNumber name = T.stripPrefix "slot-" name >>= readMaybe . T.unpack

-- | The key @key:<k>@ is the operator key @k@, and @unclassified@ is the
-- unclassified cohort.
resourceOf :: Text -> Either Text Resource
resourceOf name
  | name == "unclassified" = Right UnclassifiedResource
  | Just key <- T.stripPrefix "key:" name = Right (OperatorResource key)
  | otherwise = Left ("the resource " <> name <> " has no policy resource")

-- ---------------------------------------------------------------------------
-- Probes
-- ---------------------------------------------------------------------------

-- | The observation of a store probe. The probe throws it to end its
-- transaction, so the transaction rolls back.
data DecisionObservation = DecisionObservation ![Text] ![Text] !Text
  deriving (Show)

instance Exception DecisionObservation

-- | Run one probe. The result is 'Right' with a description when the guard
-- meets the expectation, 'Left' with the disagreement otherwise. An approval
-- probe is 'Nothing' when the root holds no submitted selectors of the
-- command, because the guard then has nothing to compare.
runProbe :: CoordinationStore -> Map.Map Text P.ApprovalRequest -> Probe -> IO (Maybe (Either Text Text))
runProbe store selectors = \case
  DecisionProbe run queue target expected -> Just <$> decisionProbe store run queue target expected
  AdmissionProbe state extra ident request profile expected -> pure (Just (admissionProbe state extra ident request profile expected))
  ApprovalProbe command preparation stale ->
    storedPreparation store preparation >>= \case
      Left problem -> pure (Just (Left problem))
      Right prepared -> do
        submitted <- maybe (digestSelectors store command prepared) (pure . Just) (Map.lookup command selectors)
        pure (fmap (\given -> approvalProbe prepared given stale) submitted)

-- | Write the pending FIFO of the run into the store copy, read the queue
-- and the heads with the guards of the manager, and roll the transaction
-- back. Every other decision of the run is resolved in the written rows.
decisionProbe :: CoordinationStore -> Text -> [(Text, Text)] -> Text -> Maybe CommandFailure -> IO (Either Text Text)
decisionProbe store run queue target expected = do
  observed <- try $ runTransaction store $ do
    execute "UPDATE decisions SET state='resolved' WHERE run_id=?" [SQL.SQLText run]
    forM_ queue $ \(ident, state) -> execute "UPDATE decisions SET state=? WHERE id=? AND run_id=?" [SQL.SQLText state, SQL.SQLText ident, SQL.SQLText run]
    -- The queue query reads only the run of the association.
    ids <- decisionQueueIds 64 (RunAssociation run "" "" (RunId ""))
    profiles <- query "SELECT profile_id FROM runs WHERE id=?" [SQL.SQLText run]
    heads <- decisionHeadIds 1024 [p | [SQL.SQLText p] <- profiles]
    states <- query "SELECT state FROM decisions WHERE id=?" [SQL.SQLText target]
    refuseTransaction (DecisionObservation ids heads (case states of [[SQL.SQLText s]] -> s; _ -> ""))
  case observed of
    Right () -> throwIO (userError "manager-conformance: a decision probe committed")
    Left (DecisionObservation ids heads state) -> do
      let refusal = decisionHeadRefusal ids target state
          isHead = target `elem` heads
          problems =
            [ "decisionQueueIds reads " <> T.intercalate "," ids <> ", not the FIFO " <> T.intercalate "," (map fst queue) | ids /= map fst queue ]
              <> [ "the addressed decision " <> target <> " has no stored row" | T.null state ]
              <> [ "decisionHeadRefusal gives " <> tshow refusal <> ", not " <> tshow expected | refusal /= expected ]
              <> [ "decisionHeadIds " <> (if isHead then "names" else "does not name") <> " " <> target | isHead /= (expected /= Just DecisionNotHead) ]
      pure $ case problems of
        [] -> Right ("decision " <> target <> " " <> maybe "admitted" tshow refusal)
        _ -> Left (T.intercalate "; " problems)

admissionProbe :: Coordination -> [Reservation] -> Text -> Request -> Profile -> AdmissionExpectation -> Either Text Text
admissionProbe state extra ident request profile expected = do
  held <- traverse heldOf (Map.elems (coordinationReservations state) <> extra)
  resources <- Set.fromList <$> traverse resourceOf (Set.toList (profileResources profile))
  let inputs = requestInputs request
      candidate =
        Candidate
          { candidateRequest = ident,
            candidateOrdinal = maybe 0 toInteger (requestQueueOrdinal request),
            candidateEnabled = profileEnabled profile && requestProfileRevision request == profileRevision profile,
            candidateReady =
              readinessRequired inputs `Set.isSubsetOf` Map.keysSet (readinessSupplied inputs) && Set.null (readinessInvalid inputs),
            candidateResources = resources
          }
      choice = oldestEligible (Set.size (coordinationSlots state)) held [candidate]
      chosen = fmap (\(c, slot) -> (candidateRequest c, slot)) choice
      met = case expected of
        ChoosesCandidate -> fmap fst chosen == Just ident
        ChoosesNothing -> chosen == Nothing
        AvoidsSlot slot -> chosen /= Just (ident, slot)
  if met
    then Right ("oldestEligible chooses " <> tshow chosen)
    else Left ("oldestEligible chooses " <> tshow chosen <> ", which does not meet " <> tshow expected)
  where
    heldOf (Reservation slot exclusive) = do
      n <- maybe (Left ("the slot " <> slot <> " has no policy slot")) Right (slotNumber slot)
      Held n . Set.fromList <$> traverse resourceOf (Set.toList exclusive)

-- | The submitted selectors of an approve command on a root without a
-- manager log. The store keeps the SHA-256 of the approval body, not the
-- body. When the approve body of the stored selectors, in the compact
-- encoding with its fields in increasing order of their names, has that
-- SHA-256, the submitted body is that body, and the approval decoder
-- 'P.decodeApproval' of the manager reads its selectors. Otherwise the root
-- holds no submitted selectors of the command.
digestSelectors :: CoordinationStore -> Text -> P.Preparation -> IO (Maybe P.ApprovalRequest)
digestSelectors store command prepared = do
  stored <-
    runRead store $
      map (\case [SQL.SQLText sha] -> Just sha; _ -> Nothing)
        <$> query "SELECT lower(hex(body_sha256)) FROM commands WHERE id=? AND operation='approve'" [SQL.SQLText command]
  let P.ApprovalRequest digest request profile descriptor generation = P.approvalSelectors prepared
      body =
        encodeLine $
          object
            [ "operation" .= ("approve" :: Text),
              "reviewDigest" .= digest,
              "requestRevision" .= request,
              "profileRevision" .= profile,
              "descriptorRevision" .= descriptor,
              "processGeneration" .= generation
            ]
  pure $ case stored of
    [Just sha] | sha == T.pack (show (hash body :: Digest SHA256)) -> either (const Nothing) Just (P.decodeApproval body)
    _ -> Nothing

-- | Compare the submitted selectors, or a stale form of them, with the
-- selectors of the stored preparation of the store copy.
approvalProbe :: P.Preparation -> P.ApprovalRequest -> Maybe Stale -> Either Text Text
approvalProbe prepared submitted stale = case (stale, agrees) of
  (Nothing, True) -> Right "the submitted selectors agree with the stored preparation"
  (Just _, False) -> Right "the stale selectors differ from the stored preparation"
  (Nothing, False) -> Left ("the submitted selectors " <> tshow submitted <> " differ from the stored preparation " <> tshow (P.approvalSelectors prepared))
  (Just _, True) -> Left ("the stale selectors " <> tshow given <> " agree with the stored preparation")
  where
    P.ApprovalRequest digest request profile descriptor generation = submitted
    given = case stale of
      Nothing -> submitted
      Just StaleRequest -> P.ApprovalRequest digest (fresh request "stale") profile descriptor generation
      Just StaleProfile -> P.ApprovalRequest digest request (fresh profile "stale") descriptor generation
    agrees = given == P.approvalSelectors prepared

-- | The public preparation of a stored row, read as the preparation
-- projection of "Agentic.Manager.Approval" reads it, without its
-- authorization of a credential.
storedPreparation :: CoordinationStore -> Text -> IO (Either Text P.Preparation)
storedPreparation store ident =
  runRead store $
    decode
      <$> query
        "SELECT p.id,p.revision,p.request_id,p.request_revision,r.profile_id,p.profile_revision,r.descriptor_revision,p.state,p.expires_at,p.review_digest,p.process_generation,p.review,coalesce(p.reason,'') FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=?"
        [SQL.SQLText ident]
  where
    decode rows = case rows of
      [[SQL.SQLText a, SQL.SQLText b, SQL.SQLText c, SQL.SQLText d, SQL.SQLText e, SQL.SQLText f, SQL.SQLText g, SQL.SQLText h, SQL.SQLText i, SQL.SQLText j, SQL.SQLText k, SQL.SQLBlob body, SQL.SQLText reason]] ->
        case eitherDecodeStrict' body of
          Right review -> Right (P.Preparation a b c d e f g h i j k review (if T.null reason then Nothing else Just reason))
          Left failure -> Left ("the stored review of " <> ident <> " does not decode: " <> T.pack failure)
      _ -> Left ("no single stored preparation " <> ident)

tshow :: Show a => a -> Text
tshow = T.pack . show
