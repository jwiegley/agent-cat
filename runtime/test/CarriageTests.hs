{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Carriage of broker operations through the run log by 'flowBroker': each
-- receiver acts on the value decoded from its record, and the runtime receives
-- the value decoded from the reply record.
module CarriageTests (carriageTests) where

import qualified Agentic.Engine as E
import Agentic.Plan
import Agentic.Planning (Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec), Code (CodeAck, CodeFlag))
import Agentic.Runtime
import BucketEvidence (withCaptureBucket)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value (Array, Bool, String))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort, sortOn)
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Text (Text)
import System.Directory (getTemporaryDirectory)
import System.FilePath ((</>))
import System.Timeout (timeout)

carriageTests :: IO ()
carriageTests = do
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-carriage-" temporary $ \bucket -> do
    strict <- carriageFindings (bucket </> "strict") strictFlowCodec flowBroker
    expect ("strict carriage: " <> show strict) (null strict)
    lossy <- carriageFindings (bucket </> "lossy") lossyCodec flowBroker
    expect ("lossy carriage: " <> show lossy) (null lossy)
    mirrored <- carriageFindings (bucket </> "mirror") lossyCodec mirrorBroker
    expect "a mirror that hands on the original values fails the carriage check" (not (null mirrored))
    failureChecks (bucket </> "failures")
    scopeChecks (bucket </> "scopes")
  answererChecks
  putStrLn "carriage checks passed: decoded values reach receivers and the runtime, a mirror is detected, D2, D3, failures and occurrence scopes"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

run :: RunId
run = RunId "carriage"

intake :: Actor
intake = Principal (LocalAccount 501 (Just "owner"))

answerer :: Actor
answerer = Model "model probe"

flowOf :: FlowWriter -> Maybe FlowScope -> RunFlow
flowOf writer scope =
  RunFlow
    { runFlowWriter = writer,
      runFlowProtocol = 2,
      runFlowRun = run,
      runFlowIntake = intake,
      runFlowAnswerer = const answerer,
      runFlowFailureClass = const FailureRuntime,
      runFlowScope = scope
    }

flagRequest :: Request 'CodeFlag
flagRequest = consultRequest (Q (AddrModel "probe") scopeUnit "orig question" 0)

engineRequestOf :: E.EngineRequest
engineRequestOf = E.EngineRequest "model probe" Nothing Nothing 0 E.Consult E.FlagAnswer "orig prompt" True

report :: E.EnginePermissionReport
report = E.EnginePermissionReport "orig permission question" "orig tool" (E.EnginePermissionGranted "orig option")

personControl :: Control
personControl = Control (ControlId "orig-control") (Just (OccurrenceId 4)) Nothing (AnswerPerson (Bool False))

-- | An engine that answers every turn with the text it was given.
newtype EchoEngine = EchoEngine (IORef [E.EngineRequest])

instance E.Engine EchoEngine where
  startEngine (EchoEngine started) _ request = do
    atomicModifyIORef' started (\requests -> (requests <> [request], ()))
    pure (E.EngineConversation (\text -> pure (E.EngineResult ("orig answer to " <> text) "orig narration" E.Completed)))
  engineTurnLane _ = Nothing

-- | A codec that changes every decoded string that contains @orig@, and every
-- JSON @false@ of an answer, while it keeps each body decodable.
lossyCodec :: FlowCodec
lossyCodec =
  strictFlowCodec
    { flowDecodeLine = \line -> do
        record <- decodeFlowLine line
        pure $ case recBody record of
          Inline value -> record {recBody = Inline (lossy (recSchema record) value)}
          _ -> record
    }
  where
    lossy schema = \case
      String text -> String (T.replace "orig" "lossy" text)
      Bool False | schema == FlowAnswer -> Bool True
      Aeson.Object fields -> Aeson.Object (KeyMap.map (lossy schema) fields)
      Array items -> Array (fmap (lossy schema) items)
      other -> other

-- | A test broker that appends through 'flowBroker' but hands the inner
-- receivers the original request and turn text, and returns their original
-- replies. It exists only to show that the carriage check detects a mirror.
mirrorBroker :: FlowCodec -> RunFlow -> DataBroker -> DataBroker
mirrorBroker codec flow inner =
  flowBroker codec flow inner
    { brokerRequest = \receive code request -> do
        original <- newIORef Nothing
        let mirror _ _ = do answer <- brokerRequest inner receive code request; writeIORef original (Just answer); pure answer
        _ <- brokerRequest (flowBroker codec flow inProcessBroker) mirror code request
        readIORef original >>= maybe (fail "mirror: no original answer") pure,
      brokerTurn = \conversation text -> do
        original <- newIORef Nothing
        let capture = inProcessBroker {brokerTurn = \c _ -> do result <- brokerTurn inner c text; writeIORef original (Just result); pure result}
        _ <- brokerTurn (flowBroker codec flow capture) conversation text
        readIORef original >>= maybe (fail "mirror: no original result") pure
    }

