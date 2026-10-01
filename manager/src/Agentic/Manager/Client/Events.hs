{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Pure live-delivery decoding: an incremental server-sent-event block
-- parser, the event invalidation and batch records of @/events@, and the
-- record of a route stream. Nothing here performs I/O or holds a session.
module Agentic.Manager.Client.Events
  ( sseBlockBytes, SseParser, SseEvent (..), SseBlock (..), newSseParser, feedSse, closeSse,
    EventName (..), eventNameText, parseEventName, Invalidation (..), InvalidationEvent (..), EventBatch (..),
    RouteRecord (..), RoutePayload (..), decodeEventBlock, decodeRouteBlock,
    validCursor, validETag
  ) where

import Agentic.Manager.Client.Failure (ClientFailure (..))
import Agentic.Manager.Protocol.Command (validId, validResource, validRevision)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value (..), object, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)

-- | The largest complete block, terminating blank line included, that the
-- manager writes and the parser accepts: the @sseBlockBytes@ limit.
sseBlockBytes :: Int
sseBlockBytes = 16384

-- | The state of one connection: the pieces of its incomplete line, the
-- complete lines of its incomplete block, the bytes of that block so far,
-- and the last complete event identifier.
data SseParser = SseParser ![BS.ByteString] ![BS.ByteString] !Int !(Maybe Text)

-- | One dispatched block. 'sseId' is the @id@ line of this block, when it has
-- one. 'sseName' is its last @event@ line, or @message@ without one. 'sseData'
-- joins its @data@ lines with LF.
data SseEvent = SseEvent {sseId :: !(Maybe Text), sseName :: !Text, sseData :: !Text}
  deriving (Eq, Show)

-- | The outcome of one complete block. A block with @data@ dispatches an
-- event. A block with an @id@ and no @data@ advances the last event
-- identifier and dispatches nothing. A block of comment lines only is a
-- heartbeat. A block of other fields only gives no outcome.
data SseBlock = SseDispatch !SseEvent | SseAdvance !Text | SseHeartbeat
  deriving (Eq, Show)

-- | A parser for a new connection. A reconnection supplies the identifier
-- that it sent in @Last-Event-ID@, which stays the last complete event
-- identifier until a later block carries an @id@.
newSseParser :: Maybe Text -> SseParser
newSseParser = SseParser [] [] 0

