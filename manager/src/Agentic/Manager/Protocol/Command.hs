{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Public command facts, without authentication or live dispatch authority.
module Agentic.Manager.Protocol.Command
  ( Operation (..), operationName, parseOperation, Scope (..), scopeName, requiredScopes,
    CommandState (..), stateName, parseState, CommandFailure (..), failureCode, failureStatus,
    CommandReceipt (..), Acknowledgement, acknowledgementValue, Effect, effectValue,
    validId, validResource, validRevision, validTimestamp, encoded, decodeReceipt
  ) where

import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.Exception (Exception)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (unless, when)
import Data.Aeson
  (FromJSON (parseJSON), ToJSON (toJSON), Value (..), encode,
   object, withObject, withText, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isAlphaNum, isAscii)
import Data.Maybe (isJust)
import Data.Time (UTCTime, ZonedTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | The frozen set of command operations, not workflow operators.
data Operation = Create | Capture | SetInput | RemoveInput | Enqueue | Withdraw
  | Approve | Discard | Cancel | Steer | Retry | ChooseRecovery | Redirect | Answer
  | Export | Restart | Resume | Fork
  deriving (Eq, Ord, Show, Enum, Bounded, Generic, NFData)

operationName :: Operation -> Text
operationName operation = names !! fromEnum operation
  where
    names = ["create", "capture", "set-input", "remove-input", "enqueue", "withdraw",
      "approve", "discard", "cancel", "steer", "retry", "choose-recovery", "redirect", "answer",
      "export", "restart", "resume", "fork"]

parseOperation :: Text -> Maybe Operation
parseOperation text = lookup text [(operationName op, op) | op <- [minBound .. maxBound]]
instance ToJSON Operation where toJSON = String . operationName
instance FromJSON Operation where
  parseJSON = withText "operation" $ maybe (fail "invalid operation") pure . parseOperation

-- | Profile-scoped permissions, independent of credential identity.
data Scope = Observe | Submit | Control | ExportScope deriving (Eq, Ord, Show, Generic, NFData)
scopeName :: Scope -> Text
scopeName scope = case scope of Observe -> "observe"; Submit -> "submit"; Control -> "control"; ExportScope -> "export"
requiredScopes :: Operation -> [Scope]
requiredScopes op
  | op `elem` [Create, Capture, SetInput, RemoveInput, Enqueue, Withdraw] = [Submit]
  | op `elem` [Approve, Discard] = [Submit, Control]
  | op `elem` [Cancel, Steer, Retry, ChooseRecovery, Redirect, Answer] = [Control]
  | op == Export = [Observe, ExportScope]
  | otherwise = [Observe, Submit]

-- | Durable observations. Accepted intent is not attempted or acknowledged delivery.
data CommandState = Accepted | DispatchAttempted | Acknowledged | EffectObserved | Refused | Unresolved
  deriving (Eq, Ord, Show, Enum, Bounded, Generic, NFData)
stateName :: CommandState -> Text
stateName state = ["accepted", "dispatch-attempted", "acknowledged", "effect-observed", "refused", "unresolved"] !! fromEnum state
parseState :: Text -> Maybe CommandState
parseState text = lookup text [(stateName state, state) | state <- [minBound .. maxBound]]
instance ToJSON CommandState where toJSON = String . stateName
instance FromJSON CommandState where
  parseJSON = withText "command state" $ maybe (fail "invalid state") pure . parseState

-- | Fixed refusal categories, never private SQL, credentials, request bytes or paths.
data CommandFailure = Unauthenticated | Forbidden | AuthorityChanged | InvalidPrecondition
  | PreconditionRequired | StaleRevision | StateConflict | IdempotencyConflict | ReceiptExpired
  | StorageQuota | RateLimit | StorageUnavailable | ResourceUnavailable | InvalidRequest
  | UnsupportedMediaType | OwnershipUnavailable | SizeLimit | InvalidInput | ViewTooLarge
  | DecisionNotHead | UnsupportedOperation | UnsupportedVersion | ViewExpired | CursorExpired
  deriving (Eq, Show, Generic, NFData)
instance Exception CommandFailure

failureCode :: CommandFailure -> Text
failureCode failure = case failure of
  DecisionNotHead -> "decision-not-head"
  UnsupportedOperation -> "unsupported-operation"
  UnsupportedVersion -> "unsupported-version"
  ViewExpired -> "view-expired"
  CursorExpired -> "cursor-expired"
  InvalidInput -> "invalid-input"
  ViewTooLarge -> "view-too-large"
  SizeLimit -> "size-limit"
  Unauthenticated -> "unauthenticated"
  Forbidden -> "insufficient-scope"
  AuthorityChanged -> "authority-changed"
  InvalidPrecondition -> "invalid-precondition"
  PreconditionRequired -> "precondition-required"
  StaleRevision -> "stale-revision"
  StateConflict -> "state-conflict"
  IdempotencyConflict -> "idempotency-conflict"
  ReceiptExpired -> "receipt-expired"
  StorageQuota -> "storage-quota"
  RateLimit -> "rate-limit"
  StorageUnavailable -> "storage-unavailable"
  ResourceUnavailable -> "unavailable-resource"
  InvalidRequest -> "malformed-request"
  UnsupportedMediaType -> "unsupported-media-type"
  OwnershipUnavailable -> "ownership-unavailable"
failureStatus :: CommandFailure -> Int
failureStatus failure = case failure of
  DecisionNotHead -> 409
  UnsupportedOperation -> 409
  InvalidInput -> 422
  ViewTooLarge -> 413
  SizeLimit -> 413
  Unauthenticated -> 401
  Forbidden -> 403
  ResourceUnavailable -> 404
  AuthorityChanged -> 409
  StateConflict -> 409
  IdempotencyConflict -> 409
  OwnershipUnavailable -> 409
  ReceiptExpired -> 410
  ViewExpired -> 410
  CursorExpired -> 410
  StaleRevision -> 412
  UnsupportedMediaType -> 415
  PreconditionRequired -> 428
  StorageQuota -> 429
  RateLimit -> 429
  StorageUnavailable -> 503
  _ -> 400

-- | A bounded public acknowledgement. Native evidence validation belongs to its adapter.
newtype Acknowledgement = Acknowledgement Value deriving (Eq, Show)
instance NFData Acknowledgement where rnf (Acknowledgement value) = rnf value
acknowledgementValue :: Acknowledgement -> Value
acknowledgementValue (Acknowledgement value) = value
instance ToJSON Acknowledgement where toJSON = acknowledgementValue
instance FromJSON Acknowledgement where
  parseJSON value = withObject "acknowledgement" (\o -> do
    closed ["commandId", "state", "message", "command", "occurrenceId", "attemptId"] o
    identifier o "commandId"
    member o "state" ["accepted", "queued", "delivered", "rejected-stale", "unsupported", "failed"]
    boundedText o "message" 4096
    command <- o .: "command" :: Parser (Maybe Text)
    mapM_ (\name -> unless (name `elem` ["cancel", "steer", "retry", "choose-recovery", "redirect", "answer"]) (fail "command")) command
    optionalDecimal o "occurrenceId" 20 18446744073709551615
    optionalDecimal o "attemptId" 10 4294967295
    occurrence <- o .: "occurrenceId" :: Parser (Maybe Text)
    attempt <- o .: "attemptId" :: Parser (Maybe Text)
    unless (attempt == Nothing || occurrence /= Nothing) (fail "attempt requires occurrence")
    when (command == Just "answer") $
      unless (occurrence /= Nothing && attempt == Nothing) (fail "answer address")
    unless (BS.length (encoded value) <= 32768) (fail "acknowledgement bound")
    pure (Acknowledgement value)) value

-- | Bounded effect evidence, independent of a pipe callback's return value.
newtype Effect = Effect Value deriving (Eq, Show)
instance NFData Effect where rnf (Effect value) = rnf value
effectValue :: Effect -> Value
effectValue (Effect value) = value
instance ToJSON Effect where toJSON = effectValue
instance FromJSON Effect where
  parseJSON value = withObject "effect" (\o -> do
    closed ["kind", "runtimeSequence", "address", "resource"] o
    member o "kind" ["started", "cancelled", "steered", "retried", "recovery-chosen", "redirected",
      "answer-accepted", "input-changed", "enqueued", "withdrawn", "discarded", "exported", "lineage-created"]
    optionalDecimal o "runtimeSequence" 20 18446744073709551615
    resource <- o .: "resource"
    unless (validResource resource) (fail "effect resource")
    address <- o .: "address"
    case address of
      Null -> pure ()
      Object fields -> do
        if KM.member "attemptId" fields then closed ["occurrenceId", "attemptId"] fields >> decimal fields "attemptId" 10 4294967295
          else closed ["occurrenceId"] fields
        decimal fields "occurrenceId" 20 18446744073709551615
      _ -> fail "effect address"
    unless (BS.length (encoded value) <= 16384) (fail "effect bound")
    pure (Effect value)) value

-- | The frozen CommandReceipt projection. No private request binding is included.
data CommandReceipt = CommandReceipt
  { receiptId :: !Text, receiptProfile :: !Text, receiptOperation :: !Operation,
    receiptResource :: !Text, receiptState :: !CommandState, receiptAcceptedAt :: !Text,
    receiptAttemptedAt :: !(Maybe Text), receiptAcknowledgement :: !(Maybe Acknowledgement),
    receiptEffect :: !(Maybe Effect), receiptRefusal :: !(Maybe Text)
  } deriving (Eq, Show, Generic, NFData)
instance ToJSON CommandReceipt where
  toJSON r = object
    ["version" .= (1 :: Int), "id" .= receiptId r, "profileId" .= receiptProfile r,
     "operation" .= receiptOperation r, "requiredScopes" .= map scopeName (requiredScopes (receiptOperation r)),
     "resource" .= receiptResource r, "state" .= receiptState r, "acceptedAt" .= receiptAcceptedAt r,
     "dispatchAttemptedAt" .= receiptAttemptedAt r, "acknowledgement" .= receiptAcknowledgement r,
     "effect" .= receiptEffect r, "refusal" .= receiptRefusal r,
     "links" .= object ["self" .= ("/v1/commands/" <> receiptId r), "resource" .= receiptResource r]]
instance FromJSON CommandReceipt where
  parseJSON = withObject "command receipt" $ \o -> do
    closed ["version", "id", "profileId", "operation", "requiredScopes", "resource", "state", "acceptedAt",
            "dispatchAttemptedAt", "acknowledgement", "effect", "refusal", "links"] o
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail "receipt version")
    r <- CommandReceipt <$> o .: "id" <*> o .: "profileId" <*> o .: "operation" <*> o .: "resource"
      <*> o .: "state" <*> o .: "acceptedAt" <*> o .: "dispatchAttemptedAt" <*> o .: "acknowledgement"
      <*> o .: "effect" <*> o .: "refusal"
    unless (validId (receiptId r) && validId (receiptProfile r) && validResource (receiptResource r)) (fail "receipt identity")
    unless (validTimestamp (receiptAcceptedAt r) && maybe True validTimestamp (receiptAttemptedAt r)) (fail "receipt timestamp")
    scopes <- o .: "requiredScopes"
    unless (scopes == map scopeName (requiredScopes (receiptOperation r))) (fail "receipt scope binding")
    links <- o .: "links"
    closed ["self", "resource"] links
    self <- links .: "self"
    resource <- links .: "resource"
    unless (self == "/v1/commands/" <> receiptId r && resource == receiptResource r) (fail "receipt links")
    case receiptState r of
      Accepted -> unless (receiptAttemptedAt r == Nothing && receiptAcknowledgement r == Nothing && receiptEffect r == Nothing && receiptRefusal r == Nothing) (fail "accepted receipt")
      DispatchAttempted -> unless (receiptAttemptedAt r /= Nothing && receiptAcknowledgement r == Nothing && receiptEffect r == Nothing && receiptRefusal r == Nothing) (fail "attempted receipt")
      Acknowledged -> unless (receiptAttemptedAt r /= Nothing && receiptAcknowledgement r /= Nothing && receiptEffect r == Nothing && receiptRefusal r == Nothing) (fail "acknowledged receipt")
      EffectObserved -> unless (receiptEffect r /= Nothing && receiptRefusal r == Nothing) (fail "effect receipt")
      Refused -> unless (receiptRefusal r /= Nothing && receiptEffect r == Nothing) (fail "refused receipt")
      Unresolved -> unless (receiptEffect r == Nothing && receiptRefusal r == Nothing) (fail "unresolved receipt")
    case receiptRefusal r of
      Nothing -> pure ()
      Just refusal -> unless (refusal `elem` ["state-conflict", "stale-revision", "unsupported-operation", "ownership-unavailable", "supervision-unavailable", "invalid-answer", "invalid-lineage-edit", "export-conflict", "storage-unavailable"]) (fail "receipt refusal")
    pure r

encoded :: ToJSON a => a -> BS.ByteString
encoded = BL.toStrict . encode

decodeReceipt :: BS.ByteString -> Either CommandFailure CommandReceipt
decodeReceipt bytes
  | BS.length bytes > 65536 = Left StorageUnavailable
  | otherwise = either (const (Left StorageUnavailable)) Right (decodeStrictValue bytes >>= parseEither parseJSON)

validTimestamp :: Text -> Bool
validTimestamp value = T.length value >= 20 && T.length value <= 64
  && T.index upper 4 == '-' && T.index upper 7 == '-' && T.index upper 10 == 'T'
  && T.index upper 13 == ':' && T.index upper 16 == ':' && not (T.any (== ',') upper)
  && all (T.all digit) [T.take 4 upper, T.take 2 (T.drop 5 upper), T.take 2 (T.drop 8 upper),
      T.take 2 (T.drop 11 upper), T.take 2 (T.drop 14 upper), T.take 2 (T.drop 17 upper)]
  && (T.index upper 19 /= '.' || not (T.null (T.takeWhile digit (T.drop 20 upper))))
  && T.take 4 upper /= "0000" && T.take 2 (T.drop 17 upper) < "60"
  && (T.isSuffixOf "Z" upper || (T.length zone == 6 && T.head zone `elem` ['+','-'] && T.index zone 3 == ':'
      && T.take 2 (T.drop 1 zone) < "24" && T.drop 4 zone < "60"))
  && (isJust (iso8601ParseM (T.unpack upper) :: Maybe UTCTime)
      || isJust (iso8601ParseM (T.unpack upper) :: Maybe ZonedTime))
  where
    upper = T.toUpper value
    zone = T.takeEnd 6 upper
    digit c = c >= '0' && c <= '9'

validId :: Text -> Bool
validId text = not (T.null text) && T.length text <= 128 && T.all tokenChar text
validRevision :: Text -> Bool
validRevision = validId
validResource :: Text -> Bool
validResource text = T.length text > 4 && T.length text <= 8192 && T.isPrefixOf "/v1/" text
  && T.all (\c -> tokenChar c || c `elem` ("/?=&.%" :: String)) text
tokenChar :: Char -> Bool
tokenChar c = isAscii c && (isAlphaNum c || c == '_' || c == '-')

closed :: [Text] -> Object -> Parser ()
closed fields o = unless (length fields == KM.size o && all ((`elem` fields) . Key.toText) (KM.keys o)) (fail "object fields")
identifier :: Object -> Key.Key -> Parser ()
identifier o key = o .: key >>= \t -> unless (validId t) (fail "identifier")
boundedText :: Object -> Key.Key -> Int -> Parser ()
boundedText o key bound = o .: key >>= \t -> when (T.length t > bound) (fail "text bound")
member :: Object -> Key.Key -> [Text] -> Parser ()
member o key choices = o .: key >>= \t -> unless (t `elem` choices) (fail "enum")
decimal :: Object -> Key.Key -> Int -> Integer -> Parser ()
decimal o key digits maximumValue = o .: key >>= checkDecimal digits maximumValue
optionalDecimal :: Object -> Key.Key -> Int -> Integer -> Parser ()
optionalDecimal o key digits maximumValue = (o .: key :: Parser (Maybe Text)) >>= mapM_ (checkDecimal digits maximumValue)
checkDecimal :: Int -> Integer -> Text -> Parser ()
checkDecimal digits maximumValue text = do
  unless (not (T.null text) && T.length text <= digits && T.all (\c -> c >= '0' && c <= '9') text
    && (text == "0" || T.head text /= '0')) (fail "decimal")
  case reads (T.unpack text) of
    [(number, "")] | number <= maximumValue -> pure ()
    _ -> fail "decimal bound"