-- | The records of a log, decoded by the codec that carried them.
recordsOf :: FlowCodec -> FilePath -> IO [Record]
recordsOf codec path = do
  bytes <- BS.readFile path
  forM (BC.lines bytes) (either (fail . T.unpack) pure . flowDecodeLine codec)

bodyOf :: Record -> Value
bodyOf record = case recBody record of
  Inline value -> value
  other -> error ("carriage: a test body is not inline: " <> show other)

withLog :: FilePath -> FlowCodec -> (FlowWriter -> IO a) -> IO (a, [Record])
withLog path codec action =
  withPrivateRoot "carriage test root" path $ \root -> do
    result <- withFlowWriter strictFlowCodec root "flow.ndjson" action
    records <- recordsOf codec (path </> "flow.ndjson")
    pure (result, records)

-- ---------------------------------------------------------------------------
-- Carriage
-- ---------------------------------------------------------------------------

data Seen = Seen
  { seenRequests :: IORef [Request 'CodeFlag],
    seenStarts :: IORef [E.EngineRequest],
    seenTurns :: IORef [Text],
    seenSteers :: IORef [(E.EngineSteering, Text)],
    seenUpdates :: IORef [E.EngineUpdate],
    seenControls :: IORef [Control]
  }

-- | Run every carried operation once through the broker that the maker builds
-- over a recording inner broker, and return each difference between a value
-- that a receiver or the runtime got and the decoding of its record.
carriageFindings :: FilePath -> FlowCodec -> (FlowCodec -> RunFlow -> DataBroker -> DataBroker) -> IO [String]
carriageFindings path codec maker = do
  seen <- Seen <$> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef []
  started <- newIORef []
  let note ref value = atomicModifyIORef' ref (\values -> (values <> [value], ()))
      inner =
        inProcessBroker
          { brokerRequest = \receive code request -> case code of
              SFlag -> note (seenRequests seen) request >> receive code request
              _ -> receive code request,
            brokerStart = \engine context request -> note (seenStarts seen) request >> E.startEngine engine context request,
            brokerTurn = \conversation text -> note (seenTurns seen) text >> E.runEngineTurn conversation text,
            brokerSteer = \steerer timing text -> note (seenSteers seen) (timing, text) >> steerer timing text,
            brokerUpdate = \sink update -> note (seenUpdates seen) update >> sink update,
            brokerControl = \receive control -> note (seenControls seen) control >> receive control
          }
  scope <- newFlowScope (OccurrenceId 4) 2
  (returned, records) <- withLog path codec $ \writer -> do
    let broker = maker codec (flowOf writer (Just scope)) inner
        context = E.EngineContext (\_ _ action -> action (const (pure ())))
    replies <- newIORef Nothing
    answer <- brokerRequest broker (\_ _ -> do
      conversation <- brokerStart broker (EchoEngine started) context engineRequestOf
      result <- brokerTurn broker conversation "orig turn"
      brokerUpdate broker (const (pure ())) (E.EnginePermission report)
      accepted <- brokerSteer broker (\_ _ -> pure (Right ())) E.InterruptNow "orig steer"
      refusedSteer <- brokerSteer broker (\_ _ -> pure (Left "orig refusal")) E.NextBoundary "orig second steer"
      writeIORef replies (Just (result, accepted, refusedSteer))
      pure False) SFlag flagRequest
    continued <- brokerControl broker (\_ -> pure True) personControl
    (result, accepted, refusedSteer) <- readIORef replies >>= maybe (fail "carriage: the receiver did not run") pure
    pure (answer, result, accepted, refusedSteer, continued)
  let (answer, result, accepted, refusedSteer, continued) = returned
      schemas = map recSchema records
      bodies schema = [bodyOf record | record <- records, recSchema record == schema]
      only :: Schema -> (Value -> Either Text a) -> Maybe a
      only schema decode = case bodies schema of
        [value] -> either (const Nothing) Just (decode value)
        _ -> Nothing
      finding label ok = [label | not ok]
  requests <- readIORef (seenRequests seen)
  starts <- readIORef (seenStarts seen)
  turns <- readIORef (seenTurns seen)
  steers <- readIORef (seenSteers seen)
  updates <- readIORef (seenUpdates seen)
  controls <- readIORef (seenControls seen)
  let steerBodies = map steerFromBody (bodies FlowSteer)
      failures = map failureFromBody (bodies FlowFailure)
      expectedSchemas =
        [ FlowQuestion, FlowEngineStart, FlowDone, FlowTurn, FlowEngineResult, FlowPermission,
          FlowSteer, FlowDone, FlowSteer, FlowFailure, FlowAnswer, FlowControl ]
  pure $
    concat
      [ finding ("records in order, not " <> show schemas) (schemas == expectedSchemas),
        finding "the request receiver got the decoded question" (map Just requests == [only FlowQuestion (questionFromBody SFlag)]),
        finding "the runtime got the decoded answer" (Just answer == only FlowAnswer (answerFromBody SFlag)),
        finding "the start receiver got the decoded engine request" (map Just starts == [only FlowEngineStart engineStartFromBody]),
        finding "the turn receiver got the decoded turn" (map Just turns == [only FlowTurn turnFromBody]),
        finding "the runtime got the decoded engine result" (Just result == only FlowEngineResult engineResultFromBody),
        finding "the update receiver got the decoded permission report" (map (Just . E.EnginePermission) [r | E.EnginePermission r <- updates] == [E.EnginePermission <$> only FlowPermission permissionFromBody]),
        finding "the steer receiver got each decoded steering" (map Right steers == steerBodies),
        finding "an accepted steering returns the done reply" (accepted == Right ()),
        finding "a refused steering returns the decoded refusal" (map (fmap (\(kind, message) -> (kind, Left message))) failures == [Right (Refused, refusedSteer)]),
        finding "the control receiver got the decoded control" (map (Right . (,) 2) controls == map controlFromBody (bodies FlowControl)),
        finding "the control loop result is the receiver's" continued,
        finding "records carry the occurrence scope" (all (scoped . recAbout) [record | record <- records, recSchema record /= FlowControl]),
        finding "the control names its command and comes from the intake" (all (\record -> recFrom record == intake && aboutCommand (recAbout record) == Just "orig-control") [record | record <- records, recSchema record == FlowControl]),
        finding "the permission comes from the adapter of the question" (all ((== Adapter "model probe") . recFrom) [record | record <- records, recSchema record == FlowPermission])
      ]
  where
    scoped about = aboutOccurrence about == Just (OccurrenceId 4) && aboutEpoch about == Just 2 && aboutNativeRun about == Just run

-- ---------------------------------------------------------------------------
-- Failures: D2, D3, receiver failures and asynchronous exceptions
-- ---------------------------------------------------------------------------

failureChecks :: FilePath -> IO ()
failureChecks path = do
  let failingOn schema =
        strictFlowCodec
          { flowDecodeLine = \line -> decodeFlowLine line >>= \record ->
              if recSchema record == schema then Left "injected decoding failure" else Right record
          }
      undecodableQuestion =
        strictFlowCodec
          { flowDecodeLine = \line -> decodeFlowLine line >>= \record ->
              if recSchema record == FlowQuestion then Right record {recBody = Inline (String "not a request")} else Right record
          }
      attempt name codec receive = do
        calls <- newIORef (0 :: Int)
        scope <- newFlowScope (OccurrenceId 0) 0
        (outcome, records) <- withLog (path <> "-" <> name) strictFlowCodec $ \writer ->
          try @SomeException (brokerRequest (flowBroker codec (flowOf writer (Just scope)) inProcessBroker) (\_ _ -> atomicModifyIORef' calls (\n -> (n + 1, ())) >> receive) SFlag flagRequest)
        called <- readIORef calls
        pure (outcome, called, map recSchema records, records)
      flowRefused = \case
        Left failure | Just (FlowError _) <- fromException failure -> True
        _ -> False
  (replyLost, replyCalls, replySchemas, _) <- attempt "reply" (failingOn FlowAnswer) (pure False)
  expect "D2: a failed reply append refuses the reply after the receiver returned" (flowRefused replyLost && replyCalls == 1)
  expect "D2: the ask stays without a reply" (replySchemas == [FlowQuestion])
  (lineLost, lineCalls, lineSchemas, _) <- attempt "line" (failingOn FlowQuestion) (pure False)
  expect "D3: undecodable bytes fail the operation before delivery" (flowRefused lineLost && lineCalls == 0 && null lineSchemas)
  (bodyLost, bodyCalls, bodySchemas, _) <- attempt "body" undecodableQuestion (pure False)
  expect "D3: an undecodable body fails the operation before delivery" (flowRefused bodyLost && bodyCalls == 0 && bodySchemas == [FlowQuestion])
  (raised, raisedCalls, raisedSchemas, raisedRecords) <- attempt "raised" strictFlowCodec (ioError (userError "orig receiver failure"))
  let original = case raised of
        Left failure -> maybe False (const True) (fromException @IOError failure)
        Right _ -> False
      failureRecord = [record | record <- raisedRecords, recSchema record == FlowFailure]
  expect "a receiver failure propagates as the original exception" (original && raisedCalls == 1)
  expect "a receiver failure is the reply to its ask" (raisedSchemas == [FlowQuestion, FlowFailure] && map recReplyTo failureRecord == [Just (Position 0)])
  expect "a receiver failure records its class and message" $ case map (failureFromBody . bodyOf) failureRecord of
    [Right (FailedWith FailureRuntime, message)] -> "orig receiver failure" `T.isInfixOf` message
    _ -> False
  (killed, _, killedSchemas, _) <- attempt "async" strictFlowCodec (throwIO ThreadKilled)
  expect "an asynchronous exception propagates" (either (\failure -> fromException failure == Just ThreadKilled) (const False) killed)
  expect "an asynchronous exception appends nothing" (killedSchemas == [FlowQuestion])
  unscoped <- withLog (path <> "-unscoped") strictFlowCodec $ \writer -> do
    let broker = flowBroker strictFlowCodec (flowOf writer Nothing) inProcessBroker
        context = E.EngineContext (\_ _ action -> action (const (pure ())))
    started <- newIORef []
    try @FlowError (brokerStart broker (EchoEngine started) context engineRequestOf)
  expect "an engine start outside an occurrence is refused before delivery" (isLeft (fst unscoped) && null (snd unscoped))

-- ---------------------------------------------------------------------------
-- Scoping
-- ---------------------------------------------------------------------------

-- | An engine whose turns wait until two engine conversations have started, so
-- two occurrences are in flight together.
data BarrierEngine = BarrierEngine (IORef [E.EngineRequest]) (TVar Int)

instance E.Engine BarrierEngine where
  startEngine (BarrierEngine requests started) _ request = do
    atomicModifyIORef' requests (\values -> (values <> [request], ()))
    atomically (modifyTVar' started (+ 1))
    pure . E.EngineConversation $ \_ -> do
      atomically (readTVar started >>= check . (>= 2))
      pure (E.EngineResult "yes" "" E.Completed)
  engineTurnLane _ = Nothing

scopeChecks :: FilePath -> IO ()
scopeChecks path = do
  requests <- newIORef []
  started <- newTVarIO 0
  let request name = consultRequest (Q (AddrModel name) scopeUnit ("scope " <> name) 0) :: Request 'CodeFlag
      act = effectRequest (Q (AddrModel "actor") scopeUnit "perform" 0) :: Request 'CodeAck
      plan = PAskC SFlag (request "a") (PAskC SFlag (request "b") (PAskC SAck act (PAskC SFlag (request "c") (PRet (exprVar VHere)))))
      world = worldOfEngineWith defaultExecSettings {esLog = const (pure ())} (BarrierEngine requests started)
      start =
        Start
          { startRun = run,
            startProgramSha256 = T.replicate 64 "a",
            startPolicyDigest = "policy",
            startPersonAnswering = Just PersonAnswerEngine,
            startTarget = "acp:stub",
            startLineage = RootRun,
            startParent = Nothing,
            startInputs = []
          }
  (outcome, records) <- withLog path strictFlowCodec $ \writer -> do
    let flow = runFlowFor writer 2 intake start []
    timeout 20000000 (runPlanScoped (flowBroker strictFlowCodec flow inProcessBroker) (flowScopedBroker strictFlowCodec flow inProcessBroker) Nothing nullPersistenceHooks nullEventSink noChains world plan)
  expect "the scoped run completes" (fmap fst outcome == Just True)
  let indexed = zip [0 :: Int ..] records
      questions = [(index, record) | (index, record) <- indexed, recSchema record == FlowQuestion]
      occurrenceOf = aboutOccurrence . recAbout
      askOf record = case recReplyTo record of
        Just (Position position) -> lookup (fromIntegral position) indexed
        Nothing -> Nothing
      questionFor index record = [q | (qi, q) <- questions, qi < index, occurrenceOf q == occurrenceOf record]
  expect "each question names its own occurrence and epoch" $
    sort [(occurrenceOf record, aboutEpoch (recAbout record)) | (_, record) <- questions]
      == [(Just (OccurrenceId n), Just epoch) | (n, epoch) <- [(0, 0), (1, 0), (2, 0), (3, 1)]]
  expect "each question is addressed to its dispatched candidate" $
    sortOn fst [(occurrenceOf record, recTo record) | (_, record) <- questions]
      == [(Just (OccurrenceId n), To (Model ("model " <> name))) | (n, name) <- zip [0 ..] ["a", "b", "actor", "c"]]
  expect "two occurrences have their questions in flight together" $
    case [index | (index, record) <- indexed, recSchema record == FlowAnswer] of
      firstAnswer : _ -> length [() | (index, record) <- questions, index < firstAnswer, occurrenceOf record `elem` [Just (OccurrenceId 0), Just (OccurrenceId 1)]] == 2
      [] -> False
  forM_ indexed $ \(index, record) ->
    when (recSchema record `elem` [FlowEngineStart, FlowTurn]) $
      case reverse (questionFor index record) of
        question : _ -> do
          expect ("the " <> show (recSchema record) <> " at " <> show index <> " carries the scope of its question") (recAbout record == recAbout question)
          expect ("the " <> show (recSchema record) <> " at " <> show index <> " goes to the answerer of its question") (recTo record == recTo question)
        [] -> expect ("the " <> show (recSchema record) <> " at " <> show index <> " has a question") False
  forM_ indexed $ \(index, record) ->
    when (schemaRole (recSchema record) == ReplySchema) $ do
      ask <- maybe (fail ("carriage: reply " <> show index <> " names no ask")) pure (askOf record)
      expect ("the reply at " <> show index <> " carries the scope of its ask") (recAbout record == recAbout ask)
      expect ("the reply at " <> show index <> " comes from the addressee of its ask") (To (recFrom record) == recTo ask)
  expect "each question has one answer" $
    let answered = [recReplyTo record | record <- records, recSchema record == FlowAnswer]
     in length answered == 4 && length (nub answered) == 4 && not (any isNothing answered)
  physical <- readIORef requests
  unless (length physical == 4) (fail "carriage: the barrier engine did not start four conversations")

-- | The answerer of each kind of request under each target and person mode.
answererChecks :: IO ()
answererChecks = do
  let routed =
        Start
          { startRun = run,
            startProgramSha256 = T.replicate 64 "a",
            startPolicyDigest = "policy",
            startPersonAnswering = Just PersonAnswerEngine,
            startTarget = "acp:stub",
            startLineage = RootRun,
            startParent = Nothing,
            startInputs = []
          }
      scripted = routed {startTarget = "scripted"}
      local = routed {startPersonAnswering = Just PersonAnswerLocalControl}
      ask addressee = consultRequest (Q addressee (QScope (Just "opus") Nothing) "who?" 0) :: Request 'CodeFlag
      answers start addressee = requestAnswerer start intake ["row"] (ask addressee)
  expect "a model question goes to the model with its axis" (answers routed (AddrModel "writer") == Model "model writer@opus")
  expect "a person question in engine mode goes to the model" (answers routed (AddrPerson "owner") == Model "person owner@opus")
  expect "a person question under local control goes to the intake" (answers local (AddrPerson "owner") == intake)
  expect "a person question under local control and the scripted target goes to the intake" (answers scripted {startPersonAnswering = Just PersonAnswerLocalControl} (AddrPerson "owner") == intake)
  expect "an in-process tool goes to its registry row" (answers routed (AddrTool "row") == ToolActor "tool row@opus" RegistryTool)
  expect "another tool goes to the model that the runtime routed it to" (answers routed (AddrTool "other") == Model "tool other@opus")
  expect "a command goes to the command" (answers routed (AddrToolExec "gate" "make" ["check"]) == ToolActor "tool gate (make)@opus" ProgramCommand)
  expect "the scripted table answers every other question" (all ((== FixtureTool) . kindOf . answers scripted) [AddrModel "writer", AddrPerson "owner", AddrTool "row", AddrToolExec "gate" "make" []])
  where
    kindOf = \case
      ToolActor _ kind -> kind
      other -> error ("carriage: not a tool actor: " <> show other)

expect :: String -> Bool -> IO ()
expect label ok = unless ok (fail ("carriage: " <> label))
