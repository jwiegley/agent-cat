{-# LANGUAGE OverloadedStrings #-}

module ServiceTests (serviceTests) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime (DescriptorCapabilities (..), WorkflowDescriptor (..), WorkflowInputDescriptor (..), WorkflowInputSource (..),
  OccurrenceId (..), AttemptId (..), RunSnapshot (..), OccurrenceSnapshot (..), AttemptSnapshot (..))
import Agentic.Tui.Model
import Agentic.Tui.Presentation (emptyPresentation, presentationConfig, serviceReviewAllowed, serviceReviewRows)
import qualified Agentic.Tui.Service as S
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

serviceTests :: IO ()
serviceTests = do
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

check :: String -> Bool -> IO ()
check label passed = unless passed (die ("FAIL " <> label)) >> putStrLn ("PASS " <> label)
