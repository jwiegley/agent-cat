{-# LANGUAGE OverloadedStrings #-}

-- | Authorized projections of the existing durable invalidation stream.
module Agentic.Manager.Events
  ( CursorBinding, captureBinding, bindingEpoch, durableStream, publicStreamId, cursorAt, withBatch, withBoundary,
    StreamReaders, newStreamReaders, StreamPump, withStream ) where

import Agentic.Manager.Authorization
import Agentic.Manager.Profile (ConfigurationLimits, PublicProfile)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Store
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar, modifyTVar', throwSTM)
import Control.DeepSeq (NFData)
import Control.Exception (bracket_, throwIO)
import Control.Monad (forM, unless, when, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import qualified Database.SQLite3 as SQL
import Text.Read (readMaybe)
import GHC.Clock (getMonotonicTimeNSec)
import System.Timeout (timeout)

-- The fields remain distinct. The public alias is an equality fingerprint,
-- never a credential or a reconstruction of any live owner.
data CursorBinding = CursorBinding
  { durableStream :: !Text, bindingEpoch :: !Text, bindingView :: !Text,
    bindingGrants :: !(Map.Map Text [Scope]) }

publicStreamId :: CursorBinding -> Text
publicStreamId binding = "stream_" <> T.pack (show (hash (encoded
  ((1 :: Int), durableStream binding, bindingEpoch binding, bindingView binding)) :: Digest SHA256))

cursorAt :: CursorBinding -> Word64 -> Text
cursorAt binding number = publicStreamId binding <> "." <> T.pack (show number)

captureBinding :: CredentialProof -> [PublicProfile] -> Text -> Transaction CursorBinding
captureBinding proof profiles expectedView = do
  (view, grants) <- catalogueAuthorization proof profiles
  unless (view == expectedView) (refuseTransaction ViewExpired)
  rows <- query "SELECT stream_id,authority_epoch FROM service_metadata WHERE singleton=1" []
  case rows of
    [[SQL.SQLText stream, SQL.SQLText epoch]] -> do
      unless (validId stream && validId epoch) (refuseTransaction StoreIntegrity)
      pure (CursorBinding stream epoch view (Map.fromList grants))
    _ -> refuseTransaction StoreIntegrity

-- | Capture an overview and both replay boundaries in the same authorized
-- transaction. Materialization and response sending happen outside SQL while
-- the caller still holds its original response view.
withBoundary :: NFData a => CoordinationStore -> CredentialProof
  -> ([Text] -> Text -> Text -> Transaction a)
  -> (AuthorizedView -> ConfigurationLimits -> a -> IO b) -> IO b
withBoundary store proof capture respond =
  withAuthorizedCatalogues store proof [Observe] $ \view limits profiles _ -> do
    revision <- authorizedCursorRevision view
    let prepare = do
          binding <- captureBinding proof (map fst profiles) revision
          pure (durableStream binding, Nothing, binding)
        project binding batch = capture (Map.keys (bindingGrants binding))
          (cursorAt binding (retainedHighWater batch)) (cursorAt binding (retainedFloor batch))
    result <- readRetainedEventsWith store prepare project >>= either refuse pure
    revalidateAuthorizedView view >>= either throwIO pure
    respond view limits result

-- | Check authority, view, floor and future positions with bounded selection.
-- Advance over scanned records, including filtered gaps, never unscanned work.
withBatch :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> Value -> IO a) -> IO a
withBatch store proof supplied respond =
  withAuthorizedCatalogues store proof [Observe] $ \view _ profiles _ ->
    readBatch store proof supplied view (map fst profiles) >>= respond view

readBatch :: CoordinationStore -> CredentialProof -> Text -> AuthorizedView -> [PublicProfile] -> IO Value
readBatch store proof supplied view profiles = do
    revision <- authorizedCursorRevision view
    (alias, position) <- either throwIO pure (parseCursor supplied)
    let prepare = do
          binding <- captureBinding proof profiles revision
          unless (alias == publicStreamId binding) (refuseTransaction ViewExpired)
          pure (durableStream binding, Just position, binding)
        project binding batch = do
          visible <- visibleResources (bindingGrants binding) (retainedEvents batch)
          let records = retainedEvents batch
              after = case reverse records of (number,_,_,_):_ -> number; [] -> position
              event (number,kind,resource,version) = object
                ["id" .= cursorAt binding number, "event" .= kind,
                 "data" .= object ["version" .= (1 :: Int),
                   "resource" .= (if kind == "service.changed" then "/v1/capabilities" else resource),
                   "revision" .= version]]
              allowed (_,kind,resource,_) = kind == "service.changed" || resource `Set.member` visible
              value = object ["version" .= (1 :: Int), "cursor" .= cursorAt binding after,
                "oldestCursor" .= cursorAt binding (retainedFloor batch),
                "events" .= map event (filter allowed records), "hasMore" .= (after < retainedHighWater batch)]
          when (BS.length (encoded value) > 1048576) (refuseTransaction ViewTooLarge)
          pure value
    result <- readRetainedEventsWith store prepare project >>= either refuse pure
    revalidateAuthorizedView view >>= either throwIO pure
    pure result

-- | Active per-client subscriptions of one application lifetime. Global reader
-- capacity remains charged by the original Store watch for the whole stream.
newtype StreamReaders = StreamReaders (TVar (Map.Map Text Int))

newStreamReaders :: IO StreamReaders
newStreamReaders = StreamReaders <$> newTVarIO Map.empty

type StreamPump = (AuthorizedView -> Value -> IO ()) -> (AuthorizedView -> IO ()) -> IO ()

-- | Validate before response entry, then lend one single-use pump to the actual
-- response callback. Writers finish within each batch's configuration/view loan.
-- Waiting never retains configuration, SQL, or a worker pipe.
withStream :: StreamReaders -> CoordinationStore -> CredentialProof -> Text
  -> (StreamPump -> IO a) -> IO a
withStream (StreamReaders readers) store proof supplied action = do
  client <- runRead store (currentClient proof) >>= either throwIO pure
  let acquire = atomically $ do
        counts <- readTVar readers
        let count = Map.findWithDefault 0 client counts
        when (count >= 2) (throwSTM StorageQuota)
        writeTVar readers (Map.insert client (count + 1) counts)
      release = atomically $ modifyTVar' readers (Map.update (\count -> if count == 1 then Nothing else Just (count - 1)) client)
  bracket_ acquire release $ withStoreAuthorizationWatch store $ \watch -> do
    initial <- withBorrowedAuthorizedCatalogues watch proof [Observe] $ \view _ profiles _ -> do
      void (readBatch store proof supplied view (map fst profiles))
      authorizedViewRevision view
    used <- newTVarIO False
    action $ \send heartbeat -> do
      atomically $ do
        started <- readTVar used
        when started (throwSTM StateConflict)
        writeTVar used True
      loop watch initial supplied Nothing send heartbeat
  where
    loop watch initial cursor lastWrite send heartbeat = do
      (next, more, written) <- withBorrowedAuthorizedCatalogues watch proof [Observe] $ \view _ profiles _ -> do
        current <- authorizedViewRevision view
        unless (current == initial) (throwIO ViewExpired)
        batch <- readBatch store proof cursor view (map fst profiles)
        (next, more, populated) <- case batch of
          Object fields | Just (String next) <- KM.lookup "cursor" fields,
            Just (Bool more) <- KM.lookup "hasMore" fields, Just (Array events) <- KM.lookup "events" fields ->
              pure (next,more,not (null events))
          _ -> throwIO StoreIntegrity
        now <- getMonotonicTimeNSec
        let due = maybe True (\previous -> now - previous >= 15000000000) lastWrite
        when (populated || due) $ do
          revalidateAuthorizedView view >>= either throwIO pure
          result <- timeout 5000000 (if populated then send view batch else heartbeat view)
          maybe (throwIO StorageUnavailable) pure result
        pure (next,more,if populated || due then Just now else lastWrite)
      unless more $ do
        alive <- withAuthorizationObservation watch (pure ())
        unless (alive == Just ()) (throwIO StoreClosed)
        awaitAuthorizationChange watch
      loop watch initial next written send heartbeat

refuse :: EventReadFailure -> IO a
refuse failure = throwIO $ case failure of
  WrongEventStream -> ViewExpired
  EventRetentionLost -> CursorExpired
  EventCursorAhead -> CursorExpired

parseCursor :: Text -> Either CommandFailure (Text, Word64)
parseCursor value = do
  let (prefix, suffix) = T.breakOnEnd "." value
      stream = T.dropEnd 1 prefix
  unless (validId stream && not (T.null prefix) && T.length value <= 149) (Left InvalidRequest)
  number <- maybe (Left InvalidRequest) Right (readMaybe (T.unpack suffix) :: Maybe Integer)
  unless (number >= 0 && number <= 18446744073709551615 && T.pack (show number) == suffix) (Left InvalidRequest)
  pure (stream, fromInteger number)

-- These are resource associations, not execution capabilities. At most64 input
-- records share these bounded lookups and the authorization snapshot above.
visibleResources :: Map.Map Text [Scope] -> [(Word64, Text, Text, Text)] -> Transaction (Set.Set Text)
visibleResources grants records = do
  let addresses = [(resource, parts resource) | (_,_,resource,_) <- records]
      wanted collection = Set.toList (Set.fromList [ident | (_, (name,ident)) <- addresses, name == collection])
      lookupRows collection sql = case wanted collection of
        [] -> pure []
        identifiers -> query sql [SQL.SQLText (TE.decodeUtf8 (encoded identifiers))]
      allowedProfile profile scopes = all (`elem` Map.findWithDefault [] profile grants) scopes
      pairs rows = forM rows $ \row -> case row of
        [SQL.SQLText ident, SQL.SQLText profile] -> pure (ident, profile)
        _ -> refuseTransaction StoreIntegrity
  requests <- lookupRows "requests" "SELECT id,profile_id FROM requests WHERE id IN (SELECT value FROM json_each(?))" >>= pairs
  preparations <- lookupRows "preparations" "SELECT p.id,r.profile_id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id IN (SELECT value FROM json_each(?))" >>= pairs
  runs <- lookupRows "runs" "WITH wanted(id) AS (SELECT value FROM json_each(?)) SELECT id,profile_id FROM runs WHERE id IN wanted UNION ALL SELECT id,profile_id FROM history_entries WHERE id IN wanted" >>= pairs
  decisions <- lookupRows "decisions" "SELECT d.id,r.profile_id FROM decisions d JOIN runs r ON r.id=d.run_id WHERE d.id IN (SELECT value FROM json_each(?))" >>= pairs
  artifacts <- lookupRows "artifacts" "WITH wanted(id) AS (SELECT value FROM json_each(?)) SELECT a.id,r.profile_id FROM artifacts a JOIN runs r ON r.id=a.run_id WHERE a.id IN wanted UNION ALL SELECT 'artifact_'||e.id,e.profile_id FROM history_entries e JOIN history_results r ON r.entry_id=e.id WHERE 'artifact_'||e.id IN wanted" >>= pairs
  commands <- lookupRows "commands" "SELECT id,profile_id,operation FROM commands WHERE id IN (SELECT value FROM json_each(?))" >>= mapM (\row -> case row of
    [SQL.SQLText ident,SQL.SQLText profile,SQL.SQLText operation] -> case parseOperation operation of
      Just kind -> pure (ident, allowedProfile profile (Observe : requiredScopes kind))
      Nothing -> refuseTransaction StoreIntegrity
    _ -> refuseTransaction StoreIntegrity)
  let readable = Map.fromList
        [(collection, Set.fromList [ident | (ident,profile) <- rows, allowedProfile profile [Observe]])
          | (collection, rows) <- [("requests", requests), ("preparations", preparations), ("runs", runs),
              ("decisions", decisions), ("artifacts", artifacts)]]
      commandIds = Set.fromList [ident | (ident, True) <- commands]
      visible (collection, ident)
        | collection == "commands" = ident `Set.member` commandIds
        | otherwise = ident `Set.member` Map.findWithDefault Set.empty collection readable
  pure (Set.fromList [uri | (uri, address) <- addresses, visible address])
  where
    parts uri = case T.splitOn "/" uri of
      "":"v1":collection:ident:_ | validId ident -> (collection, ident)
      _ -> ("", "")
