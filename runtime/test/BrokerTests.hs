{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module BrokerTests (brokerTests) where

import qualified Agentic.Engine as Engine
import Agentic.Plan
import Agentic.Planning (Addressee (AddrModel, AddrToolExec), Code (CodeAck, CodeFlag, CodeText), billExecFresh, billMemo)
import Agentic.Runtime
import Control.Exception (IOException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (Value (Bool))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T

-- The original engine owns its lane and receives actual requests and steering.
data ProbeEngine = ProbeEngine TurnLane (IORef [Engine.EngineRequest]) (IORef [Text])

instance Engine.Engine ProbeEngine where
  startEngine (ProbeEngine _ requests steering) context request = do
    append requests request
    pure . Engine.EngineConversation $ \_ ->
      Engine.runEngineAttempt context (Just (\_ text -> append steering text >> pure (Right ())))
        (Engine.engineTarget request) $ \updates -> do
          updates (Engine.EnginePublicMessage "native progress")
          updates (Engine.EngineAnswerChunk "native bytes")
          pure (Engine.EngineResult "yes" "fixture narration" Engine.Completed)
  engineTurnLane (ProbeEngine lane _ _) = Just lane

flagRequest :: Request 'CodeFlag
flagRequest = consultRequest (Q (AddrModel "broker") scopeUnit "approve?" 0)

actRequest :: Request 'CodeAck
actRequest = effectRequest (Q (AddrModel "broker") scopeUnit "perform" 0)

plan :: Plan '[] Bool
plan = PAskC SFlag flagRequest (PAskC SFlag flagRequest (PAskC SAck actRequest (PRet (exprVar (VThere VHere)))))

-- | The same reusable question on both sides of one effect, so it has epoch 0
-- before the effect and epoch 1 after it.
epochPlan :: Plan '[] Bool
epochPlan = PAskC SFlag flagRequest (PAskC SAck actRequest (PAskC SFlag flagRequest (PRet (exprVar VHere))))

brokerTests :: IO ()
brokerTests = do
  checkDelivery False
  checkDelivery True
  checkUncertainReply
  checkEpochDelivery
  checkShellLogDelivery

checkDelivery :: Bool -> IO ()
checkDelivery injected = do
  calls <- newIORef ([] :: [Text])
  requests <- newIORef []
  steering <- newIORef []
  events <- newIORef []
  stored <- newIORef []
  lane <- newTurnLaneIO
  controls <- newControlRuntimeFor correlatedProtocolVersion
  let note = append calls
      broker = if not injected then inProcessBroker else inProcessBroker
        { brokerRequest = \receive code request -> note "request" >> receive code request,
          brokerStart = \engine context request -> note "start" >> Engine.startEngine engine context request,
          brokerTurn = \conversation extra -> do
            note "turn"
            response <- Engine.runEngineTurn conversation extra
            -- Deliberately change a fixture reply to distinguish real delivery
            -- from a copied observation. This is not an identity transport.
            pure response {Engine.engineAnswer = "no"},
          brokerUpdate = \receive update -> do
            note "update"
            receive $ case update of
              Engine.EnginePublicMessage _ -> Engine.EnginePublicMessage "broker progress"
              _ -> update,
          brokerSteer = \receive timing text -> note "steer" >> receive timing ("broker:" <> text),
          brokerEvent = \receive event -> note "event" >> receive event,
          brokerLog = \receive text -> note "log" >> receive text,
          brokerPersistence = \hooks -> hooks
            { persistenceStoreAnswer = \occurrence epoch question answer reusable ->
                note "answer" >> persistenceStoreAnswer hooks occurrence epoch question answer reusable,
              persistenceStartEffect = \occurrence question ->
                note "effect-start" >> persistenceStartEffect hooks occurrence question,
              persistenceCompleteEffect = \occurrence question answer ->
                note "effect-complete" >> persistenceCompleteEffect hooks occurrence question answer,
              persistenceCheckpoint = \occurrence -> note "checkpoint" >> persistenceCheckpoint hooks occurrence
            }
        }
      persistence = nullPersistenceHooks
        { persistenceStoreAnswer = \_ _ _ answer _ -> append stored answer }
      observe event = do
        append events event
        case event of
          AttemptStarted attempt@(AttemptId occurrence _) _ | occurrence == OccurrenceId 2 -> do
            let control = Control (ControlId ("steer-" <> T.pack (show (occurrenceNumber occurrence))))
                  (Just occurrence) (Just attempt) (Steer NextBoundary "focus")
            (ack, action) <- decideRuntimeControl controls control
            expect "control accepts original attempt" (acknowledgementState ack == Accepted)
            case action of
              Nothing -> fail "broker test: accepted steering has no delivery"
              Just delivery -> do
                (delivered, release) <- deliverRuntimeActionDeferred controls control delivery
                expect "steering reaches original engine" (acknowledgementState delivered == Delivered)
                release
          _ -> pure ()
      world = worldOfEngineWith defaultExecSettings {esLog = const (pure ())} (ProbeEngine lane requests steering)
  (answer, trace) <- runPlanBrokered broker (Just controls) persistence observe noChains world plan
  let expected = not injected
  expect "broker reply becomes typed result" (answer == expected)
  expect "authored trace and reuse survive broker delivery" $ case trace of
    [ExecEvent SFlag first (AnswerAsked firstSource) a, ExecEvent SFlag second AnswerReused b, ExecEvent SAck third (AnswerAsked thirdSource) ()] ->
      first == flagRequest && firstSource == reqQuestion flagRequest && a == expected
        && second == flagRequest && b == expected && third == actRequest && thirdSource == reqQuestion actRequest
    _ -> False
  expect "exact bills survive broker delivery" ((billExecFresh trace, billMemo trace) == (3, 2))
  physical <- readIORef requests
  expect "actual addressed requests reach engine once each" $
    map Engine.engineIntent physical == [Engine.Consult, Engine.Effect]
      && all ((== "model broker") . Engine.engineTarget) physical
  receivedSteering <- readIORef steering
  expect "steering traverses broker before original engine" (receivedSteering == [if injected then "broker:focus" else "focus"])
  actualStored <- readIORef stored
  expect "persistence receives consumed typed answer" (actualStored == [Bool expected])
  actualEvents <- readIORef events
  let progress = [text | AttemptProgress _ (ProgressMessage text) <- actualEvents]
  expect "runtime consumes broker-delivered progress" (progress == replicate 2 (if injected then "broker progress" else "native progress"))
  actualCalls <- readIORef calls
  let count name = length (filter (== name) actualCalls)
  unless (not injected) $ do
    expect "broker mediates requests and replies rather than observing copies" (all ((== 2) . count) ["request", "start", "turn"] && count "steer" == 1)
    expect "broker mediates actual events and logs" (count "event" == length actualEvents && count "update" == 4 && count "log" == 2)
    expect "broker mediates persistence" (all ((== 1) . count) ["answer", "effect-start", "effect-complete"] && count "checkpoint" == 3)

checkUncertainReply :: IO ()
checkUncertainReply = do
  requests <- newIORef []
  steering <- newIORef []
  effects <- newIORef []
  lane <- newTurnLaneIO
  let broker = inProcessBroker {brokerTurn = \conversation extra -> do
        _ <- Engine.runEngineTurn conversation extra
        ioError (userError "broker response lost")}
      persistence = nullPersistenceHooks
        { persistenceStartEffect = \_ _ -> append effects ("started" :: Text),
          persistenceCompleteEffect = \_ _ _ -> append effects "completed"
        }
  result <- try @IOException $
    runPlanBrokered broker Nothing persistence nullEventSink noChains
      (worldOfEngine (ProbeEngine lane requests steering)) (askC1 SAck actRequest)
  expect "uncertain broker reply remains failure" $ case result of
    Left failure -> "broker response lost" `T.isInfixOf` T.pack (displayException failure)
    Right _ -> False
  actualRequests <- readIORef requests
  actualEffects <- readIORef effects
  expect "uncertain effect reply is neither replayed nor marked complete" (length actualRequests == 1 && actualEffects == ["started"])

-- | A broker that wraps the reusable-answer hooks must deliver the epoch
-- unchanged. The identity broker and a forwarding wrapper satisfy the check. A
-- wrapper that rewrites every epoch to 0 is the negative control: the check
-- must report each consequence of the rewrite.
checkEpochDelivery :: IO ()
checkEpochDelivery = do
  identity <- epochViolations inProcessBroker
  expect ("identity broker delivers the epoch unchanged: " <> show identity) (null identity)
  forwarded <- epochViolations (epochWrapper id)
  expect ("wrapping broker delivers the epoch unchanged: " <> show forwarded) (null forwarded)
  rewritten <- epochViolations (epochWrapper (const 0))
  expect ("epoch check detects a broker that rewrites every epoch to 0: " <> show rewritten) $
    rewritten == [lookupEpochs, storedEpochs, askedAgain, notReused]

-- | Wrap both reusable-answer hooks and pass each epoch through @deliver@.
epochWrapper :: (Int -> Int) -> DataBroker
epochWrapper deliver =
  inProcessBroker
    { brokerPersistence = \hooks -> hooks
        { persistenceLookupAnswer = \epoch question ->
            persistenceLookupAnswer hooks (deliver epoch) question,
          persistenceStoreAnswer = \occurrence epoch question answer reusable ->
            persistenceStoreAnswer hooks occurrence (deliver epoch) question answer reusable
        }
    }

lookupEpochs, storedEpochs, askedAgain, notReused :: String
lookupEpochs = "lookups carry the epochs [0, 1]"
storedEpochs = "stored answers carry the epochs [0, 1]"
askedAgain = "the question after the effect reaches the engine again"
notReused = "no answer crosses the effect"

-- | Run 'epochPlan' over a durable answer store keyed by epoch and bare
-- question, and name every epoch obligation that the broker violated.
epochViolations :: DataBroker -> IO [String]
epochViolations broker = do
  requests <- newIORef []
  steering <- newIORef []
  rows <- newIORef ([] :: [((Int, Value), Value)])
  looked <- newIORef []
  stored <- newIORef []
  lane <- newTurnLaneIO
  let persistence = nullPersistenceHooks
        { persistenceLookupAnswer = \epoch question -> do
            append looked epoch
            found <- lookup (epoch, question) <$> readIORef rows
            pure ((\answer -> (answer, "epoch store")) <$> found),
          persistenceStoreAnswer = \_ epoch question answer _ -> do
            append stored epoch
            append rows ((epoch, question), answer)
        }
      world = worldOfEngineWith defaultExecSettings {esLog = const (pure ())} (ProbeEngine lane requests steering)
  (answer, trace) <- runPlanBrokered broker Nothing persistence nullEventSink noChains world epochPlan
  expect "epoch plan returns the engine answer" answer
  actualLooked <- readIORef looked
  actualStored <- readIORef stored
  physical <- readIORef requests
  let asked = case trace of
        [ExecEvent SFlag _ (AnswerAsked _) _, ExecEvent SAck _ (AnswerAsked _) (), ExecEvent SFlag _ (AnswerAsked _) _] -> True
        _ -> False
  pure
    [ name
      | (name, holds) <-
          [ (lookupEpochs, actualLooked == [0, 1]),
            (storedEpochs, actualStored == [0, 1]),
            (askedAgain, map Engine.engineIntent physical == [Engine.Consult, Engine.Effect, Engine.Consult]),
            (notReused, asked)
          ],
        not holds
    ]

-- | The command log of a shell tool reaches its receiver through 'brokerLog'
-- of the broker that runs the plan. The runtime attempt path applies that
-- broker to the log that the shell configuration names.
checkShellLogDelivery :: IO ()
checkShellLogDelivery = do
  received <- newIORef ([] :: [Text])
  let broker = inProcessBroker {brokerLog = \receive text -> receive ("broker: " <> text)}
      config = defaultShellConfig {shellLog = append received}
      shellRequest :: Request 'CodeText
      shellRequest = consultRequest (Q (AddrToolExec "copy" "cat" []) scopeUnit "shell bytes" 0)
      noEngine = concurrentWorld $ \_ _ -> ioError (userError "broker test: no engine answers a shell tool")
  (answer, _) <-
    runPlanBrokered broker Nothing nullPersistenceHooks nullEventSink noChains
      (executingWorld config noEngine) (askC1 SText shellRequest)
  expect "shell tool answer is the command output" (answer == "shell bytes")
  logs <- readIORef received
  expect ("shell command log crosses brokerLog: " <> show logs) $
    map (T.isPrefixOf "broker: run cat ") logs == [True]

append :: IORef [a] -> a -> IO ()
append ref value = atomicModifyIORef' ref (\values -> (values <> [value], ()))

expect :: String -> Bool -> IO ()
expect name condition = unless condition (fail ("broker test: " <> name))
