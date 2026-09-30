{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A complete authorized graph at one durable manager commit boundary, and
-- the frozen request, run and decision collections. The decision collection
-- and each window of a request or run collection have one boundary.
module Agentic.Manager.Overview
  ( Collection (..), windowSize, withOverviewSource, withOverviewSourceWithin, withCollectionSource,
    withCollectionSourceWindow ) where

import Agentic.Manager.Admission (Admission)
import Agentic.Manager.Approval (preparationProjection)
import Agentic.Manager.Authorization
import Agentic.Manager.Drafts (readDraftAt)
import Agentic.Manager.Fault (FaultClass (InternalFault), ManagerFault (DeadlineElapsed), refuseStorageUnavailable)
import qualified Agentic.Manager.Events as Events
import Agentic.Manager.History (LegacyRun (..), managedRunInView)
import Agentic.Manager.Pages (Producer (..), Window (..))
import Agentic.Manager.Profile (ConfigurationLimits, publicId)
import qualified Agentic.Manager.Protocol.Command as C
import Agentic.Manager.State (RunAssociation (..), resolveDecision, resolveRun, decisionInView, decisionHeadIds, decisionQueueIds)
import Agentic.Manager.Store
import Control.DeepSeq (NFData (rnf))
import Control.Exception (catch, throwIO)
import Control.Monad (foldM, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Timeout (timeout)

-- | One frozen paged read collection. 'Requests' lists every request of the
-- authorized profiles and 'Runs' every managed run and every supplied legacy
-- entry of those profiles, both in identifier order and in keyset windows.
-- 'Decisions' without a run lists the pending run heads in manager
-- observation order, and with a run lists the pending FIFO queue of that run.
data Collection = Requests | Runs | Decisions !(Maybe Text)

-- | The most identifiers of one keyset window, and the most live items of
-- one overview list or decision collection.
windowSize :: Int
windowSize = 1024

-- The overview graph, or one collection of its members.
data Source = Overview | Members !Collection

-- The kind of one graph member. Its word is the overview tag. A legacy run
-- is a member of the run collection only.
data Kind = RequestKind | PreparationKind | RunKind | LegacyRunKind | DecisionKind

instance NFData Kind where
  rnf kind = kind `seq` ()

kindWord :: Kind -> Text
kindWord kind = case kind of
  RequestKind -> "request"
  PreparationKind -> "preparation"
  RunKind -> "run"
  LegacyRunKind -> "run"
  DecisionKind -> "decision"

-- | Reservation precedes the supplied materializer. The original reader and
-- response loans span collection and sending. The final boundary check refuses
-- a concurrent commit, rather than replaying reads or combining different cuts.
-- Materialization has an allowance of five seconds.
withOverviewSource :: CoordinationStore -> CredentialProof -> Maybe Admission
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withOverviewSource = withOverviewSourceWithin 5000000

-- | 'withOverviewSource' with an explicit materialization allowance in
-- microseconds. A materialization that exceeds the allowance keeps the
-- declared storage-unavailable refusal, and its elapsed deadline is recorded
-- privately first.
withOverviewSourceWithin :: Int -> CoordinationStore -> CredentialProof -> Maybe Admission
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withOverviewSourceWithin allowance store proof admission action =
  withSourceWithin allowance windowSize Overview store proof admission [] $ \view limits materialize ->
    action view limits $ do
      (revision, fields, _, Window items _) <- materialize Nothing
      pure (revision, fields, items)

-- | One collection under the same loans, allowance and final boundary check
-- as the overview. Each item is the representation of its detail resource.
-- A run selector that names no run of an authorized profile refuses with
-- `forbidden`, as the detail resources do. Each window of a request or run
-- collection has its own boundary, and the total counts the members at the
-- boundary of the first window. The run collection merges the supplied legacy
-- entries into the same identifier order and keyset condition, and lists
-- those of the authorized profiles. The other collections ignore them. The
-- caller retains the legacy entries before the source takes its loans, so no
-- window writes to the Store.
withCollectionSource :: CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyRun] -> Collection
  -> (AuthorizedView -> ConfigurationLimits -> Producer -> IO a) -> IO a
withCollectionSource = withCollectionSourceWindow windowSize

-- | 'withCollectionSource' with an explicit window size. Only tests choose a
-- size other than 'windowSize'.
withCollectionSourceWindow :: Int -> CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyRun] -> Collection
  -> (AuthorizedView -> ConfigurationLimits -> Producer -> IO a) -> IO a
