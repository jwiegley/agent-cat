{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A complete authorized graph at one durable manager commit boundary.
module Agentic.Manager.Overview (withOverviewSource) where

import Agentic.Manager.Admission (Admission)
import Agentic.Manager.Approval (preparationProjection)
import Agentic.Manager.Authorization
import Agentic.Manager.Drafts (readDraftAt)
import qualified Agentic.Manager.Events as Events
import Agentic.Manager.History (managedRunInView)
import Agentic.Manager.Profile (ConfigurationLimits, publicId)
import qualified Agentic.Manager.Protocol.Command as C
import Agentic.Manager.State (resolveDecision, decisionInView)
import Agentic.Manager.Store
import Control.DeepSeq (NFData)
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

-- | Reservation precedes the supplied materializer. The original reader and
-- response loans span collection and sending. The final boundary check refuses
-- a concurrent commit, rather than replaying reads or combining different cuts.
withOverviewSource :: CoordinationStore -> CredentialProof -> Maybe Admission
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text,[Pair],[Value]) -> IO a) -> IO a
withOverviewSource store proof admission action = withStoreFiles store $ \root ->
  withAuthorizedCatalogueContext store proof [C.Observe] $ \view limits visible _ invocations ->
    action view limits $ do
      revalidateAuthorizedView view >>= either throwIO pure
      result <- timeout 5000000 (materialize root view (map fst visible) invocations)
        `catch` \(failure :: StoreFailure) -> case failure of
          StoreLimit -> throwIO C.ViewTooLarge
          _ -> throwIO failure
      maybe (throwIO C.StorageUnavailable) pure result
  where
    materialize root view profiles invocations = do
      revision <- authorizedCursorRevision view
      let allowed = SQL.SQLText (TE.decodeUtf8 (C.encoded (map publicId profiles)))
          identifiers = do
            requests <- ids "SELECT r.id FROM requests r WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND r.phase NOT IN ('withdrawn','refused') AND (r.phase!='associated' OR EXISTS(SELECT 1 FROM runs u WHERE u.request_id=r.id AND u.terminal_observed=0)) ORDER BY r.id" allowed
            preparations <- ids "SELECT p.id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND p.state='live' ORDER BY p.id" allowed
            runs <- ids "SELECT id FROM runs WHERE profile_id IN (SELECT value FROM json_each(?)) AND terminal_observed=0 ORDER BY id" allowed
            decisions <- ids "SELECT d.id FROM decisions d JOIN runs r ON r.id=d.run_id WHERE r.profile_id IN (SELECT value FROM json_each(?)) AND d.state IN ('pending','submitting') ORDER BY length(d.observed_order),d.observed_order,d.id" allowed
            pure (requests,preparations,runs,decisions)
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
      (cursor,oldest,(requests,preparations,runs,decisions)) <- boundary identifiers
      let tagged kind readValue = do
            value <- readValue
            pure (object ["kind" .= (kind :: Text),Key.fromText kind .= value])
          operations =
            [tagged "request" (toJSON <$> readDraftAt store root proof ident) | ident <- requests] <>
            [tagged "preparation" (toJSON <$> runRead store (preparationProjection proof profiles ident)) | ident <- preparations] <>
            [tagged "run" (managedRunInView store root proof view admission invocations ident) | ident <- runs] <>
            [tagged "decision" (do association <- resolveDecision store proof [C.Observe] ident
                                   decisionInView store root proof view association ident) | ident <- decisions]
          append (charged,items) readValue = do
            value <- readValue
            let next = charged + BS.length (C.encoded value) + 1
            when (next > 67108864) (throwIO C.ViewTooLarge)
            pure (next,value:items)
      (_,reversed) <- foldM append (2 :: Int,[]) operations
      (current,_,()) <- boundary (pure ())
      unless (current == cursor) (throwIO StoreBusy)
      revalidateAuthorizedView view >>= either throwIO pure
      let token = "overview_" <> T.pack (show (hash (C.encoded (cursor,oldest)) :: Digest SHA256))
      pure (token,["snapshotVersion" .= (1 :: Int),"cursor" .= cursor,"oldestCursor" .= oldest],reverse reversed)

ids :: Text -> SQL.SQLData -> Transaction [Text]
ids selection parameter = do
  rows <- query ("SELECT json_group_array(id) FROM (" <> selection <> ")") [parameter]
  case rows of
    [[SQL.SQLText bytes]] -> case eitherDecodeStrict' (TE.encodeUtf8 bytes) of
      Right values | all C.validId values -> pure values
      _ -> refuseTransaction StoreIntegrity
    _ -> refuseTransaction StoreIntegrity
