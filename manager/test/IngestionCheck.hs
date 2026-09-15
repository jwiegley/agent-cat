{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module IngestionCheck (ingestionChecks, concurrentIngestionChecks) where

import Agentic.Manager.State
import Agentic.Manager.Store
import Agentic.Runtime
import Control.Exception (try, bracket)
import Control.Concurrent.Async (async, wait, cancel)
import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import Control.Monad (forM_, foldM, unless, void)
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import System.FilePath ((</>))

check :: String -> Bool -> IO ()
check label ok = unless ok (error ("FAIL "<>label)) >> putStrLn ("PASS "<>label)
right :: Show e => Either e a -> IO a
right = either (error . show) pure
first :: [a] -> IO a
first (value:_) = pure value
first [] = error "empty Runtime fixture"

-- These are Runtime-owned histories as data, not live worker authority.
ingestionChecks :: FilePath -> CoordinationStore -> IO ()
ingestionChecks source store = do
  forM_ ["protocol-v1/success","protocol-v1/cancelled","protocol-v1/reused","protocol-v1/redirected",
         "protocol-v1/recovery-failed","protocol-v1/failover-retried","protocol-v2/person-result","protocol-v2/progress"] $ \name -> do
    bytes <- BSC.lines <$> BS.readFile (source </> "test/fixtures/runtime" </> name<>".ndjson")
    envelopes <- right (traverse (decodeEnvelopeFor [1,2]) bytes)
    firstEnvelope <- first envelopes
    firstWire <- first bytes
    association <- seed store (T.replace "/" "_" (T.pack name)) (envelopeRunId firstEnvelope)
    full <- right (foldM stepRunSnapshot (initialRunSnapshot (associationNative association)) envelopes)
    forM_ (zip3 [1::Int ..] bytes envelopes) $ \(n,wire,_) -> do
      ingestRuntimeEnvelope store association wire >>= check (name<>" appended "<>show n)
      restored <- restoreRunProjection store association >>= maybe (error "missing projection") pure
      expected <- right (foldM stepRunSnapshot (initialRunSnapshot (associationNative association)) (take n envelopes))
      check (name<>" exact direct fold "<>show n) (checkpointSnapshot restored==expected && checkpointEnvelopes restored==take n envelopes)
      roundtrip <- right (encodeSnapshotCheckpoint restored >>= decodeSnapshotCheckpoint)
      suffix <- right (appendSnapshotCheckpoint roundtrip (drop n envelopes))
      check (name<>" restored suffix equals full fold "<>show n) (checkpointSnapshot suffix==full && checkpointEnvelopes suffix==envelopes)
    before <- observations store
    forM_ bytes $ \wire -> ingestRuntimeEnvelope store association wire >>= check (name<>" matching duplicate has no effects") . not
    observations store >>= check (name<>" duplicate leaves global sequence and rows untouched") . (==before)
    unchanged store association "same Envelope with different original spelling conflicts" (firstWire<>" ")
    forM_ [association {associationProfile="other"},association {associationRoot="other"},association {associationNative=RunId "other"}] $ \wrong -> do
      result <- try @StoreFailure (ingestRuntimeEnvelope store wrong firstWire)
      check "wrong trusted association refuses" (result==Left StoreIntegrity)
    let terminal = last envelopes
        after = terminal {envelopeSequence=SeqNo (sequenceNumber (envelopeSequence terminal)+1)}
    unchanged store association "post-terminal history refuses" (encodeEnvelope after)
  forM_ ["protocol-v1/sequence-gap","protocol-v1/reuse-after-attempt","protocol-v2/person-terminal-without-acceptance",
         "protocol-v2/person-queued-then-delivered","protocol-v2/control-correlation-change"] $ \name -> do
    wires <- BSC.lines <$> BS.readFile (source </> "test/fixtures/runtime" </> name<>".ndjson")
    envelopes <- right (traverse (decodeEnvelopeFor [1,2]) wires)
    firstEnvelope <- first envelopes
    association <- seed store (T.replace "/" "_" (T.pack name)) (envelopeRunId firstEnvelope)
    let loop snapshot [] = error ("invalid fixture accepted: "<>name<>show (snapshotRunStatus snapshot))
        loop snapshot ((wire,envelope):rest) = case stepRunSnapshot snapshot envelope of
          Right next -> ingestRuntimeEnvelope store association wire >>= check "valid prefix commits before invalid transition" >> loop next rest
          Left _ -> unchanged store association (name<>" shared refusal preserves durable state") wire
    loop (initialRunSnapshot (associationNative association)) (zip wires envelopes)
  boundaryChecks store
  simultaneousChecks store
  largeChecks store
  corruptionChecks store

seed :: CoordinationStore -> Text -> RunId -> IO RunAssociation
seed store name native = do
  let association = RunAssociation ("run_"<>name) "profile" ("fixture_"<>name) native
  runTransaction store $ do
    execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES (?,'fixture','fixture',?,?,?,'observer','absent')"
      (map SQL.SQLText [associationRun association,associationProfile association,associationRoot association,runIdText native])
    pure ((),[Invalidation "run.changed" ("/v1/runs/"<>associationRun association) "fixture"])
  pure association

observations :: CoordinationStore -> IO ([Integer],Text)
observations store = runRead store $ do
  counts <- mapM (\table -> do
    rows <- query ("SELECT count(*) FROM "<>table) []
    case rows of [[SQL.SQLInteger n]] -> pure (toInteger n); _ -> refuseTransaction StoreIntegrity)
    ["ingestions","decisions","artifacts","invalidations"]
  rows <- query "SELECT sequence FROM service_metadata" []
  case rows of [[SQL.SQLText sequenceKey]] -> pure (counts,sequenceKey); _ -> refuseTransaction StoreIntegrity

unchanged :: CoordinationStore -> RunAssociation -> String -> BS.ByteString -> IO ()
unchanged store association label wire = do
  before <- restoreRunProjection store association
  facts <- observations store
  result <- try @StoreFailure (ingestRuntimeEnvelope store association wire)
  after <- restoreRunProjection store association
  later <- observations store
  check label (result==Left StoreIntegrity && before==after && facts==later)

boundaryChecks :: CoordinationStore -> IO ()
boundaryChecks store = do
  association <- seed store "unsigned" (RunId "run-1")
  let event n = Envelope 1 (RunId "run-1") (SeqNo n) "2026-09-03T00:00:00Z" (RunStarted "review" "scripted")
  forM_ [1,9223372036854775808,maxBound] $ \n -> unchanged store association "unsigned first-sequence gap refuses without signed coercion" (encodeEnvelope (event n))
  void (ingestRuntimeEnvelope store association (encodeEnvelope (event 0)))
  unchanged store association "wrong run envelope refuses" (encodeEnvelope ((event 1) {envelopeRunId=RunId "other"}))
  unchanged store association "terminal without authored trace refuses" (encodeEnvelope ((event 1) {envelopeEvent=RunCompleted 0 0}))
  unchanged store association "protocol change refuses" (encodeEnvelope ((event 1) {envelopeVersion=2,envelopeEvent=RunStartedV2 "review" "scripted" PersonAnswerEngine}))

simultaneousChecks :: CoordinationStore -> IO ()
simultaneousChecks store = do
  let run=RunId "simultaneous"
      occurrence=OccurrenceId 0
      attempt=AttemptId occurrence 0
      question=QuestionRef 1 "person/questions/1.json" (T.replicate 64 "a") 1
      history=zipWith (Envelope 2 run . SeqNo) [0..] (repeat "2026-09-03T00:00:00Z")
      events=[RunStartedV2 "review" "scripted" PersonAnswerLocalControl,
              OccurrenceStarted occurrence "text" "consult" "model reviewer" "prompt",AttemptStarted attempt "scripted",
              OccurrenceStarted (OccurrenceId 1) "flag" "consult" "person reviewer" "approval",
              OccurrencePersonAnswerPending (OccurrenceId 1) question]
      envelopes=zipWith ($) history events
  _ <- right (captureSnapshotCheckpoint run envelopes)
  forM_ ["simultaneous_a","simultaneous_b"] $ \name -> do
    association <- seed store name run
    mapM_ (ingestRuntimeEnvelope store association . encodeEnvelope) envelopes
    snapshot <- restoreRunProjection store association >>= maybe (error "missing simultaneous projection") (pure . checkpointSnapshot)
    let active=any (any ((==AttemptRunning) . snapshotAttemptState) . Map.elems . snapshotOccurrenceAttempts) (Map.elems (snapshotOccurrences snapshot))
        pending=any snapshotOccurrencePersonPending (Map.elems (snapshotOccurrences snapshot))
    check "each simultaneous run retains active attempts and mandatory decisions" (active && pending)
  pending <- runRead store $ do
    rows <- query "SELECT count(*) FROM decisions WHERE run_id IN ('run_simultaneous_a','run_simultaneous_b') AND state='pending'" []
    pure (rows==[[SQL.SQLInteger 2]])
  check "independent run decision observations coexist durably" pending

largeChecks :: CoordinationStore -> IO ()
largeChecks store = do
  association <- seed store "large" (RunId "large")
  let occurrence=OccurrenceId 0; attempt=AttemptId occurrence 0
      event n e=Envelope 2 (associationNative association) (SeqNo n) "2026-09-03T00:00:00Z" e
      prefix=[event 0 (RunStartedV2 "review" "scripted" PersonAnswerEngine),event 1 (OccurrenceStarted occurrence "text" "consult" "model reviewer" "prompt"),event 2 (AttemptStarted attempt "scripted")]
      small=event 3 (AttemptOutput attempt "")
      room=maxFrameBytes-BS.length (encodeEnvelope small)
      large=event 3 (AttemptOutput attempt (T.replicate room "x"))
      history=prefix<>[large]<>[event n (AttemptOutput attempt (T.replicate 990000 "x")) | n <- [4..69]]
  check "exact native maximum frame fixture" (BS.length (encodeEnvelope large)==maxFrameBytes)
  mapM_ (ingestRuntimeEnvelope store association . encodeEnvelope) history
  restored <- restoreRunProjection store association >>= maybe (error "missing large projection") pure
  bytes <- right (encodeSnapshotCheckpoint restored)
  full <- right (foldM stepRunSnapshot (initialRunSnapshot (associationNative association)) history)
  check "near-64MiB checkpoint restores without raising Store row/result/input limits" (BS.length bytes>66000000 && checkpointSnapshot restored==full && checkpointEnvelopes restored==history)
  beforeLimit <- observations store
  overflow <- try @StoreFailure (ingestRuntimeEnvelope store association (encodeEnvelope (event 70 (AttemptOutput attempt (T.replicate 990000 "x")))))
  afterLimit <- restoreRunProjection store association
  observations store >>= check "checkpoint overflow preserves all committed evidence and observations" . (==beforeLimit)
  check "bounded checkpoint refuses without prefix truncation" (case overflow of Left _ -> afterLimit==Just restored; _ -> False)
  oversized <- try @StoreFailure (ingestRuntimeEnvelope store association (encodeEnvelope large<>" "))
  check "oversized frame refuses explicitly" (case oversized of Left _ -> True; _ -> False)

corruptionChecks :: CoordinationStore -> IO ()
corruptionChecks store = do
  emptyAssociation <- seed store "empty_corrupt" (RunId "empty-corrupt")
  runTransaction store $ do
    execute "UPDATE runs SET runtime_snapshot=X'',snapshot_version=1 WHERE id='run_empty_corrupt'" []
    pure ((),[Invalidation "run.changed" "/v1/runs/run_empty_corrupt" "corrupt-fixture"])
  emptyResult <- try @StoreFailure (restoreRunProjection store emptyAssociation)
  check "empty versioned projection cannot masquerade as absent Runtime evidence" (case emptyResult of Left StoreIntegrity -> True; _ -> False)
  association <- seed store "corrupt" (RunId "corrupt")
  let wire=encodeEnvelope (Envelope 1 (associationNative association) (SeqNo 0) "2026-09-03T00:00:00Z" (RunStarted "review" "scripted"))
  void (ingestRuntimeEnvelope store association wire)
  forM_ ["UPDATE ingestions SET envelope_digest='broken' WHERE run_id='run_corrupt'","DELETE FROM ingestions WHERE run_id='run_corrupt'"] $ \sql -> do
    result <- try @StoreFailure $ runTransaction store $ execute sql [] >> pure ((),[Invalidation "run.changed" "/v1/runs/run_corrupt" "bad"])
    check "committed envelope identity and prefix cannot be edited or deleted" (case result of Left _ -> True; _ -> False)
  runTransaction store $ do
    execute "UPDATE runs SET runtime_snapshot=? WHERE id='run_corrupt'" [SQL.SQLBlob (BL.toStrict (encode ("not a checkpoint"::Text)))]
    pure ((),[Invalidation "run.changed" "/v1/runs/run_corrupt" "corrupt-fixture"])
  refused <- try @StoreFailure (restoreRunProjection store association)
  check "corrupt projection boundary refuses hydration" (case refused of Left StoreIntegrity -> True; _ -> False)

-- Exact compiled instrumentation pauses only this caller, outside Store transactions.
concurrentIngestionChecks :: FilePath -> CoordinationStore -> IO ()
concurrentIngestionChecks source store = do
  wires <- BSC.lines <$> BS.readFile (source </> "test/fixtures/runtime/protocol-v2/progress.ndjson")
  envelopes <- right (traverse (decodeEnvelopeFor [1,2]) wires)
  firstEnvelope <- first envelopes
  association <- seed store "same_run_concurrent" (envelopeRunId firstEnvelope)
  mapM_ (ingestRuntimeEnvelope store association) (take 2 wires)
  fixed <- restoreRunProjection store association
  Audit.withReviewAudit "state-prefix" $ \audit ->
    bracket (async (restoreRunProjection store association)) cancel $ \reader -> do
      _ <- Audit.waitReviewed audit
      ingestRuntimeEnvelope store association (wires!!2) >>= check "same run advances while fixed-prefix restoration is paused"
      Audit.releaseReviewed audit
      wait reader >>= check "fixed-prefix restoration returns coherent captured boundary after same-run advance" . (==fixed)
  earlier <- evidence
  Audit.withReviewAudit "state-publication" $ \audit ->
    bracket (async (try @StoreFailure (ingestRuntimeEnvelope store association (wires!!3)))) cancel $ \writer -> do
      _ <- Audit.waitReviewed audit
      ingestRuntimeEnvelope store association (wires!!3) >>= check "competing same-run writer commits original next input"
      ingestRuntimeEnvelope store association (wires!!4) >>= check "competing same-run writer advances beyond paused fold"
      advanced <- restoreRunProjection store association
      facts <- observations store
      Audit.releaseReviewed audit
      wait writer >>= check "stale concurrent publication returns explicit StoreBusy" . (==Left StoreBusy)
      ingestRuntimeEnvelope store association (wires!!3) >>= check "explicit retry of retained competing input is exact duplicate" . not
      restoreRunProjection store association >>= check "competing publication preserves advanced boundary and exact earlier evidence" . (==advanced)
      observations store >>= check "retry duplicate cannot backfill observations or invalidations" . (==facts)
      evidence >>= check "same-run advance cannot mutate earlier original digests or bytes" . (==earlier)
  final <- restoreRunProjection store association >>= maybe (error "missing concurrent projection") pure
  expected <- right (captureSnapshotCheckpoint (associationNative association) (take 5 envelopes))
  check "same-run competing publication equals shared Runtime prefix fold" (final==expected)
  where
    evidence = runRead store $ show <$> query "SELECT sequence,envelope_digest,envelope FROM ingestions WHERE run_id='run_same_run_concurrent' AND sequence IN ('0','1','2') ORDER BY sequence" []
