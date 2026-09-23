{-# LANGUAGE OverloadedStrings #-}

-- | Durable Runtime observations. Stored associations never grant worker authority.
module Agentic.Manager.State
  ( RunAssociation (..), ingestAcceptedStart, ingestRuntimeEnvelope, restoreRunProjection, observeRetainedTerminal,
    submitRunControl, submitDecisionControl, dispatchRunControl, dispatchDecisionControl, replayControl,
    resolveRun, resolveDecision, readControlSurface, readClosedControlSurface, readDecision, readDecisionHeads,
    withControlSurface, withClosedControlSurface, withDecision, decisionInView,
    authorizeObservation, requireProjection, withProfileProjection, withProfileProjectionSource,
    ProjectionCut, captureProjectionCut, restoreProjectionCut, publicRecoveryOptionValue
  ) where

import Agentic.Manager.Admission (AcceptedStart, acceptedStartRun, consumeAcceptedStart, acceptedControlContext, acceptControlCommand, acceptAndDeliverControlCommand, observeAcceptedStart)
import Agentic.Manager.Authorization
import qualified Agentic.Manager.Commands as Commands
import qualified Agentic.Manager.Protocol.Command as Command
import Agentic.Manager.Protocol.Json (decodeStrictValue, representableEditorSchema)
import Agentic.Manager.Profile (ConfigurationLimits, publicId, publicRevision)
import Agentic.Manager.Store
import Agentic.Manager.Worker (workerEventBytes, workerEventEnvelope, WorkerObservation (..), WorkerPhase (..))
import Agentic.Runtime
import Control.DeepSeq (NFData (rnf))
import Control.Exception (throwIO, bracket)
import Control.Monad (unless, when, forM, forM_, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), ToJSON, FromJSON, encode, object, (.=), toJSON, fromJSON, Result (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL

-- | Trusted observation address, not an execution or signalling capability.
data RunAssociation = RunAssociation
  { associationRun :: !Text, associationProfile :: !Text,
    associationRoot :: !Text, associationNative :: !RunId
  } deriving (Eq, Show)

-- | The original Worker retains its head until this durable callback returns.
-- Exceptions, including StoreBusy, retain the exact input for explicit retry.
ingestAcceptedStart :: AcceptedStart -> IO Bool
ingestAcceptedStart accepted = consumeAcceptedStart accepted $ \store profile prepared event -> do
  let association = RunAssociation (acceptedStartRun accepted) profile
        (preparedRootIdentity prepared) (preparedRunId prepared)
  void (ingestValidated store association (workerEventBytes event) (workerEventEnvelope event))

-- | Reconcile original wire evidence against a trusted stored association.
-- This operation cannot start, control, or acquire a worker.
ingestRuntimeEnvelope :: CoordinationStore -> RunAssociation -> BS.ByteString -> IO Bool
ingestRuntimeEnvelope store association bytes = do
  envelope <- decodeEvidence bytes
  ingestValidated store association bytes envelope

ingestValidated :: CoordinationStore -> RunAssociation -> BS.ByteString -> Envelope -> IO Bool
ingestValidated store association bytes envelope = withStoreReader store $ do
  decoded <- decodeEvidence bytes
  unless (decoded == envelope && envelopeRunId envelope == associationNative association) (throwIO StoreIntegrity)
  old <- restoreProjection store association
  let before = maybe (initialRunSnapshot (associationNative association)) checkpointSnapshot old
      sequenceKey = sequenceText envelope
  duplicate <- runRead store $ do
    checkAssociation association
    rows <- query "SELECT envelope_digest,length(envelope) FROM ingestions WHERE run_id=? AND sequence=?"
      [text (associationRun association), text sequenceKey]
    case rows of
      [[SQL.SQLText digest, SQL.SQLInteger size]] -> pure (Just (digest,size))
      [] -> pure Nothing
      _ -> refuseTransaction StoreIntegrity
  case duplicate of
    Just (digest,size) -> do
      unless (digest == digestOf bytes && size == fromIntegral (BS.length bytes)) (throwIO StoreIntegrity)
      original <- readEnvelope store association sequenceKey
      unless (original == bytes) (throwIO StoreIntegrity)
      pure False
    Nothing -> do
      empty <- valid (captureSnapshotCheckpoint (associationNative association) [])
      next <- valid (appendSnapshotCheckpoint (maybe empty id old) [envelope])
      let after = checkpointSnapshot next
          boundary = projectionBoundary after
          expected = projectionBoundary before
          revision = "runtime_" <> sequenceKey
      runTransaction store $ do
        checkAssociation association
        actual <- projectionRow association
        unless (actual == expected) (refuseTransaction StoreBusy)
        checkEvidenceBound association (BS.length bytes)
        execute "INSERT INTO ingestions(run_id,sequence,envelope_digest,envelope) VALUES (?,?,?,?)"
          [text (associationRun association), text sequenceKey, text (digestOf bytes), SQL.SQLBlob bytes]
        requestEvents <- if BS.null expected then associateRequest association else pure []
        observations <- observeChanges association revision sequenceKey before after
        controls <- observeControls association revision envelope before after
        execute "UPDATE runs SET runtime_snapshot=?,snapshot_version=1,revision=?,terminal_observed=? WHERE id=?"
          [SQL.SQLBlob boundary, text revision, SQL.SQLInteger (if snapshotRunStatus after `elem` [RunSucceeded,RunFailedStatus,RunCancelledStatus] then 1 else 0), text (associationRun association)]
        pure (True, Invalidation "run.changed" (runURI association <> "/snapshot") revision : requestEvents <> observations <> controls)

-- | Restore one immutable, fixed sequence-zero prefix using bounded reads.
-- No read transaction spans the prefix or an observer's lifetime. Concurrent
-- appends cannot change an earlier prefix. The shared checkpoint enforces 64MiB.
-- ponytail: full prefix replay per ingestion, cache validated checkpoints if throughput requires it.
restoreRunProjection :: CoordinationStore -> RunAssociation -> IO (Maybe SnapshotCheckpoint)
restoreRunProjection store association = withStoreReader store (restoreProjection store association)

-- | One charged projection and response under current profile authority. Reader
-- admission precedes the configuration loan, which remains held through response.
withProfileProjection :: CoordinationStore -> CredentialProof -> RunAssociation -> (AuthorizedView -> RunSnapshot -> IO a) -> IO a
withProfileProjection store proof association respond =
  withProfileProjectionSource store proof association $ \view _ materialize -> materialize >>= respond view

-- | Delayed replay under the original reader and response loans. A page owner
-- can reserve capacity before invoking it. Escaped actions refuse before replay.
withProfileProjectionSource :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> ConfigurationLimits -> IO RunSnapshot -> IO a) -> IO a
withProfileProjectionSource store proof association action =
  withAuthorizedResponseLimits store proof (associationProfile association) [Command.Observe] $ \view limits ->
    action view limits $ do
      revalidateAuthorizedView view >>= either throwIO pure
      runRead store (authorizeObservation proof association)
      snapshot <- borrowedProjection store association
      revalidateAuthorizedView view >>= either throwIO pure
      pure snapshot

borrowedProjection :: CoordinationStore -> RunAssociation -> IO RunSnapshot
borrowedProjection store association = restoreProjection store association
  >>= maybe (throwIO Command.ResourceUnavailable) (pure . checkpointSnapshot)

-- | Record a newly proved terminal fact from an existing immutable Runtime prefix.
-- This grants neither cleanup nor execution authority and does not change ordinary reads.
observeRetainedTerminal :: CoordinationStore -> RunAssociation -> IO Bool
observeRetainedTerminal store association = withStoreReader store $ do
  expected <- runRead store (checkAssociation association >> projectionRow association)
  checkpoint <- restoreProjection store association
  case checkpoint of
    Just restored | snapshotRunStatus(checkpointSnapshot restored) `elem` [RunSucceeded,RunFailedStatus,RunCancelledStatus] ->
      runTransaction store $ do
        checkAssociation association
        actual <- projectionRow association
        unless (actual==expected && actual==projectionBoundary(checkpointSnapshot restored)) (refuseTransaction StoreBusy)
        rows <- query "SELECT terminal_observed FROM runs WHERE id=?" [text(associationRun association)]
        case rows of
          [[SQL.SQLInteger 1]] -> pure(False,[])
          [[SQL.SQLInteger 0]] -> do
            execute "UPDATE runs SET terminal_observed=1 WHERE id=?" [text(associationRun association)]
            generation <- transactionGeneration
            pure(True,[Invalidation "service.changed" "/v1/capabilities" generation])
          _ -> refuseTransaction StoreIntegrity
    _ -> pure False

-- | One immutable ingestion-prefix boundary, without observation or execution
-- authority. The caller keeps its original Store reader loan while replaying it.
data ProjectionCut = ProjectionCut !RunAssociation !BS.ByteString !(Maybe Text)

instance NFData ProjectionCut where
  rnf (ProjectionCut association boundary lastKey) = rnf
    (associationRun association, associationProfile association, associationRoot association,
     runIdText (associationNative association), boundary, lastKey)

captureProjectionCut :: RunAssociation -> Transaction ProjectionCut
captureProjectionCut association = do
  checkAssociation association
  boundary <- projectionRow association
  checkEvidenceBound association 0
  rows <- query "SELECT sequence FROM ingestions WHERE run_id=? ORDER BY length(sequence) DESC,sequence DESC LIMIT 1"
    [text (associationRun association)]
  lastKey <- case rows of
    [] -> pure Nothing
    [[SQL.SQLText key]] -> pure (Just key)
    _ -> refuseTransaction StoreIntegrity
  pure (ProjectionCut association boundary lastKey)

restoreProjection :: CoordinationStore -> RunAssociation -> IO (Maybe SnapshotCheckpoint)
restoreProjection store association =
  runRead store (captureProjectionCut association) >>= restoreProjectionCut store

restoreProjectionCut :: CoordinationStore -> ProjectionCut -> IO (Maybe SnapshotCheckpoint)
restoreProjectionCut store (ProjectionCut association boundary lastRow) = do
  empty <- valid (captureSnapshotCheckpoint (associationNative association) [])
  case lastRow of
    Nothing -> do
      unless (boundary == BS.empty) (throwIO StoreIntegrity)
      pure Nothing
    Just lastKey -> do
      checkpoint <- loop empty "0" lastKey
      unless (projectionBoundary (checkpointSnapshot checkpoint) == boundary) (throwIO StoreIntegrity)
      pure (Just checkpoint)
  where
    loop checkpoint key lastKey = do
      bytes <- readEnvelope store association key
      envelope <- decodeEvidence bytes
      unless (sequenceText envelope == key) (throwIO StoreIntegrity)
      next <- valid (appendSnapshotCheckpoint checkpoint [envelope])
      if key == lastKey then pure next else do
        let number = sequenceNumber (envelopeSequence envelope)
        when (number == maxBound) (throwIO StoreIntegrity)
        loop next (T.pack (show (number + 1))) lastKey

-- Original records can reach 1MiB plus LF. Read slices, not a row exceeding Store's
-- aggregate 1MiB result budget. Schema immutability fences the separate reads.
readEnvelope :: CoordinationStore -> RunAssociation -> Text -> IO BS.ByteString
readEnvelope store association key = do
  (digest,size) <- runRead store $ do
    rows <- query "SELECT envelope_digest,length(envelope) FROM ingestions WHERE run_id=? AND sequence=?" parameters
    case rows of
      [[SQL.SQLText digest,SQL.SQLInteger size]] | size > 0 && size <= fromIntegral (maxFrameBytes + 1) -> pure (digest,size)
      _ -> refuseTransaction StoreIntegrity
  parts <- forM [0,524288 .. size-1] $ \offset -> runRead store $ do
    rows <- query "SELECT substr(envelope,?,524288) FROM ingestions WHERE run_id=? AND sequence=?"
      (SQL.SQLInteger (offset+1) : parameters)
    case rows of [[SQL.SQLBlob part]] -> pure part; _ -> refuseTransaction StoreIntegrity
  let bytes = BS.concat parts
  unless (fromIntegral (BS.length bytes) == size && digestOf bytes == digest) (throwIO StoreIntegrity)
  pure bytes
  where parameters = [text (associationRun association),text key]

-- Only the record's final LF is framing. Unframed differential fixtures remain
-- supported; all other original whitespace remains payload and duplicate identity.
decodeEvidence :: BS.ByteString -> IO Envelope
decodeEvidence bytes = do
  let payload = case BS.unsnoc bytes of Just (body,10) -> body; _ -> bytes
  when (BS.length payload > maxFrameBytes) (throwIO StoreLimit)
  valid (decodeEnvelopeFor supportedProtocolVersions payload)

associateRequest :: RunAssociation -> Transaction [Invalidation]
associateRequest association = do
  binding <- query "SELECT request_id FROM runs WHERE id=?" [text (associationRun association)]
  case binding of
    [[SQL.SQLNull]] -> pure []
    [[SQL.SQLText request]] -> do
      rows <- query "SELECT r.phase,r.revision,v.id,v.request_revision,v.state FROM requests r JOIN start_intents i ON i.request_id=r.id JOIN reservations v ON v.id=i.reservation_id AND v.request_id=r.id WHERE i.run_id=?"
        [text (associationRun association)]
      reservation <- case rows of
        [[SQL.SQLText "start-pending",SQL.SQLText revision,SQL.SQLText ident,SQL.SQLText bound,SQL.SQLText state]]
          | state == "released" || revision == bound -> pure ident
        _ -> refuseTransaction StoreIntegrity
      let revision = "associated_" <> associationRun association
      execute "UPDATE requests SET phase='associated',revision=? WHERE id=?" [text revision,text request]
      execute "UPDATE reservations SET request_revision=? WHERE id=?" [text revision,text reservation]
      pure [Invalidation "request.changed" ("/v1/requests/"<>request) revision]
    _ -> refuseTransaction StoreIntegrity

checkAssociation :: RunAssociation -> Transaction ()
checkAssociation association = do
  rows <- query "SELECT profile_id,root_identity,native_run_id FROM runs WHERE id=?" [text (associationRun association)]
  unless (rows == [[text (associationProfile association),text (associationRoot association),text (runIdText (associationNative association))]])
    (refuseTransaction StoreIntegrity)

-- Bound complete original records (including LF) independently of Runtime's
-- 64MiB canonical checkpoint. Neither representation truncates the prefix.
checkEvidenceBound :: RunAssociation -> Int -> Transaction ()
checkEvidenceBound association additional = do
  rows <- query "SELECT coalesce(sum(length(envelope)),0) FROM ingestions WHERE run_id=?" [text (associationRun association)]
  case rows of
    [[SQL.SQLInteger size]] -> when (toInteger size + toInteger additional > maxArtifactBytes) (refuseTransaction StoreLimit)
    _ -> refuseTransaction StoreIntegrity

projectionRow :: RunAssociation -> Transaction BS.ByteString
projectionRow association = do
  rows <- query "SELECT runtime_snapshot,snapshot_version FROM runs WHERE id=?" [text (associationRun association)]
  case rows of
    [[SQL.SQLNull,SQL.SQLNull]] -> pure BS.empty
    [[SQL.SQLBlob bytes,SQL.SQLInteger 1]] | not (BS.null bytes) -> pure bytes
    _ -> refuseTransaction StoreIntegrity

-- This manifest denotes the shared checkpoint over the immutable ingestion
-- prefix, not a JSON hydration of an independently editable RunSnapshot.
projectionBoundary :: RunSnapshot -> BS.ByteString
projectionBoundary snapshot = case snapshotLastEnvelope snapshot of
  Nothing -> BS.empty
  Just envelope -> encoded (object
    ["projectionVersion" .= (1::Int), "representation" .= ("runtime-ingestion-prefix"::Text),
     "runId" .= runIdText (snapshotRunId snapshot), "protocolVersion" .= envelopeVersion envelope,
     "lastSequence" .= sequenceText envelope,
     "snapshotSha256" .= digestOf (encoded (runSnapshotValue snapshot))])

-- Decisions and reference-only outputs are observations of the shared snapshot.
-- They do not assert answer acceptance, artifact verification, or control effects.
observeChanges :: RunAssociation -> Text -> Text -> RunSnapshot -> RunSnapshot -> Transaction [Invalidation]
observeChanges association revision sequenceKey before after = do
  occurrenceEvents <- fmap concat $ forM changed $ \occurrence -> do
    let ident = T.pack (show (occurrenceNumber (snapshotOccurrenceId occurrence)))
        previous = Map.lookup (snapshotOccurrenceId occurrence) (snapshotOccurrences before)
        person = active && snapshotOccurrencePersonPending occurrence
        recovery = case snapshotOccurrenceRecovery occurrence of
          Just value -> active && snapshotOccurrenceState occurrence == OccurrenceRecoveringState && not (isJust (snapshotRecoveryChosen value))
          Nothing -> False
        question = snapshotOccurrencePersonQuestion occurrence
    questionArtifact <- traverse (referenceArtifact association revision (toJSON (snapshotOccurrenceCode occurrence)) . toJSON) question
    decisionEvents <- fmap concat $ forM [("question",person),("recovery",recovery)] $ \(kind,pending) -> do
      existing <- query "SELECT id FROM decisions WHERE run_id=? AND occurrence_id=? AND kind=? AND state IN ('pending','submitting')"
        [text (associationRun association),text ident,text kind]
      case (pending,existing) of
        (True,[]) -> do
          let decision = "decision_" <> digestOf (encoded (associationRun association,ident,kind,sequenceKey))
              options = maybe SQL.SQLNull (SQL.SQLBlob . encoded . snapshotRecoveryChoices) (snapshotOccurrenceRecovery occurrence)
              attempt = if kind == "question" then SQL.SQLNull else maybe SQL.SQLNull
                (text . T.pack . show . attemptNumber . fst) (Map.lookupMax (snapshotOccurrenceAttempts occurrence))
          execute "INSERT INTO decisions(id,revision,run_id,occurrence_id,attempt_id,generation,observed_sequence,observed_order,kind,state,question_artifact_id,recovery_options) VALUES (?,?,?,?,?,?,?,(SELECT sequence FROM service_metadata WHERE singleton=1),?,'pending',?,?)"
            [text decision,text revision,text (associationRun association),text ident,attempt,text sequenceKey,text sequenceKey,text kind,
             maybe SQL.SQLNull (text . fst) questionArtifact,options]
          pure [Invalidation "decision.changed" ("/v1/decisions/"<>decision) revision]
        (False,_) -> forM existing $ \row -> case row of
          [SQL.SQLText decision] -> do
            execute "UPDATE decisions SET state='resolved',revision=? WHERE id=?" [text revision,text decision]
            pure (Invalidation "decision.changed" ("/v1/decisions/"<>decision) revision)
          _ -> refuseTransaction StoreIntegrity
        (True,[[SQL.SQLText _]]) -> pure []
        _ -> refuseTransaction StoreIntegrity
    -- Intermediate output remains in the lossless prefix/shared projection.
    let outputChanged = fmap snapshotOccurrenceAttempts previous /= Just (snapshotOccurrenceAttempts occurrence)
          || fmap snapshotOccurrenceAnswer previous /= Just (snapshotOccurrenceAnswer occurrence)
        outputs = [Invalidation "run.changed" (runURI association<>"/outputs") revision | outputChanged]
    pure (decisionEvents <> maybe [] snd questionArtifact <> outputs)
  resultEvents <- if snapshotResult before == snapshotResult after then pure [] else case snapshotResult after of
    Nothing -> pure []
    Just result -> do
      (artifact,events) <- referenceArtifact association revision (resultArtifactCode result) (toJSON result)
      execute "UPDATE runs SET result_state='referenced',result_artifact_id=? WHERE id=?" [text artifact,text (associationRun association)]
      pure events
  pure (occurrenceEvents <> resultEvents)
  where
    active = snapshotRunStatus after `elem` [RunRunning,RunCancelling]
    changed = [value | (key,value) <- Map.toList (snapshotOccurrences after), not active || Map.lookup key (snapshotOccurrences before) /= Just value]

referenceArtifact :: RunAssociation -> Text -> Value -> Value -> Transaction (Text,[Invalidation])
referenceArtifact association revision code reference = do
  let bytes = encoded reference
      ident = "artifact_" <> digestOf (encoded (associationRun association,reference))
  rows <- query "SELECT id,code FROM artifacts WHERE run_id=? AND private_reference=?" [text (associationRun association),SQL.SQLBlob bytes]
  case rows of
    [] -> do
      execute "INSERT INTO artifacts(id,revision,run_id,private_reference,code,verification) VALUES (?,?,?,?,?,'referenced')"
        [text ident,text revision,text (associationRun association),SQL.SQLBlob bytes,SQL.SQLBlob (encoded code)]
      pure (ident,[Invalidation "artifact.changed" ("/v1/artifacts/"<>ident) revision])
    [[SQL.SQLText existing,SQL.SQLBlob oldCode]] | oldCode == encoded code -> pure (existing,[])
    _ -> refuseTransaction StoreIntegrity

sequenceText :: Envelope -> Text
sequenceText = T.pack . show . sequenceNumber . envelopeSequence
runURI :: RunAssociation -> Text
runURI association = "/v1/runs/" <> associationRun association
text :: Text -> SQL.SQLData
text = SQL.SQLText
encoded :: ToJSON a => a -> BS.ByteString
encoded = BL.toStrict . encode
digestOf :: BS.ByteString -> Text
digestOf bytes = T.pack (show (hash bytes :: Digest SHA256))
valid :: Either a b -> IO b
valid = either (const (throwIO StoreIntegrity)) pure

-- | Current observations only. Neither this view nor its revision grants a pipe.
readControlSurface :: AcceptedStart -> CredentialProof -> IO Value
readControlSurface accepted proof = withControlSurface accepted proof (\_ -> pure)

withControlSurface :: AcceptedStart -> CredentialProof -> (AuthorizedView -> Value -> IO a) -> IO a
withControlSurface accepted proof respond = do
  (store,profile,_,prepared) <- acceptedControlContext accepted
  let association = RunAssociation (acceptedStartRun accepted) profile (preparedRootIdentity prepared) (preparedRunId prepared)
  withAuthorizedResponse store proof profile [Command.Observe] $ \view -> do
    worker <- observeAcceptedStart accepted
    let live = observedWorkerPhase worker `elem` [WorkerStartSent,WorkerRunning] && observedWorkerExit worker == Nothing
    value <- controlSurfaceBorrowed store proof association live
    revalidateAuthorizedView view >>= either throwIO pure
    respond view value

-- | Closed observations cannot advertise native control ownership.
readClosedControlSurface :: CoordinationStore -> CredentialProof -> RunAssociation -> IO Value
readClosedControlSurface store proof association = withClosedControlSurface store proof association (\_ -> pure)

withClosedControlSurface :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> Value -> IO a) -> IO a
withClosedControlSurface store proof association respond =
  withAuthorizedResponse store proof (associationProfile association) [Command.Observe] $ \view -> do
    value <- controlSurfaceBorrowed store proof association False
    revalidateAuthorizedView view >>= either throwIO pure
    respond view value

