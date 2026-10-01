{-# LANGUAGE TypeApplications #-}
-- No Store or SQL instance. These checks exercise the production admission primitive.
module Agentic.Manager.Test.StoreAdmissionCheck (dataChecks, blocked, blockedOn) where

import Agentic.Manager.Store.Admission
import Control.Concurrent (threadDelay, throwTo)
import Control.Concurrent.Async (Async, asyncThreadId, withAsync, wait, waitCatch)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (UserInterrupt), IOException, fromException, throwIO, try)
import Control.Monad (unless, void, replicateM_)
import Data.IORef
import GHC.Conc (threadStatus, ThreadStatus (..), BlockReason (..))
import GHC.Clock (getMonotonicTimeNSec)
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check label ok = unless ok(error("FAIL "<>label)) >> putStrLn("PASS "<>label)
-- | Wait until the task's thread is blocked on an MVar. An idle event stream
-- reaches its next batch within one second, so the bound is four seconds.
blocked :: Async a -> IO ()
blocked = blockedOn BlockedOnMVar

-- | Wait until the task's thread is blocked for the given reason, within the
-- same four-second bound. A reader that waits for a returned place blocks in
-- STM, not on an MVar.
blockedOn :: BlockReason -> Async a -> IO ()
blockedOn reason task = timeout 4000000 loop >>= maybe(error "waiter did not block")pure
  where
    loop = do
      state <- threadStatus(asyncThreadId task)
      if state == ThreadBlocked reason then pure () else threadDelay 1000 >> loop

dataChecks :: IO ()
dataChecks = do
  check "waiting is subtracted from the original allowance, not reset"
    (remainingAt 0 4000000000==1000000 && remainingAt 0 5000000000==0 && remainingAt 10 9==0)
  gate <- newEmptyMVar
  calls <- newIORef (0::Int)
  let body _=modifyIORef' calls (+1)
  busy <- try @AdmissionFailure(withGate FailFast Nothing gate (pure ()) body)
  check "default admission refuses busy without running body" (busy==Left AdmissionBusy)
  withAsync (withGate WaitWithinBudget Nothing gate (pure ()) body) $ \task -> do
    blocked task
    readIORef calls >>= check "held gate never begins waiter body" . (==0)
    putMVar gate ()
    wait task
  readIORef calls >>= check "release admits original action once" . (==1)
  token <- tryTakeMVar gate
  check "successful action releases admission token" (token==Just ())
  withAsync (withGate WaitWithinBudget Nothing gate (pure ()) body) $ \task -> do
    blocked task
    throwTo (asyncThreadId task) UserInterrupt
    result <- waitCatch task
    check "waiting interruption preserves original exception"
      (case result of Left failure -> fromException failure==Just UserInterrupt; _ -> False)
  putMVar gate ()
  readIORef calls >>= check "interrupted waiter cannot execute when gate later opens" . (==1)
  forHealth gate calls "closed" (userError "closed")
  forHealth gate calls "poisoned" (userError "poisoned")
  failure <- try @IOException(withGate WaitWithinBudget Nothing gate (pure ()) (\_ -> modifyIORef' calls (+1) >> (throwIO(userError "admitted failure") :: IO ())))
  check "admitted exception is not retried" (failure==Left(userError "admitted failure"))
  readIORef calls >>= check "failed admitted action executed exactly once" . (==2)
  takeMVar gate
  expired <- try @AdmissionFailure(withGate WaitWithinBudget Nothing gate (pure ()) body)
  check "held gate exhausts allowance without entering body" (expired==Left AdmissionExpired)
  putMVar gate ()
  late <- try @AdmissionFailure(withGate WaitWithinBudget Nothing gate (threadDelay 5010000) body)
  check "post-acquisition expiry refuses before body instead of a second budget" (late==Left AdmissionExpired)
  readIORef calls >>= check "exhausted operations never execute later" . (==2)
  replicateM_ 30 $ withAsync (withGate WaitWithinBudget Nothing gate (pure ()) (\_ -> threadDelay 1000000)) $ \task -> do
    throwTo (asyncThreadId task) UserInterrupt
    void(waitCatch task)
    available <- tryTakeMVar gate
    unless (available==Just ()) (error "admission token leaked on interruption")
    putMVar gate ()
  putStrLn "PASS acquisition/action interruption does not leak original token"
  sharedDeadlineChecks gate calls
  where
    forHealth gate calls label failure = do
      takeMVar gate
      ready <- newIORef False
      withAsync (withGate WaitWithinBudget Nothing gate (readIORef ready >>= \refuse -> if refuse then throwIO failure else pure ()) (\_ -> modifyIORef' calls (+1))) $ \task -> do
        blocked task
        writeIORef ready True
        putMVar gate ()
        result <- waitCatch task
        check (label<>" recheck rejects acquired waiter before body")
          (case result of Left original -> fromException original==Just failure; _ -> False)
      readIORef calls >>= check (label<>" rejection never runs the action") . (==1)

-- | One admission deadline that several locks of one request share bounds
-- the sum of their waits. A free lock is no wait, so an expired deadline
-- still takes it. The operation allowance of an admitted action stays its own.
sharedDeadlineChecks :: MVar () -> IORef Int -> IO ()
sharedDeadlineChecks gate calls = do
  writeIORef calls 0
  let body _ = modifyIORef' calls (+1)
  lock <- newEmptyMVar
  request <- newDeadline
  withAsync (threadDelay 3000000 >> putMVar lock ()) $ \_ -> do
    first <- takeWithin request lock
    check "the first lock of a request is taken within the shared deadline" (first == Just ())
    takeMVar gate
    begun <- getMonotonicTimeNSec
    expired <- try @AdmissionFailure (withGate WaitWithinBudget (Just request) gate (pure ()) body)
    ended <- getMonotonicTimeNSec
    check "the gate wait after a three-second lock wait refuses when the shared deadline ends"
      (expired == Left AdmissionExpired)
    check "that gate wait used only the rest of the shared deadline, not a fresh allowance"
      (ended - begun >= 1500000000 && ended - begun < 2500000000)
  readIORef calls >>= check "an expired shared deadline never runs the action" . (== 0)
  putMVar gate ()
  putMVar lock ()
  late <- newDeadline
  threadDelay 5010000
  free <- takeWithin late lock
  check "a free lock is taken at once after its shared deadline ended" (free == Just ())
  admitted <- withGate WaitWithinBudget (Just late) gate (pure ()) (\operation -> do
    body operation
    maybe (pure 0) remainingMicros operation)
  check "a free gate admits an expired request deadline with a fresh operation allowance" (admitted > 4000000)
  readIORef calls >>= check "the admitted action ran once" . (== 1)
