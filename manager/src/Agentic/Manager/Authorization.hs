{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Verified credential possession, rechecked against current transactional facts.
module Agentic.Manager.Authorization
  ( CredentialProof, authenticateCredential, currentClient, authorizeProfile, proofGeneration, credentialRateKey,
    AuthorizedView, withAuthorizedView, withAuthorizedResponse, withAuthorizedResponseLimits, withAuthorizedCatalogues, withAuthorizedCatalogueContext, authorizedViewRevision, authorizedCursorRevision, catalogueAuthorization, revalidateAuthorizedView, awaitAuthorizedView, awaitAuthorizationWakeup,
    releaseResponseLoans, attachResponseLoan, attachResponseCheck ) where

import Agentic.Manager.Fault (configurationLoan, storeFailureRefusal)
import Agentic.Manager.Profile (ConfigurationLimits, Discovery, PublicProfile, publicId, publicRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Store
import Agentic.Runtime (FrontendInvocation)
import Control.DeepSeq (NFData (rnf))
import Control.Exception (mask_, try, throwIO)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (constEq, convert)
import Data.Aeson (eitherDecodeStrict')
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text.Encoding as TE
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Time.LocalTime (ZonedTime, zonedTimeToUTC)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)

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
-- The last field holds the authorization revision and the monotonic start
-- time of the last full check of the view.
data AuthorizedView = AuthorizedView !AuthorizationWatch !ViewObservation !ViewFacts !(IORef (Maybe (Word64, Word64)))

-- | How revalidation reads current facts. A borrowed observation reads under
-- the loans of the scope that owns the view. A response observation reads
-- under its materialization loans while they are held. After
-- 'releaseResponseLoans' returns them, it acquires a reader charge, the
-- configuration guard and one SQL read for each full check alone, in the
-- lock order configuration, then database, and returns them before the check
-- ends. 'revalidateAuthorizedView' states when a check reads no facts. The
-- file slot is not part of any check. A response observation also holds the
-- checks that its owner attached with 'attachResponseCheck'.
data ViewObservation
  = BorrowedObservation !(CoordinationStore -> IO ViewFacts)
  | ResponseObservation !(CoordinationStore -> IO ViewFacts) !(CoordinationStore -> IO ViewFacts) !(IORef (Maybe (IO ()))) !(IORef (IO ()))

-- Process and execution-profile lifetimes are distinct from the permission view.
-- Page bindings retain profile revisions. Event cursors retain current grants
-- and configured profile membership across an otherwise equivalent restart.
-- The last field is the earlier of the credential expiry and its rotation
-- cutoff, which the facts also hold as text. It is 'Nothing' when either
-- value does not parse, and then every revalidation reads the facts.
data ViewFacts = ViewFacts !(Text, [Text]) ![Text] !(Maybe UTCTime)
  deriving Eq

instance NFData ViewFacts where
  rnf (ViewFacts binding facts expires) = rnf (binding, facts, expires)

-- | The earlier of the expiry and the cutoff. An empty cutoff is no cutoff.
validUntil :: Text -> Text -> Maybe UTCTime
validUntil expiry cutoff = do
  expires <- trustedTime expiry
  if T.null cutoff then pure expires else min expires <$> trustedTime cutoff
  where
    trustedTime value = case iso8601ParseM (T.unpack value) of
      Just utc -> Just utc
      Nothing -> zonedTimeToUTC <$> (iso8601ParseM (T.unpack value) :: Maybe ZonedTime)

withAuthorizedView :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO (Either CommandFailure a)
withAuthorizedView store proof profile scopes action = authorizationIO "authorization view" $ do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  withStoreAuthorizationWatch store $ \watch ->
    withView watch BorrowedObservation (\request -> currentViewFacts request proof profile scopes) action

-- | A response view. The representation is materialized under one reader
-- charge and the original configuration loan, and revalidation borrows that
-- loan while it is held. A response returns both loans with
-- 'releaseResponseLoans' before its first network write, together with any
-- file slot that its owner joined with 'attachResponseLoan'. No SQL
-- transaction spans a write. The watch stays alive until the callback returns, as an
-- authorization token only. A revalidation precedes each 16 KiB write. When
-- the authorization revision is unchanged and the last full check of the
-- view started less than one second ago, it compares only the expiry and the
-- rotation cutoff with the current time, as 'revalidateAuthorizedView'
-- describes. Otherwise it is a full check, which acquires a reader charge
-- and the configuration guard for its check alone, so a revocation or scope
-- change still stops the next write. A full check contends with ingestion
-- only for its own duration. One check
-- has one five-second admission deadline: the observation retries only while
-- it lasts, and every attempt waits for a reader place, the configuration
-- guard and the Store gate within the rest of it, as does the final
-- acknowledgement. A deadline that ends refuses the check with its Store
-- failure, which stops the response before its next write, even when the
-- status and part of the body are already sent.
withAuthorizedResponse :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO a
withAuthorizedResponse store proof profile scopes action =
  withAuthorizedResponseLimits store proof profile scopes $ \view _ -> action view

withAuthorizedResponseLimits :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> IO a) -> IO a
withAuthorizedResponseLimits store proof profile scopes action = withStoreRequest store $ \scoped -> do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead scoped (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfigurationWatch scoped $ \release watch limits profiles -> do
    loans <- newIORef (Just release)
    checks <- newIORef (pure ())
    let fresh request = withStoreReader request (currentViewFacts request proof profile scopes)
    withView watch (\borrowed -> ResponseObservation borrowed fresh loans checks)
      (\request -> profileViewFacts request proof profile scopes profiles) $ \view -> action view limits
  configurationLoan "authorization response" result

-- | Return the materialization loans of a response view before its first
-- network write. Later revalidation acquires what each check needs for that
-- check alone. A second call, or a call on a view that borrows the loans of
-- its owner, does nothing.
releaseResponseLoans :: AuthorizedView -> IO ()
releaseResponseLoans (AuthorizedView _ (ResponseObservation _ _ loans _) _ _) = mask_ $
  atomicModifyIORef' loans (\pending -> (Nothing, pending)) >>= sequence_
releaseResponseLoans (AuthorizedView _ (BorrowedObservation _) _ _) = pure ()

-- | Join an outer materialization loan, such as the file slot of the response
-- owner, to the loans that 'releaseResponseLoans' returns. The outer loan is
-- returned after the reader charge and the configuration guard. When the view
-- has already returned its loans, the outer loan is returned at once. A view
-- that borrows the loans of its owner leaves the outer loan to its own scope.
attachResponseLoan :: AuthorizedView -> IO () -> IO ()
attachResponseLoan (AuthorizedView _ (ResponseObservation _ _ loans _) _ _) release = mask_ $
  atomicModifyIORef' loans (\pending -> case pending of
    Just held -> (Just (held >> release), pure ())
    Nothing -> (Nothing, release)) >>= id
attachResponseLoan (AuthorizedView _ (BorrowedObservation _) _ _) _ = pure ()

-- | Join a check of the response owner, such as the total deadline of an
-- artifact response, to every later revalidation of a response view. The
-- check runs first in each revalidation, so it runs before each network
-- write. A check that throws refuses the revalidation, and the response
-- stops before its next write. A view that borrows the loans of its owner
-- leaves such checks to its own scope.
attachResponseCheck :: AuthorizedView -> IO () -> IO ()
attachResponseCheck (AuthorizedView _ (ResponseObservation _ _ _ checks) _ _) extra =
  atomicModifyIORef' checks (\held -> (held >> extra, ()))
attachResponseCheck (AuthorizedView _ (BorrowedObservation _) _ _) _ = pure ()

withView :: AuthorizationWatch -> ((CoordinationStore -> IO ViewFacts) -> ViewObservation) -> (CoordinationStore -> IO ViewFacts)
  -> (AuthorizedView -> IO a) -> IO a
withView watch observation observe action =
  withViewResult watch observation (fmap (\facts -> (facts, ())) . observe) (\view () -> action view)

-- A public materialization and its authorization facts come from the same
-- observation. Neither part can be resampled independently after acknowledgement.
-- Both are reads, so a concurrent commit starts a fresh read of both within
-- the observation allowance. This first observation is part of the request
-- that registered the watch, so its waits share the admission deadline of
-- that request. It is the first full check of the view, under the
-- authorization revision read before it.
withViewResult :: NFData a => AuthorizationWatch -> ((CoordinationStore -> IO ViewFacts) -> ViewObservation)
  -> (CoordinationStore -> IO (ViewFacts, a)) -> (AuthorizedView -> a -> IO b) -> IO b
withViewResult watch observation observe action = do
  started <- getMonotonicTimeNSec
  revision <- authorizationRevision watch
  observed <- withAuthorizationRequestReadObservation watch observe
  (facts, value) <- maybe (throwIO Unauthenticated) pure observed
  checked <- newIORef ((\current -> (current, started)) <$> revision)
  action (AuthorizedView watch (observation (fmap fst . observe)) facts checked) value

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
withAuthorizedCatalogueContext store proof scopes action = withStoreRequest store $ \scoped -> do
  unless (length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead scoped (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreCatalogueContextWatch scoped $ \release watch limits profiles catalogues invocations -> do
    loans <- newIORef (Just release)
    checks <- newIORef (pure ())
    let fresh request = withStoreReader request (currentCatalogueFacts request proof scopes)
    catalogueView proof scopes (\borrowed -> ResponseObservation borrowed fresh loans checks) (\view current visible selected ->
      action view current visible selected
        [(ident,invocation) | (ident,invocation) <- invocations, ident `elem` map (publicId . fst) visible])
      watch limits profiles catalogues
  configurationLoan "authorization catalogue-context" result

catalogueView :: CredentialProof -> [Scope] -> ((CoordinationStore -> IO ViewFacts) -> ViewObservation)
  -> (AuthorizedView -> ConfigurationLimits -> [(PublicProfile, [Scope])] -> [(Text, Discovery)] -> IO a)
  -> AuthorizationWatch -> ConfigurationLimits -> [PublicProfile] -> [(Text, Discovery)] -> IO a
catalogueView proof scopes observation action watch limits profiles catalogues =
  withViewResult watch observation (\request -> catalogueViewFacts request proof scopes profiles) $ \view grants -> do
    let visible = [(profile, allowed) | profile <- profiles, Just allowed <- [lookup (publicId profile) grants]]
        identifiers = map fst grants
    action view limits visible [(ident, value) | (ident, value) <- catalogues, ident `elem` identifiers]

-- | A page-view fingerprint, including the installed execution-profile revisions.
-- It is an equality token, not a credential or live capability.
authorizedViewRevision :: AuthorizedView -> IO Text
authorizedViewRevision view@(AuthorizedView _ _ (ViewFacts (_, profiles) facts _) _) = do
  revalidateAuthorizedView view >>= either throwIO pure
  pure (viewFingerprint (profiles, facts))

-- | The durable permission-view identity of event cursors. Execution revisions
-- still fence open responses and pages, but fresh installation tokens alone do
-- not change permission to observe retained invalidations.
authorizedCursorRevision :: AuthorizedView -> IO Text
authorizedCursorRevision view@(AuthorizedView _ _ facts _) = do
  revalidateAuthorizedView view >>= either throwIO pure
  pure (cursorRevision facts)

cursorRevision :: ViewFacts -> Text
cursorRevision (ViewFacts _ facts _) = viewFingerprint ([], facts)

viewFingerprint :: ([Text], [Text]) -> Text
viewFingerprint facts = "view_" <> T.pack (show (hash (encoded ((1 :: Int), facts)) :: Digest SHA256))

-- | Authorization and its stable public binding in the caller's existing SQL
-- snapshot. Configured profiles come from the caller's original configuration loan.
catalogueAuthorization :: CredentialProof -> [PublicProfile] -> Transaction (Text, [(Text, [Scope])])
catalogueAuthorization proof profiles = do
  (facts, grants) <- catalogueFacts proof [Observe] profiles
  pure (cursorRevision facts, grants)

-- | The bound facts must still hold at the current generation. The checks
-- that a response owner attached with 'attachResponseCheck' run first. Then
-- the earlier of the credential expiry and its rotation cutoff, from the
-- bound facts, is compared with the current time, and a view at or after it
-- is refused without a facts read. A full check reads the facts again. Its
-- facts read is repeated after a concurrent commit within the observation
-- allowance. The revalidation skips the full check only when the
-- authorization revision equals the revision of the last full check of the
-- view and that check started less than one second ago. Every commit that
-- changes authorization facts advances that revision before its COMMIT, so a
-- revocation, a rotation cutoff, a scope change or a retirement still stops
-- the next write. The one-second bound also limits how long a change of
-- facts that no owner marked can go unnoticed.
revalidateAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
revalidateAuthorizedView (AuthorizedView watch observation bound@(ViewFacts _ _ expires) checked) = authorizationIO "authorization revalidation" $ do
  observe <- case observation of
    BorrowedObservation borrowed -> pure borrowed
    ResponseObservation borrowed fresh loans checks -> do
      readIORef checks >>= id
      maybe fresh (const borrowed) <$> readIORef loans
  now <- getCurrentTime
  when (maybe False (now >=) expires) (throwIO Unauthenticated)
  started <- getMonotonicTimeNSec
  revision <- authorizationRevision watch
  previous <- readIORef checked
  let recent = case (revision, previous, expires) of
        (Just current, Just (seen, at), Just _) -> current == seen && started - at < 1000000000
        _ -> False
  unless recent $ do
    observed <- withAuthorizationReadObservation watch $ \request -> do
      facts <- observe request
      unless (facts == bound) (throwIO Unauthenticated)
    unless (observed == Just ()) (throwIO Unauthenticated)
    writeIORef checked ((\current -> (current, started)) <$> revision)

-- A wakeup is not current authority. Every timer expiry rechecks SQLite time.
awaitAuthorizedView :: AuthorizedView -> IO (Either CommandFailure ())
awaitAuthorizedView view = awaitAuthorizationWakeup view >> revalidateAuthorizedView view

-- | Wait for a commit, a closed scope or the one-second timer on the watch of
-- the view, with no Store loan held. The wakeup carries no authority. The
-- caller authorizes its next read again.
awaitAuthorizationWakeup :: AuthorizedView -> IO ()
awaitAuthorizationWakeup (AuthorizedView watch _ _ _) = awaitAuthorizationChange watch

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
        pure (ViewFacts (generation,[profile,revision]) ["profile",epoch,credential,client,authorization,profile,actualScopes,expiry,cutoff] (validUntil expiry cutoff))
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
        pure (ViewFacts (generation, revisions) facts (validUntil expiry cutoff), [(publicId profile, actual) | (profile, actual) <- selected])
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
