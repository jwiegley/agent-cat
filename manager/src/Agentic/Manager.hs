-- | Trusted profile authority and storage boundaries for runtime coordination.
module Agentic.Manager
  ( module Agentic.Manager.Profile,
    module Agentic.Manager.Root,
    Configuration, TargetValidator, InstalledConfiguration,
    loadConfiguration, installConfiguration, reloadConfiguration, closeConfiguration,
    configurationSnapshot, selectConfiguredProfile, probeConfiguredProfile,
    CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, storeIdentity, checkpointStore,
  ) where

import Agentic.Manager.Profile
import Agentic.Manager.Configuration
import Agentic.Manager.Root

import Agentic.Manager.Store
