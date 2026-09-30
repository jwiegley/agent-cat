{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

-- | The route resources: authorized windows of the run log of one managed
-- run, and of the manager log of the current Store stream, served by route
-- class.
--
-- A run batch reads the run log @flow.ndjson@ of the run store of the run
-- with the positioned window reader of the runtime. A manager batch reads the
-- manager log of the stream of the Store, its sealed segments and its active
-- file, with the positioned window reader of "Agentic.Manager.Flow". Neither
-- reads the whole log, opens a claim-check file, takes the writer lock of the
-- manager log or writes to the coordination store. The cursor alias binds the
-- public stream identity of the event stream of the credential and the log: a
-- public run identifier, or the manager log. A served record at position @p@
-- has the identifier @ALIAS.(p+1)@, and a cursor names the next position to
-- read.
--
-- A route stream serves the same batches as server-sent events. Each served
-- record is one block, and the stream reads its next batch after a wakeup.
-- The wakeup only requests a durable read: it carries no record and no
-- position.
module Agentic.Manager.Routes
  ( routeAlias, managerRouteAlias, withRouteBatch, withManagerRouteBatch,
    RoutePump, withRouteStream, withManagerRouteStream ) where

import Agentic.Manager.Artifacts (withRunRoot)
import Agentic.Manager.Authorization
import Agentic.Manager.Events (StreamReaders, bindingGrants, captureBinding, durableStream, parseCursor, publicStreamId, streamsClosing, withStreamReader)
import Agentic.Manager.Fault (FaultClass (InternalFault), ManagerFault (ResponseWriteTimeout), refuseStorageUnavailable)
import Agentic.Manager.Flow (ManagerWindow (..), managerFlowAppends, readManagerWindow)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.State (RunAssociation (..), resolveRunIn)
import Agentic.Manager.Store
import Agentic.Runtime
  ( About (..), FlowRoute, FlowWindow (..), FlowWindowEntry (..), FlowWindowRefusal (..), Position (..),
    PrivateRoot, Record (..), RouteClass (..), Schema (FlowCommand, FlowNotice, FlowReceipt, FlowRelay, FlowReview),
    flowRouteMatches, flowWindowEntryFields, flowWindowLimits, readFlowWindow, runIdText, runLogName, schemaRouteClass )
import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVar, registerDelay, retry, throwSTM, writeTVar)
import Control.DeepSeq (NFData (rnf))
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import qualified Database.SQLite3 as SQL
import GHC.Clock (getMonotonicTimeNSec)
import System.IO.Error (isDoesNotExistError)
import System.Timeout (timeout)

-- | The cursor alias of the run route of one run for the public stream
-- identity of a credential. It is an equality fingerprint, never a
-- credential, a file identity or a reconstruction of a live owner.
routeAlias :: Text -> Text -> Text
routeAlias stream run = aliasOf stream ("run:" <> run)

-- | The cursor alias of the manager route for the public stream identity of
-- a credential. It names no segment and no file, so a seal or a prune keeps
-- a cursor valid. A restoration gives a new stream identity, and with it a
-- new alias.
managerRouteAlias :: Text -> Text
managerRouteAlias stream = aliasOf stream "manager"

aliasOf :: Text -> Text -> Text
aliasOf stream subject = "route_" <> T.pack (show (hash (encoded ((1 :: Int), stream, subject)) :: Digest SHA256))

-- | Read one route batch of the run log of the run and lend it, with the
-- response view, to the response callback.
--
-- The Store file slot, the configuration loan and one read transaction are
-- taken in the lock order file slot, configuration, database. The read
-- transaction authenticates, resolves the run under @observe@, captures the
-- event-stream binding of the credential and reads whether the credential
-- also holds @control@ on the profile of the run. The file slot joins the
-- response loans, so the response returns it before its first network write.
--
-- An absent cursor starts at position 0. A cursor with another alias refuses
-- with 'ViewExpired'. A position after the last complete record refuses with
-- 'CursorExpired'. The floor of a run log is 0, so no position lies below it.
withRouteBatch :: CoordinationStore -> CredentialProof -> Text -> Maybe Text -> Maybe FlowRoute
  -> (AuthorizedView -> Value -> IO a) -> IO a