controlSurfaceBorrowed :: CoordinationStore -> CredentialProof -> RunAssociation -> Bool -> IO Value
controlSurfaceBorrowed store proof association live = do
  (revision,supervision) <- runRead store $ do
    authorizeObservation proof association
    rows <- query "SELECT control_revision,supervision FROM runs WHERE id=?" [text(associationRun association)]
    case rows of [[SQL.SQLText revision,SQL.SQLText supervision]] -> pure(revision,supervision); _ -> refuseTransaction StoreIntegrity
  snapshot <- borrowedProjection store association
  heads <- runRead store $ do
    authorizeObservation proof association
    rows <- query "SELECT control_revision,supervision FROM runs WHERE id=?" [text(associationRun association)]
    boundary <- projectionRow association
    case rows of
      [[SQL.SQLText current,SQL.SQLText currentSupervision]] -> unless(current==revision && currentSupervision==supervision)(refuseTransaction StoreBusy)
      _ -> refuseTransaction StoreIntegrity
    unless(boundary==projectionBoundary snapshot)(refuseTransaction StoreBusy)
    pendingDecisions association
  let available=live && supervision=="owned" && snapshotRunStatus snapshot==RunRunning
      offer operation occurrence attempt generation timings choices targets=object
        ["operation" .= (operation::Text),"address" .= object(["occurrenceId" .= T.pack(show(occurrenceNumber occurrence))] <>
          maybe [] (\a->["attemptId" .= T.pack(show(attemptNumber a))]) attempt),
         "generation" .= (generation::Maybe Text),"timings" .= (timings::[Text]),"choices" .= map publicRecoveryOptionValue choices,"targets" .= (targets::[Text])]
      ordinary=concat [
        [offer "steer" (snapshotOccurrenceId occurrence) (Just(snapshotAttemptId attempt)) Nothing ["interrupt-now","next-boundary"] [] [] |
          attempt<-Map.elems(snapshotOccurrenceAttempts occurrence),snapshotAttemptState attempt==AttemptRunning,snapshotAttemptSteerable attempt==Just True] <>
        [offer "redirect" (snapshotOccurrenceId occurrence) Nothing Nothing [] [] (dispatchTargets dispatch) |
          Just dispatch<-[snapshotOccurrenceDispatch occurrence],dispatchOpen dispatch] |
        occurrence<-Map.elems(snapshotOccurrences snapshot)]
      mandatory=case heads of
        (_,occurrence,generation,_,kind,"pending"):_ -> concat
          [if kind=="question" then [offer "answer" (snapshotOccurrenceId current) Nothing (Just generation) [] [] []]
           else [offer operation (snapshotOccurrenceId current) Nothing (Just generation) [] (snapshotRecoveryChoices recovery) [] |
             Just recovery<-[snapshotOccurrenceRecovery current],operation<-["retry","choose-recovery"]] |
           current<-Map.elems(snapshotOccurrences snapshot),T.pack(show(occurrenceNumber(snapshotOccurrenceId current)))==occurrence]
        _->[]
      offers=if available then ordinary<>mandatory else []
  when(length offers>512)(throwIO Command.ViewTooLarge)
  pure(object ["version" .= (1::Int),"runId" .= associationRun association,"revision" .= (if live then revision else "closed_"<>revision),
    "supervision" .= supervision,"cancelAllowed" .= available,"offers" .= offers,
    "decisionHeadId" .= case heads of (ident,_,_,_,_,_):_->Just ident;_->Nothing])

