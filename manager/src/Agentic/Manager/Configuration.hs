{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded operator authority and a retained manager-root binding.
module Agentic.Manager.Configuration
  ( Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    acquireConfigurationStorage, releaseConfigurationStorage, withConfigurationSnapshot, withConfigurationCatalogues
  ) where

import Agentic.Manager.Lease (acquireLease, duplicateLease)
import Agentic.Manager.Profile
import Agentic.Manager.Root (validateRootSeparation)
import Agentic.Runtime
  ( PrivateRoot, FrontendInvocation (..), StateRootRole (ManagerStateRoot), assertPrivateRoot,
    openPrivateRoot, openPrivateSubroot, closePrivateRoot, withPrivateDirectoryAt, readStateRootRoleAt,
    establishManagerRootRole, readPrivateConfigurationFile )
import Control.Concurrent.MVar (MVar, modifyMVarMasked, newMVar, withMVar, tryTakeMVar, putMVar)
import Control.Exception (IOException, bracketOnError, finally, mask, mask_, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value, withObject, withText, (.:))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Object, Parser, parseEither)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath (isAbsolute)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd)

-- | CLI-owned target grammar and credential-argv validation, without workflow IO.
type TargetValidator = [Text] -> Either Diagnostic ()

-- | One fully validated private file snapshot. Constructors are not public.
data Configuration = Configuration !FilePath ![FilePath] !ConfigurationLimits ![OperatorProfile]

-- | One leased root binding, closed explicitly by its owner. No worker is created.
data InstalledConfiguration = InstalledConfiguration !(MVar (Maybe ActiveConfiguration)) !(MVar Bool)
data ActiveConfiguration = ActiveConfiguration !PrivateRoot !FilePath ![FilePath] !ConfigurationLimits !Registry !Fd

-- | Read no more than the frozen JSON byte ceiling, then reject duplicate keys,
-- nesting beyond 64 containers, unknown fields, and invalid native policy values.
-- The CLI credential predicate checks every runner prefix without interpreting
-- wrapper arguments as native target grammar, including unused runner definitions.
loadConfiguration :: TargetValidator -> (String -> Bool) -> FilePath -> IO (Either Diagnostic Configuration)
loadConfiguration validateTarget isCredentialArgument path = configurationIO $ do
  bytes <- readPrivateConfigurationFile path 2097152
  configuration <- requireRight $ do
    value <- either (const (Left InvalidConfiguration)) Right (decodeStrictValue bytes)
    either (const (Left InvalidConfiguration)) Right (parseEither (parseConfiguration isCredentialArgument) value)
  let Configuration _ _ _ profiles = configuration
  mapM_ (requireRight . validateTarget . operatorTargetArguments) profiles
  pure configuration

-- | Initial establishment on an existing, durably provisioned private root.
-- Exclusive service ownership and all configuration checks precede marker publication.
-- A marker whose publication was uncertain is never rolled back or deleted here.
installConfiguration :: Configuration -> IO (Either Diagnostic InstalledConfiguration)
installConfiguration (Configuration path retention limits profiles) = configurationIO $
  bracketOnError (openPrivateRoot "manager configuration root" path) closePrivateRoot $ \root -> do
    bracketOnError (acquireLease root) closeFd $ \lease -> do
      validateRootSeparation root retention
      registry <- newRegistry (QueryLimits 4194304 30000000) >>= requireRight
      _ <- reloadProfiles registry profiles >>= requireRight
      establishManagerRootRole root
      InstalledConfiguration <$> newMVar (Just (ActiveConfiguration root path retention limits registry lease)) <*> newMVar False

-- | Active reload cannot move the root, recreate a lost role, or release ownership.
-- Limits and all profile revisions commit under one configuration lock. The parent
-- must use this same reload boundary when coordinating pending approval invalidation.
reloadConfiguration :: InstalledConfiguration -> Configuration -> IO (Either Diagnostic [PublicProfile])
reloadConfiguration (InstalledConfiguration lock _) (Configuration path retention limits profiles) =
  modifyMVarMasked lock $ \current -> case current of
    Nothing -> pure (Nothing, Left InvalidConfiguration)
    Just active@(ActiveConfiguration root bound _ _ registry lease) -> do
      checked <- configurationIO $ do
        require (path == bound)
        assertActive active
        validateRootSeparation root retention
      case checked of
        Left failure -> pure (current, Left failure)
        -- Keep the outer transaction masked through both MVar publications.
        Right () -> do
          result <- reloadProfiles registry profiles
          pure (case result of
            Left _ -> current
            Right _ -> Just (ActiveConfiguration root bound retention limits registry lease), result)

closeConfiguration :: InstalledConfiguration -> IO ()
closeConfiguration (InstalledConfiguration lock _) = mask_ $ do
  current <- modifyMVarMasked lock (\active -> pure (Nothing, active))
  case current of
    Nothing -> pure ()
    Just (ActiveConfiguration root _ _ _ _ lease) -> closePrivateRoot root `finally` closeFd lease

