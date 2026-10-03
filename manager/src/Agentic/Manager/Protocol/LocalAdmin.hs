{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The frozen local stdin request and metadata-only response vocabulary.
module Agentic.Manager.Protocol.LocalAdmin
  ( LocalAdminRequest (..), adminOperation, validAdminRequest, decodeLocalAdminRequest,
    AdminFailure (..), adminFailureCode, adminError, adminSuccess, reloadedProfiles, stoppedManager,
    CredentialMetadata (..), validCredentialMetadata, validLocalFile
  ) where

import Agentic.Manager.Protocol.Command (Scope (..), scopeName, validId, validTimestamp, encoded)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.DeepSeq (NFData)
import Control.Exception (Exception)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), ToJSON (toJSON), object, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import Data.List (sort)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import GHC.Generics (Generic)

-- No Show instance: selected local paths must not enter diagnostics.
data LocalAdminRequest
  = IssueCredential !Text ![Scope] ![Text] !Text !FilePath
  | RotateCredential !Text !Text !FilePath
  | RevokeCredential !Text
  | ListCredentials
  | Status
  | CheckStore
  | CheckQuarantine !Text
  | -- | The quarantine identity, the cleanup evidence identity and the
    -- cleanup evidence digest that a @check-quarantine@ answer returned.
    ReleaseQuarantine !Text !Text !Text
  | -- | Load the configuration file again and install its profiles. A serving
    -- manager reloads the file that it serves. Offline administration only
    -- validates the given file.
    ReloadProfiles
  | -- | Stop admitting new work for the rest of the serving lifetime, and let
    -- the owned runs continue to their ends. The request has no deadline.
    Drain
  | -- | Stop the serving manager after the reply: the owned runs are
    -- cancelled with their cleanup and the process ends. Offline
    -- administration changes nothing and answers that the manager is stopped.
    Shutdown
  | OtherAdmin !Text

-- | Fixed refusals. Storage failure makes no assertion about publication or COMMIT.
-- 'CleanupUnverified' refuses a quarantine release whose cleanup evidence,
-- computed again at the release, is not clean or differs from the supplied
-- evidence.
data AdminFailure = MalformedRequest | UnknownOperation | UnsupportedVersion
  | UnknownField | DuplicateField | SizeLimit | StateConflict | StorageUnavailable | OutputConflict
  | CleanupUnverified
  deriving (Eq, Show, Generic, NFData, Exception)

adminFailureCode :: AdminFailure -> Text
adminFailureCode failure = case failure of
  MalformedRequest -> "malformed-request"
  UnknownOperation -> "unknown-operation"
  UnsupportedVersion -> "unsupported-version"
  UnknownField -> "unknown-field"
  DuplicateField -> "duplicate-field"
  SizeLimit -> "size-limit"
  StateConflict -> "state-conflict"
  StorageUnavailable -> "storage-unavailable"
  OutputConflict -> "output-conflict"
  CleanupUnverified -> "cleanup-unverified"

adminOperation :: LocalAdminRequest -> Text
adminOperation request = case request of
  IssueCredential {} -> "issue-credential"
  RotateCredential {} -> "rotate-credential"
  RevokeCredential {} -> "revoke-credential"
  ListCredentials -> "list-credentials"
  Status -> "status"
  CheckStore -> "check-store"
  CheckQuarantine _ -> "check-quarantine"
  ReleaseQuarantine {} -> "release-quarantine"
  ReloadProfiles -> "reload-profiles"
  Drain -> "drain"
  Shutdown -> "shutdown"
  OtherAdmin name -> name

otherOperations :: [Text]
otherOperations = ["backup", "restore"]

validLocalFile :: FilePath -> Bool
validLocalFile path = let value = T.pack path in T.length value >= 2 && T.length value <= 8192
  && T.isPrefixOf "/" value && not (T.any (`elem` ['\0','\r','\n']) value)