-- IDs, occurrence, generation, revision, kind, state in per-run opening order.
type DecisionRow = (Text,Text,Text,Text,Text,Text)
pendingDecisions :: RunAssociation -> Transaction [DecisionRow]
pendingDecisions association = do
  rows <- query "SELECT id,occurrence_id,generation,revision,kind,state FROM decisions WHERE run_id=? AND state IN ('pending','submitting') ORDER BY length(observed_sequence),observed_sequence"
    [text(associationRun association)]
  mapM (\row -> case row of
    [SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r,SQL.SQLText k,SQL.SQLText s] -> pure(i,o,g,r,k,s)
    _ -> refuseTransaction StoreIntegrity) rows

-- | Public recovery options have a required nullable target, unlike native JSON.
publicRecoveryOptionValue :: RecoveryOption -> Value
publicRecoveryOptionValue choice = object ["choice" .= recoveryChoice choice,"target" .= recoveryTarget choice]

authorizeObservation :: CredentialProof -> RunAssociation -> Transaction ()
authorizeObservation proof association = do
  _ <- currentClient proof >>= either refuseTransaction pure
  _ <- authorizeProfile proof (associationProfile association) [Command.Observe] >>= either refuseTransaction pure
  checkAssociation association

requireProjection :: CoordinationStore -> RunAssociation -> IO RunSnapshot
requireProjection store association = restoreRunProjection store association >>= maybe (throwIO Command.ResourceUnavailable) (pure . checkpointSnapshot)

