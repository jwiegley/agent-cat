{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The actor-flow record, its strict line codec, the run-log body codecs and
-- the writer, through the "Agentic.Runtime" facade.
module FlowTests (flowTests) where

import Agentic.Plan (Q (Q), askC1, consultRequest, scopeUnit)
import Agentic.Planning (Addressee (AddrModel))
import Agentic.Runtime
import qualified Agentic.Engine as E
import qualified Agentic.Planning as P
import qualified Agentic.Schema as S
import BucketEvidence (withCaptureBucket)
import Control.Exception (SomeException, evaluate, fromException, try)
import Control.Monad (forM, forM_, unless, zipWithM_)
import Data.Aeson (Value (Array, Bool, Null, Number, String), encode, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.Int (Int64)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (UTCTime), picosecondsToDiffTime)
import Data.Time.Calendar (fromGregorian)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, openBinaryFile)
import System.Mem (getAllocationCounter)

type Ledger =
  'S.SchemaProperty "amount" 'S.SchemaNumber
    ('S.SchemaProperty "label" 'S.SchemaString
      ('S.SchemaProperty "nothing" 'S.SchemaNull 'S.SchemaObject))

ledgerCode :: P.SCode ('S.CodeStructured Ledger)
ledgerCode =
  P.SStructured $
    S.schemaProperty @"amount" S.schemaNumber $
      S.schemaProperty @"label" S.schemaString (S.schemaProperty @"nothing" S.schemaNull S.schemaObject)

unicode :: Text
unicode = "Gr\252\223e, \26085\26412, \55348\56606, \"quoted\"\n\\tab\0end"

moment :: UTCTime
moment = UTCTime (fromGregorian 2026 9 29) (picosecondsToDiffTime 45296123456789012)

actors :: [Actor]
actors =
  [ Principal (Credential "client \10003" "credential-1"),
    Principal (LocalAccount 501 (Just unicode)),
    Principal (LocalAccount 0 Nothing),
    Model "acp:claude",
    ToolActor "gate" RegistryTool,
    ToolActor "make check" ProgramCommand,
    ToolActor unicode FixtureTool,
    Adapter "acp",
    Workflow (RunId "run-\26085"),
    Manager
  ]

addresses :: [Address]
addresses = [To actor | actor <- actors] <> [Approvers "profile \55348\56606", Public]

fullAbout :: About
fullAbout =
  About
    { aboutRequest = Just "request-1",
      aboutManagerRun = Just "manager-run",
      aboutNativeRun = Just (RunId "native"),
      aboutOccurrence = Just (OccurrenceId 18446744073709551615),
      aboutEpoch = Just 0,
      aboutAttempt = Just 4294967295,
      aboutCommand = Just unicode
    }

-- | A record of this schema with a reply position exactly when it is a reply.
recordOf :: Schema -> Actor -> Address -> About -> Body -> Record
recordOf schema from to about body =
  Record schema from to about (if schemaRole schema == ReplySchema then Just (Position 7) else Nothing) body moment

bodyFor :: Schema -> Value -> Body
bodyFor FlowEvent _ = EventNumber (SeqNo 42)
bodyFor _ value = Inline value

flowTests :: IO ()
flowTests = do
  envelopeRoundTrips
  bodyRoundTrips
  lineRefusals
  writerChecks
  runLogSinkChecks
  putStrLn "flow checks passed: seventeen schemas, every actor and address, exact run-log bodies, claim checks and refused lines"

envelopeRoundTrips :: IO ()
envelopeRoundTrips = do
  check "seventeen schemas" (length [minBound .. maxBound :: Schema] == 17)
  check "schema names are distinct and invert"
    (all (\schema -> schemaFromName (schemaName schema) == Just schema) [minBound .. maxBound])
  check "the schema names of section 1.1"
    ( map schemaName [minBound .. maxBound]
        == ["start", "control", "question", "answer", "engine-start", "turn", "engine-result", "steer", "done", "failure", "event", "permission", "command", "receipt", "review", "relay", "notice"]
    )
  check "restricted and public route classes"
    ([schema | schema <- [minBound .. maxBound], schemaRouteClass schema /= ActorRoute] == [FlowEngineResult, FlowFailure, FlowEvent])
  check "every reply answers an ask" (and [all ((== AskSchema) . schemaRole) (schemaAnswers schema) && not (null (schemaAnswers schema)) | schema <- [minBound .. maxBound], schemaRole schema == ReplySchema])
  forM_ [minBound .. maxBound] $ \schema ->
    forM_ [noAbout, fullAbout] $ \about ->
      roundTrip ("schema " <> T.unpack (schemaName schema)) (recordOf schema Manager Public about (bodyFor schema (String unicode)))
  forM_ (zip actors (cycle addresses)) $ \(actor, address) ->
    roundTrip ("actor " <> show actor) (recordOf FlowTurn actor address noAbout (Inline (String unicode)))
  forM_ addresses $ \address ->
    roundTrip ("address " <> show address) (recordOf FlowNotice Manager address noAbout (Inline Null))
  roundTrip "claim check body"
    (recordOf FlowEngineResult (Model "m") (To (Workflow (RunId "r"))) noAbout (ClaimCheck (T.replicate 64 "a") 65537))
  roundTrip "values in an inline body"
    (recordOf FlowPermission (Adapter "acp") Public noAbout (Inline (object ["false" .= False, "null" .= Null, "decimal" .= decimal, "text" .= unicode, "list" .= [Bool True, Number 0]])))
  where
    roundTrip label record = check (label <> " round trip") (decodeFlowLine (encodeFlowLine record) == Right record)

decimal :: Value
decimal = Number 123456789012345678901234567890.000000000000000000001

bodyRoundTrips :: IO ()
bodyRoundTrips = do
  let digest = T.replicate 64 "0"
      start =
        Start
          { startRun = RunId "broker-hello",
            startProgramSha256 = T.replicate 32 "ab",
            startPolicyDigest = "sha256:" <> T.replicate 64 "c",
            startPersonAnswering = Just PersonAnswerLocalControl,
            startTarget = unicode,
            startLineage = ForkRun,
            startParent = Just (RunId "parent"),
            startInputs = [StartInput "prompt" 0 digest, StartInput unicode 18446744073709 (T.replicate 64 "f")]
          }
      plainStart = start {startPersonAnswering = Nothing, startLineage = RootRun, startParent = Nothing, startInputs = []}
  body "start" FlowStart startBody startFromBody start
  body "start without answering mode, parent or inputs" FlowStart startBody startFromBody plainStart
  refused "start that names an input twice" (startFromBody (startBody start {startInputs = [StartInput "a" 1 digest, StartInput "a" 2 digest]}))
  refused "start whose program hash is not a digest" (startFromBody (startBody start {startProgramSha256 = "ABC"}))

  let attempt = AttemptId (OccurrenceId 3) 1
      cancelControl = Control (ControlId "cancel") Nothing Nothing CancelRun
      falseControl = Control (ControlId "answer-false") (Just (OccurrenceId 2)) Nothing (AnswerPerson (Bool False))
      personAnswer = object ["false" .= False, "null" .= Null, "decimal" .= decimal, "text" .= unicode]
      everyProtocol =
        [ cancelControl,
          Control (ControlId "steer") (Just (OccurrenceId 3)) (Just attempt) (Steer InterruptNow unicode),
          Control (ControlId "retry") (Just (OccurrenceId 3)) Nothing RetryOccurrence,
          Control (ControlId "failover") (Just (OccurrenceId 3)) Nothing (ChooseRecovery RecoveryFailOver),
          Control (ControlId "abandon") Nothing Nothing (ChooseRecovery RecoveryAbandon),
          Control (ControlId "redirect") (Just (OccurrenceId 0)) Nothing (RedirectOccurrence "acp:other")
        ]
      correlated =
        [ falseControl,
          Control (ControlId "answer-null") (Just (OccurrenceId 2)) Nothing (AnswerPerson Null),
          Control (ControlId "answer-object") (Just (OccurrenceId 2)) Nothing (AnswerPerson personAnswer)
        ]
  forM_ [1, 2, 3] $ \protocol ->
    forM_ (everyProtocol <> if protocol == 1 then [] else correlated) $ \control -> do
      value <- either (fail . T.unpack) pure (controlBody protocol control)
      bodyValue ("control " <> show protocol <> " " <> show (controlId control)) FlowControl value controlFromBody (protocol, control)
  refused "person answer at control protocol 1" (controlBody 1 falseControl)
  refused "control protocol 4" (controlBody 4 cancelControl)
  cancel <- either (fail . T.unpack) pure (controlBody 2 cancelControl)
  refused "control body with an unknown field" (controlFromBody (withKey "extra" Null cancel))
  frame <- either (fail . T.unpack) pure (frameOf cancel)
  refused "control frame with an unknown field"
    (controlFromBody (object ["protocol" .= (2 :: Int), "control" .= withKey "extra" Null frame]))

  let text = P.Request (P.Q (P.AddrModel "writer") (P.QScope (Just "claude") Nothing) unicode 0) P.Consult
      verdict = P.Request (P.Q (P.AddrPerson "owner") P.scopeUnit "approve?" 2) P.Observe
      flag = P.Request (P.Q (P.AddrToolExec "gate" "make" ["check"]) (P.QScope Nothing (Just "strict")) "" 1) P.Consult
      receipt = P.Request (P.Q (P.AddrModel "actor") P.scopeUnit unicode 3) P.Effect
      structured = P.Request (P.Q (P.AddrModel "ledger") P.scopeUnit unicode 12345678901234567890) P.Observe
  exchange "text" P.SText text [unicode, ""]
  exchange "verdict" P.SVerdict verdict [P.Approve, P.Declined, P.Object ["fix \10003"]]
  exchange "flag" P.SFlag flag [False, True]
  exchange "receipt" P.SAck receipt [()]
  exchange "structured" ledgerCode structured [(123456789012345678901234567890123 % 1000, (unicode, ((), ())))]
  check "flag false is JSON false in its record" (answerBody P.SFlag False == Bool False)

  let request = E.EngineRequest "acp:claude" (Just "opus") Nothing (-12345678901234567890) E.Effect E.StructuredAnswer unicode True
  body "engine-start" FlowEngineStart engineStartBody engineStartFromBody request
  body "engine-start without axes" FlowEngineStart engineStartBody engineStartFromBody request {E.engineModelAxis = Nothing, E.engineRequiresCompletedTurn = False}
  body "turn" FlowTurn turnBody turnFromBody unicode
  body "empty turn" FlowTurn turnBody turnFromBody ""
  forM_ [E.Completed, E.Unverified, E.Incomplete unicode] $ \completion ->
    body ("engine-result " <> show completion) FlowEngineResult engineResultBody engineResultFromBody (E.EngineResult unicode "narration \26085" completion)
  forM_ [E.InterruptNow, E.NextBoundary] $ \timing ->
    body ("steer " <> show timing) FlowSteer (uncurry steerBody) steerFromBody (timing, unicode)
  body "done" FlowDone (const doneBody) doneFromBody ()
  refused "done with a value" (doneFromBody (Bool False))
  forM_ (Refused : map FailedWith [FailureSetup, FailureTransport, FailureDecode, FailureProtocol, FailureCancelled, FailureRuntime]) $ \failure ->
    body ("failure " <> show failure) FlowFailure (uncurry failureBody) failureFromBody (failure, unicode)
  refused "failure of an unknown class" (failureFromBody (object ["class" .= ("other" :: Text), "message" .= ("" :: Text)]))
  let eventRecord = recordOf FlowEvent (Workflow (RunId "r")) Public noAbout (EventNumber (SeqNo 18446744073709551615))
  check "event round trip" ((decodeFlowLine (encodeFlowLine eventRecord) >>= \record -> eventFromContent (ContentEvent (eventNumber (recBody record)))) == Right (SeqNo 18446744073709551615))
  check "event content" (eventFromContent (eventContent (SeqNo 5)) == Right (SeqNo 5))
  refused "event content that is a value" (eventFromContent (ContentValue Null))
  forM_ [E.EnginePermissionGranted unicode, E.EnginePermissionRefused] $ \answer ->
    body ("permission " <> show answer) FlowPermission permissionBody permissionFromBody (E.EnginePermissionReport unicode "tool \26085" answer)
  where
    eventNumber (EventNumber number) = number
    eventNumber _ = SeqNo 0
    frameOf value = case value of
      Aeson.Object fields -> maybe (Left "no control") Right (KeyMap.lookup "control" fields)
      _ -> Left "not an object"
    -- The body through its codec, its record line and back.
    body :: (Eq a, Show a) => String -> Schema -> (a -> Value) -> (Value -> Either Text a) -> a -> IO ()
    body label schema encodeBody decodeBody value = bodyValue label schema (encodeBody value) decodeBody value
    exchange :: (Eq (P.El c), Show (P.El c)) => String -> P.SCode c -> P.Request c -> [P.El c] -> IO ()
    exchange label code request answers = do
      body ("question " <> label) FlowQuestion (questionBody code) (questionFromBody code) request
      forM_ answers $ \answer -> body ("answer " <> label <> " " <> show answer) FlowAnswer (answerBody code) (answerFromBody code) answer

bodyValue :: (Eq a, Show a) => String -> Schema -> Value -> (Value -> Either Text a) -> a -> IO ()
bodyValue label schema value decodeBody expected = do
  check (label <> " body round trip") (decodeBody value == Right expected)
  let record = recordOf schema (Workflow (RunId "r")) (To (Model "m")) fullAbout (Inline value)
  case decodeFlowLine (encodeFlowLine record) of
    Right Record {recBody = Inline carried} -> check (label <> " line round trip") (decodeBody carried == Right expected)
    other -> fail ("flow: " <> label <> " line decoded as " <> show other)

lineRefusals :: IO ()
lineRefusals = do
  let record = recordOf FlowAnswer (Model "m") (To (Workflow (RunId "r"))) fullAbout (Inline (object ["inner" .= object ["a" .= (1 :: Int)]]))
      line = encodeFlowLine record
  check "the fixture line decodes" (decodeFlowLine line == Right record)
  refusedWith "duplicate top-level key" "duplicate key 'schema'" (decodeFlowLine (insertAfterBrace ("\"schema\":\"answer\",") line))
  refusedWith "duplicate nested key" "duplicate key 'a'" (decodeFlowLine (replaceOnce "\"a\":1" "\"a\":1,\"a\":1" line))
  refusedWith "unknown top-level field" "unknown field 'extra'" (decodeFlowLine (insertAfterBrace "\"extra\":null," line))
  refusedWith "unknown field in about" "unknown field 'extra'" (decodeFlowLine (replaceOnce "\"about\":{" "\"about\":{\"extra\":1," line))
  refusedWith "unknown field in an actor" "unknown form" (decodeFlowLine (replaceOnce "\"from\":{" "\"from\":{\"extra\":1," line))
  refused "a reply without its position" (decodeFlowLine (encodeFlowLine record {recSchema = FlowEngineResult, recReplyTo = Nothing}))
  refused "a tell with a position" (decodeFlowLine (encodeFlowLine record {recSchema = FlowNotice}))
  refused "an event record with a value" (decodeFlowLine (encodeFlowLine record {recSchema = FlowEvent, recReplyTo = Nothing}))
  refused "an answer record with an event number" (decodeFlowLine (encodeFlowLine record {recBody = EventNumber (SeqNo 1)}))
  refused "an attempt without its occurrence" (decodeFlowLine (encodeFlowLine record {recAbout = noAbout {aboutAttempt = Just 1}}))
  refused "an unknown schema" (decodeFlowLine (replaceOnce "\"schema\":\"answer\"" "\"schema\":\"answers\"" line))
  refused "a line with whitespace" (decodeFlowLine (line <> " "))
  refused "a line with a newline" (decodeFlowLine (line <> "\n"))
  refused "an exponent spelling of a number" (decodeFlowLine (replaceOnce "\"a\":1" "\"a\":1e0" line))
  refused "a trailing-zero spelling of a number" (decodeFlowLine (replaceOnce "\"a\":1" "\"a\":1.00" line))
  refused "another spelling of a string" (decodeFlowLine (replaceOnce "\"inner\"" "\"\\u0069nner\"" line))
  refused "a claim check of an inline size" (decodeFlowLine (encodeFlowLine record {recBody = ClaimCheck (T.replicate 64 "a") 65536}))
  refused "a claim check with an upper-case digest" (decodeFlowLine (encodeFlowLine record {recBody = ClaimCheck (T.replicate 64 "A") 65537}))
  refused "two values" (decodeFlowLine (line <> line))
  refused "deep nesting" (decodeFlowLine (encodeFlowLine record {recBody = Inline (iterate (\inner -> Array (pure inner)) Null !! 200)}))

  -- A line above maxFrameBytes is refused before it is decoded. The oversize
  -- line is a valid record, so only the length check can refuse it, and the
  -- refusal allocates far less than decoding the line would.
  let big = encodeFlowLine record {recBody = Inline (String (T.replicate maxFrameBytes "x"))}
      fits = encodeFlowLine record {recBody = Inline (String (T.replicate (maxFrameBytes - 1024) "x"))}
  _ <- evaluate (BS.length big + BS.length fits)
  check "the oversize fixture is above maxFrameBytes" (BS.length big > maxFrameBytes && BS.length fits <= maxFrameBytes)
  (bigAllocated, bigResult) <- allocation (decodeFlowLine big)
  refusedWith "a line above maxFrameBytes" "exceeds 1048576 bytes" bigResult
  (fitsAllocated, fitsResult) <- allocation (decodeFlowLine fits)
  check "a line at the frame bound decodes" (either (const False) (const True) fitsResult)
  check ("an oversize line is refused before allocation (" <> show bigAllocated <> " bytes)") (bigAllocated < 16384)
  check ("decoding a line at the bound allocates (" <> show fitsAllocated <> " bytes)") (fitsAllocated > toInteger maxFrameBytes)
  where
    insertAfterBrace field bytes = "{" <> field <> BS.drop 1 bytes
    replaceOnce old new bytes =
      let (before, after) = BS.breakSubstring old bytes
       in if BS.null after then error ("fixture lacks " <> BC.unpack old) else before <> new <> BS.drop (BS.length old) after
    allocation :: Either Text Record -> IO (Integer, Either Text Record)
    allocation result = do
      before <- getAllocationCounter
      forced <- evaluate (either (\why -> T.length why `seq` result) (\decoded -> recSchema decoded `seq` result) result)
      after <- getAllocationCounter
      pure (toInteger (before - after :: Int64), forced)

writerChecks :: IO ()
writerChecks = do
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-flow-" temporary $ \bucket -> do
    let path = bucket </> "root"
        from = Workflow (RunId "run")
        to = To (Model "acp:claude")
    withPrivateRoot "flow test root" path $ \root -> do
      let inline = String (T.replicate (65536 - 2) "x")
          claimed = String (T.replicate (65537 - 2) "y")
      check "the inline fixture encodes to 65536 bytes" (BL.length (encode inline) == 65536)
      check "the claim fixture encodes to 65537 bytes" (BL.length (encode claimed) == 65537)
      records <- withFlowWriter strictFlowCodec root "flow.ndjson" $ \writer -> do
        (p0, r0) <- appendTell writer FlowStart from (To from) noAbout (ContentValue (String "start"))
        (p1, r1) <- appendTell writer FlowEvent from Public noAbout (eventContent (SeqNo 0))
        (p2, r2) <- appendAsk writer FlowQuestion from to noAbout {aboutOccurrence = Just (OccurrenceId 0)} (ContentValue inline)
        (p3, r3) <- appendAsk writer FlowEngineStart from to noAbout (ContentValue claimed)
        (p4, r4) <- appendReply writer FlowDone p3 (Model "acp:claude") (To from) noAbout (ContentValue doneBody)
        (p5, r5) <- appendAsk writer FlowTurn from to noAbout (ContentValue claimed)
        (p6, r6) <- appendReply writer FlowFailure p5 (Model "acp:claude") (To from) noAbout (ContentValue (failureBody (FailedWith FailureTransport) "gap"))
        (p7, r7) <- appendReply writer FlowAnswer p2 (Model "acp:claude") (To from) noAbout (ContentValue (Bool False))
        check "positions are 0-based and consecutive" (map positionIndex [p0, p1, p2, p3, p4, p5, p6, p7] == [0 .. 7])
        check "a reply names its ask" (recReplyTo r4 == Just p3 && recReplyTo r7 == Just p2 && recReplyTo r0 == Nothing)
        check "a body of 65536 bytes is inline" (recBody r2 == Inline inline)
        check "the sender is the writer's binding" (recFrom r4 == Model "acp:claude" && recFrom r0 == from)
        claim <- case recBody r3 of
          ClaimCheck digest size -> check "a claim check records the size" (size == 65537) >> pure (digest, size)
          other -> fail ("flow: a body of 65537 bytes is " <> show other)
        check "the same body shares its claim check" (recBody r5 == recBody r3)
        refusedIO "a reply to a later position" (appendReply writer FlowAnswer (Position 9) Manager to noAbout (ContentValue Null))
        refusedIO "a reply to its own position" (appendReply writer FlowAnswer (Position 8) Manager to noAbout (ContentValue Null))
        refusedIO "a reply to an ask of the wrong schema" (appendReply writer FlowAnswer p3 Manager to noAbout (ContentValue Null))
        refusedIO "a done reply to a question" (appendReply writer FlowDone p2 Manager to noAbout (ContentValue doneBody))
        refusedIO "a reply to a tell" (appendReply writer FlowFailure p0 Manager to noAbout (ContentValue (failureBody (FailedWith FailureRuntime) "")))
        refusedIO "a reply to a reply" (appendReply writer FlowFailure p4 Manager to noAbout (ContentValue (failureBody (FailedWith FailureRuntime) "")))
        refusedIO "an ask of a tell schema" (appendAsk writer FlowControl from to noAbout (ContentValue Null))
        refusedIO "a tell of a reply schema" (appendTell writer FlowAnswer from to noAbout (ContentValue Null))
        refusedIO "an event with a value" (appendTell writer FlowEvent from Public noAbout (ContentValue Null))
        refusedIO "a question with an event number" (appendAsk writer FlowQuestion from to noAbout (eventContent (SeqNo 1)))
        refusedIO "a line above maxFrameBytes" (appendTell writer FlowNotice Manager Public noAbout {aboutCommand = Just (T.replicate maxFrameBytes "z")} (ContentValue Null))
        (p8, _) <- appendReply writer FlowEngineResult p5 (Model "acp:claude") (To from) noAbout (ContentValue (engineResultBody (E.EngineResult "late" "" E.Completed)))
        check "refused appends take no position" (positionIndex p8 == 8)
        pure ([r0, r1, r2, r3, r4, r5, r6, r7], claim)
      let (carried, (digest, size)) = records
      bytes <- readPrivateFileAt root ["flow.ndjson"] (toInteger maxArtifactBytes)
      let lines' = BC.lines bytes
      check "the log holds one line for each accepted append" (length lines' == 9)
      decoded <- forM lines' (either (fail . T.unpack) pure . decodeFlowLine)
      zipWithM_ (\index (record, stored) -> check ("carried record " <> show (index :: Int) <> " is the stored record") (record == stored)) [0 ..] (zip carried decoded)
      content <- readFlowContent root (ClaimCheck digest size)
      check "a claim check reads back its verified value" (content == Right (ContentValue claimed))
      inlineContent <- readFlowContent root (Inline inline)
      check "an inline body reads back its value" (inlineContent == Right (ContentValue inline))
      let claimFile = path </> flowClaimDirectory </> T.unpack digest
      original <- BS.readFile claimFile
      BS.writeFile claimFile (BS.take (BS.length original - 2) original <> "z\"")
      tampered <- readFlowContent root (ClaimCheck digest size)
      refusedWith "a claim check whose bytes changed" "does not have its recorded digest" tampered
      BS.writeFile claimFile (BS.take 10 original)
      truncated <- readFlowContent root (ClaimCheck digest size)
      refused "a claim check whose size changed" truncated
      missing <- readFlowContent root (ClaimCheck (T.replicate 64 "e") size)
      refused "a missing claim check" missing
      exclusive <- try @IOError (openFlowWriter strictFlowCodec root "flow.ndjson")
      check "a second writer cannot open the same log" (isLeft exclusive)

-- | The event sink of a run with a run log appends the record of each event
-- before its line, and a failed append fails the run through the observer
-- failure path: the run ends with the original exception, the events file
-- holds exactly the lines whose records were appended, and every later call of
-- the sink fails.
runLogSinkChecks :: IO ()
runLogSinkChecks = do
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-run-log-" temporary $ \bucket -> do
    let run = RunId "run-log"
        plan = askC1 P.SText (consultRequest (Q (AddrModel "run-log") scopeUnit "hello" 0))
        world = concurrentWorld (\c _ -> pure (S.defaultEl c))
        failingAt cut =
          strictFlowCodec
            { flowDecodeLine = \line -> decodeFlowLine line >>= \record ->
                if recBody record == EventNumber (SeqNo cut) then Left "injected run-log failure" else Right record
            }
        attempt name codec = do
          let path = bucket </> name
          withPrivateRoot "run log test root" path $ \root -> do
            events <- openBinaryFile (path </> "events.ndjson") WriteMode
            (outcome, later) <- withFlowWriter codec root runLogName $ \writer -> do
              sink <- handlesEventSinkLogged (Just writer) 2 [events] run
              outcome <- try @SomeException (runPlanObserved sink noChains world plan)
              later <- try @SomeException (sink (RunFailed FailureRuntime "after the run"))
              pure (outcome, later)
            hClose events
            eventLines <- BC.lines <$> BS.readFile (path </> "events.ndjson")
            flowLines <- BC.lines <$> BS.readFile (path </> runLogName)
            records <- forM flowLines (either (fail . T.unpack) pure . decodeFlowLine)
            pure (outcome, later, eventLines, records)
        eventRecord index record =
          recSchema record == FlowEvent
            && recFrom record == Workflow run
            && recTo record == Public
            && recBody record == EventNumber (SeqNo index)
    (baseline, _, baselineLines, baselineRecords) <- attempt "baseline" strictFlowCodec
    check "the run without a failing append completes" (either (const False) (const True) baseline)
    -- The last line is the event that the sink writes after the run.
    let total = length baselineLines
        runEvents = total - 1
    check "the run emits several events" (runEvents >= 3)
    check "each line of the events file has the event record of its sequence number, in order"
      (length baselineRecords == total && and (zipWith eventRecord [0 ..] baselineRecords))
    forM_ [0 .. fromIntegral runEvents - 1] $ \cut -> do
      (outcome, later, eventLines, records) <- attempt ("cut-" <> show cut) (failingAt cut)
      let injected result = case result of
            Left failure | Just (FlowError why) <- fromException failure -> "injected run-log failure" `T.isInfixOf` why
            _ -> False
      check ("a failed append at event " <> show cut <> " fails the run with the original exception") (injected outcome)
      check ("a failed append at event " <> show cut <> " fails every later event") (injected later)
      check ("no line follows the failed append at event " <> show cut) (length eventLines == fromIntegral cut)
      check ("the run log holds the records of the written lines before event " <> show cut)
        (length records == fromIntegral cut && and (zipWith eventRecord [0 ..] records))

check :: String -> Bool -> IO ()
check label ok = unless ok (fail ("flow: " <> label))

refused :: String -> Either Text a -> IO ()
refused label result = check ("refuses " <> label) (isLeft result)

refusedWith :: String -> Text -> Either Text a -> IO ()
refusedWith label expected = \case
  Left why | expected `T.isInfixOf` why -> pure ()
  Left why -> fail ("flow: " <> label <> " was refused for another reason: " <> T.unpack why)
  Right _ -> fail ("flow: " <> label <> " was accepted")

refusedIO :: String -> IO a -> IO ()
refusedIO label action = do
  result <- try @FlowError action
  check ("the writer refuses " <> label) (isLeft result)

withKey :: Aeson.Key -> Value -> Value -> Value
withKey key value = \case
  Aeson.Object fields -> Aeson.Object (KeyMap.insert key value fields)
  other -> other
