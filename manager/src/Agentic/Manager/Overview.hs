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
import Agentic.Manager.History (LegacyHistory, LegacyRun (..), legacyRootIdentities, legacyWindow, managedRunInView, withLegacyRootsLoan)
import Agentic.Manager.Pages (Producer (..), Window (..))
import Agentic.Manager.Profile (ConfigurationLimits, publicId)
import qualified Agentic.Manager.Protocol.Command as C
import Agentic.Manager.State (RunAssociation (..), resolveDecision, resolveRun, decisionInView, decisionHeadIds, decisionQueueIds)
import Agentic.Manager.Store
import Control.DeepSeq (NFData (rnf))
import Control.Exception (catch, throwIO)
import Control.Monad (foldM, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value, eitherDecodeStrict', object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Timeout (timeout)

-- | One frozen paged read collection. 'Requests' lists every request of the
-- authorized profiles and 'Runs' every managed run and every retained legacy
-- entry of the supplied bindings of those profiles, both in identifier order
-- and in keyset windows.
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
-- boundary of the first window. The run collection opens the roots of the
-- supplied legacy bindings under its file slot. Each window is one keyset
-- over the managed run identifiers and the retained legacy handles of those
-- roots, in one identifier order, and lists those of the authorized profiles.
-- A window decodes only its own legacy entries, each by its component name,
-- at most 256 entries and 1 MiB encoded, and ends before the first legacy
-- entry beyond that bound. It retains the parent handles, result references
-- and revisions of those entries before it takes its boundary. The caller
-- retains the handles of the entry names first, with
-- 'Agentic.Manager.History.retainLegacyHandles'. The other collections
-- ignore the bindings.
withCollectionSource :: CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyHistory] -> Collection
  -> (AuthorizedView -> ConfigurationLimits -> Producer -> IO a) -> IO a
withCollectionSource = withCollectionSourceWindow windowSize

-- | 'withCollectionSource' with an explicit window size. Only tests choose a
-- size other than 'windowSize'.
withCollectionSourceWindow :: Int -> CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyHistory] -> Collection
  -> (AuthorizedView -> ConfigurationLimits -> Producer -> IO a) -> IO a
withCollectionSourceWindow window store proof admission legacy collection action =
  withSourceWithin 5000000 window (Members collection) store proof admission bound $ \view limits materialize ->
    action view limits $
      Producer (materialize Nothing) (\after -> (\(_, _, _, members) -> members) <$> materialize (Just after))
  where
    bound = case collection of
      Runs -> legacy
      _ -> []

-- The materializer takes the last identifier of the previous window, and
-- returns the revision, fields and total of its boundary with one window.
withSourceWithin :: Int -> Int -> Source -> CoordinationStore -> CredentialProof -> Maybe Admission -> [LegacyHistory]
  -> (AuthorizedView -> ConfigurationLimits -> (Maybe Text -> IO (Text,[Pair],Int,Window)) -> IO a) -> IO a
