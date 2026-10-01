{-# LANGUAGE OverloadedStrings #-}

-- | The fixed local failures of the public client and the mapping of a public
-- problem response to one of them.
module Agentic.Manager.Client.Failure (ClientFailure (..), problemFailure) where

import Agentic.Manager.Protocol.Command (validId)
import Control.Exception (Exception)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T

-- | Fixed local failures. Request headers and exception diagnostics are not retained.
data ClientFailure = ClientClosed | InvalidEndpoint | WrongEndpoint | CredentialUnavailable
  | CredentialChanged | TransportUnavailable | RedirectRefused | InvalidResponse
  | ResponseTooLarge | UnsupportedVersion | Refused !Int !Text | ClientFileUnavailable | InvalidClientProfile
  deriving (Eq, Show)
instance Exception ClientFailure

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
