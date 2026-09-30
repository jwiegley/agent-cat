{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Verified credential possession, rechecked against current transactional facts.
module Agentic.Manager.Authorization
  ( CredentialProof, authenticateCredential, currentClient, authorizeProfile, proofGeneration, credentialRateKey,
    AuthorizedView, withAuthorizedView, withAuthorizedResponse, withAuthorizedResponseLimits, withAuthorizedCatalogues, withAuthorizedCatalogueContext, withBorrowedAuthorizedCatalogues, authorizedViewRevision, authorizedCursorRevision, catalogueAuthorization, revalidateAuthorizedView, awaitAuthorizedView,
    releaseResponseLoans, attachResponseLoan ) where

import Agentic.Manager.Fault (configurationLoan, storeFailureRefusal)
import Agentic.Manager.Profile (ConfigurationLimits, Discovery, PublicProfile, publicId, publicRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Store
import Agentic.Runtime (FrontendInvocation)
import Control.DeepSeq (NFData (rnf))
import Control.Exception (mask_, try, throwIO)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (constEq, convert)
import Data.Aeson (eitherDecodeStrict')
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
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

-- | A declared refusal is returned. A Store failure propagates unchanged, so the
-- transport records its distinct class behind the unchanged public problem.
authenticateCredential :: CoordinationStore -> BS.ByteString -> IO (Either CommandFailure CredentialProof)
authenticateCredential store bearer
  | BS.length bearer < 32 || BS.length bearer > 512 = pure (Left Unauthenticated)
  | otherwise = do
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
data AuthorizedView = AuthorizedView !AuthorizationWatch !ViewObservation !ViewFacts

-- | How revalidation reads current facts. A borrowed observation reads under
-- the loans of the scope that owns the view. A response observation reads
-- under its materialization loans while they are held. After
-- 'releaseResponseLoans' returns them, it acquires a reader charge, the
-- configuration guard and one SQL read for each check alone, in the lock
-- order configuration, then database, and returns them before the check
-- ends. The file slot is not part of any check.
data ViewObservation
  = BorrowedObservation !(IO ViewFacts)
  | ResponseObservation !(IO ViewFacts) !(IO ViewFacts) !(IORef (Maybe (IO ())))

-- Process and execution-profile lifetimes are distinct from the permission view.
-- Page bindings retain profile revisions. Event cursors retain current grants
-- and configured profile membership across an otherwise equivalent restart.
type ViewFacts = ((Text, [Text]), [Text])

withAuthorizedView :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO (Either CommandFailure a)
withAuthorizedView store proof profile scopes action = authorizationIO "authorization view" $ do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  withStoreAuthorizationWatch store $ \watch ->
    withView watch BorrowedObservation (currentViewFacts store proof profile scopes) action

-- | A response view. The representation is materialized under one reader
-- charge and the original configuration loan, and revalidation borrows that
-- loan while it is held. A response returns both loans with
-- 'releaseResponseLoans' before its first network write, together with any
-- file slot that its owner joined with 'attachResponseLoan'. No SQL
-- transaction spans a write. The watch stays alive until the callback returns, as an
-- authorization token only. Each later revalidation acquires a reader charge
-- and the configuration guard for its check alone, each within its unchanged
-- five-second allowance, so a revocation or scope change still stops the next
-- write. One such check precedes each 16 KiB write, and it contends with
-- ingestion only for its own duration. The allowances of one check are not
-- combined: the observation retries within its own allowance, and each
-- attempt can wait for a reader place, the configuration guard and the Store
-- gate, each within its own allowance. The longest wait before one write is
-- the sum of these allowances. An allowance that expires refuses the check
-- with its Store failure, which stops the response before its next write,
-- even when the status and part of the body are already sent.
withAuthorizedResponse :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO a
withAuthorizedResponse store proof profile scopes action =
  withAuthorizedResponseLimits store proof profile scopes $ \view _ -> action view

withAuthorizedResponseLimits :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> IO a) -> IO a
withAuthorizedResponseLimits store proof profile scopes action = do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfigurationWatch store $ \release watch limits profiles -> do
    loans <- newIORef (Just release)
    let fresh = withStoreReader store (currentViewFacts store proof profile scopes)
    withView watch (\borrowed -> ResponseObservation borrowed fresh loans)
      (profileViewFacts store proof profile scopes profiles) $ \view -> action view limits
  configurationLoan "authorization response" result

-- | Return the materialization loans of a response view before its first
-- network write. Later revalidation acquires what each check needs for that
-- check alone. A second call, or a call on a view that borrows the loans of
-- its owner, does nothing.
releaseResponseLoans :: AuthorizedView -> IO ()
releaseResponseLoans (AuthorizedView _ (ResponseObservation _ _ loans) _) = mask_ $
  atomicModifyIORef' loans (\pending -> (Nothing, pending)) >>= sequence_
releaseResponseLoans (AuthorizedView _ (BorrowedObservation _) _) = pure ()

-- | Join an outer materialization loan, such as the file slot of the response
-- owner, to the loans that 'releaseResponseLoans' returns. The outer loan is
-- returned after the reader charge and the configuration guard. When the view
-- has already returned its loans, the outer loan is returned at once. A view
-- that borrows the loans of its owner leaves the outer loan to its own scope.
attachResponseLoan :: AuthorizedView -> IO () -> IO ()
attachResponseLoan (AuthorizedView _ (ResponseObservation _ _ loans) _) release = mask_ $
  atomicModifyIORef' loans (\pending -> case pending of
    Just held -> (Just (held >> release), pure ())
    Nothing -> (Nothing, release)) >>= id
attachResponseLoan (AuthorizedView _ (BorrowedObservation _) _) _ = pure ()

withView :: AuthorizationWatch -> (IO ViewFacts -> ViewObservation) -> IO ViewFacts -> (AuthorizedView -> IO a) -> IO a
withView watch observation observe action =
  withViewResult watch observation ((\facts -> (facts, ())) <$> observe) (\view () -> action view)

-- A public materialization and its authorization facts come from the same
-- observation. Neither part can be resampled independently after acknowledgement.
-- Both are reads, so a concurrent commit starts a fresh read of both within
-- the observation allowance.
withViewResult :: NFData a => AuthorizationWatch -> (IO ViewFacts -> ViewObservation) -> IO (ViewFacts, a)
  -> (AuthorizedView -> a -> IO b) -> IO b
withViewResult watch observation observe action = do
  observed <- withAuthorizationReadObservation watch observe
  (facts, value) <- maybe (throwIO Unauthenticated) pure observed
  action (AuthorizedView watch (observation (fst <$> observe)) facts) value

-- | A filtered catalogue loan and its live authorization view. One reader charge
-- and one original configuration loan cover materialization. A response returns
-- them with 'releaseResponseLoans' before its first network write, as
-- 'withAuthorizedResponse' describes.
withAuthorizedCatalogues :: CoordinationStore -> CredentialProof -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> [(PublicProfile, [Scope])] -> [(Text, Discovery)] -> IO a)
  -> IO a
