{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded NDJSON transport for runtime events and controls.
module Agentic.Runtime.Machine
  ( MachineCancelled (..),
    DeferredEventSink,
    newDeferredEventSink,
    deferredEventSink,
    activateEventSink,
    eventSinkActive,
    handleEventSink,
    handleEventSinkFor,
    handlesEventSink,
    handlesEventSinkFor,
    stdoutEventSink,
    stdoutEventSinkFor,
    withControlInput,
    withControlInputFor,
    withBufferedControlInputFor,
    readNdjsonFrame,
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
    ackEventFor,
    invalidAckEventFor,
    decideRuntimeControl,
    decodeControlFor,
    deliverRuntimeActionDeferred,
  )
import Agentic.Runtime.Protocol
  ( Envelope (Envelope),
    EventSink,
    RunId,
    SeqNo (SeqNo),
    RecoveryOption (..),
    QuestionRef (..),
    PublicProgress (..),
    PublicTodoItem (..),
    PublicToolUpdate (..),
    ResultRef (..),
    RuntimeEvent (..),
    encodeEnvelopeFor,
    latestProtocolVersion,
    maxFrameBytes,
    protocolVersion,
  )
import Control.Concurrent (forkIO, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Exception (Exception, SomeException, finally, throwIO, try)
import Control.Monad (when)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import System.IO (Handle, hFlush, stdout)

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
activateEventSink (DeferredEventSink state) sink started = do
  result <-
    modifyMVar state $ \current -> case current of
      Activated _ -> pure (current, Right False)
      Deferred events -> do
        outcome <- try @SomeException (sink started >> mapM_ sink (reverse events))
        pure (Activated sink, either Left (const (Right True)) outcome)
  either throwIO pure result

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
handleEventSink = handleEventSinkFor protocolVersion

handleEventSinkFor :: Int -> Handle -> RunId -> IO EventSink
handleEventSinkFor version handle = handlesEventSinkFor version [handle]

-- | Write each envelope to every handle in order.  Put a durable journal
-- handle before stdout so a streamed event is never ahead of its record.
handlesEventSink :: [Handle] -> RunId -> IO EventSink
handlesEventSink = handlesEventSinkFor protocolVersion

handlesEventSinkFor :: Int -> [Handle] -> RunId -> IO EventSink
handlesEventSinkFor version handles runId = do
  next <- newMVar (0 :: Word64)
  pure $ \event -> case event of
    AttemptProgress {} | version /= latestProtocolVersion -> pure ()
    _ -> mapM_ (writeEvent next) (splitOutput event)
  where
    writeEvent next event = do
      mirrorFailure <- modifyMVar next $ \sequence' -> do
        when (sequence' == maxBound) (throwIO (userError "runtime protocol sequence counter exhausted"))
        when (not (eventTextFits event)) (throwIO (userError "runtime protocol event text exceeds bounded frame policy"))
        now <- T.pack . formatTime defaultTimeLocale "%FT%T%QZ" <$> getCurrentTime
        bytes <-
          either (throwIO . userError . T.unpack) pure $
            encodeEnvelopeFor version (Envelope version runId (SeqNo sequence') now event)
        failure <- case handles of
          [] -> pure Nothing
          durable : mirrors -> do
            writeEnvelope bytes durable
            firstMirrorFailure bytes mirrors
        pure (sequence' + 1, failure)
      case mirrorFailure of
        Just exception | not (terminalEvent event) -> throwIO exception
        _ -> pure ()

    firstMirrorFailure _ [] = pure Nothing
    firstMirrorFailure bytes (handle : rest) = do
      result <- try (writeEnvelope bytes handle)
      case result of
        Left (exception :: SomeException) -> pure (Just exception)
        Right () -> firstMirrorFailure bytes rest

    writeEnvelope bytes handle = do
      BS.hPut handle bytes
      BS.hPut handle "\n"
      hFlush handle

terminalEvent :: RuntimeEvent -> Bool
terminalEvent RunCompleted {} = True
terminalEvent RunCompletedV2 {} = True
terminalEvent RunFailed {} = True
terminalEvent RunCancelled {} = True
terminalEvent _ = False

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
    texts (RunStartedV2 workflow target _) = [workflow, target]
    texts (OccurrenceStarted _ code intent addressee prompt) = [code, intent, addressee, prompt]
    texts (AttemptStarted _ target) = [target]
    texts (AttemptOutput _ chunk) = [chunk]
    texts (AttemptProgress _ progress) = progressTexts progress
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
    texts (ControlAcknowledgedV2 control state message command _ _) = [control, state, message, command]
    texts (OccurrencePersonAnswerPending _ reference) =
      [questionArtifactPath reference, questionArtifactSha256 reference]
    texts (TraceOrdered _) = []
    texts (RunCompleted _ _) = []
    texts (RunCompletedV2 _ _ reference) =
      [resultArtifactPath reference, resultArtifactSha256 reference, resultArtifactPreview reference]
    texts (RunFailed _ message) = [message]
    texts (RunCancelled message) = [message]
    optionTexts option = recoveryChoice option : maybe [] pure (recoveryTarget option)
    progressTexts (ProgressMessage text) = [text]
    progressTexts (ProgressTool tool) =
      publicToolId tool : foldMap maybeToList [publicToolTitle tool, publicToolKind tool, publicToolStatus tool, publicToolSummary tool]
    progressTexts (ProgressTodos items) = concatMap (\item -> [publicTodoContent item, publicTodoPriority item, publicTodoStatus item]) items
    progressTexts (ProgressUsage _) = []
    progressTexts (ProgressReasoningSummary text) = [text]
    maybeToList Nothing = []
    maybeToList (Just value) = [value]

stdoutEventSink :: RunId -> IO EventSink
stdoutEventSink = stdoutEventSinkFor protocolVersion

stdoutEventSinkFor :: Int -> RunId -> IO EventSink
stdoutEventSinkFor version = handleEventSinkFor version stdout

newtype MachineCancelled = MachineCancelled {machineCancellationReason :: String}
  deriving (Show)

instance Exception MachineCancelled

-- | One bounded newline-terminated frame and the bytes already read after it.
readNdjsonFrame :: Int -> T.Text -> Handle -> BS.ByteString -> IO (Either T.Text (Maybe (BS.ByteString, BS.ByteString)))
readNdjsonFrame limit label handle buffered =
  case BS.break (== 10) buffered of
    (line, rest)
      | not (BS.null rest) ->
          if BS.length line > limit
            then pure (Left oversized)
            else pure (Right (Just (line, BS.drop 1 rest)))
      | BS.length buffered > limit -> pure (Left oversized)
      | otherwise -> do
          let remaining = max 1 (min 32768 (limit + 1 - BS.length buffered))
          chunk <- BS.hGetSome handle remaining
          if BS.null chunk
            then
              if BS.null buffered
                then pure (Right Nothing)
                else pure (Left (label <> " stream ended without a terminating newline"))
            else readNdjsonFrame limit label handle (buffered <> chunk)
  where
    oversized = label <> " frame exceeds " <> T.pack (show limit) <> " bytes"

-- | Run an action while a dedicated NDJSON control stream may cancel it.
withControlInput :: Handle -> EventSink -> ControlRuntime -> IO a -> IO a
withControlInput = withControlInputFor protocolVersion

withControlInputFor :: Int -> Handle -> EventSink -> ControlRuntime -> IO a -> IO a
withControlInputFor version handle = withBufferedControlInputFor version handle BS.empty

-- | Begin controls with bytes retained from the same transport before activation.
withBufferedControlInputFor :: Int -> Handle -> BS.ByteString -> EventSink -> ControlRuntime -> IO a -> IO a
withBufferedControlInputFor version handle initial sink runtime action = do
  owner <- myThreadId
  reader <- forkIO (loop owner initial)
  action `finally` killThread reader
  where
    loop owner buffered = do
      frame <- readNdjsonFrame maxFrameBytes "runtime control" handle buffered
      case frame of
        Left why -> do
          sink (invalidAckEventFor version (ControlAck (ControlId "invalid") ControlFailed why))
          throwTo owner (MachineCancelled (T.unpack why))
        Right Nothing -> throwTo owner (MachineCancelled "control input closed")
        Right (Just (line, rest)) ->
          case decodeControlFor version line of
            Left why -> do
              sink (invalidAckEventFor version (ControlAck (ControlId "invalid") ControlFailed why))
              throwTo owner (MachineCancelled (T.unpack why))
            Right control -> do
              (ack, next) <- decideRuntimeControl runtime control
              sink (ackEventFor version control ack)
              case next of
                Just ActCancel -> throwTo owner (MachineCancelled "cancelled by control")
                Just delivery -> do
                  (delivered, afterAcknowledgement) <- deliverRuntimeActionDeferred runtime control delivery
                  case delivery of
                    ActSteer attempt timing text
                      | acknowledgementState delivered == Delivered ->
                          sink (AttemptSteered attempt (controlIdText (controlId control)) (timingWord timing) text)
                    ActRedirect occurrence target
                      | acknowledgementState delivered == Delivered ->
                          sink (OccurrenceRedirected occurrence (controlIdText (controlId control)) target)
                    _ -> pure ()
                  sink (ackEventFor version control delivered)
                  afterAcknowledgement
                Nothing -> pure ()
              loop owner rest

    timingWord InterruptNow = "interrupt-now"
    timingWord NextBoundary = "next-boundary"