-- | Accept the next bytes of the response, split at any point, and return the
-- outcomes of the blocks that they complete, in order. A line ends at LF or
-- CRLF, and a blank line ends a block. A carriage return elsewhere, a block
-- that is not UTF-8, an @id@ that is not a cursor, and a block above
-- 'sseBlockBytes' refuse with 'InvalidResponse', and the connection is then
-- unusable. An incomplete block is refused as soon as it passes the bound.
feedSse :: SseParser -> BS.ByteString -> Either ClientFailure (SseParser, [SseBlock])
feedSse start chunk = go start chunk []
  where
    go (SseParser pieces complete bytes lastId) rest out = case BS.elemIndex 10 rest of
      Nothing -> do
        let total = bytes + BS.length rest
        when (total > sseBlockBytes) (Left InvalidResponse)
        pure (SseParser (if BS.null rest then pieces else rest : pieces) complete total lastId, reverse out)
      Just index -> do
        let total = bytes + index + 1
        when (total > sseBlockBytes) (Left InvalidResponse)
        line <- lineOf (BS.concat (reverse (BS.take index rest : pieces)))
        let remaining = BS.drop (index + 1) rest
        if BS.null line
          then do
            (lastId', outcome) <- blockOf lastId (reverse complete)
            go (SseParser [] [] 0 lastId') remaining (maybe out (: out) outcome)
          else go (SseParser [] (line : complete) total lastId) remaining out
    lineOf raw = do
      let line = fromMaybe raw (BS.stripSuffix "\r" raw)
      when (BS.elem 13 line) (Left InvalidResponse)
      pure line

-- | The last complete event identifier at the end of a connection. The bytes
-- of an incomplete final block are discarded and dispatch nothing.
closeSse :: SseParser -> Maybe Text
closeSse (SseParser _ _ _ lastId) = lastId

blockOf :: Maybe Text -> [BS.ByteString] -> Either ClientFailure (Maybe Text, Maybe SseBlock)
blockOf lastId rawLines = do
  texts <- traverse (either (const (Left InvalidResponse)) Right . TE.decodeUtf8') rawLines
  let fields = [field line | line <- texts, not (":" `T.isPrefixOf` line)]
      field line = case T.break (== ':') line of
        (name, value) -> (name, maybe "" (\v -> fromMaybe v (T.stripPrefix " " v)) (T.stripPrefix ":" value))
      ids = [value | ("id", value) <- fields]
      names = [value | ("event", value) <- fields]
      payload = [value | ("data", value) <- fields]
  unless (all validCursor ids) (Left InvalidResponse)
  let blockId = if null ids then Nothing else Just (last ids)
      outcome
        | not (null payload) = Just (SseDispatch (SseEvent blockId (if null names then "message" else last names)
            (T.intercalate "\n" payload)))
        | Just ident <- blockId = Just (SseAdvance ident)
        | null fields && not (null texts) = Just SseHeartbeat
        | otherwise = Nothing
  pure (maybe lastId Just blockId, outcome)

-- | A canonical event cursor: an identifier, a dot and a canonical unsigned
-- 64-bit decimal. Event, route and manager-route cursors share this syntax.
validCursor :: Text -> Bool
validCursor value = case T.splitOn "." value of
  [stream,number] -> validId stream && not (T.null number) && T.length number <= 20
    && T.all (\c -> c >= '0' && c <= '9') number
    && (number == "0" || T.take 1 number /= "0")
    && T.foldl' (\n c -> 10 * n + toInteger (fromEnum c - fromEnum '0')) 0 number <= 18446744073709551615
  _ -> False

-- | A strong entity tag: a quoted identifier. Two tags match only when they
-- are equal as text, and a tag carries no order.
validETag :: Text -> Bool
validETag value = T.length value >= 3 && T.length value <= 130 && T.head value == '"'
  && T.last value == '"' && validId (T.dropEnd 1 (T.drop 1 value))

-- | The seven event names of the @/events@ stream.
data EventName = RequestChanged | PreparationChanged | RunChanged | DecisionChanged
  | CommandChanged | ArtifactChanged | ServiceChanged
  deriving (Eq, Ord, Show, Enum, Bounded)

eventNameText :: EventName -> Text
eventNameText name = case name of
  RequestChanged -> "request.changed"
  PreparationChanged -> "preparation.changed"
  RunChanged -> "run.changed"
  DecisionChanged -> "decision.changed"
  CommandChanged -> "command.changed"
  ArtifactChanged -> "artifact.changed"
  ServiceChanged -> "service.changed"

parseEventName :: Text -> Maybe EventName
parseEventName text = lookup text [(eventNameText name, name) | name <- [minBound .. maxBound]]

-- | A versioned resource invalidation. The revision is an equality token.
data Invalidation = Invalidation {invalidationResource :: !Text, invalidationRevision :: !Text}
  deriving (Eq, Show)

-- | One event of a JSON batch or of the @/events@ stream.
data InvalidationEvent = InvalidationEvent
  {invalidationEventId :: !Text, invalidationEventName :: !EventName, invalidationEventData :: !Invalidation}
  deriving (Eq, Show)

-- | One JSON polling batch. 'batchOldestCursor' is used as supplied.
data EventBatch = EventBatch
  {batchCursor :: !Text, batchOldestCursor :: !Text, batchEvents :: ![InvalidationEvent], batchHasMore :: !Bool}
  deriving (Eq, Show)

-- | One record of a run route or manager route: the fields of the local flow
-- reader with @id@ and @class@. The record at position p has the identifier
-- of position p+1.
data RouteRecord = RouteRecord
  { routeId :: !Text, routeClass :: !Text, routePosition :: !Word64, routeSchema :: !Text,
    routeFrom :: !Value, routeTo :: !Value, routeAbout :: !Value, routeReplyTo :: !(Maybe Word64),
    routeAt :: !Text, routePayload :: !RoutePayload }
  deriving (Eq, Show)

-- | An inline body, a claim check with its digest and size, or the sequence
-- number of an event record.
data RoutePayload = RouteBody !Value | RouteClaim !Text !Word64 | RouteEvent !Word64
  deriving (Eq, Show)

instance NFData EventName where rnf name = name `seq` ()
instance NFData Invalidation where rnf (Invalidation a b) = rnf a `seq` rnf b
instance NFData InvalidationEvent where rnf (InvalidationEvent a b c) = rnf a `seq` rnf b `seq` rnf c
instance NFData EventBatch where rnf (EventBatch a b c d) = rnf a `seq` rnf b `seq` rnf c `seq` rnf d
instance NFData RoutePayload where
  rnf payload = case payload of
    RouteBody value -> rnf value
    RouteClaim digest size -> rnf digest `seq` rnf size
    RouteEvent number -> rnf number
instance NFData RouteRecord where
  rnf (RouteRecord a b c d e f g h i j) = rnf a `seq` rnf b `seq` rnf c `seq` rnf d `seq` rnf e
    `seq` rnf f `seq` rnf g `seq` rnf h `seq` rnf i `seq` rnf j

closed :: [Key] -> Object -> Parser ()
closed names fields = unless (KM.size fields == length names && all (`KM.member` fields) names) (fail "fields")

versionOne :: Object -> Parser ()
versionOne fields = case KM.lookup "version" fields of
  Just (Number 1) -> pure ()
  _ -> fail "version"

cursorField :: Object -> Key -> Parser Text
cursorField fields name = do
  value <- fields .: name
  unless (validCursor value) (fail "cursor")
  pure value

-- A decimal JSON number in the unsigned 64-bit range, without rounding.
word64 :: Value -> Parser Word64
word64 (Number number) = maybe (fail "integer") pure (toBoundedInteger number)
word64 _ = fail "integer"

instance FromJSON Invalidation where
  parseJSON = withObject "invalidation" $ \fields -> do
    closed ["version", "resource", "revision"] fields
    versionOne fields
    resource <- fields .: "resource"
    revision <- fields .: "revision"
    unless (validResource resource && validRevision revision) (fail "invalidation")
    pure (Invalidation resource revision)

instance ToJSON Invalidation where
  toJSON (Invalidation resource revision) =
    object ["version" .= (1 :: Int), "resource" .= resource, "revision" .= revision]

instance FromJSON InvalidationEvent where
  parseJSON = withObject "event" $ \fields -> do
    closed ["id", "event", "data"] fields
    ident <- cursorField fields "id"
    name <- fields .: "event" >>= maybe (fail "event name") pure . parseEventName
    InvalidationEvent ident name <$> fields .: "data"

instance ToJSON InvalidationEvent where
  toJSON (InvalidationEvent ident name value) =
    object ["id" .= ident, "event" .= eventNameText name, "data" .= value]

instance FromJSON EventBatch where
  parseJSON = withObject "event batch" $ \fields -> do
    closed ["version", "cursor", "oldestCursor", "events", "hasMore"] fields
    versionOne fields
    cursor <- cursorField fields "cursor"
    oldest <- cursorField fields "oldestCursor"
    events <- fields .: "events"
    unless (length events <= 256) (fail "events")
    EventBatch cursor oldest events <$> fields .: "hasMore"

instance ToJSON EventBatch where
  toJSON (EventBatch cursor oldest events more) = object
    ["version" .= (1 :: Int), "cursor" .= cursor, "oldestCursor" .= oldest, "events" .= events, "hasMore" .= more]

routeSchemas :: [Text]
routeSchemas = ["start", "control", "question", "answer", "engine-start", "turn", "steer", "done", "event",
  "permission", "command", "receipt", "review", "relay", "notice"]

instance FromJSON RouteRecord where
  parseJSON = withObject "route record" $ \fields -> do
    let header = ["id", "class", "position", "schema", "from", "to", "about", "replyTo", "at"]
        bodies = mapMaybe (\name -> (,) name <$> KM.lookup name fields) ["body", "claim", "event"]
    (bodyName, bodyValue) <- case bodies of
      [single] -> pure single
      _ -> fail "route payload"
    closed (bodyName : header) fields
    ident <- cursorField fields "id"
    kind <- fields .: "class"
    position <- fields .: "position" >>= word64
    schema <- fields .: "schema"
    from <- fields .: "from"
    to <- fields .: "to"
    about <- fields .: "about"
    replyTo <- fields .: "replyTo" >>= \value -> case value of
      Null -> pure Nothing
      _ -> Just <$> word64 value
    at <- fields .: "at"
    unless (kind `elem` ["public", "actor" :: Text] && schema `elem` routeSchemas) (fail "route record")
    unless (position < maxBound && T.takeWhileEnd (/= '.') ident == T.pack (show (position + 1))) (fail "route identifier")
    case from of
      String "manager" -> pure ()
      Object _ -> pure ()
      _ -> fail "route from"
    case to of
      String "public" -> pure ()
      Object _ -> pure ()
      _ -> fail "route to"
    case about of
      Object _ -> pure ()
      _ -> fail "route about"
    payload <- case bodyName of
      "body" -> pure (RouteBody bodyValue)
      "claim" -> flip (withObject "claim") bodyValue $ \claim -> do
        closed ["sha256", "bytes"] claim
        digest <- claim .: "sha256"
        unless (T.length digest == 64 && T.all (`elem` ("0123456789abcdef" :: String)) digest) (fail "claim digest")
        RouteClaim digest <$> (claim .: "bytes" >>= word64)
      _ -> flip (withObject "event") bodyValue $ \event -> do
        closed ["sequence"] event
        RouteEvent <$> (event .: "sequence" >>= word64)
    pure (RouteRecord ident kind position schema from to about replyTo at payload)

instance ToJSON RouteRecord where
  toJSON record = object $
    [ "id" .= routeId record, "class" .= routeClass record, "position" .= routePosition record,
      "schema" .= routeSchema record, "from" .= routeFrom record, "to" .= routeTo record,
      "about" .= routeAbout record, "replyTo" .= routeReplyTo record, "at" .= routeAt record ]
    <> case routePayload record of
      RouteBody value -> ["body" .= value]
      RouteClaim digest size -> ["claim" .= object ["sha256" .= digest, "bytes" .= size]]
      RouteEvent number -> ["event" .= object ["sequence" .= number]]

-- The data of a block as one strict JSON value of the given decoder.
blockData :: FromJSON a => SseEvent -> Either ClientFailure a
blockData event = case decodeStrictValue (TE.encodeUtf8 (sseData event)) of
  Left _ -> Left InvalidResponse
  Right value -> either (const (Left InvalidResponse)) Right (parseEither parseJSON value)

-- | The invalidation of one dispatched block of @/events@. The block carries
-- its own @id@, one of the seven event names, and an invalidation as data.
decodeEventBlock :: SseEvent -> Either ClientFailure InvalidationEvent
decodeEventBlock event = do
  ident <- maybe (Left InvalidResponse) Right (sseId event)
  name <- maybe (Left InvalidResponse) Right (parseEventName (sseName event))
  InvalidationEvent ident name <$> blockData event

-- | The record of one dispatched block of a route stream. The block carries
-- the identifier of the record and the event name @route.@ and its schema.
decodeRouteBlock :: SseEvent -> Either ClientFailure RouteRecord
decodeRouteBlock event = do
  ident <- maybe (Left InvalidResponse) Right (sseId event)
  record <- blockData event
  unless (routeId record == ident && sseName event == "route." <> routeSchema record) (Left InvalidResponse)
  pure record