withCollectionSourceWindow window store proof admission legacy collection action =
  withSourceWithin 5000000 window (Members collection) store proof admission legacy $ \view limits materialize ->
    action view limits $
      Producer (materialize Nothing) (\after -> (\(_, _, _, members) -> members) <$> materialize (Just after))

-- The materializer takes the last identifier of the previous window, and
-- returns the revision, fields and total of its boundary with one window.
withSourceWithin :: Int -> Int -> Source -> CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyRun]
  -> (AuthorizedView -> ConfigurationLimits -> (Maybe Text -> IO (Text,[Pair],Int,Window)) -> IO a) -> IO a
withSourceWithin allowance window source store proof admission legacy action = withStoreFileLoan store $ \files root ->
  withAuthorizedCatalogueContext store proof [C.Observe] $ \view limits visible _ invocations -> do
    attachResponseLoan view files
    action view limits $ \after -> do
      revalidateAuthorizedView view >>= either throwIO pure
      result <- timeout allowance (materialize root view (map fst visible) invocations after)
        `catch` \(failure :: StoreFailure) -> case failure of
          StoreLimit -> throwIO C.ViewTooLarge
          _ -> throwIO failure
      maybe (refuseStorageUnavailable "overview materialization" (InternalFault DeadlineElapsed)) pure result
  where
    materialize root view profiles invocations after = do
      revision <- authorizedCursorRevision view
      let publicProfiles = map publicId profiles
          allowed = SQL.SQLText (TE.decodeUtf8 (C.encoded publicProfiles))
          legacyVisible = Map.fromList [(legacyRunId entry, legacyRunValue entry) | entry <- legacy,
            legacyRunProfile entry `elem` publicProfiles]
      queue <- case source of
        Members (Decisions (Just run)) -> do
          association <- resolveRun store proof [C.Observe] run
          unless (associationProfile association `elem` publicProfiles) (throwIO C.Forbidden)
          pure (Just association)
        _ -> pure Nothing
      let tag kind = map (\ident -> (kind, ident))
          profileFilter = " WHERE profile_id IN (SELECT value FROM json_each(?))"
          -- A live list holds at most one window, and a larger list refuses
          -- before any member renders.
          live selection = do
            found <- ids (window + 1) selection [allowed]
            bounded found
          bounded found = do
            when (length found > window) (refuseTransaction C.ViewTooLarge)
            pure found
          -- One keyset window of a request or run table in identifier order,
          -- with the member count of the table at the first window. The
          -- extra members are merged into the same order under the same
          -- keyset condition, and the total counts them.
          keyset kind table extra = do
            found <- case after of
              Nothing -> ids (window + 1) ("SELECT id FROM " <> table <> profileFilter <> " ORDER BY id") [allowed]
              Just previous -> ids (window + 1) ("SELECT id FROM " <> table <> profileFilter <> " AND id>? ORDER BY id")
                [allowed, SQL.SQLText previous]
            total <- case after of
              Nothing -> Just . (+ length extra) <$> count ("SELECT count(*) FROM " <> table <> profileFilter) [allowed]
              Just _ -> pure Nothing
            let following = [member | member@(_, ident) <- extra, maybe True (ident >) after]
                merged = take (window + 1) (mergeMembers (tag kind found) following)
                kept = take window merged
                continuation = if length merged > window then snd <$> listToMaybe (reverse kept) else Nothing
            pure (kept, total, continuation)
          whole kind found = (tag kind found, Nothing, Nothing)
          identifiers = case (source, queue) of
            (Overview, _) -> do
              requests <- live "SELECT r.id FROM requests r WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND r.phase NOT IN ('withdrawn','refused') AND (r.phase!='associated' OR EXISTS(SELECT 1 FROM runs u WHERE u.request_id=r.id AND u.terminal_observed=0)) ORDER BY r.id"
              preparations <- live "SELECT p.id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND p.state='live' ORDER BY p.id"
              runs <- live "SELECT id FROM runs WHERE profile_id IN (SELECT value FROM json_each(?)) AND terminal_observed=0 ORDER BY id"
              decisions <- live "SELECT d.id FROM decisions d JOIN runs r ON r.id=d.run_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND d.state IN ('pending','submitting') ORDER BY length(d.observed_order),d.observed_order,d.id"
              pure (tag RequestKind requests <> tag PreparationKind preparations <> tag RunKind runs <> tag DecisionKind decisions,
                Nothing, Nothing)
            (Members Requests, _) -> keyset RequestKind "requests" []
            (Members Runs, _) -> keyset RunKind "runs" (tag LegacyRunKind (Map.keys legacyVisible))
            (Members (Decisions _), Just association) -> whole DecisionKind <$> (decisionQueueIds (window + 1) association >>= bounded)
            (Members (Decisions _), Nothing) -> whole DecisionKind <$> (decisionHeadIds (window + 1) publicProfiles >>= bounded)
          boundary :: NFData b => Transaction b -> IO (Text,Text,b)
          boundary capture = do
            let prepare = do
                  binding <- Events.captureBinding proof profiles revision
                  pure (Events.durableStream binding,Nothing,binding)
                project binding batch = do
                  value <- capture
                  pure (Events.cursorAt binding (retainedHighWater batch),
                    Events.cursorAt binding (retainedFloor batch),value)
            readRetainedEventsWith store prepare project >>= either (const (throwIO StoreIntegrity)) pure
      (cursor,oldest,(members,total,continuation)) <- boundary identifiers
      let present kind value = case source of
            Overview -> object ["kind" .= kindWord kind,Key.fromText (kindWord kind) .= value]
            Members _ -> value
          render (kind,ident) = present kind <$> case kind of
            RequestKind -> toJSON <$> readDraftAt store root proof ident
            PreparationKind -> toJSON <$> runRead store (preparationProjection proof profiles ident)
            RunKind -> managedRunInView store root proof view admission invocations ident
            LegacyRunKind -> maybe (throwIO StoreIntegrity) pure (Map.lookup ident legacyVisible)
            DecisionKind -> do
              association <- resolveDecision store proof [C.Observe] ident
              decisionInView store root proof view association ident
          append (charged,items) member = do
            value <- render member
            let next = charged + BS.length (C.encoded value) + 1
            when (next > 67108864) (throwIO C.ViewTooLarge)
            pure (next,value:items)
      (_,reversed) <- foldM append (2 :: Int,[]) members
      (current,_,()) <- boundary (pure ())
      unless (current == cursor) (throwIO StoreBusy)
      revalidateAuthorizedView view >>= either throwIO pure
      let digest = T.pack (show (hash (C.encoded (cursor,oldest)) :: Digest SHA256))
          items = reverse reversed
          members' = Window items continuation
          counted = fromMaybe (length items) total
      pure $ case source of
        Overview -> ("overview_" <> digest,
          ["snapshotVersion" .= (1 :: Int),"cursor" .= cursor,"oldestCursor" .= oldest],counted,members')
        Members collection -> (collectionName collection <> "_" <> digest,[],counted,members')

-- Two identifier-ordered member lists in one identifier order.
mergeMembers :: [(Kind,Text)] -> [(Kind,Text)] -> [(Kind,Text)]
mergeMembers left [] = left
mergeMembers [] right = right
mergeMembers left@(l:ls) right@(r:rs)
  | snd r < snd l = r : mergeMembers left rs
  | otherwise = l : mergeMembers ls right

collectionName :: Collection -> Text
collectionName collection = case collection of
  Requests -> "requests"
  Runs -> "runs"
  Decisions _ -> "decisions"

-- The identifiers of one selection, at most the given number.
ids :: Int -> Text -> [SQL.SQLData] -> Transaction [Text]
ids bound selection parameters = do
  rows <- query (selection <> " LIMIT ?") (parameters <> [SQL.SQLInteger (fromIntegral bound)])
  mapM (\row -> case row of
    [SQL.SQLText ident] | C.validId ident -> pure ident
    _ -> refuseTransaction StoreIntegrity) rows

count :: Text -> [SQL.SQLData] -> Transaction Int
count selection parameters = do
  rows <- query selection parameters
  case rows of
    [[SQL.SQLInteger value]] | value >= 0 -> pure (fromIntegral value)
    _ -> refuseTransaction StoreIntegrity
