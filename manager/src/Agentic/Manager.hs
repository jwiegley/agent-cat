{-# LANGUAGE TypeApplications #-}

-- | Trusted profile authority and storage boundaries for runtime coordination.
module Agentic.Manager
  ( module Agentic.Manager.Profile,
    module Agentic.Manager.Root,
    Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, withServingStore, storeIdentity, checkpointStore, backupCoordinationStore, restoreCoordinationStore,
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
import qualified Agentic.Manager.History as History
import Agentic.Manager.Protocol.Command (CommandFailure)
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.Transport as Transport
import Control.Exception (bracket, throwIO, try)
import Control.Monad (forM, forM_, void)
import Data.Text (Text)

-- | One foreground listener within the original configuration and Store
-- lifetimes. Each legacy binding names a configured local retention root and
-- a configured profile. It is bound through 'History.bindLegacyHistory'
-- before the service starts, and a binding that fails refuses the start with
-- 'InvalidConfiguration'.
serveManager :: Configuration -> [(FilePath, Text)] -> IO ()
serveManager configuration legacy = do
  https <- maybe (throwIO InvalidConfiguration) pure (configurationHttps configuration)
  bracket (installConfiguration configuration >>= either throwIO pure) closeConfiguration $ \installed -> do
    (limits, profiles) <- configurationSnapshot installed >>= either throwIO pure
    forM_ profiles $ \profile ->
      void (probeConfiguredProfile installed (publicId profile) (publicRevision profile))
    withServingStore installed $ \store -> do
      bindings <- forM legacy $ \(root, profile) ->
        try @CommandFailure (History.bindLegacyHistory store root profile) >>= either (const (throwIO InvalidConfiguration)) pure
      Service.withService store bindings $ \service -> do
        (application, closing) <- Application.newApplication https service
        let listen = Transport.runHttps https limits closing application
        case configurationAdministrationRoot configuration of
          Nothing -> listen
          Just _ -> withLocalAdministration store listen
