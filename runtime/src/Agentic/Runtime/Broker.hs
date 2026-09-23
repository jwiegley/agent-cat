{-# LANGUAGE RankNTypes #-}

-- | Typed request/reply relations and ordered data delivery for a runtime.
--
-- The default broker is the identity transport on the existing payloads and
-- outcomes. For matched inputs and engine observations, replacing the direct
-- delivery operations with 'inProcessBroker' must preserve the runtime result,
-- authored trace and bills. This is a realization obligation, not a new workflow
-- interpretation or a claim of exactly-once external effects.
module Agentic.Runtime.Broker
  ( DataBroker (..),
    inProcessBroker,
    PersistenceHooks (..),
    nullPersistenceHooks,
  )
where

import Agentic.Engine
  ( Engine (startEngine),
    EngineContext,
    EngineConversation (runEngineTurn),
    EngineRequest,
    EngineResult,
    EngineSteerer,
    EngineUpdate,
    EngineUpdateSink,
  )
import Agentic.Plan (El, Request, SCode)
import Agentic.Runtime.Control (Control)
import Agentic.Runtime.Protocol
  ( EventSink,
    OccurrenceId,
    QuestionRef,
    ResultRef,
    RuntimeEvent,
  )
import Data.Aeson (Value)
import Data.Text (Text)

-- | A family of typed delivery operations, with replies correlated by the
-- original invocation. Receivers, engines, conversations and steerers are
-- borrowed local capabilities, not serializable addresses or resumable owners.
-- Request payloads contain the destination selected by runtime policy.
--
-- Each successful delivery returns the actual receiver outcome. The broker
-- does not decode engine bytes, choose recovery, grant approval or recalculate
-- bills. Runtime reserves the original lanes before delivery. Calls on distinct
-- lanes may overlap, and a broker must preserve the established causal order.
--
-- A broker must preserve the existing bounds and failure distinctions, stop
-- using borrowed capabilities before their scope ends, and propagate uncertain
-- publication without replaying it. Return from a publication is only that
-- operation's acknowledgement, not evidence of worker exit or resource cleanup.
-- External implementations must carry data through their own correlated
-- sessions rather than serialize these local capabilities or adopt IDs as owners.
-- Public events and private diagnostic/narration receivers remain distinct.
data DataBroker = DataBroker
  { brokerRequest :: forall c. (SCode c -> Request c -> IO (El c)) -> SCode c -> Request c -> IO (El c),
    brokerStart :: forall engine. Engine engine => engine -> EngineContext -> EngineRequest -> IO EngineConversation,
    brokerTurn :: EngineConversation -> Text -> IO EngineResult,
    brokerUpdate :: EngineUpdateSink -> EngineUpdate -> IO (),
    brokerSteer :: EngineSteerer -> EngineSteerer,
    -- The receiver returns whether its original input loop may read another
    -- frame. In particular, cancellation must not be replaced by a later EOF.
    brokerControl :: (Control -> IO Bool) -> Control -> IO Bool,
    brokerEvent :: EventSink -> RuntimeEvent -> IO (),
    brokerLog :: (Text -> IO ()) -> Text -> IO (),
    brokerPersistence :: PersistenceHooks -> PersistenceHooks
  }

-- | The identity transport, using the existing in-process receivers and their
-- original owners. No extra queue, worker, retry or acknowledgement is added.
-- All returned responses are consumed by runtime rather than copied to observers.
inProcessBroker :: DataBroker
inProcessBroker =
  DataBroker
    { brokerRequest = \receive code request -> receive code request,
      brokerStart = startEngine,
      brokerTurn = runEngineTurn,
      brokerUpdate = ($),
      brokerSteer = id,
      brokerControl = ($),
      brokerEvent = ($),
      brokerLog = ($),
      brokerPersistence = id
    }

-- | Existing durable data operations, loaned by the original run-store owner.
-- Workflow interpretation and the decision to invoke each operation remain in
-- runtime. A broker may replace delivery, never infer permission to replay it.
data PersistenceHooks = PersistenceHooks
  { persistenceLookupAnswer :: Value -> IO (Maybe (Value, Text)),
    persistenceStoreAnswer :: OccurrenceId -> Value -> Value -> Bool -> IO (),
    persistenceStartEffect :: OccurrenceId -> Value -> IO (),
    persistenceCompleteEffect :: OccurrenceId -> Value -> Value -> IO (),
    persistenceStoreQuestion :: OccurrenceId -> Text -> Value -> IO (Maybe QuestionRef),
    persistenceCheckpoint :: OccurrenceId -> IO (),
    persistenceStoreResult :: Value -> Value -> Text -> IO ResultRef
  }

nullPersistenceHooks :: PersistenceHooks
nullPersistenceHooks =
  PersistenceHooks
    { persistenceLookupAnswer = const (pure Nothing),
      persistenceStoreAnswer = \_ _ _ _ -> pure (),
      persistenceStartEffect = \_ _ -> pure (),
      persistenceCompleteEffect = \_ _ _ -> pure (),
      persistenceStoreQuestion = \_ _ _ -> pure Nothing,
      persistenceCheckpoint = const (pure ()),
      persistenceStoreResult = \_ _ _ ->
        ioError (userError "protocol version 2 lost its required run store")
    }
