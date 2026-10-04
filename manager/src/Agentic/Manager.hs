{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Trusted profile authority and storage boundaries for runtime coordination.
module Agentic.Manager
  ( module Agentic.Manager.Profile,
    module Agentic.Manager.Root,
    Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration, validateConfigurationProfiles,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, withServingStore, storeIdentity, checkpointStore, backupCoordinationStore, RestoreFence (..), StoreRestoration (..), restoreCoordinationStore,
    LocalAdminRequest, decodeLocalAdminRequest, administerCredentials, withLocalAdministration,
    AdministrationHooks (..), offlineAdministration, StoreState (..), LifetimeFacts (..), stoppedLifetime, ServeHooks (..), serveManager,
    ListenerFileRefused (..), listenerUrl,
  ) where

import Agentic.Manager.Profile
import Agentic.Manager.Configuration
import Agentic.Manager.Root

import Agentic.Manager.Store
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.LocalAdmin (AdministrationHooks (..), offlineAdministration, withLocalAdministration)
import Agentic.Manager.Quarantine (StoreState (..), LifetimeFacts (..), stoppedLifetime)
import Agentic.Manager.Protocol.LocalAdmin (LocalAdminRequest, decodeLocalAdminRequest)
import qualified Agentic.Manager.Application as Application
import qualified Agentic.Manager.History as History
import Agentic.Manager.Protocol.Command (CommandFailure)
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.Transport as Transport
import Agentic.Manager.Transport (ListenerFileRefused (..))
import Control.Exception (bracket, throwIO, try)
import Control.Monad (forM, void)
import Data.Text (Text)
import qualified Data.Text as T

-- | The actions that the composition of a serving manager supplies.
-- 'serveReload' loads the configuration file of the manager again and
-- installs it with 'reloadConfiguration' on the given installation.
-- 'serveStop' requests the end of the serving process with the same effect as
-- the termination signal: the action of 'serveManager' is interrupted, its
-- scopes end with their original cleanup, and the process exits with status
-- 0. 'serveListening' receives the URL of the @/v1@ base, from
-- 'listenerUrl', once the HTTPS listener is bound.
data ServeHooks = ServeHooks
  { serveReload :: InstalledConfiguration -> IO (Either Diagnostic [PublicProfile]),
    serveStop :: IO (),
    serveListening :: Text -> IO ()
  }

-- | The URL of the @/v1@ base of a listener, with a numeric IPv6 host in
-- brackets.
listenerUrl :: HttpsConfiguration -> Text
listenerUrl https = "https://" <> host <> ":" <> T.pack (show (httpsPort https)) <> "/v1"
  where
    host = if T.any (== ':') (httpsHost https) then "[" <> httpsHost https <> "]" else httpsHost https

-- | One foreground listener within the original configuration and Store
-- lifetimes. Each legacy binding names a configured local retention root and
-- a configured profile. It is bound through 'History.bindLegacyHistory'
-- before the service starts, and a binding that fails refuses the start with
-- 'InvalidConfiguration'. With an administration root, the local
-- administration channel serves @reload-profiles@ with 'serveReload',
-- @drain@ with 'Service.drain' and @shutdown@ with 'serveStop', and @status@
-- reports the facts of 'Service.lifetimeFacts', with @draining@ after a
-- drain. After a successful reload, each installed
-- profile is probed, as at the start. A drain keeps the listener serving
-- until the process ends. A shutdown calls 'serveStop' after its reply.
serveManager :: ServeHooks -> Configuration -> [(FilePath, Text)] -> IO ()
serveManager hooks configuration legacy = do
  https <- maybe (throwIO InvalidConfiguration) pure (configurationHttps configuration)
  bracket (installConfiguration configuration >>= either throwIO pure) closeConfiguration $ \installed -> do
    (limits, profiles) <- configurationSnapshot installed >>= either throwIO pure
    let probe = mapM_ (\profile -> void (probeConfiguredProfile installed (publicId profile) (publicRevision profile)))
        reload = serveReload hooks installed >>= \result -> either (const (pure ())) probe result >> pure result
    probe profiles
    withServingStore installed $ \store -> do
      bindings <- forM legacy $ \(root, profile) ->
        try @CommandFailure (History.bindLegacyHistory store root profile) >>= either (const (throwIO InvalidConfiguration)) pure
      Service.withService store bindings $ \service -> do
        (application, closing) <- Application.newApplication https service
        let listen = Transport.runHttps https limits (serveListening hooks (listenerUrl https)) closing application
        case configurationAdministrationRoot configuration of
          Nothing -> listen
          Just _ -> withLocalAdministration store (AdministrationHooks
            { hookFacts = Service.lifetimeFacts service,
              hookWake = Service.wakeAdmission service, hookReload = Just reload, hookDrain = Just (Service.drain service),
              hookShutdown = Just (serveStop hooks) }) listen