readDecision :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> IO Value
readDecision store proof association ident = withDecision store proof association ident (\_ -> pure)

withDecision :: CoordinationStore -> CredentialProof -> RunAssociation -> Text
  -> (AuthorizedView -> Value -> IO a) -> IO a
withDecision store proof association ident respond = withStoreFiles store $ \root ->
  withAuthorizedResponse store proof (associationProfile association) [Command.Observe] $ \view -> do
    value <- decisionInView store root proof view association ident
    respond view value

-- | A decision observation borrowing the caller's original response scope.
decisionInView :: CoordinationStore -> PrivateRoot -> CredentialProof -> AuthorizedView -> RunAssociation -> Text -> IO Value
decisionInView store root proof view association ident = do
  revalidateAuthorizedView view >>= either throwIO pure
  value <- decisionBorrowed store root proof association ident
  revalidateAuthorizedView view >>= either throwIO pure
  pure value

decisionBorrowed :: CoordinationStore -> PrivateRoot -> CredentialProof -> RunAssociation -> Text -> IO Value
decisionBorrowed store root proof association ident = do
  rows <- runRead store $ authorizeObservation proof association >> pendingDecisions association
  (position,(_,occurrence,generation,revision,kind,state)) <- case [(n,row)| (n,row@(i,_,_,_,_,_))<-zip [0::Int ..] rows,i==ident] of
    [found] -> pure found
    _ -> throwIO Command.ResourceUnavailable
  snapshot <- borrowedProjection store association
  current <- maybe (throwIO StoreIntegrity) pure $ lookup occurrence
    [(T.pack(show(occurrenceNumber key)),value)|(key,value)<-Map.toList(snapshotOccurrences snapshot)]
  detail <- if kind=="question" then do
    reference <- maybe (throwIO StoreIntegrity) pure (snapshotOccurrencePersonQuestion current)
    question <- verifiedQuestionAt root association current reference
    pure ["question" .= question]
    else case snapshotOccurrenceRecovery current of
      Just recovery -> pure ["gap" .= snapshotRecoveryGap recovery,"message" .= snapshotRecoveryMessage recovery,"choices" .= map publicRecoveryOptionValue (snapshotRecoveryChoices recovery)]
      Nothing -> throwIO StoreIntegrity
  runRead store $ do
    authorizeObservation proof association
    currentRows <- pendingDecisions association
    unless((ident,occurrence,generation,revision,kind,state) `elem` currentRows)(refuseTransaction StoreBusy)
  let view=object (["version" .= (1::Int),"id" .= ident,"revision" .= revision,"runId" .= associationRun association,
        "profileId" .= associationProfile association,"generation" .= generation,"address" .= object["occurrenceId" .= occurrence],
        "state" .= state,"position" .= position,"observedSequence" .= generation,
        "queue" .= ("/v1/decisions?runId="<>associationRun association),"kind" .= kind] <> detail)
  when(BS.length(encoded view)>1048576)(throwIO Command.ViewTooLarge)
  pure view

