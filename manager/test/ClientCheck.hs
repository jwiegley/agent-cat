{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Manager.Client as C
import Control.Concurrent.Async (AsyncCancelled, async, cancel, waitCatch)
import Control.Exception (bracket, fromException)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (ToJSON (toJSON), Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Char (digitToInt, isHexDigit)
import Data.Foldable (toList)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))

check :: String -> Bool -> IO ()
check label value = unless value (die ("FAIL " <> label)) >> putStrLn ("PASS " <> label)

right :: Show e => Either e a -> IO a
right = either (die . show) pure

field :: Text -> Value -> Value
field key (Object fields) = maybe Null id (KM.lookup (Key.fromText key) fields)
field _ _ = Null

string :: Value -> Text
string (String value) = value
string _ = error "expected public string"

withClient :: FilePath -> (C.Client -> IO a) -> IO a
withClient path = bracket (C.connectClientProfile path >>= right) C.closeClient

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments <- getArgs
  case arguments of
    ["real",profile] -> withClient profile $ \client -> do
      profilesURI <- right (C.reference client "/v1/profiles")
      profiles <- C.getPageSet client profilesURI >>= right
      check "public client assembles profile page" (length (C.pageSetItems profiles) == 1)
      selected <- case C.pageSetItems profiles of
        [profileValue] -> pure (string (field "id" profileValue))
        _ -> die "expected one profile"
      workflowsURI <- right (C.reference client ("/v1/workflows?profileId=" <> selected))
      workflows <- C.getPageSet client workflowsURI >>= right
      check "public client assembles actual workflow catalogue" (not (null (C.pageSetItems workflows)))
      snapshotURI <- right (C.reference client "/v1/snapshot")
      snapshot <- C.getPageSet client snapshotURI >>= right
      let cursor = string (field "cursor" (C.pageSetMetadata snapshot))
      events <- C.pollEvents client cursor >>= right
      check "public client sends Last-Event-ID polling" (C.responseStatus events == 200)
      observed <- C.observeResource client workflowsURI >>= right
      check "GET observation retains exact resource URI" (C.referenceURI (C.observedReference observed) == C.referenceURI workflowsURI)
      withClient profile $ \other -> do
        wrong <- C.prepareObserved other observed (object ["operation" .= ("enqueue" :: Text)])
        check "GET observation cannot migrate to another session" (case wrong of Left C.WrongEndpoint -> True; _ -> False)
      C.closeClient client
      closed <- C.getResource client profilesURI
      check "closed client rejects later reads" (case closed of Left C.ClientClosed -> True; _ -> False)
    ["pages",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/snapshot")
      pages <- C.getPageSet client uri >>= right
      check "complete multi-page assembly preserves every item" (C.pageSetItems pages == [String "first",String "second"])
    ["bad-pages",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/snapshot")
      result <- C.getPageSet client uri
      check "mismatched page set refuses rather than installs partial data" (case result of Left C.InvalidResponse -> True; _ -> False)
    ["nonce",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/requests/request_probe")
      observed <- C.observeResource client uri >>= right
      pending <- C.prepareObserved client observed (object ["operation" .= ("enqueue" :: Text)]) >>= right
      result <- C.sendCommand client pending
      check "maximum authority epoch reaches explicit single HTTP attempt" (case result of Left (C.Refused 409 "state-conflict") -> True; _ -> False)
    ["lost",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/requests")
      pending <- C.prepareCommand client uri Nothing (object ["probe" .= True]) >>= right
      result <- C.sendCommand client pending
      check "lost reply remains an explicit failure without retry" (case result of Left C.TransportUnavailable -> True; _ -> False)
    ["changed",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/profiles")
      result <- C.getResource client uri
      check "credential change before response installation refuses old session" (case result of Left C.CredentialChanged -> True; _ -> False)
    ["cancel",profile] -> withClient profile $ \client -> do
      uri <- right (C.reference client "/v1/blocked")
      original <- async (C.getResource client uri)
      line <- getLine
      unless (line == "cancel") (die "unexpected cancellation barrier")
      cancel original
      outcome <- waitCatch original
      check "original HTTP task is cancelled and joined" (case outcome of
        Left failure -> case fromException failure :: Maybe AsyncCancelled of Just _ -> True; _ -> False
        Right _ -> False)
    ["failure",profile,kind] -> do
      result <- C.connectClientProfile profile
      check "fixed client-profile refusal" $ case result of
        Left C.ClientFileUnavailable -> kind == "file"
        Left C.InvalidClientProfile -> kind == "profile"
        Left C.TransportUnavailable -> kind == "transport"
        Left C.UnsupportedVersion -> kind == "version"
        Left C.RedirectRefused -> kind == "redirect"
        _ -> False
      either (const (pure ())) (void . C.closeClient) result
    ["vectors",path] -> BS.readFile path >>= either (die . ("vector file: " <>)) (\root -> eventVectors root >> resourceVectors root)
      . eitherDecodeStrict
    _ -> die "usage: manager-client-check MODE ABS_CLIENT_PROFILE [FAILURE_KIND] | manager-client-check vectors PATH"

-- The fields of one vector object, or a failure that names the vector.
members :: Text -> Value -> [Value]
members key value = case field key value of
  Array items -> toList items
  _ -> []

text :: Value -> Maybe Text
text (String value) = Just value
text _ = Nothing

bool :: Text -> Value -> Bool
bool key value = field key value == Bool True

vectorLabel :: Text -> Value -> String
vectorLabel kind value = T.unpack (kind <> " " <> maybe "unnamed" id (text (field "name" value)))

-- | The events section of test/manager_client_vectors.json.
eventVectors :: Value -> IO ()
eventVectors root = do
  let section = field "events" root
      counted name = do
        let items = members name section
        when (null items) (die ("FAIL vector section " <> T.unpack name <> " is empty"))
        pure items
  sse <- counted "sse"
  forM_ sse sseVector
  forM_ [("invalidations", jsonVector (C.decodeObservation :: Value -> Either C.ClientFailure C.Invalidation)),
         ("batches", jsonVector (C.decodeObservation :: Value -> Either C.ClientFailure C.EventBatch)),
         ("routeRecords", jsonVector (C.decodeObservation :: Value -> Either C.ClientFailure C.RouteRecord))] $ \(name, run) ->
    counted name >>= mapM_ (run name)
  counted "cursors" >>= mapM_ (\vector -> do
    cursor <- maybe (die "FAIL cursor vector without cursor") pure (text (field "cursor" vector))
    check ("cursor " <> show cursor) (C.validCursor cursor == bool "valid" vector))
  counted "etags" >>= mapM_ (\vector -> case (text (field "a" vector), text (field "b" vector), members "valid" vector) of
    (Just a, Just b, [Bool validA, Bool validB]) -> check ("etag " <> show a <> " " <> show b)
      (C.validETag a == validA && C.validETag b == validB && (a == b) == bool "equal" vector)
    _ -> die "FAIL malformed etag vector")
  counted "problems" >>= mapM_ (\vector -> do
    status <- case field "status" vector of
      Number number -> pure (round number)
      _ -> die ("FAIL " <> vectorLabel "problem" vector <> " has no status")
    expected <- case field "expected" vector of
      String "InvalidResponse" -> pure C.InvalidResponse
      Object _ | [Number code, String name] <- members "refused" (field "expected" vector) -> pure (C.Refused (round code) name)
      _ -> die ("FAIL " <> vectorLabel "problem" vector <> " has no expected failure")
    check (vectorLabel "problem" vector) (C.problemFailure status (field "body" vector) == expected))

-- | The sections of the resources section of test/manager_client_vectors.json
-- that the facade decodes. Each case names its public type.
resourceVectors :: Value -> IO ()
resourceVectors root = do
  let section = field "resources" root
      projected :: ToJSON a => (Value -> Either C.ClientFailure a) -> Value -> Either C.ClientFailure Value
      projected decode = fmap toJSON . decode
      sections =
        [ ("drafts", [("DraftView", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.DraftView)),
            ("Readiness", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.Readiness)),
            ("InputDeclaration", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.InputDeclaration)),
            ("SuppliedInput", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.SuppliedInput)),
            ("InputError", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.InputError))]),
          ("preparations", [("Preparation", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.Preparation)),
            ("Review", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.Review)),
            ("ReviewInput", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.ReviewInput)),
            ("ReviewLineage", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.ReviewLineage)),
            ("ReviewEdit", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.ReviewEdit))]),
          ("receipts", [("CommandReceipt", projected (C.decodeObservation :: Value -> Either C.ClientFailure C.CommandReceipt))]) ]
  forM_ sections $ \(name, decoders) -> do
    let items = members name section
    when (null items) (die ("FAIL vector section resources." <> T.unpack name <> " is empty"))
    forM_ items $ \vector -> case text (field "type" vector) >>= (`lookup` decoders) of
      Just decode -> resourceVector decode name vector
      Nothing -> die ("FAIL " <> vectorLabel name vector <> " names no type of its section")

