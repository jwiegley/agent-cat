{-# LANGUAGE OverloadedStrings #-}

-- | Capture of the private standard error log for the fault record checks.
module Agentic.Manager.Test.PrivateLog (withPrivateStderr, recordCount) where

import Control.Exception (bracket, finally)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (WriteMode), hClose, hFlush, openFile, stderr)

-- | Run one action with standard error redirected to a private file, and
-- return the action result with the captured bytes.
withPrivateStderr :: FilePath -> IO a -> IO (a, BS.ByteString)
withPrivateStderr path action = do
  hFlush stderr
  saved <- hDuplicate stderr
  result <- bracket (openFile path WriteMode) hClose $ \handle -> do
    hDuplicateTo handle stderr
    action `finally` (hFlush stderr >> hDuplicateTo saved stderr)
  hClose saved
  bytes <- BS.readFile path
  pure (result, bytes)

-- | The number of private fault lines that end with this suffix.
recordCount :: BS.ByteString -> Text -> Int
recordCount recorded suffix =
  length [line | line <- T.lines (TE.decodeUtf8 recorded), "manager-fault " `T.isPrefixOf` line, suffix `T.isSuffixOf` line]
