{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Agentic.Runtime.Control
  ( ControlId (..),
    SteeringTiming (..),
    RecoveryControl (..),
    ControlCommand (..),
    Control (..),
    AckState (..),
    ControlAck (..),
    ControlCapabilities (..),
    ControlSnapshot (..),
    ControlAction (..),
    ControlRuntime,
    AttemptSteerer,
    newControlRuntime,
    registerControlAttempt,
    unregisterControlAttempt,
    waitForRuntimeRecovery,
    registerRuntimeRedirects,
    awaitRuntimeRedirect,
    controlRuntimeSnapshot,
    runtimeOccurrenceReplayable,
    decideRuntimeControl,
    deliverRuntimeAction,
    emptyControlSnapshot,
    decideControl,
    ackEvent,
    encodeControl,
    decodeControl,
  )
where

import Agentic.Runtime.Protocol (AttemptId (..), OccurrenceId (..), RuntimeEvent (ControlAcknowledged), maxFrameBytes)
import Control.Concurrent.MVar
  ( MVar,
    modifyMVar,
    modifyMVar_,
    newEmptyMVar,
    newMVar,
    readMVar,
    takeMVar,
    tryPutMVar,
  )
import Control.Exception (SomeException, displayException, finally, try)
import Control.Monad (when)
import System.Timeout (timeout)
import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word (Word32, Word64)

newtype ControlId = ControlId {controlIdText :: Text}
  deriving (Eq, Ord, Show)

data SteeringTiming = InterruptNow | NextBoundary
  deriving (Eq, Ord, Show)

data RecoveryControl = RecoveryRetry | RecoveryFailOver | RecoveryAbandon
  deriving (Eq, Ord, Show)

data ControlCommand
  = CancelRun
  | Steer !SteeringTiming !Text
  | RetryOccurrence
  | ChooseRecovery !RecoveryControl
  | RedirectOccurrence !Text
  deriving (Eq, Show)

data Control = Control
  { controlId :: !ControlId,
    expectedOccurrence :: !(Maybe OccurrenceId),
    expectedAttempt :: !(Maybe AttemptId),
    controlCommand :: !ControlCommand
  }
  deriving (Eq, Show)

data AckState = Accepted | Queued | Delivered | RejectedStale | Unsupported | ControlFailed
  deriving (Eq, Ord, Show)

data ControlAck = ControlAck
  { acknowledgedControl :: !ControlId,
    acknowledgementState :: !AckState,
    acknowledgementMessage :: !Text
  }
  deriving (Eq, Show)

data ControlCapabilities = ControlCapabilities
  { canSteer :: !Bool,
    canRetry :: !Bool,
    canRedirect :: !Bool
  }
  deriving (Eq, Show)

data ControlSnapshot = ControlSnapshot
  { controlTerminal :: !Bool,
    controlCancelling :: !Bool,
    activeAttempts :: ![AttemptId],
    recoverableOccurrences :: ![OccurrenceId],
    recoveryOptions :: !(Map OccurrenceId [RecoveryControl]),
    reservedRedirects :: !(Map OccurrenceId [Text])
  }
  deriving (Eq, Show)

data ControlAction
  = ActCancel
  | ActSteer !AttemptId !SteeringTiming !Text
  | ActRecover !OccurrenceId !RecoveryControl
  | ActRedirect !OccurrenceId !Text
  deriving (Eq, Show)

type AttemptSteerer = SteeringTiming -> Text -> IO (Either Text ())

data LiveControlState = LiveControlState
  { liveSnapshot :: !ControlSnapshot,
    liveSteerers :: !(Map AttemptId (Maybe AttemptSteerer)),
    liveRetries :: !(Map OccurrenceId (MVar (ControlId, RecoveryControl))),
    liveRedirects :: !(Map OccurrenceId (MVar Text)),
    liveNonReplayable :: !(Map OccurrenceId ()),
    liveAcks :: !(Map ControlId ControlAck)
  }

newtype ControlRuntime = ControlRuntime (MVar LiveControlState)

newControlRuntime :: IO ControlRuntime
newControlRuntime = ControlRuntime <$> newMVar (LiveControlState emptyControlSnapshot Map.empty Map.empty Map.empty Map.empty Map.empty)

registerControlAttempt :: ControlRuntime -> AttemptId -> Maybe AttemptSteerer -> IO ()
registerControlAttempt (ControlRuntime state) attempt steerer =
  modifyMVar_ state $ \live ->
    pure
      live
        { liveSnapshot = (liveSnapshot live) {activeAttempts = activeAttempts (liveSnapshot live) <> [attempt]},
          liveSteerers = Map.insert attempt steerer (liveSteerers live)
        }

unregisterControlAttempt :: ControlRuntime -> AttemptId -> IO ()
unregisterControlAttempt (ControlRuntime state) attempt =
  modifyMVar_ state $ \live ->
    pure
      live
        { liveSnapshot = (liveSnapshot live) {activeAttempts = filter (/= attempt) (activeAttempts (liveSnapshot live))},
          liveSteerers = Map.delete attempt (liveSteerers live)
        }

waitForRuntimeRecovery :: ControlRuntime -> OccurrenceId -> [RecoveryControl] -> IO () -> IO (ControlId, RecoveryControl)
waitForRuntimeRecovery (ControlRuntime state) occurrence offered ready = do
  gate <- newEmptyMVar
  modifyMVar_ state $ \live ->
    pure
      live
        { liveSnapshot =
            (liveSnapshot live)
              { recoverableOccurrences = occurrence : filter (/= occurrence) (recoverableOccurrences (liveSnapshot live)),
                recoveryOptions = Map.insert occurrence offered (recoveryOptions (liveSnapshot live))
              },
          liveRetries = Map.insert occurrence gate (liveRetries live)
        }
  ready
  retryId <-
    takeMVar gate `finally`
      modifyMVar_ state
        ( \live ->
            pure
              live
                { liveSnapshot =
                    (liveSnapshot live)
                      { recoverableOccurrences = filter (/= occurrence) (recoverableOccurrences (liveSnapshot live)),
                        recoveryOptions = Map.delete occurrence (recoveryOptions (liveSnapshot live))
                      },
                  liveRetries = Map.delete occurrence (liveRetries live)
                }
        )
  pure retryId

registerRuntimeRedirects :: ControlRuntime -> OccurrenceId -> [Text] -> IO ()
registerRuntimeRedirects (ControlRuntime state) occurrence targets = do
  gate <- newEmptyMVar
  modifyMVar_ state $ \live ->
    pure
      live
        { liveSnapshot =
            (liveSnapshot live)
              { reservedRedirects = Map.insert occurrence targets (reservedRedirects (liveSnapshot live))
              },
          liveRedirects = Map.insert occurrence gate (liveRedirects live)
        }

awaitRuntimeRedirect :: ControlRuntime -> OccurrenceId -> IO (Maybe Text)
awaitRuntimeRedirect (ControlRuntime state) occurrence = do
  gate <- Map.lookup occurrence . liveRedirects <$> readMVar state
  case gate of
    Nothing -> pure Nothing
    Just pending ->
      -- A human-visible bounded decision window; no attempt exists during it.
      timeout (30 * 1000 * 1000) (takeMVar pending) `finally`
        modifyMVar_ state
          ( \live ->
              pure
                live
                  { liveSnapshot =
                      (liveSnapshot live)
                        { reservedRedirects = Map.delete occurrence (reservedRedirects (liveSnapshot live))
                        },
                    liveRedirects = Map.delete occurrence (liveRedirects live)
                  }
          )

runtimeOccurrenceReplayable :: ControlRuntime -> OccurrenceId -> IO Bool
runtimeOccurrenceReplayable (ControlRuntime state) occurrence =
  Map.notMember occurrence . liveNonReplayable <$> readMVar state

controlRuntimeSnapshot :: ControlRuntime -> IO ControlSnapshot
controlRuntimeSnapshot (ControlRuntime state) = liveSnapshot <$> readMVar state

decideRuntimeControl :: ControlRuntime -> Control -> IO (ControlAck, Maybe ControlAction)
decideRuntimeControl (ControlRuntime state) control =
  modifyMVar state $ \live -> case Map.lookup (controlId control) (liveAcks live) of
    Just prior -> pure (live, (prior, Nothing))
    Nothing -> do
      let steerable = expectedAttempt control >>= (`Map.lookup` liveSteerers live) >>= id
          retryable = maybe False (`Map.member` liveRetries live) (expectedOccurrence control)
          redirectable = maybe False (`Map.member` liveRedirects live) (expectedOccurrence control)
          capabilities = ControlCapabilities (isJust steerable) retryable redirectable
          (snapshot', ack, action) = decideControl capabilities (liveSnapshot live) control
          next = live {liveSnapshot = snapshot', liveAcks = Map.insert (controlId control) ack (liveAcks live)}
      pure (next, (ack, action))

deliverRuntimeAction :: ControlRuntime -> Control -> ControlAction -> IO ControlAck
deliverRuntimeAction runtime@(ControlRuntime state) control action = do
  ack <- case action of
    ActSteer attempt timing text -> do
      handler <- Map.lookup attempt . liveSteerers <$> readMVar state
      case joinMaybe handler of
        Nothing -> pure (ControlAck cid Unsupported "active target no longer supports steering")
        Just steer -> do
          outcome <- tryDelivery (steer timing text)
          pure $ case outcome of
            Left failure -> ControlAck cid ControlFailed (T.pack (displayException failure))
            Right (Left why) -> ControlAck cid ControlFailed why
            Right (Right ()) -> ControlAck cid Delivered "steer delivered to active attempt"
    ActRecover occurrence recovery -> do
      gate <- Map.lookup occurrence . liveRetries <$> readMVar state
      case gate of
        Nothing -> pure (ControlAck cid RejectedStale "occurrence is no longer waiting for recovery")
        Just retry -> do
          delivered <- tryPutMVar retry (cid, recovery)
          pure $
            if delivered
              then ControlAck cid Delivered "recovery choice delivered to recoverable occurrence"
              else ControlAck cid ControlFailed "recovery choice was already delivered"
    ActRedirect occurrence target -> do
      gate <- Map.lookup occurrence . liveRedirects <$> readMVar state
      case gate of
        Nothing -> pure (ControlAck cid RejectedStale "occurrence is no longer waiting for redirect")
        Just redirect -> do
          delivered <- tryPutMVar redirect target
          pure $
            if delivered
              then ControlAck cid Delivered "redirect delivered before attempt dispatch"
              else ControlAck cid ControlFailed "redirect was already delivered"
    ActCancel -> pure (ControlAck cid Unsupported "cancellation delivery belongs to the machine owner")
  when (acknowledgementState ack == Delivered) $ case action of
    ActSteer attempt _ _ ->
      modifyMVar_ state $ \live ->
        pure live {liveNonReplayable = Map.insert (attemptOccurrence attempt) () (liveNonReplayable live)}
    _ -> pure ()
  recordAck runtime ack
  pure ack
  where
    cid = controlId control

recordAck :: ControlRuntime -> ControlAck -> IO ()
recordAck (ControlRuntime state) ack =
  modifyMVar_ state $ \live -> pure live {liveAcks = Map.insert (acknowledgedControl ack) ack (liveAcks live)}

tryDelivery :: IO a -> IO (Either SomeException a)
tryDelivery = try

joinMaybe :: Maybe (Maybe a) -> Maybe a
joinMaybe (Just value) = value
joinMaybe Nothing = Nothing

emptyControlSnapshot :: ControlSnapshot
emptyControlSnapshot = ControlSnapshot False False [] [] Map.empty Map.empty
-- | Pure stale/capability/scheduler-boundary policy.  Delivery is performed by
-- the runtime after this decision and receives a later acknowledgement.
decideControl :: ControlCapabilities -> ControlSnapshot -> Control -> (ControlSnapshot, ControlAck, Maybe ControlAction)
decideControl capabilities snapshot control = case controlCommand control of
  CancelRun
    | controlTerminal snapshot -> reject "run is already terminal"
    | controlCancelling snapshot -> accept snapshot "run is already cancelling" Nothing
    | otherwise ->
        accept snapshot {controlCancelling = True} "cancellation accepted" (Just ActCancel)
  Steer timing text -> withAttempt $ \attempt ->
    if canSteer capabilities
      then accept snapshot "steer accepted for active attempt" (Just (ActSteer attempt timing text))
      else unsupported "active target does not support steering"
  RetryOccurrence -> recover RecoveryRetry
  ChooseRecovery recovery -> recover recovery
  RedirectOccurrence target -> withOccurrence $ \occurrence ->
    if any ((== occurrence) . attemptOccurrence) (activeAttempts snapshot)
      then reject "redirect is allowed only before an attempt is dispatched"
      else
        if target `notElem` Map.findWithDefault [] occurrence (reservedRedirects snapshot)
          then reject "redirect target was not reserved by the scheduler"
          else
            if canRedirect capabilities
              then accept snapshot "redirect accepted" (Just (ActRedirect occurrence target))
              else unsupported "runtime does not support redirect"
  where
    cid = controlId control
    ack state message = ControlAck cid state message
    accept next message action = (next, ack Accepted message, action)
    reject message = (snapshot, ack RejectedStale message, Nothing)
    unsupported message = (snapshot, ack Unsupported message, Nothing)
    recover recovery = withOccurrence $ \occurrence ->
      case Map.lookup occurrence (recoveryOptions snapshot) of
        Nothing -> reject "occurrence is not waiting for recovery"
        Just offered
          | recovery `notElem` offered -> reject "recovery choice was not offered"
          | canRetry capabilities -> accept snapshot "recovery choice accepted" (Just (ActRecover occurrence recovery))
          | otherwise -> unsupported "runtime does not support interactive recovery"
    withOccurrence k = case expectedOccurrence control of
      Nothing -> reject "control requires expectedOccurrenceId"
      Just occurrence -> k occurrence
    withAttempt k = case expectedAttempt control of
      Nothing -> reject "control requires expectedAttemptId"
      Just attempt
        | Just occurrence <- expectedOccurrence control,
          occurrence /= attemptOccurrence attempt -> reject "attempt does not belong to expected occurrence"
        | attempt `notElem` activeAttempts snapshot -> reject "attempt is stale or no longer active"
        | otherwise -> k attempt

ackEvent :: ControlAck -> RuntimeEvent
ackEvent ack =
  ControlAcknowledged
    (controlIdText (acknowledgedControl ack))
    (ackStateText (acknowledgementState ack))
    (acknowledgementMessage ack)

encodeControl :: Control -> ByteString
encodeControl = BL.toStrict . encode

decodeControl :: ByteString -> Either Text Control
decodeControl bytes
  | BS.length bytes > maxFrameBytes = Left "runtime control frame exceeds 1048576 bytes"
  | otherwise = either (Left . T.pack) Right (eitherDecodeStrict' bytes)

instance ToJSON Control where
  toJSON control =
    object
      [ "controlId" .= controlIdText (controlId control),
        "expectedOccurrenceId" .= fmap occurrenceText (expectedOccurrence control),
        "expectedAttemptId" .= fmap attemptValue (expectedAttempt control),
        "command" .= commandValue (controlCommand control)
      ]

instance FromJSON Control where
  parseJSON = withObject "runtime control" $ \o -> do
    cid <- ControlId <$> (o .: "controlId" >>= validId)
    occurrence <- traverse (parseOccurrence "expectedOccurrenceId") =<< o .:? "expectedOccurrenceId"
    attempt <- traverse parseAttempt =<< o .:? "expectedAttemptId"
    command <- o .: "command" >>= parseCommand
    pure (Control cid occurrence attempt command)

commandValue :: ControlCommand -> Value
commandValue = \case
  CancelRun -> object ["type" .= ("cancelRun" :: Text)]
  Steer timing text -> object ["type" .= ("steerOccurrence" :: Text), "timing" .= timingText timing, "text" .= text]
  RetryOccurrence -> object ["type" .= ("retryOccurrence" :: Text)]
  ChooseRecovery RecoveryRetry -> object ["type" .= ("retryOccurrence" :: Text)]
  ChooseRecovery RecoveryFailOver -> object ["type" .= ("failoverOccurrence" :: Text)]
  ChooseRecovery RecoveryAbandon -> object ["type" .= ("abandonOccurrence" :: Text)]
  RedirectOccurrence target -> object ["type" .= ("redirectOccurrence" :: Text), "target" .= target]

parseCommand :: Value -> Parser ControlCommand
parseCommand = withObject "runtime control command" $ \o -> do
  command <- o .: "type" :: Parser Text
  case command of
    "cancelRun" -> pure CancelRun
    "steerOccurrence" -> Steer <$> (o .: "timing" >>= parseTiming) <*> o .: "text"
    "retryOccurrence" -> pure RetryOccurrence
    "failoverOccurrence" -> pure (ChooseRecovery RecoveryFailOver)
    "abandonOccurrence" -> pure (ChooseRecovery RecoveryAbandon)
    "redirectOccurrence" -> RedirectOccurrence <$> o .: "target"
    _ -> fail ("unknown runtime control command " <> T.unpack command)

attemptValue :: AttemptId -> Value
attemptValue attempt =
  object
    [ "occurrenceId" .= occurrenceText (attemptOccurrence attempt),
      "attemptNumber" .= wordText (fromIntegral (attemptNumber attempt))
    ]

parseAttempt :: Value -> Parser AttemptId
parseAttempt = withObject "runtime attempt id" $ \o ->
  AttemptId
    <$> (o .: "occurrenceId" >>= parseOccurrence "attempt occurrenceId")
    <*> (o .: "attemptNumber" >>= parseAttemptNumber)

parseAttemptNumber :: Text -> Parser Word32
parseAttemptNumber text = do
  n <- parseNatural "attemptNumber" text
  if n <= toInteger (maxBound :: Word32)
    then pure (fromInteger n)
    else fail "runtime control attemptNumber exceeds Word32"

parseOccurrence :: String -> Text -> Parser OccurrenceId
parseOccurrence label text = do
  n <- parseNatural label text
  if n <= toInteger (maxBound :: Word64)
    then pure (OccurrenceId (fromInteger n))
    else fail ("runtime control " <> label <> " exceeds Word64")

parseNatural :: String -> Text -> Parser Integer
parseNatural label text = case TR.decimal text of
  Right (n, rest) | T.null rest -> pure n
  _ -> fail ("runtime control " <> label <> " is not an unsigned decimal string")

validId :: Text -> Parser Text
validId text
  | T.null text = fail "runtime control id is empty"
  | T.length text > 128 = fail "runtime control id exceeds 128 characters"
  | T.all allowed text = pure text
  | otherwise = fail "runtime control id contains an invalid character"
  where
    allowed c = isAlphaNum c || c `elem` ("._-" :: String)

occurrenceText :: OccurrenceId -> Text
occurrenceText = wordText . occurrenceNumber

wordText :: Word64 -> Text
wordText = T.pack . show

ackStateText :: AckState -> Text
ackStateText = \case
  Accepted -> "accepted"
  Queued -> "queued"
  Delivered -> "delivered"
  RejectedStale -> "rejected-stale"
  Unsupported -> "unsupported"
  ControlFailed -> "failed"

timingText :: SteeringTiming -> Text
timingText InterruptNow = "interrupt-now"
timingText NextBoundary = "next-boundary"

parseTiming :: Text -> Parser SteeringTiming
parseTiming "interrupt-now" = pure InterruptNow
parseTiming "next-boundary" = pure NextBoundary
parseTiming other = fail ("unknown steering timing " <> T.unpack other)
