-- | Pure refresh coordination for one client session: per-resource
-- serialization with dirty coalescing and generation fencing, the bounded
-- reconnection backoff, and the reconciliation rule of an uncertain command.
-- Nothing here performs I/O. The functions return the next state and the
-- actions that the caller performs, and no action is a send.
module Agentic.Manager.Client.Refresh
  ( FetchGeneration (..), Flight (..), Refresh, refreshGeneration, refreshFlights, newRefresh,
    RefreshAction (..), invalidateResource, completeFetch, advanceGeneration,
    reconnectBackoffMaxSeconds, Backoff, backoffSeconds, initialBackoff, reconnectDelay, jitteredMicroseconds,
    Uncertain (..), ReconcileRead (..), reconcileRead, ReconcileObservation (..), Reconciled (..), reconcile
  ) where

import Agentic.Manager.Client.Failure (ClientFailure)
import Agentic.Manager.Protocol.Command (CommandState (..))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Numeric.Natural (Natural)

-- | The generation of a fetch. A resnapshot or an endpoint switch advances
-- the current generation, and only a fetch of the current generation installs.
newtype FetchGeneration = FetchGeneration Natural
  deriving (Eq, Ord, Show)

-- | The one fetch in flight for a resource: its generation, and whether an
-- invalidation arrived after it started.
data Flight = Flight {flightGeneration :: !FetchGeneration, flightDirty :: !Bool}
  deriving (Eq, Show)

-- | The current generation and the fetch in flight for each resource key.
-- A key without a flight is idle.
data Refresh key = Refresh {refreshGeneration :: !FetchGeneration, refreshFlights :: !(Map.Map key Flight)}
  deriving (Eq, Show)

-- | Generation zero with every resource idle.
newRefresh :: Refresh key
newRefresh = Refresh (FetchGeneration 0) Map.empty

-- | What the caller does. 'StartFetch' starts one fetch of the resource for
-- the generation. 'InstallFetch' installs the result of the completed fetch,
-- a value or a refusal. 'DiscardFetch' drops the result of the completed
-- fetch without installing it.
data RefreshAction key
  = StartFetch !key !FetchGeneration
  | InstallFetch !key !FetchGeneration
  | DiscardFetch !key !FetchGeneration
  deriving (Eq, Show)

-- | An invalidation of the resource. An idle resource starts a fetch of the
-- current generation. A resource with a fetch in flight only becomes dirty,
-- so any number of invalidations during one fetch give one later fetch.
invalidateResource :: Ord key => key -> Refresh key -> (Refresh key, [RefreshAction key])
invalidateResource key state@(Refresh generation flights) = case Map.lookup key flights of
  Just flight -> (state {refreshFlights = Map.insert key flight {flightDirty = True} flights}, [])
  Nothing -> (state {refreshFlights = Map.insert key (Flight generation False) flights}, [StartFetch key generation])

-- | The completion of a fetch of the resource for the generation. Only the
-- fetch in flight of the current generation installs. When that resource is
-- dirty, exactly one further fetch starts, and otherwise the resource
-- becomes idle. Every other completion, in particular one of an earlier
-- generation, is discarded and changes nothing.
completeFetch :: Ord key => key -> FetchGeneration -> Refresh key -> (Refresh key, [RefreshAction key])
completeFetch key generation state@(Refresh current flights) = case Map.lookup key flights of
  Just (Flight started dirty) | generation == current && started == current ->
    if dirty
      then (state {refreshFlights = Map.insert key (Flight current False) flights},
            [InstallFetch key generation, StartFetch key current])
      else (state {refreshFlights = Map.delete key flights}, [InstallFetch key generation])
  _ -> (state, [DiscardFetch key generation])

-- | A resnapshot, after a 410 refusal or a new overview, or an endpoint
-- switch. The generation advances and every resource becomes idle, so each
-- fetch still in flight is discarded when it completes.
advanceGeneration :: Refresh key -> Refresh key
advanceGeneration (Refresh (FetchGeneration number) _) = Refresh (FetchGeneration (number + 1)) Map.empty

