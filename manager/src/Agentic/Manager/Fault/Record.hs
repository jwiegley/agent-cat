{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The private fault log and the internal causes that owners below the
-- command layer record. A record holds fixed words, validated identifiers,
-- the validated public resource path of a response and constructor or type
-- names only. It never holds an exception message, request content,
-- credential, file path or SQL text.
module Agentic.Manager.Fault.Record
  ( ManagerFault (..), loanFault, internalLabel, refusalLabel, ioExceptionName,
    faultLine, recordFaultLine, recordErasure, recordBusy ) where

import Agentic.Manager.Profile (Diagnostic (SupervisionUnavailable))
import Agentic.Manager.Store.Admission (Deadline, waitDetail)
import Control.Exception (Exception, IOException, try)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import System.IO (stderr)
import System.IO.Error (ioeGetErrorType)

-- | Internal causes that are neither declared Store failures nor declared
-- command refusals. Each constructor names one cause and carries no text.
data ManagerFault
  = ConfigurationBusy
    -- ^ A configuration loan did not acquire the original configuration
    -- guard within its five-second allowance, because another owner held it.
  | ConfigurationRefused !Diagnostic
    -- ^ An entered configuration loan ended with this fixed diagnostic.
  | AuthorizationChanged
    -- ^ A writable commit advanced the authorization revision during one
    -- authorization observation.
  | PageSetCollision
    -- ^ A fresh page-set identifier was already reserved.
  | ResponseWriteTimeout
    -- ^ One bounded response write did not complete within its allowance.
  | DeadlineElapsed
    -- ^ One bounded file operation or materialization did not complete within
    -- its allowance.
  | AdmissionStopping
    -- ^ The admission controller fence of the caller was set, because a drain
    -- or a cancellation had begun.
  | AdmissionStoreInactive
    -- ^ The admission controller held no live Store admission, because the
    -- admission never started or the Store ended it.
  | AdmissionCapacity
    -- ^ The admission controller already held its fixed number of operations
    -- in flight.
  deriving (Eq, Show)
instance Exception ManagerFault

-- | The internal cause of one unsuccessful configuration loan. A loan that
-- could not acquire the original configuration guard within its allowance
-- reports 'SupervisionUnavailable'. Every other diagnostic remains distinct.
loanFault :: Diagnostic -> ManagerFault
loanFault SupervisionUnavailable = ConfigurationBusy
loanFault diagnostic = ConfigurationRefused diagnostic

internalLabel :: ManagerFault -> Text
internalLabel fault = "internal " <> T.pack (show fault)

-- | A family word and a constructor name, for example @store StoreBusy@.
refusalLabel :: Show a => Text -> a -> Text
refusalLabel family value = family <> " " <> T.pack (show value)

-- | The type name of an I/O exception and its fixed error type.
ioExceptionName :: IOException -> Text
ioExceptionName failure = "IOException " <> T.pack (show (ioeGetErrorType failure))

-- | One private log line. The caller supplies a context of fixed words and
-- validated public identifiers only.
faultLine :: UTCTime -> Text -> Text -> Text
faultLine time context label =
  "manager-fault " <> T.pack (iso8601Show time) <> " " <> context <> " class=" <> label

-- | Append one line to the private standard error log. The log is not
-- authoritative, so a failed write changes no coordination outcome and is
-- deliberately not reported.
recordFaultLine :: Text -> Text -> IO ()
recordFaultLine context label = do
  now <- getCurrentTime
  written <- try @IOException (BS.hPut stderr (TE.encodeUtf8 (faultLine now context label <> "\n")))
  either (const (pure ())) pure written

-- | Record the distinct cause at the point where an owner replaces it with a
-- declared value. The caller then refuses with that declared value unchanged.
recordErasure :: Text -> Text -> Text -> IO ()
recordErasure context cause erased = recordFaultLine context (cause <> " erased=" <> erased)

-- | Record one busy refusal at the site that produces it: the fixed site
-- name, the refusal label, the elapsed wait of the site and the remaining
-- allowance of its deadline. A site that does not wait passes no deadline.
-- The caller then refuses unchanged, so this record adds no public field.
recordBusy :: Text -> Text -> Maybe Deadline -> IO ()
recordBusy site label end = waitDetail end >>= \detail -> recordFaultLine ("busy site=" <> site) (label <> " " <> detail)