verifiedQuestion :: CoordinationStore -> RunAssociation -> OccurrenceSnapshot -> QuestionRef -> IO Value
verifiedQuestion store association occurrence reference = withStoreFiles store $ \root ->
  verifiedQuestionAt root association occurrence reference

-- | Borrow the original file loan when a response already retains configuration.
verifiedQuestionAt :: PrivateRoot -> RunAssociation -> OccurrenceSnapshot -> QuestionRef -> IO Value
verifiedQuestionAt root association occurrence reference =
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    unless (T.pack(privateRootIdentity runs)==associationRoot association)(throwIO StoreIntegrity)
    bracket (openPrivateSubroot runs ["runs",T.unpack(runIdText(associationNative association)),"runtime"]) closePrivateRoot $ \runtime -> do
      (intent,question,code,schema) <- withPrivateDirectoryAt runtime [] $ \descriptor ->
        readQuestionArtifactSchemaAt (privateRootPath runtime) descriptor (associationNative association) (snapshotOccurrenceId occurrence) reference
      unless (code==snapshotOccurrenceCode occurrence && intent==snapshotOccurrenceIntent occurrence)(throwIO StoreIntegrity)
      assertPrivateRoot runs
      case question of
        Object fields -> do
          address <- case KM.lookup "addressee" fields of
            Just raw -> case fromJSON raw of Success value->pure(addresseeWord value);Error _->throwIO StoreIntegrity
            _ -> throwIO StoreIntegrity
          semantic <- case KM.lookup "code" fields of
            Just(Object raw) -> case KM.lookup "json" raw of
              Just(Object structured) -> maybe (throwIO StoreIntegrity) pure (KM.lookup "schema" structured)
              _ -> throwIO StoreIntegrity
            Just(String _) -> pure Null
            _ -> throwIO StoreIntegrity
          unless(T.length address<=1024)(throwIO Command.ViewTooLarge)
          case KM.lookup "prompt" fields of Just(String prompt)->when(T.length prompt>524288)(throwIO Command.ViewTooLarge);_->throwIO StoreIntegrity
          case KM.lookup "scope" fields of
            Just(Object scope) | KM.size scope==2 -> forM_ ["model","mode"] $ \axis -> case KM.lookup axis scope of
              Just Null -> pure ()
              Just(String label) -> when(T.length label>1024)(throwIO Command.ViewTooLarge)
              _ -> throwIO StoreIntegrity
            _ -> throwIO StoreIntegrity
          draw <- case KM.lookup "draw" fields of
            Just(Number number) | number>=0 && number<=18446744073709551615 -> case floatingOrInteger number :: Either Double Integer of
              Right value -> pure(String(T.pack(show value)))
              _ -> throwIO StoreIntegrity
            _ -> throwIO Command.ViewTooLarge
          pure(Object (KM.insert "addressee" (String address) (KM.insert "draw" draw (KM.insert "editorSchema" (if representableEditorSchema schema then schema else Null) (KM.insert "semanticSchema" semantic fields)))))
        _ -> throwIO StoreIntegrity

-- | Global inbox compares manager opening observations, never native sequences across runs.
readDecisionHeads :: CoordinationStore -> CredentialProof -> IO [Value]
readDecisionHeads store proof = do
  rows <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    found <- query "SELECT d.id,r.id,r.profile_id,r.root_identity,r.native_run_id,d.observed_order FROM decisions d JOIN runs r ON r.id=d.run_id WHERE d.state IN ('pending','submitting') AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=r.profile_id AND s.scope='observe') AND NOT EXISTS(SELECT 1 FROM decisions earlier WHERE earlier.run_id=d.run_id AND earlier.state IN ('pending','submitting') AND (length(earlier.observed_sequence)<length(d.observed_sequence) OR (length(earlier.observed_sequence)=length(d.observed_sequence) AND earlier.observed_sequence<d.observed_sequence))) ORDER BY length(d.observed_order),d.observed_order"
      [text(credentialRateKey proof)]
    forM found $ \row -> case row of
      [SQL.SQLText ident,SQL.SQLText run,SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native,SQL.SQLText _] -> pure(ident,run,profile,root,native)
      _ -> refuseTransaction StoreIntegrity
  forM rows $ \(ident,run,profile,root,native) ->
    readDecision store proof (RunAssociation run profile root (RunId native)) ident

submitRunControl :: AcceptedStart -> CredentialProof -> Text -> Maybe Text -> BS.ByteString -> IO (Either Command.CommandFailure Commands.Submission)
submitRunControl accepted proof = submitControl False accepted proof Nothing

submitDecisionControl :: AcceptedStart -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either Command.CommandFailure Commands.Submission)
submitDecisionControl accepted proof decision = submitControl False accepted proof (Just decision)

dispatchRunControl :: AcceptedStart -> CredentialProof -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either Command.CommandFailure Commands.Submission)
dispatchRunControl accepted proof = submitControl True accepted proof Nothing

dispatchDecisionControl :: AcceptedStart -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either Command.CommandFailure Commands.Submission)
dispatchDecisionControl accepted proof decision = submitControl True accepted proof (Just decision)

