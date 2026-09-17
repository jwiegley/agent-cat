{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module CaptureTests (captureTests, captureBucketEvidenceData, withCaptureBucket, bucketEvidenceChecks) where

import Agentic.Runtime
import BucketEvidence (withCaptureBucket, bucketEvidenceChecks)
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, finally, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import System.Directory (doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly, renameDirectory)
import System.FilePath ((</>))
import qualified System.Posix.Directory as Directory
import System.Posix.Files (createSymbolicLink, fileMode, getFileStatus)
import System.Posix.IO (OpenFileFlags (cloexec, directory, nofollow), OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

captureTests :: IO ()
captureTests = do
  captureBucketEvidenceData
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-capture-" temporary $ \bucket -> do
    let path = bucket </> "root"
    withPrivateRoot "capture test root" path $ \root -> do
      -- Establish the fixture's root namespace before testing relative publication.
      mapM_ syncDirectory [path, bucket, temporary]
      ensurePrivateDirectoryAt root ["one", "two"]
      let bytes = TE.encodeUtf8 "λ\r\ntext\n\n" <> BS.pack [0, 255]
      forM_ [("empty", [], BS.empty), ("exact", [bytes], bytes), ("chunks", [BS.take 3 bytes, BS.drop 3 bytes], bytes)] $ \(name, chunks, expected) -> do
        source <- chunksOf chunks
        receipt <- publishPrivateCaptureAt root ["one", "two", name] (toInteger (BS.length expected)) source >>= confirmed
        actual <- readPrivateFileAt root ["one", "two", name] (toInteger (BS.length expected))
        status <- getFileStatus (path </> "one" </> "two" </> name)
        check "capture bytes, name, count, digest and private mode" $
          actual == expected && privateCapturePath receipt == ["one", "two", name]
            && privateCaptureBytes receipt == toInteger (BS.length expected)
            && privateCaptureSha256 receipt == digest expected && fileMode status .&. 0o777 == 0o600
      source <- chunksOf ["123", "45"]
      refused <- publishPrivateCaptureAt root ["oversize"] 4 source
      absent <- not <$> doesFileExist (path </> "oversize")
      check "oversize stream publishes no partial final" (notPublished refused && absent)
      called <- newIORef False
      forM_ [([], 1), (["..", "bad"], 1), (["bad/name"], 1), (["nul\NULname"], 1), (["negative"], -1)] $ \(name, bound) -> do
        result <- publishPrivateCaptureAt root name bound (writeIORef called True >> pure "x")
        check "invalid capture arguments refuse" (notPublished result)
      readIORef called >>= check "invalid arguments do not call producer" . not
      sourceFailure <- publishPrivateCaptureAt root ["source-failure"] 10 (ioError (userError "source failed"))
      sourceAbsent <- not <$> doesFileExist (path </> "source-failure")
      check "source error publishes nothing" (notPublished sourceFailure && sourceAbsent)
      writePrivateExclusiveAt root ["existing"] "original"
      Directory.createDirectory (path </> "directory") 0o700
      createSymbolicLink (path </> "existing") (path </> "link")
      forM_ ["existing", "directory", "link"] $ \name -> do
        chunks <- chunksOf ["replacement"]
        result <- publishPrivateCaptureAt root [name] 11 chunks
        check "no existing entry is replaced" (notPublished result)
      readPrivateFileAt root ["existing"] 8 >>= check "existing bytes preserved" . (== "original")
      createSymbolicLink (path </> "existing") (path </> ".agentic-tmp-stale")
      staleSource <- chunksOf ["after stale"]
      void (publishPrivateCaptureAt root ["after-stale"] 11 staleSource >>= confirmed)
      doesFileExist (path </> ".agentic-tmp-stale") >>= check "unowned stale temporary preserved"
      completions <- forM [1 .. 8] $ \index -> do
        done <- newEmptyMVar
        _ <- forkIO $ do
          chunks <- chunksOf [BS.replicate 32 index]
          try @SomeException (publishPrivateCaptureAt root ["winner"] 32 chunks) >>= putMVar done
        pure done
      outcomes <- mapM (bounded . takeMVar) completions
      winner <- readPrivateFileAt root ["winner"] 32
      check "concurrent publications have exactly one complete winner" $
        length [() | Right (CapturePublished _) <- outcomes] == 1
          && length [() | Right (CaptureNotPublished _) <- outcomes] == 7
          && winner `elem` [BS.replicate 32 index | index <- [1 .. 8]]
      started <- newEmptyMVar
      release <- newEmptyMVar
      finished <- newEmptyMVar
      chunks <- chunksOf ["partial"]
      let interruptedSource = do
            chunk <- chunks
            if BS.null chunk then putMVar started () >> takeMVar release >> pure BS.empty else pure chunk
      worker <- forkIO $ try @SomeException (publishPrivateCaptureAt root ["interrupted"] 10 interruptedSource) >>= putMVar finished
      (do
        bounded (takeMVar started)
        killThread worker
        outcome <- bounded (takeMVar finished)
        missing <- not <$> doesFileExist (path </> "interrupted")
        check "cancellation remains cancellation and publishes no partial file" $
          missing && case outcome of
            Left failure -> fromException failure == Just ThreadKilled
            Right _ -> False) `finally` killThread worker
      bracket (openPrivateRoot "closing capture root" path) closePrivateRoot $ \closing -> do
        result <- publishPrivateCaptureAt closing ["closed"] 0 (closePrivateRoot closing >> pure BS.empty)
        check "capture refuses confirmation after root close" (notPublished result)
      forM_ [[], ["one"], ["one", "two"]] $ \components -> do
        let replaced = foldl (</>) path components
            moved = replaced <> "-moved"
        sourceOnce <- chunksOf ["complete"]
        let movingSource = do
              chunk <- sourceOnce
              if BS.null chunk
                then renameDirectory replaced moved >> Directory.createDirectory replaced 0o700 >> pure BS.empty
                else pure chunk
        result <- publishPrivateCaptureAt root ["one", "two", "moved"] 8 movingSource
        check "changed root or parent refuses before publication" (notPublished result)
        names <- listDirectory replaced
        check "replacement directory receives no writes" (null names)
        removePathForcibly replaced
        renameDirectory moved replaced
        doesFileExist (path </> "one" </> "two" </> "moved") >>= check "retained directory has no rejected final" . not
      lostSource <- chunksOf ["retained"]
      void (publishPrivateCaptureAt root ["lost-reply"] 8 lostSource >>= confirmed)
      retrySource <- chunksOf ["different"]
      retried <- publishPrivateCaptureAt root ["lost-reply"] 9 retrySource
      bytesAfterRetry <- readPrivateFileAt root ["lost-reply"] 8
      check "lost receipt cannot cause overwrite" (notPublished retried && bytesAfterRetry == "retained")
      names <- listDirectory path
      check "owned temporary files were cleaned" (filter (T.isPrefixOf ".agentic-tmp-" . T.pack) names == [".agentic-tmp-stale"])
  putStrLn "capture tests passed: bytes, limits, exclusivity, cancellation, retained parents and lost replies"

-- This entrypoint uses ordinary files only, never Runtime PrivateRoot or capture publication.
captureBucketEvidenceData :: IO ()
captureBucketEvidenceData = do
  bucketEvidenceChecks "agentic-capture-"
  putStrLn "PASS capture bucket evidence data-only checks"

chunksOf :: [BS.ByteString] -> IO (IO BS.ByteString)
chunksOf chunks = do
  state <- newIORef chunks
  pure $ atomicModifyIORef' state $ \current -> case current of
    [] -> ([], BS.empty)
    next : rest -> (rest, next)

confirmed :: CapturePublication -> IO PrivateCapture
confirmed (CapturePublished receipt) = pure receipt
confirmed other = ioError (userError ("expected confirmed publication: " <> show other))

notPublished :: CapturePublication -> Bool
notPublished (CaptureNotPublished _) = True
notPublished _ = False

digest :: BS.ByteString -> T.Text
digest bytes = T.pack (show (hash bytes :: Digest SHA256))

check :: String -> Bool -> IO ()
check label condition = unless condition (ioError (userError label))

bounded :: IO a -> IO a
bounded action = timeout 5000000 action >>= maybe (throwIO (userError "capture test deadline")) pure

syncDirectory :: FilePath -> IO ()
syncDirectory path = bracket (openFd path ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}) closeFd $ \(Fd descriptor) ->
  void (throwErrnoIfMinus1Retry "fixture directory synchronization" (syncFixture descriptor))

foreign import ccall safe "agentic_sync_private_descriptor" syncFixture :: CInt -> IO CInt