withRouteBatch store proof ident supplied route respond =
  withStoreFileLoan store $ \files root ->
    withAuthorizedCatalogues store proof [Observe] $ \view _ profiles _ -> do
      attachResponseLoan view files
      revision <- authorizedCursorRevision view
      (association, stream, control) <- runRead store $ do
        association <- resolveRunIn proof [Observe] ident
        binding <- captureBinding proof (map fst profiles) revision
        control <- authorizeProfile proof (associationProfile association) [Control]
        pure (association, publicStreamId binding, either (const False) (const True) control)
      let alias = routeAlias stream (associationRun association)
      start <- cursorStart alias supplied
      batch <- withRunRoot root association $ \runs ->
        routeBatch alias route (runSource runs association control) start
      revalidateAuthorizedView view >>= either throwIO pure
      respond view batch

-- | Read one route batch of the manager log of the current Store stream and
-- lend it, with the response view, to the response callback.
--
-- The Store file slot, the configuration loan and the read transactions are
-- taken in the lock order file slot, configuration, database. The first read
-- transaction captures the event-stream binding of the credential, with its
-- grants on the configured profiles. The file slot joins the response loans,
-- so the response returns it before its first network write. The log is read
-- with 'readManagerWindow', never under the writer lock of the manager log.
--
-- An absent cursor starts at the retained floor of the log. A cursor with
-- another alias refuses with 'ViewExpired'. A position below the retained
-- floor or after the last complete record refuses with 'CursorExpired'.
withManagerRouteBatch :: CoordinationStore -> CredentialProof -> Maybe Text -> Maybe FlowRoute
  -> (AuthorizedView -> Value -> IO a) -> IO a
withManagerRouteBatch store proof supplied route respond =
  withStoreFileLoan store $ \files root ->
    withAuthorizedCatalogues store proof [Observe] $ \view _ profiles _ -> do
      attachResponseLoan view files
      revision <- authorizedCursorRevision view
      (public, stream, grants) <- runRead store $ do
        binding <- captureBinding proof (map fst profiles) revision
        pure (publicStreamId binding, durableStream binding, bindingGrants binding)
      let alias = managerRouteAlias public
      start <- cursorStart alias supplied
      batch <- routeBatch alias route (managerSource store root stream grants) start
      revalidateAuthorizedView view >>= either throwIO pure
      respond view batch

-- The position that a supplied cursor names, or nothing without a cursor. A
-- cursor with another alias refuses with 'ViewExpired'.
cursorStart :: Text -> Maybe Text -> IO (Maybe Word64)
cursorStart alias = \case
  Nothing -> pure Nothing
  Just cursor -> do
    (given, position) <- either throwIO pure (parseCursor cursor)
    unless (given == alias) (throwIO ViewExpired)
    pure (Just position)

-- | Where a route batch reads its records. A window reader gives, for a
-- position, the retained floor of the log and the window from that position.
-- A visibility reader gives, for the entries of one window, the class name
-- under which the principal receives each entry, or nothing when the entry is
-- omitted.
data RouteSource = RouteSource
  { sourceWindow :: Position -> IO (Position, Either FlowWindowRefusal FlowWindow),
    sourceServed :: [FlowWindowEntry] -> IO (FlowWindowEntry -> Maybe Text)
  }

-- The run log of the run store of the run. Its floor is 0. A log that does
-- not exist yet holds no record. Every record is served by its route class
-- alone, because the profile of every record is the profile of the run.
runSource :: PrivateRoot -> RunAssociation -> Bool -> RouteSource
runSource runs association control = RouteSource window (const (pure served))
  where
    path = ["runs", T.unpack (runIdText (associationNative association)), "runtime", runLogName]
    served entry = servedClass control (schemaRouteClass (recSchema (windowRecord entry)))
    window cursor = do
      found <- try @IOException (readFlowWindow runs path (Position 0) cursor flowWindowLimits)
      (,) (Position 0) <$> case found of
        Left failure
          | isDoesNotExistError failure && positionIndex cursor == 0 -> pure (Right (FlowWindow [] cursor False 0))
          | isDoesNotExistError failure -> pure (Left (FlowWindowAhead (Position 0)))
          | otherwise -> throwIO failure
        Right result -> pure result

-- The manager log of the stream. Each record is served by its route class
-- and by the grants of the credential on the profile of the record, which one
-- read transaction per window resolves from the identifiers of its About, as
-- 'recordOwner' states. A record whose profile does not resolve is omitted.
managerSource :: CoordinationStore -> PrivateRoot -> Text -> Map.Map Text [Scope] -> RouteSource
managerSource store root stream grants = RouteSource window served
  where
    window cursor = do
      found <- readManagerWindow root stream cursor flowWindowLimits
      pure (managerWindowFloor found, managerWindowResult found)
    served entries = do
      owners <- runRead store (recordProfiles (mapMaybe recordOwner entries))
      pure $ \entry -> do
        owner <- recordOwner entry
        profile <- Map.lookup owner owners
        let scopes = Map.findWithDefault [] profile grants
        unless (Observe `elem` scopes) Nothing
        servedClass (Control `elem` scopes) (schemaRouteClass (recSchema (windowRecord entry)))

