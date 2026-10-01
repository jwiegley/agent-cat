{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module ServiceTests (serviceTests) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime (DescriptorCapabilities (..), WorkflowDescriptor (..), WorkflowInputDescriptor (..), WorkflowInputSource (..),
  OccurrenceId (..), AttemptId (..), RunSnapshot (..), OccurrenceSnapshot (..), AttemptSnapshot (..), ControlAckSnapshot (..),
  PersonAnswering (..), RecoverySnapshot (..), RecoveryOption (..), RunStatus (..), mkRunId)
import Agentic.Tui.Person (PersonPrompt (..))
import Agentic.Tui.Model
import qualified Agentic.Tui.Approval as A
import Agentic.Tui.Presentation (ActiveLayer (..), Presentation (..), emptyPresentation, endpointLine, endpointsLines, serviceRequestLines, serviceReviewAllowed, serviceReviewRows,
  savedLeftoverNote, serviceSaveRefusal, serviceSavedLine, wrapDisplayLines)
import Agentic.Tui.RunModel (emptyRunView, reconcileRunView)
import Agentic.Tui.Save (SaveRefusal (..), Saved (..), saveExact, saveExactUsing)
import qualified Agentic.Tui.Service as S
import qualified Agentic.Tui.ServiceLane as L
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay, throwTo)
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (ErrorCall), SomeException, finally, fromException, throwIO, try)
import Data.Bits ((.&.))
import Data.Char (isSpace)
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectory, doesPathExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink, fileMode, getFileStatus, getSymbolicLinkStatus, isSymbolicLink, readSymbolicLink)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import qualified Data.Text.Encoding as TE
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy as BL
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Map.Strict as Map
import qualified Graphics.Vty as Vty
import System.Exit (die)
import System.IO.Error (alreadyExistsErrorType, mkIOError, permissionErrorType)
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
  compositeTests render profile row request0 preparation snapshot absentRuntime (metadata,items) control decision
  decisionTests render profile request0 receiptValue (metadata,items) (decisionValue,decision) control
  liveTests render profile request0 (metadata,items)
  resultTests render profile
  saveTests
  laneTests render row profile
  resourceVectorTests
  endpointTests render profile
  switchTests render row profile
  where
    profileValue = object ["version" .= (1 :: Int), "id" .= ("profile_main" :: T.Text),
      "revision" .= ("profile_rev_4" :: T.Text), "workspaceLabel" .= ("Café 雪 λ" :: T.Text),
      "targetLabel" .= ("local fixture" :: T.Text), "readiness" .= ("ready" :: T.Text), "refusal" .= Null]
    property rest = object ["property" .= object ["name" .= ("same" :: T.Text),
      "schema" .= ("boolean" :: T.Text), "rest" .= rest]]
    duplicateSchema = object ["json" .= object ["schema" .= property (property (String "object"))]]
    duplicate (Array values) = Array (values V.++ values)
    duplicate other = other

-- | Every scope that a manager credential can hold.
allScopes :: [T.Text]
allScopes = ["observe", "submit", "control", "export"]

