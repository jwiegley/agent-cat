{-# LANGUAGE TypeApplications #-}

-- | Trusted profile authority and storage boundaries for runtime coordination.
module Agentic.Manager
  ( module Agentic.Manager.Profile,
    module Agentic.Manager.Root,
    Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration, validateConfigurationProfiles,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, withServingStore, storeIdentity, checkpointStore, backupCoordinationStore, restoreCoordinationStore,
    LocalAdminRequest, decodeLocalAdminRequest, administerCredentials, withLocalAdministration, ServeHooks (..), serveManager,
  ) where

import Agentic.Manager.Profile
import Agentic.Manager.Configuration
import Agentic.Manager.Root

import Agentic.Manager.Store
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.LocalAdmin (withLocalAdministration)
import Agentic.Manager.Protocol.LocalAdmin (LocalAdminRequest, decodeLocalAdminRequest)
import qualified Agentic.Manager.Application as Application
import qualified Agentic.Manager.History as History
import Agentic.Manager.Protocol.Command (CommandFailure)
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.Transport as Transport
import Control.Exception (bracket, throwIO, try)
import Control.Monad (forM, void)
import Data.Text (Text)

-- | The actions that the composition of a serving manager supplies.
-- 'serveReload' loads the configuration file of the manager again and
-- installs it with 'reloadConfiguration' on the given installation.
newtype ServeHooks = ServeHooks
  { serveReload :: InstalledConfiguration -> IO (Either Diagnostic [PublicProfile]) }

-- | One foreground listener within the original configuration and Store
-- lifetimes. Each legacy binding names a configured local retention root and
-- a configured profile. It is bound through 'History.bindLegacyHistory'
-- before the service starts, and a binding that fails refuses the start with
-- 'InvalidConfiguration'. With an administration root, the local
-- administration channel serves @reload-profiles@ with 'serveReload'. After a
-- successful reload, each installed profile is probed, as at the start.
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
        let listen = Transport.runHttps https limits closing application
        case configurationAdministrationRoot configuration of
          Nothing -> listen
          Just _ -> withLocalAdministration store (Service.wakeAdmission service) reload listen
