{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module ServiceTests (serviceTests) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime (DescriptorCapabilities (..), WorkflowDescriptor (..), WorkflowInputDescriptor (..), WorkflowInputSource (..),
  OccurrenceId (..), AttemptId (..), RunSnapshot (..), OccurrenceSnapshot (..), AttemptSnapshot (..))
import Agentic.Tui.Model
import Agentic.Tui.Presentation (Presentation (..), emptyPresentation, serviceReviewAllowed, serviceReviewRows)
import qualified Agentic.Tui.Service as S
import qualified Agentic.Tui.ServiceLane as L
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay, throwTo)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Time.Clock (addUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified Data.Text.Encoding as TE
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Map.Strict as Map
import System.Exit (die)
import System.Timeout (timeout)

-- | The argument renders one presentation at a fixed terminal size.
serviceTests :: ((Int,Int) -> Presentation -> T.Text) -> IO ()
serviceTests render = do
  value <- BS.readFile "test/fixtures/manager/v1/valid/workflow.json" >>= either die pure . eitherDecodeStrict'
  row <- either (die . show) pure (S.decodeWorkflow value)
  let descriptor = S.workflowDisplay row
      capabilities = workflowCapabilities descriptor
  check "public catalogue keeps its distinct profile/workflow revisions" $
    S.createBody row == object ["workflowId" .= S.workflowId row,
      "descriptorRevision" .= S.workflowRevision row, "profileId" .= S.workflowProfile row,
      "profileRevision" .= S.workflowProfileRevision row]
  check "public catalogue does not manufacture invocation capabilities" $
    null (workflowProtocolVersions descriptor) && null (workflowStoreVersions descriptor)
      && descriptorControlFd capabilities == Nothing && descriptorRoutingJsonVersion capabilities == Nothing
  check "receipt observations remain receipt rather than native ack" (workflowResultCode descriptor == String "receipt")
  check "false capability remains present and false" (not (descriptorEffectful capabilities))
  large <- either (die . show) pure (S.decodeWorkflow (put "size" (String "18446744073709551616") value))
  check "public natural counts are not narrowed to machine words" (workflowSize (S.workflowDisplay large) == 18446744073709551616)
  case S.decodeWorkflow (put "minFold" Null value) of
    Right nullable -> check "required null is distinct from missing" (workflowMinFold (S.workflowDisplay nullable) == Nothing)
    Left _ -> die "FAIL required nullable fold"
  mapM_ (\(label,bad) -> check label (case S.decodeWorkflow bad of Left C.InvalidResponse -> True; _ -> False))
    [ ("missing nullable field refuses", remove "minFold" value),
      ("unknown workflow field refuses", put "invocation" Null value),
      ("unknown API version refuses", put "version" (Number 99) value),
      ("unknown native descriptor version refuses", put "descriptorVersion" (Number 99) value),
      ("numeric rather than decimal count refuses", put "size" (Number 3) value),
      ("noncanonical decimal count refuses", put "size" (String "03") value),
      ("private control descriptor refuses", alter "capabilities" (put "controlFd" (Number 4)) value),
      ("missing false capability refuses", alter "capabilities" (remove "effectful") value),
      ("duplicate input names refuse", alter "inputs" duplicate value),
      ("native ack does not substitute for observation receipt", put "resultCode" (String "ack") value),
      ("duplicate semantic property names refuse", put "resultCode" duplicateSchema value)
    ]
  profile <- either (die . show) pure (S.decodeProfile profileValue)
  check "profile labels preserve Unicode" (S.profileWorkspace profile == "Café 雪 λ")
  check "profile required null cannot disappear" (case S.decodeProfile (remove "refusal" profileValue) of Left C.InvalidResponse -> True; _ -> False)
  let unavailable = profile {S.profileId = "profile_unavailable", S.profileReadiness = "unavailable",
        S.profileRefusal = Just "supervision-unavailable"}
      first = initialServiceModel [profile,unavailable]
      selected = moveSelection 1 first
  check "service model starts without a local invocation configuration" (presentationConfig (emptyPresentation first) == Nothing)
  check "unavailable profiles remain visible observations" (length (browserRows first) == 2 && selectedServiceProfile selected == Just unavailable)
  check "service selection is bounded" (selectedServiceProfile (moveSelection 100 selected) == Just unavailable)
  check "profile detail retains the published refusal" (any (T.isInfixOf "supervision-unavailable") (browserDetailLines selected))
  requestValue <- BS.readFile "test/fixtures/manager/v1/valid/request.json" >>= either die pure . eitherDecodeStrict'
  preparationValue <- BS.readFile "test/fixtures/manager/v1/valid/preparation.json" >>= either die pure . eitherDecodeStrict'
  request0 <- either (die . show) pure (C.decodeObservation requestValue)
  preparation0 <- either (die . show) pure (C.decodeObservation preparationValue)
  let logical = "Café λ — unchanged.\nSecond line."
      bytes = TE.encodeUtf8 logical <> "\n"
      declaration = WorkflowInputDescriptor "subject" DescriptorPrompt
      selectedWorkflowRow = row {S.workflowDisplay = descriptor {workflowInputs = [declaration]}}
      request = request0 {C.draftRevision = C.preparationRequestRevision preparation0,
        C.draftPhase = "review", C.draftPreparation = Just (C.preparationId preparation0),
        C.draftReadiness = C.Readiness [C.InputDeclaration "subject" "prompt"] [C.LiteralValue "subject" logical] [] []}
      reviewInput = C.ReviewInput "subject" "literal" (T.pack (show (BS.length bytes))) (T.pack (show (hash bytes :: Digest SHA256)))
      review = (C.preparationReview preparation0) {C.reviewInputs = [reviewInput]}
      preparation = preparation0 {C.preparationReview = review}
      unframed = reviewInput {C.reviewInputBytes = T.pack (show (BS.length (TE.encodeUtf8 logical))),
        C.reviewInputSha256 = T.pack (show (hash (TE.encodeUtf8 logical) :: Digest SHA256))}
  check "review binds the native prompt LF without changing logical text" (S.reviewMatches selectedWorkflowRow request preparation)
  check "logical-byte hash does not authorize different prompt-transport bytes"
    (not (S.reviewMatches selectedWorkflowRow request (preparation {C.preparationReview = review {C.reviewInputs = [unframed]}})))
  check "review cannot move to another request revision"
    (not (S.reviewMatches selectedWorkflowRow (request {C.draftRevision = "other"}) preparation))
  check "review selectors fit the acceptance terminal in full" (serviceReviewAllowed preparation "\"preprev_1\"" (140,36))
  check "clipped selectors disable approval" (not (serviceReviewAllowed preparation "\"preprev_1\"" (40,8)))
  check "all five exact selectors are rendered" (all (`elem` serviceReviewRows preparation "\"preprev_1\"") (S.approvalSelectors preparation))
  check "approval body preserves the complete binding" (S.approvalBody preparation == object
    ["operation" .= ("approve" :: T.Text), "reviewDigest" .= C.preparationDigest preparation,
     "requestRevision" .= C.preparationRequestRevision preparation, "profileRevision" .= C.preparationProfileRevision preparation,
     "descriptorRevision" .= C.preparationDescriptorRevision preparation, "processGeneration" .= C.preparationGeneration preparation])
  expiry <- maybe (die "invalid fixture expiry") pure (iso8601ParseM (T.unpack (C.preparationExpiresAt preparation)))
  check "review expiry is not extended by a frontend observation"
    (S.reviewLive (addUTCTime (-1) expiry) preparation && not (S.reviewLive expiry preparation))
  receiptValue <- BS.readFile "test/fixtures/manager/v1/valid/request-command.json" >>= either die pure . eitherDecodeStrict'
  receipt <- either (die . show) pure (C.decodeObservation receiptValue)
  let mutation = S.SaveLiteral request "subject" logical 0
  check "receipt remains bound to its operation, resource and profile" (S.receiptMatches mutation receipt)
  check "another receipt operation does not retire the pending attempt" (not (S.receiptMatches (S.Enqueue request) receipt))
  check "accepted intent is not an observed effect" (S.receiptEffectKind receipt == Nothing)
  let unrelatedEffect = object ["kind" .= ("input-changed" :: T.Text), "runtimeSequence" .= Null,
        "address" .= Null, "resource" .= ("/v1/requests/other" :: T.Text)]
  unrelated <- either (die . show) pure (C.decodeObservation (put "state" (String "effect-observed") (put "effect" unrelatedEffect receiptValue)))
  check "effect for another resource cannot advance the input editor" (not (S.receiptMatches mutation unrelated))
  snapshotValue <- BS.readFile "test/fixtures/manager/v1/valid/run-snapshot.json" >>= either die pure . eitherDecodeStrict'
  (metadata,items) <- case snapshotValue of
    Object fields | Just (Array values) <- KM.lookup "items" fields -> pure (Object (KM.delete "page" (KM.delete "items" fields)),V.toList values)
    _ -> die "invalid snapshot fixture shape"
  snapshot <- either (die . show) pure (S.decodeSnapshot metadata items)
  check "public runtime sequence remains exact beyond JavaScript integer precision" (S.runSequence snapshot == Just 9007199254740993)
  native <- maybe (die "missing runtime fixture") pure (S.runSnapshot snapshot)
  occurrence <- maybe (die "missing maximum occurrence") pure (Map.lookup (OccurrenceId maxBound) (snapshotOccurrences native))
  attempt <- maybe (die "missing maximum attempt") pure (Map.lookup (AttemptId (OccurrenceId maxBound) maxBound) (snapshotOccurrenceAttempts occurrence))
  check "snapshot adapter retains exact bounded Unicode output" (snapshotAttemptOutput attempt == "雪😀\n")
  check "public snapshot never manufactures native question or result references"
    (snapshotOccurrencePersonQuestion occurrence == Nothing && snapshotResult native == Nothing && snapshotLastEnvelope native == Nothing)
  absentRuntime <- either (die . show) pure (S.decodeSnapshot (put "runtime" Null metadata) items)
  check "absent runtime does not become a fabricated run status" (S.runSnapshot absentRuntime == Nothing && S.runItems absentRuntime == items)
  check "private occurrence fields refuse" (case S.decodeSnapshot metadata (map (put "questionRef" Null) items) of Left C.InvalidResponse -> True; _ -> False)
  decisionValue <- BS.readFile "test/fixtures/manager/v1/valid/decision.json" >>= either die pure . eitherDecodeStrict'
  controlValue <- BS.readFile "test/fixtures/manager/v1/valid/run-control.json" >>= either die pure . eitherDecodeStrict'
  decision <- either (die . show) pure (S.decodeDecision decisionValue)
  control <- either (die . show) pure (S.decodeControl controlValue)
  check "matched original public head exposes its answer offer" (S.answerOffered control decision)
  check "answer conversion retains typed false" (S.answerValue decision "false" == Right (Bool False))
  check "different decision generation does not acquire an answer offer"
    (not (S.answerOffered control (decision {S.decisionGeneration = "other_generation"})))
  check "non-head decision does not acquire an answer offer"
    (not (S.answerOffered control (decision {S.decisionPosition = 1})))
  check "required nullable question scope does not disappear"
    (case S.decodeDecision (alter "question" (alter "scope" (remove "mode")) decisionValue) of Left C.InvalidResponse -> True; _ -> False)
  laneTests render row profile
  where
    profileValue = object ["version" .= (1 :: Int), "id" .= ("profile_main" :: T.Text),
      "revision" .= ("profile_rev_4" :: T.Text), "workspaceLabel" .= ("Café 雪 λ" :: T.Text),
      "targetLabel" .= ("local fixture" :: T.Text), "readiness" .= ("ready" :: T.Text), "refusal" .= Null]
    property rest = object ["property" .= object ["name" .= ("same" :: T.Text),
      "schema" .= ("boolean" :: T.Text), "rest" .= rest]]
    duplicateSchema = object ["json" .= object ["schema" .= property (property (String "object"))]]
    duplicate (Array values) = Array (values V.++ values)
    duplicate other = other

put :: Key.Key -> Value -> Value -> Value
put key value (Object fields) = Object (KM.insert key value fields)
put _ _ other = other

remove :: Key.Key -> Value -> Value
remove key (Object fields) = Object (KM.delete key fields)
remove _ other = other

alter :: Key.Key -> (Value -> Value) -> Value -> Value
alter key f value@(Object fields) = put key (f (maybe Null id (KM.lookup key fields))) value
alter _ _ other = other

-- | Model and fixed-size render tests for call classification and the
-- command lane. Pending commands and locations are opaque markers here.
laneTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Workflow -> S.Profile -> IO ()
laneTests render row profile = do
  let marker = "PRIVATE-FAULT-MARKER-5c1e" :: String
      markerText = T.pack marker
      isFault outcome = case outcome of L.InternalFault -> True; _ -> False
  userFault <- L.serviceCall (ioError (userError marker) :: IO (Either C.ClientFailure Int))
  check "injected userError is an internal fault, not transport uncertainty" (isFault userFault)
  errorFault <- L.serviceCall (throwIO (ErrorCall marker) :: IO (Either C.ClientFailure Int))
  check "injected ErrorCall is an internal fault, not transport uncertainty" (isFault errorFault)
  lazyFault <- L.serviceCall (pure (Right (error marker)) :: IO (Either C.ClientFailure Int))
  check "a failing returned payload is an internal fault" (isFault lazyFault)
  declared <- L.serviceCall (pure (Left C.TransportUnavailable) :: IO (Either C.ClientFailure Int))
  check "returned TransportUnavailable stays declared" (declared == L.Declared (Left C.TransportUnavailable))
  thrown <- L.serviceCall (throwIO (C.Refused 409 "state-conflict") :: IO (Either C.ClientFailure Int))
  check "thrown declared ClientFailure stays that declared failure" (thrown == L.Declared (Left (C.Refused 409 "state-conflict")))
  value <- L.serviceCall (pure (Right 7) :: IO (Either C.ClientFailure Int))
  check "returned value stays declared" (value == L.Declared (Right 7))
  synchronousAsync <- try @SomeException (L.serviceCall (throwIO ThreadKilled :: IO (Either C.ClientFailure Int)))
  check "a thrown asynchronous exception is rethrown"
    (either (\problem -> fromException problem == Just ThreadKilled) (const False) synchronousAsync)
  started <- newEmptyMVar
  finished <- newEmptyMVar
  worker <- forkIO $ try @SomeException (L.serviceCall (putMVar started () >> threadDelay 30000000 >> pure (Right ())))
    >>= putMVar finished . either (Just . fromException) (const Nothing)
  takeMVar started
  throwTo worker ThreadKilled
  delivered <- timeout 10000000 (takeMVar finished)
  check "a delivered asynchronous exception propagates through the call" (delivered == Just (Just (Just ThreadKilled)))
  -- Every lane state below comes from an outcome that serviceCall classified
  -- from an injected exception carrying the private marker.
  let create = S.Create row
      original = "pending-original" :: T.Text
      location = "/v1/commands/cmd_original" :: T.Text
      retained = L.Attempt create original (Just location)
      laneWith ticket mutation = L.Lane ticket mutation False False :: L.Lane T.Text T.Text
      sendingLane = laneWith Nothing (L.MutationSending 7 retained)
      priorUncertain = L.MutationUncertain retained (L.DeclaredUncertainty "TransportUnavailable")
      awaiting = L.MutationAwaiting create original location
  sendFault <- L.serviceCall (ioError (userError marker) :: IO (Either C.ClientFailure Int))
  readFault <- L.serviceCall (throwIO (ErrorCall marker) :: IO (Either C.ClientFailure Int))
  prepareFault <- L.serviceCall (ioError (userError marker) :: IO (Either C.ClientFailure T.Text))
  let (sendFaultStep,sendFaultLane) = L.sendStep 7 sendFault sendingLane
      (declaredStep,declaredLane) = L.sendStep 7 (L.Declared (Left C.TransportUnavailable)) sendingLane
      (readFaultStep,readFaultLane) = L.readStep 5 readFault ((laneWith (Just 5) priorUncertain) {L.laneResendConfirm = True})
      (awaitingFaultStep,awaitingFaultLane) = L.readStep 5 readFault (laneWith (Just 5) awaiting)
      (prepareFaultStep,prepareFaultLane) = L.prepareStep 3 prepareFault (laneWith Nothing (L.MutationPreparing 3 create))
  checks
    [ ("declared send failure keeps its present treatment and drops the earlier receipt location",
        case (declaredStep,L.laneMutation declaredLane) of
          (L.SendUncertain,L.MutationUncertain attempt (L.DeclaredUncertainty _)) ->
            L.attemptLocation attempt == Nothing && L.attemptPending attempt == original
          _ -> False),
      ("read fault over an accepted intent names the awaiting command",
        let notice = L.faultScreen awaitingFaultLane
        in all (`T.isInfixOf` notice) ["accepted the create intent", "/v1/requests", "not yet observed"]),
      ("fault status names only what remains available",
        L.internalFaultStatus == "internal frontend fault: read-only actions remain and no mutation starts")
    ]
  check "send fault retains the original pending command, operation, URI and receipt location"
    (case (sendFaultStep,L.laneMutation sendFaultLane) of
      (L.SendFaulted,L.MutationUncertain attempt L.FaultUncertainty) ->
        L.attemptPending attempt == original && L.attemptLocation attempt == Just location
          && S.mutationOperation (L.attemptMutation attempt) == "create" && S.mutationURI (L.attemptMutation attempt) == "/v1/requests"
          && L.laneFault sendFaultLane
      _ -> False)
  check "send fault offers no ordinary exact resend"
    (not (L.resendOffered sendFaultLane) && not (L.resendOffered sendFaultLane {L.laneFault = False})
      && L.mutationNotice sendFaultLane == Just ("create", "/v1/requests", False))
  check "declared TransportUnavailable keeps ordinary uncertainty with the exact resend offered"
    (L.resendOffered declaredLane && fmap L.attemptPending (L.resendAttempt declaredLane) == Just original
      && not (L.laneFault declaredLane) && L.mutationNotice declaredLane == Just ("create", "/v1/requests", True))
  check "a session fault withdraws the declared exact resend" (not (L.resendOffered (L.faultLane declaredLane)))
  check "a stale send result does not touch the lane"
    (case L.sendStep 8 sendFault sendingLane of (L.SendStale,lane) -> laneShape lane == laneShape sendingLane; _ -> False)
  check "preparation fault sends nothing and creates no uncertainty"
    (case (prepareFaultStep,L.laneMutation prepareFaultLane) of
      (L.PrepareFaulted,L.MutationIdle) -> L.laneFault prepareFaultLane && L.mutationNotice prepareFaultLane == Nothing
      _ -> False)
  check "declared preparation refusal stays a refusal and leaves no fault"
    (case L.prepareStep 3 (L.Declared (Left C.TransportUnavailable)) (laneWith Nothing (L.MutationPreparing 3 create)) of
      (L.PrepareRefused C.TransportUnavailable,lane) -> laneShape lane == laneShape (laneWith Nothing L.MutationIdle); _ -> False)
  check "a prepared command starts one new attempt without a prior location"
    (case L.prepareStep 3 (L.Declared (Right original)) (laneWith Nothing (L.MutationPreparing 3 create)) of
      (L.PrepareSend attempt,_) -> L.attemptPending attempt == original && L.attemptLocation attempt == Nothing; _ -> False)
  check "no mutation starts after a fault"
    (L.mutationAllowed (laneWith Nothing L.MutationIdle) && not (L.mutationAllowed (L.faultLane (laneWith Nothing L.MutationIdle))))
  check "read fault clears the read ticket and any resend confirmation, records the fault, and keeps the prior command state"
    (case readFaultStep of
      L.ReadFaulted -> laneShape readFaultLane == laneShape ((laneWith Nothing priorUncertain) {L.laneFault = True})
      _ -> False)
  check "read fault keeps an accepted intent unchanged"
    (case awaitingFaultStep of
      L.ReadFaulted -> laneShape awaitingFaultLane == laneShape ((laneWith Nothing awaiting) {L.laneFault = True})
      _ -> False)
  check "declared read refusal stays a refusal, ends the ticket and leaves no fault"
    (case L.readStep 5 (L.Declared (Left C.TransportUnavailable) :: L.CallOutcome Int) (laneWith (Just 5) priorUncertain) of
      (L.ReadRefused C.TransportUnavailable,lane) -> laneShape lane == laneShape (laneWith Nothing priorUncertain); _ -> False)
  check "a stale read does not touch the lane"
    (case L.readStep 5 readFault (laneWith (Just 6) priorUncertain) of
      (L.ReadStale,lane) -> laneShape lane == laneShape (laneWith (Just 6) priorUncertain); _ -> False)
  nestedDeclared <- L.serviceCall (Right <$> L.declaredCall (throwIO (C.Refused 403 "receipt-hidden") :: IO (Either C.ClientFailure Int)))
  check "a nested declared receipt failure stays in its slot"
    (nestedDeclared == L.Declared (Right (Left (C.Refused 403 "receipt-hidden"))))
  nestedFault <- L.serviceCall (Right <$> L.declaredCall (ioError (userError marker) :: IO (Either C.ClientFailure Int)))
  check "an undeclared exception in a nested receipt read faults the whole read" (isFault nestedFault)
  check "shutdown names the internal fault and the retained uncertainty"
    (L.shutdownNotices True True == ["The frontend stopped manager operations after an internal frontend fault.",
      "Manager command outcome may be uncertain. The manager run was not cancelled."]
      && L.shutdownNotices True False == ["Manager command outcome may be uncertain. The manager run was not cancelled."]
      && null (L.shutdownNotices False False))
  -- The presentation takes the fault notice, fault flag, command notice and
  -- resend confirmation from the lane, as the application does.
  let serviceModel = initialServiceModel [profile]
      lanePresentation notice lane = (emptyPresentation (serviceModel {modelScreen = ServiceCommandScreen notice}))
        {presentationService = True, presentationServiceFault = L.laneFault lane, presentationServiceMutation = L.mutationNotice lane,
          presentationServiceResendConfirm = L.laneResendConfirm lane, presentationNoColor = True}
      faultPresentation lane = lanePresentation (L.faultScreen lane) lane
      states =
        [ ("read fault over an unresolved command", readFaultLane, ["Outcome unresolved: TransportUnavailable", "Original create attempt retained.", "No exact resend is offered."]),
          ("read fault over an accepted intent", awaitingFaultLane, ["The manager accepted the create intent for /v1/requests."]),
          ("preparation fault", prepareFaultLane, ["sent no mutation for it"]),
          ("send fault", sendFaultLane, ["Outcome unresolved after an internal frontend fault.", "Original create attempt retained.", "/v1/requests"])
        ]
  mapM_ (\(label,lane,expected) -> mapM_ (\size -> do
      let frame = render size (faultPresentation lane)
      check (label <> " render at " <> show size <> " names the fixed internal fault and the retained command")
        (all (`T.isInfixOf` frame) (L.internalFaultStatus : "Internal frontend fault" : expected))
      check (label <> " render at " <> show size <> " contains no private text and no resend offer")
        (not (markerText `T.isInfixOf` frame) && not ("RESEND" `T.isInfixOf` frame) && not ("x requests" `T.isInfixOf` frame)))
    [(100,30),(80,24)]) states
  mapM_ (\(label,lane,_) -> putStrLn ("RENDER " <> label <> " at (80,24):") >> putStr (T.unpack (render (80,24) (faultPresentation lane)))) states
  let declaredFrame = render (100,30) (lanePresentation (maybe "" id (L.unresolvedNotice declaredLane)) declaredLane)
  check "declared uncertainty control render offers the exact resend and names no fault"
    ("x EXACT RESEND" `T.isInfixOf` declaredFrame && "x requests an exact resend" `T.isInfixOf` declaredFrame
      && not ("nternal frontend fault" `T.isInfixOf` declaredFrame))

-- | A comparable summary of a lane whose pending commands and locations are
-- text markers.
laneShape :: L.Lane T.Text T.Text -> (Maybe Int, Bool, Bool, String)
laneShape lane = (L.laneReadTicket lane, L.laneFault lane, L.laneResendConfirm lane, mutationShape (L.laneMutation lane))
  where
    mutationShape state = case state of
      L.MutationIdle -> "idle"
      L.MutationPreparing ticket mutation -> unwords ["preparing", show ticket, operation mutation]
      L.MutationSending ticket attempt -> unwords ["sending", show ticket, attemptShape attempt]
      L.MutationAwaiting mutation pending location -> unwords ["awaiting", operation mutation, show pending, show location]
      L.MutationUncertain attempt cause -> unwords ["uncertain", attemptShape attempt, show cause]
    operation mutation = T.unpack (S.mutationOperation mutation <> " " <> S.mutationURI mutation)
    attemptShape attempt = unwords [operation (L.attemptMutation attempt), show (L.attemptPending attempt), show (L.attemptLocation attempt)]

check :: String -> Bool -> IO ()
check label passed = unless passed (die ("FAIL " <> label)) >> putStrLn ("PASS " <> label)

-- | Report every check in the group, then stop if any failed.
checks :: [(String,Bool)] -> IO ()
checks group = do
  mapM_ (\(label,passed) -> putStrLn ((if passed then "PASS " else "FAIL ") <> label)) group
  unless (all snd group) (die ("FAIL " <> show (length (filter (not . snd) group)) <> " checks in the group"))
