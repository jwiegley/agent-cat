{-# LANGUAGE TypeApplications #-}
-- No Store or SQL instance. These checks exercise the production admission primitive.
module StoreAdmissionCheck (dataChecks, blocked) where

import Agentic.Manager.Store.Admission
import Control.Concurrent (threadDelay, throwTo)
import Control.Concurrent.Async (Async, asyncThreadId, withAsync, wait, waitCatch)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (UserInterrupt), IOException, fromException, throwIO, try)
import Control.Monad (unless, void, replicateM_)
import Data.IORef
import GHC.Conc (threadStatus, ThreadStatus (..), BlockReason (..))
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check label ok = unless ok(error("FAIL "<>label)) >> putStrLn("PASS "<>label)
blocked :: Async a -> IO ()
blocked task = timeout 1000000 loop >>= maybe(error "waiter did not block")pure
  where
    loop = do
      state <- threadStatus(asyncThreadId task)
      case state of ThreadBlocked BlockedOnMVar -> pure (); _ -> threadDelay 1000 >> loop

dataChecks :: IO ()
dataChecks = do
  check "waiting is subtracted from the original allowance, not reset"
    (remainingAt 0 4000000000==1000000 && remainingAt 0 5000000000==0 && remainingAt 10 9==0)
  gate <- newEmptyMVar
  calls <- newIORef (0::Int)
  let body _=modifyIORef' calls (+1)
  busy <- try @AdmissionFailure(withGate FailFast gate (pure ()) body)
  check "default admission refuses busy without running body" (busy==Left AdmissionBusy)
  withAsync (withGate WaitWithinBudget gate (pure ()) body) $ \task -> do
    blocked task
    readIORef calls >>= check "held gate never begins waiter body" . (==0)
    putMVar gate ()
    wait task
  readIORef calls >>= check "release admits original action once" . (==1)
  token <- tryTakeMVar gate
  check "successful action releases admission token" (token==Just ())
  withAsync (withGate WaitWithinBudget gate (pure ()) body) $ \task -> do
    blocked task
    throwTo (asyncThreadId task) UserInterrupt
    result <- waitCatch task
    check "waiting interruption preserves original exception"
      (case result of Left failure -> fromException failure==Just UserInterrupt; _ -> False)
  putMVar gate ()
  readIORef calls >>= check "interrupted waiter cannot execute when gate later opens" . (==1)
  forHealth gate calls "closed" (userError "closed")
  forHealth gate calls "poisoned" (userError "poisoned")
  failure <- try @IOException(withGate WaitWithinBudget gate (pure ()) (\_ -> modifyIORef' calls (+1) >> (throwIO(userError "admitted failure") :: IO ())))
  check "admitted exception is not retried" (failure==Left(userError "admitted failure"))
  readIORef calls >>= check "failed admitted action executed exactly once" . (==2)
  takeMVar gate
  expired <- try @AdmissionFailure(withGate WaitWithinBudget gate (pure ()) body)
  check "held gate exhausts allowance without entering body" (expired==Left AdmissionExpired)
  putMVar gate ()
  late <- try @AdmissionFailure(withGate WaitWithinBudget gate (threadDelay 5010000) body)
  check "post-acquisition expiry refuses before body instead of a second budget" (late==Left AdmissionExpired)
  readIORef calls >>= check "exhausted operations never execute later" . (==2)
  replicateM_ 30 $ withAsync (withGate WaitWithinBudget gate (pure ()) (\_ -> threadDelay 1000000)) $ \task -> do
    throwTo (asyncThreadId task) UserInterrupt
    void(waitCatch task)
    available <- tryTakeMVar gate
    unless (available==Just ()) (error "admission token leaked on interruption")
    putMVar gate ()
  putStrLn "PASS acquisition/action interruption does not leak original token"
  where
    forHealth gate calls label failure = do
      takeMVar gate
      ready <- newIORef False
      withAsync (withGate WaitWithinBudget gate (readIORef ready >>= \refuse -> if refuse then throwIO failure else pure ()) (\_ -> modifyIORef' calls (+1))) $ \task -> do
        blocked task
        writeIORef ready True
        putMVar gate ()
        result <- waitCatch task
        check (label<>" recheck rejects acquired waiter before body")
          (case result of Left original -> fromException original==Just failure; _ -> False)
      readIORef calls >>= check (label<>" rejection never runs the action") . (==1)
