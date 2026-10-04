{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Manager.Client as C
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled, async, cancel, wait, waitCatch)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (bracket, fromException)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (ToJSON (toJSON), Value (..), eitherDecodeStrict, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import qualified Data.ByteString as BS
import Data.Char (digitToInt, isHexDigit)
import Data.Foldable (foldlM, toList)
import Data.List (find, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (getArgs)
import System.Exit (die)
import System.IO (hPutStrLn, hSetBuffering, stderr, stdout, BufferMode (LineBuffering))
import System.Timeout (timeout)

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
      workflow <- case C.pageSetItems workflows of
        first : _ -> pure first
        [] -> die "expected one workflow"
      liveDelivery client workflow
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
      either (hPutStrLn stderr . ("failure: " <>) . show) (const (hPutStrLn stderr "connected")) result
      check "fixed client-profile refusal" $ case result of
        Left (C.ClientFileRefused C.ProfileFile C.FileWritableByOthers) -> kind == "file"
        Left (C.ClientFileRefused C.ProfileFile C.FileNotPrivate) -> kind == "private"
        Left (C.ClientFileRefused C.CredentialFile C.FileMissing) -> kind == "missing-credential"
        Left C.ManagerCertificateRefused -> kind == "certificate"
        Left C.TlsHandshakeFailed -> kind == "handshake"
        Left C.InvalidClientProfile -> kind == "profile"
        Left C.TransportUnavailable -> kind == "transport"
        Left C.UnsupportedVersion -> kind == "version"
        Left C.RedirectRefused -> kind == "redirect"
        _ -> False
      either (const (pure ())) (void . C.closeClient) result
    ["stream-idle",profile] -> withClient profile $ \client -> do
      received <- newTVarIO []
      result <- C.streamEventsWithin 1000 client "stream_fixture.0" (collect received)
      items <- reverse <$> readTVarIO received
      check "idle stream ends after its bound with the last complete event identifier"
        (result == Right "stream_fixture.1" && items == [C.StreamInvalidation fixtureEvent, C.StreamHeartbeat])
    ["stream-close",profile] -> withClient profile $ \client -> do
      received <- newTVarIO []
      stream <- async (C.streamEvents client "stream_fixture.0" (collect received))
      arrived <- timeout 5000000 (atomically (readTVar received >>= \items -> if null items then retry else pure ()))
      check "stream delivers the invalidation before the close" (arrived == Just ())
      C.closeClient client
      outcome <- timeout 5000000 (wait stream)
      check "closeClient ends an open stream with ClientClosed" (outcome == Just (Left C.ClientClosed))
    ["stream-gone",profile] -> withClient profile $ \client -> do
      result <- C.streamEvents client "stream_fixture.0" (const (pure ()))
      check "expired stream cursor gives the 410 problem" (result == Left (C.Refused 410 "cursor-expired"))
    ["overview",profile] -> withClient profile $ \client -> do
      overview <- C.loadOverview client >>= right
      check "overview assembles every page with one cursor"
        (C.overviewCursor overview == "stream_fixture.7" && C.overviewOldestCursor overview == "stream_fixture.0"
          && [(C.overviewKind item, C.referenceURI (C.overviewResource item), C.overviewRevision item) | item <- C.overviewItems overview]
            == [(C.OverviewRequest, "/v1/requests/request_probe", "revision_probe"), (C.OverviewRun, "/v1/runs/run_probe", "revision_run")])
    ["bad-overview",profile] -> withClient profile $ \client -> do
      result <- C.loadOverview client
      check "overview whose pages differ in cursor refuses" (case result of Left C.InvalidResponse -> True; _ -> False)
    ["vectors",path] -> BS.readFile path >>= either (die . ("vector file: " <>))
      (\root -> eventVectors root >> resourceVectors root >> refreshVectors root)
      . eitherDecodeStrict
    _ -> die "usage: manager-client-check MODE ABS_CLIENT_PROFILE [FAILURE_KIND] | manager-client-check vectors PATH"

-- | Record each stream item, newest first.
collect :: TVar [C.StreamItem] -> C.StreamItem -> IO ()
collect received item = atomically (modifyTVar' received (item :))

-- | The invalidation that the native stream fixture serves.
fixtureEvent :: C.InvalidationEvent
fixtureEvent = C.InvalidationEvent "stream_fixture.1" C.RequestChanged (C.Invalidation "/v1/requests/request_probe" "revision_probe")

-- | The idle bound of the live-delivery case against the running manager,
-- shorter than the 15-second heartbeat interval, so that the stream ends
-- after the last event and the check stays inside its 30-second timeout.
realIdleMilliseconds :: Int
realIdleMilliseconds = 4000

-- | Live delivery against the running manager: bootstrap from the overview,
-- stream from its cursor, create a request, and require its request.changed
-- invalidation on the stream and in polling from the same cursor. The
-- request is then withdrawn, so that the overview is empty again.
liveDelivery :: C.Client -> Value -> IO ()
liveDelivery client workflow = do
  overview <- C.loadOverview client >>= right
  let cursor = C.overviewCursor overview
  check "overview bootstrap gives a cursor and an oldest cursor"
    (C.validCursor cursor && C.validCursor (C.overviewOldestCursor overview))
  received <- newTVarIO []
  stream <- async (C.streamEventsWithin realIdleMilliseconds client cursor (collect received))
  requestsURI <- right (C.reference client "/v1/requests")
  pending <- C.prepareCommand client requestsURI Nothing (object
    [ "workflowId" .= field "id" workflow, "descriptorRevision" .= field "revision" workflow,
      "profileId" .= field "profileId" workflow, "profileRevision" .= field "profileRevision" workflow ]) >>= right
  created <- C.sendCommand client pending >>= right
  check "public client creates a request through prepareCommand and sendCommand" (C.responseStatus created == 201)
  let resource = "/v1/requests/" <> string (field "id" (C.responseValue created))
      matching item = case item of
        C.StreamInvalidation event -> C.invalidationEventName event == C.RequestChanged
          && C.invalidationResource (C.invalidationEventData event) == resource
        C.StreamHeartbeat -> False
  refreshed <- C.loadOverview client >>= right
  check "overview holds the created request with its kind and detail resource"
    ([C.overviewKind item | item <- C.overviewItems refreshed, C.referenceURI (C.overviewResource item) == resource]
      == [C.OverviewRequest])
  streamed <- timeout 10000000 (atomically (readTVar received >>= maybe retry pure . find matching))
  event <- case streamed of
    Just (C.StreamInvalidation event) -> pure event
    _ -> die "FAIL the stream did not deliver the request.changed invalidation within 10 seconds"
  check "streamEvents delivers the request.changed invalidation of the created request" True
  let pollFrom position remaining = do
        batch <- C.pollEventBatch client position >>= right
        if event `elem` C.batchEvents batch || not (C.batchHasMore batch) || remaining <= (0 :: Int)
          then pure (event `elem` C.batchEvents batch)
          else pollFrom (C.batchCursor batch) (remaining - 1)
  polled <- pollFrom cursor 8
  check "polling from the same cursor delivers the same event" polled
  ended <- timeout 10000000 (wait stream)
  items <- readTVarIO received
  let lastStreamed = case [ident | C.StreamInvalidation (C.InvalidationEvent ident _ _) <- items] of
        newest : _ -> newest
        [] -> cursor
  check "idle stream ends after its bound with the last complete event identifier" (ended == Just (Right lastStreamed))
  requestURI <- right (C.reference client resource)
  observed <- C.observeResource client requestURI >>= right
  withdraw <- C.prepareObserved client observed (object ["operation" .= ("withdraw" :: Text)]) >>= right
  withdrawn <- C.sendCommand client withdraw >>= right
  check "public client withdraws the created request" (C.responseStatus withdrawn == 202)
  let settled remaining = do
        current <- C.observeResource client requestURI >>= right
        if field "phase" (C.observedValue current) == String "withdrawn" then pure True
          else if remaining <= (0 :: Int) then pure False
          else threadDelay 100000 >> settled (remaining - 1)
  settled 100 >>= check "the created request reaches the withdrawn phase"

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

-- | The refresh section of test/manager_client_vectors.json: scripted
-- coordinator sequences, reconnection backoff, jitter and reconciliation.
refreshVectors :: Value -> IO ()
refreshVectors root = do
  let section = field "refresh" root
      counted name = do
        let items = members name section
        when (null items) (die ("FAIL vector section refresh." <> T.unpack name <> " is empty"))
        pure items
  counted "sequences" >>= mapM_ refreshSequence
  counted "backoff" >>= mapM_ backoffVector
  counted "jitter" >>= mapM_ jitterVector
  counted "reconciliation" >>= mapM_ reconcileVector

integerField :: Value -> Maybe Integer
integerField (Number value) = Just (round value)
integerField _ = Nothing

-- One action of a sequence step: kind, resource key and generation.
expectedAction :: String -> Value -> IO (C.RefreshAction Text)
expectedAction label value = case value of
  Array items | [String kind, String key, Number generation] <- toList items ->
    let at = C.FetchGeneration (round generation) in case kind of
      "fetch" -> pure (C.StartFetch key at)
      "install" -> pure (C.InstallFetch key at)
      "discard" -> pure (C.DiscardFetch key at)
      _ -> die ("FAIL " <> label <> " names an unknown action")
  _ -> die ("FAIL " <> label <> " has a malformed action")

-- Run a coordinator sequence. Each step states its exact actions. Every step
-- also keeps the coordinator rules: an install has the current generation, a
-- completion of another generation never installs, an invalidation of a
-- resource in flight starts nothing, a completion starts at most one fetch,
-- and an advance leaves every resource idle.
refreshSequence :: Value -> IO ()
refreshSequence vector = do
  let label = vectorLabel "refresh sequence" vector
  final <- foldlM (\state (index, step) -> do
    let stepLabel = label <> " step " <> show (index :: Int)
        current = C.refreshGeneration state
    expected <- mapM (expectedAction stepLabel) (members "actions" step)
    (next, actions, rule) <- case (text (field "invalidate" step), text (field "complete" step)) of
      (Just key, Nothing) -> do
        let (next, actions) = C.invalidateResource key state
            inFlight = Map.member key (C.refreshFlights state)
        pure (next, actions, if inFlight then null actions else actions == [C.StartFetch key current])
      (Nothing, Just key) -> do
        generation <- maybe (die ("FAIL " <> stepLabel <> " has no generation")) (pure . C.FetchGeneration . fromInteger)
          (integerField (field "generation" step))
        let (next, actions) = C.completeFetch key generation state
            installs = [at | C.InstallFetch _ at <- actions]
            fetches = [() | C.StartFetch _ _ <- actions]
        pure (next, actions, all (== current) installs && (generation == current || null installs) && length fetches <= 1)
      (Nothing, Nothing) | bool "resnapshot" step || bool "endpointSwitch" step -> do
        let next = C.advanceGeneration state
            C.FetchGeneration before = current
        pure (next, [], Map.null (C.refreshFlights next)
          && integerField (field "generation" step) == Just (toInteger before + 1)
          && C.refreshGeneration next == C.FetchGeneration (before + 1))
      _ -> die ("FAIL " <> stepLabel <> " names no single step kind")
    unless (actions == expected) (die ("FAIL " <> stepLabel <> ": " <> show actions))
    unless rule (die ("FAIL " <> stepLabel <> " breaks a coordinator rule"))
    pure next) C.newRefresh (zip [1 ..] (members "steps" vector))
  check (label <> " ending at " <> show (C.refreshGeneration final)) True

-- A backoff vector: the delay of each failure in order, every delay within one
-- second and the cap, and a delivered event resets the next delay to one second.
backoffVector :: Value -> IO ()
backoffVector vector = do
  let label = vectorLabel "backoff" vector
      run (backoff, delivered, delays) step = case step of
        String "failure" -> do
          let (delay, next) = C.reconnectDelay backoff
          when (delivered && delay /= 1) (die ("FAIL " <> label <> ": no reset after delivery"))
          pure (next, False, delays <> [delay])
        String "delivered" -> pure (C.initialBackoff, True, delays)
        _ -> die ("FAIL " <> label <> " has an unknown step")
  (_, _, delays) <- foldlM run (C.initialBackoff, False, []) (members "steps" vector)
  let expected = [fromInteger delay | Just delay <- map integerField (members "delays" vector)]
  check label (delays == expected && C.reconnectBackoffMaxSeconds == 30
    && all (\delay -> delay >= 1 && delay <= C.reconnectBackoffMaxSeconds) delays)

jitterVector :: Value -> IO ()
jitterVector vector = case (integerField (field "seconds" vector), field "fraction" vector, integerField (field "microseconds" vector)) of
  (Just seconds, Number fraction, Just expected) -> do
    let delayed = C.jitteredMicroseconds (fromInteger seconds) (realToFrac fraction)
    check (vectorLabel "jitter" vector) (toInteger delayed == expected
      && toInteger delayed <= 1000000 * toInteger C.reconnectBackoffMaxSeconds && 2 * toInteger delayed >= 1000000 * seconds)
  _ -> die ("FAIL " <> vectorLabel "jitter" vector <> " is malformed")

-- A reconciliation vector. The read is the receipt location when one is
-- known and otherwise the target. A command that stays uncertain comes back
-- unchanged with its exact bytes, key and precondition, and no report sends.
reconcileVector :: Value -> IO ()
reconcileVector vector = do
  let label = vectorLabel "reconciliation" vector
      observation = field "observation" vector
  target <- maybe (die ("FAIL " <> label <> " has no target")) pure (text (field "target" vector))
  observed <- case (field "receiptState" observation, field "targetETag" observation, field "failure" observation) of
    (state@(String _), Null, Null) -> either (const (die ("FAIL " <> label <> " names an unknown receipt state"))) (pure . C.ObservedReceipt)
      (C.decodeObservation state)
    (Null, String etag, Null) -> pure (C.ObservedTarget etag (bool "effectVisible" observation))
    (Null, Null, failure) -> C.ObservedFailure <$> case failure of
      String "InvalidResponse" -> pure C.InvalidResponse
      String "TransportUnavailable" -> pure C.TransportUnavailable
      Object _ | [Number status, String code] <- members "refused" failure -> pure (C.Refused (round status) code)
      _ -> die ("FAIL " <> label <> " names an unknown failure")
    _ -> die ("FAIL " <> label <> " has a malformed observation")
  let uncertain = C.Uncertain (field "command" vector) target (text (field "precondition" vector)) (text (field "receipt" vector))
      read' = case C.reconcileRead uncertain of
        C.ReadReceipt location -> ("receipt", location)
        C.ReadTarget location -> ("target", location)
      expectedRead = case text (field "receipt" vector) of
        Just location -> ("receipt", location)
        Nothing -> ("target", target)
      outcome = C.reconcile uncertain observed
      report = case outcome of
        C.ReconciledEffect -> "effect-observed"
        C.ReconciledRefused -> "refused"
        C.ReconciledUncertain _ -> "uncertain"
      retained = case outcome of
        C.ReconciledUncertain kept -> kept == uncertain && C.uncertainCommand kept == field "command" vector
        _ -> True
  check label (read' == expectedRead && Just (fst read') == text (field "read" vector)
    && Just report == text (field "report" vector) && retained)
