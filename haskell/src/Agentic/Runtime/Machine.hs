{-# LANGUAGE OverloadedStrings #-}

-- | Thread-safe NDJSON writer for the runtime protocol.
module Agentic.Runtime.Machine
  ( MachineCancelled (..),
    DeferredEventSink,
    newDeferredEventSink,
    deferredEventSink,
    activateEventSink,
    eventSinkActive,
    handleEventSink,
    handlesEventSink,
    stdoutEventSink,
    withControlInput,
  )
where

import Agentic.Runtime.Control
  ( AckState (ControlFailed, Delivered),
    Control (controlId),
    ControlAck (ControlAck, acknowledgementState),
    ControlAction (..),
    ControlId (ControlId, controlIdText),
    SteeringTiming (InterruptNow, NextBoundary),
    ControlRuntime,
    ackEvent,
    decideRuntimeControl,
    decodeControl,
    deliverRuntimeAction,
  )
import Agentic.Runtime.Protocol
  ( Envelope (Envelope),
    EventSink,
    RunId,
    SeqNo (SeqNo),
    RecoveryOption (..),
    RuntimeEvent (..),
    encodeEnvelope,
    maxFrameBytes,
    protocolVersion,
  )
import Control.Concurrent (forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (Exception, finally, throwIO)
import Control.Monad (foldM, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import System.IO (Handle, hFlush, hIsEOF, stdout)

-- | Queue events until the run store and its sequenced sink exist.
data DeferredState = Deferred [RuntimeEvent] | Activated EventSink

newtype DeferredEventSink = DeferredEventSink (MVar DeferredState)

newDeferredEventSink :: IO DeferredEventSink
newDeferredEventSink = DeferredEventSink <$> newMVar (Deferred [])

deferredEventSink :: DeferredEventSink -> EventSink
deferredEventSink (DeferredEventSink state) event =
  modifyMVar_ state $ \current -> case current of
    Deferred events -> pure (Deferred (event : events))
    Activated sink -> sink event >> pure current

-- | Emit @run.started@ first, then queued controls, and forward future events.
activateEventSink :: DeferredEventSink -> EventSink -> RuntimeEvent -> IO Bool
activateEventSink (DeferredEventSink state) sink started =
  modifyMVar state $ \current -> case current of
    Activated _ -> pure (current, False)
    Deferred events -> do
      sink started
      mapM_ sink (reverse events)
      pure (Activated sink, True)

eventSinkActive :: DeferredEventSink -> IO Bool
eventSinkActive (DeferredEventSink state) = do
  current <- readMVar state
  pure $ case current of
    Activated _ -> True
    Deferred _ -> False

-- | One writer lock and one sequence supply per run.  Concurrent scheduler
-- threads may call the sink, but complete envelopes reach the handle in one
-- monotone order.
handleEventSink :: Handle -> RunId -> IO EventSink
handleEventSink handle = handlesEventSink [handle]

-- | Write each envelope to every handle in order.  Put a durable journal
-- handle before stdout so a streamed event is never ahead of its record.
handlesEventSink :: [Handle] -> RunId -> IO EventSink
handlesEventSink handles runId = do
  next <- newMVar (0 :: Word64)
  pure $ \event ->
    modifyMVar_ next $ \sequence' -> foldM writeEvent sequence' (splitOutput event)
  where
    writeEvent sequence' event = do
      when (sequence' == maxBound) (throwIO (userError "runtime protocol sequence counter exhausted"))
      when (not (eventTextFits event)) (throwIO (userError "runtime protocol event text exceeds bounded frame policy"))
      now <- T.pack . formatTime defaultTimeLocale "%FT%T%QZ" <$> getCurrentTime
      let bytes = encodeEnvelope (Envelope protocolVersion runId (SeqNo sequence') now event)
      when (BS.length bytes > maxFrameBytes) (throwIO (userError "runtime protocol event exceeds 1048576 bytes"))
      mapM_ (writeEnvelope bytes) handles
      pure (sequence' + 1)

    writeEnvelope bytes handle = do
      BS.hPut handle bytes
      BS.hPut handle "\n"
      hFlush handle

-- A JSON string can expand to six bytes per character (for example, @\u0000@).
-- One eighth of the wire limit leaves room for that expansion and the envelope.
maxEventTextChars :: Int
maxEventTextChars = maxFrameBytes `div` 8

splitOutput :: RuntimeEvent -> [RuntimeEvent]
splitOutput (AttemptOutput attempt chunk)
  | T.length chunk > maxEventTextChars = map (AttemptOutput attempt) (T.chunksOf maxEventTextChars chunk)
splitOutput event = [event]

eventTextFits :: RuntimeEvent -> Bool
eventTextFits event = go 0 (texts event)
  where
    go _ [] = True
    go total (text : rest) =
      let size = T.length text
       in size <= maxEventTextChars - total && go (total + size) rest
    texts (RunStarted workflow target) = [workflow, target]
    texts (OccurrenceStarted _ code intent addressee prompt) = [code, intent, addressee, prompt]
    texts (AttemptStarted _ target) = [target]
    texts (AttemptOutput _ chunk) = [chunk]
    texts (AttemptSteered _ control timing text) = [control, timing, text]
    texts (AttemptCompleted _ source) = [source]
    texts (AttemptFailed _ _ message) = [message]
    texts (OccurrenceReused _ group) = [group]
    texts (OccurrenceRecoveryPending _ gap message choices) = gap : message : concatMap optionTexts choices
    texts (OccurrenceRetried _ control) = [control]
    texts (OccurrenceRecoveryChosen _ control choice target) = [control, choice] <> maybe [] pure target
    texts (OccurrenceDispatchPending _ targets) = targets
    texts (OccurrenceRedirected _ control target) = [control, target]
    texts (OccurrenceCompleted _ source answer) = [source, answer]
    texts (OccurrenceFailed _ _ message) = [message]
    texts (ControlAcknowledged control state message) = [control, state, message]
    texts (TraceOrdered _) = []
    texts (RunCompleted _ _) = []
    texts (RunFailed _ message) = [message]
    texts (RunCancelled message) = [message]
    optionTexts option = recoveryChoice option : maybe [] pure (recoveryTarget option)

stdoutEventSink :: RunId -> IO EventSink
stdoutEventSink = handleEventSink stdout

newtype MachineCancelled = MachineCancelled {machineCancellationReason :: String}
  deriving (Show)

instance Exception MachineCancelled

-- | Run an action while a dedicated NDJSON control stream may cancel it.
withControlInput :: Handle -> EventSink -> ControlRuntime -> IO a -> IO a
withControlInput handle sink runtime action = do
  owner <- myThreadId
  reader <- forkIO (loop owner)
  action `finally` killThread reader
  where
    loop owner = do
      eof <- hIsEOF handle
      if eof
        then throwTo owner (MachineCancelled "control input closed")
        else do
          line <- BSC.hGetLine handle
          case decodeControl line of
            Left why -> do
              sink (ackEvent (ControlAck (ControlId "invalid") ControlFailed why))
              throwTo owner (MachineCancelled (T.unpack why))
            Right control -> do
              (ack, next) <- decideRuntimeControl runtime control
              sink (ackEvent ack)
              case next of
                Just ActCancel -> throwTo owner (MachineCancelled "cancelled by control")
                Just delivery -> do
                  delivered <- deliverRuntimeAction runtime control delivery
                  case delivery of
                    ActSteer attempt timing text
                      | acknowledgementState delivered == Delivered ->
                          sink (AttemptSteered attempt (controlIdText (controlId control)) (timingWord timing) text)
                    ActRedirect occurrence target
                      | acknowledgementState delivered == Delivered ->
                          sink (OccurrenceRedirected occurrence (controlIdText (controlId control)) target)
                    _ -> pure ()
                  sink (ackEvent delivered)
                Nothing -> pure ()
              loop owner

    timingWord InterruptNow = "interrupt-now"
    timingWord NextBoundary = "next-boundary"