-- | Resolve a current authorized observation address, never a live association.
resolveRun :: CoordinationStore -> CredentialProof -> [Command.Scope] -> Text -> IO RunAssociation
resolveRun store proof scopes ident = do
  unless (Command.validId ident) (throwIO Command.InvalidRequest)
  (profile,root,native) <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    rows <- query "SELECT profile_id,root_identity,native_run_id FROM runs WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native]] -> do
        _ <- authorizeProfile proof profile scopes >>= either refuseTransaction pure
        pure (profile,root,native)
      _ -> refuseTransaction Command.Forbidden
  nativeId <- either (const (throwIO StoreIntegrity)) pure (mkRunId native)
  pure (RunAssociation ident profile root nativeId)

resolveDecision :: CoordinationStore -> CredentialProof -> [Command.Scope] -> Text -> IO RunAssociation
resolveDecision store proof scopes ident = do
  unless (Command.validId ident) (throwIO Command.InvalidRequest)
  run <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    rows <- query "SELECT run_id FROM decisions WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText value]] -> pure value
      _ -> refuseTransaction Command.Forbidden
  resolveRun store proof scopes run

-- | Exact cached receipt replay does not reconstruct a control ticket or Worker.
replayControl :: CoordinationStore -> CredentialProof -> RunAssociation -> Maybe Text
  -> Text -> Maybe Text -> BS.ByteString -> IO (Either Command.CommandFailure Commands.Submission)
replayControl store proof association decision key precondition body = case parseControlBody body of
  Left failure -> pure (Left failure)
  Right (operation,_,_)
    | isJust decision && operation `notElem` [Command.Answer,Command.ChooseRecovery] -> pure (Left Command.InvalidRequest)
    | otherwise ->
        let uri = maybe (runURI association <> "/control") ("/v1/decisions/" <>) decision
            request = Commands.CommandRequest operation (associationProfile association) "POST" uri key "application/json" precondition body
        in Commands.submitConfiguredCommand store proof request (\_ _ _ -> Left Command.OwnershipUnavailable)

submitControl :: Bool -> AcceptedStart -> CredentialProof -> Maybe Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either Command.CommandFailure Commands.Submission)
submitControl dispatch accepted proof decision key precondition body = do
  (store,profile,_,prepared) <- acceptedControlContext accepted
  let association=RunAssociation (acceptedStartRun accepted) profile (preparedRootIdentity prepared) (preparedRunId prepared)
      uri=maybe (runURI association<>"/control") ("/v1/decisions/"<>) decision
  case parseControlBody body of
    Left failure -> pure(Left failure)
    Right (operation,_,_) | isJust decision && operation `notElem` [Command.Answer,Command.ChooseRecovery] -> pure(Left Command.InvalidRequest)
    Right (operation,generation,makeControl) -> do
      let request=Commands.CommandRequest operation profile "POST" uri key "application/json" precondition body
          version=do
            rows <- case decision of
              Nothing -> query "SELECT control_revision FROM runs WHERE id=?" [text(associationRun association)]
              Just ident -> query "SELECT revision FROM decisions WHERE id=? AND run_id=?" [text ident,text(associationRun association)]
            pure $ case rows of [[SQL.SQLText revision]]->Just(uri,profile,revision);_->Nothing
      (if dispatch then acceptAndDeliverControlCommand else acceptControlCommand) accepted proof request version $ do
          selected <- withStoreConfiguration store $ \_ profiles -> case [publicRevision current|current<-profiles,publicId current==profile] of
            [revision]->pure revision
            _->throwIO Command.Forbidden
          policy <- either (const(throwIO Command.StorageUnavailable)) pure selected
          snapshot <- requireProjection store association
          availabilityRevision <- runRead store $ do
            boundary <- projectionRow association
            unless(boundary==projectionBoundary snapshot)(refuseTransaction StoreBusy)
            rows <- query "SELECT control_revision FROM runs WHERE id=?" [text(associationRun association)]
            case rows of [[SQL.SQLText revision]]->pure revision;_->refuseTransaction StoreIntegrity
          -- Verify the question with Runtime before any answer reservation. The transaction
          -- below binds this snapshot to the current durable observation boundary.
          let addressed=expectedOccurrence(makeControl "validation")
          when(operation==Command.Answer) $ case addressed >>= (`Map.lookup` snapshotOccurrences snapshot) of
            Just occurrence -> case snapshotOccurrencePersonQuestion occurrence of
              Just reference -> void(verifiedQuestion store association occurrence reference)
              _ -> throwIO Command.ResourceUnavailable
            _ -> throwIO Command.ResourceUnavailable
          let encoder candidate=either (const(Left Command.InvalidRequest)) Right
                (encodeControlFor correlatedProtocolVersion (addressControl snapshot operation (makeControl candidate)))
          pure(encoder, \candidate _ _ -> Right Commands.Mutation
            { Commands.mutationProfileRevision=policy,
              Commands.mutationVersion=version,
              Commands.mutationValidate=do
                rows <- query "SELECT control_revision FROM runs WHERE id=?" [text(associationRun association)]
                unless(rows==[[text availabilityRevision]])(refuseTransaction StoreBusy)
                do
                  pending <- pendingDecisions association
                  let base=makeControl candidate
                      target=T.pack . show . occurrenceNumber <$> expectedOccurrence base
                      mandatory=operation `elem` [Command.Answer,Command.ChooseRecovery,Command.Retry]
                      chosen=[row|row@(_,o,g,_,kind,_)<-pending,Just o==target,Just g==generation,
                        kind==(if operation==Command.Answer then "question" else "recovery")]
                  case (mandatory,chosen) of
                    (True,[(ident,_,_,_,_,state)])
                      | maybe False (/=ident) decision -> pure(Left Command.InvalidRequest)
                      | case pending of (headId,_,_,_,_,_):_->headId/=ident;_->True -> pure(Left Command.DecisionNotHead)
                      | state/="pending" -> pure(Left Command.StaleRevision)
                      | otherwise -> reserveControl association snapshot candidate operation (Just ident) base
                    (True,_) -> pure(Left Command.StaleRevision)
                    (False,_) | isJust decision -> pure(Left Command.InvalidRequest)
                    _ -> reserveControl association snapshot candidate operation Nothing base
            })