-- | The endpoint identity of the service shell, the scope refusal of the
-- mutation keys and the fixed startup failure lines.
endpointTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> IO ()
endpointTests render profile = do
  capabilities <- BS.readFile "test/fixtures/manager/v1/valid/capabilities.json" >>= either die pure . eitherDecodeStrict'
  endpoint <- either (die . show) pure (S.decodeEndpoint ("127.0.0.1", 8443) capabilities)
  let stream = "stream_" <> T.replicate 64 "a"
      authority = "authority_0123456789abcdef0123"
      wide = S.Endpoint "127.0.0.1" 54321 stream authority ["observe", "submit"]
      shell size model ident = render size ((emptyPresentation model) {presentationService = True, presentationNoColor = True,
        presentationServiceEndpoint = ident})
      catalogue = initialServiceModel [profile]
      -- A key outcome that starts nothing, with its text and whether it defers.
      idle = L.Lane Nothing L.MutationIdle False False :: L.Lane T.Text T.Text
      paging = L.Lane (Just (L.ReadTicket 3 L.PageSetRead)) L.MutationIdle False False :: L.Lane T.Text T.Text
      outcome scopes operation lane = L.mutationKeyOutcome scopes operation lane
      submitOperations = ["create", "capture", "set-input", "remove-input", "enqueue", "withdraw"]
      controlOperations = ["cancel", "steer", "retry", "choose-recovery", "redirect", "answer"]
      current = A.ReviewCurrent () :: A.ReviewCheck ()
      failures = [ (C.InvalidClientProfile, "invalid client profile"),
        (C.ClientFileUnavailable, "client profile, credential or CA file unavailable"),
        (C.InvalidEndpoint, "invalid manager endpoint"), (C.WrongEndpoint, "wrong manager endpoint"),
        (C.CredentialUnavailable, "credential unavailable"), (C.CredentialChanged, "credential changed during the connection"),
        (C.TransportUnavailable, "manager unreachable"), (C.RedirectRefused, "manager redirect refused"),
        (C.InvalidResponse, "invalid manager response"), (C.ResponseTooLarge, "manager response too large"),
        (C.UnsupportedVersion, "manager API version unsupported"), (C.ClientClosed, "client closed"),
        (C.Refused 401 "unauthenticated", "credential refused"),
        (C.Refused 403 "insufficient-scope", "credential lacks the observe scope"),
        (C.Refused 503 "storage-unavailable", "manager refused the connection: 503 storage-unavailable") ]
  checks
    [ ("the endpoint identity takes the stream, authority and scopes of the capabilities",
        endpoint == S.Endpoint "127.0.0.1" 8443 "stream_A" "epoch_A" ["observe", "submit", "control", "export"]),
      ("capabilities without a string streamId refuse the endpoint identity",
        S.decodeEndpoint ("h", 1) (put "streamId" Null capabilities) == Left C.InvalidResponse),
      ("capabilities without a scope list refuse the endpoint identity",
        S.decodeEndpoint ("h", 1) (remove "scopes" capabilities) == Left C.InvalidResponse),
      ("the identity row names the host and port, the authority prefix, the scopes and the full stream",
        S.endpointStream wide `T.isInfixOf` endpointLine wide
          && "manager 127.0.0.1:54321 · authority_01234567… · scopes observe submit · " `T.isPrefixOf` endpointLine wide),
      ("an IPv6 host is bracketed and an empty scope list reads none",
        "manager [::1]:9 · epoch_A · scopes none · stream_A" == endpointLine (S.Endpoint "::1" 9 "stream_A" "epoch_A" [])),
      ("a wide service shell shows the complete identity row",
        endpointLine wide `T.isInfixOf` shell (200,36) catalogue (Just wide)),
      ("an acceptance-size service shell shows the endpoint, authority prefix, scopes and the leading stream characters",
        all (`T.isInfixOf` shell (140,36) catalogue (Just wide))
          ["127.0.0.1:54321", "authority_01234567…", "scopes observe submit", T.take 40 stream]),
      ("the identity row is a header row of its own in every service screen",
        all (\screen -> "127.0.0.1:54321" `T.isInfixOf` shell (80,24) catalogue {modelScreen = screen} (Just wide))
          [InitialLoading, BrowserScreen, ServiceCommandScreen "notice"]),
      ("a small terminal keeps its one-row header without the identity row",
        not ("127.0.0.1:54321" `T.isInfixOf` shell (40,12) catalogue (Just wide))),
      ("the local shell has no identity row", not ("manager 127.0.0.1" `T.isInfixOf` shell (140,36) catalogue Nothing)),
      ("every submit operation without the submit scope refuses with the scope, even during a page-set read",
        and [ outcome ["observe", "control"] operation lane == Just (operation <> " did not start: this credential lacks submit.", False)
            | operation <- submitOperations, lane <- [idle, paging] ]),
      ("every run control and answer without the control scope refuses with the scope",
        and [ outcome ["observe", "submit"] operation idle == Just (operation <> " did not start: this credential lacks control.", False)
            | operation <- controlOperations ]),
      ("export without the export scope refuses with the scope",
        outcome ["observe", "submit", "control"] "export" idle == Just ("export did not start: this credential lacks export.", False)),
      ("approve needs submit and control and names the first one missing",
        S.missingScope ["observe", "control"] "approve" == Just "submit" && S.missingScope ["observe", "submit"] "approve" == Just "control"
          && S.missingScope allScopes "approve" == Nothing),
      ("with every scope an idle lane starts the key and a page-set read defers it",
        and [ outcome allScopes operation idle == Nothing
              && outcome allScopes operation paging == Just (operation <> " deferred during a page-set read. Press the key again.", True)
            | operation <- submitOperations <> controlOperations <> ["approve", "discard", "export"] ]),
      ("a summary y without the control scope refuses with the scope before the lane and the review",
        A.approvalDecision ["observe", "submit"] A.ApproveKey A.SummaryView idle current == A.Unscoped "control"
          && A.approvalDecision ["observe", "submit"] A.ApproveKey A.SummaryView paging current == A.Unscoped "control"),
      ("forbidden approval keys and views refuse before the scope",
        A.approvalDecision [] A.EnterKey A.SummaryView idle current == A.Refuse A.EnterRefused
          && A.approvalDecision [] A.ApproveKey A.DetailView idle current == A.Refuse A.DetailRefused
          && A.approvalDecision [] A.ApproveKey A.KeyHelpView idle current == A.Refuse A.HelpRefused),
      ("the scope refusal of approval carries its numbered notice and withholds the approval hint",
        A.decisionNotice 4 (A.Unscoped "control" :: A.ApprovalDecision ()) == A.KeyNotice 4 "Approval did not start: this credential lacks control."
          && not (A.approvalOffered ["observe", "submit"] A.SummaryView idle current)
          && A.approvalOffered allScopes A.SummaryView idle current),
      ("both approval scope refusals are listed for layout reservation",
        all (`elem` A.noticeTexts) [A.unscopedText "submit", A.unscopedText "control"]),
      ("a scope refusal renders as a numbered key outcome on the status line",
        "Key 5: create did not start: this credential lacks submit." `T.isInfixOf`
          render (80,24) ((emptyPresentation catalogue) {presentationService = True, presentationNoColor = True,
            presentationServiceKeyOutcome = Just (L.KeyOutcome 5 (L.scopeText "create" "submit") Nothing)})),
      ("every startup failure has its one fixed line",
        and [ L.startupFailureText failure == "--tui --service: " <> line | (failure, line) <- failures ]),
      ("the startup failure lines are distinct single lines",
        let lines' = map (L.startupFailureText . fst) failures
         in length (Set.fromList lines') == length lines' && not (any (T.any (== '\n')) lines'))
    ]

-- | Endpoint switching: the selection, the connection of another profile,
-- generation fencing of late results, the unresolved command of the earlier
-- session, a failed connection, the switch back and the Endpoints view.
switchTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Workflow -> S.Profile -> IO ()
switchTests render row profile = do
  let first = S.Endpoint "127.0.0.1" 8443 "stream_A" "epoch_A" ["observe", "submit"]
      second = S.Endpoint "127.0.0.1" 8443 "stream_A" "epoch_A" ["observe", "submit", "control"]
      start = L.newEndpoints "/p/one.json" first ["/p/two.json", "/p/three.json"]
      generation = L.endpointsGeneration
      states endpoints = map L.slotState (L.endpointsSlots endpoints)
      create = S.Create row
      retained = L.Attempt create ("pending-original" :: T.Text) (Nothing :: Maybe T.Text)
      uncertain = L.Lane (Just (L.ReadTicket 7 L.PageSetRead)) (L.MutationUncertain retained (L.DeclaredUncertainty "TransportUnavailable")) False False
      unresolved = L.unresolvedCommands uncertain
      (activeRefusal, _) = L.beginSwitch 10 start
      selected = L.moveEndpoint 1 start
      (switchStart, connecting) = L.beginSwitch 10 selected
      (secondRefusal, _) = L.beginSwitch 11 (L.moveEndpoint 1 connecting)
      (staleStep, staleAfter) = L.switchStep 9 (L.Declared (Right ("late session" :: T.Text, second))) unresolved connecting
      (failedStep, failed) = L.switchStep 10 (L.Declared (Left C.TransportUnavailable) :: L.CallOutcome (T.Text, S.Endpoint)) unresolved connecting
      (faultStep, _) = L.switchStep 10 (L.InternalFault :: L.CallOutcome (T.Text, S.Endpoint)) unresolved connecting
      (_, retrying) = L.beginSwitch 12 failed
      (connectedStep, switched) = L.switchStep 12 (L.Declared (Right ("second session" :: T.Text, second))) unresolved retrying
      -- A read of the earlier session that was in flight with ticket 7.
      late = L.Stamped (generation start) (7 :: Int, L.Declared (Right ("old observation" :: T.Text)) :: L.CallOutcome T.Text)
      current = L.Stamped (generation switched) (1 :: Int)
      (backStart, back) = L.beginSwitch 13 (L.moveEndpoint (-1) switched)
      (backStep, returned) = L.switchStep 13 (L.Declared (Right ("first again" :: T.Text, first))) [] back
      view endpoints = render (100, 30) ((emptyPresentation (initialServiceModel [profile])) {presentationService = True, presentationNoColor = True,
        presentationLayer = EndpointsLayer, presentationServiceEndpoint = L.activeIdentity endpoints, presentationServiceEndpoints = Just endpoints})
      switchedLines = endpointsLines switched
  checks
    [ ("the first profile is active with its identity at generation zero and the others have no session",
        L.activeIdentity start == Just first && states start == [L.EndpointActive, L.EndpointIdle, L.EndpointIdle]
          && generation start == C.FetchGeneration 0),
      ("selecting the active endpoint starts nothing", activeRefusal == L.SwitchRefused "endpoint 1 is already active."),
      ("selecting another endpoint connects its profile and keeps the active session",
        switchStart == L.SwitchStart "/p/two.json" && L.endpointsActive connecting == 0
          && states connecting == [L.EndpointActive, L.EndpointConnecting 10, L.EndpointIdle] && generation connecting == generation start),
      ("a second connection while one is in flight starts nothing",
        secondRefusal == L.SwitchRefused "endpoint switch did not start: a connection is in progress."),
      ("a completion with a stale ticket changes nothing and closes the session that it opened",
        staleStep == L.SwitchStale (Just "late session") && staleAfter == connecting),
      ("a failed connection keeps the active endpoint, its identity and the generation, and shows the fixed reason",
        failedStep == L.SwitchFailed "manager unreachable" && L.endpointsActive failed == 0 && L.activeIdentity failed == Just first
          && generation failed == generation start && states failed == [L.EndpointActive, L.EndpointFailed "manager unreachable", L.EndpointIdle]),
      ("an internal fault during the connection is a failed connection",
        faultStep == L.SwitchFailed "internal frontend fault during the connection"),
      ("a successful connection makes the new identity active and advances the generation",
        connectedStep == L.SwitchConnected "second session" && L.endpointsActive switched == 1 && L.activeIdentity switched == Just second
          && generation switched == C.FetchGeneration 1 && states switched == [L.EndpointIdle, L.EndpointActive, L.EndpointIdle]),
      ("a late result of the earlier session is not admitted, so it never reaches the new session",
        isNothing (L.admitStamped switched late) && L.admitStamped switched current == Just 1),
      ("the stale read ticket of the earlier session is stale for the lane of the new session",
        case L.readStep 7 (L.Declared (Right ("old observation" :: T.Text))) (L.sessionLane :: L.Lane T.Text T.Text) of
          (L.ReadStale, lane) -> laneShape lane == laneShape L.sessionLane
          _ -> False),
      ("the new session has no read, no command, no fault and no exact resend",
        laneShape (L.sessionLane :: L.Lane T.Text T.Text) == (Nothing, False, False, "idle")
          && isNothing (L.resendAttempt (L.sessionLane :: L.Lane T.Text T.Text))),
      ("the unresolved command of the earlier session stays listed for its own profile",
        unresolved == ["create " <> S.mutationURI create]
          && map L.slotUnresolved (L.endpointsSlots switched) == [unresolved, [], []]),
      ("a send in flight is unresolved at a switch and a preparation or an accepted intent is not",
        L.unresolvedCommands (L.Lane Nothing (L.MutationSending 3 retained) False False) == unresolved
          && null (L.unresolvedCommands (L.Lane Nothing (L.MutationPreparing 3 create) False False :: L.Lane T.Text T.Text))
          && null (L.unresolvedCommands (L.Lane Nothing (L.MutationAwaiting create "pending" "/v1/commands/c") False False :: L.Lane T.Text T.Text))),
      ("selecting the earlier endpoint again opens a new session at a new generation and keeps its unresolved command listed",
        backStart == L.SwitchStart "/p/one.json" && backStep == L.SwitchConnected "first again" && L.endpointsActive returned == 0
          && L.activeIdentity returned == Just first && generation returned == C.FetchGeneration 2
          && map L.slotUnresolved (L.endpointsSlots returned) == [unresolved, [], []]
          && isNothing (L.admitStamped returned current)),
      ("the Endpoints view lists each profile with its state, path and identity, and marks the selection",
        switchedLines!!0 == "  1. not connected  /p/one.json" && switchedLines!!2 == "     unresolved create " <> S.mutationURI create <> " (not sent through another endpoint)"
          && switchedLines!!3 == "> 2. active  /p/two.json" && switchedLines!!4 == "     " <> endpointLine second
          && switchedLines!!5 == "  3. not connected  /p/three.json" && switchedLines!!6 == "     identity not observed"),
      ("the Endpoints view shows a failed connection with its fixed reason",
        "> 2. failed: manager unreachable  /p/two.json" `elem` endpointsLines failed),
      ("the rendered Endpoints view shows the new identity, the unresolved command and its keys",
        all (`T.isInfixOf` view switched) ["Manager endpoints", "active  /p/two.json", "scopes observe submit control",
          "unresolved create", "Enter CONNECT", "Esc BACK"])
    ]

-- | The decision, answer, control, request and run sections of the resources
-- section of the shared client vectors, run with the TUI service parsers. The
-- file path is relative to the repository root, as the fixture paths are. Each
-- accepted decision and control view also retains its exact JSON value.
resourceVectorTests :: IO ()
resourceVectorTests = do
  root <- BS.readFile "test/manager_client_vectors.json" >>= either die pure . eitherDecodeStrict'
  let section name = case lookupKey "resources" root >>= lookupKey name of
        Just (Array items) | not (V.null items) -> pure (V.toList items)
        _ -> die ("FAIL vector section resources." <> T.unpack (Key.toText name) <> " is empty")
      origin vector = lookupKey "from" vector
      byOrigin item overview vector = case origin vector of
        Just (String "item") -> pure item
        Just (String "overview") -> pure overview
        _ -> die ("FAIL " <> vectorName vector <> " names no origin")
  decisions <- section "decisions"
  mapM_ (\vector -> byOrigin (retained S.decodeDecision S.decisionValue decisionProjection) member vector
    >>= \decode -> resourceVector decode vector) decisions
  section "answers" >>= mapM_ answerVector
  section "controls" >>= mapM_ (resourceVector (retained S.decodeControl S.controlValue controlProjection))
  requests <- section "requests"
  mapM_ (\vector -> byOrigin (fmap toJSON . S.decodeRequestItem) member vector >>= \decode -> resourceVector decode vector) requests
  runs <- section "runs"
  mapM_ (\vector -> byOrigin (fmap runProjection . S.decodeRunItem) member vector >>= \decode -> resourceVector decode vector) runs
  where
    member value = memberProjection <$> S.decodeOverviewMember value
    -- A view keeps its JSON value. When that value is not the input itself,
    -- the projection is a fixed text that matches no expected projection.
    retained decodeView raw projection value = decodeView value >>= \view -> Right
      (if raw view == value then projection view else String "the retained value differs from the input")
    -- The projections name the decoded fields. UInt64 and UInt32 values are
    -- canonical decimal text, and an absent optional value is null.
    decisionProjection view = object
      [ "id" .= S.decisionId view, "revision" .= S.decisionRevision view, "runId" .= S.decisionRun view,
        "profileId" .= S.decisionProfile view, "generation" .= S.decisionGeneration view,
        "occurrenceId" .= occurrenceText (S.decisionOccurrence view), "state" .= S.decisionState view,
        "position" .= S.decisionPosition view, "observedSequence" .= T.pack (show (S.decisionSequence view)),
        "content" .= case S.decisionContent view of
          S.QuestionContent code prompt -> object ["kind" .= ("question" :: T.Text), "code" .= code, "prompt" .= prompt]
          S.RecoveryContent gap message choices -> object ["kind" .= ("recovery" :: T.Text), "gap" .= gap,
            "message" .= message, "choices" .= map choiceProjection choices] ]
    choiceProjection option = object ["choice" .= recoveryChoice option, "target" .= recoveryTarget option]
    controlProjection view = object
      [ "runId" .= S.controlRun view, "revision" .= S.controlRevision view, "supervision" .= S.controlSupervision view,
        "cancelAllowed" .= S.controlCancel view, "decisionHeadId" .= S.controlHead view,
        "offers" .= map offerProjection (S.controlOffers view) ]
    offerProjection offer = object
      [ "operation" .= S.offerOperation offer, "occurrenceId" .= occurrenceText (S.offerOccurrence offer),
        "attemptId" .= fmap (T.pack . show) (S.offerAttempt offer), "generation" .= S.offerGeneration offer,
        "timings" .= S.offerTimings offer, "choices" .= map choiceProjection (S.offerChoices offer), "targets" .= S.offerTargets offer ]
    runProjection item = object
      [ "id" .= S.runItemId item, "revision" .= S.runItemRevision item, "profileId" .= S.runItemProfile item,
        "content" .= case S.runItemContent item of
          S.UnreadableContent category -> object ["kind" .= ("unreadable" :: T.Text), "category" .= category]
          S.KnownContent known -> object
            [ "kind" .= ("known" :: T.Text), "workflowId" .= S.knownWorkflow known, "requestId" .= S.knownRequest known,
              "parentRunId" .= S.knownParent known, "lineage" .= S.knownLineage known, "manifestVersion" .= S.knownManifest known,
              "runtime" .= fmap (\(status,sequenceNumber,protocol) -> object ["status" .= statusText status,
                "lastSequence" .= T.pack (show sequenceNumber), "protocolVersion" .= protocol]) (S.knownRuntime known),
              "supervision" .= S.knownSupervision known, "integrity" .= S.knownIntegrity known,
              "verification" .= verificationProjection (S.knownVerification known), "limitations" .= S.knownLimitations known ] ]
    verificationProjection verification = case verification of
      S.Absent -> object ["state" .= ("absent" :: T.Text)]
      S.Referenced artifact -> object ["state" .= ("referenced" :: T.Text), "artifactId" .= artifact]
      S.Verified artifact -> object ["state" .= ("verified" :: T.Text), "artifactId" .= artifact]
      S.Unavailable artifact reason -> object ["state" .= ("unavailable" :: T.Text), "artifactId" .= artifact, "reason" .= reason]
    statusText :: RunStatus -> T.Text
    statusText status = case status of
      RunStarting -> "starting"
      RunRunning -> "running"
      RunCancelling -> "cancelling"
      RunSucceeded -> "succeeded"
      RunFailedStatus -> "failed"
      RunCancelledStatus -> "cancelled"
      RunOrphaned -> "orphaned"
    memberProjection overviewMember = case overviewMember of
      S.RequestMember request -> tagged "request" (toJSON request)
      S.PreparationMember preparation -> tagged "preparation" (toJSON preparation)
      S.RunMember item -> tagged "run" (runProjection item)
      S.DecisionMember view -> tagged "decision" (decisionProjection view)
    tagged kind value = object ["kind" .= (kind :: T.Text), Key.fromText kind .= value]
    occurrenceText = T.pack . show . occurrenceNumber

vectorName :: Value -> String
vectorName vector = case lookupKey "name" vector of
  Just (String name) -> T.unpack name
  _ -> "unnamed vector"

-- | The JSON text of one vector field, decoded.
vectorJson :: Value -> Key.Key -> IO Value
vectorJson vector key = case lookupKey key vector of
  Just (String source) -> either (\problem -> die ("FAIL " <> vectorName vector <> ": " <> problem)) pure
    (eitherDecodeStrict' (TE.encodeUtf8 source))
  _ -> die ("FAIL " <> vectorName vector <> " has no " <> T.unpack (Key.toText key))

-- | A resource vector decodes to its projection or refuses with InvalidResponse.
resourceVector :: (Value -> Either C.ClientFailure Value) -> Value -> IO ()
resourceVector decode vector = do
  value <- vectorJson vector "json"
  expected <- case (lookupKey "projection" vector, lookupKey "refusal" vector) of
    (Just (String _), Nothing) -> Right <$> vectorJson vector "projection"
    (Nothing, Just (String "InvalidResponse")) -> pure (Left C.InvalidResponse)
    _ -> die ("FAIL " <> vectorName vector <> " states neither one projection nor one refusal")
  let outcome = decode value
  unless (outcome == expected) (die ("FAIL resource vector " <> vectorName vector <> ": " <> show outcome))
  check ("resource vector " <> vectorName vector) True

-- | An answer vector: the typed value of the input for the decision gives the
-- projected answer body, or the answer is refused before any command.
answerVector :: Value -> IO ()
answerVector vector = do
  decision <- vectorJson vector "decision" >>= either (\failure -> die ("FAIL " <> vectorName vector <> ": " <> show failure)) pure . S.decodeDecision
  input <- case lookupKey "input" vector of
    Just (String given) -> pure given
    _ -> die ("FAIL " <> vectorName vector <> " has no input")
  let outcome = S.answerBody decision <$> S.answerValue decision input
  passed <- case (lookupKey "projection" vector, lookupKey "refusal" vector) of
    (Just (String _), Nothing) -> (\expected -> outcome == Right expected) <$> vectorJson vector "projection"
    (Nothing, Just (String "InvalidAnswer")) -> pure (either (const True) (const False) outcome)
    _ -> die ("FAIL " <> vectorName vector <> " states neither one projection nor one refusal")
  unless passed (die ("FAIL answer vector " <> vectorName vector <> ": " <> show outcome))
  check ("answer vector " <> vectorName vector) True

put :: Key.Key -> Value -> Value -> Value
put key value (Object fields) = Object (KM.insert key value fields)
put _ _ other = other

lookupKey :: Key.Key -> Value -> Maybe Value
lookupKey key (Object fields) = KM.lookup key fields
lookupKey _ _ = Nothing

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
      single number = Just (L.ReadTicket number L.SingleResourceRead)
      laneWith ticket mutation = L.Lane (ticket >>= single) mutation False False :: L.Lane T.Text T.Text
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

-- | Model and fixed-size render tests for the composite read of the selected
-- request, the retention of the last complete observation, the receipt rules
-- and the mutation-key admission policy. Observations are (URI, entity tag)
-- pairs here, and the binding is the identity.
compositeTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> S.Workflow -> C.DraftView -> C.Preparation
  -> S.RunObservation -> S.RunObservation -> (Value,[Value]) -> S.ControlView -> S.DecisionView -> IO ()
compositeTests render profile row request0 preparation snapshot absentRuntime (metadata,items) control decision = do
  otherRunId <- either (die . show) pure (mkRunId "run_other")
  let binding = id :: (T.Text,T.Text) -> (T.Text,T.Text)
      requestObs = ("/v1/requests/req_8", "\"request_rev_1\"") :: (T.Text,T.Text)
      controlObs = ("/v1/runs/run_21/control", "\"controlrev_2\"") :: (T.Text,T.Text)
      decisionObs = ("/v1/decisions/decision_3", "\"decisionrev_1\"") :: (T.Text,T.Text)
      associated = request0 {C.draftPhase = "associated", C.draftRun = Just "run_21"}
      runRead = S.RunRead snapshot (controlObs,control) (Just (decisionObs,decision))
      composite = S.RequestRead (requestObs,associated) Nothing Nothing (Just runRead)
      before = S.RequestRead (requestObs,request0) Nothing Nothing Nothing
      firstAssociation = S.RequestRead (requestObs,associated) Nothing Nothing Nothing
      afterSelection = S.Selection "req_8" (Just "run_21")
      beforeSelection = S.Selection "req_8" Nothing
      verdict = S.readVerdict binding afterSelection
      withRun changed = composite {S.readRun = Just changed}
  check "a complete bound composite for the selected request and run is current" (verdict composite == S.ReadCurrent)
  checks [ (label, verdict bad == S.ReadInvalid) | (label,bad) <-
    [ ("a snapshot for another run is invalid", withRun runRead {S.runReadSnapshot = snapshot {S.runIdentity = otherRunId}}),
      ("controls for another run are invalid", withRun runRead {S.runReadControl = (controlObs,control {S.controlRun = "run_other"})}),
      ("controls with another entity tag are invalid", withRun runRead {S.runReadControl = (("/v1/runs/run_21/control","\"controlrev_9\""),control)}),
      ("controls observed at another URI are invalid", withRun runRead {S.runReadControl = (("/v1/runs/run_other/control","\"controlrev_2\""),control)}),
      ("a decision for another run is invalid", withRun runRead {S.runReadDecision = Just (decisionObs,decision {S.decisionRun = "run_other"})}),
      ("a decision for another profile is invalid", withRun runRead {S.runReadDecision = Just (decisionObs,decision {S.decisionProfile = "profile_other"})}),
      ("a decision with another entity tag is invalid", withRun runRead {S.runReadDecision = Just (("/v1/decisions/decision_3","\"decisionrev_9\""),decision)}),
      ("a decision other than the control head is invalid",
        withRun runRead {S.runReadDecision = Just (("/v1/decisions/decision_4","\"decisionrev_1\""),decision {S.decisionId = "decision_4"})}),
      ("a decision body with another id at the head URI is invalid",
        withRun runRead {S.runReadDecision = Just (decisionObs,decision {S.decisionId = "decision_4"})}),
      ("a named head without its decision is invalid", withRun runRead {S.runReadDecision = Nothing}),
      ("a decision without a named head is invalid", withRun runRead {S.runReadControl = (controlObs,control {S.controlHead = Nothing})}),
      ("missing run components after association are invalid", composite {S.readRun = Nothing}),
      ("a request with another entity tag is invalid", composite {S.readRequest = (("/v1/requests/req_8","\"request_rev_9\""),associated)}),
      ("a preparation that the request does not name is invalid", composite {S.readPreparation = Just (("/v1/preparations/prep_9","\"preprev_1\""),preparation)})
    ] ]
  checks
    [ ("a composite for another request is foreign", S.readVerdict binding (S.Selection "req_other" (Just "run_21")) composite == S.ReadForeign),
      ("a read before association without run components is current", S.readVerdict binding beforeSelection before == S.ReadCurrent),
      ("the read that first observes the association carries no run components and is current",
        S.readVerdict binding beforeSelection firstAssociation == S.ReadCurrent),
      ("run components that the selection did not name are invalid", S.readVerdict binding beforeSelection composite == S.ReadInvalid),
      ("controls without a head and without a decision are valid",
        S.runReadValid binding "profile_main" "run_21" runRead {S.runReadControl = (controlObs,control {S.controlHead = Nothing}), S.runReadDecision = Nothing})
    ]
  -- The completion of the composite read over the lane and the installed observation.
  let create = S.Create row
      awaiting = L.MutationAwaiting create "pending" "/v1/commands/cmd_1" :: L.MutationState T.Text T.Text
      readingLane kind = L.Lane (Just (L.ReadTicket 5 kind)) awaiting False False :: L.Lane T.Text T.Text
      afterLane = readingLane L.PageSetRead
      beforeLane = readingLane L.SingleResourceRead
      endedLane = L.Lane Nothing awaiting False False :: L.Lane T.Text T.Text
      priorAfter = L.Installed (Just composite) Nothing
      priorBefore = L.Installed (Just before) Nothing
      isStale step = case step of L.RequestStale -> True; _ -> False
      refusedWith failure step = case step of L.RequestRefused problem -> problem == failure; _ -> False
      stepAfter = L.requestStep verdict
      stepBefore = L.requestStep (S.readVerdict binding beforeSelection)
      staleTicket = stepAfter 6 (L.Declared (Right composite)) afterLane priorAfter
      otherRequest = L.requestStep (S.readVerdict binding (S.Selection "req_other" (Just "run_21"))) 5 (L.Declared (Right composite)) afterLane priorAfter
      otherRun = L.requestStep (S.readVerdict binding (S.Selection "req_8" (Just "run_other"))) 5 (L.Declared (Right composite)) afterLane priorAfter
      invalid = stepAfter 5 (L.Declared (Right composite {S.readRun = Nothing})) afterLane priorAfter
      installed = stepAfter 5 (L.Declared (Right composite)) afterLane (priorAfter {L.installedStale = Just "503 storage-unavailable"})
      faulted = stepAfter 5 (L.InternalFault :: L.CallOutcome (S.RequestRead (T.Text,T.Text))) afterLane priorAfter
      refusal status code = C.Refused status code
      refusedStep step lane prior failure = L.requestStep step 5 (L.Declared (Left failure)) lane prior
      retained (step,lane,after) prior failure code =
        refusedWith failure step && L.installedRead after == L.installedRead prior && L.installedStale after == Just code
          && laneShape lane == laneShape endedLane && not (L.resendOffered lane)
  checks
    [ ("a result with a stale ticket is not installed and leaves the lane and observation unchanged",
        case staleTicket of (step,lane,after) -> isStale step && after == priorAfter && laneShape lane == laneShape afterLane),
      ("a result for another request is not installed", case otherRequest of (step,lane,after) -> isStale step && after == priorAfter && laneShape lane == laneShape endedLane),
      ("a composite with an invalid component is not installed and keeps the observation and command state",
        retained invalid priorAfter C.InvalidResponse "InvalidResponse"),
      ("a current composite is installed in one step and clears the stale mark",
        case installed of (L.RequestInstalled value,lane,after) -> value == composite && after == L.Installed (Just composite) Nothing
                                                                    && laneShape lane == laneShape endedLane; _ -> False),
      ("an internal fault installs nothing and records the fault",
        case faulted of (L.RequestFaulted,lane,after) -> after == priorAfter && L.laneFault lane && L.laneReadTicket lane == Nothing; _ -> False),
      ("a declared 503 before association keeps the prior observation and marks it stale",
        retained (refusedStep (S.readVerdict binding beforeSelection) beforeLane priorBefore (refusal 503 "storage-unavailable")) priorBefore
          (refusal 503 "storage-unavailable") "503 storage-unavailable"),
      ("a declared 429 before association keeps the prior observation and marks it stale",
        retained (refusedStep (S.readVerdict binding beforeSelection) beforeLane priorBefore (refusal 429 "storage-quota")) priorBefore
          (refusal 429 "storage-quota") "429 storage-quota"),
      ("a declared 503 after association keeps the prior observation and marks it stale",
        retained (refusedStep verdict afterLane priorAfter (refusal 503 "storage-unavailable")) priorAfter
          (refusal 503 "storage-unavailable") "503 storage-unavailable"),
      ("a declared 429 after association keeps the prior observation and marks it stale",
        retained (refusedStep verdict afterLane priorAfter (refusal 429 "storage-quota")) priorAfter (refusal 429 "storage-quota") "429 storage-quota"),
      ("a declared 410 after association keeps the prior observation and marks it stale",
        retained (refusedStep verdict afterLane priorAfter (refusal 410 "view-expired")) priorAfter (refusal 410 "view-expired") "410 view-expired"),
      ("a refusal before any complete observation installs nothing",
        retained (refusedStep verdict afterLane L.noObservation (refusal 503 "storage-unavailable")) (L.noObservation :: L.Installed (S.RequestRead (T.Text,T.Text)))
          (refusal 503 "storage-unavailable") "503 storage-unavailable"),
      ("a later valid read after a refused one installs",
        case stepBefore 5 (L.Declared (Right firstAssociation)) beforeLane (priorBefore {L.installedStale = Just "503 storage-unavailable"}) of
          (L.RequestInstalled _,_,after) -> after == L.Installed (Just firstAssociation) Nothing; _ -> False)
    ]
  -- Runtime status, retention of public fields and the observation lines.
  let absentLines = S.observationLines False Nothing True (Just absentRuntime)
  checks
    [ ("a null runtime yields no status", S.runtimeStatus absentRuntime == Nothing),
      ("a null runtime is shown as not yet observed, not as a status", absentLines == ["Observation: current", "Runtime: not yet observed"]),
      ("a published runtime status is shown", S.observationLines False Nothing True (Just snapshot) == ["Observation: current", "Runtime: Running"]),
      ("a stale mark names its refusal code and the retained observation",
        S.observationLines False (Just "503 storage-unavailable") True Nothing == ["Observation: stale (503 storage-unavailable); the last complete observation is retained"]),
      ("a refusal without an installed observation claims no retained observation",
        S.observationLines False (Just "503 storage-unavailable") False Nothing == ["Observation: refused (503 storage-unavailable); no complete observation is installed"]),
      ("no observation lines precede the first read", null (S.observationLines False Nothing False Nothing)),
      ("a paused refresh replaces the current-observation line and keeps the runtime line",
        S.observationLines True Nothing True (Just snapshot) == ["Observation: automatic refresh paused after a deferred key", "Runtime: Running"]),
      ("a paused refresh does not hide a stale observation",
        S.observationLines True (Just "503 storage-unavailable") True Nothing == ["Observation: stale (503 storage-unavailable); the last complete observation is retained"]),
      ("a refusal code carries the status and problem code", L.refusalCode (C.Refused 429 "storage-quota") == "429 storage-quota")
    ]
  let acknowledgement = object ["commandId" .= ("cmd_4" :: T.Text), "state" .= ("delivered" :: T.Text), "message" .= ("answered" :: T.Text),
        "command" .= ("answer" :: T.Text), "occurrenceId" .= ("0" :: T.Text), "attemptId" .= Null]
      enriched = put "authoredOrder" (Array (V.fromList [String "0"])) (put "controlAcks" (Array (V.fromList [acknowledgement]))
        (put "billFresh" (String "18446744073709551617") (put "billMemo" (String "5") metadata)))
      answered = [if lookupKey "occurrenceId" item == Just (String "0") then put "answer" (String "false") item else item | item <- items]
  retainedFields <- either (die . show) pure (S.decodeSnapshot enriched answered)
  native <- maybe (die "FAIL missing runtime") pure (S.runSnapshot retainedFields)
  check "authored order, acknowledgements and exact bills are retained"
    (snapshotAuthoredOrder native == [OccurrenceId 0] && snapshotBillFresh native == Just 18446744073709551617 && snapshotBillMemo native == Just 5
      && fmap snapshotControlCommand (Map.lookup "cmd_4" (snapshotControlAcks native)) == Just (Just "answer")
      && fmap snapshotControlOccurrence (Map.lookup "cmd_4" (snapshotControlAcks native)) == Just (Just (OccurrenceId 0))
      && S.runItems retainedFields == answered && S.runMetadata retainedFields == enriched)
  check "the published answer, the answering party and the decision id of an occurrence are retained"
    (fmap snapshotOccurrenceAnswer (Map.lookup (OccurrenceId 0) (snapshotOccurrences native)) == Just (Just "false")
      && snapshotPersonAnswering native == Just PersonAnswerLocalControl
      && Map.lookup (OccurrenceId 0) (S.runDecisionIds retainedFields) == Just (Just "decision_3"))
  -- Receipts: only a readable receipt of the attempt settles or resolves it.
  approvalValue <- BS.readFile "test/fixtures/manager/v1/valid/approval-command.json" >>= either die pure . eitherDecodeStrict'
  unresolvedValue <- BS.readFile "test/fixtures/manager/v1/valid/command-unresolved.json" >>= either die pure . eitherDecodeStrict'
  approvalReceipt <- either (die . show) pure (C.decodeObservation approvalValue)
  unresolvedReceipt <- either (die . show) pure (C.decodeObservation unresolvedValue)
  approvalUnresolved <- either (die . show) pure (C.decodeObservation (put "state" (String "unresolved")
    (put "dispatchAttemptedAt" (String "2026-09-03T00:00:00Z") approvalValue)))
  let approval = S.Approve request0 preparation
      enqueue = S.Enqueue request0
      hidden = Left (C.Refused 403 "receipt-hidden")
      unreadable = Just (approval, hidden)
  checks
    [ ("an unreadable receipt leaves the approval status unresolved",
        S.approvalStatus approval unreadable Nothing == "outcome unresolved (receipt read unavailable)"),
      ("an unreadable receipt keeps the earlier receipt state without resolving it",
        S.approvalStatus approval unreadable (Just "accepted") == "accepted (receipt read unavailable)"
          && S.approvalStatus approval unreadable (Just "accepted (receipt read unavailable)") == "accepted (receipt read unavailable)"),
      ("a readable approval receipt sets its state", S.approvalStatus approval (Just (approval, Right approvalReceipt)) Nothing == "accepted"),
      ("an unreadable receipt settles nothing, so it offers no resend", S.receiptSettlement approval unreadable == Nothing),
      ("an unrelated unresolved receipt settles nothing", S.receiptSettlement approval (Just (approval, Right unresolvedReceipt)) == Nothing),
      ("a readable unresolved receipt of the attempt settles it with its declared state",
        S.receiptSettlement approval (Just (approval, Right approvalUnresolved)) == Just "unresolved"),
      ("an accepted receipt of the attempt settles nothing", S.receiptSettlement approval (Just (approval, Right approvalReceipt)) == Nothing)
    ]
  -- Honest uncertainty: an unread, unmatched or unrelated receipt never
  -- supplies or removes an approval state, a status line never claims an
  -- observation that is not installed, and a changed run association is
  -- never discarded silently.
  checks
    [ ("an associated approval whose receipt was not read shows outcome unresolved",
        S.approvalStatus approval Nothing Nothing == "outcome unresolved"),
      ("an associated approval whose read receipt does not match shows outcome unresolved",
        S.approvalStatus approval (Just (approval, Right unresolvedReceipt)) Nothing == "outcome unresolved"),
      ("an unreadable receipt of an unrelated command keeps the approval status unchanged",
        S.approvalStatus approval (Just (enqueue, hidden)) (Just "accepted") == "accepted"),
      ("an unreadable receipt of an unrelated command leaves a new approval outcome unresolved without the unavailable mark",
        S.approvalStatus approval (Just (enqueue, hidden)) Nothing == "outcome unresolved"),
      ("an unreadable receipt of an unrelated command settles nothing and offers no resend",
        S.receiptSettlement approval (Just (enqueue, hidden)) == Nothing && S.receiptSettlement enqueue (Just (enqueue, hidden)) == Nothing),
      ("the status after a refusal with an installed observation states that it is retained",
        L.staleStatus "503 storage-unavailable" True == "observation stale: 503 storage-unavailable; the last complete observation is retained"),
      ("the status after a refusal without an installed observation claims no retained observation",
        L.staleStatus "503 storage-unavailable" False == "observation refused: 503 storage-unavailable; no complete observation is installed"),
      ("a composite that names another run than the selected one is invalid, not foreign",
        S.readVerdict binding (S.Selection "req_8" (Just "run_other")) composite == S.ReadInvalid),
      ("a composite that names no run after association is invalid, not foreign",
        S.readVerdict binding afterSelection before == S.ReadInvalid),
      ("a result that names another run is not installed and marks the observation stale",
        retained otherRun priorAfter C.InvalidResponse "InvalidResponse")
    ]
  -- The mutation-key admission policy over every lane.
  let attempt = L.Attempt create ("pending" :: T.Text) (Just ("/v1/commands/cmd_1" :: T.Text))
      mutations =
        [ ("idle", L.MutationIdle), ("preparing", L.MutationPreparing 3 create), ("sending", L.MutationSending 3 attempt),
          ("awaiting", awaiting), ("declared uncertainty", L.MutationUncertain attempt (L.DeclaredUncertainty "TransportUnavailable")),
          ("fault uncertainty", L.MutationUncertain attempt L.FaultUncertainty) ] :: [(String, L.MutationState T.Text T.Text)]
      tickets = [Nothing, Just (L.ReadTicket 4 L.SingleResourceRead), Just (L.ReadTicket 4 L.PageSetRead)]
      lanes = [ (name, ticket, L.Lane ticket state faultedLane confirm)
              | (name,state) <- mutations, ticket <- tickets, faultedLane <- [False,True], confirm <- [False,True] ]
      pageSet ticket = fmap L.ticketKind ticket == Just L.PageSetRead
      resendStarts admission = case admission of L.ResendStart _ -> True; _ -> False
      resendDefers admission = case admission of L.ResendDeferred -> True; _ -> False
  check "the admission enumeration spans 6 command states, 3 read states, 2 fault states and 2 confirmation states" (length lanes == 72)
  checks
    [ ("a new-mutation key starts exactly on an idle lane without a fault and without a page-set read",
        and [(L.mutationAdmission lane == L.KeyStart) == (name == "idle" && not (L.laneFault lane) && not (pageSet ticket)) | (name,ticket,lane) <- lanes]),
      ("a new-mutation key during a page-set read on an idle lane without a fault defers visibly",
        and [L.mutationAdmission lane == L.KeyDeferred | (name,ticket,lane) <- lanes, name == "idle", not (L.laneFault lane), pageSet ticket]),
      ("a new-mutation key during a single-resource read on an idle lane starts after that read ends",
        and [L.mutationAdmission lane == L.KeyStart && L.laneReadTicket (L.beginMutation 9 create lane) == Nothing
              && laneShape (L.beginMutation 9 create lane) == laneShape (L.Lane Nothing (L.MutationPreparing 9 create) (L.laneFault lane) False)
            | (name,ticket,lane) <- lanes, name == "idle", not (L.laneFault lane), fmap L.ticketKind ticket == Just L.SingleResourceRead]),
      ("a new-mutation key during a command is refused as busy", and [L.mutationAdmission lane == L.KeyBusy | (name,_,lane) <- lanes, name /= "idle"]),
      ("a new-mutation key on an idle lane after a fault is refused", and [L.mutationAdmission lane == L.KeyFaulted | (name,_,lane) <- lanes, name == "idle", L.laneFault lane]),
      ("pure: no new-mutation key outcome lacks a text: every outcome but a start has a fixed text",
        and [maybe (L.mutationAdmission lane == L.KeyStart) (not . T.null) (L.admissionText "enqueue" (L.mutationAdmission lane)) | (_,_,lane) <- lanes]
          && all (\admission -> (L.admissionText "enqueue" admission == Nothing) == (admission == L.KeyStart)) [minBound .. maxBound]),
      ("a resend confirmation starts exactly for a declared uncertainty without a fault and without a page-set read",
        and [resendStarts (L.resendAdmission lane) == (name == "declared uncertainty" && not (L.laneFault lane) && not (pageSet ticket)) | (name,ticket,lane) <- lanes]),
      ("a resend confirmation during a page-set read defers visibly",
        and [resendDefers (L.resendAdmission lane) == (name == "declared uncertainty" && not (L.laneFault lane) && pageSet ticket) | (name,ticket,lane) <- lanes]),
      ("a resend start carries the retained attempt unchanged",
        and [case L.resendAdmission lane of L.ResendStart retainedAttempt -> L.attemptPending retainedAttempt == "pending"
                                                                  && L.attemptLocation retainedAttempt == Just "/v1/commands/cmd_1"; _ -> True | (_,_,lane) <- lanes]),
      ("no read starts while another read holds the ticket",
        and [null (L.startRead 8 L.SingleResourceRead lane) == (ticket /= Nothing) | (_,ticket,lane) <- lanes]
          && fmap L.laneReadTicket (L.startRead 8 L.PageSetRead (L.Lane Nothing L.MutationIdle False False :: L.Lane T.Text T.Text))
            == Just (Just (L.ReadTicket 8 L.PageSetRead))),
      ("golden: the deferral, busy, fault, help, validator and resend texts are fixed",
        L.admissionText "enqueue" L.KeyDeferred == Just "enqueue deferred during a page-set read. Press the key again."
          && L.admissionText "create" L.KeyBusy == Just "create did not start: a command is in progress or unresolved."
          && L.admissionText "set-input" L.KeyFaulted == Just "set-input did not start: an internal fault stopped all mutations."
          && L.keyHelpText "create" == "create did not start: the key help is open. Esc closes it."
          && L.unobservedText "set-input" == "set-input did not start: the request validator is not yet observed."
          && L.resendDeferredText == "exact resend deferred during a page-set read. Press y again."
          && L.resendUnofferedText == "exact resend did not start: no exact resend is offered.")
    ]
  -- The visible outcome of a mutation key that starts nothing lasts until the
  -- next key press or until the view changes. Reads, installs and ticks that
  -- keep the view do not remove it.
  let deferredAt = read "2026-09-30 12:00:00 UTC" :: UTCTime
      deferredBy = Just (L.Deferral 4 deferredAt)
      outcome serial = Just (L.KeyOutcome serial "enqueue deferred during a page-set read. Press the key again." deferredBy)
      screenA = "request screen" :: String
      screenB = "command screen" :: String
      pressed = L.retainKeyOutcome True screenA screenA Nothing (outcome 1)
      afterRead = L.retainKeyOutcome False screenA screenA pressed pressed
      afterInstall = L.retainKeyOutcome False screenA screenA afterRead afterRead
      nextKey = L.retainKeyOutcome True screenA screenA afterInstall afterInstall
      repeated = L.retainKeyOutcome True screenA screenA afterInstall (outcome 2)
      moved = L.retainKeyOutcome False screenA screenB afterInstall afterInstall
      operations = ["create", "set-input", "enqueue", "answer"]
      outcomeTexts = [text | operation <- operations, Just text <- map (L.admissionText operation) [minBound .. maxBound]]
        <> map L.keyHelpText operations <> map L.unobservedText operations <> [L.resendDeferredText, L.resendUnofferedText]
      -- The deferring page-set read holds ticket 4. A later read holds ticket 5.
      reading = L.Lane (Just (L.ReadTicket 4 L.PageSetRead)) L.MutationIdle False False :: L.Lane T.Text T.Text
      completed = reading {L.laneReadTicket = Nothing}
      nextRead = reading {L.laneReadTicket = Just (L.ReadTicket 5 L.PageSetRead)}
      after seconds = addUTCTime seconds deferredAt
  checks
    [ ("a key outcome is shown after the press that produced it", pressed == outcome 1),
      ("a key outcome survives a read start and an install that keep the view", afterRead == outcome 1 && afterInstall == outcome 1),
      ("the next key press that produces nothing ends the key outcome", nextKey == Nothing),
      ("a repeated press that is refused again shows its own numbered outcome", repeated == outcome 2),
      ("an event that changes the view ends the key outcome", moved == Nothing),
      ("every key outcome line fits an 80-column status line with a three-digit key number",
        all (\text -> T.length (L.keyOutcomeLine (L.KeyOutcome 999 text Nothing)) <= 80) outcomeTexts && length outcomeTexts == 22),
      ("a deferral records the page-set read in flight and the time of the key outcome",
        L.deferral deferredAt reading == deferredBy
          && L.deferral deferredAt completed == Nothing
          && L.deferral deferredAt reading {L.laneReadTicket = Just (L.ReadTicket 4 L.SingleResourceRead)} == Nothing),
      ("automatic refresh pauses while the deferring page-set read is in flight, through events that keep the view",
        all (L.refreshPaused (after 1) reading) [pressed, afterRead, afterInstall]),
      ("the pause ends when the deferring page-set read completes, before the limit",
        not (L.refreshPaused (after 1) completed afterInstall) && not (L.refreshPaused (after 1) nextRead afterInstall)),
      ("the pause ends 3 seconds after the key outcome while the deferring read is still in flight",
        L.refreshPauseLimit == 3 && L.refreshPaused (after 2.999) reading afterInstall
          && not (L.refreshPaused (after 3) reading afterInstall) && not (L.refreshPaused (after 60) reading afterInstall)),
      ("automatic refresh resumes after the next key press or a view change ends the deferral",
        not (L.refreshPaused (after 1) reading nextKey) && not (L.refreshPaused (after 1) reading moved)),
      ("a key outcome that is not a deferral does not pause refresh",
        not (L.refreshPaused (after 1) reading (Just (L.KeyOutcome 3 "enqueue did not start: a command is in progress or unresolved." Nothing)))
          && not (L.refreshPaused (after 1) reading Nothing))
    ]
  -- The retrieval of the verified result retries a failure. An automatic
  -- refresh retries after the next installed composite read, and g retries
  -- at once. Only retrieved bytes are retained, and they are never retrieved
  -- again.
  let bytesOf = "verified bytes" :: T.Text
      refusedOnce = L.retrievalStep "run_21" (Left (C.Refused 503 "storage-unavailable") :: Either C.ClientFailure (Maybe T.Text))
      noneYet = L.retrievalStep "run_21" (Right Nothing :: Either C.ClientFailure (Maybe T.Text))
      retrievedOnce = L.retrievalStep "run_21" (Right (Just bytesOf))
      due cause retrieval = L.retrievalDue cause "run_21" retrieval
  checks
    [ ("a run without a retrieval is retrieved on an automatic and an explicit refresh",
        due L.AutomaticRefresh Nothing && due L.ExplicitRefresh Nothing
          && due L.AutomaticRefresh (Just (L.Retrieval "run_other" (L.Retrieved bytesOf)))),
      ("a refusal and a retrieval without a verified result are retryable failures, not retained bytes",
        refusedOnce == L.Retrieval "run_21" (L.RetrievalFailed "503 storage-unavailable" False)
          && noneYet == L.Retrieval "run_21" (L.RetrievalFailed "no verified result" False)
          && L.retrievedResult "run_21" (Just refusedOnce) == Nothing && L.retrievedResult "run_21" (Just noneYet) == Nothing),
      ("after a failure an automatic refresh reads the observation first and does not retrieve",
        not (due L.AutomaticRefresh (Just noneYet)) && not (due L.AutomaticRefresh (Just refusedOnce))),
      ("after a failure g retries the retrieval at once",
        due L.ExplicitRefresh (Just noneYet) && due L.ExplicitRefresh (Just refusedOnce)),
      ("an installed composite read makes the failed retrieval due for the next automatic refresh",
        due L.AutomaticRefresh (L.retrievalObserved (Just noneYet)) && due L.AutomaticRefresh (L.retrievalObserved (Just refusedOnce))),
      ("a retry that finds the verified state retains the bytes, and they are not retrieved again",
        L.retrievedResult "run_21" (Just retrievedOnce) == Just bytesOf
          && not (due L.AutomaticRefresh (Just retrievedOnce)) && not (due L.ExplicitRefresh (Just retrievedOnce))
          && L.retrievalObserved (Just retrievedOnce) == Just retrievedOnce),
      ("the retained bytes belong to their run only", L.retrievedResult "run_other" (Just retrievedOnce) == Nothing
          && L.retrievalShown "run_other" (Just retrievedOnce) == Nothing),
      ("the result lines show a failure as retried and the bytes as retrieved",
        L.retrievalShown "run_21" (Just noneYet) == Just (Left "no verified result")
          && L.retrievalShown "run_21" (Just retrievedOnce) == Just (Right bytesOf)),
      ("golden: the status line states the failure and the retry",
        L.retrievalStatus noneYet == "verified result not retrieved: no verified result; the next refresh retries"
          && L.retrievalStatus refusedOnce == "verified result not retrieved: 503 storage-unavailable; the next refresh retries"
          && L.retrievalStatus retrievedOnce == "verified result retrieved")
    ]
  let busyText = maybe "" id (L.admissionText "enqueue" L.KeyBusy)
      loadingModel = (initialServiceModel [profile]) {modelScreen = ServiceRequestScreen associated, modelStatus = "loading manager catalogue"}
      outcomePresentation = (emptyPresentation loadingModel) {presentationService = True, presentationNoColor = True,
        presentationServiceKeyOutcome = Just (L.KeyOutcome 3 busyText Nothing)}
  mapM_ (\size -> do
      let frame = render size outcomePresentation
      check ("the status line at " <> show size <> " shows the key outcome while a read replaces the status text")
        (L.keyOutcomeLine (L.KeyOutcome 3 busyText Nothing) `T.isInfixOf` frame && not ("loading manager catalogue" `T.isInfixOf` frame)))
    [(100,30),(80,24)]
  -- A refused request read keeps the request screen and states the refusal.
  -- App applies 'refuseRequestRead' to a refused request read and
  -- 'refuseCatalogueRead' to a refused catalogue read.
  let requestModel = (initialServiceModel [profile]) {modelScreen = ServiceRequestScreen associated, modelStatus = "manager request: associated"}
      staleModel = refuseRequestRead "503 storage-unavailable" True requestModel
      refusedModel = refuseRequestRead "503 storage-unavailable" False requestModel
      catalogueModel = refuseCatalogueRead "Refused 503 \"storage-unavailable\"" requestModel
  checks
    [ ("a refused request read with an installed observation keeps the request screen and states the retained observation",
        modelScreen staleModel == ServiceRequestScreen associated && modelStatus staleModel == L.staleStatus "503 storage-unavailable" True),
      ("a refused request read without an installed observation keeps the request screen and claims no retained observation",
        modelScreen refusedModel == ServiceRequestScreen associated && modelStatus refusedModel == L.staleStatus "503 storage-unavailable" False),
      ("only a refused catalogue read replaces the screen with the refusal",
        modelScreen catalogueModel == ServiceCommandScreen "Observation refused: Refused 503 \"storage-unavailable\"")
    ]
  let presentationOf model kept = (emptyPresentation model) {presentationService = True, presentationNoColor = True,
        presentationServiceObservation = S.observationLines False (Just "503 storage-unavailable") kept (if kept then Just snapshot else Nothing)}
      stalePresentation = presentationOf staleModel True
      refusedPresentation = presentationOf refusedModel False
  mapM_ (\size -> do
      let staleFrame = render size stalePresentation
          refusedFrame = render size refusedPresentation
      check ("the stale request screen at " <> show size <> " keeps the request and names the refusal")
        (all (`T.isInfixOf` staleFrame) ["Request: req_8", "Run: run_21", "stale (503 storage-unavailable)", "Runtime: Running",
          "observation stale: 503 storage-unavailable"]
          && not ("Observation refused" `T.isInfixOf` staleFrame) && not ("no complete observation" `T.isInfixOf` staleFrame))
      check ("the refused request screen at " <> show size <> " claims no retained observation on any line")
        (all (`T.isInfixOf` refusedFrame) ["Request: req_8", "refused (503 storage-unavailable)", "observation refused: 503 storage-unavailable"]
          && not ("retained" `T.isInfixOf` refusedFrame)))
    [(100,30),(80,24)]
  putStrLn "RENDER stale request observation at (80,24):" >> putStr (T.unpack (render (80,24) stalePresentation))
  putStrLn "RENDER refused request observation at (80,24):" >> putStr (T.unpack (render (80,24) refusedPresentation))

-- | The install decision for a composite read with run components, and
-- fixed-size renders of the live monitor in service mode. Each rendered model
-- comes from 'serviceRunObserved' on an idle lane: the live screen of the run,
-- with the published runtime as the displayed snapshot, or no snapshot when
-- the runtime is absent.
liveTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> C.DraftView -> (Value,[Value]) -> IO ()
liveTests render profile request0 (metadata,items) = do
  let maximumId = "18446744073709551615" :: T.Text
      acknowledgement = object ["commandId" .= ("cmd_4" :: T.Text), "state" .= ("delivered" :: T.Text), "message" .= ("answered" :: T.Text),
        "command" .= ("answer" :: T.Text), "occurrenceId" .= ("0" :: T.Text), "attemptId" .= Null]
      enriched = put "authoredOrder" (Array (V.fromList [String maximumId, String "0"])) (put "traceRecorded" (Bool True)
        (put "controlAcks" (Array (V.fromList [acknowledgement])) (put "billFresh" (String "7") (put "billMemo" (String "5") metadata))))
      routed = [if lookupKey "occurrenceId" item == Just (String maximumId)
                  then put "dispatch" (object ["targets" .= (["alpha", "beta"] :: [T.Text]), "open" .= True, "redirect" .= Null]) item
                  else item | item <- items]
      withOutput text = [alter "attempts" (\attempts -> case attempts of
                            Array values -> Array (V.map (put "output" (String text)) values)
                            other -> other) item | item <- routed]
  observation <- either (die . show) pure (S.decodeSnapshot enriched routed)
  native <- maybe (die "FAIL missing runtime") pure (S.runSnapshot observation)
  absent <- either (die . show) pure (S.decodeSnapshot (put "runtime" Null enriched) routed)
  let run = snapshotRunId native
      associated = request0 {C.draftPhase = "associated", C.draftRun = Just "run_21"}
      serviceModel = initialServiceModel [profile]
      requestModel = serviceModel {modelScreen = ServiceRequestScreen associated}
      runOf observed = Just (S.runIdentity observed, S.runSnapshot observed)
      installed observed = maybe (die "FAIL an idle read with a run did not install the live monitor") pure
        (serviceRunObserved True (runOf observed) requestModel)
  liveModel <- installed observation
  absentModel <- installed absent
  -- The decision that App.applyServiceObservation takes for every installed
  -- composite read before it chooses a request or review screen.
  let decided idle observed screen = serviceRunObserved idle observed (serviceModel {modelScreen = screen})
  checks
    [ ("an idle read with a run and a published runtime shows the run in the live monitor with that runtime as the snapshot",
        (modelScreen <$> decided True (runOf observation) (ServiceRequestScreen associated)) == Just (LiveScreen run)
          && (modelSnapshot =<< decided True (runOf observation) (ServiceRequestScreen associated)) == Just native),
      ("an idle read with a run and an absent runtime shows the run in the live monitor without a snapshot",
        (modelScreen <$> decided True (runOf absent) (ServiceRequestScreen associated)) == Just (LiveScreen run)
          && fmap modelSnapshot (decided True (runOf absent) (ServiceRequestScreen associated)) == Just Nothing
          && S.runIdentity absent == run),
      ("a later idle read on the live monitor replaces the displayed snapshot with the new runtime",
        fmap modelSnapshot (serviceRunObserved True (runOf absent) liveModel) == Just Nothing
          && fmap modelSnapshot (serviceRunObserved True (runOf observation) absentModel) == Just (Just native)),
      ("a busy command lane keeps the screen when a read carries a run",
        decided False (runOf observation) (ServiceRequestScreen associated) == Nothing
          && serviceRunObserved False (runOf absent) liveModel == Nothing),
      ("the input screen keeps its screen when a read carries a run", decided True (runOf observation) (InputScreen 0) == Nothing),
      ("a read without run components leaves the screen to the request and review decision",
        decided True Nothing (ServiceRequestScreen associated) == Nothing && decided True Nothing (ServiceCommandScreen "notice") == Nothing)
    ]
  let livePresentation model observed stale layer = (emptyPresentation model)
        { presentationService = True, presentationNoColor = True, presentationLayer = layer,
          presentationServiceRequestLines = serviceRequestLines associated,
          presentationRunView = maybe emptyRunView (`reconcileRunView` emptyRunView) (modelSnapshot model),
          presentationServiceApproval = Just "dispatch-attempted",
          presentationServiceRun = Just observed,
          presentationServiceObservation = S.observationLines False stale True (Just observed) }
      frame = render (140,36) (livePresentation liveModel observation Nothing ScreenLayer)
      details = render (140,36) (livePresentation liveModel observation Nothing RunDetailsLayer)
      staleFrame = render (140,36) (livePresentation liveModel observation (Just "503 storage-unavailable") ScreenLayer)
      absentFrame = render (140,36) (livePresentation absentModel absent Nothing ScreenLayer)
      localOnly = ["steer", "Steer", "route", "Routes", "CANCEL", "cancel", "LINEAGE", "lineage", "Esc RUNS", "Esc DETACH", "Esc detaches",
        "RESULT AVAILABLE", "r result", "s save", "restart", "resume", "fork", "persona none", "target pending"]
      runtimeLabels = ["Starting", "Running", "Cancelling", "Succeeded", "Failed", "Cancelled", "Owner unavailable"]
  checks
    [ ("the maximum public occurrence id keeps its exact one-based number in the rows and the output title at (140,36)",
        all (`T.isInfixOf` frame) ["> 18446744073709551616", "Output · Request 18446744073709551616"]
          && not ("Request 0 " `T.isInfixOf` frame) && not ("> 0  Running" `T.isInfixOf` frame)),
      ("the service live monitor at (140,36) names the request, its phase and its run",
        all (`T.isInfixOf` frame) ["Request: req_8", "Phase: associated", "Run: run_21"]),
      ("the service live monitor at (140,36) shows the retained Unicode output, the exact bills and elapsed unknown",
        all (`T.isInfixOf` frame) ["雪😀", "bill 7 fresh / 5 memo", "elapsed unknown"]),
      ("the service live monitor at (140,36) shows the observation, the published runtime and the approval receipt on separate lines",
        all (`T.isInfixOf` frame) ["Observation: current", "Runtime: Running", "Approval receipt: dispatch-attempted"]
          && not ("Runtime: Running" `T.isInfixOf` T.concat (filter ("Approval receipt" `T.isInfixOf`) (T.lines frame)))),
      ("the service live monitor at (140,36) shows no local cancel, steer, redirect, lineage or local result text",
        not (any (`T.isInfixOf` frame) localOnly)),
      ("the service live monitor at (140,36) offers detach and details",
        all (`T.isInfixOf` frame) ["q DETACH", "d DETAILS"]),
      ("the service run details at (140,36) list the control acknowledgements and no local persona or realization",
        "control cmd_4: delivered — answered" `T.isInfixOf` details
          && not (any (`T.isInfixOf` details) ["persona: none", "realization: pending"])),
      ("a stale service observation at (140,36) shows its stale marker and refusal code beside the retained runtime",
        all (`T.isInfixOf` staleFrame) ["Observation: stale (503 storage-unavailable)", "Runtime: Running", "Approval receipt: dispatch-attempted"]),
      ("an absent runtime at (140,36) is shown as not yet observed, with no runtime status and no local text",
        "Runtime: not yet observed" `T.isInfixOf` absentFrame && "Approval receipt: dispatch-attempted" `T.isInfixOf` absentFrame
          && not (any (`T.isInfixOf` absentFrame) (runtimeLabels <> localOnly <> ["Waiting for run.started", "c cancels"])))
    ]
  -- Manager ids are long. A request line that also carried the run wrapped
  -- between "Run:" and the run id at 140 columns in the actual journey.
  let longRequest = "request_" <> T.replicate 48 "a"
      longRun = "run_" <> T.replicate 48 "b"
      longLines = serviceRequestLines (request0 {C.draftId = longRequest, C.draftPhase = "associated", C.draftRun = Just longRun})
      longFrame size = render size ((livePresentation liveModel observation Nothing ScreenLayer) {presentationServiceRequestLines = longLines})
  checks
    [ ("with manager-length ids the run id stays whole on one row at " <> show size,
        ("Run: " <> longRun) `T.isInfixOf` longFrame size && ("Request: " <> longRequest) `T.isInfixOf` longFrame size)
    | size <- [(140,36),(80,24)] ]
  -- The header names the published workflow and target whether or not the
  -- runtime is present. Only a null target label reads as not reported.
  noTarget <- either (die . show) pure (S.decodeSnapshot (put "targetLabel" Null (put "runtime" Null enriched)) routed)
  noTargetModel <- installed noTarget
  let noTargetFrame = render (140,36) (livePresentation noTargetModel noTarget Nothing ScreenLayer)
      failedModel = liveModel {modelSnapshot = Just native {snapshotRunFailure = Just (T.unwords (replicate 80 "failure"))}}
      failedFrame size = render size (livePresentation failedModel observation Nothing ScreenLayer)
      helpFrame = render (140,36) (livePresentation liveModel observation Nothing KeyHelpLayer)
  putStrLn "RENDER service live monitor with a long run failure at (80,20):" >> putStr (T.unpack (failedFrame (80,20)))
  checks
    [ ("an absent runtime at (140,36) still shows the published workflow and target in the header",
        all (`T.isInfixOf` absentFrame) ["review | runtime not yet observed", " target scripted"]
          && not ("target not reported" `T.isInfixOf` absentFrame)),
      ("a null target label with an absent runtime at (140,36) reads as not reported",
        " target not reported" `T.isInfixOf` noTargetFrame),
      ("a long run failure at (80,24) keeps the service lines, both panes, the selected output and the pointer to the details",
        all (`T.isInfixOf` failedFrame (80,24)) ["Run: run_21", "Runtime: Running", "Approval receipt: dispatch-attempted", "Run running",
          "... d DETAILS for the complete error", "Requests", "Output · Request 18446744073709551616", "> 184467440737095", "雪😀", "q DETACH"]),
      -- The failure banner counts the service lines above the panes, so the
      -- panes keep their first rows on a short screen.
      ("a long run failure at (80,20) keeps the service lines, the first rows of both panes and the pointer to the details",
        all (`T.isInfixOf` failedFrame (80,20)) ["Runtime: Running", "Approval receipt: dispatch-attempted", "Run running",
          "... d DETAILS for the complete error", "Output · Request", "> 184467440737095", "\x2502 model reviewer", "q DETACH"]),
      ("the service live key help at (140,36) lists the read-only keys and q detach, and no local action",
        all (`T.isInfixOf` helpFrame) ["d full run details and error", "g refreshes observations", "q detaches; the manager run continues"]
          && not (any (`T.isInfixOf` helpFrame) ["c cancel", "steer", "route", "result", "save"]))
    ]
  putStrLn "RENDER service live monitor at (140,36):" >> putStr (T.unpack frame)
  putStrLn "RENDER service live monitor with an absent runtime at (140,36):" >> putStr (T.unpack absentFrame)
  -- Terminal control sequences in manager-supplied run output, in a refusal
  -- code and in the status line reach the frame only as U+FFFD.
  let payload = "A\ESC[2JB\ESC]52;c;SGVsbG8=\a\&C\NUL\&D\x9b\&E" :: T.Text
      sanitized = "A\xfffd[2JB\xfffd]52;c;SGVsbG8=\xfffd\&C\xfffd\&D\xfffd\&E" :: T.Text
      hostileCode = "503 " <> payload
  hostile <- either (die . show) pure (S.decodeSnapshot enriched (withOutput payload))
  hostileNative <- maybe (die "FAIL missing hostile runtime") pure (S.runSnapshot hostile)
  let hostileModel = serviceModel {modelScreen = LiveScreen run, modelSnapshot = Just hostileNative,
        modelStatus = L.staleStatus hostileCode True}
      hostileFrame size layer = render size (livePresentation hostileModel hostile (Just hostileCode) layer)
      hostileSummary = hostileFrame (140,36) ScreenLayer
      hostileDetails = hostileFrame (140,36) RunDetailsLayer
      hostileSmall = hostileFrame (80,24) ScreenLayer
      hostileFrames = [hostileSummary, hostileDetails, hostileSmall, hostileFrame (80,24) RunDetailsLayer]
      raw = T.filter (\character -> character /= '\n' && (character < ' ' || (character >= '\DEL' && character <= '\x9f')))
  checks
    [ ("control sequences in run output render as U+FFFD at (140,36)", sanitized `T.isInfixOf` hostileSummary),
      ("control sequences in a refusal code render as U+FFFD in the stale marker at (140,36)",
        ("Observation: stale (503 " <> sanitized) `T.isInfixOf` hostileSummary),
      ("control sequences in the status line render as U+FFFD at (140,36)",
        ("observation stale: 503 " <> sanitized) `T.isInfixOf` hostileSummary),
      ("control sequences in run output render as U+FFFD in the run details at (140,36)", sanitized `T.isInfixOf` hostileDetails),
      ("no frame at (140,36) or (80,24), summary or details, contains a raw control character", all (T.null . raw) hostileFrames)
    ]
  putStrLn "RENDER hostile manager text in the service live monitor at (80,24):" >> putStr (T.unpack hostileSmall)
  -- Terminal control sequences in the published workflow, target and
  -- addressee, in the request id, phase and run, and in command-screen text
  -- reach the frame only as U+FFFD.
  let labelled = put "workflow" (String payload) (put "targetLabel" (String payload) enriched)
      addressed = [put "addressee" (String payload) item | item <- routed]
  hostileLabels <- either (die . show) pure (S.decodeSnapshot labelled addressed)
  hostileLabelsAbsent <- either (die . show) pure (S.decodeSnapshot (put "runtime" Null labelled) addressed)
  labelPresentModel <- installed hostileLabels
  labelAbsentModel <- installed hostileLabelsAbsent
  let hostileRequest = serviceRequestLines (request0 {C.draftId = payload, C.draftPhase = payload, C.draftRun = Just payload})
      labelFrame model observed = render (140,36) ((livePresentation model observed Nothing ScreenLayer) {presentationServiceRequestLines = hostileRequest})
      labelPresent = labelFrame labelPresentModel hostileLabels
      labelAbsent = labelFrame labelAbsentModel hostileLabelsAbsent
      commandFrame size = render size ((emptyPresentation (serviceModel {modelScreen = ServiceCommandScreen ("Observation refused: " <> payload)}))
        {presentationService = True, presentationNoColor = True})
  checks
    [ ("control sequences in the workflow, target and addressee render as U+FFFD with a runtime at (140,36)",
        all (`T.isInfixOf` labelPresent) [sanitized <> " | Running", " target " <> sanitized, "\x2502 " <> sanitized]),
      ("control sequences in the workflow and target render as U+FFFD with an absent runtime at (140,36)",
        all (`T.isInfixOf` labelAbsent) [sanitized <> " | runtime not yet observed", " target " <> sanitized]),
      ("control sequences in the request id, phase and run render as U+FFFD at (140,36)",
        all (`T.isInfixOf` labelPresent) ["Request: " <> sanitized <> "   Phase: " <> sanitized, "Run: " <> sanitized]),
      ("control sequences in command-screen text render as U+FFFD at (140,36)",
        ("Observation refused: " <> sanitized) `T.isInfixOf` commandFrame (140,36)),
      ("no label, request or command-screen frame contains a raw control character",
        all (T.null . raw) [labelPresent, labelAbsent, commandFrame (140,36), commandFrame (80,24)])
    ]

-- | The service decision head, the answer mutation and the rendering of
-- the head in service mode. The fixture run run_21 has a pending flag
-- question at occurrence 0, which decision_3 names as the owned head.
decisionTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> C.DraftView -> Value -> (Value,[Value])
  -> (Value,S.DecisionView) -> S.ControlView -> IO ()
decisionTests render profile request0 receiptValue (metadata,items) (decisionValue,decision) control = do
  snapshot <- either (die . show) pure (S.decodeSnapshot metadata items)
  otherRunId <- either (die . show) pure (mkRunId "run_other")
  let controlObs = ("/v1/runs/run_21/control", "\"controlrev_2\"") :: (T.Text,T.Text)
      decisionObs = ("/v1/decisions/decision_3", "\"decisionrev_1\"") :: (T.Text,T.Text)
      runRead = S.RunRead snapshot (controlObs,control) (Just (decisionObs,decision))
      withDecision changed = runRead {S.runReadDecision = Just (decisionObs,changed)}
      withControl changed = runRead {S.runReadControl = (controlObs,changed)}
      answer read' input = S.answerMutation "profile_main" read' input
      refused result = case result of Left _ -> True; Right _ -> False
      notPending = [put "personPending" (Bool False) item | item <- items]
  idle <- either (die . show) pure (S.decodeSnapshot metadata notPending)
  checks
    [ ("an owned pending head question is the decision head with its prompt",
        case S.decisionHead runRead of
          Just (S.QuestionHead view prompt) -> view == decision && S.decisionPrompt decision == Just prompt
          _ -> False),
      ("a head that the controls do not own is not shown", S.decisionHead (withControl control {S.controlSupervision = "lost"}) == Nothing),
      ("a decision that the controls do not name is not shown", S.decisionHead (withControl control {S.controlHead = Just "decision_4"}) == Nothing),
      ("a decision after position 0 is not shown", S.decisionHead (withDecision decision {S.decisionPosition = 1}) == Nothing),
      ("a decision that is no longer pending is not shown", S.decisionHead (withDecision decision {S.decisionState = "resolved"}) == Nothing),
      ("a decision for another run than the snapshot is not shown",
        S.decisionHead runRead {S.runReadSnapshot = snapshot {S.runIdentity = otherRunId}} == Nothing),
      ("a read without a decision has no head", S.decisionHead runRead {S.runReadDecision = Nothing} == Nothing)
    ]
  (mutation,observed) <- either (die . ("FAIL the fixture answer was refused: " <>) . T.unpack) pure (answer runRead "false")
  let encoded = TE.decodeUtf8 (BL.toStrict (encode (S.answerBody decision (Bool False))))
  checks
    [ ("the answer \"false\" to a flag question is the typed JSON false for the displayed decision",
        mutation == S.Answer decision (Bool False) && observed == decisionObs),
      ("the answer is sent to the decision URI with the decision profile",
        S.mutationOperation mutation == "answer" && S.mutationURI mutation == "/v1/decisions/decision_3" && S.mutationProfile mutation == "profile_main"),
      ("the encoded answer body carries \"value\":false and never a string",
        "\"value\":false" `T.isInfixOf` encoded && not ("\"value\":\"false\"" `T.isInfixOf` encoded)
          && all (`T.isInfixOf` encoded) ["\"operation\":\"answer\"", "\"occurrenceId\":\"0\"", "\"generation\":\"generation_3\""]),
      ("an unparsable flag input is refused before any send", refused (answer runRead "maybe") && refused (answer runRead "")),
      ("no answer is offered for another generation", refused (answer (withDecision decision {S.decisionGeneration = "generation_9"}) "false")),
      ("no answer is offered for a decision after position 0", refused (answer (withDecision decision {S.decisionPosition = 1}) "false")),
      ("no answer is offered for controls that are not owned", refused (answer (withControl control {S.controlSupervision = "observer"}) "false")),
      ("no answer is offered for another run", refused (answer runRead {S.runReadSnapshot = snapshot {S.runIdentity = otherRunId}} "false")
          && refused (answer (withDecision decision {S.decisionRun = "run_other"}) "false")),
      ("no answer is offered for another profile", refused (S.answerMutation "profile_other" runRead "false")),
      ("no answer is offered for a decision that is not the head", refused (answer (withControl control {S.controlHead = Just "decision_4"}) "false")
          && refused (answer runRead {S.runReadDecision = Nothing} "false")),
      ("no answer is offered when the occurrence no longer waits for an answer", refused (answer runRead {S.runReadSnapshot = idle} "false")),
      ("no answer is offered without the manager answer offer", refused (answer (withControl control {S.controlOffers = []}) "false"))
    ]
  -- Only an answer receipt for the decision, with an effect whose address is
  -- the answered occurrence of the run controls, completes the answer.
  let effect occurrence resource = object ["kind" .= ("answer-accepted" :: T.Text), "runtimeSequence" .= ("12" :: T.Text),
        "address" .= object ["occurrenceId" .= (occurrence :: T.Text)], "resource" .= (resource :: T.Text)]
      answerReceipt value = put "operation" (String "answer") (put "requiredScopes" (toJSON ["control" :: T.Text])
        (put "resource" (String "/v1/decisions/decision_3") (put "links" (object ["self" .= ("/v1/commands/cmd_11" :: T.Text),
          "resource" .= ("/v1/decisions/decision_3" :: T.Text)]) (put "state" (String "effect-observed") (put "effect" value
            (put "dispatchAttemptedAt" (String "2026-09-03T00:00:01Z") receiptValue))))))
      decodedReceipt value = either (die . ("FAIL answer receipt fixture: " <>) . show) pure (C.decodeObservation (answerReceipt value))
  matching <- decodedReceipt (effect "0" "/v1/runs/run_21/control")
  otherOccurrence <- decodedReceipt (effect "1" "/v1/runs/run_21/control")
  otherResource <- decodedReceipt (effect "0" "/v1/runs/run_other/control")
  checks
    [ ("an answer-accepted effect for the answered occurrence of the run matches the answer",
        S.receiptMatches mutation matching && S.receiptEffectKind matching == Just "answer-accepted"),
      ("an answer effect for another occurrence does not complete the answer", not (S.receiptMatches mutation otherOccurrence)),
      ("an answer effect for another run does not complete the answer", not (S.receiptMatches mutation otherResource)),
      ("an answer receipt does not complete another decision", not (S.receiptMatches (S.Answer decision {S.decisionId = "decision_4"} (Bool False)) matching))
    ]
  -- The recovery head carries the recovery that the snapshot publishes.
  let recoveryObject = object ["gap" .= ("adapter gap" :: T.Text), "message" .= ("Retry the adapter?" :: T.Text),
        "retries" .= ([] :: [T.Text]), "choices" .= [object ["choice" .= ("retry" :: T.Text), "target" .= Null]], "chosen" .= Null]
      recovering = [if lookupKey "occurrenceId" item == Just (String "0") then put "personPending" (Bool False) (put "recovery" recoveryObject item) else item | item <- items]
      recoveryValue = put "kind" (String "recovery") (put "gap" (String "adapter gap") (put "message" (String "Retry the adapter?")
        (put "choices" (toJSON [object ["choice" .= ("retry" :: T.Text), "target" .= Null]]) (remove "question" decisionValue))))
  recoverySnapshot <- either (die . show) pure (S.decodeSnapshot metadata recovering)
  recoveryDecision <- either (die . show) pure (S.decodeDecision recoveryValue)
  let recoveryRead = S.RunRead recoverySnapshot (controlObs,control {S.controlOffers = []}) (Just (decisionObs,recoveryDecision))
  recoveryHead <- case S.decisionHead recoveryRead of
    Just (S.RecoveryHead view occurrence recovery) | view == recoveryDecision -> pure (occurrence,recovery)
    _ -> die "FAIL an owned pending head recovery with a published snapshot recovery is not the decision head"
  checks
    [ ("a recovery head without the snapshot recovery is not shown",
        S.decisionHead recoveryRead {S.runReadSnapshot = snapshot} == Nothing),
      ("a recovery head offers no answer", refused (answer recoveryRead "false"))
    ]
  -- The head renders in service mode below the service lines, without local
  -- keys, and manager text reaches the frame only through safeDisplay.
  native <- maybe (die "FAIL missing runtime") pure (S.runSnapshot snapshot)
  prompt <- maybe (die "FAIL missing prompt") pure (S.decisionPrompt decision)
  let associated = request0 {C.draftPhase = "associated", C.draftRun = Just "run_21"}
      model = (initialServiceModel [profile]) {modelScreen = LiveScreen (S.runIdentity snapshot), modelSnapshot = Just native}
      headPresentation layer = (emptyPresentation model)
        { presentationService = True, presentationNoColor = True, presentationLayer = layer,
          presentationServiceRequestLines = serviceRequestLines associated,
          presentationRunView = reconcileRunView native emptyRunView,
          presentationServiceApproval = Just "dispatch-attempted",
          presentationServiceRun = Just snapshot,
          presentationServiceObservation = S.observationLines False Nothing True (Just snapshot) }
      question = render (140,36) (headPresentation PersonLayer) {presentationPersonPrompt = Just prompt}
      submitted = render (140,36) (headPresentation PersonLayer) {presentationPersonPrompt = Just prompt, presentationPersonSubmitted = True}
      recoveryFrame = render (140,36) (headPresentation RecoveryLayer) {presentationRecovery = Just recoveryHead}
      localOnly = ["Esc CANCEL RUN", "c CANCEL RUN", "CANCEL", "Esc detaches", "r retry", "PgUp/PgDn scroll", "accepted locally"]
      payload = "A\ESC[2JB\ESC]52;c;SGVsbG8=\a\&C\NUL\&D\x9b\&E" :: T.Text
      sanitized = "A\xfffd[2JB\xfffd]52;c;SGVsbG8=\xfffd\&C\xfffd\&D\xfffd\&E" :: T.Text
      hostileQuestion = render (140,36) (headPresentation PersonLayer) {presentationPersonPrompt = Just prompt {personPromptText = payload}}
      hostileRecovery = render (140,36) (headPresentation RecoveryLayer)
        {presentationRecovery = Just (fst recoveryHead, (snd recoveryHead) {snapshotRecoveryMessage = payload})}
      raw = T.filter (\character -> character /= '\n' && (character < ' ' || (character >= '\DEL' && character <= '\x9f')))
  putStrLn "RENDER service question head at (140,36):" >> putStr (T.unpack question)
  putStrLn "RENDER service recovery head at (140,36):" >> putStr (T.unpack recoveryFrame)
  checks
    [ ("the service question head at (140,36) shows the manager prompt below the runtime and the approval receipt",
        all (`T.isInfixOf` question) ["Your answer", "Proceed with 雪😀?", "Runtime: Running", "Approval receipt: dispatch-attempted",
          "Run: run_21", "Waiting for your answer"]),
      ("the service question head at (140,36) offers Ctrl-D and Ctrl-C and no local cancel or detach key",
        all (`T.isInfixOf` question) ["Ctrl-D SEND ANSWER", "Ctrl-C DETACH"] && not (any (`T.isInfixOf` question) localOnly)),
      ("a sent service answer at (140,36) waits for the manager effect and shows no editor",
        all (`T.isInfixOf` submitted) ["WAITING FOR THE MANAGER EFFECT", "waiting for its observed effect"]
          && not ("Ctrl-D SEND ANSWER" `T.isInfixOf` submitted)),
      ("the service recovery head at (140,36) shows the published message and choices read-only",
        all (`T.isInfixOf` recoveryFrame) ["Recovery required", "Retry the adapter?", "Choices (read-only here): retry", "READ-ONLY RECOVERY",
          "Runtime: Running", "q DETACH", "d DETAILS"] && not (any (`T.isInfixOf` recoveryFrame) localOnly)),
      ("control sequences in a decision prompt render as U+FFFD at (140,36)", sanitized `T.isInfixOf` hostileQuestion),
      ("control sequences in a recovery message render as U+FFFD at (140,36)", sanitized `T.isInfixOf` hostileRecovery),
      ("no decision head frame contains a raw control character", all (T.null . raw) [question, submitted, recoveryFrame, hostileQuestion, hostileRecovery])
    ]
  retryTests render headPresentation (metadata,items) receiptValue (controlObs,control) (decisionObs,recoveryValue) snapshot runRead

-- | The retry of the recovery at the head: only 'S.retryOffer' selects the
-- offer, the body matches the offer kind, and only the matching effect
-- completes it.
retryTests :: ((Int,Int) -> Presentation -> T.Text) -> (ActiveLayer -> Presentation) -> (Value,[Value]) -> Value
  -> ((T.Text,T.Text),S.ControlView) -> ((T.Text,T.Text),Value) -> S.RunObservation -> S.RunRead (T.Text,T.Text) -> IO ()
retryTests render headPresentation (metadata,items) receiptValue (controlObs,control) (decisionObs,recoveryValue) snapshot questionRead = do
  otherRunId <- either (die . show) pure (mkRunId "run_other")
  let recoveryObject = object ["gap" .= ("adapter gap" :: T.Text), "message" .= ("Retry the adapter?" :: T.Text),
        "retries" .= ([] :: [T.Text]), "choices" .= [object ["choice" .= ("retry" :: T.Text), "target" .= Null]], "chosen" .= Null]
      failedAttempt = case [attempt | item <- items, lookupKey "occurrenceId" item == Just (String "18446744073709551615"),
          Just (Array attempts) <- [lookupKey "attempts" item], attempt <- V.toList attempts] of
        attempt : _ -> put "state" (String "failed") (put "address" (object ["occurrenceId" .= ("0" :: T.Text), "attemptId" .= ("2" :: T.Text)]) attempt)
        [] -> Null
      recovering = [if lookupKey "occurrenceId" item == Just (String "0")
        then put "attempts" (toJSON [failedAttempt]) (put "personPending" (Bool False) (put "recovery" recoveryObject item)) else item | item <- items]
      retryOfferValue = S.ControlOffer "retry" (OccurrenceId 0) Nothing (Just "generation_3") [] [] []
      chooseOffer choices = S.ControlOffer "choose-recovery" (OccurrenceId 0) Nothing (Just "generation_3") [] choices []
  recoverySnapshot <- either (die . show) pure (S.decodeSnapshot metadata recovering)
  decision <- either (die . show) pure (S.decodeDecision recoveryValue)
  let owned = control {S.controlOffers = [retryOfferValue]}
      retryRead = S.RunRead recoverySnapshot (controlObs,owned) (Just (decisionObs,decision))
      withOffers offers = retryRead {S.runReadControl = (controlObs,owned {S.controlOffers = offers})}
      withControl changed = retryRead {S.runReadControl = (controlObs,changed)}
      withDecision changed = retryRead {S.runReadDecision = Just (decisionObs,changed)}
      retry read' = S.retryMutation "profile_main" read'
      refused result = case result of Left _ -> True; Right _ -> False
      encodedBody mutation = case mutation of
        S.Retry _ view offer _ -> TE.decodeUtf8 (BL.toStrict (encode (S.retryBody view offer)))
        _ -> ""
  (mutation,observed) <- either (die . ("FAIL the fixture retry was refused: " <>) . T.unpack) pure (retry retryRead)
  (chosen,_) <- either (die . ("FAIL the fixture choose-recovery retry was refused: " <>) . T.unpack) pure
    (retry (withOffers [chooseOffer [RecoveryOption "abandon" Nothing, RecoveryOption "retry" Nothing]]))
  checks
    [ ("a retry offer for the owned pending recovery head is the retry mutation with the control observation as its precondition",
        mutation == S.Retry owned decision retryOfferValue (Just 2) && observed == controlObs),
      ("the retry is sent to the run controls with the decision profile",
        S.mutationOperation mutation == "retry" && S.mutationURI mutation == "/v1/runs/run_21/control" && S.mutationProfile mutation == "profile_main"),
      ("a retry offer sends the closed retry body", encodedBody mutation == "{\"generation\":\"generation_3\",\"occurrenceId\":\"0\",\"operation\":\"retry\"}"),
      ("a choose-recovery offer that carries retry sends the retry choice",
        S.mutationOperation chosen == "choose-recovery"
          && encodedBody chosen == "{\"choice\":\"retry\",\"generation\":\"generation_3\",\"occurrenceId\":\"0\",\"operation\":\"choose-recovery\"}"),
      ("a retry offer is preferred to a choose-recovery offer",
        case retry (withOffers [chooseOffer [RecoveryOption "retry" Nothing], retryOfferValue]) of
          Right (S.Retry _ _ offer _, _) -> offer == retryOfferValue
          _ -> False),
      ("no retry is offered for another generation", refused (retry (withOffers [retryOfferValue {S.offerGeneration = Just "generation_9"}]))
          && refused (retry (withDecision decision {S.decisionGeneration = "generation_9"}))),
      ("no retry is offered for another occurrence", refused (retry (withOffers [retryOfferValue {S.offerOccurrence = OccurrenceId 1}]))),
      ("no retry is offered for controls that are not owned", refused (retry (withControl owned {S.controlSupervision = "observer"}))
          && refused (retry (withControl owned {S.controlSupervision = "lost"}))),
      ("no retry is offered for a decision that is not the head", refused (retry (withControl owned {S.controlHead = Just "decision_4"}))
          && refused (retry (withDecision decision {S.decisionPosition = 1})) && refused (retry (withDecision decision {S.decisionState = "submitting"}))
          && refused (retry retryRead {S.runReadDecision = Nothing})),
      ("no retry is offered without a retry offer", refused (retry (withOffers []))
          && refused (retry (withOffers [chooseOffer [RecoveryOption "abandon" Nothing]]))
          && refused (retry (withOffers [retryOfferValue {S.offerOperation = "answer"}]))),
      ("no retry is offered for a recovery whose choices lack retry",
        refused (retry (withDecision decision {S.decisionContent = S.RecoveryContent "adapter gap" "Retry the adapter?" [RecoveryOption "abandon" Nothing]}))),
      ("no retry is offered for a question head", refused (retry questionRead {S.runReadControl = (controlObs,control {S.controlOffers = [retryOfferValue]})})),
      ("no retry is offered for another run or profile", refused (retry retryRead {S.runReadSnapshot = recoverySnapshot {S.runIdentity = otherRunId}})
          && refused (S.retryMutation "profile_other" retryRead)),
      ("no retry is offered when the snapshot publishes no recovery", refused (retry retryRead {S.runReadSnapshot = snapshot})),
      ("a retry completes on the retried effect and a choose-recovery retry on the recovery-chosen effect",
        [S.retryEffect offer | S.Retry _ _ offer _ <- [mutation, chosen]] == ["retried", "recovery-chosen"])
    ]
  let effect kind place resource = object ["kind" .= (kind :: T.Text), "runtimeSequence" .= ("12" :: T.Text),
        "address" .= place, "resource" .= (resource :: T.Text)]
      address occurrence attempt = object (["occurrenceId" .= (occurrence :: T.Text)] <> ["attemptId" .= (value :: T.Text) | Just value <- [attempt]])
      retryReceipt operation value = put "operation" (String operation) (put "requiredScopes" (toJSON ["control" :: T.Text])
        (put "resource" (String "/v1/runs/run_21/control") (put "links" (object ["self" .= ("/v1/commands/cmd_11" :: T.Text),
          "resource" .= ("/v1/runs/run_21/control" :: T.Text)]) (put "state" (String "effect-observed") (put "effect" value
            (put "dispatchAttemptedAt" (String "2026-09-03T00:00:01Z") receiptValue))))))
      decoded operation value = either (die . ("FAIL retry receipt fixture: " <>) . show) pure (C.decodeObservation (retryReceipt operation value))
  matching <- decoded "retry" (effect "retried" (address "0" (Just "2")) "/v1/runs/run_21/control")
  otherAttempt <- decoded "retry" (effect "retried" (address "0" (Just "1")) "/v1/runs/run_21/control")
  noAttempt <- decoded "retry" (effect "retried" (address "0" Nothing) "/v1/runs/run_21/control")
  otherOccurrence <- decoded "retry" (effect "retried" (address "1" (Just "2")) "/v1/runs/run_21/control")
  otherResource <- decoded "retry" (effect "retried" (address "0" (Just "2")) "/v1/runs/run_other/control")
  chosenReceipt <- decoded "choose-recovery" (effect "recovery-chosen" (address "0" (Just "2")) "/v1/runs/run_21/control")
  checks
    [ ("a retried effect for the recovering occurrence and attempt of the run matches the retry",
        S.receiptMatches mutation matching && S.receiptEffectKind matching == Just "retried"),
      ("a retry effect for another attempt or without the attempt does not complete the retry",
        not (S.receiptMatches mutation otherAttempt) && not (S.receiptMatches mutation noAttempt)),
      ("a retry effect for another occurrence or run does not complete the retry",
        not (S.receiptMatches mutation otherOccurrence) && not (S.receiptMatches mutation otherResource)),
      ("a choose-recovery receipt matches only the choose-recovery retry",
        S.receiptMatches chosen chosenReceipt && not (S.receiptMatches mutation chosenReceipt) && not (S.receiptMatches chosen matching))
    ]
  native <- maybe (die "FAIL missing recovery runtime") pure (S.runSnapshot recoverySnapshot)
  (occurrence,recovery) <- case S.decisionHead retryRead of
    Just (S.RecoveryHead _ occurrence recovery) -> pure (occurrence,recovery)
    _ -> die "FAIL the retry fixture has no recovery head"
  let base = (headPresentation RecoveryLayer) {presentationRecovery = Just (occurrence,recovery), presentationServiceRun = Just recoverySnapshot,
        presentationModel = (presentationModel (headPresentation RecoveryLayer)) {modelSnapshot = Just native}}
      offered = render (140,36) base {presentationServiceRetry = True}
      mixedChoices = render (140,36) base {presentationServiceRetry = True,
        presentationRecovery = Just (occurrence,recovery {snapshotRecoveryChoices = [RecoveryOption "retry" Nothing, RecoveryOption "abandon" Nothing]})}
  putStrLn "RENDER service recovery head with a retry offer at (140,36):" >> putStr (T.unpack offered)
  checks
    [ ("a recovery head with a retry offer shows r RETRY and no read-only marker",
        all (`T.isInfixOf` offered) ["Recovery required", "Retry the adapter?", "r RETRY", "q DETACH"]
          && not (any (`T.isInfixOf` offered) ["READ-ONLY RECOVERY", "Choices (read-only here)", "Unsupported here"])),
      ("published choices other than retry are shown as unsupported", "Unsupported here: abandon" `T.isInfixOf` mixedChoices)
    ]

-- | Terminal recognition and verified result selection from the validated
-- snapshot and output page set.
resultTests :: ((Int,Int) -> Presentation -> T.Text) -> S.Profile -> IO ()
resultTests render profile = do
  snapshotValue <- BS.readFile "test/fixtures/manager/v1/valid/snapshot-result-metadata.json" >>= either die pure . eitherDecodeStrict'
  (metadata,items) <- case snapshotValue of
    Object fields | Just (Array values) <- KM.lookup "items" fields -> pure (Object (KM.delete "page" (KM.delete "items" fields)),V.toList values)
    _ -> die "invalid result snapshot fixture shape"
  outputsValue <- BS.readFile "test/fixtures/manager/v1/valid/outputs.json" >>= either die pure . eitherDecodeStrict'
  (outputMetadata,outputItems) <- case outputsValue of
    Object fields | Just (Array values) <- KM.lookup "items" fields -> pure (Object (KM.delete "page" (KM.delete "items" fields)),V.toList values)
    _ -> die "invalid outputs fixture shape"
  let verifiedMetadata = put "verification" (object ["state" .= ("verified" :: T.Text), "artifactId" .= ("artifact_1" :: T.Text)]) metadata
      runtime status = put "runtime" (object ["status" .= (status :: T.Text), "lastSequence" .= ("7" :: T.Text), "protocolVersion" .= (2 :: Int)])
      decoded value = either (die . show) pure (S.decodeSnapshot value items)
      alterArtifact change = [if lookupKey "kind" item == Just (String "result") then alter "artifact" change item else item | item <- outputItems]
      refusedOutputs run changed = case S.decodeOutputs run outputMetadata changed of Left C.InvalidResponse -> True; _ -> False
  unavailable <- decoded metadata
  verified <- decoded verifiedMetadata
  failed <- decoded (runtime "failed" verifiedMetadata)
  cancelled <- decoded (runtime "cancelled" verifiedMetadata)
  orphaned <- decoded (runtime "orphaned" verifiedMetadata)
  running <- decoded (runtime "running" verifiedMetadata)
  cancelling <- decoded (runtime "cancelling" verifiedMetadata)
  absent <- decoded (put "runtime" Null verifiedMetadata)
  referencedOther <- decoded (alter "result" (put "artifactId" (String "artifact_2")) verifiedMetadata)
  referenced <- decoded (put "verification" (object ["state" .= ("referenced" :: T.Text), "artifactId" .= ("artifact_1" :: T.Text)]) metadata)
  referencedFailed <- decoded (runtime "failed" (put "verification" (object ["state" .= ("referenced" :: T.Text), "artifactId" .= ("artifact_1" :: T.Text)]) metadata))
  artifact <- case S.decodeOutputs verified outputMetadata outputItems of
    Right (Just value) -> pure value
    other -> die ("FAIL the verified fixture artifact was refused: " <> show other)
  let bytes = BS.replicate 80 65 <> "\n"
      result = S.VerifiedResult artifact bytes
      successLines = S.resultLines verified (Just (Right result))
  checks
    [ ("only a succeeded runtime with a verified matching result reference is retrieved",
        S.resultWanted verified && not (any S.resultWanted [unavailable, failed, cancelled, orphaned, running, cancelling, absent, referencedOther, referenced])),
      ("only a succeeded runtime with a referenced matching result reference asks the manager to verify it",
        S.resultReferenced referenced && not (any S.resultReferenced [verified, unavailable, referencedFailed, referencedOther])),
      ("the output artifact that the manager verified for a referenced snapshot is bound to the same reference",
        S.decodeOutputs referenced outputMetadata outputItems == Right (Just artifact) && refusedOutputs referenced (alterArtifact (put "bytes" (String "82")))),
      ("a referenced result waits for the retrieval, and an unavailable one downloads nothing",
        S.resultLines referenced Nothing == ["Terminal: succeeded", "Result: retrieving the verified bytes"]),
      ("succeeded, failed, cancelled and orphaned are terminal",
        map S.runTerminal [verified, failed, cancelled, orphaned] == map Just [RunSucceeded, RunFailedStatus, RunCancelledStatus, RunOrphaned]),
      ("a null, running or cancelling runtime is never terminal and shows no result lines",
        all ((== Nothing) . S.runTerminal) [running, cancelling, absent] && all (null . (`S.resultLines` Nothing)) [running, cancelling, absent]),
      ("failed, cancelled and orphaned runs show their terminal status without a download",
        [S.resultLines run Nothing | run <- [failed, cancelled, orphaned]] ==
          [["Terminal: " <> name, "Result: no download for a run that did not succeed"] | name <- ["failed", "cancelled", "orphaned"]]),
      ("unavailable verification yields no download", S.resultLines unavailable Nothing == ["Terminal: succeeded", "Result: no download; verification is unavailable (missing)"]),
      ("the verified output artifact is bound to the run result reference",
        S.artifactId artifact == "artifact_1" && S.artifactRun artifact == "run_21" && S.artifactKind artifact == "source-result"
          && S.artifactBytes artifact == 81 && S.artifactDigest artifact == "9294065bba4452375bfdc9a35d8126ce26a9d6f8fb720a22cccb3cb706651fcd"
          && S.artifactDownload artifact == "/v1/artifacts/artifact_1"),
      ("mismatched artifact metadata is refused",
        all (refusedOutputs verified) [alterArtifact (put "sha256" (String (T.replicate 64 "0"))), alterArtifact (put "bytes" (String "82")),
          alterArtifact (put "runId" (String "run_other")), alterArtifact (put "kind" (String "export")), alterArtifact (put "id" (String "artifact_2")),
          alterArtifact (put "code" (String "text"))]),
      ("a verified output artifact for an unverified run snapshot is refused", refusedOutputs unavailable outputItems),
      ("a retrieved result shows the terminal status, the verified size, the digest and a bounded preview",
        successLines == ["Terminal: succeeded", "Result: verified 81 bytes",
          "Result SHA-256: 9294065bba4452375bfdc9a35d8126ce26a9d6f8fb720a22cccb3cb706651fcd", "Result preview: " <> T.replicate 80 "A" <> " "]),
      ("a pending or refused retrieval is shown as such",
        S.resultLines verified Nothing == ["Terminal: succeeded", "Result: retrieving the verified bytes"]
          && S.resultLines verified (Just (Left "503 storage-unavailable")) == ["Terminal: succeeded", "Result: not retrieved (503 storage-unavailable); the next refresh retries"]),
      ("a long preview is bounded to 120 characters",
        T.length (last (S.resultLines verified (Just (Right result {S.verifiedBytes = BS.replicate 100000 66})))) == T.length "Result preview: " + 120)
    ]
  native <- maybe (die "FAIL missing result runtime") pure (S.runSnapshot verified)
  let model = (initialServiceModel [profile]) {modelScreen = LiveScreen (S.runIdentity verified), modelSnapshot = Just native}
      frame = render (140,36) (emptyPresentation model)
        { presentationService = True, presentationNoColor = True, presentationRunView = reconcileRunView native emptyRunView,
          presentationServiceRun = Just verified, presentationServiceResultLines = successLines,
          presentationServiceObservation = S.observationLines False Nothing True (Just verified) }
  putStrLn "RENDER service terminal result at (140,36):" >> putStr (T.unpack frame)
  check "the live monitor at (140,36) shows the terminal status, the verified size and the digest"
    (all (`T.isInfixOf` frame) ["Runtime: Succeeded", "Terminal: succeeded", "Result: verified 81 bytes",
      "Result SHA-256: 9294065bba4452375bfdc9a35d8126ce26a9d6f8fb720a22cccb3cb706651fcd"])
  -- The service save dialog, its fixed refusal and the saved result line.
  let savable = (emptyPresentation model)
        { presentationService = True, presentationNoColor = True, presentationRunView = reconcileRunView native emptyRunView,
          presentationServiceRun = Just verified, presentationServiceObservation = S.observationLines False Nothing True (Just verified),
          presentationServiceResultLines = successLines, presentationServiceSavable = True }
      existingPath = "/tmp/caf\233/existing.bin"
      existing = mkIOError alreadyExistsErrorType "createLink" Nothing (Just (T.unpack existingPath))
      offeredFrame = render (140,36) savable
      dialogFrame = render (140,36) savable {presentationLayer = SaveLayer}
      refusedFrame = render (140,36) savable {presentationLayer = SaveLayer, presentationSaveError = Just (serviceSaveRefusal existingPath (SaveIOFailure existing))}
      invalidFrame = render (140,36) savable {presentationLayer = SaveLayer, presentationSaveError = Just (serviceSaveRefusal "relative.bin" InvalidDestination)}
      savedFrame = render (140,36) savable {presentationServiceResultLines = successLines <> [serviceSavedLine "/tmp/saved.bin" 81 Saved]}
      -- A wrapped row continues after the dialog border and its padding.
      compact = T.filter (\c -> not (isSpace c) && not ('\x2500' <= c && c <= '\x257f'))
  putStrLn "RENDER service save refusal at (140,36):" >> putStr (T.unpack refusedFrame)
  checks
    [ ("a live monitor with retained verified bytes offers s SAVE RESULT, and one without them does not",
        "s SAVE RESULT" `T.isInfixOf` offeredFrame && not ("s SAVE RESULT" `T.isInfixOf` frame)),
      ("the service save dialog describes the verified result bytes and its keys",
        all ((`T.isInfixOf` compact dialogFrame) . compact) ["Save verified result", "Copy the verified result bytes to a new absolute path. Existing entries are refused.", "Ctrl-D SAVE"]),
      ("the service save dialog shows the fixed refusal of an existing entry with its path",
        compact "ERROR: Save refused: an entry already exists at the destination. Nothing was written. Path: /tmp/caf\233/existing.bin" `T.isInfixOf` compact refusedFrame),
      ("the service save dialog shows the fixed refusal of an invalid path",
        compact "ERROR: Save refused: the destination must be one absolute single-line file path. Path: relative.bin" `T.isInfixOf` compact invalidFrame),
      ("a successful service save shows the saved size and path in the result lines",
        "Saved the verified 81 bytes to /tmp/saved.bin" `T.isInfixOf` savedFrame)
    ]

-- | Exclusive publication of exact bytes.
saveTests :: IO ()
saveTests = do
  base <- getTemporaryDirectory
  suffix <- show <$> getMonotonicTimeNSec
  let directory = base </> ("tui-save-" <> suffix)
      bytes = "exact \NUL bytes without a final newline" :: BS.ByteString
      target = directory </> "result.bin"
      existing = directory </> "existing.bin"
      link = directory </> "link.bin"
      dangling = directory </> "dangling.bin"
      missing = directory </> "missing.bin"
  createDirectory directory
  (do
    saved <- saveExact target bytes
    written <- BS.readFile target
    status <- getFileStatus target
    BS.writeFile existing "keep"
    refusedExisting <- saveExact existing bytes
    keptExisting <- BS.readFile existing
    createSymbolicLink existing link
    refusedLink <- saveExact link bytes
    linkStatus <- getSymbolicLinkStatus link
    linkTarget <- readSymbolicLink link
    keptThroughLink <- BS.readFile existing
    createSymbolicLink missing dangling
    refusedDangling <- saveExact dangling bytes
    danglingStatus <- getSymbolicLinkStatus dangling
    missingCreated <- doesPathExist missing
    refusedAgain <- saveExact target "other"
    keptTarget <- BS.readFile target
    refusedRelative <- saveExact "relative.bin" bytes
    refusedParent <- saveExact (directory </> "absent" </> "result.bin") bytes
    entries <- listDirectory directory
    let failed result = case result of Left _ -> True; Right _ -> False
    checks
      [ ("the save function writes exactly the given bytes without a trailing newline", saved == Right Saved && written == bytes),
        ("the saved file has mode 0600", fileMode status .&. 0o777 == 0o600),
        ("the save function refuses an existing file without modifying it", failed refusedExisting && keptExisting == "keep"
            && failed refusedAgain && keptTarget == bytes),
        ("the save function refuses a symlink without modifying it or its target",
          failed refusedLink && isSymbolicLink linkStatus && linkTarget == existing && keptThroughLink == "keep"),
        ("the save function refuses a dangling symlink without creating its target",
          failed refusedDangling && isSymbolicLink danglingStatus && not missingCreated),
        ("the save function refuses a relative path and a missing directory", failed refusedRelative && failed refusedParent),
        ("a refused save leaves no new file", Set.fromList entries == Set.fromList ["result.bin", "existing.bin", "link.bin", "dangling.bin"])
      ]
    let message path = either (Just . serviceSaveRefusal (T.pack path)) (const Nothing)
        existsText path = "Save refused: an entry already exists at the destination. Nothing was written. Path: " <> T.pack path
    checks
      [ ("an existing file, a symlink and a dangling symlink get the fixed existing-entry message with the path",
          message existing refusedExisting == Just (existsText existing) && message link refusedLink == Just (existsText link)
            && message dangling refusedDangling == Just (existsText dangling)),
        ("a relative path gets the fixed invalid-path message",
          message "relative.bin" refusedRelative == Just "Save refused: the destination must be one absolute single-line file path. Path: relative.bin"),
        ("another input or output failure names only its failure type",
          message (directory </> "absent" </> "result.bin") refusedParent
            == Just ("Save failed: nothing was written (does not exist). Path: " <> T.pack (directory </> "absent" </> "result.bin"))),
        ("a refusal shows control characters and line breaks of the path as replacement characters",
          serviceSaveRefusal "/tmp/a\ESC[31m\nb" InvalidDestination
            == "Save refused: the destination must be one absolute single-line file path. Path: /tmp/a\xfffd[31m\xfffd\&b"),
        ("a successful save names the verified size and the path", serviceSavedLine (T.pack target) (BS.length bytes) Saved
            == "Saved the verified " <> T.pack (show (BS.length bytes)) <> " bytes to " <> T.pack target)
      ]
    -- The removal of the private file fails after the link has published the
    -- bytes. The save succeeds and names the leftover private file.
    let leftoverTarget = directory </> "leftover.bin"
        removalRefused file = ioError (mkIOError permissionErrorType "removeLink" Nothing (Just file))
    leftover <- saveExactUsing removalRefused leftoverTarget bytes
    published <- BS.readFile leftoverTarget
    publishedStatus <- getFileStatus leftoverTarget
    privateEntries <- filter (\entry -> entry `notElem` ["result.bin", "existing.bin", "link.bin", "dangling.bin", "leftover.bin"]) <$> listDirectory directory
    let privatePath = case leftover of Right (SavedLeftover file) -> file; _ -> ""
    privateBytes <- if null privatePath then pure "" else BS.readFile privatePath
    -- A removal that fails before the link still refuses the save and the
    -- destination is not created.
    refusedWithoutRemoval <- saveExactUsing removalRefused existing bytes
    keptAfterRefusal <- BS.readFile existing
    checks
      [ ("a save whose private-file removal fails after the link succeeds and names the leftover private file",
          case (leftover, privateEntries) of
            (Right (SavedLeftover file), [entry]) -> file == directory </> entry
              && T.isPrefixOf ".leftover.bin." (T.pack entry) && T.isSuffixOf ".partial" (T.pack entry)
            _ -> False),
        ("the destination of a save with a leftover private file holds the exact bytes with mode 0600",
          published == bytes && fileMode publishedStatus .&. 0o777 == 0o600 && privateBytes == bytes),
        ("a refused save stays a refusal when the removal of the private file fails",
          case refusedWithoutRemoval of Left (SaveIOFailure _) -> keptAfterRefusal == "keep"; _ -> False),
        ("golden: the saved line names the leftover private file",
          serviceSavedLine "/tmp/saved.bin" 81 (SavedLeftover "/tmp/.saved.bin.00.partial")
            == "Saved the verified 81 bytes to /tmp/saved.bin; the temporary file /tmp/.saved.bin.00.partial was not removed"
            && savedLeftoverNote Saved == "")
      ]) `finally` removePathForcibly directory

-- | A comparable summary of a lane whose pending commands and locations are
-- text markers.
laneShape :: L.Lane T.Text T.Text -> (Maybe L.ReadTicket, Bool, Bool, String)
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
      singleRead = Just (L.ReadTicket 4 L.SingleResourceRead)
      pageSetRead = Just (L.ReadTicket 4 L.PageSetRead)
      cases = [ (screen,key,view,mutation,readTicket,faulted,checked)
              | screen <- screens, key <- keys, view <- views, mutation <- mutations,
                readTicket <- [Nothing, singleRead, pageSetRead], faulted <- [False,True], checked <- reviews ]
      laneOf (_,m) readTicket faulted = L.Lane readTicket m faulted False :: L.Lane T.Text T.Text
      press ((_,screen),(_,key,modifiers),_,_,_,_,_) = A.reviewApprovalKey screen key modifiers
      -- The outcome of one case: Nothing when the press is not an approval
      -- press and keeps its other meaning, otherwise the decision.
      decide c@(_,_,view,mutation,readTicket,faulted,(_,checked)) =
        fmap (\(approval,_,_) -> A.approvalDecision allScopes approval view (laneOf mutation readTicket faulted) checked) (press c)
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
        A.ReadDeferred -> "Approval did not start: a manager page-set read is in progress. Press y again."
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
  check "the enumeration spans 12 screens, 5 keys, 3 views, 7 command states, 3 read states, 2 fault states and 5 review states"
    ((length screens, length keys, length views, length mutations, length reviews, length cases) == (12, 5, 3, 7, 5, 12 * 5 * 3 * 7 * 3 * 2 * 5))
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
      ("approval occurs only for summary y on the review with a current review, an idle lane without a fault and no page-set read",
        and [approves (decide c) == (onReview c && keyName c == "y" && view == A.SummaryView && idle mutation && not faulted
              && readTicket /= pageSetRead && name == "current")
            | c@(_,_,view,mutation,readTicket,faulted,(name,_)) <- cases]),
      ("a single-resource read in flight changes no outcome",
        and [decide (screen,key,view,mutation,Nothing,faulted,checked) == decide (screen,key,view,mutation,singleRead,faulted,checked)
            | (screen,key,view,mutation,_,faulted,checked) <- cases]),
      ("a page-set read defers a summary y on an idle lane without a fault, before any review fact",
        and [refuses A.ReadDeferred (decide c) | c@(_,_,A.SummaryView,mutation,readTicket,False,_) <- reviewCases,
              keyName c == "y", idle mutation, readTicket == pageSetRead]),
      ("a page-set read changes no outcome other than that deferral",
        and [decide (screen,key,view,mutation,pageSetRead,faulted,checked) == decide (screen,key,view,mutation,Nothing,faulted,checked)
            | c@(screen,key,view,mutation,_,faulted,checked) <- cases,
              not (onReview c && keyName c == "y" && view == A.SummaryView && idle mutation && not faulted)]),
      ("a summary y during a command refuses as busy before any review fact",
        and [refuses A.CommandBusy (decide c) | c@(_,_,A.SummaryView,mutation,_,_,_) <- reviewCases, keyName c == "y", not (idle mutation)]),
      ("a summary y after an internal fault refuses before any review fact",
        and [refuses A.FaultStopped (decide c) | c@(_,_,A.SummaryView,mutation,_,True,_) <- reviewCases, keyName c == "y", idle mutation]),
      ("a summary y on an idle lane without a page-set read refuses a stale, expired, mismatched or clipped review by name",
        and [fmap A.Refuse (expectedReviewRefusal name) == decide c
            | c@(_,_,A.SummaryView,mutation,readTicket,False,(name,_)) <- reviewCases, keyName c == "y", idle mutation,
              readTicket /= pageSetRead, name /= "current"]),
      ("every non-approve outcome carries its fixed notice text and the key number",
        and [A.decisionNotice 7 outcome == A.KeyNotice 7 (fixedText refusal) | c <- cases, Just outcome@(A.Refuse refusal) <- [decide c]]),
      ("an approval start carries its own fixed notice", A.decisionNotice 7 (A.Approve ()) == A.KeyNotice 7 startText),
      ("the approval hint is offered exactly when summary y would approve",
        and [A.approvalOffered allScopes view (laneOf mutation readTicket faulted) checked == approves (decide c)
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
        {presentationService = True, presentationServiceEndpoint = Just (S.Endpoint "127.0.0.1" 8443 "stream_A" "epoch_A" allScopes),
          presentationExactDetails = view == A.DetailView, presentationServiceNotice = notice,
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