unique :: Ord a => [a] -> Bool
unique values = Set.size (Set.fromList values) == length values

-- | A lowercase hexadecimal SHA-256 digest.
validDigest :: Text -> Bool
validDigest digest = T.length digest == 64 && T.all (`elem` ("0123456789abcdef" :: String)) digest

validExpiry :: Text -> Bool
validExpiry value = T.length value <= 40 && validTimestamp value

validAdminRequest :: LocalAdminRequest -> Bool
validAdminRequest request = case request of
  IssueCredential label scopes profiles expiry path ->
    not (T.null label) && T.length label <= 256 && length scopes <= 4 && unique scopes
    && not (null profiles) && length profiles <= 256 && unique profiles && all validId profiles
    && validExpiry expiry && validLocalFile path
  RotateCredential ident expiry path -> validId ident && validExpiry expiry && validLocalFile path
  RevokeCredential ident -> validId ident
  ListCredentials -> True
  Status -> True
  CheckStore -> True
  CheckQuarantine ident -> validId ident
  ReleaseQuarantine ident evidence digest -> validId ident && validId evidence && validDigest digest
  ReloadProfiles -> True
  Drain -> True
  Shutdown -> True
  OtherAdmin name -> name `elem` otherOperations

decodeLocalAdminRequest :: BS.ByteString -> Either AdminFailure LocalAdminRequest
decodeLocalAdminRequest bytes
  | BS.length bytes > 2097152 = Left SizeLimit
  | otherwise = do
      value <- either (\failure -> Left (if failure == "duplicate-field" then DuplicateField else MalformedRequest)) Right (decodeStrictValue bytes)
      fields <- case value of Object fields -> Right fields; _ -> Left MalformedRequest
      operation <- case KM.lookup "operation" fields of Just (String name) -> Right name; _ -> Left MalformedRequest
      unless (operation `elem` (["issue-credential","rotate-credential","revoke-credential","list-credentials","status","check-store","check-quarantine","release-quarantine","reload-profiles","drain","shutdown"] <> otherOperations)) (Left UnknownOperation)
      case KM.lookup "version" fields of
        Just (Number 1) -> Right ()
        Just (Number _) -> Left UnsupportedVersion
        _ -> Left MalformedRequest
      let required = ["version","operation"] <> case operation of
            "issue-credential" -> ["label","scopes","profileIds","expiresAt","outputFile"]
            "rotate-credential" -> ["credentialId","expiresAt","outputFile"]
            "revoke-credential" -> ["credentialId"]
            "backup" -> ["outputFile"]
            "restore" -> ["backupFile","fencingEvidenceFile"]
            "check-quarantine" -> ["quarantineId"]
            "release-quarantine" -> ["quarantineId","cleanupEvidenceId","cleanupEvidenceDigest"]
            _ -> []
      unless (all ((`elem` required) . Key.toText) (KM.keys fields)) (Left UnknownField)
      unless (all (\key -> KM.member (Key.fromText key) fields) required) (Left MalformedRequest)
      request <- either (const (Left MalformedRequest)) Right (parseEither (parseRequest operation) fields)
      unless (validAdminRequest request) (Left MalformedRequest)
      pure request

