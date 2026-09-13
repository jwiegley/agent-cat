{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Installed operator authority, separate from historical invocation provenance.
module Agentic.Manager.Profile
  ( OperatorProfile (..), Ownership (..), ConfigurationLimits (..),
    validateConfigurationLimits, validateProfiles, QueryLimits (..), Registry,
    PublicProfile, publicId, publicRevision, Diagnostic (..),
    Selection, selectionContext, selectionInvocation,
    Discovery, discoveryServer, discoveryWorkflows, discoveryRevision, discoveryEntries, discoverySelection, discoveryProfileRevision, currentCatalogues,
    newRegistry, reloadProfiles, publicProfiles, selectProfile, probeProfile
  ) where

import Agentic.Runtime
  ( PersonAnswering, FrontendInvocation (..), FrontendServer (..), FrontendCapabilities (..),
    WorkflowDescriptor (..), DescriptorCapabilities (..),
    decodeFrontendCapabilities, decodeWorkflowDescriptors, maxFrontendQueryBytes,
    createProcessGroup,
    terminateProcessGroup, closeGroupPipes, groupOutput, groupErrors, waitProcessGroup )
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception (Exception, IOException, SomeException, bracket, finally, mask, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Result (Success, Error), ToJSON (toJSON), encode, fromJSON, object, (.=))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath (isAbsolute)
import System.IO (Handle)
import System.Process (CreateProcess (cwd, env, std_in, std_out, std_err), StdStream (NoStream, CreatePipe), proc)
import System.Timeout (timeout)

-- | Ownership asserted by trusted CLI policy, not inferred from transport or names.
data Ownership = ServiceOwned | ClientBound deriving (Eq, Show)

-- | Private immutable configuration supplied only by operator composition.
-- The caller validates target grammar, ownership (including named routes), and
-- workspace/root roles. Labels are explicitly public. No manifest or HTTP input
-- may construct this value. This module does not read configuration files.
data OperatorProfile = OperatorProfile
  { operatorId :: !Text,
    operatorWorkspaceLabel :: !Text,
    operatorTargetLabel :: !Text,
    operatorRunnerAlias :: !Text,
    operatorExecutable :: !FilePath,
    operatorPrefix :: ![String],
    operatorCwd :: !FilePath,
    operatorTargetArguments :: ![Text],
    operatorEnvironment :: ![(String, String)],
    operatorOwnership :: !Ownership,
    operatorQuarantined :: !Bool,
    operatorPersonAnswering :: !PersonAnswering,
    operatorResourceKeys :: ![Text],
    operatorConfigurationLimits :: !ConfigurationLimits
  }

-- | The configurable part of frozen manager Limits, captured with one revision.
-- Fields retain their contract scopes. This is not a per-profile allocation.
-- Old selections retain these facts, not authority over current coordinator limits.
data ConfigurationLimits = ConfigurationLimits
  { limitDrafts :: !Int,
    limitGlobalDrafts :: !Int,
    limitGlobalCaptureBytes :: !Int,
    limitGlobalPageSets :: !Int,
    limitGlobalConnections :: !Int,
    limitGlobalDatabaseReaders :: !Int,
    limitGlobalMutationLedgerBytes :: !Int,
    limitSafetyControlsPerMinute :: !Int,
    limitExecutionReservations :: !Int
  } deriving (Eq)

validateConfigurationLimits :: ConfigurationLimits -> Either Diagnostic ()
validateConfigurationLimits limits = unless
  (all (\n -> n >= 1 && n <= 2147483647)
    [limitDrafts limits, limitGlobalDrafts limits, limitGlobalCaptureBytes limits,
     limitGlobalPageSets limits, limitGlobalConnections limits, limitGlobalDatabaseReaders limits,
     limitGlobalMutationLedgerBytes limits, limitSafetyControlsPerMinute limits]
    && limitExecutionReservations limits >= 1 && limitExecutionReservations limits <= 16)
  (Left InvalidConfiguration)

-- | Per-query byte and execution budgets, bounded by the discovery ceiling.
data QueryLimits = QueryLimits
  { queryBytes :: !Int, queryMicros :: !Int }

-- | Fixed failure categories. No process output or exception text is retained.
data Diagnostic
  = InvalidConfiguration | UnknownProfile | StaleRevision | Quarantined
  | SupervisionUnavailable | UnsupportedOperation | OutputOverflow
  | QueryTimeout | ProcessFailure | InvalidReply | RunnerVersionMismatch
  deriving (Eq, Show)

instance Exception Diagnostic

-- | The frozen public Profile projection, with no private execution fields.
data PublicProfile = PublicProfile
  { publicId :: !Text, publicRevision :: !Text,
    publicWorkspaceLabel :: !Text, publicTargetLabel :: !Text,
    publicFailure :: !(Maybe Diagnostic)
  } deriving (Eq, Show)

instance ToJSON PublicProfile where
  toJSON p = object
    [ "version" .= (1 :: Int), "id" .= publicId p,
      "revision" .= publicRevision p,
      "workspaceLabel" .= publicWorkspaceLabel p,
      "targetLabel" .= publicTargetLabel p,
      "readiness" .= readiness, "refusal" .= refusal ]
    where
      (readiness, refusal) = case publicFailure p of
        Nothing -> ("ready" :: Text, Nothing :: Maybe Text)
        Just Quarantined -> ("quarantined", Just "quarantined")
        Just UnsupportedOperation -> ("unavailable", Just "unsupported-operation")
        Just _ -> ("unavailable", Just "supervision-unavailable")

-- | A selected immutable context, not an approval or an independently launchable handle.
data Selection = Selection !OperatorProfile

selectionContext :: Selection -> OperatorProfile
selectionContext (Selection p) = p

selectionInvocation :: Selection -> FrontendInvocation
selectionInvocation (Selection p) = FrontendInvocation
  1 (operatorRunnerAlias p) (T.pack (operatorExecutable p)) (map T.pack (operatorPrefix p))

-- | Private discovery evidence. Server identity is process-reported, not authority.
data Discovery = Discovery
  { discoveryServer :: !FrontendServer,
    discoveryWorkflows :: ![WorkflowDescriptor],
    discoveryRevision :: !Text,
    discoveryEntries :: ![(Text, WorkflowDescriptor)],
    discoverySelection :: !Selection,
    discoveryProfileRevision :: !Text }

data Installed = Installed !OperatorProfile !PublicProfile !(Maybe Discovery)
data Snapshot = Snapshot !Integer !(Map.Map Text Installed)

-- | A registry-local revision namespace and one atomically replaced snapshot.
data Registry = Registry !Text !QueryLimits !(MVar Snapshot)

newRegistry :: QueryLimits -> IO (Either Diagnostic Registry)
newRegistry limits
  | queryBytes limits <= 0 || queryBytes limits > 4194304
      || queryMicros limits <= 0 || queryMicros limits > 30000000 = pure (Left InvalidConfiguration)
  | otherwise = do
      nonce <- getRandomBytes 16 :: IO BS.ByteString
      lock <- newMVar (Snapshot 0 Map.empty)
      pure (Right (Registry (TE.decodeUtf8 (convertToBase Base16 nonce)) limits lock))

-- | Successful reload gives every profile a fresh token, even if values agree.
-- Tokens contain random registry identity and a generation, never secret hashes.
-- Failed validation changes neither the generation nor the installed snapshot.
reloadProfiles :: Registry -> [OperatorProfile] -> IO (Either Diagnostic [PublicProfile])
reloadProfiles (Registry nonce _ lock) candidates = case validateProfiles candidates of
  Left failure -> pure (Left failure)
  Right () -> modifyMVar lock $ \old@(Snapshot generation _) -> do
      let revision = nonce <> "_" <> T.pack (show (generation + 1))
          install p = Installed p (PublicProfile (operatorId p) revision
            (operatorWorkspaceLabel p) (operatorTargetLabel p) (Just (initialFailure p))) Nothing
          entries = Map.fromList [(operatorId p, install p) | p <- candidates]
      if not (validToken revision)
        then pure (old, Left InvalidConfiguration)
        else pure (Snapshot (generation + 1) entries, Right (map installedPublic (Map.elems entries)))

publicProfiles :: Registry -> IO [PublicProfile]
publicProfiles (Registry _ _ lock) = withMVar lock $ \(Snapshot _ entries) ->
  pure (map installedPublic (Map.elems entries))

installedPublic :: Installed -> PublicProfile
installedPublic (Installed _ p _) = p

initialFailure :: OperatorProfile -> Diagnostic
initialFailure p
  | operatorQuarantined p = Quarantined
  | operatorOwnership p == ClientBound = UnsupportedOperation
  | otherwise = SupervisionUnavailable

validToken :: Text -> Bool
validToken t = not (T.null t) && T.length t <= 128 && T.all asciiToken t
  where
    asciiToken c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9') || c == '_' || c == '-'

validateProfiles :: [OperatorProfile] -> Either Diagnostic ()
validateProfiles candidates = unless
  (all validDefinition candidates && Set.size (Set.fromList (map operatorId candidates)) == length candidates)
  (Left InvalidConfiguration)

validDefinition :: OperatorProfile -> Bool
validDefinition p = validToken (operatorId p)
  && T.length (operatorWorkspaceLabel p) <= 4096
  && T.length (operatorTargetLabel p) <= 4096
  && validInvocation
  && isAbsolute (operatorExecutable p) && isAbsolute (operatorCwd p)
  && all (notElem '\0') (operatorExecutable p : operatorCwd p : operatorPrefix p)
  && all (not . T.any (== '\0')) (operatorTargetArguments p)
  && all validBinding bindings
  && Set.size (Set.fromList (map fst bindings)) == length bindings
  && length (operatorResourceKeys p) <= 256
  && all validToken (operatorResourceKeys p)
  && Set.size (Set.fromList (operatorResourceKeys p)) == length (operatorResourceKeys p)
  && validateConfigurationLimits (operatorConfigurationLimits p) == Right ()
  where
    -- Reuse the native provenance codec without treating provenance as authority.
    validInvocation = case fromJSON (toJSON (selectionInvocation (Selection p))) :: Result FrontendInvocation of
      Success _ -> True
      Error _ -> False
    bindings = operatorEnvironment p
    validBinding (key, value) = not (null key) && all (`notElem` ['=', '\0']) key && '\0' `notElem` value

lookupInstalled :: Map.Map Text Installed -> Text -> Text -> Either Diagnostic Installed
lookupInstalled entries ident revision = case Map.lookup ident entries of
  Nothing -> Left UnknownProfile
  Just installed@(Installed _ p _)
    | revision /= publicRevision p -> Left StaleRevision
    | otherwise -> Right installed

-- | Check current ID, exact revision, and discovery readiness before handing off
-- private values. Parent must serialize approval with reload and revalidate an
-- unapproved selection at that transaction. This value alone is not approval.
selectProfile :: Registry -> Text -> Text -> IO (Either Diagnostic Selection)
selectProfile (Registry _ _ lock) ident revision = withMVar lock $ \(Snapshot _ entries) ->
  pure $ do
    Installed p view _ <- lookupInstalled entries ident revision
    maybe (Right (Selection p)) Left (publicFailure view)

-- | Probe only installed authority. Reload cannot revoke between selection and
-- either launch. No public function launches a previously returned selection.
-- ponytail: registry lock serializes queries, per-profile leases if contention matters.
probeProfile :: Registry -> Text -> Text -> IO (Either Diagnostic Discovery)
probeProfile (Registry _ limits lock) ident revision = mask $ \restore -> do
  outcome <- modifyMVar lock $ \snapshot@(Snapshot generation entries) ->
    case lookupInstalled entries ident revision of
      Left failure -> pure (snapshot, Right (Left failure))
      Right (Installed p view _)
        | operatorQuarantined p -> pure (snapshot, Right (Left Quarantined))
        | operatorOwnership p == ClientBound -> pure (snapshot, Right (Left UnsupportedOperation))
        | otherwise -> do
            result <- try @SomeException (restore (discover limits p revision))
            let discovered = either (const (Left QueryTimeout)) id result
                updated = view {publicFailure = either Just (const Nothing) discovered}
                current = Installed p updated (either (const Nothing) Just discovered)
            pure (Snapshot generation (Map.insert ident current entries), result)
  either throwIO pure outcome

-- | Only current successful discovery, cleared by reload and every failed probe.
currentCatalogues :: Registry -> IO [(Text, Discovery)]
currentCatalogues (Registry _ _ lock) = withMVar lock $ \(Snapshot _ entries) ->
  pure [(ident, catalogue) | (ident, Installed _ _ (Just catalogue)) <- Map.toList entries]

discover :: QueryLimits -> OperatorProfile -> Text -> IO (Either Diagnostic Discovery)
discover limits p profileRevision = do
  capabilities <- query limits p ["frontend", "--capabilities"]
  case capabilities >>= either (const (Left InvalidReply)) Right . decodeFrontendCapabilities of
    Left failure -> pure (Left failure)
    Right caps | not (supportsMutation caps) -> pure (Left UnsupportedOperation)
    Right caps -> do
      catalogue <- query limits p ["list", "--json", "--descriptor-version", "3"]
      nonce <- getRandomBytes 16 :: IO BS.ByteString
      pure $ do
        bytes <- catalogue
        rows <- either (const (Left InvalidReply)) Right (decodeWorkflowDescriptors bytes)
        unless (all ((== frontendServerRunnerVersion (capabilityServer caps)) . workflowRunnerVersion) rows)
          (Left RunnerVersionMismatch)
        unless (all supportsWorkflow rows) (Left UnsupportedOperation)
        unless (Set.size (Set.fromList (map workflowName rows)) == length rows
          && all ((<= 256) . length . workflowInputs) rows) (Left InvalidReply)
        let revision = TE.decodeUtf8 (convertToBase Base16 nonce)
            identifier row = "workflow_" <> T.pack (show (hash (BL.toStrict (encode (operatorId p, workflowName row))) :: Digest SHA256))
        pure (Discovery (capabilityServer caps) rows revision [(identifier row, row) | row <- rows] (Selection p) profileRevision)

supportsMutation :: FrontendCapabilities -> Bool
supportsMutation c = and
  [ 1 `elem` capabilitySessionVersions c,
    all (`elem` capabilitySessionOperations c) ["prepare", "prepare-lineage", "start", "discard"],
    all (`elem` capabilityInputSources c) ["literal", "file", "transport"],
    1 `elem` capabilityInvocationVersions c,
    capabilityMaxRequestBytes c >= toInteger maxFrontendQueryBytes,
    2 `elem` capabilityIoVersions c,
    all (`elem` capabilityIoOperations c)
      ["open-root", "read-question", "read-result", "list-runs", "read-run", "read-run-checkpoint", "read-question-schema"],
    1 `elem` capabilityExportVersions c,
    "export-result" `elem` capabilityExportOperations c,
    capabilityExportFormat c == "result-json",
    capabilityExportDestination c == "state-exports",
    all (`elem` capabilityManifestVersions c) [2, 3],
    capabilityLegacyManifests c ]

supportsWorkflow :: WorkflowDescriptor -> Bool
supportsWorkflow d = workflowDescriptorVersion d == 3
  && and [descriptorStructuredRun c, descriptorWholeRunCancel c,
          descriptorControlFd c == Just 3, descriptorRequestControls c,
          descriptorSemanticResume c, descriptorImmutableFork c, descriptorRestartFromScratch c]
  where c = workflowCapabilities d

query :: QueryLimits -> OperatorProfile -> [String] -> IO (Either Diagnostic BS.ByteString)
query limits p arguments = do
  result <- try @IOException $ try @Diagnostic $ timeout (queryMicros limits) $
    bracket (createProcessGroup command) cleanup collect
  pure $ case result of
    Left _ -> Left ProcessFailure
    Right (Left failure) -> Left failure
    Right (Right Nothing) -> Left QueryTimeout
    Right (Right (Just value)) -> value
  where
    command = (proc (operatorExecutable p) (operatorPrefix p <> arguments))
      { cwd = Just (operatorCwd p), env = Just (operatorEnvironment p),
        std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe }
    -- Runtime retains sole-reaper authority. Final KILL/reap is not a hard OS deadline.
    cleanup group = terminateProcessGroup 2000000 group `finally` closeGroupPipes group
    collect group = case (groupOutput group, groupErrors group) of
      (Just output, Just errors) -> do
        (bytes, _) <- concurrently (readBounded (queryBytes limits) output) (readBounded (queryBytes limits) errors)
        code <- waitProcessGroup group
        pure (if code == ExitSuccess then Right bytes else Left ProcessFailure)
      _ -> pure (Left ProcessFailure)

readBounded :: Int -> Handle -> IO BS.ByteString
readBounded limit handle = BS.concat . reverse <$> go 0 []
  where
    go size chunks = do
      chunk <- BS.hGetSome handle (min 32768 (limit - size + 1))
      if BS.null chunk then pure chunks else do
        let next = size + BS.length chunk
        unless (next <= limit) (throwIO OutputOverflow)
        go next (chunk : chunks)