-- A resource vector: the JSON text decodes to the projection, which is the
-- canonical encoding of the decoded value, or refuses with InvalidResponse.
resourceVector :: (Value -> Either C.ClientFailure Value) -> Text -> Value -> IO ()
resourceVector decode section vector = do
  let label = vectorLabel section vector
      parsed key = case text (field key vector) of
        Just source -> either (\problem -> die ("FAIL " <> label <> ": " <> problem)) pure (eitherDecodeStrict (TE.encodeUtf8 source))
        Nothing -> die ("FAIL " <> label <> " has no " <> T.unpack key)
  value <- parsed "json"
  expected <- case (field "projection" vector, field "refusal" vector) of
    (String _, Null) -> Right <$> parsed "projection"
    (Null, String "InvalidResponse") -> pure (Left C.InvalidResponse)
    _ -> die ("FAIL " <> label <> " states neither one projection nor one refusal")
  let outcome = decode value
  unless (outcome == expected) (die ("FAIL " <> label <> ": " <> show outcome))
  check label True

-- A JSON vector: a valid one decodes and encodes back to the identical value,
-- and an invalid one refuses with InvalidResponse.
jsonVector :: ToJSON a => (Value -> Either C.ClientFailure a) -> Text -> Value -> IO ()
jsonVector decode section vector = do
  source <- maybe (die ("FAIL " <> vectorLabel section vector <> " has no json")) pure (text (field "json" vector))
  value <- either (\problem -> die ("FAIL " <> vectorLabel section vector <> ": " <> problem)) pure
    (eitherDecodeStrict (TE.encodeUtf8 source))
  check (vectorLabel section vector) $ case decode value of
    Right decoded -> bool "valid" vector && toJSON decoded == value
    Left C.InvalidResponse -> not (bool "valid" vector)
    Left _ -> False