withAuthorizedCatalogues store proof scopes action =
  withAuthorizedCatalogueContext store proof scopes $ \view limits profiles catalogues _ ->
    action view limits profiles catalogues

-- | The same authorization loan, including permitted immutable invocation facts.
-- These observations are not independently launchable capabilities.
withAuthorizedCatalogueContext :: CoordinationStore -> CredentialProof -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> [(PublicProfile,[Scope])] -> [(Text,Discovery)] -> [(Text,FrontendInvocation)] -> IO a)
  -> IO a
withAuthorizedCatalogueContext store proof scopes action = do
  unless (length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreCatalogueContextWatch store $ \release watch limits profiles catalogues invocations -> do
    loans <- newIORef (Just release)
    let fresh = withStoreReader store (currentCatalogueFacts store proof scopes)
    catalogueView store proof scopes (\borrowed -> ResponseObservation borrowed fresh loans) (\view current visible selected ->
      action view current visible selected
        [(ident,invocation) | (ident,invocation) <- invocations, ident `elem` map (publicId . fst) visible])
      watch limits profiles catalogues
  configurationLoan "authorization catalogue-context" result

-- | A batch response borrowing the stream's original charged reader. Each
-- call owns only its configuration/watch scope, not a second reader slot.
withBorrowedAuthorizedCatalogues :: AuthorizationWatch -> CredentialProof -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> [(PublicProfile, [Scope])] -> [(Text, Discovery)] -> IO a)
  -> IO a
