{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Verified credential possession, rechecked against current transactional facts.
module Agentic.Manager.Authorization
  ( CredentialProof, authenticateCredential, currentClient, authorizeProfile, proofGeneration, credentialRateKey,
    AuthorizedView, withAuthorizedView, withAuthorizedResponse, revalidateAuthorizedView, awaitAuthorizedView ) where

import Agentic.Manager.Profile (PublicProfile, publicId, publicRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Store
import Control.DeepSeq (NFData (rnf))
import Control.Exception (try, throwIO)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (constEq, convert)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Database.SQLite3 as SQL

-- | Possession evidence bound to one live store, not a credential or client ID API.
-- No Show or JSON instance may disclose the verifier.
data CredentialProof = CredentialProof !Text !Text !BS.ByteString !Text
instance NFData CredentialProof where
  rnf (CredentialProof credential client verifier generation) =
    rnf credential `seq` rnf client `seq` rnf verifier `seq` rnf generation

credentialRateKey :: CredentialProof -> Text
credentialRateKey (CredentialProof credential _ _ _) = credential

proofGeneration :: CredentialProof -> Text
proofGeneration (CredentialProof _ _ _ generation) = generation

authenticateCredential :: CoordinationStore -> BS.ByteString -> IO (Either CommandFailure CredentialProof)
authenticateCredential store bearer
  | BS.length bearer < 32 || BS.length bearer > 512 = pure (Left Unauthenticated)
  | otherwise = do
      result <- try @StoreFailure $ do
        generation <- storeProcessGeneration <$> storeIdentity store
        let verifier = convert (hash bearer :: Digest SHA256) :: BS.ByteString
        runRead store $ do
          rows <- query
            "SELECT c.id,c.client_id,c.verifier FROM credentials c JOIN clients p ON p.id=c.client_id WHERE c.verifier=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now') AND NOT EXISTS(SELECT 1 FROM credential_administration a WHERE a.credential_id=c.id AND julianday(a.rotation_cutoff)<=julianday('now'))"
            [SQL.SQLBlob verifier]
          pure $ case rows of
            [[SQL.SQLText credential, SQL.SQLText client, SQL.SQLBlob actual]]
              | validId credential && validId client && BS.length actual == 32 && constEq actual verifier ->
                  Right (CredentialProof credential client verifier generation)
            _ -> Left Unauthenticated
      pure (either (const (Left StorageUnavailable)) id result)

-- Trusted time is obtained from SQLite in the same transaction as authorization.
currentClient :: CredentialProof -> Transaction (Either CommandFailure Text)
currentClient (CredentialProof credential client verifier generation) = do
  current <- transactionGeneration
  if current /= generation then pure (Left Unauthenticated) else do
    rows <- query
      "SELECT c.client_id,c.verifier FROM credentials c JOIN clients p ON p.id=c.client_id WHERE c.id=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now') AND NOT EXISTS(SELECT 1 FROM credential_administration a WHERE a.credential_id=c.id AND julianday(a.rotation_cutoff)<=julianday('now'))"
      [SQL.SQLText credential]
    pure $ case rows of
      [[SQL.SQLText actualClient, SQL.SQLBlob actualVerifier]]
        | actualClient == client && BS.length actualVerifier == 32 && constEq verifier actualVerifier -> Right client
      _ -> Left Unauthenticated

authorizeProfile :: CredentialProof -> Text -> [Scope] -> Transaction (Either CommandFailure Text)
authorizeProfile proof@(CredentialProof credential _ _ _) profile scopes = do
  current <- currentClient proof
  case current of
    Left failure -> pure (Left failure)
    Right client -> do
      rows <- query "SELECT scope FROM credential_scopes WHERE credential_id=? AND profile_id=?"
        [SQL.SQLText credential, SQL.SQLText profile]
      let actual = [scope | [SQL.SQLText scope] <- rows]
      pure $ if all ((`elem` actual) . scopeName) scopes then Right client else Left Forbidden

-- | A scoped binding to current authority, credential, client authorization revision,
-- profile revision, scope facts and effective deadline. Neither Show nor Generic is safe.
-- Future page/cursor/transport owners must revalidate before releasing protected data.
data AuthorizedView = AuthorizedView !AuthorizationWatch !(IO [Text]) ![Text]

withAuthorizedView :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO (Either CommandFailure a)
withAuthorizedView store proof profile scopes action = authorizationIO $ do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  withStoreAuthorizationWatch store $ \watch ->
    withView watch (currentViewFacts store proof profile scopes) action

-- | A response view under the original configuration loan and one reader charge.
-- Its revalidation borrows that configuration rather than reacquiring its guard.
-- The original watch ends before the configuration loan is released.
withAuthorizedResponse :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO a
withAuthorizedResponse store proof profile scopes action = do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfigurationWatch store $ \watch _ profiles ->
    withView watch (profileViewFacts store proof profile scopes profiles) action
  either (const (throwIO StorageUnavailable)) pure result

withView :: AuthorizationWatch -> IO [Text] -> (AuthorizedView -> IO a) -> IO a
withView watch observe action = do
  observed <- withAuthorizationObservation watch observe
  facts <- maybe (throwIO Unauthenticated) pure observed
  action (AuthorizedView watch observe facts)

revalidateAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
revalidateAuthorizedView (AuthorizedView watch observe bound) = authorizationIO $ do
  observed <- withAuthorizationObservation watch $ do
    facts <- observe
    unless (facts == bound) (throwIO Unauthenticated)
  unless (observed == Just ()) (throwIO Unauthenticated)

-- A wakeup is not current authority. Every timer expiry rechecks SQLite time.
awaitAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
awaitAuthorizedView view@(AuthorizedView watch _ _) =
  awaitAuthorizationChange watch >> revalidateAuthorizedView view

currentViewFacts :: CoordinationStore -> CredentialProof -> Text -> [Scope] -> IO [Text]
currentViewFacts store proof profile scopes = do
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfiguration store $ \_ profiles ->
    profileViewFacts store proof profile scopes profiles
  either (const (throwIO StorageUnavailable)) pure result

profileViewFacts :: CoordinationStore -> CredentialProof -> Text -> [Scope] -> [PublicProfile] -> IO [Text]
profileViewFacts store proof@(CredentialProof credential client _ generation) profile scopes profiles =
  runRead store $ do
    _ <- authorizeProfile proof profile scopes >>= either refuseTransaction pure
    revision <- case [publicRevision p | p <- profiles, publicId p == profile] of
      [value] -> pure value
      _ -> refuseTransaction Forbidden
    rows <- query "SELECT s.authority_epoch,p.authorization_revision,c.expires_at,coalesce(a.rotation_cutoff,''),(SELECT json_group_array(scope) FROM (SELECT scope FROM credential_scopes WHERE credential_id=c.id AND profile_id=? ORDER BY scope)) FROM credentials c JOIN clients p ON p.id=c.client_id CROSS JOIN service_metadata s LEFT JOIN credential_administration a ON a.credential_id=c.id WHERE c.id=? AND s.singleton=1"
      [SQL.SQLText profile,SQL.SQLText credential]
    case rows of
      [[SQL.SQLText epoch,SQL.SQLText authorization,SQL.SQLText expiry,SQL.SQLText cutoff,SQL.SQLText actualScopes]] ->
        pure [generation,epoch,credential,client,authorization,profile,revision,actualScopes,expiry,cutoff]
      _ -> refuseTransaction Unauthenticated

authorizationIO :: IO a -> IO (Either CommandFailure a)
authorizationIO action = either (const (Left StorageUnavailable)) id <$> try @StoreFailure (try @CommandFailure action)