-- | The kind of the coordination row whose profile is the profile of a
-- manager-log record.
data OwnerKind = CommandOwner | RequestOwner | RunOwner
  deriving (Eq, Ord, Show)

instance NFData OwnerKind where
  rnf kind = kind `seq` ()

-- | The row that owns a manager-log record. A command and a receipt belong to
-- the command that their About names. A @command-changed@ notice belongs to
-- its command. A review, a @review-ended@ notice and a @request-ended@ notice
-- belong to their request. A start or a control relay belongs to its manager
-- run. A discard relay belongs to its request: the relay codec requires that
-- a start and a control relay name a manager run and that a discard relay
-- name none. Every other record, such as an administration command, its
-- receipt, and the lifetime, shutdown and gap notices, has no owner. A notice
-- whose body is a claim check has no owner either.
recordOwner :: FlowWindowEntry -> Maybe (OwnerKind, Text)
recordOwner entry = case recSchema record of
  FlowCommand -> (,) CommandOwner <$> aboutCommand about
  FlowReceipt -> (,) CommandOwner <$> aboutCommand about
  FlowReview -> (,) RequestOwner <$> aboutRequest about
  FlowRelay -> case aboutManagerRun about of
    Just run -> Just (RunOwner, run)
    Nothing -> (,) RequestOwner <$> aboutRequest about
  FlowNotice -> case windowBody entry of
    Just (Object fields) -> case KM.lookup "notice" fields of
      Just (String "command-changed") -> (,) CommandOwner <$> aboutCommand about
      Just (String kind) | kind `elem` ["review-ended", "request-ended"] -> (,) RequestOwner <$> aboutRequest about
      _ -> Nothing
    _ -> Nothing
  _ -> Nothing
  where
    record = windowRecord entry
    about = recAbout record

-- | The profiles of the owners, by read-only lookups batched per owner kind:
-- @commands.profile_id@, @requests.profile_id@ and @runs.profile_id@. An owner
-- without a row, such as a command whose transaction rolled back, is absent.
recordProfiles :: [(OwnerKind, Text)] -> Transaction (Map.Map (OwnerKind, Text) Text)
recordProfiles owners = do
  found <- forM [(CommandOwner, "commands"), (RequestOwner, "requests"), (RunOwner, "runs")] $ \(kind, table) ->
    case Set.toList (Set.fromList [ident | (owned, ident) <- owners, owned == kind]) of
      [] -> pure []
      identifiers -> do
        rows <- query ("SELECT id,profile_id FROM " <> table <> " WHERE id IN (SELECT value FROM json_each(?))")
          [SQL.SQLText (TE.decodeUtf8 (encoded identifiers))]
        forM rows $ \case
          [SQL.SQLText ident, SQL.SQLText profile] -> pure ((kind, ident), profile)
          _ -> refuseTransaction StoreIntegrity
  pure (Map.fromList (concat found))

-- | The class name under which a principal receives a record of the route
-- class, or nothing when the record is omitted. Public records reach every
-- principal with @observe@. Actor records also need @control@. Restricted
-- records are never served.
servedClass :: Bool -> RouteClass -> Maybe Text
servedClass control = \case
  PublicRoute -> Just "public"
  ActorRoute | control -> Just "actor"
  ActorRoute -> Nothing
  RestrictedRoute -> Nothing

-- | The most windows that one batch reads while every record it meets is a
-- filtered gap. With the window bounds of 'flowWindowLimits' one batch scans
-- at most 1024 records.
routeScanWindows :: Int
routeScanWindows = 16

-- | The encoded bytes that a batch keeps for its served records. The rest of
-- the 1048576-byte page holds the fields of the batch.
routeRecordBytes :: Int
routeRecordBytes = 1048576 - 1024