-- | The @reconnectBackoffMaxSeconds@ limit of @/capabilities@.
reconnectBackoffMaxSeconds :: Int
reconnectBackoffMaxSeconds = 30

-- | The delay in seconds before the next reconnection.
newtype Backoff = Backoff Int
  deriving (Eq, Show)

backoffSeconds :: Backoff -> Int
backoffSeconds (Backoff seconds) = seconds

-- | One second. A connection that delivered an event resets to it.
initialBackoff :: Backoff
initialBackoff = Backoff 1

-- | The delay in seconds before a reconnection, and the backoff after it.
-- The delay doubles from one second up to 'reconnectBackoffMaxSeconds' and
-- then stays there.
reconnectDelay :: Backoff -> (Int, Backoff)
reconnectDelay (Backoff seconds) = (seconds, Backoff (min reconnectBackoffMaxSeconds (2 * seconds)))

-- | The jittered wait in microseconds for a delay in seconds and a fraction
-- from zero to one. The wait is between half the delay and the whole delay,
-- so it never passes 'reconnectBackoffMaxSeconds'. A fraction outside that
-- range is clamped.
jitteredMicroseconds :: Int -> Double -> Int
jitteredMicroseconds seconds fraction =
  floor (fromIntegral seconds * 1000000 * (0.5 + 0.5 * max 0 (min 1 fraction)) :: Double)

-- | A sent command whose outcome is uncertain. It keeps its exact pending
-- command, with its bytes, key and precondition, the target resource, the
-- precondition entity tag, and the receipt location when an earlier
-- response gave one.
data Uncertain command location = Uncertain
  { uncertainCommand :: !command,
    uncertainTarget :: !location,
    uncertainPrecondition :: !(Maybe Text),
    uncertainReceipt :: !(Maybe location) }
  deriving (Eq, Show)

-- | The one read of a reconciliation.
data ReconcileRead location = ReadReceipt !location | ReadTarget !location
  deriving (Eq, Show)

-- | The receipt location when one is known, or else the target resource.
reconcileRead :: Uncertain command location -> ReconcileRead location
reconcileRead uncertain = maybe (ReadTarget (uncertainTarget uncertain)) ReadReceipt (uncertainReceipt uncertain)

-- | The result of the reconciliation read. 'ObservedReceipt' is the state of
-- the receipt that the receipt location gives. 'ObservedTarget' is the entity
-- tag of the target resource and whether the caller sees the effect of the
-- command in it. 'ObservedFailure' is a refused or failed read.
data ReconcileObservation
  = ObservedReceipt !CommandState
  | ObservedTarget !Text !Bool
  | ObservedFailure !ClientFailure
  deriving (Eq, Show)

-- | The report of a reconciliation. A command that stays uncertain is
-- returned unchanged, so its exact bytes, key and precondition remain for an
-- explicit exact resend. No report carries a send.
data Reconciled command location
  = ReconciledEffect
  | ReconciledRefused
  | ReconciledUncertain !(Uncertain command location)
  deriving (Eq, Show)

-- | Reconcile an uncertain command with the result of 'reconcileRead'. With
-- a receipt location, only the receipt decides: @effect-observed@ observes
-- the effect, @refused@ reports the refusal, and every other state stays
-- uncertain. Without one, the target observes the effect only when the
-- caller sees the effect and the entity tag differs from the precondition.
-- A failed read and an observation of the other read stay uncertain.
reconcile :: Uncertain command location -> ReconcileObservation -> Reconciled command location
reconcile uncertain observation = case (uncertainReceipt uncertain, observation) of
  (Just _, ObservedReceipt EffectObserved) -> ReconciledEffect
  (Just _, ObservedReceipt Refused) -> ReconciledRefused
  (Nothing, ObservedTarget etag True) | Just etag /= uncertainPrecondition uncertain -> ReconciledEffect
  _ -> ReconciledUncertain uncertain
