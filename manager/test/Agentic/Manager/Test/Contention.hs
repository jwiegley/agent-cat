-- | Controlled holders of the Store gate and the configuration guard. Each
-- holder keeps its lock until the check releases it, and each check proves a
-- waiter blocked on the lock before it acts, so no outcome depends on timing.
module Agentic.Manager.Test.Contention (blocked, newMarker, blockedSince, withHeldStore, withHeldConfiguration) where

import Agentic.Manager.Store
import Agentic.Manager.Test.StoreAdmissionCheck (blocked)
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.Async (async, cancel, wait)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Exception (bracket)
import Control.Monad (void)
import GHC.Conc (ThreadStatus (..), BlockReason (..), threadStatus)
import GHC.Conc.Sync (listThreads)
import System.Timeout (timeout)

-- | A thread identifier that orders before every thread created later.
newMarker :: IO ThreadId
newMarker = forkIO (pure ())

-- | Wait until a thread created after the marker is blocked on an MVar. An
-- operation that runs its work in a thread of its own is proved waiting this
-- way, because the caller's own thread waits in STM for the result.
blockedSince :: ThreadId -> IO ()
blockedSince marker = timeout 4000000 loop >>= maybe (error "no later thread blocked") pure
  where
    loop = do
      later <- filter (> marker) <$> listThreads
      states <- mapM threadStatus later
      if any (== ThreadBlocked BlockedOnMVar) states then pure () else threadDelay 1000 >> loop

-- | Hold the Store gate inside an admitted transaction that changes nothing,
-- until the check calls the supplied release action or the holder's own
-- five-second allowance ends. The holder's commit clock blocks inside the
-- gate, so the transaction owns the gate while the check runs.
withHeldStore :: CoordinationStore -> (IO () -> IO a) -> IO a
withHeldStore store action = do
  held <- newEmptyMVar
  resume <- newEmptyMVar
  let clock = putMVar held () >> readMVar resume >> pure 0
      release = void (tryPutMVar resume ())
  withCommitDeadline store clock 1 $ \guard ->
    bracket (async (runTransaction store (enforceCommitDeadline guard >> pure ((), []))))
      (\holder -> release >> cancel holder) $ \holder -> do
        timeout 1000000 (takeMVar held) >>= maybe (error "Store holder not admitted") pure
        value <- action release
        release
        wait holder
        pure value

-- | Hold the configuration guard in a separate thread until the check calls
-- the supplied release action.
withHeldConfiguration :: CoordinationStore -> (IO () -> IO a) -> IO a
withHeldConfiguration store action = do
  held <- newEmptyMVar
  resume <- newEmptyMVar
  let release = void (tryPutMVar resume ())
      holding = withStoreConfiguration store (\_ _ -> putMVar held () >> readMVar resume)
  bracket (async holding) (\holder -> release >> cancel holder) $ \holder -> do
    timeout 1000000 (takeMVar held) >>= maybe (error "configuration holder not admitted") pure
    value <- action release
    release
    wait holder >>= either (error . show) pure
    pure value
