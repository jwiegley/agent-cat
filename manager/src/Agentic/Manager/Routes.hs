{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The run-log route resource: authorized windows of the run log of one
-- managed run, served by route class.
--
-- A batch reads the run log @flow.ndjson@ of the run store of the run with
-- the positioned window reader of the runtime. It never reads the whole log,
-- never opens a claim-check file and writes nothing to the coordination
-- store. The cursor alias binds the public stream identity of the event
-- stream of the credential and the public run identifier. A served record at
-- position @p@ has the identifier @ALIAS.(p+1)@, and a cursor names the next
-- position to read.
module Agentic.Manager.Routes (routeAlias, withRouteBatch) where

import Agentic.Manager.Artifacts (withRunRoot)
import Agentic.Manager.Authorization
import Agentic.Manager.Events (captureBinding, parseCursor, publicStreamId)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.State (RunAssociation (..), resolveRunIn)
import Agentic.Manager.Store
import Agentic.Runtime
  ( FlowRoute, FlowWindow (..), FlowWindowEntry (..), FlowWindowRefusal (..), Position (..),
    PrivateRoot, Record (..), RouteClass (..), flowRouteMatches, flowWindowEntryFields,
    flowWindowLimits, readFlowWindow, runIdText, runLogName, schemaRouteClass )
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import System.IO.Error (isDoesNotExistError)

-- | The cursor alias of the run route of one run for the public stream
-- identity of a credential. It is an equality fingerprint, never a
-- credential, a file identity or a reconstruction of a live owner.
routeAlias :: Text -> Text -> Text
routeAlias stream run = "route_" <> T.pack (show (hash (encoded
  ((1 :: Int), stream, "run:" <> run)) :: Digest SHA256))

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
      start <- case supplied of
        Nothing -> pure 0
        Just cursor -> do
          (given, position) <- either throwIO pure (parseCursor cursor)
          unless (given == alias) (throwIO ViewExpired)
          pure position
      batch <- withRunRoot root association $ \runs ->
        routeBatch runs association alias (servedClass control) route start
      revalidateAuthorizedView view >>= either throwIO pure
      respond view batch

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

-- Read windows of the run log from the start position. A window whose
-- records are all filtered gaps is followed by the next one, up to
-- 'routeScanWindows'. The batch ends after the first window that serves a
-- record, before the first record that would exceed 'routeRecordBytes', or
-- at the end of the complete records.
routeBatch :: PrivateRoot -> RunAssociation -> Text -> (RouteClass -> Maybe Text) -> Maybe FlowRoute
  -> Word64 -> IO Value
routeBatch runs association alias served route start = scan 1 (Position start)
  where
    path = ["runs", T.unpack (runIdText (associationNative association)), "runtime", runLogName]
    cursorAt position = alias <> "." <> T.pack (show position)
    scan :: Int -> Position -> IO Value
    scan windows cursor = do
      found <- try @IOException (readFlowWindow runs path (Position 0) cursor flowWindowLimits)
      window <- case found of
        Left failure
          | isDoesNotExistError failure && positionIndex cursor == 0 -> pure (Right (FlowWindow [] cursor False 0))
          | isDoesNotExistError failure -> pure (Left (FlowWindowAhead (Position 0)))
          | otherwise -> throwIO failure
        Right result -> pure result
      case window of
        Left (FlowWindowAhead _) -> throwIO CursorExpired
        Left (FlowWindowBelowFloor _) -> throwIO CursorExpired
        Left (FlowWindowUndecodable _ _) -> throwIO StoreIntegrity
        Right result -> case collect [] 0 (windowEntries result) of
          (records, Just stop) -> pure (batch records stop True)
          (records, Nothing)
            | null records && windowMore result && windows < routeScanWindows -> scan (windows + 1) (windowNext result)
            | otherwise -> pure (batch records (windowNext result) (windowMore result))
    -- The served records of the entries in order, and the position of the
    -- first entry that the batch leaves for the next one.
    collect done _ [] = (reverse done, Nothing)
    collect done used (entry : rest) = case visible entry of
      Nothing -> collect done used rest
      Just name ->
        let value = object (("id" .= cursorAt (positionIndex (windowPosition entry) + 1)) : ("class" .= name)
              : flowWindowEntryFields entry)
            size = BS.length (encoded value) + 1
         in if used + size > routeRecordBytes && not (null done)
              then (reverse done, Just (windowPosition entry))
              else collect (value : done) (used + size) rest
    visible entry = do
      name <- served (schemaRouteClass (recSchema (windowRecord entry)))
      unless (maybe True (`flowRouteMatches` windowRecord entry) route) Nothing
      pure name
    batch records next more = object
      [ "version" .= (1 :: Int), "cursor" .= cursorAt (positionIndex next), "oldestCursor" .= cursorAt (0 :: Word64),
        "records" .= records, "hasMore" .= more ]