-- The bytes of a stream description: text, hexadecimal and repeated segments.
streamBytes :: Value -> IO BS.ByteString
streamBytes vector = BS.concat <$> mapM segment (members "stream" vector)
  where
    segment value
      | Just chars <- text (field "text" value) = pure (TE.encodeUtf8 chars)
      | Just digits <- text (field "hex" value), even (T.length digits), T.all isHexDigit digits =
          pure (BS.pack (pairs (T.unpack digits)))
      | Just chars <- text (field "repeat" value), Number count <- field "count" value =
          pure (TE.encodeUtf8 (T.replicate (round count) chars))
      | otherwise = die ("FAIL " <> vectorLabel "sse" vector <> " has a malformed segment")
    pairs (high:low:rest) = fromIntegral (16 * digitToInt high + digitToInt low) : pairs rest
    pairs _ = []

expectedBlock :: Value -> IO C.SseBlock
expectedBlock (String "heartbeat") = pure C.SseHeartbeat
expectedBlock value
  | Just ident <- text (field "advance" value) = pure (C.SseAdvance ident)
  | Object _ <- event, Just name <- text (field "name" event), Just payload <- eventData (field "data" event) =
      pure (C.SseDispatch (C.SseEvent (text (field "id" event)) name payload))
  | otherwise = die "FAIL malformed expected SSE block"
  where
    event = field "event" value
    eventData (String payload) = Just payload
    eventData repeated
      | Just chars <- text (field "repeat" repeated), Number count <- field "count" repeated = Just (T.replicate (round count) chars)
    eventData _ = Nothing

