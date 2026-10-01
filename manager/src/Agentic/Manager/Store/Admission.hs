{-# LANGUAGE OverloadedStrings #-}

-- | Admission to one Store operation, with no SQL activity while waiting.
module Agentic.Manager.Store.Admission
  ( StoreAdmission (..), AdmissionFailure (..), Deadline,
    withGate, newDeadline, takeWithin, remainingMicros, remainingAt, waitDetail, releaseOnce ) where

import Control.Concurrent.MVar (MVar, takeMVar, tryTakeMVar, putMVar)
import Control.Exception (Exception, mask, mask_, finally, throwIO)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Timeout (timeout)

-- | The admission policy for a single original Store action, not retry authority.
data StoreAdmission = FailFast | WaitWithinBudget deriving (Eq, Show)
data AdmissionFailure = AdmissionBusy | AdmissionExpired deriving (Eq, Show)
instance Exception AdmissionFailure

-- | The monotonic start of the unchanged five-second operation allowance.
newtype Deadline = Deadline Word64

remainingAt :: Word64 -> Word64 -> Int
remainingAt start now
  | now < start = 0
  | otherwise = fromInteger (max 0 (5000000 - (toInteger now - toInteger start + 999) `div` 1000))

-- | The start of one fresh allowance at the current monotonic time.
newDeadline :: IO Deadline
newDeadline = Deadline <$> getMonotonicTimeNSec

-- | The elapsed wait and the remaining allowance of one deadline, in whole
-- milliseconds, as fixed words for a private record. A site that does not
-- wait has no deadline, and its record names no allowance.
waitDetail :: Maybe Deadline -> IO Text
waitDetail Nothing = pure "elapsed=0ms remaining=none"
waitDetail (Just (Deadline start)) = do
  now <- getMonotonicTimeNSec
  let elapsed = if now < start then 0 else (now - start) `div` 1000000
      milliseconds value = T.pack (show value) <> "ms"
  pure ("elapsed=" <> milliseconds elapsed <> " remaining=" <> milliseconds (remainingAt start now `div` 1000))

-- | Take a lock before the allowance ends. Nothing proves that the lock was
-- not taken. The caller masks asynchronous exceptions, so a taken value
-- cannot be lost between the take and the caller's release handler.
takeWithin :: Deadline -> MVar a -> IO (Maybe a)
takeWithin end lock = remainingMicros end >>= \left -> timeout left (takeMVar lock)

remainingMicros :: Deadline -> IO Int
remainingMicros (Deadline start) = do
  now <- getMonotonicTimeNSec
  let left = remainingAt start now
  if left > 0 then pure left else throwIO AdmissionExpired

-- Acquisition stays masked so interruption cannot lose a successfully taken token.
-- The supplied health check runs after acquisition, before the action is exposed.
withGate :: StoreAdmission -> MVar () -> IO () -> (Maybe Deadline -> IO a) -> IO a
withGate policy gate check action = mask $ \restore -> do
  deadline <- case policy of
    FailFast -> pure Nothing
    WaitWithinBudget -> Just <$> newDeadline
  token <- case deadline of
    Nothing -> tryTakeMVar gate
    Just end -> takeWithin end gate
  case token of
    Nothing -> throwIO (case policy of FailFast -> AdmissionBusy; WaitWithinBudget -> AdmissionExpired)
    Just () -> (check >> mapM_ (void . remainingMicros) deadline >> restore (action deadline))
      `finally` putMVar gate ()

-- | A release action that runs at most once. A loan owner calls it at the end
-- of its scope, and a response calls it earlier, before its first network
-- write. Later calls do nothing. The release runs with asynchronous
-- exceptions masked, so an interruption cannot lose the returned loan.
releaseOnce :: IO () -> IO (IO ())
releaseOnce release = do
  pending <- newIORef True
  pure $ mask_ $ do
    first <- atomicModifyIORef' pending (\current -> (False, current))
    if first then release else pure ()
