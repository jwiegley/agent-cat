{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module BucketEvidence (withCaptureBucket, bucketEvidenceChecks) where

import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, sort)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (getTemporaryDirectory, listDirectory)
import System.FilePath ((</>), takeFileName)
import qualified System.Posix.Directory as Directory
import System.Posix.Files (fileID, fileMode, getFileStatus, modificationTimeHiRes, setFileMode, statusChangeTimeHiRes)

-- Retain the diagnostic bucket whether its action returns or raises.
withCaptureBucket :: String -> FilePath -> (FilePath -> IO a) -> IO a
withCaptureBucket prefix temporary action = do
  stamp <- getMonotonicTimeNSec
  let bucket = temporary </> (prefix <> show stamp)
  Directory.createDirectory bucket 0o700
  action bucket

bucketEvidenceChecks :: String -> IO ()
bucketEvidenceChecks prefix = do
  temporary <- getTemporaryDirectory
  let firstBytes = BS.pack [0, 255] <> "first\r\n\n"
      failedBytes = BS.pack [254, 0] <> "body failure\n\n"
      secondBytes = "different repeat\n\n"
      emit bucket bytes = do
        let file = bucket </> "evidence.bin"
        BS.writeFile file bytes
        setFileMode file 0o600
      retained bucket bytes = do
        check "bucket uses supplied prefix" (prefix `isPrefixOf` takeFileName bucket)
        BS.readFile (bucket </> "evidence.bin") >>= check "bucket retains exact action bytes" . (== bytes)
        getFileStatus bucket >>= check "retained bucket remains private" . (== 0o700) . (.&. 0o777) . fileMode
        getFileStatus (bucket </> "evidence.bin") >>= check "retained data remains private" . (== 0o600) . (.&. 0o777) . fileMode
      identity path = do
        status <- getFileStatus path
        pure (fileID status, fileMode status, modificationTimeHiRes status, statusChangeTimeHiRes status)
  first <- withCaptureBucket prefix temporary $ \bucket -> emit bucket firstBytes >> pure bucket
  retained first firstBytes
  failedPath <- newIORef Nothing
  let primary = userError "capture bucket inert body failure"
  outcome <- try @IOException $ withCaptureBucket prefix temporary $ \bucket -> do
    writeIORef failedPath (Just bucket)
    emit bucket failedBytes
    throwIO primary :: IO ()
  check "bucket preserves the specific body exception" (case outcome of Left failure -> show failure == show primary; Right () -> False)
  failed <- readIORef failedPath >>= maybe (ioError (userError "inert body did not run")) pure
  retained failed failedBytes
  before <- mapM identity [first, first </> "evidence.bin", failed, failed </> "evidence.bin"]
  second <- withCaptureBucket prefix temporary $ \bucket -> emit bucket secondBytes >> pure bucket
  check "repeated bucket allocations are distinct" (first /= failed && first /= second && failed /= second)
  retained second secondBytes
  retained first firstBytes
  retained failed failedBytes
  after <- mapM identity [first, first </> "evidence.bin", failed, failed </> "evidence.bin"]
  check "repeat does not change prior bucket metadata" (before == after)
  let obstruction = second </> "not-a-directory"
  BS.writeFile obstruction "allocation obstruction\n"
  setFileMode obstruction 0o600
  called <- newIORef False
  refused <- try @IOException (withCaptureBucket prefix obstruction (\_ -> writeIORef called True))
  check "bucket allocation obstruction refuses" (case refused of Left _ -> True; Right () -> False)
  readIORef called >>= check "failed allocation cannot invoke action" . not
  BS.readFile obstruction >>= check "failed allocation preserves obstruction" . (== "allocation obstruction\n")
  (sort <$> listDirectory second) >>= check "failed allocation creates no output" . (== ["evidence.bin", "not-a-directory"])

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError label))