parseRequest :: Text -> Object -> Parser LocalAdminRequest
parseRequest operation fields = case operation of
  "issue-credential" -> do
    names <- fields .: "scopes"
    scopes <- mapM parseScope names
    IssueCredential <$> fields .: "label" <*> pure scopes <*> fields .: "profileIds"
      <*> fields .: "expiresAt" <*> fields .: "outputFile"
  "rotate-credential" -> RotateCredential <$> fields .: "credentialId" <*> fields .: "expiresAt" <*> fields .: "outputFile"
  "revoke-credential" -> RevokeCredential <$> fields .: "credentialId"
  "list-credentials" -> pure ListCredentials
  "status" -> pure Status
  "check-store" -> pure CheckStore
  "check-quarantine" -> CheckQuarantine <$> fields .: "quarantineId"
  "release-quarantine" -> ReleaseQuarantine <$> fields .: "quarantineId" <*> fields .: "cleanupEvidenceId" <*> fields .: "cleanupEvidenceDigest"
  "reload-profiles" -> pure ReloadProfiles
  "drain" -> pure Drain
  "shutdown" -> pure Shutdown
  _ -> do
    case operation of
      "backup" -> localFile "outputFile"
      "restore" -> localFile "backupFile" >> localFile "fencingEvidenceFile"
      _ -> pure ()
    pure (OtherAdmin operation)
  where
    localFile key = fields .: key >>= \path -> unless (validLocalFile path) (fail "path")
    parseScope name = case lookup name [(scopeName s,s) | s <- [Observe,Submit,Control,ExportScope]] of
      Just scope -> pure scope
      Nothing -> fail "scope"

-- | Retained non-secret metadata. Declared expiry is not a rotation cutoff.
data CredentialMetadata = CredentialMetadata
  { credentialId :: !Text, credentialClientId :: !Text, credentialLabel :: !Text,
    credentialScopes :: ![Scope], credentialProfileIds :: ![Text],
    credentialExpiresAt :: !Text, credentialState :: !Text
  } deriving (Eq, Show, Generic, NFData)

validCredentialMetadata :: CredentialMetadata -> Bool
validCredentialMetadata value = validId (credentialId value) && validId (credentialClientId value)
  && not (T.null (credentialLabel value)) && T.length (credentialLabel value) <= 256
  && length (credentialScopes value) <= 4 && unique (credentialScopes value)
  && length (credentialProfileIds value) <= 256 && unique (credentialProfileIds value)
  && all validId (credentialProfileIds value) && validExpiry (credentialExpiresAt value)
  && credentialState value `elem` ["active","revoked","expired"]

instance ToJSON CredentialMetadata where
  toJSON value = object
    ["credentialId" .= credentialId value, "clientId" .= credentialClientId value,
     "label" .= credentialLabel value, "scopes" .= map scopeName (credentialScopes value),
     "profileIds" .= credentialProfileIds value, "expiresAt" .= credentialExpiresAt value,
     "state" .= credentialState value]

adminError :: Maybe Text -> AdminFailure -> BS.ByteString
adminError operation failure = encoded $ object
  ["version" .= (1 :: Int), "operation" .= operation, "ok" .= False,
   "error" .= object ["code" .= adminFailureCode failure, "message" .= ("" :: Text)]]

adminSuccess :: Text -> Value -> BS.ByteString
adminSuccess operation result =
  let bytes = encoded $ object ["version" .= (1 :: Int), "operation" .= operation, "ok" .= True, "result" .= result]
  -- Reserve the CLI's terminating newline within the frozen response byte ceiling.
  in if BS.length bytes < 1048576 then bytes else adminError (Just operation) SizeLimit

-- | The frozen answer of @shutdown@: the manager is stopped, or it stops
-- after this reply.
stoppedManager :: BS.ByteString
stoppedManager = adminSuccess "shutdown" (object ["state" .= ("stopped" :: Text)])

-- | The result of @reload-profiles@ from the identifier and revision of each
-- installed profile: the identifiers in ascending order and the profile-set
-- revision. The revision is the lowercase hexadecimal SHA-256 digest of the
-- compact JSON array of @[profileId, profileRevision]@ pairs in ascending
-- order. Equal revisions mean equal profile identifiers with equal profile
-- revisions.
reloadedProfiles :: [(Text, Text)] -> Value
reloadedProfiles profiles = object ["profileIds" .= map fst pairs, "revision" .= digest]
  where
    pairs = sort profiles
    digest = TE.decodeUtf8 (convertToBase Base16 (hash (encoded (map (\(ident, revision) -> [ident, revision]) pairs)) :: Digest SHA256))