-- Read windows of the log from the start position. A window whose records
-- are all filtered gaps is followed by the next one, up to
-- 'routeScanWindows'. The batch ends after the first window that serves a
-- record, before the first record that would exceed 'routeRecordBytes', or
-- at the end of the complete records. The oldest cursor names the retained
-- floor that the last window reported. Without a start position the batch
-- starts at the retained floor: it reads from position 0, and a refusal below
-- the floor starts it again at the floor.
routeBatch :: Text -> Maybe FlowRoute -> RouteSource -> Maybe Word64 -> IO Value
routeBatch alias route source start = scan 1 (Position (fromMaybe 0 start))
  where
    cursorAt position = alias <> "." <> T.pack (show position)
    scan :: Int -> Position -> IO Value
    scan windows cursor = do
      (floor', window) <- sourceWindow source cursor
      case window of
        Left (FlowWindowBelowFloor retained) | isNothing start && windows == 1 && cursor < retained -> scan windows retained
        Left (FlowWindowAhead _) -> throwIO CursorExpired
        Left (FlowWindowBelowFloor _) -> throwIO CursorExpired
        Left (FlowWindowUndecodable _ _) -> throwIO StoreIntegrity
        Right result -> do
          served <- sourceServed source (windowEntries result)
          case collect (visible served) [] 0 (windowEntries result) of
            (records, Just stop) -> pure (batch floor' records stop True)
            (records, Nothing)
              | null records && windowMore result && windows < routeScanWindows -> scan (windows + 1) (windowNext result)
              | otherwise -> pure (batch floor' records (windowNext result) (windowMore result))
    -- The served records of the entries in order, and the position of the
    -- first entry that the batch leaves for the next one.
    collect _ done _ [] = (reverse done, Nothing)
    collect shown done used (entry : rest) = case shown entry of
      Nothing -> collect shown done used rest
      Just name ->
        let value = object (("id" .= cursorAt (positionIndex (windowPosition entry) + 1)) : ("class" .= name)
              : flowWindowEntryFields entry)
            size = BS.length (encoded value) + 1
         in if used + size > routeRecordBytes && not (null done)
              then (reverse done, Just (windowPosition entry))
              else collect shown (value : done) (used + size) rest
    visible served entry = do
      name <- served entry
      unless (maybe True (`flowRouteMatches` windowRecord entry) route) Nothing
      pure name
    batch floor' records next more = object
      [ "version" .= (1 :: Int), "cursor" .= cursorAt (positionIndex next), "oldestCursor" .= cursorAt (positionIndex floor'),
        "records" .= records, "hasMore" .= more ]

-- ---------------------------------------------------------------------------
-- Route streams
-- ---------------------------------------------------------------------------

-- | The single-use pump of a route stream. The response callback passes the
-- action that writes and flushes one complete block, and the pump runs until
-- an ordinary shutdown or a failure ends the stream.
type RoutePump = (BS.ByteString -> IO ()) -> IO ()

-- | Serve the run route of the run as server-sent events.
--
-- The stream holds one subscription of the client of the credential, shared
-- with the event stream, for its whole response. It reads its first batch
-- before response entry, so a refusal of that batch is an ordinary problem
-- response. Each later batch is a new 'withRouteBatch'. A stream with nothing
-- more to read reads again after one second, or at its heartbeat deadline
-- when that comes first.
withRouteStream :: StreamReaders -> CoordinationStore -> CredentialProof -> Text -> Maybe Text -> Maybe FlowRoute
  -> (RoutePump -> IO a) -> IO a
withRouteStream streams store proof ident supplied route =
  routeStream streams store proof (\cursor -> withRouteBatch store proof ident cursor route)
    (pure (pure False)) (Just 1000000) supplied

-- | Serve the manager route as server-sent events.
--
-- The stream behaves as 'withRouteStream', except that a stream with nothing
-- more to read waits for a change of the append count of the manager log of
-- the Store, or for its heartbeat deadline. The count is read before each
-- batch, so an append during the batch read wakes the stream at once.
withManagerRouteStream :: StreamReaders -> CoordinationStore -> CredentialProof -> Maybe Text -> Maybe FlowRoute
  -> (RoutePump -> IO a) -> IO a
withManagerRouteStream streams store proof supplied route =
  routeStream streams store proof (\cursor -> withManagerRouteBatch store proof cursor route) appended Nothing supplied
  where
    appended = case storeManagerFlow store of
      Nothing -> pure (pure False)
      Just flow -> do
        seen <- atomically (managerFlowAppends flow)
        pure ((/= seen) <$> managerFlowAppends flow)

-- | One route batch lent to a callback, from a cursor or from the start.
type RouteReader = forall b. Maybe Text -> (AuthorizedView -> Value -> IO b) -> IO b

-- | The largest complete block of a route stream, the @sseBlockBytes@ limit.
routeBlockBytes :: Int
routeBlockBytes = 16384

-- | The heartbeat interval of a route stream, the @heartbeatSeconds@ limit, in
-- nanoseconds.
routeHeartbeatNanos :: Word64
routeHeartbeatNanos = 15000000000

-- Validate before response entry, then lend one single-use pump. Each batch
-- reads under the loans of its reader and returns them with
-- 'releaseResponseLoans' before its first write, so no write and no wait
-- holds a configuration guard, SQL transaction, reader charge or file slot.
-- The view is revalidated immediately before each block and heartbeat, and
-- each write completes within five seconds. The blocks of a batch are its
-- served records. A batch that serves no record and advances its cursor over
-- filtered gaps writes one block with the identifier of its cursor only. A
-- batch that writes nothing at the heartbeat deadline writes a heartbeat.
-- After 'closeStreams' the loop ends before its next batch read.
routeStream :: StreamReaders -> CoordinationStore -> CredentialProof -> RouteReader -> IO (STM Bool) -> Maybe Int
  -> Maybe Text -> (RoutePump -> IO a) -> IO a
routeStream streams store proof reader wake poll supplied action =
  withStreamReader streams store proof $ do
    initial <- reader supplied $ \view _ -> authorizedViewRevision view
    used <- newTVarIO False
    action $ \write -> do
      atomically $ do
        started <- readTVar used
        when started (throwSTM StateConflict)
        writeTVar used True
      loop initial write supplied Nothing
  where
    loop initial write cursor lastWrite = do
      closed <- atomically (streamsClosing streams)
      unless closed $ do
        changed <- wake
        (next, more, written) <- reader cursor $ \view value -> do
          current <- authorizedViewRevision view
          releaseResponseLoans view
          unless (current == initial) (throwIO ViewExpired)
          (next, more, records) <- batchFields value
          now <- getMonotonicTimeNSec
          let due = maybe True (\previous -> now - previous >= routeHeartbeatNanos) lastWrite
          blocks <- if not (null records) then mapM recordBlock records
            else if Just next /= cursor then pure ["id: " <> TE.encodeUtf8 next <> "\n\n"]
            else if due then pure [": heartbeat\n\n"] else pure []
          forM_ blocks $ \bytes -> do
            revalidateAuthorizedView view >>= either throwIO pure
            result <- timeout 5000000 (write bytes)
            maybe (refuseStorageUnavailable "route write" (InternalFault ResponseWriteTimeout)) pure result
          pure (next, more, if null blocks then lastWrite else Just now)
        unless more $ do
          now <- getMonotonicTimeNSec
          let remaining = maybe 0 (\previous -> routeHeartbeatNanos - min routeHeartbeatNanos (now - previous)) written
              micros = fromIntegral (min (remaining `div` 1000) (fromIntegral (maxBound :: Int)))
          awaitRoute changed (maybe micros (min micros) poll)
        loop initial write (Just next) written
    awaitRoute changed micros = unless (micros <= 0) $ do
      expired <- registerDelay micros
      atomically $ do
        closed <- streamsClosing streams
        fresh <- changed
        done <- readTVar expired
        unless (closed || fresh || done) retry

-- The cursor, the more flag and the served records of a route batch.
batchFields :: Value -> IO (Text, Bool, [Value])
batchFields (Object fields)
  | Just (String next) <- KM.lookup "cursor" fields, Just (Bool more) <- KM.lookup "hasMore" fields,
    Just (Array records) <- KM.lookup "records" fields = pure (next, more, foldr (:) [] records)
batchFields _ = throwIO StoreIntegrity

-- | The block of one served record: its identifier, the event name
-- @route.<schema>@ and the record as compact JSON. A block above
-- 'routeBlockBytes' is written with the body of the record replaced by
-- @{"omitted":"size","bytes":N}@, where N is the encoded size of the body.
recordBlock :: Value -> IO BS.ByteString
recordBlock (Object fields)
  | Just (String ident) <- KM.lookup "id" fields, Just (String schema) <- KM.lookup "schema" fields = do
      let block value = "id: " <> TE.encodeUtf8 ident <> "\nevent: route." <> TE.encodeUtf8 schema
            <> "\ndata: " <> encoded value <> "\n\n"
          whole = block (Object fields)
          omitted body = object ["omitted" .= ("size" :: Text), "bytes" .= BS.length (encoded body)]
      if BS.length whole <= routeBlockBytes then pure whole else case KM.lookup "body" fields of
        Just body | reduced <- block (Object (KM.insert "body" (omitted body) fields)), BS.length reduced <= routeBlockBytes -> pure reduced
        _ -> throwIO ViewTooLarge
recordBlock _ = throwIO StoreIntegrity
