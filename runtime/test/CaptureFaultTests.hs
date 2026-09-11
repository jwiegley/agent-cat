{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Agentic.Runtime.PrivateRoot
import Control.Concurrent (forkIO, killThread, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, finally, fromException, mask, try)
import Control.Monad (forM_, unless, void, when)
import qualified Data.ByteString as BS
import Data.IORef (atomicModifyIORef', newIORef)
import Foreign.C.Types (CInt (..), CULLong (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import System.Directory (doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly, renameDirectory)
import System.FilePath ((</>))
import qualified System.Posix.Directory as Directory
import System.Posix.Files (fileID, getFileStatus)
import System.Posix.IO (closeFd, createPipe)
import System.Posix.IO.ByteString (fdRead, fdWrite)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

main :: IO ()
main = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let bucket = temporary </> ("agentic-capture-fault-" <> show stamp)
      path = bucket </> "root"
  Directory.createDirectory bucket 0o700
  (withPrivateRoot "capture fault root" path $ \root -> do
    ensurePrivateDirectoryAt root ["one", "two"]
    forM_ [0 .. 4] $ \failure -> do
      configure failure 0 (-1) (-1)
      source <- chunks
      let name = "sync-" <> show failure
      result <- publishPrivateCaptureAt root ["one", "two", name] 8 source
      exists <- doesFileExist (path </> "one" </> "two" </> name)
      check "sync failure publication phase" $ case (failure, result) of
        (0, CapturePublished receipt) -> exists && privateCaptureBytes receipt == 8
        (1, CaptureNotPublished _) -> not exists
        (_, CaptureUnconfirmed receipt _) -> exists && privateCaptureBytes receipt == 8
        _ -> False
      when exists $ do
        actual <- readPrivateFileAt root ["one", "two", name] 8
        check "post-publication failure retains all bytes" (actual == "complete")
      if failure == 0 then do
        count <- syncCalls
        kinds <- mapM syncIsDirectory [0 .. 3]
        inodes <- mapM syncInode [1 .. 3]
        expected <- mapM (fmap (fromIntegral . fileID) . getFileStatus) [path </> "one" </> "two", path </> "one", path]
        check "file barrier then every parent barrier bottom-up" (count == 4 && kinds == [0, 1, 1, 1] && inodes == expected)
      else syncCalls >>= check "failure is not silently downgraded" . (== failure)
    forM_ [[], ["one"], ["one", "two"]] $ \components ->
      withPause $ \waitReady release -> do
        source <- chunks
        done <- newEmptyMVar
        worker <- forkIO $ mask $ \restore -> try @SomeException (restore (publishPrivateCaptureAt root ["one", "two", "after-link"] 8 source)) >>= putMVar done
        (do
          waitReady
          let replaced = foldl (</>) path components
              moved = replaced <> "-moved"
          renameDirectory replaced moved
          Directory.createDirectory replaced 0o700
          release
          outcome <- bounded (takeMVar done)
          check "post-link replacement is reported as unconfirmed" $ case outcome of
            Right (CaptureUnconfirmed _ _) -> True
            _ -> False
          listDirectory replaced >>= check "replacement directory remains empty" . null
          removePathForcibly replaced
          renameDirectory moved replaced
          readPrivateFileAt root ["one", "two", "after-link"] 8 >>= check "published bytes never rolled back" . (== "complete")
          removePrivateFileAt root ["one", "two", "after-link"]) `finally` (release >> killThread worker)
    withPause $ \waitReady release -> do
      source <- chunks
      done <- newEmptyMVar
      worker <- forkIO $ mask $ \restore -> try @SomeException (restore (publishPrivateCaptureAt root ["one", "two", "cancelled"] 8 source)) >>= putMVar done
      (do
        waitReady
        senderDone <- newEmptyMVar
        sender <- forkIO (killThread worker >> putMVar senderDone ())
        let awaitPending = do
              status <- threadStatus sender
              if status == ThreadBlocked BlockedOnException then pure () else yield >> awaitPending
        bounded awaitPending
        release
        outcome <- bounded (takeMVar done)
        bounded (takeMVar senderDone)
        check "post-link cancellation remains an asynchronous exception" $ case outcome of
          Left failure -> fromException failure == Just ThreadKilled
          _ -> False
        readPrivateFileAt root ["one", "two", "cancelled"] 8 >>= check "cancelled acknowledgement leaves installed bytes" . (== "complete")) `finally` (release >> killThread worker)
    configure 1 0 (-1) (-1)
    publishPrivateFileAt root ["legacy"] (\handle -> BS.hPut handle "unchanged")
    syncCalls >>= check "legacy publication does not acquire new barriers" . (== 0)
    configure 0 0 (-1) (-1)
    before <- listDirectory (path </> "one" </> "two")
    source <- chunks
    retry <- publishPrivateCaptureAt root ["one", "two", "sync-2"] 8 source
    after <- listDirectory (path </> "one" </> "two")
    check "retry after uncertain sync neither deletes nor replaces" $ before == after && case retry of
      CaptureNotPublished _ -> True
      _ -> False
    roleFaultTests bucket) `finally` removePathForcibly bucket
  putStrLn "capture and role fault tests passed: real barriers, injected sync errors, post-link replacement and cancellation"

roleFaultTests :: FilePath -> IO ()
roleFaultTests bucket = forM_ [1, 2] $ \failure ->
  withPrivateRoot "role fault root" (bucket </> ("role-" <> show failure)) $ \root -> do
    configure failure 0 (-1) (-1)
    initial <- try @SomeException (establishManagerRootRole root)
    check "failed role barrier refuses establishment" (case initial of Left _ -> True; Right () -> False)
    syncCalls >>= check "role establishment reaches expected failed barrier" . (== failure)
    role <- withPrivateDirectoryAt root [] readStateRootRoleAt
    check "role failure preserves publication phase" (role == if failure == 1 then UnmarkedStateRoot else ManagerStateRoot)
    configure 0 0 (-1) (-1)
    establishManagerRootRole root
    count <- syncCalls
    kinds <- mapM syncIsDirectory [0, 1]
    check "role establishment synchronizes file and root" (count == 2 && kinds == [0, 1])
    let marker = privateRootPath root </> ".agentic-root-role.json"
    before <- getFileStatus marker
    forM_ [1, 2] $ \failedAgain -> do
      configure failedAgain 0 (-1) (-1)
      retried <- try @SomeException (establishManagerRootRole root)
      check "existing role does not bypass failed synchronization" (case retried of Left _ -> True; Right () -> False)
      syncCalls >>= check "existing marker reaches failed barrier" . (== failedAgain)
    configure 0 0 (-1) (-1)
    establishManagerRootRole root
    syncCalls >>= check "existing role repeats both persistence barriers" . (== 2)
    after <- getFileStatus marker
    check "uncertain existing role is never replaced" (fileID before == fileID after)
    readPrivateFileAt root [".agentic-root-role.json"] 256 >>= check "role bytes survive synchronization failures" . (== "{\"version\":1,\"role\":\"manager\"}\n")

chunks :: IO (IO BS.ByteString)
chunks = do
  state <- newIORef ["complete"]
  pure $ atomicModifyIORef' state $ \current -> case current of
    [] -> ([], BS.empty)
    next : rest -> (rest, next)

withPause :: (IO () -> IO () -> IO a) -> IO a
withPause action = bracket createPipe closePair $ \(readyRead, Fd readyWrite) ->
  bracket createPipe closePair $ \(Fd releaseRead, releaseWrite) -> do
    configure 0 2 readyWrite releaseRead
    action (bounded (void (fdRead readyRead 1))) (void (fdWrite releaseWrite "x"))
  where
    closePair (readEnd, writeEnd) = closeFd readEnd `finally` closeFd writeEnd

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError label))


bounded :: IO a -> IO a
bounded action = timeout 5000000 action >>= maybe (ioError (userError "capture fault test deadline")) pure

foreign import ccall unsafe "capture_configure_sync" configure :: CInt -> CInt -> CInt -> CInt -> IO ()
foreign import ccall unsafe "capture_sync_calls" syncCalls :: IO CInt
foreign import ccall unsafe "capture_sync_inode" syncInode :: CInt -> IO CULLong
foreign import ccall unsafe "capture_sync_is_directory" syncIsDirectory :: CInt -> IO CInt
