{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Verified credential possession, rechecked against current transactional facts.
module Agentic.Manager.Authorization
  ( CredentialProof, authenticateCredential, currentClient, authorizeProfile, proofGeneration, credentialRateKey ) where

import Agentic.Manager.Protocol.Command
import Agentic.Manager.Store
import Control.DeepSeq (NFData (rnf))
import Control.Exception (try)
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
            "SELECT c.id,c.client_id,c.verifier FROM credentials c JOIN clients p ON p.id=c.client_id WHERE c.verifier=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now')"
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
      "SELECT c.client_id,c.verifier FROM credentials c JOIN clients p ON p.id=c.client_id WHERE c.id=? AND c.revoked=0 AND p.retired=0 AND julianday(c.expires_at)>julianday('now')"
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
