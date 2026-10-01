{-# LANGUAGE ForeignFunctionInterface #-}

-- | Exclusive ownership of one open directory description, shared only by dup.
module Agentic.Manager.Lease (acquireLease, duplicateLease) where

import Agentic.Runtime (PrivateRoot, lockPrivateDescriptor, withPrivateDirectoryAt)
import Control.Exception (bracketOnError)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import System.Posix.IO
  (OpenFileFlags (cloexec, directory, nofollow), OpenMode (ReadOnly),
   closeFd, defaultFileFlags, openFdAt)
import System.Posix.Types (Fd (..))

acquireLease :: PrivateRoot -> IO Fd
acquireLease root = withPrivateDirectoryAt root [] $ \parent ->
  bracketOnError
    (openFdAt (Just parent) "." ReadOnly
      defaultFileFlags {cloexec = True, directory = True, nofollow = True})
    closeFd $ \fd -> do
      lockPrivateDescriptor "manager service ownership unavailable" fd
      pure fd

duplicateLease :: Fd -> IO Fd
duplicateLease (Fd fd) = Fd <$> throwErrnoIfMinus1Retry "duplicate manager lease" (duplicateDirectory fd)

foreign import ccall unsafe "agentic_manager_duplicate_lease"
  duplicateDirectory :: CInt -> IO CInt
