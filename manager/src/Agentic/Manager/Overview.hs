{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A complete authorized graph at one durable manager commit boundary, and
-- the frozen request, run and decision collections over the same boundary.
module Agentic.Manager.Overview
  ( Collection (..), withOverviewSource, withOverviewSourceWithin, withCollectionSource ) where

import Agentic.Manager.Admission (Admission)
import Agentic.Manager.Approval (preparationProjection)
import Agentic.Manager.Authorization
import Agentic.Manager.Drafts (readDraftAt)
import Agentic.Manager.Fault (FaultClass (InternalFault), ManagerFault (DeadlineElapsed), refuseStorageUnavailable)
import qualified Agentic.Manager.Events as Events
import Agentic.Manager.History (managedRunInView)
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
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Timeout (timeout)

-- | One frozen paged read collection. 'Requests' lists every request of the
-- authorized profiles and 'Runs' every managed run, both in identifier order.
-- 'Decisions' without a run lists the pending run heads in manager
-- observation order, and with a run lists the pending FIFO queue of that run.
data Collection = Requests | Runs | Decisions !(Maybe Text)

-- The overview graph, or one collection of its members.
data Source = Overview | Members !Collection

-- The kind of one graph member. Its word is the overview tag.
data Kind = RequestKind | PreparationKind | RunKind | DecisionKind

instance NFData Kind where
  rnf kind = kind `seq` ()

kindWord :: Kind -> Text
kindWord kind = case kind of
  RequestKind -> "request"
  PreparationKind -> "preparation"
  RunKind -> "run"
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
withOverviewSourceWithin allowance = withSourceWithin allowance Overview

-- | One collection under the same loans, allowance and final boundary check
-- as the overview. Each item is the representation of its detail resource.
-- A run selector that names no run of an authorized profile refuses with
-- `forbidden`, as the detail resources do.
withCollectionSource :: CoordinationStore -> CredentialProof -> Maybe Admission -> Collection
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withCollectionSource store proof admission collection =
  withSourceWithin 5000000 (Members collection) store proof admission

withSourceWithin :: Int -> Source -> CoordinationStore -> CredentialProof -> Maybe Admission
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withSourceWithin allowance source store proof admission action = withStoreFileLoan store $ \files root ->
  withAuthorizedCatalogueContext store proof [C.Observe] $ \view limits visible _ invocations -> do
    attachResponseLoan view files
    action view limits $ do
      revalidateAuthorizedView view >>= either throwIO pure
      result <- timeout allowance (materialize root view (map fst visible) invocations)
        `catch` \(failure :: StoreFailure) -> case failure of
          StoreLimit -> throwIO C.ViewTooLarge
          _ -> throwIO failure
      maybe (refuseStorageUnavailable "overview materialization" (InternalFault DeadlineElapsed)) pure result
  where
    materialize root view profiles invocations = do
      revision <- authorizedCursorRevision view
      let publicProfiles = map publicId profiles
          allowed = SQL.SQLText (TE.decodeUtf8 (C.encoded publicProfiles))
      queue <- case source of
        Members (Decisions (Just run)) -> do
          association <- resolveRun store proof [C.Observe] run
          unless (associationProfile association `elem` publicProfiles) (throwIO C.Forbidden)
          pure (Just association)
        _ -> pure Nothing
      let tag kind = map (\ident -> (kind, ident))
          identifiers = case (source, queue) of
            (Overview, _) -> do
              requests <- ids "SELECT r.id FROM requests r WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND r.phase NOT IN ('withdrawn','refused') AND (r.phase!='associated' OR EXISTS(SELECT 1 FROM runs u WHERE u.request_id=r.id AND u.terminal_observed=0)) ORDER BY r.id" allowed
              preparations <- ids "SELECT p.id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND p.state='live' ORDER BY p.id" allowed
              runs <- ids "SELECT id FROM runs WHERE profile_id IN (SELECT value FROM json_each(?)) AND terminal_observed=0 ORDER BY id" allowed
              decisions <- ids "SELECT d.id FROM decisions d JOIN runs r ON r.id=d.run_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND d.state IN ('pending','submitting') ORDER BY length(d.observed_order),d.observed_order,d.id" allowed
              pure (tag RequestKind requests <> tag PreparationKind preparations <> tag RunKind runs <> tag DecisionKind decisions)
            (Members Requests, _) -> tag RequestKind <$> ids "SELECT id FROM requests WHERE profile_id IN (SELECT value FROM json_each(?)) ORDER BY id" allowed
            (Members Runs, _) -> tag RunKind <$> ids "SELECT id FROM runs WHERE profile_id IN (SELECT value FROM json_each(?)) ORDER BY id" allowed
            (Members (Decisions _), Just association) -> tag DecisionKind <$> decisionQueueIds association
            (Members (Decisions _), Nothing) -> tag DecisionKind <$> decisionHeadIds publicProfiles
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
      (cursor,oldest,members) <- boundary identifiers
      let present kind value = case source of
            Overview -> object ["kind" .= kindWord kind,Key.fromText (kindWord kind) .= value]
            Members _ -> value
          render (kind,ident) = present kind <$> case kind of
            RequestKind -> toJSON <$> readDraftAt store root proof ident
            PreparationKind -> toJSON <$> runRead store (preparationProjection proof profiles ident)
            RunKind -> managedRunInView store root proof view admission invocations ident
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
      pure $ case source of
        Overview -> ("overview_" <> digest,
          ["snapshotVersion" .= (1 :: Int),"cursor" .= cursor,"oldestCursor" .= oldest],reverse reversed)
        Members collection -> (collectionName collection <> "_" <> digest,[],reverse reversed)

collectionName :: Collection -> Text
collectionName collection = case collection of
  Requests -> "requests"
  Runs -> "runs"
  Decisions _ -> "decisions"

ids :: Text -> SQL.SQLData -> Transaction [Text]
ids selection parameter = do
  rows <- query ("SELECT json_group_array(id) FROM (" <> selection <> ")") [parameter]
  case rows of
    [[SQL.SQLText bytes]] -> case eitherDecodeStrict' (TE.encodeUtf8 bytes) of
      Right values | all C.validId values -> pure values
      _ -> refuseTransaction StoreIntegrity
    _ -> refuseTransaction StoreIntegrity
