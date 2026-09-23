{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

module BrokerTests (brokerTests) where

import qualified Agentic.Engine as Engine
import Agentic.Plan
import Agentic.Planning (Addressee (AddrModel), Code (CodeAck, CodeFlag), billExecFresh, billMemo)
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

brokerTests :: IO ()
brokerTests = do
  checkDelivery False
  checkDelivery True
  checkUncertainReply

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
            { persistenceStoreAnswer = \occurrence question answer reusable ->
                note "answer" >> persistenceStoreAnswer hooks occurrence question answer reusable,
              persistenceStartEffect = \occurrence question ->
                note "effect-start" >> persistenceStartEffect hooks occurrence question,
              persistenceCompleteEffect = \occurrence question answer ->
                note "effect-complete" >> persistenceCompleteEffect hooks occurrence question answer,
              persistenceCheckpoint = \occurrence -> note "checkpoint" >> persistenceCheckpoint hooks occurrence
            }
        }
      persistence = nullPersistenceHooks
        { persistenceStoreAnswer = \_ _ answer _ -> append stored answer }
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

append :: IORef [a] -> a -> IO ()
append ref value = atomicModifyIORef' ref (\values -> (values <> [value], ()))

expect :: String -> Bool -> IO ()
expect name condition = unless condition (fail ("broker test: " <> name))
