-- | The single native adapter lifecycle, shared with its fixed commit guard.
module Agentic.Manager.Worker.State
  ( WorkerFailure (..), WorkerPhase (..), StopReason (..), WorkerLifecycle,
    newWorkerLifecycle, lifecyclePhase, lifecycleStop, lifecycleFinished,
    lifecycleReleased, acceptingPreparation ) where

import Control.Concurrent.STM
import Control.Exception (Exception)
import System.Exit (ExitCode)

-- | Fixed worker refusals, without private paths or native diagnostic content.
data WorkerFailure = WorkerConfiguration | WorkerUnavailable | WorkerClosed | WorkerStartupTimeout
  | WorkerCapabilityRejected | WorkerPreparedFraming | WorkerPreparedDecode | WorkerWrongIdentity
  | WorkerRuntimeFraming | WorkerRuntimeDecode | WorkerSequenceViolation | WorkerPhaseViolation
  | WorkerUnexpectedExit | WorkerCleanupUnproven | WorkerWriteFailed | WorkerWriteTimeout | WorkerWriterBusy | WorkerConsumerBusy
  deriving (Eq, Show)
instance Exception WorkerFailure

-- | Adapter phase, not request admission, approval or a Runtime outcome.
data WorkerPhase = WorkerPreparing | WorkerPrepared | WorkerStartSent | WorkerRunning
  | WorkerDiscardSent | WorkerExited | WorkerReleased deriving (Eq, Show)

data StopReason = StopRequested | StopFailed !WorkerFailure

-- | Mutable transport lifecycle cells, not independently minted worker authority.
data WorkerLifecycle = WorkerLifecycle
  { lifecyclePhase :: !(TVar WorkerPhase),
    lifecycleStop :: !(TMVar StopReason),
    lifecycleFinished :: !(TMVar (Either WorkerFailure ExitCode)),
    lifecycleReleased :: !(TVar Bool) }

newWorkerLifecycle :: IO WorkerLifecycle
newWorkerLifecycle = WorkerLifecycle <$> newTVarIO WorkerPreparing <*> newEmptyTMVarIO <*> newEmptyTMVarIO <*> newTVarIO False

acceptingPreparation :: WorkerLifecycle -> STM Bool
acceptingPreparation state = do
  phase <- readTVar(lifecyclePhase state)
  released <- readTVar(lifecycleReleased state)
  stopped <- isEmptyTMVar(lifecycleStop state)
  finished <- isEmptyTMVar(lifecycleFinished state)
  pure(phase==WorkerPrepared && not released && stopped && finished)