withSourceWithin allowance window source store proof admission legacy action = withLegacyRootsLoan store legacy $ \files root roots ->
  withAuthorizedCatalogueContext store proof [C.Observe] $ \view limits visible _ invocations -> do
    attachResponseLoan view files
    action view limits $ \after -> do
      revalidateAuthorizedView view >>= either throwIO pure
      result <- timeout allowance (materialize root roots view (map fst visible) invocations after)
        `catch` \(failure :: StoreFailure) -> case failure of
          StoreLimit -> throwIO C.ViewTooLarge
          _ -> throwIO failure
      maybe (refuseStorageUnavailable "overview materialization" (InternalFault DeadlineElapsed)) pure result
  where
    materialize root roots view profiles invocations after = do
      revision <- authorizedCursorRevision view
      let publicProfiles = map publicId profiles
          allowed = SQL.SQLText (TE.decodeUtf8 (C.encoded publicProfiles))
          rootIdentities = SQL.SQLText (TE.decodeUtf8 (C.encoded [identity | (identity, profile) <- legacyRootIdentities roots,
            profile `elem` publicProfiles]))
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
          following = maybe [] (pure . SQL.SQLText) after
          -- One keyset window of the request table in identifier order,
          -- with the member count of the table at the first window.
          keyset kind table = do
            found <- keysetMembers (window + 1) ("SELECT id,0 AS member FROM " <> table <> profileFilter
              <> maybe "" (const " AND id>?") after <> " ORDER BY id") ([allowed] <> following)
            total <- case after of
              Nothing -> Just <$> count ("SELECT count(*) FROM " <> table <> profileFilter) [allowed]
              Just _ -> pure Nothing
            let kept = take window (tag kind (map fst found))
                continuation = if length found > window then snd <$> listToMaybe (reverse kept) else Nothing
            pure (kept, total, continuation, True)
          -- The managed run identifiers and the retained legacy handles of
          -- the opened roots after the previous window, in identifier order,
          -- at most one more than a window.
          runCandidates = do
            found <- keysetMembers (window + 1) ("SELECT id,member FROM (SELECT id,0 AS member FROM runs" <> profileFilter
              <> " UNION ALL SELECT id,1 AS member FROM history_entries" <> profileFilter
              <> " AND root_identity IN (SELECT value FROM json_each(?)))"
              <> maybe "" (const " WHERE id>?") after <> " ORDER BY id")
              ([allowed, allowed, rootIdentities] <> following)
            mapM (\(ident, member) -> case member of
              0 -> pure (RunKind, ident)
              1 -> pure (LegacyRunKind, ident)
              _ -> refuseTransaction StoreIntegrity) found
          -- One run window ends before the first legacy entry that the
          -- decoded legacy window does not hold. A legacy candidate before
          -- that entry that is not decoded is a concurrent retention, and
          -- the window is not complete.
          runWindow decoded stop = do
            found <- runCandidates
            total <- case after of
              Nothing -> do
                runs <- count ("SELECT count(*) FROM runs" <> profileFilter) [allowed]
                entries <- count ("SELECT count(*) FROM history_entries" <> profileFilter
                  <> " AND root_identity IN (SELECT value FROM json_each(?))") [allowed, rootIdentities]
                pure (Just (runs + entries))
              Just _ -> pure Nothing
            let kept = take window (takeWhile (\(_, ident) -> maybe True (ident <) stop) found)
                held = and [Map.member ident decoded | (LegacyRunKind, ident) <- kept]
                continuation = if length kept < length found then snd <$> listToMaybe (reverse kept) else Nothing
            pure (kept, total, continuation, held && not (null kept && not (null found)))
          whole kind found = (tag kind found, Nothing, Nothing, True)
          identifiers decoded stop = case (source, queue) of
            (Overview, _) -> do
              requests <- live "SELECT r.id FROM requests r WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND r.phase NOT IN ('withdrawn','refused') AND (r.phase!='associated' OR EXISTS(SELECT 1 FROM runs u WHERE u.request_id=r.id AND u.terminal_observed=0)) ORDER BY r.id"
              preparations <- live "SELECT p.id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND p.state='live' ORDER BY p.id"
              runs <- live "SELECT id FROM runs WHERE profile_id IN (SELECT value FROM json_each(?)) AND terminal_observed=0 ORDER BY id"
              decisions <- live "SELECT d.id FROM decisions d JOIN runs r ON r.id=d.run_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND d.state IN ('pending','submitting') ORDER BY length(d.observed_order),d.observed_order,d.id"
              pure (tag RequestKind requests <> tag PreparationKind preparations <> tag RunKind runs <> tag DecisionKind decisions,
                Nothing, Nothing, True)
            (Members Requests, _) -> keyset RequestKind "requests"
            (Members Runs, _) -> runWindow decoded stop
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
          -- The legacy entries of a run window are decoded and retained
          -- before its boundary. A concurrent retention inside the window
          -- repeats the window, at most three times.
          attempt :: Int -> IO (Map.Map Text Value,(Text,Text,([(Kind,Text)],Maybe Int,Maybe Text,Bool)))
          attempt tries = do
            (decoded,stop) <- case source of
              Members Runs -> do
                found <- runRead store runCandidates
                legacyWindow store roots invocations [ident | (LegacyRunKind, ident) <- found]
              _ -> pure ([],Nothing)
            let decodedMap = Map.fromList [(legacyRunId entry, legacyRunValue entry) | entry <- decoded]
            outcome@(_,_,(_,_,_,complete)) <- boundary (identifiers decodedMap stop)
            if complete then pure (decodedMap,outcome)
              else if tries < 3 then attempt (tries + 1) else refuseBusy "overview-legacy-window" Nothing
      (legacyVisible,(cursor,oldest,(members,total,continuation,_))) <- attempt 1
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
      unless (current == cursor) (refuseBusy "overview-cursor" Nothing)
      revalidateAuthorizedView view >>= either throwIO pure
      let digest = T.pack (show (hash (C.encoded (cursor,oldest)) :: Digest SHA256))
          items = reverse reversed
          members' = Window items continuation
          counted = fromMaybe (length items) total
      pure $ case source of
        Overview -> ("overview_" <> digest,
          ["snapshotVersion" .= (1 :: Int),"cursor" .= cursor,"oldestCursor" .= oldest],counted,members')
        Members collection -> (collectionName collection <> "_" <> digest,[],counted,members')

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

-- The identifier and member number of each row of one identifier-ordered
-- selection of the columns @id@ and @member@, at most the given number. The
-- rows arrive as one aggregated row, so that a window of 1024 identifiers
-- stays within the row budget of its transaction.
keysetMembers :: Int -> Text -> [SQL.SQLData] -> Transaction [(Text, Int)]
keysetMembers bound selection parameters = do
  rows <- query ("SELECT json_group_array(json_array(id,member)) FROM (" <> selection <> " LIMIT ?)")
    (parameters <> [SQL.SQLInteger (fromIntegral bound)])
  case rows of
    [[SQL.SQLText members]] -> case eitherDecodeStrict' (TE.encodeUtf8 members) of
      Right decoded | all (C.validId . fst) decoded -> pure (sortOn fst decoded)
      _ -> refuseTransaction StoreIntegrity
    _ -> refuseTransaction StoreIntegrity

count :: Text -> [SQL.SQLData] -> Transaction Int
count selection parameters = do
  rows <- query selection parameters
  case rows of
    [[SQL.SQLInteger value]] | value >= 0 -> pure (fromIntegral value)
    _ -> refuseTransaction StoreIntegrity