reserveControl :: RunAssociation -> RunSnapshot -> Text -> Command.Operation -> Maybe Text -> Control -> Transaction (Either Command.CommandFailure Commands.Intent)
reserveControl association snapshot candidate operation decision base = do
  let occurrence=expectedOccurrence base >>= (`Map.lookup` snapshotOccurrences snapshot)
      control=addressControl snapshot operation base
      permitted=case controlCommand control of
        CancelRun -> snapshotRunStatus snapshot==RunRunning
        AnswerPerson _ -> maybe False snapshotOccurrencePersonPending occurrence
        RetryOccurrence -> recoveryOffered occurrence "retry"
        ChooseRecovery choice -> recoveryOffered occurrence (case choice of RecoveryRetry->"retry";RecoveryFailOver->"failover";RecoveryAbandon->"abandon")
        RedirectOccurrence target -> maybe False (\dispatch->dispatchOpen dispatch && target `elem` dispatchTargets dispatch) (occurrence >>= snapshotOccurrenceDispatch)
        Steer _ _ -> case (occurrence,expectedAttempt control) of
          (Just current,Just attempt) -> maybe False (\value->snapshotAttemptState value==AttemptRunning && snapshotAttemptSteerable value==Just True) (Map.lookup attempt(snapshotOccurrenceAttempts current))
          _ -> False
  pure $ if not permitted then Left Command.UnsupportedOperation else Right Commands.Intent
    { Commands.intentReferences=Commands.noReferences {Commands.referenceRun=Just(associationRun association),Commands.referenceDecision=decision},
      Commands.intentDispatch=True,
      Commands.intentApply=do
        bytes <- either (const(refuseTransaction Command.InvalidRequest)) pure (encodeControlFor correlatedProtocolVersion control)
        let payload=controlEffectPayload control
        execute "INSERT INTO control_intents(command_id,run_id,decision_id,native_command,occurrence_id,attempt_id,generation,native_sha256,native_bytes,effect_sha256,effect_bytes) VALUES (?,?,?,?,?,?,(SELECT generation FROM decisions WHERE id=?),?,?,?,?)"
          [text candidate,text(associationRun association),maybe SQL.SQLNull text decision,text(controlCommandName(controlCommand control)),
           maybe SQL.SQLNull (text . occurrenceKey) (expectedOccurrence control),maybe SQL.SQLNull (text . attemptKey) (expectedAttempt control),
           maybe SQL.SQLNull text decision,text(digestOf bytes),SQL.SQLInteger(fromIntegral(BS.length bytes)),
           maybe SQL.SQLNull (text . digestOf) payload,maybe SQL.SQLNull (SQL.SQLInteger . fromIntegral . BS.length) payload]
        execute "UPDATE runs SET control_revision=? WHERE id=?" [text candidate,text(associationRun association)]
        forM_ decision $ \ident -> execute "UPDATE decisions SET state='submitting',revision=? WHERE id=?"
          [text candidate,text ident]
        pure (Invalidation "run.changed" (runURI association<>"/control") candidate:
          [Invalidation "decision.changed" ("/v1/decisions/"<>ident) candidate|ident<-maybe [] pure decision],Nothing)
    }
  where
    recoveryOffered occurrence choice=maybe False (any ((==choice) . recoveryChoice) . snapshotRecoveryChoices) (occurrence >>= snapshotOccurrenceRecovery)

addressControl :: RunSnapshot -> Command.Operation -> Control -> Control
addressControl snapshot operation control
  | operation `elem` [Command.Retry,Command.ChooseRecovery] = control {expectedAttempt =
      expectedOccurrence control >>= (`Map.lookup` snapshotOccurrences snapshot) >>= fmap fst . Map.lookupMax . snapshotOccurrenceAttempts}
  | otherwise = control

controlEffectPayload :: Control -> Maybe BS.ByteString
controlEffectPayload control=case controlCommand control of
  Steer timing message -> Just(encoded(timingText timing,message))
  RedirectOccurrence target -> Just(encoded target)
  _ -> Nothing

occurrenceKey :: OccurrenceId -> Text
occurrenceKey = T.pack . show . occurrenceNumber
attemptKey :: AttemptId -> Text
attemptKey = T.pack . show . attemptNumber

parseControlBody :: BS.ByteString -> Either Command.CommandFailure (Command.Operation,Maybe Text,Text -> Control)
parseControlBody bytes = do
  when(BS.length bytes>2097152)(Left Command.SizeLimit)
  value <- either (const(Left Command.InvalidRequest)) Right (decodeStrictValue bytes)
  fields <- case value of Object fields->Right fields;_->Left Command.InvalidRequest
  name <- stringField fields "operation"
  operation <- maybe (Left Command.InvalidRequest) Right (Command.parseOperation name)
  let keys=case operation of
        Command.Cancel->["operation"]
        Command.Steer->["operation","occurrenceId","attemptId","timing","text"]
        Command.Redirect->["operation","occurrenceId","target"]
        Command.Retry->["operation","occurrenceId","generation"]
        Command.ChooseRecovery->["operation","occurrenceId","generation","choice"]
        Command.Answer->["operation","occurrenceId","generation","value"]
        _->[]
  unless(not(null keys) && KM.size fields==length keys && all ((`elem` keys) . Key.toText) (KM.keys fields))(Left Command.InvalidRequest)
  occurrence <- if operation==Command.Cancel then Right Nothing else Just <$> decimalField fields "occurrenceId"
  attempt <- if operation==Command.Steer then Just <$> decimalField fields "attemptId" else Right Nothing
  generation <- if operation `elem` [Command.Answer,Command.Retry,Command.ChooseRecovery] then do
    g<-stringField fields "generation";unless(Command.validRevision g)(Left Command.InvalidRequest);pure(Just g)
    else Right Nothing
  native <- case operation of
    Command.Cancel->pure(object["type" .= ("cancelRun"::Text)])
    Command.Answer->pure(object["type" .= ("answerPerson"::Text),"answer" .= maybe Null id (KM.lookup "value" fields)])
    Command.Retry->pure(object["type" .= ("retryOccurrence"::Text)])
    Command.ChooseRecovery->do
      choice<-stringField fields "choice"
      kind<-case choice of "retry"->Right "retryOccurrence";"failover"->Right "failoverOccurrence";"abandon"->Right "abandonOccurrence";_->Left Command.InvalidRequest
      pure(object["type" .= (kind::Text)])
    Command.Redirect->do
      target<-stringField fields "target"
      unless(not(T.null target) && T.length target<=1024)(Left Command.InvalidRequest)
      pure(object["type" .= ("redirectOccurrence"::Text),"target" .= target])
    Command.Steer->do
      timing<-stringField fields "timing";message<-stringField fields "text"
      when(T.length message>524288)(Left Command.InvalidRequest)
      pure(object["type" .= ("steerOccurrence"::Text),"timing" .= timing,"text" .= message])
    _->Left Command.InvalidRequest
  control <- either (const(Left Command.InvalidRequest)) Right $ decodeControlFor correlatedProtocolVersion (encoded(object
    ["controlId" .= ("validation"::Text),"expectedOccurrenceId" .= occurrence,
     "expectedAttemptId" .= fmap (\number->object["occurrenceId" .= occurrence,"attemptNumber" .= number]) attempt,"command" .= native]))
  pure(operation,generation,\ident->control {controlId=ControlId ident})
  where
    stringField fields key=case KM.lookup key fields of Just(String value)->Right value;_->Left Command.InvalidRequest
    decimalField fields key=do
      value<-stringField fields key
      unless(not(T.null value) && T.length value<=20 && T.all (\c->c>='0'&&c<='9') value && (value=="0" || T.head value/='0'))(Left Command.InvalidRequest)
      pure value

-- Address/availability changes, not output fragments, revise the control surface.
controlAvailability :: RunSnapshot -> Value
controlAvailability snapshot=object["state" .= show(snapshotRunStatus snapshot),"occurrences" .=
  [object["id" .= occurrenceNumber(snapshotOccurrenceId occurrence),"person" .= snapshotOccurrencePersonPending occurrence,
    "state" .= show(snapshotOccurrenceState occurrence),"recovery" .= fmap (\r->object["choices" .= snapshotRecoveryChoices r,"chosen" .= fmap chosenControlId(snapshotRecoveryChosen r)]) (snapshotOccurrenceRecovery occurrence),
    "dispatch" .= fmap (\d->object["open" .= dispatchOpen d,"targets" .= dispatchTargets d]) (snapshotOccurrenceDispatch occurrence),
    "attempts" .= [object["id" .= attemptNumber(snapshotAttemptId a),"state" .= show(snapshotAttemptState a),"steerable" .= snapshotAttemptSteerable a]|a<-Map.elems(snapshotOccurrenceAttempts occurrence)]]
    |occurrence<-Map.elems(snapshotOccurrences snapshot)]]

