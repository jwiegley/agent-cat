-- | Trusted profile authority and storage boundaries for runtime coordination.
module Agentic.Manager
  ( module Agentic.Manager.Profile,
    module Agentic.Manager.Root,
    Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, storeIdentity, checkpointStore, backupCoordinationStore, restoreCoordinationStore,
    LocalAdminRequest, decodeLocalAdminRequest, administerCredentials, withLocalAdministration, serveManager,
  ) where

import Agentic.Manager.Profile
import Agentic.Manager.Configuration
import Agentic.Manager.Root

import Agentic.Manager.Store
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.LocalAdmin (withLocalAdministration)
import Agentic.Manager.Protocol.LocalAdmin (LocalAdminRequest, decodeLocalAdminRequest)
import qualified Agentic.Manager.Application as Application
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.Transport as Transport
import Control.Exception (bracket, throwIO)
import Control.Monad (forM_, void)

-- | One foreground listener within the original configuration and Store lifetimes.
serveManager :: Configuration -> IO ()
serveManager configuration = do
  https <- maybe (throwIO InvalidConfiguration) pure (configurationHttps configuration)
  bracket (installConfiguration configuration >>= either throwIO pure) closeConfiguration $ \installed -> do
    (limits, profiles) <- configurationSnapshot installed >>= either throwIO pure
    forM_ profiles $ \profile ->
      void (probeConfiguredProfile installed (publicId profile) (publicRevision profile))
    withCoordinationStore installed $ \store ->
      Service.withService store $ \service -> do
        application <- Application.newApplication https service
        let listen = Transport.runHttps https limits application
        case configurationAdministrationRoot configuration of
          Nothing -> listen
          Just _ -> withLocalAdministration store listen
