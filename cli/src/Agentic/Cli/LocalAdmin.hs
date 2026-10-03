{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Frozen stdin administration through the selected local authority.
module Agentic.Cli.LocalAdmin (runLocalAdmin) where

import Agentic.Manager.Configuration
import Agentic.Manager.LocalAdmin (administerLocally, callLocalAdministration, offlineAdministration)
import Agentic.Manager.Profile (Diagnostic (UnreadableConfiguration), publicId, publicRevision)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Quarantine (unavailableStoreCheck)
import Agentic.Manager.Store (CoordinationStore, StoreFailure, withCoordinationStore)
import Control.Exception (IOException, bracket, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import System.Exit (exitFailure, exitSuccess)
import System.IO (stdin, stdout)

-- A configured channel is authoritative even when unavailable. Only omission
-- selects offline ownership, including the normal restart reconciliation.
-- Operations without an implementation refuse before either path. Offline
-- reload-profiles validates the given file through the loader and answers
-- before the configuration lease and the Store are acquired. Offline drain
-- has no serving lifetime to drain and refuses at the same point. Offline
-- shutdown acquires the configuration lease, which proves that no manager
-- serves the configuration, and answers that the manager is stopped without
-- opening the Store, so it changes nothing.
runLocalAdmin :: (FilePath -> IO (Either Diagnostic Configuration)) -> FilePath -> IO ()
runLocalAdmin load path = do
  input <- try @IOException (BS.hGet stdin 2097153)
  output <- case input of
    Left _ -> pure (adminError Nothing MalformedRequest)
    Right bytes -> case decodeLocalAdminRequest bytes of
      Left failure -> pure (adminError Nothing failure)
      Right request -> do
        result <- try @IOException $ try @StoreFailure $ try @Diagnostic $ do
          if not (validLocalFile path)
            then pure (adminError (Just (adminOperation request)) MalformedRequest)
            else case request of
              OtherAdmin _ -> pure (adminError (Just (adminOperation request)) StateConflict)
              _ -> do
                configuration <- load path
                case (request, configuration) of
                  (ReloadProfiles, Left UnreadableConfiguration) -> pure (adminError (Just (adminOperation request)) StorageUnavailable)
                  (ReloadProfiles, Left _) -> pure (adminError (Just (adminOperation request)) StateConflict)
                  (_, Left _) -> pure (adminError (Just (adminOperation request)) StorageUnavailable)
                  (_, Right value) -> do
                    live <- callLocalAdministration value bytes
                    case (live, request) of
                      (Just response, _) -> pure response
                      (Nothing, ReloadProfiles) -> validateOffline value
                      (Nothing, Drain) -> pure (adminError (Just (adminOperation request)) StateConflict)
                      (Nothing, _) -> do
                        installed <- installConfiguration value
                        case (installed, request) of
                          (Left _, _) -> pure (adminError (Just (adminOperation request)) StorageUnavailable)
                          (Right owner, Shutdown) -> closeConfiguration owner >> pure stoppedManager
                          (Right owner, _) -> bracket (pure owner) closeConfiguration $ \active ->
                            offline request (withCoordinationStore active)
        pure $ case result of
          Right (Right (Right response)) -> response
          _ -> adminError (Just (adminOperation request)) StorageUnavailable
  BS.hPut stdout (output <> "\n")
  case eitherDecodeStrict' output of
    Right (Object fields) | KM.lookup "ok" fields == Just (Bool True) -> exitSuccess
    _ -> exitFailure

-- | Offline @reload-profiles@: validate the profiles of the loaded file as an
-- installation would and answer their identifiers and the revision of the
-- validation registry. Nothing is installed.
validateOffline :: Configuration -> IO BS.ByteString
validateOffline value = do
  validated <- validateConfigurationProfiles value
  pure $ case validated of
    Left _ -> adminError (Just "reload-profiles") StateConflict
    Right profiles -> adminSuccess "reload-profiles" (reloadedProfiles [(publicId profile, publicRevision profile) | profile <- profiles])

-- | Offline administration on a Store that this process opens. A Store that
-- cannot be opened answers @check-store@ with integrity @unavailable@. Every
-- other failure keeps its existing mapping.
offline :: LocalAdminRequest -> ((CoordinationStore -> IO BS.ByteString) -> IO BS.ByteString) -> IO BS.ByteString
offline request open = do
  entered <- newIORef False
  result <- try @StoreFailure (open (\store -> writeIORef entered True >> fst <$> administerLocally offlineAdministration store request))
  opened <- readIORef entered
  case (request, result) of
    (_, Right response) -> pure response
    (CheckStore, Left _) | not opened -> pure unavailableStoreCheck
    (_, Left failure) -> throwIO failure
