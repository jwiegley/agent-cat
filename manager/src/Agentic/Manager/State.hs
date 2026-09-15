{-# LANGUAGE OverloadedStrings #-}

-- | Durable Runtime observations. Stored associations never grant worker authority.
module Agentic.Manager.State
  ( RunAssociation (..), ingestAcceptedStart, ingestRuntimeEnvelope, restoreRunProjection
  ) where

import Agentic.Manager.Admission (AcceptedStart, acceptedStartRun, consumeAcceptedStart)
import Agentic.Manager.Store
import Agentic.Manager.Worker (workerEventBytes, workerEventEnvelope)
import Agentic.Runtime
import Control.Exception (throwIO)
import Control.Monad (unless, when, forM, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, ToJSON, encode, object, (.=), toJSON)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
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
ingestValidated store association bytes envelope = do
  decoded <- decodeEvidence bytes
  unless (decoded == envelope && envelopeRunId envelope == associationNative association) (throwIO StoreIntegrity)
  old <- restoreRunProjection store association
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
        execute "UPDATE runs SET runtime_snapshot=?,snapshot_version=1,revision=? WHERE id=?"
          [SQL.SQLBlob boundary, text revision, text (associationRun association)]
        pure (True, Invalidation "run.changed" (runURI association <> "/snapshot") revision : requestEvents <> observations)

-- | Restore one immutable, fixed sequence-zero prefix using bounded reads.
-- No read transaction spans the prefix or an observer's lifetime. Concurrent
-- appends cannot change an earlier prefix. The shared checkpoint enforces 64MiB.
-- ponytail: full prefix replay per ingestion, cache validated checkpoints if throughput requires it.
restoreRunProjection :: CoordinationStore -> RunAssociation -> IO (Maybe SnapshotCheckpoint)
restoreRunProjection store association = do
  (boundary, lastRow) <- runRead store $ do
    checkAssociation association
    boundary <- projectionRow association
    checkEvidenceBound association 0
    rows <- query "SELECT sequence FROM ingestions WHERE run_id=? ORDER BY length(sequence) DESC,sequence DESC LIMIT 1"
      [text (associationRun association)]
    lastKey <- case rows of
      [] -> pure Nothing
      [[SQL.SQLText key]] -> pure (Just key)
      _ -> refuseTransaction StoreIntegrity
    pure (boundary, lastKey)
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
  valid (decodeEnvelopeFor [protocolVersion, latestProtocolVersion] payload)

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
        person = snapshotOccurrencePersonPending occurrence
        recovery = case snapshotOccurrenceRecovery occurrence of
          Just value -> snapshotOccurrenceState occurrence == OccurrenceRecoveringState && not (isJust (snapshotRecoveryChosen value))
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
          execute "INSERT INTO decisions(id,revision,run_id,occurrence_id,attempt_id,generation,observed_sequence,kind,state,question_artifact_id,recovery_options) VALUES (?,?,?,?,?,?,?,?,'pending',?,?)"
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
    changed = [value | (key,value) <- Map.toList (snapshotOccurrences after), Map.lookup key (snapshotOccurrences before) /= Just value]

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
