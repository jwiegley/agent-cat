{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Read-only Store status and quarantine discovery for local administration.
-- Neither operation changes a Store row or appends to the manager log.
module Agentic.Manager.Quarantine
  ( StoreState (..), reportStatus, reportStoreCheck, unavailableStoreCheck
  ) where

import Agentic.Manager.Protocol.Command (validId)
import Agentic.Manager.Protocol.LocalAdmin (AdminFailure (..), adminError, adminSuccess)
import Agentic.Manager.Store
import Control.Exception (IOException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Database.SQLite3 as SQL

-- | The lifetime that answers @status@: the live channel of a serving
-- manager, or offline administration while no manager serves.
data StoreState = StoreServing | StoreStopped

stateName :: StoreState -> Text
stateName state = case state of
  StoreServing -> "serving"
  StoreStopped -> "stopped"

-- | The durable identities of the Store, the process generation of the
-- answering lifetime, and the count of reservations that are not released.
-- Quarantined reservations count, since they keep their slots and resource
-- keys until cleanup evidence releases them.
reportStatus :: StoreState -> CoordinationStore -> IO BS.ByteString
reportStatus state store = answered "status" $ do
  identity <- storeIdentity store
  active <- runRead store $ do
    rows <- query "SELECT count(*) FROM reservations WHERE state!='released'" []
    case rows of
      [[SQL.SQLInteger count]] | count >= 0 && count <= 16 -> pure (fromIntegral count :: Int)
      _ -> refuseTransaction StoreIntegrity
  pure $ object
    ["state" .= stateName state, "authorityEpoch" .= storeAuthorityEpoch identity,
     "streamId" .= storeStreamId identity, "processGeneration" .= storeProcessGeneration identity,
     "activeReservations" .= active]

-- | A SQLite quick check of the open Store, and the identities of its
-- quarantined claims in identity order: each reservation in state
-- @quarantined@ and each claim that a restoration carried forward. More than
-- 256 claims refuse with @size-limit@.
reportStoreCheck :: CoordinationStore -> IO BS.ByteString
reportStoreCheck store = answered "check-store" $ do
  (integrity, identities) <- runRead store $ do
    checked <- query "SELECT quick_check FROM pragma_quick_check" []
    rows <- query "SELECT id FROM reservations WHERE state='quarantined' UNION SELECT id FROM restoration_quarantine ORDER BY id LIMIT 257" []
    unless (length rows <= 256) (refuseTransaction StoreLimit)
    identities <- forM rows $ \row -> case row of
      [SQL.SQLText ident] | validId ident -> pure ident
      _ -> refuseTransaction StoreIntegrity
    pure (if checked == [[SQL.SQLText "ok"]] then "valid" else "corrupt" :: Text, identities)
  pure (storeCheck integrity identities)

-- | The @check-store@ answer when the Store cannot be opened.
unavailableStoreCheck :: BS.ByteString
unavailableStoreCheck = adminSuccess "check-store" (storeCheck "unavailable" [])

storeCheck :: Text -> [Text] -> Value
storeCheck integrity identities = object ["integrity" .= integrity, "quarantineIds" .= identities]

-- The refusals of 'Agentic.Manager.Credentials.administerCredentials'. A read
-- records nothing, so no receipt follows.
answered :: Text -> IO Value -> IO BS.ByteString
answered operation action = do
  result <- try @IOException (try @StoreFailure action)
  pure $ case result of
    Left _ -> adminError (Just operation) StorageUnavailable
    Right (Left StoreLimit) -> adminError (Just operation) SizeLimit
    Right (Left _) -> adminError (Just operation) StorageUnavailable
    Right (Right value) -> adminSuccess operation value
