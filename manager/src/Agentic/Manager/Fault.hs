{-# LANGUAGE OverloadedStrings #-}

-- | Fixed classifications of refused responses and recorded service faults.
-- A classification holds constructor and type names only. It never holds an
-- exception message, request content, credential, file path or SQL text.
module Agentic.Manager.Fault
  ( ManagerFault (..), FaultClass (..), configurationLoan, refuseStorageUnavailable, storeFailureRefusal,
    recordUndeclaredRefusal, classifyFault, faultProblem, faultLabel, faultClassName, recordFault ) where

import Agentic.Manager.Fault.Record
import Agentic.Manager.Profile (Diagnostic)
import Agentic.Manager.Protocol.Command (CommandFailure (StorageUnavailable), failureCode, failureStatus)
import Agentic.Manager.Store (StoreFailure)
import Agentic.Manager.Worker.State (WorkerFailure)
import Control.Exception (SomeException (..), fromException, throwIO)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Typeable (typeOf)

-- | The private classification of one failure.
data FaultClass
  = CommandRefusal !CommandFailure
  | StoreRefusal !StoreFailure
  | ConfigurationFault !Diagnostic
  | WorkerRefusal !WorkerFailure
  | InternalFault !ManagerFault
  | UnexpectedFault !Text
    -- ^ The exception type name. An I/O exception adds its fixed error type.
  deriving (Eq, Show)

-- | Complete one configuration loan result at the named site. An unsuccessful
-- loan keeps its declared command refusal, storage-unavailable, so every
-- caller and every 'Either' contract is unchanged. Its distinct internal cause
-- ('ConfigurationBusy' or 'ConfigurationRefused') is recorded privately first.
-- A loan taken through 'Agentic.Manager.Store.withStoreReader' reports a held
-- guard at reader admission before this site can observe it.
configurationLoan :: Text -> Either Diagnostic a -> IO a
configurationLoan context = either (refuseStorageUnavailable context . InternalFault . loanFault) pure

-- | Refuse with the declared storage-unavailable command failure after one
-- private record of the distinct cause that this refusal replaces.
refuseStorageUnavailable :: Text -> FaultClass -> IO a
refuseStorageUnavailable context cause = recordStorageUnavailable context cause >> throwIO StorageUnavailable

-- | Return the declared storage-unavailable command failure after one private
-- record of the Store failure that it replaces.
storeFailureRefusal :: Text -> StoreFailure -> IO (Either CommandFailure a)
storeFailureRefusal context failure = Left StorageUnavailable <$ recordStorageUnavailable context (StoreRefusal failure)

-- | Record one failure that the caller replaces with the declared
-- storage-unavailable refusal. A declared command refusal keeps its own
-- value, so it is not an erasure and is not recorded.
recordUndeclaredRefusal :: Text -> SomeException -> IO ()
recordUndeclaredRefusal context failure = case classifyFault failure of
  CommandRefusal _ -> pure ()
  cause -> recordStorageUnavailable context cause

recordStorageUnavailable :: Text -> FaultClass -> IO ()
recordStorageUnavailable context cause =
  recordErasure context (faultLabel cause) (faultLabel (CommandRefusal StorageUnavailable))

classifyFault :: SomeException -> FaultClass
classifyFault failure
  | Just value <- fromException failure = CommandRefusal value
  | Just value <- fromException failure = StoreRefusal value
  | Just value <- fromException failure = InternalFault value
  | Just value <- fromException failure = ConfigurationFault value
  | Just value <- fromException failure = WorkerRefusal value
  | Just value <- fromException failure = UnexpectedFault (ioExceptionName value)
  | SomeException value <- failure = UnexpectedFault (T.pack (show (typeOf value)))

-- | The public problem status and code. Declared command refusals keep their
-- own codes. Every other class uses the declared storage-unavailable problem,
-- which is the only 5xx problem of the frozen contract that states no
-- supervision fact. The private record keeps the distinct class.
faultProblem :: FaultClass -> (Int, Text)
faultProblem (CommandRefusal failure) = (failureStatus failure, failureCode failure)
faultProblem _ = (503, "storage-unavailable")

-- | The fixed word of the class of one fault, without the refusal, the
-- diagnostic or the exception type that the class holds. The @status@
-- operation of local administration reports it as @serviceFault@.
faultClassName :: FaultClass -> Text
faultClassName fault = case fault of
  CommandRefusal _ -> "command-refusal"
  StoreRefusal _ -> "store-refusal"
  ConfigurationFault _ -> "configuration-fault"
  WorkerRefusal _ -> "worker-refusal"
  InternalFault _ -> "internal-fault"
  UnexpectedFault _ -> "unexpected-fault"

faultLabel :: FaultClass -> Text
faultLabel fault = case fault of
  CommandRefusal value -> refusalLabel "command" value
  StoreRefusal value -> refusalLabel "store" value
  ConfigurationFault value -> refusalLabel "configuration" value
  WorkerRefusal value -> refusalLabel "worker" value
  InternalFault value -> internalLabel value
  UnexpectedFault name -> "unexpected " <> name

-- | Append one classified line to the private standard error log.
recordFault :: Text -> FaultClass -> IO ()
recordFault context = recordFaultLine context . faultLabel