withBorrowedAuthorizedCatalogues original proof scopes action = do
  unless (length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  result <- withStoreCataloguesBorrowed original $ \store -> catalogueView store proof scopes BorrowedObservation action
  configurationLoan "authorization borrowed-catalogues" result

catalogueView :: CoordinationStore -> CredentialProof -> [Scope] -> (IO ViewFacts -> ViewObservation)
  -> (AuthorizedView -> ConfigurationLimits -> [(PublicProfile, [Scope])] -> [(Text, Discovery)] -> IO a)
  -> AuthorizationWatch -> ConfigurationLimits -> [PublicProfile] -> [(Text, Discovery)] -> IO a
catalogueView store proof scopes observation action watch limits profiles catalogues =
  withViewResult watch observation (catalogueViewFacts store proof scopes profiles) $ \view grants -> do
    let visible = [(profile, allowed) | profile <- profiles, Just allowed <- [lookup (publicId profile) grants]]
        identifiers = map fst grants
    action view limits visible [(ident, value) | (ident, value) <- catalogues, ident `elem` identifiers]

-- | A page-view fingerprint, including the installed execution-profile revisions.
-- It is an equality token, not a credential or live capability.
authorizedViewRevision :: AuthorizedView -> IO Text
authorizedViewRevision view@(AuthorizedView _ _ ((_, profiles), facts)) = do
  revalidateAuthorizedView view >>= either throwIO pure
  pure (viewFingerprint (profiles, facts))

-- | The durable permission-view identity of event cursors. Execution revisions
-- still fence open responses and pages, but fresh installation tokens alone do
-- not change permission to observe retained invalidations.
authorizedCursorRevision :: AuthorizedView -> IO Text
authorizedCursorRevision view@(AuthorizedView _ _ facts) = do
  revalidateAuthorizedView view >>= either throwIO pure
  pure (cursorRevision facts)

cursorRevision :: ViewFacts -> Text
cursorRevision (_, facts) = viewFingerprint ([], facts)

viewFingerprint :: ([Text], [Text]) -> Text
viewFingerprint facts = "view_" <> T.pack (show (hash (encoded ((1 :: Int), facts)) :: Digest SHA256))

-- | Authorization and its stable public binding in the caller's existing SQL
-- snapshot. Configured profiles come from the caller's original configuration loan.
catalogueAuthorization :: CredentialProof -> [PublicProfile] -> Transaction (Text, [(Text, [Scope])])
catalogueAuthorization proof profiles = do
  (facts, grants) <- catalogueFacts proof [Observe] profiles
  pure (cursorRevision facts, grants)

-- | The bound facts must still hold at the current generation. The facts read
-- is repeated after a concurrent commit within the observation allowance.
revalidateAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
revalidateAuthorizedView (AuthorizedView watch observation bound) = authorizationIO "authorization revalidation" $ do
  observe <- case observation of
    BorrowedObservation borrowed -> pure borrowed
    ResponseObservation borrowed fresh loans -> maybe fresh (const borrowed) <$> readIORef loans
  observed <- withAuthorizationReadObservation watch $ do
    facts <- observe
    unless (facts == bound) (throwIO Unauthenticated)
  unless (observed == Just ()) (throwIO Unauthenticated)

-- A wakeup is not current authority. Every timer expiry rechecks SQLite time.
awaitAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
awaitAuthorizedView view@(AuthorizedView watch _ _) =
  awaitAuthorizationChange watch >> revalidateAuthorizedView view

currentViewFacts :: CoordinationStore -> CredentialProof -> Text -> [Scope] -> IO ViewFacts
currentViewFacts store proof profile scopes = do
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfiguration store $ \_ profiles ->
    profileViewFacts store proof profile scopes profiles
  configurationLoan "authorization view-facts" result

-- | Catalogue facts under a new configuration loan, for a catalogue view whose
-- materialization loans were returned.
currentCatalogueFacts :: CoordinationStore -> CredentialProof -> [Scope] -> IO ViewFacts
currentCatalogueFacts store proof scopes = do
  result <- withStoreConfiguration store $ \_ profiles ->
    fst <$> catalogueViewFacts store proof scopes profiles
  configurationLoan "authorization catalogue-facts" result

profileViewFacts :: CoordinationStore -> CredentialProof -> Text -> [Scope] -> [PublicProfile] -> IO ViewFacts
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
        pure ((generation,[profile,revision]),["profile",epoch,credential,client,authorization,profile,actualScopes,expiry,cutoff])
      _ -> refuseTransaction Unauthenticated

catalogueViewFacts :: CoordinationStore -> CredentialProof -> [Scope] -> [PublicProfile]
  -> IO (ViewFacts, [(Text, [Scope])])
catalogueViewFacts store proof required profiles = runRead store (catalogueFacts proof required profiles)

catalogueFacts :: CredentialProof -> [Scope] -> [PublicProfile] -> Transaction (ViewFacts, [(Text, [Scope])])
catalogueFacts proof@(CredentialProof credential client _ generation) required profiles = do
    _ <- currentClient proof >>= either refuseTransaction pure
    rows <- query
      "SELECT s.authority_epoch,p.authorization_revision,c.expires_at,coalesce(a.rotation_cutoff,''),(SELECT json_group_array(json_array(profile_id,scope)) FROM (SELECT profile_id,scope FROM credential_scopes WHERE credential_id=c.id ORDER BY profile_id,scope)) FROM credentials c JOIN clients p ON p.id=c.client_id CROSS JOIN service_metadata s LEFT JOIN credential_administration a ON a.credential_id=c.id WHERE c.id=? AND s.singleton=1"
      [SQL.SQLText credential]
    case rows of
      [[SQL.SQLText epoch,SQL.SQLText authorization,SQL.SQLText expiry,SQL.SQLText cutoff,SQL.SQLText scopeRows]] -> do
        pairs <- case eitherDecodeStrict' (TE.encodeUtf8 scopeRows) :: Either String [(Text, Text)] of
          Left _ -> refuseTransaction StoreIntegrity
          Right values -> mapM grant values
        let byProfile = Map.fromListWith (<>) [(ident, [scope]) | (ident, scope) <- pairs]
            selected = [(profile, actual) | profile <- profiles,
              let actual = Map.findWithDefault [] (publicId profile) byProfile,
              not (null actual), all (`elem` actual) required]
            facts = ["catalogues",epoch,credential,client,authorization,expiry,cutoff,scopeRows]
              <> [publicId profile | (profile, _) <- selected]
            revisions = concat [[publicId profile, publicRevision profile] | (profile, _) <- selected]
        pure (((generation, revisions), facts), [(publicId profile, actual) | (profile, actual) <- selected])
      _ -> refuseTransaction Unauthenticated
  where
    grant (ident, name) = case lookup name [(scopeName scope, scope) | scope <- [Observe,Submit,Control,ExportScope]] of
      Just scope | validId ident -> pure (ident, scope)
      _ -> refuseTransaction StoreIntegrity

-- | A declared refusal is returned. A Store failure keeps the declared
-- storage-unavailable refusal, and its Store constructor is recorded privately
-- first under the named context.
authorizationIO :: Text -> IO a -> IO (Either CommandFailure a)
authorizationIO context action = try @StoreFailure (try @CommandFailure action) >>= either (storeFailureRefusal context) pure
