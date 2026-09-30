{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The manager-log reader on constructed logs: each join between a manager
-- log and run logs, each state of the manager log, the consent verification
-- of a start relay with each of its failures, and the joins of a pruned log
-- across its retained floor.
module Agentic.Manager.Test.FlowReader (flowReaderChecks) where

import Agentic.Manager.Flow
import Agentic.Manager.Protocol.Command (CommandReceipt (..), CommandState (..), Operation (..))
import Agentic.Manager.Protocol.Preparation (ApprovalRequest (..))
import qualified Agentic.Runtime as Runtime
import Control.Exception (bracket)
import Control.Monad (unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (createDirectory)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

flowReaderChecks :: FilePath -> IO ()
flowReaderChecks work = do
  let base = work </> "flow-reader"
  createDirectory base
  setFileMode base 0o700
  runOne <- runLog (base </> "run-1") "native_1" True
  runTwo <- runLog (base </> "run-2") "native_2" False
  joinChecks base runOne runTwo
  consentChecks base runOne
  prunedChecks base runOne
  putStrLn "PASS manager-log reader: joins, undecided commands, unresolved deliveries, pending reviews, lifetimes, consent and the retained floor"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

sha :: BS.ByteString -> Text
sha bytes = T.pack (show (hash bytes :: Digest SHA256))

principal :: Runtime.Actor
principal = Runtime.Principal (Runtime.Credential "client_1" "credential_a")

commandAbout :: Text -> Runtime.About
commandAbout command = Runtime.noAbout {Runtime.aboutCommand = Just command}

relayAbout :: Text -> Text -> Runtime.About
relayAbout native command =
  Runtime.noAbout {Runtime.aboutCommand = Just command, Runtime.aboutManagerRun = Just "run_1", Runtime.aboutNativeRun = Just (Runtime.RunId native)}

-- | A review of the preparation for the native run. The edit changes the
-- fields of the binding before its bytes and digest are computed.
reviewFor :: Text -> Text -> (KM.KeyMap Value -> KM.KeyMap Value) -> ReviewBody
reviewFor preparation native edit =
  let bytes = TE.encodeUtf8 ("{\"review\":\"" <> preparation <> "\",\"text\":\"caf\233\"}")
      fields =
        KM.fromList
          [ ("nativeRunId", String native),
            ("reviewSha256", String (sha bytes)),
            ("invocation", object ["prefixArgs" .= ([] :: [Text]), "version" .= (1 :: Int)]),
            ("targetArguments", toJSON (["--engine", "acp", "--adapter", "mixed-adapter"] :: [Text]))
          ]
      binding = BL.toStrict (encode (Object (edit fields)))
      digest = sha binding
   in ReviewBody preparation bytes (sha bytes) binding digest "2026-09-29T01:00:00Z"
        (ApprovalRequest digest "request_revision_1" "profile_revision_1" "descriptor_1" "generation_1")

approveBody :: Text -> ApprovalRequest -> CommandBody
approveBody preparation (ApprovalRequest digest request profile descriptor generation) =
  CommandBody Approve "profile_1" "POST" ("/v1/preparations/" <> preparation) "application/json" (Just "\"preparation_revision_1\"")
    (Just (object ["operation" .= ("approve" :: Text), "reviewDigest" .= digest, "requestRevision" .= request, "profileRevision" .= profile, "descriptorRevision" .= descriptor, "processGeneration" .= generation]))
    Nothing

plainCommand :: Operation -> Text -> CommandBody
plainCommand operation resource =
  CommandBody operation "profile_1" "POST" resource "application/json" Nothing (Just (object ["operation" .= ("fixture" :: Text)])) Nothing

receiptFor :: Text -> CommandBody -> CommandState -> CommandReceipt
receiptFor command body state =
  CommandReceipt command "profile_1" (commandBodyOperation body) (commandBodyResource body) state "2026-09-29T00:00:00Z" Nothing Nothing Nothing
    (if state == Refused then Just "state-conflict" else Nothing)

-- | The appends of one manager log under construction.
newtype Log = Log {logWriter :: Runtime.FlowWriter}

-- | Remove the oldest sealed segments of a segmented log until the retained
-- floor is the given position.
pruneTo :: Log -> Runtime.Position -> IO ()
pruneTo log' (Runtime.Position target) = do
  segments <- Runtime.flowWriterSegments (logWriter log')
  case segments of
    oldest : _
      | Runtime.segmentFirst oldest < target -> do
          removed <- Runtime.pruneFlowSegment (logWriter log') (Runtime.segmentFirst oldest)
          unless removed (fail ("FAIL manager-log reader: the fixture cannot prune the segment at " <> show (Runtime.segmentFirst oldest)))
          pruneTo log' (Runtime.Position target)
    _ -> pure ()

withManagerLog :: FilePath -> Text -> (Log -> IO a) -> IO (a, FilePath)
withManagerLog base name = withManagerLogSegments base name Nothing

-- | A manager log whose writer seals before every append after the first, so
-- each record is one segment and a prune can move the floor to any position.
withSegmentedLog :: FilePath -> Text -> (Log -> IO a) -> IO (a, FilePath)
withSegmentedLog base name = withManagerLogSegments base name (Just 1)

withManagerLogSegments :: FilePath -> Text -> Maybe Integer -> (Log -> IO a) -> IO (a, FilePath)
withManagerLogSegments base name segmentBytes action = do
  let root = base </> T.unpack name
  createDirectory root
  setFileMode root 0o700
  bracket (Runtime.openPrivateRoot "manager reader check" root) Runtime.closePrivateRoot $ \private -> do
    Runtime.ensurePrivateDirectoryAt private ["flow"]
    let stream = "stream_" <> name
        path = root </> "flow" </> T.unpack stream <> ".ndjson"
        segments = Runtime.FlowSegments (managerFlowSealed stream) <$> segmentBytes
    bracket (fst <$> Runtime.openFlowLog Runtime.strictFlowCodec private (managerFlowPath stream) (managerFlowClaims stream) segments (64 * 1024 * 1024)) Runtime.closeFlowWriter $ \writer -> do
      value <- action (Log writer)
      pure (value, path)

tell :: Log -> Runtime.Schema -> Runtime.Actor -> Runtime.Address -> Runtime.About -> Value -> IO Runtime.Position
tell log' schema from to about body = fst <$> Runtime.appendTell (logWriter log') schema from to about (Runtime.ContentValue body)

appendCommand :: Log -> Runtime.Actor -> Text -> CommandBody -> IO Runtime.Position
appendCommand log' from identifier body = fst <$> Runtime.appendAsk (logWriter log') Runtime.FlowCommand from (Runtime.To Runtime.Manager) (commandAbout identifier) (Runtime.ContentValue (commandFlowBody body))

receipt :: Log -> Runtime.Position -> Text -> CommandBody -> CommandState -> IO Runtime.Position
receipt log' asked identifier body state =
  fst <$> Runtime.appendReply (logWriter log') Runtime.FlowReceipt asked Runtime.Manager (Runtime.To principal) (commandAbout identifier) (Runtime.ContentValue (receiptFlowBody (receiptFor identifier body state)))

notice :: Log -> Runtime.About -> Notice -> IO Runtime.Position
notice log' about body = tell log' Runtime.FlowNotice Runtime.Manager (Runtime.To Runtime.Manager) about (noticeFlowBody body)

review :: Log -> ReviewBody -> IO Runtime.Position
review log' body = do
  value <- either (fail . T.unpack) pure (reviewFlowBody body)
  tell log' Runtime.FlowReview Runtime.Manager (Runtime.Approvers "profile_1") Runtime.noAbout {Runtime.aboutRequest = Just "request_1"} value

relay :: Log -> RelayKind -> Text -> Text -> IO Runtime.Position
relay log' kind native identifier = do
  value <- either (fail . T.unpack) pure (relayFlowBody (RelayBody kind (Just "run_1") (Runtime.RunId native) (Just identifier) "{\"frame\":\"fixture\"}"))
  tell log' Runtime.FlowRelay Runtime.Manager (Runtime.To (Runtime.Workflow (Runtime.RunId native))) (relayAbout native identifier) value

lifetime :: Text -> Notice
lifetime generation = LifetimeNotice (Lifetime generation noReconciliation [CredentialEntry "client_1" "credential_a" "active" ["submit", "control"] ["profile_1"]] 0)

-- | A run log in a run store: its start from the manager, and with the flag a
-- control for @command_answer@, its acknowledgement and a person question
-- answered through that command. A terminal event ends it. The result holds
-- the directory and the positions of the control, its acknowledgement and the
-- answer.
runLog :: FilePath -> Text -> Bool -> IO (FilePath, Maybe (Runtime.Position, Runtime.Position, Runtime.Position))
runLog directory native withControl = do
  let run = Runtime.RunId native
      workflow = Runtime.Workflow run
      manifest = Runtime.RunManifest run "review" "0.1.0.0" (object ["program" .= ("fixture" :: Text)]) "scripted" (object ["kind" .= ("scripted" :: Text)]) Nothing Runtime.RootRun Nothing (Just Runtime.PersonAnswerLocalControl)
      start = Runtime.Start run (T.replicate 64 "a") ("sha256:" <> T.replicate 64 "b") (Just Runtime.PersonAnswerLocalControl) "scripted" Runtime.RootRun Nothing []
  positions <- Runtime.withRunStoreVersioned Runtime.latestStoreVersion Runtime.correlatedProtocolVersion directory manifest $ \store ->
    Runtime.withRunLog store Runtime.Manager start $ \writer -> do
      let event number runtimeEvent = do
            (position, _) <- Runtime.appendTell writer Runtime.FlowEvent workflow Runtime.Public (Runtime.runAbout run) (Runtime.eventContent (Runtime.SeqNo number))
            void (Runtime.appendStoredEvent store (Runtime.Envelope Runtime.correlatedProtocolVersion run (Runtime.SeqNo number) "2026-09-29T00:00:00Z" runtimeEvent))
            pure position
      _ <- event 0 (Runtime.RunStartedV2 "review" "scripted" Runtime.PersonAnswerLocalControl)
      found <-
        if withControl
          then do
            body <- either (fail . T.unpack) pure (Runtime.controlBody Runtime.correlatedProtocolVersion (Runtime.Control (Runtime.ControlId "command_answer") (Just (Runtime.OccurrenceId 1)) Nothing (Runtime.AnswerPerson (Bool False))))
            (control, _) <- Runtime.appendTell writer Runtime.FlowControl Runtime.Manager (Runtime.To workflow) (Runtime.runAbout run) {Runtime.aboutCommand = Just "command_answer"} (Runtime.ContentValue body)
            acknowledgement <- event 1 (Runtime.ControlAcknowledgedV2 "command_answer" "accepted" "accepted" "answerPerson" (Just (Runtime.OccurrenceId 1)) Nothing)
            let scoped = (Runtime.runAbout run) {Runtime.aboutOccurrence = Just (Runtime.OccurrenceId 1), Runtime.aboutEpoch = Just 0}
                question = object ["addressee" .= object ["person" .= object ["id" .= ("owner" :: Text)]], "code" .= ("flag" :: Text), "draw" .= (0 :: Int), "intent" .= ("consult" :: Text), "prompt" .= ("Confirm?" :: Text), "scope" .= object ["mode" .= Null, "model" .= Null]]
            (asked, _) <- Runtime.appendAsk writer Runtime.FlowQuestion workflow (Runtime.To Runtime.Manager) scoped (Runtime.ContentValue question)
            (answer, _) <- Runtime.appendReply writer Runtime.FlowAnswer asked Runtime.Manager (Runtime.To workflow) scoped {Runtime.aboutCommand = Just "command_answer"} (Runtime.ContentValue (Bool False))
            _ <- event 2 (Runtime.RunFailed Runtime.FailureRuntime "the fixture stops")
            pure (Just (control, acknowledgement, answer))
          else event 1 (Runtime.RunFailed Runtime.FailureRuntime "the fixture stops") >> pure Nothing
      pure found
  pure (directory, positions)

readRun :: FilePath -> IO (FilePath, Runtime.FlowReport)
readRun directory = (,) directory <$> Runtime.readFlow Runtime.FlowEnded directory

credentialArgument :: String -> Bool
credentialArgument argument = any (`T.isInfixOf` T.toLower (T.pack argument)) ["key", "token", "secret", "credential"]

-- ---------------------------------------------------------------------------
-- Joins and states
-- ---------------------------------------------------------------------------

joinChecks :: FilePath -> (FilePath, Maybe (Runtime.Position, Runtime.Position, Runtime.Position)) -> (FilePath, a) -> IO ()
joinChecks base (runOne, controlAnswer) (runTwo, _) = do
  (control, acknowledgement, runAnswer) <- maybe (fail "FAIL manager-log reader: the first run log has no control") pure controlAnswer
  let reviewOne = reviewFor "preparation_1" "native_1" id
      reviewTwo = reviewFor "preparation_2" "native_2" id
      approveOne = approveBody "preparation_1" (reviewBodySelectors reviewOne)
      approveTwo = approveBody "preparation_2" (reviewBodySelectors reviewTwo)
      create = plainCommand Create "/v1/requests"
      answer = plainCommand Answer "/v1/decisions/decision_1"
      enqueue = plainCommand Enqueue "/v1/requests/request_1"
  (positions, path) <- withManagerLog base "joins" $ \log' -> do
    p0 <- notice log' Runtime.noAbout (lifetime "generation_1")
    p1 <- appendCommand log' principal "command_create" create
    p2 <- receipt log' p1 "command_create" create Accepted
    p3 <- notice log' (commandAbout "command_create") (CommandChanged Acknowledged Nothing)
    p4 <- review log' reviewOne
    p5 <- appendCommand log' principal "command_approve_1" approveOne
    p6 <- receipt log' p5 "command_approve_1" approveOne Accepted
    p7 <- relay log' RelayStart "native_1" "command_approve_1"
    p8 <- review log' reviewTwo
    p9 <- appendCommand log' principal "command_approve_2" approveTwo
    p10 <- notice log' Runtime.noAbout (GapNotice [MissingRecord Runtime.FlowReceipt (commandAbout "command_approve_2")] 0)
    p11 <- relay log' RelayStart "native_2" "command_approve_2"
    p12 <- appendCommand log' principal "command_answer" answer
    p13 <- receipt log' p12 "command_answer" answer Accepted
    p14 <- relay log' RelayControl "native_1" "command_answer"
    p15 <- review log' (reviewFor "preparation_3" "native_3" id)
    p16 <- review log' (reviewFor "preparation_4" "native_4" id)
    p17 <- notice log' Runtime.noAbout (ReviewEnded "preparation_4" "expired")
    p18 <- appendCommand log' principal "command_enqueue" enqueue
    p19 <- relay log' RelayControl "native_1" "command_unrelayed"
    p20 <- notice log' Runtime.noAbout (ShutdownNotice "generation_1")
    p21 <- notice log' Runtime.noAbout (lifetime "generation_2")
    pure [p0, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12, p13, p14, p15, p16, p17, p18, p19, p20, p21]
  manager <- readManagerLog path
  runs <- mapM readRun [runOne, runTwo]
  let joined = joinFlows credentialArgument [manager] runs
      at = LogPosition path . (positions !!)
      inRun directory = LogPosition directory
  check ("the joined logs verify: " <> show (flowJoinProblems joined)) (flowJoinVerified joined)
  check "every manager record decodes" (length (managerLogEntries manager) == 22 && all (null . Runtime.entryProblems) (managerLogEntries manager))
  check ("a review joins its approve command by preparation, and a review ending ends a review: " <> show (joinReviews joined)) $
    map (\r -> (reviewJoinReview r, reviewJoinPreparation r, reviewJoinCommands r, reviewJoinEndings r)) (joinReviews joined)
      == [ (at 4, "preparation_1", [positions !! 5], []),
           (at 8, "preparation_2", [positions !! 9], []),
           (at 15, "preparation_3", [], []),
           (at 16, "preparation_4", [], [positions !! 17])
         ]
  check ("a relay joins the start or control of the run log by native run and command: " <> show (joinRelays joined)) $
    map (\r -> (relayJoinRelay r, relayJoinDelivered r)) (joinRelays joined)
      == [ (at 7, Just (inRun runOne (Runtime.Position 0))),
           (at 11, Just (inRun runTwo (Runtime.Position 0))),
           (at 14, Just (inRun runOne control)),
           (at 19, Nothing)
         ]
  check ("a control joins its acknowledgement event by command: " <> show (joinControls joined)) $
    joinControls joined == [ControlJoin (inRun runOne control) (Just acknowledgement)]
  check ("a command joins its reply and its later notices by command: " <> show (joinCommands joined)) $
    map (\c -> (commandJoinCommand c, commandJoinReply c, commandJoinNotices c)) (joinCommands joined)
      == [ (at 1, Just (positions !! 2), [positions !! 3]),
           (at 5, Just (positions !! 6), []),
           (at 9, Nothing, []),
           (at 12, Just (positions !! 13), []),
           (at 18, Nothing, [])
         ]
  check ("a person answer joins the answer command of the principal by command: " <> show (joinAnswers joined)) $
    joinAnswers joined == [AnswerJoin (inRun runOne runAnswer) "command_answer" (Just (at 12))]
  check "a command without a reply is undecided" (joinUndecided joined == [at 9, at 18])
  check "a relay without its run-log record is an unresolved delivery" (joinUnresolvedDelivery joined == [at 19])
  check "a review without a command and without an ending is pending" (joinPendingReview joined == [at 15])
  check "a lifetime without its shutdown notice has lost supervision" (joinLostLifetimes joined == [at 21])
  check "a lifetime without its shutdown notice leaves the reading uncertain" (flowJoinUncertain joined)
  check ("both start relays have verified consent, through a receipt and through a gap notice: " <> show (joinConsent joined)) $
    map (\c -> (consentRelay c, consentReview c, consentCommand c, consentReceipt c, consentGap c, consentRunStart c, consentProblems c)) (joinConsent joined)
      == [ (at 7, Just (positions !! 4), Just (positions !! 5), Just (positions !! 6), Nothing, Just (inRun runOne (Runtime.Position 0)), []),
           (at 11, Just (positions !! 8), Just (positions !! 9), Nothing, Just (positions !! 10), Just (inRun runTwo (Runtime.Position 0)), [])
         ]
  -- Without the run logs, every start and control relay is an unresolved
  -- delivery, and consent does not verify.
  let alone = joinFlows credentialArgument [manager] []
  check "without run logs every start and control relay is an unresolved delivery" (joinUnresolvedDelivery alone == [at 7, at 11, at 14, at 19])
  check "without run logs the consent of a start relay does not verify" (not (flowJoinVerified alone) && all (not . null . consentProblems) (joinConsent alone))

-- ---------------------------------------------------------------------------
-- Consent
-- ---------------------------------------------------------------------------

-- | One way to build the consent of a start relay for @native_1@.
data Variant = Variant
  { variantName :: Text,
    variantReview :: ReviewBody,
    variantSelectors :: ApprovalRequest,
    variantSender :: Runtime.Actor,
    variantReceipt :: Maybe CommandState
  }

baseVariant :: Text -> Variant
baseVariant name =
  let body = reviewFor "preparation_1" "native_1" id
   in Variant name body (reviewBodySelectors body) principal (Just Accepted)

consentLog :: FilePath -> Variant -> IO FilePath
consentLog base variant = fmap snd $ withManagerLog base (variantName variant) $ \log' -> do
  let approve = approveBody "preparation_1" (variantSelectors variant)
  _ <- notice log' Runtime.noAbout (lifetime "generation_1")
  _ <- review log' (variantReview variant)
  asked <- appendCommand log' (variantSender variant) "command_approve" approve
  mapM_ (receipt log' asked "command_approve" approve) (variantReceipt variant)
  _ <- relay log' RelayStart "native_1" "command_approve"
  void (notice log' Runtime.noAbout (ShutdownNotice "generation_1"))

consentChecks :: FilePath -> (FilePath, a) -> IO ()
consentChecks base (runOne, _) = do
  run <- readRun runOne
  let problemsOf runs path = do
        manager <- readManagerLog path
        pure (joinFlows credentialArgument [manager] runs)
      failing variant expected = do
        path <- consentLog base variant
        joined <- problemsOf [run] path
        let problems = concatMap consentProblems (joinConsent joined)
        check (T.unpack (variantName variant) <> " fails consent with '" <> T.unpack expected <> "': " <> show problems) $
          not (flowJoinVerified joined) && any (expected `T.isInfixOf`) problems
      withBinding edit = (reviewFor "preparation_1" "native_1" edit)
      rebound name edit = let body = withBinding edit in (baseVariant name) {variantReview = body, variantSelectors = reviewBodySelectors body}
  verifiedPath <- consentLog base (baseVariant "consent")
  verified <- problemsOf [run] verifiedPath
  check ("the base consent verifies: " <> show (flowJoinProblems verified)) (flowJoinVerified verified && not (flowJoinUncertain verified))
  failing (rebound "binding-review-digest" (KM.insert "reviewSha256" (String (T.replicate 64 "0")))) "differs from the reviewSha256 of the binding"
  failing (rebound "binding-native-run" (KM.insert "nativeRunId" (String "native_9"))) "another native run"
  failing (rebound "binding-credential" (KM.insert "invocation" (object ["prefixArgs" .= (["--api-key=fixture"] :: [Text])]))) "carries a credential"
  let ApprovalRequest digest request profile descriptor generation = variantSelectors (baseVariant "x")
  failing (baseVariant "other-selectors") {variantSelectors = ApprovalRequest digest "request_revision_2" profile descriptor generation} "names other selectors"
  let base' = baseVariant "other-digest"
      otherDigest = ApprovalRequest (T.replicate 64 "f") request profile descriptor generation
  failing base' {variantReview = (variantReview base') {reviewBodySelectors = otherDigest}, variantSelectors = otherDigest} "another digest than the binding digest"
  failing (baseVariant "no-receipt") {variantReceipt = Nothing} "neither an accepted receipt nor a gap notice"
  failing (baseVariant "refused-receipt") {variantReceipt = Just Refused} "neither an accepted receipt nor a gap notice"
  failing (baseVariant "manager-sender") {variantSender = Runtime.Manager} "not from a credential"
  alone <- problemsOf [] verifiedPath
  check "the consent without its run log does not verify" (any ("no run log that was read begins with a start" `T.isInfixOf`) (concatMap consentProblems (joinConsent alone)))
  -- One changed byte inside the review body fails the review codec and the
  -- consent that depends on it.
  tamperedPath <- consentLog base (baseVariant "tampered")
  bytes <- BS.readFile tamperedPath
  let (before, after) = BS.breakSubstring "\\\"review\\\":\\\"preparation_1" bytes
  check "the tampered fixture holds the review bytes" (not (BS.null after))
  BS.writeFile tamperedPath (before <> BS.take 13 after <> "q" <> BS.drop 14 after)
  tampered <- problemsOf [run] tamperedPath
  check ("a changed review byte fails the review body and the consent: " <> show (flowJoinProblems tampered)) $
    not (flowJoinVerified tampered)
      && any ("the review body does not decode" `T.isInfixOf`) (flowJoinProblems tampered)
      && any ("no earlier review record" `T.isInfixOf`) (concatMap consentProblems (joinConsent tampered))

-- ---------------------------------------------------------------------------
-- The retained floor
-- ---------------------------------------------------------------------------

-- | The consent chain of 'consentLog' in a segmented log, pruned to the floor
-- after the relay and the shutdown notice. The result holds the positions of
-- the lifetime notice, the review, the approve command, its receipt, the start
-- relay and the shutdown notice, and the path of the log.
prunedLog :: FilePath -> Text -> Runtime.Actor -> Int -> IO ([Runtime.Position], FilePath)
prunedLog base name sender kept = withSegmentedLog base name $ \log' -> do
  let body = reviewFor "preparation_1" "native_1" id
      approve = approveBody "preparation_1" (reviewBodySelectors body)
  p0 <- notice log' Runtime.noAbout (lifetime "generation_1")
  p1 <- review log' body
  p2 <- appendCommand log' sender "command_approve" approve
  p3 <- receipt log' p2 "command_approve" approve Accepted
  p4 <- relay log' RelayStart "native_1" "command_approve"
  p5 <- notice log' Runtime.noAbout (ShutdownNotice "generation_1")
  let positions = [p0, p1, p2, p3, p4, p5]
  pruneTo log' (positions !! kept)
  pure positions

prunedChecks :: FilePath -> (FilePath, a) -> IO ()
prunedChecks base (runOne, _) = do
  run <- readRun runOne
  let joinOf path = do
        manager <- readManagerLog path
        pure (manager, joinFlows credentialArgument [manager] [run])
      summaryOf joined = case flowJoinSummaryValue joined of
        Object top | Just (Object summary) <- KM.lookup "summary" top -> summary
        _ -> KM.empty
      field key object' = case object' of
        Object fields -> KM.lookup key fields
        _ -> Nothing
      firstOf key summary = case KM.lookup key summary of
        Just (Array items) | item : _ <- foldr (:) [] items -> Just item
        _ -> Nothing
  -- The review lies below the floor, and the approve command, its receipt and
  -- the relay are retained.
  (reviewPositions, reviewPath) <- prunedLog base "pruned-review" principal 2
  (reviewManager, reviewJoin) <- joinOf reviewPath
  check ("a log pruned to the approve command has its floor there: " <> show (managerLogFloor reviewManager)) $
    managerLogFloor reviewManager == reviewPositions !! 2
      && map Runtime.entryPosition (managerLogEntries reviewManager) == drop 2 reviewPositions
  check ("a start relay whose review lies below the floor has pruned consent, and the join verifies: " <> show (joinConsent reviewJoin, flowJoinProblems reviewJoin)) $
    flowJoinVerified reviewJoin
      && not (flowJoinUncertain reviewJoin)
      && map (\c -> (consentReview c, consentCommand c, consentReceipt c, consentProblems c, consentPruned c)) (joinConsent reviewJoin)
        == [(Nothing, Just (reviewPositions !! 2), Just (reviewPositions !! 3), [], True)]
  let reviewSummary = summaryOf reviewJoin
      reviewConsent = firstOf "consent" reviewSummary
  check ("the summary names the floor of the manager log: " <> show (firstOf "logs" reviewSummary)) $
    (firstOf "logs" reviewSummary >>= field "floor") == Just (toJSON (Runtime.positionIndex (reviewPositions !! 2)))
  check ("the summary reports the consent as pruned and not verified: " <> show reviewConsent) $
    (reviewConsent >>= field "pruned") == Just (Bool True) && (reviewConsent >>= field "verified") == Just (Bool False)
  -- The approve command lies below the floor, so its retained receipt replies
  -- to a pruned ask.
  (commandPositions, commandPath) <- prunedLog base "pruned-command" principal 3
  (commandManager, commandJoin) <- joinOf commandPath
  let receiptEntry = [entry | entry <- managerLogEntries commandManager, Runtime.entryPosition entry == commandPositions !! 3]
  check ("a receipt whose command lies below the floor is pruned, decodes and fails nothing: " <> show receiptEntry) $
    map (\entry -> (Runtime.entryPruned entry, Runtime.entryProblems entry)) receiptEntry == [(True, [])]
      && fmap isReceipt (Map.lookup (commandPositions !! 3) (managerLogValues commandManager)) == Just True
  check ("a start relay whose approve command lies below the floor has pruned consent, and the join verifies: " <> show (joinConsent commandJoin, flowJoinProblems commandJoin)) $
    flowJoinVerified commandJoin
      && map (\c -> (consentReview c, consentCommand c, consentReceipt c, consentProblems c, consentPruned c)) (joinConsent commandJoin)
        == [(Nothing, Nothing, Just (commandPositions !! 3), [], True)]
      && null (joinCommands commandJoin)
      && null (joinUndecided commandJoin)
  check ("the summary names the pruned reply of the manager log: " <> show (firstOf "logs" (summaryOf commandJoin))) $
    (firstOf "logs" (summaryOf commandJoin) >>= field "prunedReplies") == Just (toJSON [Runtime.positionIndex (commandPositions !! 3)])
  -- A pruned review does not excuse a retained check: an approve command from
  -- the manager still fails the consent.
  (_, senderPath) <- prunedLog base "pruned-review-sender" Runtime.Manager 2
  (_, senderJoin) <- joinOf senderPath
  check ("a retained approve command that is not from a credential fails consent across the floor: " <> show (joinConsent senderJoin)) $
    not (flowJoinVerified senderJoin) && any ("not from a credential" `T.isInfixOf`) (concatMap consentProblems (joinConsent senderJoin))
  where
    isReceipt = \case
      ReceiptValue _ -> True
      _ -> False

check :: String -> Bool -> IO ()
check label ok = unless ok (fail ("FAIL manager-log reader: " <> label))