-- No answer or steering content is retained in the command ledger.
data ControlCorrelation = ControlCorrelation
  { correlatedNativeCommand :: !Text, correlatedOccurrence :: !(Maybe Text),
    correlatedAttempt :: !(Maybe Text), correlatedEffect :: !(Maybe (Text,Integer)) }

effectMatches :: ControlCorrelation -> BS.ByteString -> Bool
effectMatches binding bytes = correlatedEffect binding==Just(digestOf bytes,toInteger(BS.length bytes))

observeControls :: RunAssociation -> Text -> Envelope -> RunSnapshot -> RunSnapshot -> Transaction [Invalidation]
observeControls association revision envelope before after = do
  availability <- if controlAvailability before==controlAvailability after then pure [] else do
    execute "UPDATE runs SET control_revision=? WHERE id=?" [text revision,text(associationRun association)]
    pure[Invalidation "run.changed" (runURI association<>"/control") revision]
  correlated <- case envelopeEvent envelope of
    ControlAcknowledgedV2 ident state _ native occurrence attempt -> correlate ident $ \operation control decision -> do
      unless(native==correlatedNativeCommand control && fmap occurrenceKey occurrence==correlatedOccurrence control && fmap attemptKey attempt==correlatedAttempt control)(refuseTransaction StoreIntegrity)
      ack <- jsonTx(object["commandId" .= ident,"state" .= state,"message" .= ("Runtime acknowledgement"::Text),
        "command" .= Command.operationName operation,"occurrenceId" .= fmap (T.pack . show . occurrenceNumber) occurrence,
        "attemptId" .= fmap (T.pack . show . attemptNumber) attempt])
      effect <- if operation==Command.Answer && state=="delivered" then Just <$> effectAt "answer-accepted" occurrence (fmap attemptKey attempt) else pure Nothing
      events <- Commands.recordRuntimeObservation ident revision (Just ack) effect
      released <- if state `elem` ["rejected-stale","unsupported","failed"] then releaseDecision ident decision else pure []
      pure(events<>released)
    AttemptSteered attempt ident timing message -> correlate ident $ \operation control _ -> do
      unless(operation==Command.Steer && correlatedNativeCommand control=="steerOccurrence"
        && correlatedOccurrence control==Just(occurrenceKey(attemptOccurrence attempt)) && correlatedAttempt control==Just(attemptKey attempt)
        && effectMatches control (encoded(timing,message)))(refuseTransaction StoreIntegrity)
      effect <- effectAt "steered" (Just(attemptOccurrence attempt)) (Just(attemptKey attempt))
      Commands.recordRuntimeObservation ident revision Nothing (Just effect)
    OccurrenceRetried occurrence ident -> correlate ident $ \operation control _ -> do
      let chosen = Map.lookup occurrence (snapshotOccurrences after) >>= snapshotOccurrenceRecovery >>= snapshotRecoveryChosen
          expectedChoice=case correlatedNativeCommand control of "retryOccurrence"->Just "retry";"failoverOccurrence"->Just "failover";_->Nothing
      unless(operation `elem` [Command.Retry,Command.ChooseRecovery] && correlatedOccurrence control==Just(occurrenceKey occurrence)
        && fmap chosenControlId chosen==Just ident && fmap chosenChoice chosen==expectedChoice && isJust expectedChoice)(refuseTransaction StoreIntegrity)
      effect <- effectAt (if operation==Command.Retry then "retried" else "recovery-chosen") (Just occurrence) (correlatedAttempt control)
      Commands.recordRuntimeObservation ident revision Nothing (Just effect)
    OccurrenceRecoveryChosen occurrence ident choice _ | choice=="abandon" -> correlate ident $ \operation control _ -> do
      unless(operation==Command.ChooseRecovery && correlatedNativeCommand control=="abandonOccurrence" && correlatedOccurrence control==Just(occurrenceKey occurrence))(refuseTransaction StoreIntegrity)
      effect <- effectAt "recovery-chosen" (Just occurrence) (correlatedAttempt control)
      Commands.recordRuntimeObservation ident revision Nothing (Just effect)
    OccurrenceRedirected occurrence ident target -> correlate ident $ \operation control _ -> do
      unless(operation==Command.Redirect && correlatedNativeCommand control=="redirectOccurrence" && correlatedOccurrence control==Just(occurrenceKey occurrence)
        && effectMatches control (encoded target))(refuseTransaction StoreIntegrity)
      effect <- effectAt "redirected" (Just occurrence) Nothing
      Commands.recordRuntimeObservation ident revision Nothing (Just effect)
    -- RunCancelled has no causal ControlId. Never attribute EOF/another cancellation.
    _ -> pure []
  pure(availability<>correlated)
  where
    correlate ident action = do
      rows <- query "SELECT c.operation,i.native_command,i.occurrence_id,i.attempt_id,i.effect_sha256,i.effect_bytes,i.decision_id FROM control_intents i JOIN commands c ON c.id=i.command_id WHERE i.command_id=? AND i.run_id=?" [text ident,text(associationRun association)]
      case rows of
        [] -> pure []
        [[SQL.SQLText op,SQL.SQLText native,occurrence,attempt,digest,size,decision]] -> do
          operation <- maybe(refuseTransaction StoreIntegrity)pure(Command.parseOperation op)
          effect <- case (digest,size) of
            (SQL.SQLNull,SQL.SQLNull)->pure Nothing
            (SQL.SQLText sha,SQL.SQLInteger bytes)->pure(Just(sha,toInteger bytes))
            _->refuseTransaction StoreIntegrity
          control <- ControlCorrelation native <$> optionalText occurrence <*> optionalText attempt <*> pure effect
          target <- optionalText decision
          action operation control target
        _ -> refuseTransaction StoreIntegrity
    optionalText SQL.SQLNull=pure Nothing
    optionalText (SQL.SQLText value)=pure(Just value)
    optionalText _=refuseTransaction StoreIntegrity
    effectAt kind occurrence attempt = jsonTx(object["kind" .= (kind::Text),"runtimeSequence" .= sequenceText envelope,
      "address" .= fmap (\ident->object(["occurrenceId" .= T.pack(show(occurrenceNumber ident))]<>maybe [] (\a->["attemptId" .= (a::Text)]) attempt)) occurrence,
      "resource" .= (runURI association<>"/control")])
    releaseDecision ident decision = case decision of
      Nothing->pure []
      Just identDecision->do
        rows <- query "SELECT count(*) FROM commands WHERE id=? AND effect_evidence IS NULL" [text ident]
        if rows/=[[SQL.SQLInteger 1]] then pure [] else do
          execute "UPDATE decisions SET state='pending',command_id=NULL,revision=? WHERE id=? AND state='submitting' AND command_id=?"
            [text revision,text identDecision,text ident]
          execute "UPDATE runs SET control_revision=? WHERE id=?" [text revision,text(associationRun association)]
          pure[Invalidation "decision.changed" ("/v1/decisions/"<>identDecision) revision,Invalidation "run.changed" (runURI association<>"/control") revision]

jsonTx :: FromJSON a => Value -> Transaction a
jsonTx value=case fromJSON value of Success result->pure result;Error _->refuseTransaction StoreIntegrity