-- | Internal storage acquisition. One slot per installation survives concurrent close.
-- The caller owns both returned resources and must release the slot after cleanup.
acquireConfigurationStorage :: InstalledConfiguration -> IO (PrivateRoot, Fd)
acquireConfigurationStorage installed@(InstalledConfiguration _ slot) = do
  acquired <- withActive installed $ \(ActiveConfiguration root _ _ _ _ lease) ->
    modifyMVarMasked slot $ \occupied -> do
      require (not occupied)
      pair <- bracketOnError (openPrivateSubroot root []) closePrivateRoot $ \retained -> do
        copied <- duplicateLease lease
        pure (retained, copied)
      pure (True, pair)
  requireRight acquired

releaseConfigurationStorage :: InstalledConfiguration -> IO ()
releaseConfigurationStorage (InstalledConfiguration _ slot) =
  modifyMVarMasked slot (const (pure (False, ())))

-- | Internal fail-fast configuration boundary. Lock order is configuration, then store.
withConfigurationSnapshot :: InstalledConfiguration -> (ConfigurationLimits -> [PublicProfile] -> IO a) -> IO (Either Diagnostic a)
withConfigurationSnapshot installed action = withConfigurationCatalogues installed $ \limits profiles _ -> action limits profiles

withConfigurationCatalogues :: InstalledConfiguration -> (ConfigurationLimits -> [PublicProfile] -> [(Text, Discovery)] -> IO a) -> IO (Either Diagnostic a)
withConfigurationCatalogues (InstalledConfiguration lock _) action = mask $ \restore -> do
  available <- tryTakeMVar lock
  case available of
    Nothing -> pure (Left SupervisionUnavailable)
    Just current -> (case current of
      Nothing -> pure (Left InvalidConfiguration)
      Just active@(ActiveConfiguration _ _ _ limits registry _) ->
        configurationIO $ do
          assertActive active
          profiles <- publicProfiles registry
          catalogues <- currentCatalogues registry
          restore (action limits profiles catalogues)) `finally` putMVar lock current

configurationSnapshot :: InstalledConfiguration -> IO (Either Diagnostic (ConfigurationLimits, [PublicProfile]))
configurationSnapshot installed = withActive installed $ \(ActiveConfiguration _ _ _ limits registry _) ->
  (\profiles -> (limits, profiles)) <$> publicProfiles registry

selectConfiguredProfile :: InstalledConfiguration -> Text -> Text -> IO (Either Diagnostic Selection)
selectConfiguredProfile installed ident revision = flatten <$> withActive installed
  (\(ActiveConfiguration _ _ _ _ registry _) -> selectProfile registry ident revision)

probeConfiguredProfile :: InstalledConfiguration -> Text -> Text -> IO (Either Diagnostic Discovery)
probeConfiguredProfile installed ident revision = flatten <$> withActive installed
  (\(ActiveConfiguration _ _ _ _ registry _) -> probeProfile registry ident revision)

withActive :: InstalledConfiguration -> (ActiveConfiguration -> IO a) -> IO (Either Diagnostic a)
withActive (InstalledConfiguration lock _) action = withMVar lock $ \current -> case current of
  Nothing -> pure (Left InvalidConfiguration)
  Just active -> configurationIO (assertActive active >> action active)

assertActive :: ActiveConfiguration -> IO ()
assertActive (ActiveConfiguration root _ retention _ _ _) = do
  assertPrivateRoot root
  role <- withPrivateDirectoryAt root [] readStateRootRoleAt
  require (role == ManagerStateRoot)
  validateRootSeparation root retention

configurationIO :: IO a -> IO (Either Diagnostic a)
configurationIO action = either (const (Left InvalidConfiguration)) id <$> try @IOException (try @Diagnostic action)

require :: Bool -> IO ()
require condition = unless condition (throwIO InvalidConfiguration)

requireRight :: Either Diagnostic a -> IO a
requireRight = either throwIO pure

flatten :: Either Diagnostic (Either Diagnostic a) -> Either Diagnostic a
flatten = either Left id

parseConfiguration :: (String -> Bool) -> Value -> Parser Configuration
parseConfiguration isCredentialArgument = withObject "operator configuration" $ \o -> do
  closed ["version", "managerRoot", "localRetentionRoots", "runners", "limits", "profiles"] o
  version <- o .: "version" :: Parser Int
  unless (version == 1) (fail "unsupported version")
  root <- o .: "managerRoot" >>= absolutePath
  retention <- o .: "localRetentionRoots" >>= boundedList 256 >>= traverse absolutePath
  distinct retention
  runners <- o .: "runners" >>= boundedList 256 >>= traverse (parseRunner isCredentialArgument)
  distinct (map fst runners)
  limits <- o .: "limits" >>= parseLimits
  profiles <- o .: "profiles" >>= boundedList 256 >>= traverse (parseProfile limits (Map.fromList runners))
  either (const (fail "invalid profiles")) pure (validateProfiles profiles)
  pure (Configuration root retention limits profiles)

