{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module ServiceTests (serviceTests) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime (DescriptorCapabilities (..), WorkflowDescriptor (..), WorkflowInputDescriptor (..), WorkflowInputSource (..),
  OccurrenceId (..), AttemptId (..), RunSnapshot (..), OccurrenceSnapshot (..), AttemptSnapshot (..))
import Agentic.Tui.Model
import qualified Agentic.Tui.Approval as A
import Agentic.Tui.Presentation (ActiveLayer (..), Presentation (..), emptyPresentation, serviceReviewAllowed, serviceReviewRows, wrapDisplayLines)
import qualified Agentic.Tui.Service as S
import qualified Agentic.Tui.ServiceLane as L
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay, throwTo)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, fromException, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified Data.Text.Encoding as TE
import Data.Aeson (Value (..), eitherDecodeStrict', object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as Vty
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
  approvalTests render profile selectedWorkflowRow request preparation expiry
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

-- | Model and fixed-size render tests for approval-key admissibility on the
-- exact manager review. The expected notice texts are written out here, so a
-- change to any fixed text fails a check.
approvalTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> S.Workflow -> C.DraftView -> C.Preparation -> UTCTime -> IO ()
approvalTests render profile row request preparation expiry = do
  let live = addUTCTime (-1) expiry
      tag = "\"preprev_1\"" :: T.Text
      literals = S.literalInputs request
      review now fits installed draft inputs = A.checkReview id now fits (Just row) (fmap ((,) ()) draft) installed inputs preparation tag
  check "a current, live, bound and complete review is current and yields its request and validator"
    (case review live True (Just (tag,preparation)) (Just request) literals of
      A.ReviewCurrent (draft,validator) -> draft == request && validator == tag; _ -> False)
  checks
    [ ("another installed validator makes the displayed review stale",
        review live True (Just ("\"preprev_2\"",preparation)) (Just request) literals == A.ReviewStale),
      ("another installed preparation makes the displayed review stale",
        review live True (Just (tag,preparation {C.preparationDigest = "other"})) (Just request) literals == A.ReviewStale),
      ("a missing installed preparation makes the displayed review stale",
        review live True Nothing (Just request) literals == A.ReviewStale),
      ("a missing installed request makes the displayed review stale",
        review live True (Just (tag,preparation)) Nothing literals == A.ReviewStale),
      ("a missing workflow makes the displayed review stale",
        A.checkReview id live True Nothing (Just ((),request)) (Just (tag,preparation)) literals preparation tag == A.ReviewStale),
      ("a review at its expiry is expired", review expiry True (Just (tag,preparation)) (Just request) literals == A.ReviewExpired),
      ("a review for another request revision is mismatched",
        review live True (Just (tag,preparation)) (Just (request {C.draftRevision = "other"})) literals == A.ReviewMismatched),
      ("a review for other operator literals is mismatched",
        review live True (Just (tag,preparation)) (Just request) (Map.insert "subject" "other" literals) == A.ReviewMismatched),
      ("a review that does not fit is clipped", review live False (Just (tag,preparation)) (Just request) literals == A.ReviewClipped),
      ("the clipped acceptance size supplies a review that does not fit",
        not (serviceReviewAllowed preparation tag (40,8)) && serviceReviewAllowed preparation tag (140,36))
    ]
  checks
    [ ("Enter without modifiers is the Enter approval key", A.approvalKey Vty.KEnter [] == Just A.EnterKey),
      ("y without modifiers is the approval key", A.approvalKey (Vty.KChar 'y') [] == Just A.ApproveKey),
      ("other keys are not approval keys",
        all (\(key,modifiers) -> A.approvalKey key modifiers == Nothing)
          [(Vty.KChar 'Y',[]), (Vty.KChar 'y',[Vty.MCtrl]), (Vty.KChar 'n',[]), (Vty.KChar 'd',[]), (Vty.KEsc,[])]),
      ("the key help covers either review view, and the detail flag selects the detail view",
        A.reviewView True False == A.KeyHelpView && A.reviewView True True == A.KeyHelpView
          && A.reviewView False True == A.DetailView && A.reviewView False False == A.SummaryView)
    ]
  let create = S.Create row
      approve = S.Approve request preparation
      attempt = L.Attempt create ("pending" :: T.Text) (Just ("/v1/commands/cmd_1" :: T.Text))
      preparingApproval = L.MutationPreparing 3 approve :: L.MutationState T.Text T.Text
      mutations =
        [ ("idle", L.MutationIdle), ("preparing", L.MutationPreparing 3 create), ("preparing approval", preparingApproval),
          ("sending", L.MutationSending 3 attempt), ("awaiting", L.MutationAwaiting create "pending" "/v1/commands/cmd_1"),
          ("declared uncertainty", L.MutationUncertain attempt (L.DeclaredUncertainty "TransportUnavailable")),
          ("fault uncertainty", L.MutationUncertain attempt L.FaultUncertainty) ]
      reviews =
        [ ("current", A.ReviewCurrent ()), ("stale", A.ReviewStale), ("expired", A.ReviewExpired),
          ("mismatched", A.ReviewMismatched), ("clipped", A.ReviewClipped) ] :: [(String, A.ReviewCheck ())]
      reviewScreen = ServiceReviewScreen preparation tag
      screens =
        [ ("initial loading", InitialLoading), ("browser", BrowserScreen), ("profiles", ServiceProfilesScreen [profile] 0),
          ("request", ServiceRequestScreen request), ("review", reviewScreen), ("command", ServiceCommandScreen "notice"),
          ("input", InputScreen 0), ("target", TargetScreen), ("preview loading", PreviewLoading), ("help loading", HelpLoading),
          ("workflow help", HelpScreen "help"), ("failure", FailureScreen "failure") ] :: [(String, Screen)]
      keys =
        [ ("Enter", Vty.KEnter, []), ("y", Vty.KChar 'y', []), ("Y", Vty.KChar 'Y', []),
          ("Ctrl-y", Vty.KChar 'y', [Vty.MCtrl]), ("Meta-Enter", Vty.KEnter, [Vty.MMeta]) ] :: [(String, Vty.Key, [Vty.Modifier])]
      views = [minBound .. maxBound] :: [A.ReviewView]
      cases = [ (screen,key,view,mutation,readTicket,faulted,checked)
              | screen <- screens, key <- keys, view <- views, mutation <- mutations,
                readTicket <- [Nothing, Just 4], faulted <- [False,True], checked <- reviews ]
      laneOf (_,m) readTicket faulted = L.Lane readTicket m faulted False :: L.Lane T.Text T.Text
      press ((_,screen),(_,key,modifiers),_,_,_,_,_) = A.reviewApprovalKey screen key modifiers
      -- The outcome of one case: Nothing when the press is not an approval
      -- press and keeps its other meaning, otherwise the decision.
      decide c@(_,_,view,mutation,readTicket,faulted,(_,checked)) =
        fmap (\(approval,_,_) -> A.approvalDecision approval view (laneOf mutation readTicket faulted) checked) (press c)
      onReview ((name,_),_,_,_,_,_,_) = name == ("review" :: String)
      keyName (_,(name,_,_),_,_,_,_,_) = name :: String
      viewOf (_,_,view,_,_,_,_) = view
      idle (name,_) = name == ("idle" :: String)
      approves outcome = case outcome of Just (A.Approve ()) -> True; _ -> False
      refuses refusal outcome = outcome == Just (A.Refuse refusal)
      fixedText refusal = case refusal of
        A.EnterRefused -> "Enter does not approve; y approves the exact review"
        A.EnterDetailRefused -> "Enter does not approve; Esc returns to the summary, where y approves"
        A.DetailRefused -> "y does not approve in the detail view"
        A.HelpRefused -> "Approval did not start: the key help is open. Esc closes it."
        A.CommandBusy -> "Approval did not start: a manager command is in progress or unresolved."
        A.FaultStopped -> "Approval did not start: an internal frontend fault stopped all mutations."
        A.StaleReview -> "Approval did not start: the displayed review is stale."
        A.ExpiredReview -> "Approval did not start: the displayed review has expired or is no longer live."
        A.MismatchedReview -> "Approval did not start: the review does not match the request and its literals."
        A.ClippedReview -> "Approval did not start: the complete review does not fit. Resize the terminal." :: T.Text
      startText = "Approval started for the exact displayed review." :: T.Text
      notSentText = "Approval was not sent: the preflight check refused it before any send." :: T.Text
      expectedReviewRefusal name = case name of
        "stale" -> Just A.StaleReview; "expired" -> Just A.ExpiredReview
        "mismatched" -> Just A.MismatchedReview; "clipped" -> Just A.ClippedReview; _ -> Nothing
      reviewCases = filter onReview cases
  -- A fixture-shape guard: the enumeration must keep every dimension.
  check "the enumeration spans 12 screens, 5 keys, 3 views, 7 command states, 2 read states, 2 fault states and 5 review states"
    ((length screens, length keys, length views, length mutations, length reviews, length cases) == (12, 5, 3, 7, 5, 12 * 5 * 3 * 7 * 2 * 2 * 5))
  checks
    [ ("only an unmodified Enter or y on the review screen reaches the predicate, with the displayed review and validator",
        and [ fmap (\(approval,displayed,shownTag) -> (approval, displayed == preparation && shownTag == tag)) (press c)
                == if onReview c then lookup (keyName c) [("Enter",(A.EnterKey,True)),("y",(A.ApproveKey,True))] else Nothing
            | c <- cases ]),
      ("Enter on the review always refuses, whatever the view, command, read, fault and review state",
        and [not (approves (decide c)) && decide c /= Nothing | c <- reviewCases, keyName c == "Enter"]),
      ("Enter in the summary refuses with the summary Enter text",
        and [refuses A.EnterRefused (decide c) | c <- reviewCases, keyName c == "Enter", viewOf c == A.SummaryView]),
      ("Enter in the detail view refuses without pointing to y in that view",
        and [refuses A.EnterDetailRefused (decide c) | c <- reviewCases, keyName c == "Enter", viewOf c == A.DetailView]),
      ("y in the detail view always refuses, including while a read is in flight",
        and [refuses A.DetailRefused (decide c) | c <- reviewCases, keyName c == "y", viewOf c == A.DetailView]
          && not (null [() | c@(_,_,A.DetailView,_,Just _,_,_) <- reviewCases, keyName c == "y"])),
      ("every approval key under the key help refuses",
        and [refuses A.HelpRefused (decide c) | c <- reviewCases, keyName c `elem` ["Enter","y"], viewOf c == A.KeyHelpView]),
      ("no forbidden-key refusal depends on the command, read, fault or review state",
        and [ length (foldr (\x acc -> if x `elem` acc then acc else x : acc) []
                [decide c | c@(_,(name,_,_),view,_,_,_,_) <- reviewCases, name == kname, view == v]) == 1
            | kname <- ["Enter","y"], v <- views, not (kname == "y" && v == A.SummaryView) ]),
      ("approval occurs only for summary y on the review with a current review and an idle lane without a fault",
        and [approves (decide c) == (onReview c && keyName c == "y" && view == A.SummaryView && idle mutation && not faulted && name == "current")
            | c@(_,_,view,mutation,_,faulted,(name,_)) <- cases]),
      ("a read in flight changes no outcome",
        and [decide (screen,key,view,mutation,Nothing,faulted,checked) == decide (screen,key,view,mutation,Just 4,faulted,checked)
            | (screen,key,view,mutation,_,faulted,checked) <- cases]),
      ("a summary y during a command refuses as busy before any review fact",
        and [refuses A.CommandBusy (decide c) | c@(_,_,A.SummaryView,mutation,_,_,_) <- reviewCases, keyName c == "y", not (idle mutation)]),
      ("a summary y after an internal fault refuses before any review fact",
        and [refuses A.FaultStopped (decide c) | c@(_,_,A.SummaryView,mutation,_,True,_) <- reviewCases, keyName c == "y", idle mutation]),
      ("a summary y on an idle lane refuses a stale, expired, mismatched or clipped review by name",
        and [fmap A.Refuse (expectedReviewRefusal name) == decide c
            | c@(_,_,A.SummaryView,mutation,_,False,(name,_)) <- reviewCases, keyName c == "y", idle mutation, name /= "current"]),
      ("every non-approve outcome carries its fixed notice text and the key number",
        and [A.decisionNotice 7 outcome == A.KeyNotice 7 (fixedText refusal) | c <- cases, Just outcome@(A.Refuse refusal) <- [decide c]]),
      ("an approval start carries its own fixed notice", A.decisionNotice 7 (A.Approve ()) == A.KeyNotice 7 startText),
      ("the approval hint is offered exactly when summary y would approve",
        and [A.approvalOffered view (laneOf mutation readTicket faulted) checked == approves (decide c)
            | c@(_,(name,_,_),view,mutation,readTicket,faulted,(_,checked)) <- reviewCases, name == "y"]),
      ("the notice line names the key number", A.noticeLine (A.KeyNotice 12 "text") == "Approval key 12: text"),
      ("every fixed text is listed for layout reservation",
        all (`elem` A.noticeTexts) (startText : notSentText : map fixedText [minBound .. maxBound]))
    ]
  -- An approval that the preflight refuses returns to idle before any send.
  checks
    [ ("a preflight refusal returns the approval of its press to idle before any send",
        A.unsentApproval (Just 5) preparingApproval L.MutationIdle == Just 5),
      ("an approval that proceeds to its send is not unsent",
        A.unsentApproval (Just 5) preparingApproval (L.MutationSending 3 attempt) == Nothing),
      ("an approval that stays in preparation is not unsent", A.unsentApproval (Just 5) preparingApproval preparingApproval == Nothing),
      ("another preparing mutation that returns to idle is not an unsent approval",
        A.unsentApproval (Just 5) (L.MutationPreparing 3 create) (L.MutationIdle :: L.MutationState T.Text T.Text) == Nothing),
      ("an idle lane is not an unsent approval", A.unsentApproval (Just 5) L.MutationIdle (L.MutationIdle :: L.MutationState T.Text T.Text) == Nothing)
    ]
  -- The notice lifetime over key presses, observation installs, ticks and
  -- the preflight of an approval.
  let renewedScreen = ServiceReviewScreen preparation "\"preprev_2\""
      requestScreen = ServiceRequestScreen request
      first = A.KeyNotice 1 (fixedText A.EnterRefused)
      second = A.KeyNotice 2 (fixedText A.DetailRefused)
      started = A.KeyNotice 3 startText
      busy = A.KeyNotice 4 (fixedText A.CommandBusy)
      notSent = A.KeyNotice 3 notSentText
      summary screen = (screen, False)
      detailed screen = (screen, True)
      event keyPress before after shown unsent = A.NoticeEvent keyPress before after shown unsent
  checks
    [ ("the key that produced a notice keeps it",
        A.retainNotice (event True (summary reviewScreen) (summary reviewScreen) True Nothing) Nothing (Just first) == Just first),
      ("an installed observation that renews the review keeps the notice",
        A.retainNotice (event False (summary reviewScreen) (summary renewedScreen) True Nothing) (Just first) (Just first) == Just first),
      ("a tick keeps the notice",
        A.retainNotice (event False (summary reviewScreen) (summary reviewScreen) True Nothing) (Just first) (Just first) == Just first),
      ("a key that changes neither screen nor mode keeps the notice",
        A.retainNotice (event True (detailed reviewScreen) (detailed reviewScreen) True Nothing) (Just first) (Just first) == Just first),
      ("a key that changes the mode ends the notice",
        A.retainNotice (event True (summary reviewScreen) (detailed reviewScreen) True Nothing) (Just first) (Just first) == Nothing),
      ("a key that changes the screen ends the notice",
        A.retainNotice (event True (summary reviewScreen) (summary requestScreen) False Nothing) (Just first) (Just first) == Nothing),
      ("an installed observation that removes the review ends the notice",
        A.retainNotice (event False (summary reviewScreen) (summary requestScreen) False Nothing) (Just first) (Just first) == Nothing),
      ("a later approval key replaces the earlier notice",
        A.retainNotice (event True (detailed reviewScreen) (detailed reviewScreen) True Nothing) (Just first) (Just second) == Just second),
      ("a preflight refusal after an approval start does not keep the approval-start notice",
        A.retainNotice (event False (summary reviewScreen) (summary reviewScreen) True (Just 3)) (Just started) (Just started) /= Just started),
      ("a preflight refusal replaces the approval-start notice with the fixed not-sent notice of that press",
        A.retainNotice (event False (summary reviewScreen) (summary reviewScreen) True (Just 3)) (Just started) (Just started) == Just notSent),
      ("a preflight refusal replaces a later busy notice with the not-sent notice of the approval press",
        A.retainNotice (event False (summary reviewScreen) (summary reviewScreen) True (Just 3)) (Just busy) (Just busy) == Just notSent),
      ("a preflight refusal after the review left the screen leaves no notice",
        A.retainNotice (event False (summary reviewScreen) (summary requestScreen) False (Just 3)) (Just started) (Just started) == Nothing)
    ]
  -- The same lifetime driven through a sequence of service events, each with
  -- the command lane before and after it, as the App wrapper supplies them.
  let step notice (keyPress,before,after,shown,approvalPress,laneBefore,laneAfter,produced) =
        A.retainNotice (event keyPress before after shown (A.unsentApproval approvalPress laneBefore laneAfter)) notice (maybe notice Just produced)
      sending = L.MutationSending 3 (L.Attempt approve "pending" (Just "/v1/commands/cmd_1")) :: L.MutationState T.Text T.Text
      awaiting = L.MutationAwaiting approve "pending" "/v1/commands/cmd_1" :: L.MutationState T.Text T.Text
      s = summary reviewScreen
      refused = scanl step Nothing
        [ (True, s, s, True, Just 3, L.MutationIdle, preparingApproval, Just started),
          (False, s, s, True, Just 3, preparingApproval, preparingApproval, Nothing),
          (True, s, s, True, Just 3, preparingApproval, preparingApproval, Just busy),
          (False, s, s, True, Just 3, preparingApproval, L.MutationIdle, Nothing),
          (False, s, summary renewedScreen, True, Just 3, L.MutationIdle, L.MutationIdle, Nothing),
          (False, summary renewedScreen, summary renewedScreen, True, Just 3, L.MutationIdle, L.MutationIdle, Nothing) ]
      proceeded = scanl step Nothing
        [ (True, s, s, True, Just 3, L.MutationIdle, preparingApproval, Just started),
          (False, s, s, True, Just 3, preparingApproval, sending, Nothing),
          (False, s, s, True, Just 3, sending, awaiting, Nothing),
          (False, s, summary renewedScreen, True, Just 3, awaiting, awaiting, Nothing) ]
  checks
    [ ("an approval press, a tick, a busy press, a preflight refusal, an install and a tick end with the not-sent notice",
        refused == [Nothing, Just started, Just started, Just busy, Just notSent, Just notSent, Just notSent]),
      ("an approval that proceeds to its send keeps the approval-start notice while the review stays",
        proceeded == [Nothing, Just started, Just started, Just started, Just started])
    ]
  -- Fixed-size renders of every notice in both review views and under the
  -- key help, before and after an installed observation that renews the
  -- review and its status.
  let serviceModel = initialServiceModel [profile]
      reviewPresentation screen status view notice offered = (emptyPresentation (serviceModel {modelScreen = screen, modelStatus = status}))
        {presentationService = True, presentationExactDetails = view == A.DetailView, presentationServiceNotice = notice,
          presentationServiceApprovalOffered = offered, presentationNoColor = True,
          presentationLayer = if view == A.KeyHelpView then KeyHelpLayer else presentationLayer (emptyPresentation serviceModel {modelScreen = screen})}
      noticeShown size frame notice = all (`T.isInfixOf` frame) (wrapDisplayLines (min 84 (fst size) - 4) (A.noticeLine notice))
      notices = notSent : map (A.decisionNotice 9) (A.Approve () : map A.Refuse [minBound .. maxBound] :: [A.ApprovalDecision ()])
  mapM_ (\notice -> mapM_ (\(size,view) -> do
      let before = render size (reviewPresentation reviewScreen "exact manager review observed" view (Just notice) False)
          kept = A.retainNotice (event False (reviewScreen,view) (renewedScreen,view) True Nothing) (Just notice) (Just notice)
          after = render size (reviewPresentation renewedScreen "manager request: review" view kept False)
          viewName = case view of A.SummaryView -> "summary review"; A.DetailView -> "detail view"; A.KeyHelpView -> "key help"
      check ("the notice " <> show (A.noticeText notice) <> " renders in the " <> viewName <> " at " <> show size)
        (noticeShown size before notice)
      check ("the notice " <> show (A.noticeText notice) <> " survives an installed observation in the " <> viewName <> " at " <> show size)
        (noticeShown size after notice && "manager request: review" `T.isInfixOf` after))
    [(size,view) | size <- [(140,36),(80,24)], view <- views]) notices
  let shownRefusal view = case view of
        A.SummaryView -> A.EnterRefused
        A.DetailView -> A.DetailRefused
        A.KeyHelpView -> A.HelpRefused
      refusalNotice view = A.decisionNotice 3 (A.Refuse (shownRefusal view) :: A.ApprovalDecision ())
  mapM_ (\view -> putStrLn ("RENDER approval-key refusal in the " <> show view <> " at (80,24):")
      >> putStr (T.unpack (render (80,24) (reviewPresentation reviewScreen "exact manager review observed" view (Just (refusalNotice view)) False))))
    views
  putStrLn "RENDER preflight refusal after an approval start in the summary review at (80,24):"
    >> putStr (T.unpack (render (80,24) (reviewPresentation renewedScreen "exact manager review observed" A.SummaryView (Just notSent) True)))
  checks
    [ ("the approval hint renders when the predicate offers approval",
        "y APPROVE EXACT REVIEW" `T.isInfixOf` render (140,36) (reviewPresentation reviewScreen "review" A.SummaryView Nothing True)),
      ("the approval hint is absent when the predicate refuses",
        not ("y APPROVE EXACT REVIEW" `T.isInfixOf` render (140,36) (reviewPresentation reviewScreen "review" A.SummaryView Nothing False)))
    ]
  smallest <- case filter (\height -> serviceReviewAllowed preparation tag (100,height)) [8 .. 60] of
    height : _ -> pure height
    [] -> die "FAIL no admissible review height at width 100"
  let longest = snd (maximum [(T.length text,text) | text <- A.noticeTexts])
      tight = render (100,smallest) (reviewPresentation reviewScreen "review" A.SummaryView (Just (A.KeyNotice maxBound longest)) True)
  check ("the longest notice does not clip the review at the smallest admissible height " <> show smallest)
    (all (`T.isInfixOf` tight) (concatMap (wrapDisplayLines 80) (serviceReviewRows preparation tag))
      && noticeShown (100,smallest) tight (A.KeyNotice maxBound longest))
