{-# LANGUAGE OverloadedStrings #-}
-- Compiled fixture instrumentation only. No Runtime state or callback is changed.
module ControlDeliveryAudit (beforeControlDelivery, afterAttemptRetired, beforeControlRead) where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Timeout (timeout)

beforeControlRead :: Int -> IO ()
beforeControlRead bufferedBytes = do
  barrier <- lookupEnv "AGENT_CAT_TEST_CONTROL_READ_BARRIER"
  case barrier of
    Nothing -> pure ()
    Just path -> do
      writeFile (path <> ".ready") (show bufferedBytes)
      let wait = doesFileExist (path <> ".release") >>= \released -> unless released (threadDelay 1000 >> wait)
      ended <- timeout 60000000 wait
      unless (ended == Just ()) (error "original control reader barrier expired")

afterAttemptRetired :: Text -> IO ()
afterAttemptRetired attempt = lookupEnv "AGENT_CAT_TEST_CONTROL_BARRIER" >>= mapM_ (\path ->
  Text.writeFile (path <> ".retired") attempt)

beforeControlDelivery :: Text -> IO ()
beforeControlDelivery ident = do
  barrier <- lookupEnv "AGENT_CAT_TEST_CONTROL_BARRIER"
  case barrier of
    Nothing -> pure ()
    Just path -> do
      Text.writeFile (path <> ".accepted") ident
      let wait = doesFileExist (path <> ".release") >>= \released -> unless released (threadDelay 1000 >> wait)
      ended <- timeout 60000000 wait
      unless (ended == Just ()) (error "original control delivery barrier expired")
