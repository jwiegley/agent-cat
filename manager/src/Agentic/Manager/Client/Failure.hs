{-# LANGUAGE OverloadedStrings #-}

-- | The fixed local failures of the public client and the mapping of a public
-- problem response to one of them.
module Agentic.Manager.Client.Failure (ClientFailure (..), ClientFile (..), FileRule (..), problemFailure) where

import Agentic.Manager.Protocol.Command (validId)
import Control.Exception (Exception)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T

-- | Fixed local failures. Request headers and exception diagnostics are not retained.
--
-- 'ManagerCertificateRefused' and 'TlsHandshakeFailed' are failures of the TLS
-- handshake of a connection, which precedes every request byte. The first is a
-- refusal of the certificate that the manager presented: the @caFile@ does not
-- validate it for the endpoint host, or the Name Constraints check refuses it.
-- The second is every other handshake failure. A transport failure after the
-- handshake stays 'TransportUnavailable'.
data ClientFailure = ClientClosed | InvalidEndpoint | WrongEndpoint | CredentialUnavailable
  | CredentialChanged | TransportUnavailable | RedirectRefused | InvalidResponse
  | ResponseTooLarge | UnsupportedVersion | Refused !Int !Text | ClientFileRefused !ClientFile !FileRule
  | InvalidClientProfile | ManagerCertificateRefused | TlsHandshakeFailed
  deriving (Eq, Show)
instance Exception ClientFailure

-- | The role of a file that a client profile names.
data ClientFile = ProfileFile | CredentialFile | CaFile
  deriving (Eq, Show)

-- | The first rule that a client file failed, in the order that the client
-- checks them. The client profile and the credential file are private files.
-- The CA file is not private, but no group or other user can write to it.
data FileRule
  = -- | The path names no file.
    FileMissing
  | -- | The last component of the path is a symbolic link.
    FileSymbolicLink
  | -- | The file could not be opened or read for another reason.
    FileUnreadable
  | -- | The file is not a regular file.
    FileNotRegular
  | -- | The file is larger than the limit of its role.
    FileTooLarge
  | -- | A group or other user can write to the file.
    FileWritableByOthers
  | -- | The private file is not owned by the effective user.
    FileNotOwned
  | -- | The private file gives a group or other user some access.
    FileNotPrivate
  | -- | The private file has more than one hard link.
    FileMultipleLinks
  deriving (Eq, Show)

-- | The failure of a problem response with the given HTTP status. A body whose
-- @status@ equals that status and whose @code@ is a bounded identifier gives
-- 'Refused' with that status and code, so a 410 @view-expired@ or
-- @cursor-expired@ problem gives @Refused 410@ with its code. Every other body
-- gives 'InvalidResponse'.
problemFailure :: Int -> Value -> ClientFailure
problemFailure status (Object fields) = case (KM.lookup "status" fields, KM.lookup "code" fields) of
  (Just (Number number), Just (String code)) | number == fromIntegral status
    && validId code && T.length code <= 128 -> Refused status code
  _ -> InvalidResponse
problemFailure _ _ = InvalidResponse
