{-# LANGUAGE OverloadedStrings #-}
-- Test-only observations used by the exact compiled Commands instrumentation.
module Agentic.Manager.Test.AcceptanceAudit
  ( Audit, withAcceptanceAudit, waitAccepted, auditSummary,
    afterFreshCommit, recordReconciliation, recordDelivery ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.MVar
import Control.Exception (bracket)
import Control.Monad (unless, void)
import Data.Dynamic (Dynamic, Typeable, toDyn, fromDynamic)
import Data.IORef
import Data.Text (Text)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

data Anchor = Anchor !Text !Dynamic !Dynamic
data Audit = Audit !(IORef (Maybe Anchor)) !(MVar (ThreadId,Text)) !(MVar ()) !(IORef (Int,Int,Bool,Bool))

{-# NOINLINE currentAudit #-}
currentAudit :: MVar (Maybe Audit)
currentAudit = unsafePerformIO (newMVar Nothing)

withAcceptanceAudit :: (Audit -> IO a) -> IO a
withAcceptanceAudit = bracket acquire release
  where
    acquire = do
      audit <- Audit <$> newIORef Nothing <*> newEmptyMVar <*> newEmptyMVar <*> newIORef (0,0,True,True)
      modifyMVar_ currentAudit $ \old -> case old of Nothing->pure(Just audit);Just _->error "audit already active"
      pure audit
    release (Audit _ _ stop _) = do
      void(tryPutMVar stop ())
      modifyMVar_ currentAudit (const(pure Nothing))

waitAccepted :: Audit -> IO (ThreadId,Text)
waitAccepted (Audit _ entered _ _) = timeout 5000000(takeMVar entered) >>= maybe(error "fresh acceptance boundary was not reached")pure

auditSummary :: Audit -> IO (Int,Int,Bool,Bool)
auditSummary (Audit _ _ _ counts)=readIORef counts

-- The sole rendezvous is after a fresh successful real transaction, before publication.
afterFreshCommit :: (Typeable a,Typeable b) => Text -> IORef a -> IORef b -> IO ()
afterFreshCommit command ticket attempt = readMVar currentAudit >>= mapM_ enter
  where
    enter (Audit anchor entered stop _) = do
      first <- atomicModifyIORef' anchor $ \old -> case old of
        Nothing -> (Just(Anchor command (toDyn ticket) (toDyn attempt)),True)
        Just _ -> (old,False)
      if not first then pure() else do
        thread <- myThreadId
        putMVar entered(thread,command)
        ended <- timeout 5000000(takeMVar stop)
        unless(ended==Just())(error "fresh acceptance boundary interruption timed out")

sameReference :: Typeable a => IORef a -> Dynamic -> Bool
sameReference actual original=maybe False (==actual)(fromDynamic original)

recordReconciliation :: (Typeable a,Typeable b) => Text -> IORef a -> IORef b -> IO ()
recordReconciliation command ticket attempt = readMVar currentAudit >>= mapM_ (\(Audit anchor _ _ counts)->do
  original <- readIORef anchor
  case original of
    Just(Anchor ident oldTicket oldAttempt) | ident==command -> atomicModifyIORef' counts $ \(reconciled,delivered,sameTicket,sameAttempt)->
      ((reconciled+1,delivered,sameTicket && sameReference ticket oldTicket,sameAttempt && sameReference attempt oldAttempt),())
    _ -> pure())

recordDelivery :: Typeable a => Text -> IORef a -> IO ()
recordDelivery command ticket = readMVar currentAudit >>= mapM_ (\(Audit anchor _ _ counts)->do
  original <- readIORef anchor
  case original of
    Just(Anchor ident oldTicket _) | ident==command -> atomicModifyIORef' counts $ \(reconciled,delivered,sameTicket,sameAttempt)->
      ((reconciled,delivered+1,sameTicket && sameReference ticket oldTicket,sameAttempt),())
    _ -> pure())
