{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Local administration on the original Store. Possession proofs grant no access here.
module Agentic.Manager.Credentials (administerCredentials) where

import Agentic.Manager.Administration (Logged, localAdministrator, recordAdministration, recordAdministrationReceipt)
import Agentic.Manager.Flow (AdministrationBody (..), AdministrationOperation (..))
import Agentic.Manager.Profile (publicId, publicRevision)
import Agentic.Manager.Protocol.Command (Scope (..), scopeName, encoded)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Store
import Agentic.Runtime (openPrivateRoot, closePrivateRoot, publishPrivateCaptureAt, CapturePublication (..), Actor)
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value, eitherDecodeStrict', object, toJSON, (.=))
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.IORef (newIORef, atomicModifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.FilePath (takeDirectory, takeFileName)
import System.IO.Error (isAlreadyExistsError)

-- | Trusted local composition supplies the Store, never a bearer or stored ID.
-- Offline callers acquire the existing exclusive lease. The live local channel
-- calls this same operation on its original Store without opening another writer.
administerCredentials :: CoordinationStore -> LocalAdminRequest -> IO BS.ByteString
administerCredentials store request = do
  principal <- localAdministrator
  result <- try @IOException $ try @StoreFailure $ try @AdminFailure $ do
    unless (validAdminRequest request) (throwIO MalformedRequest)
    perform store principal request
  case result of
    Left _ -> pure (failure StorageUnavailable)
    Right (Left StoreLimit) -> pure (failure SizeLimit)
    Right (Left _) -> pure (failure StorageUnavailable)
    Right (Right (Left problem)) -> pure (failure problem)
    Right (Right (Right (value, logged))) -> recordAdministrationReceipt store principal logged (adminSuccess operation value)
  where
    operation = adminOperation request
    failure = adminError (Just operation)

perform :: CoordinationStore -> Actor -> LocalAdminRequest -> IO (Value, Logged)
perform store principal request = case request of
  ListCredentials -> do
    values <- runRead store $ do
      rows <- query (metadataSQL <> " ORDER BY c.id LIMIT 257") []
      unless (length rows <= 256) (refuseTransaction SizeLimit)
      mapM decodeMetadata rows
    pure (object ["credentials" .= values], Nothing)
  RevokeCredential ident -> do
    revision <- freshId "authorization_"
    logged <- runTransaction store $ do
      rows <- query "SELECT client_id FROM credentials WHERE id=?" [text ident]
      client <- case rows of
        [[SQL.SQLText value]] -> pure value
        _ -> refuseTransaction StateConflict
      execute "UPDATE credentials SET revoked=1 WHERE id=?" [text ident]
      reviseClient client revision
      revoked <- metadataById ident
      logged <- recordAdministration store principal (administered AdministerRevoke Nothing revoked)
      pure (logged, changed revision)
    pure (object ["credentialId" .= ident, "state" .= ("revoked" :: Text)], logged)
  IssueCredential label scopes profiles declaredExpiry destination -> do
    let expiry = T.toUpper declaredExpiry
    snapshot <- withProfiles store profiles $ runRead store (futureExpiry expiry)
    client <- freshId "client_"
    ident <- freshId "credential_"
    revision <- freshId "authorization_"
    verifier <- publishBearer destination
    metadata <- configured store $ \current -> do
      unless (selectProfiles profiles current == Just snapshot) (throwIO StateConflict)
      runTransaction store $ do
        futureExpiry expiry
        execute "INSERT INTO clients(id,revision,authorization_revision,retired) VALUES (?,?,?,0)" [text client,text revision,text revision]
        insertCredential ident client verifier expiry label
        insertProfiles ident profiles
        execute "INSERT INTO credential_scopes SELECT ?,p.value,s.value FROM json_each(?) p CROSS JOIN json_each(?) s"
          [text ident,jsonText profiles,jsonText (map scopeName scopes)]
        value <- metadataById ident
        futureExpiry expiry
        logged <- recordAdministration store principal (administered AdministerIssue Nothing value)
        pure ((value, logged), changed revision)
    pure (object ["credential" .= fst metadata, "secretWritten" .= True], snd metadata)
  RotateCredential previous declaredExpiry destination -> do
    let expiry = T.toUpper declaredExpiry
    original <- runRead store (rotationTarget previous <* futureExpiry expiry)
    let profiles = credentialProfileIds original
    snapshot <- profileSnapshot store profiles
    ident <- freshId "credential_"
    revision <- freshId "authorization_"
    verifier <- publishBearer destination
    metadata <- configured store $ \currentProfiles -> do
      unless (selectProfiles profiles currentProfiles == Just snapshot) (throwIO StateConflict)
      runTransaction store $ do
        current <- rotationTarget previous
        unless (current == original) (refuseTransaction StateConflict)
        futureExpiry expiry
        let client = credentialClientId current
        insertCredential ident client verifier expiry (credentialLabel current)
        insertProfiles ident profiles
        execute "INSERT INTO credential_scopes SELECT ?,profile_id,scope FROM credential_scopes WHERE credential_id=?" [text ident,text previous]
        -- Repeated rotation retires every older predecessor, without extending a cutoff.
        execute "UPDATE credentials SET revoked=1 WHERE client_id=? AND id NOT IN (?,?)" [text client,text previous,text ident]
        execute "INSERT INTO credential_administration(credential_id,label) VALUES (?,?) ON CONFLICT(credential_id) DO NOTHING"
          [text previous,text (credentialLabel current)]
        execute "UPDATE credential_administration SET superseded_by=?,rotation_cutoff=strftime('%Y-%m-%dT%H:%M:%fZ',min(julianday((SELECT expires_at FROM credentials WHERE id=?)),coalesce(julianday(rotation_cutoff),julianday('now','+60 seconds')),julianday('now','+60 seconds'))) WHERE credential_id=?"
          [text ident,text previous,text previous]
        reviseClient client revision
        value <- metadataById ident
        futureExpiry expiry
        active <- query "SELECT c.id FROM credentials c JOIN clients p ON p.id=c.client_id JOIN credential_administration a ON a.credential_id=c.id WHERE c.id=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now') AND julianday(a.rotation_cutoff)>julianday('now') AND a.superseded_by=?" [text previous,text ident]
        unless (active == [[text previous]]) (refuseTransaction StateConflict)
        logged <- recordAdministration store principal (administered AdministerRotate (Just previous) value)
        pure ((value, logged), changed revision)
    pure (object ["credential" .= fst metadata, "previousCredentialId" .= previous, "secretWritten" .= True], snd metadata)
  -- Store status, inspection, quarantine checks and quarantine release
  -- belong to "Agentic.Manager.Quarantine", and the profile reload and the
  -- drain belong to "Agentic.Manager.LocalAdmin". The other recognized
  -- operations have no implementation yet.
  Status -> throwIO StateConflict
  CheckStore -> throwIO StateConflict
  CheckQuarantine _ -> throwIO StateConflict
  ReleaseQuarantine {} -> throwIO StateConflict
  ReloadProfiles -> throwIO StateConflict
  Drain -> throwIO StateConflict
  OtherAdmin _ -> throwIO StateConflict

-- | The command body of a credential operation, from the metadata of the
-- credential that it issues, rotates to or revokes.
administered :: AdministrationOperation -> Maybe Text -> CredentialMetadata -> AdministrationBody
administered operation previous metadata =
  AdministrationBody operation (credentialClientId metadata) (credentialId metadata) previous (credentialLabel metadata)
    (map scopeName (credentialScopes metadata)) (credentialProfileIds metadata) (credentialExpiresAt metadata)

-- The configuration lock covers the final SQL revalidation, never publication.
configured :: CoordinationStore -> ([(Text,Text)] -> IO a) -> IO a
configured store action = do
  result <- withStoreConfiguration store $ \_ profiles -> action [(publicId p,publicRevision p) | p <- profiles]
  either (const (throwIO StorageUnavailable)) pure result

selectProfiles :: [Text] -> [(Text,Text)] -> Maybe [(Text,Text)]
selectProfiles names profiles = mapM (\name -> (,) name <$> lookup name profiles) names

profileSnapshot :: CoordinationStore -> [Text] -> IO [(Text,Text)]
profileSnapshot store names = configured store $ \profiles ->
  maybe (throwIO StateConflict) pure (selectProfiles names profiles)

withProfiles :: CoordinationStore -> [Text] -> IO () -> IO [(Text,Text)]
withProfiles store names action = configured store $ \profiles -> do
  selected <- maybe (throwIO StateConflict) pure (selectProfiles names profiles)
  action
  pure selected

futureExpiry :: Text -> Transaction ()
futureExpiry expiry = do
  rows <- query "SELECT julianday(?)>julianday('now')" [text expiry]
  unless (rows == [[SQL.SQLInteger 1]]) (refuseTransaction StateConflict)

rotationTarget :: Text -> Transaction CredentialMetadata
rotationTarget ident = do
  rows <- query "SELECT c.id FROM credentials c JOIN clients p ON p.id=c.client_id LEFT JOIN credential_administration a ON a.credential_id=c.id WHERE c.id=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now') AND (a.rotation_cutoff IS NULL OR julianday(a.rotation_cutoff)>julianday('now')) AND a.superseded_by IS NULL" [text ident]
  unless (rows == [[text ident]]) (refuseTransaction StateConflict)
  metadataById ident

insertCredential :: Text -> Text -> BS.ByteString -> Text -> Text -> Transaction ()
insertCredential ident client verifier expiry label = do
  markAuthorizationChange
  execute "INSERT INTO credentials(id,client_id,verifier,expires_at,revoked) VALUES (?,?,?,?,0)"
    [text ident,text client,SQL.SQLBlob verifier,text expiry]
  execute "INSERT INTO credential_administration(credential_id,label) VALUES (?,?)" [text ident,text label]

insertProfiles :: Text -> [Text] -> Transaction ()
insertProfiles ident profiles = execute "INSERT INTO credential_profiles SELECT ?,value FROM json_each(?)" [text ident,jsonText profiles]

-- | Every revocation and rotation revises the client. The mark advances the
-- authorization revision, so the next revalidation of an open view reads the
-- facts again.
reviseClient :: Text -> Text -> Transaction ()
reviseClient client revision = do
  markAuthorizationChange
  execute "UPDATE clients SET revision=?,authorization_revision=? WHERE id=?" [text revision,text revision,text client]

changed :: Text -> [Invalidation]
changed revision = [Invalidation "service.changed" "/v1/service" revision]

metadataById :: Text -> Transaction CredentialMetadata
metadataById ident = do
  rows <- query (metadataSQL <> " WHERE c.id=?") [text ident]
  case rows of [row] -> decodeMetadata row; _ -> refuseTransaction StateConflict

-- Aggregate in SQL so 256 profiles with four scopes do not consume 1024 result rows.
metadataSQL :: Text
metadataSQL = "SELECT c.id,c.client_id,coalesce(a.label,c.id),c.expires_at,CASE WHEN c.revoked=1 OR p.retired=1 OR julianday(a.rotation_cutoff)<=julianday('now') THEN 'revoked' WHEN julianday(c.expires_at)<=julianday('now') THEN 'expired' ELSE 'active' END,(SELECT json_group_array(scope) FROM (SELECT DISTINCT scope FROM credential_scopes WHERE credential_id=c.id ORDER BY scope)),(SELECT json_group_array(profile_id) FROM (SELECT profile_id FROM credential_profiles WHERE credential_id=c.id UNION SELECT profile_id FROM credential_scopes WHERE credential_id=c.id ORDER BY profile_id)) FROM credentials c JOIN clients p ON p.id=c.client_id LEFT JOIN credential_administration a ON a.credential_id=c.id"

decodeMetadata :: [SQL.SQLData] -> Transaction CredentialMetadata
decodeMetadata row = case row of
  [SQL.SQLText ident,SQL.SQLText client,SQL.SQLText label,SQL.SQLText expiry,SQL.SQLText state,SQL.SQLText scopesJSON,SQL.SQLText profilesJSON] -> do
    names <- decodeArray scopesJSON
    scopes <- mapM (\name -> maybe (refuseTransaction StoreIntegrity) pure
      (lookup name [(scopeName s,s) | s <- [Observe,Submit,Control,ExportScope]])) names
    profiles <- decodeArray profilesJSON
    let value = CredentialMetadata ident client label scopes profiles expiry state
    unless (validCredentialMetadata value) (refuseTransaction SizeLimit)
    pure value
  _ -> refuseTransaction StoreIntegrity
  where
    decodeArray value = either (const (refuseTransaction StoreIntegrity)) pure
      (eitherDecodeStrict' (TE.encodeUtf8 value) :: Either String [Text])

text :: Text -> SQL.SQLData
text = SQL.SQLText

jsonText :: [Text] -> SQL.SQLData
jsonText = text . TE.decodeUtf8 . encoded . toJSON

freshId :: Text -> IO Text
freshId prefix = (prefix <>) . TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 16 :: IO BS.ByteString)

-- Only confirmed publication permits activation. Never remove or overwrite the file,
-- including on SQL refusal, uncertain publication, cancellation, or uncertain COMMIT.
publishBearer :: FilePath -> IO BS.ByteString
publishBearer destination = bracket (openPrivateRoot "credential destination" (takeDirectory destination)) closePrivateRoot $ \root -> do
  randomBytes <- getRandomBytes 32 :: IO BS.ByteString
  let bearer = convertToBase Base16 randomBytes :: BS.ByteString
      verifier = convert (hash bearer :: Digest SHA256) :: BS.ByteString
  remaining <- newIORef bearer
  publication <- publishPrivateCaptureAt root [takeFileName destination] 64
    (atomicModifyIORef' remaining (\bytes -> (BS.empty,bytes)))
  case publication of
    CaptureNotPublished failure -> throwIO (if isAlreadyExistsError failure then OutputConflict else StorageUnavailable)
    CaptureUnconfirmed _ _ -> throwIO StorageUnavailable
    CapturePublished _ -> pure verifier
