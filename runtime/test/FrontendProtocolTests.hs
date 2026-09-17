{-# LANGUAGE OverloadedStrings #-}

module FrontendProtocolTests (frontendProtocolTests, frontendCodecCheck) where

import Agentic.Runtime
import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import System.Timeout (timeout)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

frontendCodecCheck :: [String] -> BS.ByteString -> Either Text BS.ByteString
frontendCodecCheck arguments bytes = case arguments of
  ["request"] -> decodeFrontendSetupRequest bytes >>= encodeFrontendSetupRequest
  ["prepared"] -> decodeFrontendPrepared bytes >>= encodeFrontendPrepared
  ["capabilities"] -> decodeFrontendCapabilities bytes >>= encodeFrontendCapabilities
  ["decision", approval] -> do
    start <- decodeFrontendDecision (T.pack approval) bytes
    encodeFrontendDecision (if start then FrontendStart (T.pack approval) else FrontendDiscard (T.pack approval))
  _ -> Left "unknown frontend codec check"

frontendProtocolTests :: IO ()
frontendProtocolTests = do
  descriptor <- BS.readFile "test/fixtures/runtime/descriptor-v2/valid.json" >>= right . eitherDecodeStrict'
  let setup = FrontendSetup "review" "/tmp/state" ["--scripted"] Nothing PersonAnswerLocalControl
        [("subject", Literal "\xfeff雪\r\n"), ("notes", Transport "one\n\n"), ("file", File "/tmp/input")] Nothing
      root = RootSetup setup
      invocation = FrontendInvocation 1 "configured alias 世界" "/trusted/wrapper" ["--profile", "work"]
      edits = [DropAnswer (OccurrenceId 0), ReplaceAnswer (OccurrenceId maxBound) (Bool False), ReplaceAnswer (OccurrenceId 1) Null,
        ReplaceAnswer (OccurrenceId 2) (object ["nested" .= [Bool False, Null]])]
      lineage operation changes = DerivedSetup "/tmp/state" (RunId "parent") operation changes PersonAnswerEngine (Just invocation)
  forM_ [root, RootSetup setup {setupInvocation = Just invocation}, lineage RestartRun [], lineage ResumeRun [], lineage ForkRun edits] $ \value -> do
    bytes <- right (encodeFrontendSetupRequest value)
    check "setup round trip" (decodeFrontendSetupRequest bytes == Right value)
    check "encoder leaves NDJSON delimiter to adapter" (BS.last bytes /= 10)
  check "explicit legacy setup bytes" (encodeFrontendSetupRequestFor 1 root == encodeFrontendSetupRequest root)
  negotiated <- right (encodeFrontendSetupRequestFor 2 root)
  negotiatedValue <- right (eitherDecodeStrict' negotiated)
  check "session v2 selects same preparation facts" (parseEither parseSessionSetup negotiatedValue == Right (2, root))
  left "old parser refuses session v2" (decodeFrontendSetupRequest negotiated)
  left "unknown session encoder refuses" (encodeFrontendSetupRequestFor 3 root)
  check "session protocol domains remain distinct" (sessionRuntimeProtocol 1 == Right 2 && sessionRuntimeProtocol 2 == Right 3)
  check "absent invocation omitted" (field "invocation" (toJSON root) == Nothing)
  check "false replacement exact" (field "answer" (toJSON (edits !! 1)) == Just (Bool False))
  check "null replacement exact" (field "answer" (toJSON (edits !! 2)) == Just Null)
  left "explicit request null invocation refused" (decodeFrontendSetupRequest (bytesOf (put "invocation" Null (toJSON root))))
  left "non-fork edits refused by encoder" (encodeFrontendSetupRequest (lineage ResumeRun edits))
  left "root lineage refused by encoder" (encodeFrontendSetupRequest (lineage RootRun []))
  left "relative file refused by encoder" (encodeFrontendSetupRequest (RootSetup setup {setupInputs = [("file", File "relative")]}))
  left "unknown request field" (parseEither parseSetupRequest (put "future" Null (toJSON root)))
  check "legacy nullable defaults" $
    parseEither parseSetupRequest (put "personAnswering" Null (put "targetKind" Null (toJSON root))) == Right root
  forM_ ["-1", "18446744073709551616", "1.0", "", "000000000000000000000"] $ \occurrence ->
    left "invalid occurrence" (parseEither parseEdit (object ["operation" .= ("drop" :: Text), "occurrenceId" .= (occurrence :: Text)]))
  check "legacy leading-zero occurrence accepted" $
    parseEither parseEdit (object ["operation" .= ("drop" :: Text), "occurrenceId" .= ("0001" :: Text)]) == Right (DropAnswer (OccurrenceId 1))
  forM_ [(FrontendStart "approval", True), (FrontendDiscard "approval", False)] $ \(decision, expected) -> do
    bytes <- right (encodeFrontendDecision decision)
    check "decision round trip" (decodeFrontendDecision "approval" bytes == Right expected)
    check "approval refusal exact" (decodeFrontendDecision "other" bytes == Left "Error in $: frontend approval does not name this prepared execution")
  check "invalid JSON refusal exact" (decodeFrontendSetupRequest "invalid" == Left "frontend request is not valid JSON")
  let rootBytes = bytesOf (toJSON root)
      padding = BS.replicate (maxFrontendQueryBytes - BS.length rootBytes) 32
  check "request at byte bound" (decodeFrontendSetupRequest (rootBytes <> padding) == Right root)
  left "request above byte bound" (decodeFrontendSetupRequest (rootBytes <> padding <> " "))
  let small = RootSetup setup {setupInputs = []}
      room = maxFrontendQueryBytes - BS.length (bytesOf (toJSON small))
      full = RootSetup setup {setupInputs = [], setupWorkflow = "review" <> T.replicate room "x"}
  fullBytes <- right (encodeFrontendSetupRequest full)
  check "encoded request exactly at byte bound" (BS.length fullBytes == maxFrontendQueryBytes)
  check "maximal request round trip" (decodeFrontendSetupRequest fullBytes == Right full)
  left "oversized request encoder" (encodeFrontendSetupRequest (RootSetup setup {setupInputs = [], setupWorkflow = T.replicate maxFrontendQueryBytes "x"}))
  let server = FrontendServer "fixture" "/bin/fixture" "0.1.0.0"
      capabilities = frontendCapabilities server
  encodedCapabilities <- right (encodeFrontendCapabilities capabilities)
  check "capabilities round trip" (decodeFrontendCapabilities encodedCapabilities == Right capabilities)
  check "native capability lists" $
    capabilitySessionOperations capabilities == ["prepare", "prepare-lineage", "start", "discard"]
      && capabilityIoVersions capabilities == [1, 2]
      && capabilityIoOperations capabilities == ["open-root", "read-question", "read-result", "list-runs", "read-run", "read-run-checkpoint", "read-question-schema"]
      && capabilityInputSources capabilities == ["literal", "file", "transport"]
      && capabilityManifestVersions capabilities == [2, 3]
      && capabilityLegacyManifests capabilities
  forM_ ["session", "io", "export"] $ \key -> do
    nested <- maybe (fail "missing capability object") pure (field key (toJSON capabilities))
    left "unknown nested capability field" (decodeFrontendCapabilities (bytesOf (put key (put "future" Null nested) (toJSON capabilities))))
    left "missing nested capability versions" (decodeFrontendCapabilities (bytesOf (put key (delete "versions" nested) (toJSON capabilities))))
  left "wrong capabilities operation" (decodeFrontendCapabilities (bytesOf (put "operation" (String "prepared") (toJSON capabilities))))
  let plan = planValue descriptor
      policy = object ["kind" .= ("routed" :: Text), "scratch" .= Null, "verbose" .= False,
        "realizations" .= [object ["opaque" .= [Null, Bool False]]]]
      prepared = FrontendPrepared "approval" (RunId "run") "opaque-root-identity" "/tmp/cwd" descriptor plan (T.replicate 64 "a") "scripted"
        ["--scripted"] policy PersonAnswerLocalControl server Nothing
        [FrontendPreparedInput "subject" 0 (T.replicate 64 "b"), FrontendPreparedInput "notes" 3 (T.replicate 64 "c")] Nothing
      derived = prepared {preparedInvocation = Just invocation, preparedLineage = Just
        (FrontendPreparedLineage (RunId "parent") ForkRun [DroppedAnswer (OccurrenceId 0), ReplacedAnswer (OccurrenceId maxBound) (T.replicate 64 "d")])}
  forM_ [prepared, derived] $ \value -> do
    bytes <- right (encodeFrontendPrepared value)
    check "prepared round trip" (decodeFrontendPrepared bytes == Right value)
    check "prepared semantic JSON preservation" ((toJSON <$> decodeFrontendPrepared (bytesOf (toJSON value))) == Right (toJSON value))
  negotiatedReply <- right (encodeFrontendPreparedFor 2 prepared)
  check "negotiated prepared round trip" (decodeFrontendPreparedFor 2 negotiatedReply == Right prepared)
  left "prepared reply cannot downgrade session" (decodeFrontendPreparedFor 1 negotiatedReply)
  check "legacy prepared bytes unchanged" (encodeFrontendPreparedFor 1 prepared == encodeFrontendPrepared prepared)
  decision2 <- right (encodeFrontendDecisionFor 2 (FrontendStart "approval")) >>= right . eitherDecodeStrict'
  check "same-session approval" (parseEither (parseSessionDecision 2 "approval") decision2 == Right True)
  left "cross-session approval refused" (parseEither (parseSessionDecision 1 "approval") decision2)
  controlObservationChecks
  check "native null reply invocation retained" (field "invocation" (toJSON prepared) == Just Null)
  forM_ ["approvalId", "runId", "rootIdentity", "cwd", "descriptor", "plan", "programHash", "targetKind", "targetArguments", "policy", "personAnswering", "server", "invocation", "inputs"] $ \key ->
    left "required prepared field" (decodeFrontendPrepared (bytesOf (delete key (toJSON prepared))))
  forM_ ["parentRunId", "lineage", "lineageEdits"] $ \key ->
    left "lineage metadata all-or-none" (decodeFrontendPrepared (bytesOf (delete key (toJSON derived))))
  left "unknown prepared field" (decodeFrontendPrepared (bytesOf (put "future" Null (toJSON prepared))))
  left "invalid exact plan" (encodeFrontendPrepared prepared {preparedPlan = delete "fold" plan})
  left "non-object policy" (encodeFrontendPrepared prepared {preparedPolicy = Bool False})
  left "bad digest" (encodeFrontendPrepared prepared {preparedProgramHash = T.replicate 64 "A"})
  left "negative input bytes" (encodeFrontendPrepared prepared {preparedInputs = [FrontendPreparedInput "x" (-1) (T.replicate 64 "a")]})
  left "duplicate input metadata" (encodeFrontendPrepared prepared {preparedInputs = preparedInputs prepared <> preparedInputs prepared})
  left "aggregate input bound" (encodeFrontendPrepared prepared {preparedInputs =
    [FrontendPreparedInput "x" maxArtifactBytes (T.replicate 64 "a"), FrontendPreparedInput "y" 1 (T.replicate 64 "b")]})
  left "reply above byte bound" (decodeFrontendPrepared (BS.replicate (fromInteger maxFrontendReplyBytes + 1) 32))
  let longCount = put "inputs" (toJSON [object ["name" .= ("x" :: Text), "bytes" .= T.replicate 1000000 "9", "sha256" .= T.replicate 64 "a"]]) (toJSON prepared)
      manyInputs = [FrontendPreparedInput ("input-" <> T.pack (show n)) 0 (T.replicate 64 "a") | n <- [0 .. 32767 :: Int]]
  longResult <- timeout 5000000 (evaluate (decodeFrontendPrepared (bytesOf longCount)))
  maybe (fail "oversized decimal conversion exceeded five seconds") (left "million-digit byte count") longResult
  manyResult <- timeout 5000000 (evaluate (decodeFrontendPrepared (bytesOf (toJSON prepared {preparedInputs = manyInputs}))))
  decodedMany <- maybe (fail "distinct input validation exceeded five seconds") right manyResult
  check "large distinct metadata remains valid" (preparedInputs decodedMany == manyInputs)
  putStrLn "Frontend.Protocol checks passed"

controlObservationChecks :: IO ()
controlObservationChecks = do
  let occurrence = OccurrenceId 0
      attempt = AttemptId occurrence 0
      run = RunId "control-observation"
      envelope n event = Envelope 3 run (SeqNo n) "2026-09-10T00:00:00Z" event
      opening = [envelope 0 (RunStartedV2 "fixture" "fixture" PersonAnswerEngine),
        envelope 1 (OccurrenceStarted occurrence "text" "consult" "engine" "question"),
        envelope 2 (AttemptStarted attempt "fixture")]
      support snapshot = snapshotAttemptSteerable =<<
        (Map.lookup occurrence (snapshotOccurrences snapshot) >>= Map.lookup attempt . snapshotOccurrenceAttempts)
  legacy <- newControlRuntime
  registerControlAttempt legacy attempt (Just (\_ _ -> pure (Right ())))
  check "legacy availability is unknown" . (== Nothing) =<< registeredAttemptSteerability legacy attempt
  unregisterControlAttempt legacy attempt
  observed <- newControlRuntimeFor 3
  registerControlAttempt observed attempt Nothing
  check "registered nonsteerable evidence" . (== Just False) =<< registeredAttemptSteerability observed attempt
  unregisterControlAttempt observed attempt
  registerControlAttempt observed attempt (Just (\_ _ -> pure (Right ())))
  check "registered steerable evidence" . (== Just True) =<< registeredAttemptSteerability observed attempt
  unregisterControlAttempt observed attempt
  check "unregistered attempt has no support" . (== Nothing) =<< registeredAttemptSteerability observed attempt
  prefix <- right (captureSnapshotCheckpoint run opening)
  check "start alone never implies support" (support (checkpointSnapshot prefix) == Nothing)
  ready <- right (appendSnapshotCheckpoint prefix [envelope 3 (AttemptControlAvailability attempt True)])
  check "native availability projected" (support (checkpointSnapshot ready) == Just True)
  restored <- right (encodeSnapshotCheckpoint ready >>= decodeSnapshotCheckpoint)
  check "v3 checkpoint exact restoration" (restored == ready)
  ended <- right (appendSnapshotCheckpoint ready [envelope 4 (AttemptCompleted attempt "fixture")])
  check "completion removes live support" (support (checkpointSnapshot ended) == Just False)
  cancelled <- right (appendSnapshotCheckpoint ready [envelope 4 (RunCancelled "fixture")])
  check "terminal removes live support" (support (checkpointSnapshot cancelled) == Just False)
  left "post-completion availability refused" (appendSnapshotCheckpoint ended [envelope 5 (AttemptControlAvailability attempt True)])
  left "unknown attempt availability refused" (appendSnapshotCheckpoint prefix [envelope 3 (AttemptControlAvailability (AttemptId occurrence 1) True)])
  forM_ [1,2] $ \version -> left "legacy availability encode refused"
    (encodeEnvelopeFor version ((envelope 3 (AttemptControlAvailability attempt True)) {envelopeVersion = version}))
  bytes <- right (encodeEnvelopeFor 3 (envelope 3 (AttemptControlAvailability attempt True)))
  left "old negotiated decoder refuses v3" (decodeEnvelopeFor [1,2] bytes)
  left "observation version does not become control version" (encodeControlFor 3 (Control (ControlId "test") Nothing Nothing CancelRun))
  forM_ [1,2,3] $ \version -> do
    let start=if version==1 then RunStarted "fixture" "fixture" else RunStartedV2 "fixture" "fixture" PersonAnswerEngine
        frame n event=Envelope version run (SeqNo n) "2026-09-10T00:00:00Z" event
        acknowledgement ident command state=if version==1 then ControlAcknowledged ident state "fixture" else ControlAcknowledgedV2 ident state "fixture" command Nothing Nothing
        ordinary n=frame n (acknowledgement ("ordinary_"<>T.pack(show n)) "retryOccurrence" "rejected-stale")
    full<-right(captureSnapshotCheckpoint run (frame 0 start:map ordinary [1..256]))
    check "all versions preserve 256 ordinary acknowledgements" (Map.size(snapshotControlAcks(checkpointSnapshot full))==256)
    left "257th ordinary control is refused" (appendSnapshotCheckpoint full [ordinary 257])
    let cancel=frame 257(acknowledgement "safety_cancel" "cancelRun" "accepted")
    if version/=3 then left "legacy cancellation bound remains 256" (appendSnapshotCheckpoint full [cancel]) else do
      safety<-right(appendSnapshotCheckpoint full [cancel])
      check "v3 has one additional cancel-only slot" (Map.size(snapshotControlAcks(checkpointSnapshot safety))==257)
      restoredSafety<-right(encodeSnapshotCheckpoint safety >>= decodeSnapshotCheckpoint)
      check "v3 safety capacity checkpoint restores exactly" (restoredSafety==safety)
      duplicate<-right(appendSnapshotCheckpoint safety [frame 258(acknowledgement "safety_cancel" "cancelRun" "accepted")])
      check "duplicate saturated cancellation creates no new ID" (Map.size(snapshotControlAcks(checkpointSnapshot duplicate))==257)
      rejected<-right(appendSnapshotCheckpoint safety [frame 258(acknowledgement "safety_cancel" "cancelRun" "unsupported")])
      left "native refusal does not reopen extra cancellation ID" (appendSnapshotCheckpoint rejected [frame 259(acknowledgement "second_cancel" "cancelRun" "accepted")])
      left "saturated correlation cannot change cancellation into ordinary control" (appendSnapshotCheckpoint safety [frame 258(acknowledgement "safety_cancel" "retryOccurrence" "unsupported")])

planValue :: WorkflowDescriptor -> Value
planValue descriptor = put "program" (object []) $ put "codes" Null $ put "fold"
  (toJSON [object ["consults" .= (2 :: Int), "paths" .= (1 :: Int)]]) (toJSON descriptor)

bytesOf :: Value -> BS.ByteString
bytesOf = BL.toStrict . encode

put :: Text -> Value -> Value -> Value
put key value (Object fields) = Object (KM.insert (Key.fromText key) value fields)
put _ _ _ = error "test expected object"

delete :: Text -> Value -> Value
delete key (Object fields) = Object (KM.delete (Key.fromText key) fields)
delete _ _ = error "test expected object"

field :: Text -> Value -> Maybe Value
field key (Object fields) = KM.lookup (Key.fromText key) fields
field _ _ = error "test expected object"

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

left :: Show a => String -> Either e a -> IO ()
left _ (Left _) = pure ()
left label (Right value) = fail (label <> ": accepted " <> show value)

check :: String -> Bool -> IO ()
check label condition = unless condition (fail label)