parseLimits :: Value -> Parser ConfigurationLimits
parseLimits = withObject "configuration limits" $ \o -> do
  closed ["drafts", "globalDrafts", "globalCaptureBytes", "globalPageSets", "globalConnections",
          "globalDatabaseReaders", "globalMutationLedgerBytes", "safetyControlsPerMinute", "executionReservations"] o
  limits <- ConfigurationLimits <$> o .: "drafts" <*> o .: "globalDrafts" <*> o .: "globalCaptureBytes"
    <*> o .: "globalPageSets" <*> o .: "globalConnections" <*> o .: "globalDatabaseReaders"
    <*> o .: "globalMutationLedgerBytes" <*> o .: "safetyControlsPerMinute" <*> o .: "executionReservations"
  either (const (fail "invalid limits")) pure (validateConfigurationLimits limits)
  pure limits

parseRunner :: (String -> Bool) -> Value -> Parser (Text, (FilePath, [String]))
parseRunner isCredentialArgument = withObject "installed runner" $ \o -> do
  closed ["alias", "executable", "prefix"] o
  alias <- o .: "alias"
  executable <- o .: "executable" >>= absolutePath
  prefix <- o .: "prefix" >>= arguments
  when (any (isCredentialArgument . T.unpack) prefix) (fail "credential-bearing runner prefix")
  _ <- parseJSON (toJSON (FrontendInvocation 1 alias (T.pack executable) prefix)) :: Parser FrontendInvocation
  pure (alias, (executable, map T.unpack prefix))

parseProfile :: ConfigurationLimits -> Map.Map Text (FilePath, [String]) -> Value -> Parser OperatorProfile
parseProfile limits runners = withObject "installed profile" $ \o -> do
  closed ["id", "runner", "workspace", "workspaceLabel", "targetLabel", "targetArguments",
          "environment", "ownership", "quarantined", "personAnswering", "resourceKeys"] o
  alias <- o .: "runner"
  (executable, prefix) <- maybe (fail "unknown runner") pure (Map.lookup alias runners)
  profile <- OperatorProfile <$> o .: "id" <*> o .: "workspaceLabel" <*> o .: "targetLabel"
    <*> pure alias <*> pure executable <*> pure prefix
    <*> (o .: "workspace" >>= absolutePath) <*> (o .: "targetArguments" >>= arguments)
    <*> (o .: "environment" >>= boundedList 256 >>= traverse parseBinding)
    <*> (o .: "ownership" >>= withText "ownership" (\value -> case value of
      "service-owned" -> pure ServiceOwned
      "client-bound" -> pure ClientBound
      _ -> fail "invalid ownership"))
    <*> o .: "quarantined" <*> o .: "personAnswering" <*> o .: "resourceKeys" <*> pure limits
  -- Known client bridge/session dependencies are not made service-owned by an
  -- operator label or by ACP transport. Arbitrary executable code is not proved safe.
  when (operatorOwnership profile == ClientBound || any ((`elem` clientBindings) . fst) (operatorEnvironment profile)) $
    fail "client-bound policy"
  pure profile
  where
    clientBindings = ["AGENT_CAT_PI_BRIDGE_SOCKET", "AGENT_CAT_PI_BRIDGE_TOKEN_FILE",
                      "AGENT_CAT_PI_REMOTE_SOCKET", "AGENT_CAT_PI_REMOTE_SESSION"]

parseBinding :: Value -> Parser (String, String)
parseBinding = withObject "environment binding" $ \o -> do
  closed ["name", "value"] o
  name <- o .: "name" >>= boundedText 128
  value <- o .: "value" >>= boundedText 65536
  pure (T.unpack name, T.unpack value)

arguments :: [Text] -> Parser [Text]
arguments values = do
  _ <- boundedList 4096 values
  unless (sum (map (toInteger . BS.length . TE.encodeUtf8) values) <= 65536) (fail "argument byte bound")
  traverse (boundedText 65536) values

absolutePath :: Text -> Parser FilePath
absolutePath value = do
  _ <- boundedText 4096 value
  let path = T.unpack value
  unless (isAbsolute path) (fail "path must be absolute")
  pure path

boundedText :: Int -> Text -> Parser Text
boundedText limit value = do
  unless (T.length value <= limit && not (T.any (== '\0') value)) (fail "text bound")
  pure value

boundedList :: Int -> [a] -> Parser [a]
boundedList limit values = do
  unless (length values <= limit) (fail "list bound")
  pure values

distinct :: Ord a => [a] -> Parser ()
distinct values = unless (Set.size (Set.fromList values) == length values) (fail "duplicate definition")

closed :: [Text] -> Object -> Parser ()
closed allowed o = unless (all ((`elem` allowed) . Key.toText) (KM.keys o)) (fail "unknown field")
