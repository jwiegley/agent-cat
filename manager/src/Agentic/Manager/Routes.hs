{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
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
module Agentic.Manager.Routes (routeAlias, managerRouteAlias, withRouteBatch, withManagerRouteBatch) where

import Agentic.Manager.Artifacts (withRunRoot)
import Agentic.Manager.Authorization
import Agentic.Manager.Events (bindingGrants, captureBinding, durableStream, parseCursor, publicStreamId)
import Agentic.Manager.Flow (ManagerWindow (..), readManagerWindow)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.State (RunAssociation (..), resolveRunIn)
import Agentic.Manager.Store
import Agentic.Runtime
  ( About (..), FlowRoute, FlowWindow (..), FlowWindowEntry (..), FlowWindowRefusal (..), Position (..),
    PrivateRoot, Record (..), RouteClass (..), Schema (FlowCommand, FlowNotice, FlowReceipt, FlowRelay, FlowReview),
    flowRouteMatches, flowWindowEntryFields, flowWindowLimits, readFlowWindow, runIdText, runLogName, schemaRouteClass )
import Control.DeepSeq (NFData (rnf))
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM, unless)
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
import System.IO.Error (isDoesNotExistError)

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
