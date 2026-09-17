{-# LANGUAGE OverloadedStrings #-}
-- Test-only observations used by the exact compiled Commands instrumentation.
module Agentic.Manager.Test.AcceptanceAudit
  ( ReviewAudit, withReviewAudit, waitReviewed, releaseReviewed, afterCurrentReview,
    Audit, withAcceptanceAudit, withDeliveryAudit, waitAccepted, waitReturned, auditSummary,
    afterFreshCommit, afterNativeReturn, recordReconciliation, recordDelivery,
    atSqlStep, retainSqlInterrupt, rescueSql,
    FrameAudit, withFrameAudit, waitFramePrefix, frameSummary, writeControlFrame,
    recordControlWait, waitControlWaiter ) where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (bracket, uninterruptibleMask_)
import Control.Monad (unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import System.IO (Handle, hFlush)
import Data.Dynamic (Dynamic, Typeable, toDyn, fromDynamic)
import Data.IORef
import Data.Text (Text)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

-- The audit retains only the original Handle identity and bounded measurements.
data FrameAudit = FrameAudit !(IORef (Maybe Handle)) !(MVar ()) !(IORef (Int,Int,Int,Text,Bool))
{-# NOINLINE currentFrameAudit #-}
currentFrameAudit :: MVar (Maybe FrameAudit)
currentFrameAudit = unsafePerformIO(newMVar Nothing)

withFrameAudit :: (FrameAudit -> IO a) -> IO a
withFrameAudit = bracket acquire (const(modifyMVar_ currentFrameAudit (const(pure Nothing))))
  where
    acquire = do
      audit <- FrameAudit <$> newIORef Nothing <*> newEmptyMVar <*> newIORef(0,0,0,"",True)
      modifyMVar_ currentFrameAudit $ \old -> case old of Nothing->pure(Just audit);_->error "concurrent frame audit"
      pure audit

waitFramePrefix :: FrameAudit -> IO ()
waitFramePrefix (FrameAudit _ ready _) = timeout 5000000(readMVar ready) >>= maybe(error "original flushed prefix not observed")pure
frameSummary :: FrameAudit -> IO (Int,Int,Int,Text,Bool)
frameSummary (FrameAudit _ _ summary) = readIORef summary

-- Called inside the original single five-second deadline in compiled fixtures.
writeControlFrame :: Handle -> BS.ByteString -> IO ()
writeControlFrame pipe frame = do
  active <- readMVar currentFrameAudit
  case active of
    Nothing -> normal
    Just(FrameAudit original ready summary) -> do
      first <- atomicModifyIORef' original $ \old -> case old of Nothing->(Just pipe,True);_->(old,False)
      if not first then normal else do
        let size=BS.length frame
            prefixBytes=max 1 (min 4096 ((size-1) `div` 2))
            prefix=BS.take prefixBytes frame
            remainder=BS.drop prefixBytes frame
            digest=T.pack(show(hash(prefix<>remainder)::Digest SHA256))
        unless(prefixBytes<size)(error "control frame too small for original prefix audit")
        same <- (==Just pipe) <$> readIORef original
        writeIORef summary(size,prefixBytes,1,digest,same)
        BS.hPut pipe prefix
        hFlush pipe
        writeIORef summary(size,prefixBytes,2,digest,same)
        putMVar ready()
        writeIORef summary(size,prefixBytes,3,digest,same)
        BS.hPut pipe remainder
        hFlush pipe
        writeIORef summary(size,prefixBytes,4,digest,same)
  where normal=BS.hPut pipe frame >> hFlush pipe

data Anchor = Anchor !Text !Dynamic !Dynamic
data Audit = Audit !Bool !(IORef Bool) !(IORef (Maybe Anchor)) !(MVar (ThreadId,Text)) !(MVar ()) !(IORef (Int,Int,Bool,Bool))

{-# NOINLINE currentAudit #-}
currentAudit :: MVar (Maybe Audit)
currentAudit = unsafePerformIO (newMVar Nothing)

withAcceptanceAudit :: (Audit -> IO a) -> IO a
withAcceptanceAudit = withAudit False
withDeliveryAudit :: (Audit -> IO a) -> IO a
withDeliveryAudit = withAudit True
withAudit :: Bool -> (Audit -> IO a) -> IO a
withAudit delivery = bracket acquire release
  where
    acquire = do
      audit <- Audit delivery <$> newIORef False <*> newIORef Nothing <*> newEmptyMVar <*> newEmptyMVar <*> newIORef (0,0,True,True)
      modifyMVar_ currentAudit $ \old -> case old of Nothing->pure(Just audit);Just _->error "audit already active"
      pure audit
    release (Audit _ _ _ _ stop _) = do
      void(tryPutMVar stop ())
      modifyMVar_ currentAudit (const(pure Nothing))

waitAccepted :: Audit -> IO (ThreadId,Text)
waitAccepted (Audit _ _ _ entered _ _) = timeout 5000000(takeMVar entered) >>= maybe(error "fresh acceptance boundary was not reached")pure

auditSummary :: Audit -> IO (Int,Int,Bool,Bool)
auditSummary (Audit _ _ _ _ _ counts)=readIORef counts

-- The sole rendezvous is after a fresh successful real transaction, before publication.
afterFreshCommit :: (Typeable a,Typeable b) => Text -> IORef a -> IORef b -> IO ()
afterFreshCommit command ticket attempt = readMVar currentAudit >>= mapM_ enter
  where
    enter (Audit delivery _ anchor entered stop _) = do
      first <- atomicModifyIORef' anchor $ \old -> case old of
        Nothing -> (Just(Anchor command (toDyn ticket) (toDyn attempt)),True)
        Just _ -> (old,False)
      if not first || delivery then pure() else do
        thread <- myThreadId
        putMVar entered(thread,command)
        ended <- timeout 5000000(takeMVar stop)
        unless(ended==Just())(error "fresh acceptance boundary interruption timed out")

waitReturned :: Audit -> IO (ThreadId,Text)
waitReturned (Audit _ _ _ entered _ _) = timeout 5000000(takeMVar entered) >>= maybe(error "native callback return boundary was not reached")pure

afterNativeReturn :: Typeable a => Text -> IORef a -> IO ()
afterNativeReturn command ticket = readMVar currentAudit >>= mapM_ (\(Audit delivery fired anchor entered stop counts)->do
  original<-readIORef anchor
  case original of
    Just(Anchor ident old _) | delivery && ident==command -> do
      first<-atomicModifyIORef' fired (\seen->(True,not seen))
      if not first then pure() else do
        atomicModifyIORef' counts (\(reconciled,delivered,sameTicket,sameAttempt)->((reconciled,delivered,sameTicket && sameReference ticket old,sameAttempt),()))
        thread<-myThreadId
        putMVar entered(thread,command)
        ended<-timeout 5000000(takeMVar stop)
        unless(ended==Just())(error "native return interruption timed out")
    _->pure())

sameReference :: Typeable a => IORef a -> Dynamic -> Bool
sameReference actual original=maybe False (==actual)(fromDynamic original)

recordReconciliation :: (Typeable a,Typeable b) => Text -> IORef a -> IORef b -> IO ()
recordReconciliation command ticket attempt = readMVar currentAudit >>= mapM_ (\(Audit _ _ anchor _ _ counts)->do
  original <- readIORef anchor
  case original of
    Just(Anchor ident oldTicket oldAttempt) | ident==command -> atomicModifyIORef' counts $ \(reconciled,delivered,sameTicket,sameAttempt)->
      ((reconciled+1,delivered,sameTicket && sameReference ticket oldTicket,sameAttempt && sameReference attempt oldAttempt),())
    _ -> pure())

recordDelivery :: Typeable a => Text -> IORef a -> IO ()
recordDelivery command ticket = readMVar currentAudit >>= mapM_ (\(Audit _ _ anchor _ _ counts)->do
  original <- readIORef anchor
  case original of
    Just(Anchor ident oldTicket _) | ident==command -> atomicModifyIORef' counts $ \(reconciled,delivered,sameTicket,sameAttempt)->
      ((reconciled,delivered+1,sameTicket && sameReference ticket oldTicket,sameAttempt),())
    _ -> pure())

{-# NOINLINE controlWaiters #-}
controlWaiters :: MVar (Maybe (Text,[ThreadId]))
controlWaiters = unsafePerformIO(newMVar Nothing)
recordControlWait :: Text -> IO ()
recordControlWait stage = do
  thread <- myThreadId
  modifyMVar_ controlWaiters $ \current -> case current of
    Just(expected,threads) | expected==stage -> do
      unless(length threads<16)(error "control waiter audit exceeded operation bound")
      pure(Just(expected,threads<>[thread]))
    _ -> pure current
waitControlWaiter :: ReviewAudit -> IO ThreadId
waitControlWaiter _ = timeout 5000000 wait >>= maybe(error "original queued control not observed")pure
  where
    wait = readMVar controlWaiters >>= \current -> case current of
      Just(_, _:second:_) -> pure second
      _ -> threadDelay 1000 >> wait

data ReviewAudit = ReviewAudit !Text !(IORef Bool) !(MVar ThreadId) !(MVar ())
{-# NOINLINE currentReviewAudit #-}
currentReviewAudit :: MVar (Maybe ReviewAudit)
currentReviewAudit = unsafePerformIO(newMVar Nothing)
withReviewAudit :: Text -> (ReviewAudit -> IO a) -> IO a
withReviewAudit stage=bracket acquire release
  where
    acquire=do
      audit<-ReviewAudit stage <$> newIORef False <*> newEmptyMVar <*> newEmptyMVar
      modifyMVar_ currentReviewAudit $ \old->case old of Nothing->pure(Just audit);Just _->error "concurrent review audit"
      modifyMVar_ controlWaiters (const(pure(Just(stage,[]))))
      pure audit
    release audit=do
      releaseReviewed audit
      modifyMVar_ currentReviewAudit(const(pure Nothing))
      modifyMVar_ controlWaiters(const(pure Nothing))
      modifyMVar_ sqlInterrupt(const(pure Nothing))
waitReviewed :: ReviewAudit -> IO ThreadId
waitReviewed (ReviewAudit _ _ entered _)=timeout 5000000(takeMVar entered)>>=maybe(error "actual currentReview boundary was not reached")pure
releaseReviewed :: ReviewAudit -> IO ()
releaseReviewed (ReviewAudit _ _ _ resume)=do _<-tryPutMVar resume();pure()
afterCurrentReview :: Text -> IO ()
afterCurrentReview stage=readMVar currentReviewAudit >>= mapM_ (\(ReviewAudit expected claimed entered resume)->do
  if stage/=expected then pure() else do
    first<-atomicModifyIORef' claimed(\seen->(True,not seen))
    if not first then pure() else do
      original<-myThreadId
      putMVar entered original
      completed<-timeout 5000000(takeMVar resume)
      unless(completed==Just())(error "currentReview rendezvous timed out"))

-- Compiled audit only: hold the actual step across an inherited-mask cancellation.
-- Retain the original connection's interrupt solely to join a failing red control.
{-# NOINLINE sqlInterrupt #-}
sqlInterrupt :: MVar (Maybe (IO ()))
sqlInterrupt = unsafePerformIO (newMVar Nothing)
retainSqlInterrupt :: IO () -> IO ()
retainSqlInterrupt action = readMVar currentReviewAudit >>= mapM_ (\(ReviewAudit stage _ _ _) ->
  if stage=="store-step" then modifyMVar_ sqlInterrupt (const (pure (Just action))) else pure ())
rescueSql :: IO ()
rescueSql = readMVar sqlInterrupt >>= maybe (error "missing original SQL interrupt") id
atSqlStep :: IO a -> IO a
atSqlStep action = readMVar currentReviewAudit >>= \active -> case active of
  Just (ReviewAudit "store-step" _ _ _) -> uninterruptibleMask_ (afterCurrentReview "store-step" >> action)
  _ -> action
