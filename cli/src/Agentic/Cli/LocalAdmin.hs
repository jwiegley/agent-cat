{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Frozen stdin administration through the selected local authority.
module Agentic.Cli.LocalAdmin (runLocalAdmin) where

import Agentic.Manager.Configuration
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.LocalAdmin (callLocalAdministration)
import Agentic.Manager.Profile (Diagnostic)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Store (StoreFailure, withCoordinationStore)
import Control.Exception (IOException, bracket, try)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import System.Exit (exitFailure, exitSuccess)
import System.IO (stdin, stdout)

-- A configured channel is authoritative even when unavailable. Only omission
-- selects offline ownership, including the normal restart reconciliation.
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
                case configuration of
                  Left _ -> pure (adminError (Just (adminOperation request)) StorageUnavailable)
                  Right value -> do
                    live <- callLocalAdministration value bytes
                    case live of
                      Just response -> pure response
                      Nothing -> do
                        installed <- installConfiguration value
                        case installed of
                          Left _ -> pure (adminError (Just (adminOperation request)) StorageUnavailable)
                          Right owner -> bracket (pure owner) closeConfiguration $ \active ->
                            withCoordinationStore active $ \store -> administerCredentials store request
        pure $ case result of
          Right (Right (Right response)) -> response
          _ -> adminError (Just (adminOperation request)) StorageUnavailable
  BS.hPut stdout (output <> "\n")
  case eitherDecodeStrict' output of
    Right (Object fields) | KM.lookup "ok" fields == Just (Bool True) -> exitSuccess
    _ -> exitFailure
