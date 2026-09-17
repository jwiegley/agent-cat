-- | Admission to one Store operation, with no SQL activity while waiting.
module Agentic.Manager.Store.Admission
  ( StoreAdmission (..), AdmissionFailure (..), Deadline,
    withGate, remainingMicros, remainingAt ) where

import Control.Concurrent.MVar (MVar, takeMVar, tryTakeMVar, putMVar)
import Control.Exception (Exception, mask, finally, throwIO)
import Control.Monad (void)
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
    WaitWithinBudget -> Just . Deadline <$> getMonotonicTimeNSec
  token <- case deadline of
    Nothing -> tryTakeMVar gate
    Just end -> remainingMicros end >>= \left -> timeout left (takeMVar gate)
  case token of
    Nothing -> throwIO (case policy of FailFast -> AdmissionBusy; WaitWithinBudget -> AdmissionExpired)
    Just () -> (check >> mapM_ (void . remainingMicros) deadline >> restore (action deadline))
      `finally` putMVar gate ()