-- Feed the chunks in order. The outcome is the blocks that were dispatched,
-- and the refusal or the last complete event identifier at close.
feedAll :: Maybe Text -> [BS.ByteString] -> ([C.SseBlock], Either C.ClientFailure (Maybe Text))
feedAll initial = go (C.newSseParser initial) []
  where
    go parser out [] = (concat (reverse out), Right (C.closeSse parser))
    go parser out (chunk:rest) = case C.feedSse parser chunk of
      Left failure -> (concat (reverse out), Left failure)
      Right (next, blocks) -> go next (blocks : out) rest

chunksAt :: [Int] -> BS.ByteString -> [BS.ByteString]
chunksAt offsets bytes = go 0 offsets
  where
    go start (point:rest) = BS.take (point - start) (BS.drop start bytes) : go point rest
    go start [] = [BS.drop start bytes]

sseVector :: Value -> IO ()
sseVector vector = do
  bytes <- streamBytes vector
  expected <- mapM expectedBlock (members "expected" vector)
  let size = BS.length bytes
      listed = [[round point | Number point <- elements split] | split <- members "splits" vector]
      elements (Array items) = toList items
      elements _ = []
      exhaustive = if size <= 2048 then [[point] | point <- [1 .. size - 1]] else []
      bytewise = [[1 .. size - 1]]
      refusing = bool "refuse" vector
      lastId = text (field "lastId" vector)
      initial = text (field "initialId" vector)
  forM_ listed $ \points -> unless (and (zipWith (<) (0 : points) (points ++ [size])))
    (die ("FAIL " <> vectorLabel "sse" vector <> " lists an invalid split " <> show points))
  when (null listed) (die ("FAIL " <> vectorLabel "sse" vector <> " lists no split point"))
  let outcomes = [(points, feedAll initial (chunksAt points bytes)) | points <- [] : listed ++ exhaustive ++ bytewise]
      agrees (blocks, result)
        | refusing = result == Left C.InvalidResponse && blocks `isPrefixOf` expected
        | otherwise = result == Right lastId && blocks == expected
      wrong = [(points, outcome) | (points, outcome) <- outcomes, not (agrees outcome)]
  case wrong of
    [] -> pure ()
    (points, outcome):_ -> die ("FAIL " <> vectorLabel "sse" vector <> " at split " <> show points <> ": " <> show outcome)
  check (vectorLabel "sse" vector <> " for " <> show (length outcomes) <> " splits") True
  let events = [event | C.SseDispatch event <- expected]
      decodes :: (C.SseEvent -> Either C.ClientFailure a) -> Bool
      decodes decode = let results = map decode events in
        if bool "decodeValid" vector then all (either (const False) (const True)) results
        else any (== Left C.InvalidResponse) (map (either Left (const (Right ()))) results)
  case text (field "decode" vector) of
    Just "invalidation" -> check (vectorLabel "sse decode" vector) (decodes C.decodeEventBlock)
    Just "route" -> check (vectorLabel "sse decode" vector) (decodes C.decodeRouteBlock)
    Nothing -> pure ()
    Just other -> die ("FAIL unknown decode " <> T.unpack other)
