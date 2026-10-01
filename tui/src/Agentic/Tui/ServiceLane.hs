{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Classification of manager-client calls and the service command lane.
--
-- A call either returns a declared 'C.ClientFailure' or value, or it fails
-- with an internal frontend fault. A declared failure keeps its declared
-- meaning, whether the call returned it or threw it. Any other synchronous
-- exception is an internal fault. A fault carries no exception text, and it
-- never becomes the transport uncertainty that offers an exact resend.
-- Asynchronous exceptions propagate unchanged.
--
-- The 'Lane' holds the read ticket, the one command lane, the internal-fault
-- flag and the resend confirmation. The completion of every read,
-- preparation and send is a pure transition of the lane. Observations are not
-- lane facts, so no lane transition can change them. The lane values are
-- polymorphic in the pending command and receipt location. The lane only
-- retains them. It never inspects, rebuilds or retargets them.
--
-- The read lane is single-flight. A read ticket records whether the read in
-- flight reads a page set or only single resources. The completion of the
-- composite read of the selected request is also a pure transition of the
-- 'Installed' observation: 'requestStep' installs a complete current read in
-- one step, and a declared refusal keeps the last complete observation and
-- marks it stale with the refusal code.
--
-- Every mutation key has exactly one visible outcome, which
-- 'mutationKeyOutcome' and 'resendAdmission' decide: a start, a refusal or a
-- deferral. A key whose operation needs a scope that the credential lacks is
-- refused first. 'mutationAdmission' then decides from the lane. A key never cancels a page-set read, because an
-- abandoned page set holds a manager slot until it expires. It defers
-- instead, and a deferred key is never replayed. A key during a
-- single-resource read ends and cancels that read and starts. A refusal or a
-- deferral is a numbered 'KeyOutcome', and 'retainKeyOutcome' keeps it on
-- the status line until the next key press or until the view changes. A
-- deferral pauses automatic refresh ('refreshPaused'). The pause ends when the
-- deferring page-set read completes or 'refreshPauseLimit' after the key
-- outcome, whichever comes first.
--
-- The verified result of a run is retrieved through the same lane. Only
-- retrieved verified bytes are retained, by run identifier ('Retrievals'). A refusal or a
-- retrieval without a verified result is a retryable failure: an automatic
-- refresh retries it after the next installed composite read, and an
-- explicit refresh retries it at once ('retrievalDue').
--
-- The service frontend holds 1 to 8 explicitly supplied client profiles
-- ('Endpoints'). Exactly one session is active. A switch connects the other
-- profile first ('beginSwitch'), and only a successful connection replaces
-- the active session ('switchStep'). That replacement advances the
-- generation of the refresh coordinator of the session, and every worker
-- result carries the generation of the session that started the worker
-- ('Stamped'), so no result of an earlier session is admitted
-- ('admitStamped'). The command that a switch leaves unresolved stays listed
-- for its own profile, and no later session sends it. A failed connection
-- keeps the active session and records its fixed reason.
--
-- Live delivery keeps four reads current: the manager overview, the
-- composite read of the selected request, the pending decision heads of
-- the manager decisions and the shown read of the History view ('FetchKey'). The event worker of
-- the session records each invalidated resource in a bounded set
-- ('Invalidated') and wakes the frontend once. 'invalidatedFetches' routes
-- the set to the reads that read an invalidated resource, and the refresh
-- coordinator of the session decides each fetch: one fetch in flight for
-- each read, and one later fetch when invalidations arrive during it.
-- 'Fetches' holds the fetches that wait for the read lane and the fetch that
-- holds the read ticket. A fetch runs through the single-flight read lane
-- like any other read, so the mutation deferral rule is unchanged. While the
-- stream is live, the timer refresh of the selected request is only a
-- safety read ('safetyReadDue').
module Agentic.Tui.ServiceLane
  ( CallOutcome (..),
    serviceCall,
    declaredCall,
    Attempt (..),
    Uncertainty (..),
    MutationState (..),
    ReadKind (..),
    ReadTicket (..),
    Lane (..),
    faultLane,
    settleUncertain,
    declaredSendUncertain,
    startRead,
    beginMutation,
    ReadStep (..),
    readStep,
    Installed (..),
    noObservation,
    RequestStep (..),
    requestStep,
    refusalCode,
    staleStatus,
    KeyAdmission (..),
    mutationAdmission,
    ResendAdmission (..),
    resendAdmission,
    admissionText,
    scopeText,
    mutationKeyOutcome,
    startupFailureText,
    connectionFailureText,
    EndpointState (..),
    EndpointSlot (..),
    Endpoints (..),
    newEndpoints,
    endpointsGeneration,
    activeIdentity,
    SessionGeneration (..),
    Stamped (..),
    admitStamped,
    moveEndpoint,
    SwitchStart (..),
    beginSwitch,
    SwitchStep (..),
    switchStep,
    sessionLane,
    unresolvedCommands,
    resendDeferredText,
    resendUnofferedText,
    keyHelpText,
    unobservedText,
    Confirmation (..),
    confirmationOperation,
    confirmationLines,
    confirmCancelledText,
    confirmChangedText,
    KeyOutcome (..),
    Deferral (..),
    deferral,
    keyOutcomeLine,
    retainKeyOutcome,
    refreshPauseLimit,
    refreshPaused,
    RefreshCause (..),
    Retrievals,
    noRetrievals,
    retrievalsBound,
    RetrievalState (..),
    retrievalOf,
    retrievalRuns,
    retrievalDue,
    retrievalStep,
    retrievalObserved,
    retrievedResult,
    retrievalShown,
    retrievalStatus,
    PrepareStep (..),
    prepareStep,
    SendStep (..),
    sendStep,
    mutationAllowed,
    resendAttempt,
    resendOffered,
    mutationNotice,
    internalFaultStatus,
    unresolvedNotice,
    faultScreen,
    shutdownNotices,
    FetchKey (..),
    Delivery (..),
    deliveryText,
    disconnected,
    Follow (..),
    newFollow,
    streamFailureLimit,
    pollIntervalSeconds,
    StreamEnd (..),
    FollowStep (..),
    afterStream,
    PollStep (..),
    afterPoll,
    overviewStartsStream,
    Invalidated (..),
    noInvalidations,
    invalidatedBound,
    noteInvalidation,
    invalidatedFetches,
    Fetches (..),
    noFetches,
    invalidateFetches,
    takeFetch,
    fetchStarted,
    fetchSkipped,
    fetchCompleted,
    fetchAbandoned,
    resnapshotFetches,
    OverviewRetry (..),
    overviewRefused,
    overviewRetryDue,
    overviewRetryStarted,
    safetyReadInterval,
    safetyReadDue,
    RowFocus (..),
    noFocus,
    focusedIndex,
    moveFocus,
    DraftKey (..),
    Drafts,
    noDrafts,
    draftsBound,
    draftText,
    draftKeys,
    recordDraft,
    dropDraft,
    showDraft,
    keepDraft,
    draftKeptText,
  )
where

import qualified Agentic.Manager.Client as C
import Agentic.Tui.Service (Endpoint, Mutation, ReadVerdict (..), missingScope, mutationOperation, mutationURI)
import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, throwIO, try)
import Data.List (elemIndex, findIndex, minimumBy)
import Data.Ord (comparing)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Numeric.Natural (Natural)

-- | The outcome of one call into the manager client facade.
data CallOutcome a
  = -- | The call returned a declared failure or a value.
    Declared !(Either C.ClientFailure a)
  | -- | The call failed with an undeclared synchronous exception.
    InternalFault
  deriving (Eq, Show)

-- | Run one client call and classify its outcome.
--
-- The returned 'Either' and its immediate payload are evaluated inside the
-- classification, so an undeclared failure in that evaluation is a fault.
serviceCall :: IO (Either C.ClientFailure a) -> IO (CallOutcome a)
serviceCall action = do
  outcome <- try @SomeException $ do
    result <- declaredCall action >>= evaluate
    either (fmap Left . evaluate) (fmap Right . evaluate) result
  case outcome of
    Right result -> pure (Declared result)
    Left failure
      | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
      | otherwise -> pure InternalFault

-- | Return a thrown declared 'C.ClientFailure' as a value.
--
-- Every other exception propagates, so an enclosing 'serviceCall' classifies
-- it.
declaredCall :: IO (Either C.ClientFailure a) -> IO (Either C.ClientFailure a)
declaredCall action = either Left id <$> try @C.ClientFailure action

-- | One original attempt: the intent, its immutable pending command and the
-- receipt location that an earlier attempt of the same command returned.
data Attempt pending location = Attempt
  { attemptMutation :: !Mutation,
    attemptPending :: !pending,
    attemptLocation :: !(Maybe location)
  }

-- | Why the outcome of a sent attempt is unresolved.
data Uncertainty
  = -- | A declared failure or response with this fixed public description.
    DeclaredUncertainty !Text
  | -- | An internal frontend fault interrupted the send.
    FaultUncertainty
  deriving (Eq, Show)

-- | The one command lane. Each attempted mutation retains its original
-- pending command.
data MutationState pending location
  = MutationIdle
  | MutationPreparing !Int !Mutation
  | MutationSending !Int !(Attempt pending location)
  | MutationAwaiting !Mutation !pending !location
  | MutationUncertain !(Attempt pending location) !Uncertainty

-- | What the read in flight reads.
data ReadKind
  = -- | Only single resources: the request, its preparation and a receipt.
    SingleResourceRead
  | -- | At least one page set: the profiles, the workflows, the manager
    -- overview, or the composite read of an associated request with its
    -- snapshot page set.
    PageSetRead
  deriving (Eq, Show, Enum, Bounded)

-- | The ticket of the one read in flight and what that read reads.
data ReadTicket = ReadTicket {ticketNumber :: !Int, ticketKind :: !ReadKind}
  deriving (Eq, Show)

-- | The lane-owned facts of one service session: the read ticket, the one
-- command lane, whether an internal fault occurred in this session, and
-- whether an exact resend awaits confirmation. Observations, approvals and
-- receipts are not lane facts, so no lane transition can change them.
data Lane pending location = Lane
  { laneReadTicket :: !(Maybe ReadTicket),
    laneMutation :: !(MutationState pending location),
    laneFault :: !Bool,
    laneResendConfirm :: !Bool
  }

-- | Record an internal fault. The command lane stays as it is. The read
-- ticket and any resend confirmation end.
faultLane :: Lane pending location -> Lane pending location
faultLane lane = lane {laneReadTicket = Nothing, laneFault = True, laneResendConfirm = False}

-- | Leave an attempt unresolved. The read ticket and any resend confirmation
-- end.
settleUncertain :: Attempt pending location -> Uncertainty -> Lane pending location -> Lane pending location
settleUncertain attempt cause lane =
  lane {laneMutation = MutationUncertain attempt cause, laneReadTicket = Nothing, laneResendConfirm = False}

-- | Leave a sent attempt unresolved after a declared send failure or an
-- invalid response. The retained attempt keeps its pending command but no
-- earlier receipt location.
declaredSendUncertain :: Attempt pending location -> Text -> Lane pending location -> Lane pending location
declaredSendUncertain attempt failure =
  settleUncertain attempt {attemptLocation = Nothing} (DeclaredUncertainty failure)

-- | Start a read with this ticket number and kind. No read starts while
-- another read holds the ticket, so at most one read is ever in flight.
startRead :: Int -> ReadKind -> Lane pending location -> Maybe (Lane pending location)
startRead ticket kind lane = case laneReadTicket lane of
  Just _ -> Nothing
  Nothing -> Just lane {laneReadTicket = Just (ReadTicket ticket kind)}

-- | Begin preparing a mutation that 'mutationAdmission' started. The read
-- ticket ends, and the caller cancels that single-resource read, so it
-- delivers nothing afterwards. Any resend confirmation ends.
beginMutation :: Int -> Mutation -> Lane pending location -> Lane pending location
beginMutation ticket mutation lane =
  lane {laneReadTicket = Nothing, laneMutation = MutationPreparing ticket mutation, laneResendConfirm = False}

-- | The meaning of one completed read for the read lane.
data ReadStep a
  = -- | The read no longer owns the lane. The lane is unchanged.
    ReadStale
  | -- | The read ticket ends and the manager refusal is shown.
    ReadRefused !C.ClientFailure
  | -- | The read failed with an internal fault. It delivers no observation.
    -- The lane records the fault and keeps its command state.
    ReadFaulted
  | -- | The read ticket ends and the observation is installed.
    ReadDelivered !a

-- | Complete the read that holds the given ticket.
readStep :: Int -> CallOutcome a -> Lane pending location -> (ReadStep a, Lane pending location)
readStep ticket outcome lane
  | fmap ticketNumber (laneReadTicket lane) /= Just ticket = (ReadStale, lane)
  | otherwise = case outcome of
      InternalFault -> (ReadFaulted, faultLane lane)
      Declared (Left failure) -> (ReadRefused failure, lane {laneReadTicket = Nothing})
      Declared (Right value) -> (ReadDelivered value, lane {laneReadTicket = Nothing})

-- | The installed observation of the selected request: the last complete
-- read that was installed, and the refusal code of the latest read when that
-- read was refused.
data Installed a = Installed
  { installedRead :: !(Maybe a),
    installedStale :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | No installed observation, as for a newly selected request.
noObservation :: Installed a
noObservation = Installed Nothing Nothing

-- | The meaning of one completed composite read of the selected request.
data RequestStep a
  = -- | The read no longer owns the lane, or it concerns another request.
    -- Nothing is installed.
    RequestStale
  | -- | The read failed with an internal fault. Nothing is installed.
    RequestFaulted
  | -- | The manager refused the read, a component was invalid, or the
    -- request named another run than the selected one. Nothing is installed.
    -- The last complete observation stays and is marked stale.
    RequestRefused !C.ClientFailure
  | -- | The complete current read is installed in one step.
    RequestInstalled !a

-- | Complete the composite read that holds the given ticket, given the
-- verdict of a delivered read against the current selection. The lane
-- changes as 'readStep' states, so a refusal leaves the command lane
-- unchanged. Only a current read replaces the installed observation, and it
-- clears the stale mark. A refusal keeps the installed read and marks it
-- stale.
requestStep ::
  (a -> ReadVerdict) ->
  Int ->
  CallOutcome a ->
  Lane pending location ->
  Installed a ->
  (RequestStep a, Lane pending location, Installed a)
requestStep verdict ticket outcome lane installed = case readStep ticket outcome lane of
  (ReadStale, next) -> (RequestStale, next, installed)
  (ReadFaulted, next) -> (RequestFaulted, next, installed)
  (ReadRefused failure, next) -> refused failure next
  (ReadDelivered value, next) -> case verdict value of
    ReadForeign -> (RequestStale, next, installed)
    ReadInvalid -> refused C.InvalidResponse next
    ReadCurrent -> (RequestInstalled value, next, Installed (Just value) Nothing)
  where
    refused failure next = (RequestRefused failure, next, installed {installedStale = Just (refusalCode failure)})

-- | The public code of a declared failure: the status and problem code of a
-- manager refusal, or the name of a client failure.
refusalCode :: C.ClientFailure -> Text
refusalCode failure = case failure of
  C.Refused status code -> T.pack (show status) <> " " <> code
  _ -> T.pack (show failure)

-- | The status line after a refused request read, given the refusal code
-- and whether a complete observation is installed.
staleStatus :: Text -> Bool -> Text
staleStatus code retained
  | retained = "observation stale: " <> code <> "; the last complete observation is retained"
  | otherwise = "observation refused: " <> code <> "; no complete observation is installed"

-- | The meaning of one completed preparation for the command lane.
data PrepareStep pending location
  = PrepareStale
  | -- | The manager refused before any send. The lane becomes idle.
    PrepareRefused !C.ClientFailure
  | -- | An internal fault stopped the preparation. Nothing was sent, no
    -- uncertainty exists, and the lane becomes idle and records the fault.
    PrepareFaulted
  | -- | Send exactly this new attempt once.
    PrepareSend !(Attempt pending location)

-- | Complete the preparation that holds the given ticket.
prepareStep :: Int -> CallOutcome pending -> Lane pending location -> (PrepareStep pending location, Lane pending location)
prepareStep ticket outcome lane = case laneMutation lane of
  MutationPreparing expected mutation | ticket == expected -> case outcome of
    InternalFault -> (PrepareFaulted, faultLane lane {laneMutation = MutationIdle})
    Declared (Left failure) -> (PrepareRefused failure, lane {laneMutation = MutationIdle})
    Declared (Right pending) -> (PrepareSend (Attempt mutation pending Nothing), lane)
  _ -> (PrepareStale, lane)

-- | The meaning of one completed send for the command lane.
data SendStep pending location response
  = SendStale
  | -- | An internal fault interrupted the send. The lane retains the original
    -- attempt, including any earlier receipt location, as unresolved.
    SendFaulted
  | -- | A declared failure left the original attempt unresolved.
    SendUncertain
  | -- | The manager refused the attempt with 412 @stale-revision@. The
    -- manager recognizes a matching retry of a durable command before it
    -- evaluates the precondition, so this refusal proves that no command
    -- exists under the key of the attempt. The lane becomes idle, nothing is
    -- retained for a resend, and nothing is sent again.
    SendRefused !(Attempt pending location) !C.ClientFailure
  | SendDelivered !(Attempt pending location) !response

-- | Complete the send that holds the given ticket.
sendStep :: Int -> CallOutcome response -> Lane pending location -> (SendStep pending location response, Lane pending location)
sendStep ticket outcome lane = case laneMutation lane of
  MutationSending expected attempt | ticket == expected -> case outcome of
    InternalFault -> (SendFaulted, faultLane (settleUncertain attempt FaultUncertainty lane))
    Declared (Left failure@(C.Refused 412 "stale-revision")) ->
      (SendRefused attempt failure, lane {laneMutation = MutationIdle, laneResendConfirm = False})
    Declared (Left failure) -> (SendUncertain, declaredSendUncertain attempt (T.pack (show failure)) lane)
    Declared (Right response) -> (SendDelivered attempt response, lane)
  _ -> (SendStale, lane)

-- | Whether a new mutation may start. No mutation starts after an internal
-- fault.
mutationAllowed :: Lane pending location -> Bool
mutationAllowed lane = case laneMutation lane of
  MutationIdle -> not (laneFault lane)
  _ -> False

-- | The one visible outcome of a key that asks for a new mutation.
data KeyAdmission
  = -- | Start now. A single-resource read in flight ends and is cancelled.
    KeyStart
  | -- | Nothing starts while a page-set read is in flight. The key is not
    -- replayed later.
    KeyDeferred
  | -- | Nothing starts while a command is in progress or unresolved.
    KeyBusy
  | -- | Nothing starts after an internal fault.
    KeyFaulted
  deriving (Eq, Show, Enum, Bounded)

-- | Decide a key that asks for a new mutation. The command lane decides
-- first, then the fault flag, then the read in flight.
mutationAdmission :: Lane pending location -> KeyAdmission
mutationAdmission lane = case laneMutation lane of
  MutationIdle
    | laneFault lane -> KeyFaulted
    | pageSetRead lane -> KeyDeferred
    | otherwise -> KeyStart
  _ -> KeyBusy

-- | The one visible outcome of the key that confirms an exact resend.
data ResendAdmission pending location
  = -- | Send this retained attempt again now. A single-resource read in
    -- flight ends and is cancelled.
    ResendStart !(Attempt pending location)
  | -- | Nothing is sent while a page-set read is in flight. The confirmation
    -- stays open, and the key is not replayed later.
    ResendDeferred
  | -- | No exact resend is offered.
    ResendUnoffered

-- | Decide the key that confirms an exact resend.
resendAdmission :: Lane pending location -> ResendAdmission pending location
resendAdmission lane = case resendAttempt lane of
  Nothing -> ResendUnoffered
  Just attempt
    | pageSetRead lane -> ResendDeferred
    | otherwise -> ResendStart attempt

pageSetRead :: Lane pending location -> Bool
pageSetRead lane = fmap ticketKind (laneReadTicket lane) == Just PageSetRead

-- | The fixed text of a key outcome that starts nothing, given the operation
-- that the key asks for. Every such text fits an 80-column status line with
-- its key number.
admissionText :: Text -> KeyAdmission -> Maybe Text
admissionText operation admission = case admission of
  KeyStart -> Nothing
  KeyDeferred -> Just (operation <> " deferred during a page-set read. Press the key again.")
  KeyBusy -> Just (operation <> " did not start: a command is in progress or unresolved.")
  KeyFaulted -> Just (operation <> " did not start: an internal fault stopped all mutations.")

-- | The fixed text of a key that asks for an operation whose scope the
-- credential lacks, given the operation and the first missing scope.
scopeText :: Text -> Text -> Text
scopeText operation scope = operation <> " did not start: this credential lacks " <> scope <> "."

-- | The visible outcome of a key that asks for a new mutation, given the
-- scopes of the credential, the operation and the lane: 'Nothing' for a
-- start, or the fixed text of a key outcome that starts nothing and whether
-- it is a deferral. A missing scope decides first, so such a key never starts
-- a preparation or a send, and it never defers.
mutationKeyOutcome :: [Text] -> Text -> Lane pending location -> Maybe (Text, Bool)
mutationKeyOutcome scopes operation lane = case missingScope scopes operation of
  Just scope -> Just (scopeText operation scope, False)
  Nothing -> (\text -> (text, admission == KeyDeferred)) <$> admissionText operation admission
  where
    admission = mutationAdmission lane

-- | The one fixed line that the service frontend prints for a declared
-- failure of its connection at startup, before it exits with status 1.
startupFailureText :: C.ClientFailure -> Text
startupFailureText failure = "--tui --service: " <> connectionFailureText failure

-- | The fixed reason of a declared connection failure. The startup line and
-- the Endpoints view both show it.
connectionFailureText :: C.ClientFailure -> Text
connectionFailureText failure = case failure of
  C.InvalidClientProfile -> "invalid client profile"
  C.ClientFileUnavailable -> "client profile, credential or CA file unavailable"
  C.InvalidEndpoint -> "invalid manager endpoint"
  C.WrongEndpoint -> "wrong manager endpoint"
  C.CredentialUnavailable -> "credential unavailable"
  C.CredentialChanged -> "credential changed during the connection"
  C.TransportUnavailable -> "manager unreachable"
  C.RedirectRefused -> "manager redirect refused"
  C.InvalidResponse -> "invalid manager response"
  C.ResponseTooLarge -> "manager response too large"
  C.UnsupportedVersion -> "manager API version unsupported"
  C.ClientClosed -> "client closed"
  C.Refused 401 _ -> "credential refused"
  C.Refused 403 "insufficient-scope" -> "credential lacks the observe scope"
  C.Refused status code -> "manager refused the connection: " <> T.pack (show status) <> " " <> code

-- | The connection state of one client profile.
data EndpointState
  = -- | No session of the profile is open. It was never connected, or a
    -- switch to another profile closed its session.
    EndpointIdle
  | -- | The connection with this ticket is in flight.
    EndpointConnecting !Int
  | -- | The session of the profile is the active session.
    EndpointActive
  | -- | The latest connection failed with this fixed reason.
    EndpointFailed !Text
  deriving (Eq, Show)

-- | One explicitly supplied client profile.
data EndpointSlot = EndpointSlot
  { slotProfile :: !FilePath,
    slotState :: !EndpointState,
    -- | The endpoint identity of the latest session of the profile.
    slotIdentity :: !(Maybe Endpoint),
    -- | The operation and URI of each command whose outcome was unresolved
    -- when a switch closed a session of the profile. No later session sends
    -- these commands.
    slotUnresolved :: ![Text]
  }
  deriving (Eq, Show)

-- | The client profiles of one service frontend in the given order, the
-- index of the active profile, the selection of the Endpoints view, the
-- generation of the active session and the refresh coordinator of that
-- session. The session generation fences every worker result, and a switch
-- advances it. The coordinator has a generation of its own, which fences the
-- fetches of live delivery. A switch and a resnapshot advance it, so a
-- resnapshot discards the fetches in flight without discarding the other
-- worker results of the session.
data Endpoints = Endpoints
  { endpointsSlots :: ![EndpointSlot],
    endpointsActive :: !Int,
    endpointsCursor :: !Int,
    endpointsSession :: !SessionGeneration,
    endpointsRefresh :: !(C.Refresh FetchKey)
  }
  deriving (Eq, Show)

-- | The generation of one session of the frontend. Each successful switch
-- opens a session of the next generation.
newtype SessionGeneration = SessionGeneration Natural
  deriving (Eq, Ord, Show)

-- | The profiles at startup: the connected first profile with its identity
-- and the other profiles without a session.
newEndpoints :: FilePath -> Endpoint -> [FilePath] -> Endpoints
newEndpoints first identity rest =
  Endpoints
    (EndpointSlot first EndpointActive (Just identity) [] : [EndpointSlot path EndpointIdle Nothing [] | path <- rest])
    0
    0
    (SessionGeneration 0)
    C.newRefresh

-- | The generation of the active session.
endpointsGeneration :: Endpoints -> SessionGeneration
endpointsGeneration = endpointsSession

-- | The endpoint identity of the active session.
activeIdentity :: Endpoints -> Maybe Endpoint
activeIdentity endpoints = case drop (endpointsActive endpoints) (endpointsSlots endpoints) of
  slot : _ -> slotIdentity slot
  [] -> Nothing

-- | One worker result with the generation of the session that started the
-- worker.
data Stamped a = Stamped !SessionGeneration !a

-- | The result when the session that started its worker is still the active
-- session. A result of an earlier session gives 'Nothing' and changes
-- nothing.
admitStamped :: Endpoints -> Stamped a -> Maybe a
admitStamped endpoints (Stamped generation value)
  | generation == endpointsGeneration endpoints = Just value
  | otherwise = Nothing

-- | Move the selection of the Endpoints view, within the profiles.
moveEndpoint :: Int -> Endpoints -> Endpoints
moveEndpoint delta endpoints =
  endpoints {endpointsCursor = max 0 (min (length (endpointsSlots endpoints) - 1) (endpointsCursor endpoints + delta))}

-- | The outcome of the key that selects the profile under the selection.
data SwitchStart
  = -- | Connect this profile in a worker.
    SwitchStart !FilePath
  | -- | Nothing starts, for this fixed reason.
    SwitchRefused !Text
  deriving (Eq, Show)

-- | Select the profile under the selection with this connection ticket. The
-- active profile and a second connection while one is in flight are
-- refused. The active session stays active until the connection succeeds.
beginSwitch :: Int -> Endpoints -> (SwitchStart, Endpoints)
beginSwitch ticket endpoints
  | any (connecting . slotState) slots = (SwitchRefused "endpoint switch did not start: a connection is in progress.", endpoints)
  | cursor == endpointsActive endpoints = (SwitchRefused ("endpoint " <> number cursor <> " is already active."), endpoints)
  | otherwise = case drop cursor slots of
      slot : _ -> (SwitchStart (slotProfile slot), replaceSlot cursor slot {slotState = EndpointConnecting ticket} endpoints)
      [] -> (SwitchRefused "endpoint switch did not start: no endpoint is selected.", endpoints)
  where
    slots = endpointsSlots endpoints
    cursor = endpointsCursor endpoints
    connecting state = case state of EndpointConnecting _ -> True; _ -> False

-- | The meaning of one completed connection.
data SwitchStep session
  = -- | No connection holds this ticket. A session that it opened is closed
    -- unused.
    SwitchStale !(Maybe session)
  | -- | The connection failed with this fixed reason. The active session
    -- continues unchanged.
    SwitchFailed !Text
  | -- | This session replaces the active session. The caller cancels the
    -- workers of the earlier session, closes it and clears every
    -- observation, selection, retained result and settled command.
    SwitchConnected !session
  deriving (Eq, Show)

-- | Complete the connection that holds this ticket, given the commands that
-- the active session leaves unresolved ('unresolvedCommands'). A success
-- makes the connected profile active, lists those commands for the earlier
-- profile and advances the generation, so no result of the earlier session
-- is admitted later.
switchStep :: Int -> CallOutcome (session, Endpoint) -> [Text] -> Endpoints -> (SwitchStep session, Endpoints)
switchStep ticket outcome unresolved endpoints =
  case findIndex ((== EndpointConnecting ticket) . slotState) slots of
    Nothing -> (SwitchStale (either (const Nothing) (Just . fst) declared), endpoints)
    Just index -> case declared of
      Right (session, identity) ->
        let earlier = endpointsActive endpoints
            update position slot
              | position == index = slot {slotState = EndpointActive, slotIdentity = Just identity}
              | position == earlier = slot {slotState = EndpointIdle, slotUnresolved = slotUnresolved slot <> unresolved}
              | otherwise = slot
         in ( SwitchConnected session,
              endpoints
                { endpointsSlots = zipWith update [0 ..] slots,
                  endpointsActive = index,
                  endpointsSession = let SessionGeneration previous = endpointsSession endpoints in SessionGeneration (previous + 1),
                  endpointsRefresh = C.advanceGeneration (endpointsRefresh endpoints)
                } )
      Left reason -> (SwitchFailed reason, replaceSlot index (slots !! index) {slotState = EndpointFailed reason} endpoints)
  where
    slots = endpointsSlots endpoints
    declared = case outcome of
      Declared (Right value) -> Right value
      Declared (Left failure) -> Left (connectionFailureText failure)
      InternalFault -> Left "internal frontend fault during the connection"

replaceSlot :: Int -> EndpointSlot -> Endpoints -> Endpoints
replaceSlot index slot endpoints =
  endpoints {endpointsSlots = [if position == index then slot else other | (position, other) <- zip [0 ..] (endpointsSlots endpoints)]}

number :: Int -> Text
number index = T.pack (show (index + 1))

-- | The lane of a new session: no read, an idle command lane, no fault and
-- no resend confirmation.
sessionLane :: Lane pending location
sessionLane = Lane Nothing MutationIdle False False

-- | The operation and URI of the command whose outcome is unresolved when
-- the session closes: an unresolved attempt, or a send in flight, whose
-- cancellation leaves its outcome unknown.
unresolvedCommands :: Lane pending location -> [Text]
unresolvedCommands lane = case laneMutation lane of
  MutationSending _ attempt -> [entry attempt]
  MutationUncertain attempt _ -> [entry attempt]
  _ -> []
  where
    entry attempt = mutationOperation (attemptMutation attempt) <> " " <> mutationURI (attemptMutation attempt)

-- | The fixed status text of a deferred resend confirmation.
resendDeferredText :: Text
resendDeferredText = "exact resend deferred during a page-set read. Press y again."

-- | The fixed status text of a resend confirmation without an offered resend.
resendUnofferedText :: Text
resendUnofferedText = "exact resend did not start: no exact resend is offered."

-- | The fixed status text of a mutation key under the key help.
keyHelpText :: Text -> Text
keyHelpText operation = operation <> " did not start: the key help is open. Esc closes it."

-- | The fixed status text of a mutation key whose request validator is not
-- yet observed.
unobservedText :: Text -> Text
unobservedText operation = operation <> " did not start: the request validator is not yet observed."

-- | A mutation that starts only after an explicit confirmation, with the
-- identifier of the resource that its key named: the withdrawal of a
-- request, the discard of the review of a preparation, and the cancel of a
-- run. The key opens the
-- confirmation only when 'mutationKeyOutcome' would start the mutation. The
-- confirming key decides again with 'mutationKeyOutcome', and the mutation
-- starts only for the resource that the key named.
data Confirmation
  = ConfirmWithdraw !Text
  | ConfirmDiscard !Text
  | ConfirmCancel !Text
  deriving (Eq, Show)

-- | The manager operation of a confirmation.
confirmationOperation :: Confirmation -> Text
confirmationOperation confirmation = case confirmation of
  ConfirmWithdraw _ -> "withdraw"
  ConfirmDiscard _ -> "discard"
  ConfirmCancel _ -> "cancel"

-- | The title and the lines of the dialog of a confirmation.
confirmationLines :: Confirmation -> (Text, [Text])
confirmationLines confirmation = case confirmation of
  ConfirmWithdraw ident ->
    ( " Confirm withdrawal ",
      [ "Withdraw request " <> ident <> "?",
        "The request moves to the withdrawn phase and cannot be prepared again.",
        "y WITHDRAW REQUEST   n BACK" ] )
  ConfirmDiscard ident ->
    ( " Confirm discard ",
      [ "Discard the review of preparation " <> ident <> "?",
        "The request returns to the draft phase, and Enter prepares a new review.",
        "y DISCARD REVIEW   n BACK" ] )
  ConfirmCancel ident ->
    ( " Confirm cancel ",
      [ "Cancel run " <> ident <> "?",
        "The manager asks the runtime to cancel the run. The run ends only when its runtime status is Cancelled.",
        "y CANCEL RUN   n BACK" ] )

-- | The fixed status text of a confirmation that n or Esc closed.
confirmCancelledText :: Text -> Text
confirmCancelledText operation = operation <> " was not sent: the confirmation was closed."

-- | The fixed status text of a confirmation whose resource is no longer the
-- displayed and installed one.
confirmChangedText :: Text -> Text
confirmChangedText operation = operation <> " did not start: the confirmed resource is no longer displayed."

-- | The visible outcome of one mutation-key press that started nothing: the
-- sequence number of the press among such presses of the session, its fixed
-- text, and the deferral when a page-set read in flight deferred the key.
data KeyOutcome = KeyOutcome
  { outcomeKey :: !Int,
    outcomeText :: !Text,
    outcomeDeferral :: !(Maybe Deferral)
  }
  deriving (Eq, Show)

-- | The page-set read that deferred a key, by its ticket number, and the
-- time of the key outcome.
data Deferral = Deferral
  { deferralTicket :: !Int,
    deferralAt :: !UTCTime
  }
  deriving (Eq, Show)

-- | The deferral of a key at this time, given the lane when the key arrived:
-- the page-set read in flight, if one holds the ticket.
deferral :: UTCTime -> Lane pending location -> Maybe Deferral
deferral now lane = case laneReadTicket lane of
  Just (ReadTicket ticket PageSetRead) -> Just (Deferral ticket now)
  _ -> Nothing

-- | The longest pause of automatic refresh after a deferred key, measured
-- from the key outcome.
refreshPauseLimit :: NominalDiffTime
refreshPauseLimit = 3

-- | Whether automatic refresh pauses at this time, given the lane and the key
-- outcome that remains. Only a deferral pauses refresh. The pause ends when
-- the deferring page-set read no longer holds the read ticket or
-- 'refreshPauseLimit' after the key outcome, whichever comes first. The next
-- key press or a view change ends the outcome, and with it the pause. An
-- explicit refresh key still reads.
refreshPaused :: UTCTime -> Lane pending location -> Maybe KeyOutcome -> Bool
refreshPaused now lane outcome = case outcome >>= outcomeDeferral of
  Nothing -> False
  Just (Deferral ticket at) ->
    fmap ticketNumber (laneReadTicket lane) == Just ticket && diffUTCTime now at < refreshPauseLimit

-- | What asked for a refresh: the one-second timer and the completion of a
-- command, or the explicit refresh key.
data RefreshCause = AutomaticRefresh | ExplicitRefresh
  deriving (Eq, Show, Enum, Bounded)

-- | The retrievals of the verified results of the session by run
-- identifier. Each run keeps its own retrieval state and its own retry rule
-- ('retrievalDue'). At most 'retrievalsBound' runs are kept. A new run
-- beyond that bound removes the run whose retrieval completed first, so the
-- retained bytes stay bounded. The counter orders the completions.
data Retrievals result = Retrievals !Int !(Map.Map Text (Int, RetrievalState result))
  deriving (Eq, Show)

-- | No retrieval, as for a new session.
noRetrievals :: Retrievals result
noRetrievals = Retrievals 0 Map.empty

-- | The largest number of runs whose retrievals the session keeps. With the
-- 64 MiB bound of one verified result, the retained bytes stay within
-- 512 MiB.
retrievalsBound :: Int
retrievalsBound = 8

-- | The latest retrieval of the verified result of a run.
data RetrievalState result
  = -- | The exact verified bytes. They are never retrieved again.
    Retrieved !result
  | -- | The latest retrieval was refused with this code, or it found no
    -- verified result. The flag records whether an observation of the run
    -- was installed after that retrieval, which makes an automatic retry due.
    RetrievalFailed !Text !Bool
  deriving (Eq, Show)

-- | The latest retrieval of this run.
retrievalOf :: Text -> Retrievals result -> Maybe (RetrievalState result)
retrievalOf run (Retrievals _ entries) = snd <$> Map.lookup run entries

-- | The runs with a retrieval, in identifier order.
retrievalRuns :: Retrievals result -> [Text]
retrievalRuns (Retrievals _ entries) = Map.keys entries

-- | Whether a refresh for this cause retrieves the verified result of this
-- run now, given the retrievals of the session. A run without a retrieval is
-- retrieved. Retrieved bytes are never retrieved again. After a failure, an
-- explicit refresh retries at once, and an automatic refresh retries only
-- after the next installed observation of the run, so each automatic refresh
-- starts at most one retrieval and the observation keeps its refresh.
retrievalDue :: RefreshCause -> Text -> Retrievals result -> Bool
retrievalDue cause run retrievals = case retrievalOf run retrievals of
  Just (Retrieved _) -> False
  Just (RetrievalFailed _ observed) -> observed || cause == ExplicitRefresh
  Nothing -> True

-- | The retrievals after one completed retrieval of this run: the verified
-- bytes, or a retryable failure with the refusal code or the fixed text
-- @no verified result@. The retrievals of the other runs stay, except that a
-- new run beyond 'retrievalsBound' removes the run whose retrieval completed
-- first.
retrievalStep :: Text -> Either C.ClientFailure (Maybe result) -> Retrievals result -> Retrievals result
retrievalStep run outcome (Retrievals counter entries) =
  Retrievals (counter + 1) (Map.insert run (counter, state) kept)
  where
    state = case outcome of
      Right (Just result) -> Retrieved result
      Right Nothing -> RetrievalFailed "no verified result" False
      Left failure -> RetrievalFailed (refusalCode failure) False
    kept
      | Map.member run entries || Map.size entries < retrievalsBound = entries
      | otherwise = Map.delete (fst (minimumBy (comparing (fst . snd)) (Map.toList entries))) entries

-- | The retrievals after an installed observation of this run. A failed
-- retrieval of the run becomes due for an automatic retry. Retrieved bytes
-- and the retrievals of the other runs stay.
retrievalObserved :: Text -> Retrievals result -> Retrievals result
retrievalObserved run (Retrievals counter entries) = Retrievals counter (Map.adjust observed run entries)
  where
    observed (order, state) = case state of
      RetrievalFailed code _ -> (order, RetrievalFailed code True)
      Retrieved _ -> (order, state)

-- | The retained verified bytes of this run.
retrievedResult :: Text -> Retrievals result -> Maybe result
retrievedResult run retrievals = case retrievalOf run retrievals of
  Just (Retrieved result) -> Just result
  _ -> Nothing

-- | The retrieval of this run for display: none yet, the failure code of the
-- latest retrieval, or the verified bytes.
retrievalShown :: Text -> Retrievals result -> Maybe (Either Text result)
retrievalShown run retrievals = flip fmap (retrievalOf run retrievals) $ \state -> case state of
  Retrieved result -> Right result
  RetrievalFailed code _ -> Left code

-- | The status line after one completed retrieval.
retrievalStatus :: RetrievalState result -> Text
retrievalStatus state = case state of
  Retrieved _ -> "verified result retrieved"
  RetrievalFailed code _ -> "verified result not retrieved: " <> code <> "; the next refresh retries"

-- | The status line of a key outcome.
keyOutcomeLine :: KeyOutcome -> Text
keyOutcomeLine outcome = "Key " <> T.pack (show (outcomeKey outcome)) <> ": " <> outcomeText outcome

-- | The key outcome that remains after one service event, given whether the
-- event was a key press, the view before and after the event, and the key
-- outcome before and after the event.
--
-- An outcome that the event produced is shown. An earlier outcome lasts until
-- the next key press or until an event changes the view, so reads, installs
-- and ticks that keep the view never remove it.
retainKeyOutcome :: (Eq view) => Bool -> view -> view -> Maybe KeyOutcome -> Maybe KeyOutcome -> Maybe KeyOutcome
retainKeyOutcome keyPress viewBefore viewAfter previous current
  | current /= previous = current
  | keyPress || viewBefore /= viewAfter = Nothing
  | otherwise = current

-- | The retained attempt that an explicit exact resend may send again.
-- Only a declared uncertainty offers one, and no fault may have occurred.
resendAttempt :: Lane pending location -> Maybe (Attempt pending location)
resendAttempt lane = case laneMutation lane of
  MutationUncertain attempt (DeclaredUncertainty _) | not (laneFault lane) -> Just attempt
  _ -> Nothing

resendOffered :: Lane pending location -> Bool
resendOffered = isJust . resendAttempt

-- | The operation and URI of the command in the lane, and whether an explicit
-- exact resend is offered for it.
mutationNotice :: Lane pending location -> Maybe (Text, Text, Bool)
mutationNotice lane = case laneMutation lane of
  MutationIdle -> Nothing
  MutationPreparing _ mutation -> entry mutation
  MutationSending _ attempt -> entry (attemptMutation attempt)
  MutationAwaiting mutation _ _ -> entry mutation
  MutationUncertain attempt _ -> entry (attemptMutation attempt)
  where
    entry mutation = Just (mutationOperation mutation, mutationURI mutation, resendOffered lane)

-- | The fixed status line after an internal fault.
internalFaultStatus :: Text
internalFaultStatus = "internal frontend fault: read-only actions remain and no mutation starts"

-- | The fixed lines that close every notice after an internal fault.
faultClosing :: [Text]
faultClosing =
  [ "The frontend starts no further mutation in this session. Read-only actions remain.",
    "g refreshes the observation of the current request, if one exists. q detaches."
  ]

-- | The notice for the unresolved attempt that the lane holds, if any. It
-- names the original operation and URI, and it offers an exact resend only
-- when 'resendOffered' holds for the lane.
unresolvedNotice :: Lane pending location -> Maybe Text
unresolvedNotice lane = case laneMutation lane of
  MutationUncertain attempt cause ->
    Just . T.intercalate "\n" $
      [ case cause of
          DeclaredUncertainty failure -> "Outcome unresolved: " <> failure
          FaultUncertainty -> "Outcome unresolved after an internal frontend fault.",
        "Original " <> mutationOperation (attemptMutation attempt) <> " attempt retained.",
        mutationURI (attemptMutation attempt)
      ]
        <> if resendOffered lane
          then ["g refreshes observations. x requests an exact resend. q detaches."]
          else ["Internal frontend fault. No exact resend is offered."] <> faultClosing
  _ -> Nothing

-- | The notice shown after an internal fault. An unresolved attempt or an
-- accepted intent remains visible with its original operation and URI.
faultScreen :: Lane pending location -> Text
faultScreen lane = case (unresolvedNotice lane, laneMutation lane) of
  (Just notice, _) -> notice
  (Nothing, MutationAwaiting mutation _ _) ->
    T.intercalate "\n" $
      [ "Internal frontend fault.",
        "The manager accepted the " <> mutationOperation mutation <> " intent for " <> mutationURI mutation <> ".",
        "Its effect is not yet observed, and automatic refresh has stopped."
      ]
        <> faultClosing
  (Nothing, _) ->
    T.intercalate "\n" $
      [ "Internal frontend fault.",
        "The frontend stopped the faulted operation and sent no mutation for it.",
        "Previous command outcomes and installed observations are unchanged."
      ]
        <> faultClosing

-- | Fixed standard-error notices at shutdown, given whether a command outcome
-- remains uncertain and whether an internal fault occurred.
shutdownNotices :: Bool -> Bool -> [Text]
shutdownNotices uncertain faulted =
  ["The frontend stopped manager operations after an internal frontend fault." | faulted]
    <> ["Manager command outcome may be uncertain. The manager run was not cancelled." | uncertain]

-- | A read that live delivery keeps current: the manager overview, the
-- composite read of the selected request, the pending decision heads of
-- the manager decisions, or the shown read of the History view, which is
-- the run list or the detail of one run.
data FetchKey = OverviewFetch | RequestFetch | DecisionsFetch | HistoryFetch
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The state of live delivery of the session.
data Delivery
  = -- | No stream runs. The first overview of the session has not been read.
    DeliveryIdle
  | -- | The first stream connects and has delivered nothing yet.
    DeliveryConnecting
  | -- | The stream delivered a heartbeat or an invalidation.
    DeliveryLive
  | -- | The latest JSON polling batch succeeded. The stream is tried again
    -- after the backoff.
    DeliveryPolling
  | -- | Delivery failed at this time with this refusal code, and nothing has
    -- succeeded since. The worker reconnects or polls again.
    DeliveryDisconnected !UTCTime !Text
  | -- | The manager refused the cursor with 410. The stream waits for a new
    -- overview, whose cursor starts it again.
    DeliveryResnapshot
  | -- | The stream stopped for this reason and does not reconnect.
    DeliveryStopped !Text
  deriving (Eq, Show)

-- | The delivery state as the shell shows it. The time of a disconnection
-- is the UTC time of day.
deliveryText :: Delivery -> Text
deliveryText delivery = "delivery " <> case delivery of
  DeliveryIdle -> "not started"
  DeliveryConnecting -> "connecting"
  DeliveryLive -> "live"
  DeliveryPolling -> "polling"
  DeliveryDisconnected since code -> "disconnected since " <> T.pack (formatTime defaultTimeLocale "%H:%M:%SZ" since) <> " (" <> code <> ")"
  DeliveryResnapshot -> "resnapshot"
  DeliveryStopped reason -> "stopped (" <> reason <> ")"

-- | A failure of delivery at this time with this failure. A delivery that
-- is already disconnected keeps the time of its first failure.
disconnected :: UTCTime -> C.ClientFailure -> Delivery -> Delivery
disconnected now failure current = case current of
  DeliveryDisconnected since _ -> DeliveryDisconnected since (refusalCode failure)
  _ -> DeliveryDisconnected now (refusalCode failure)

-- | The transport state of the event worker: the last complete event
-- identifier, which every reconnection and every poll sends, the backoff of
-- the next SSE attempt, and the number of consecutive SSE failures.
data Follow = Follow
  { followCursor :: !Text,
    followBackoff :: !C.Backoff,
    followFailures :: !Int
  }
  deriving (Eq, Show)

-- | The worker that starts from the cursor of an installed overview.
newFollow :: Text -> Follow
newFollow cursor = Follow cursor C.initialBackoff 0

-- | The number of consecutive SSE failures after which the worker polls.
streamFailureLimit :: Int
streamFailureLimit = 2

-- | The interval between two JSON polling batches.
pollIntervalSeconds :: Int
pollIntervalSeconds = 1

-- | The end of one SSE connection: whether it delivered a heartbeat or an
-- invalidation, the identifier of its last complete event, which is the
-- supplied cursor when no event arrived, and its failure. 'Nothing' is an
-- end of the response by the manager or after the idle bound.
data StreamEnd = StreamEnd
  { endDelivered :: !Bool,
    endCursor :: !Text,
    endFailure :: !(Maybe C.ClientFailure)
  }
  deriving (Eq, Show)

-- | What the worker does after an SSE connection.
data FollowStep
  = -- | Connect again from the cursor after this delay in seconds.
    FollowStream !Int
  | -- | Poll every 'pollIntervalSeconds' from the cursor, and connect again
    -- after this delay in seconds.
    FollowPoll !Int
  | -- | The manager refused the cursor with 410. A new overview is needed.
    FollowResnapshot
  | -- | The client is closed. The worker ends.
    FollowClosed
  deriving (Eq, Show)

-- | The step after one SSE connection at this time, the next transport
-- state, and the next delivery state, given the current one. Every
-- reconnection and every poll starts from the last complete event
-- identifier. A connection that delivered resets the backoff and the count
-- of consecutive failures, and its end then counts as one failure. A 410
-- refusal needs a resnapshot. Any other refusal, for example 429 when the
-- credential has no free SSE reader, or 'streamFailureLimit' consecutive
-- failures change to polling. Otherwise the worker connects again after the
-- backoff. The backoff doubles with each attempt that delivered nothing. An
-- SSE attempt that fails while polling keeps the polling state, so the next
-- batch decides the state.
afterStream :: UTCTime -> StreamEnd -> Delivery -> Follow -> (Follow, Delivery, FollowStep)
afterStream now (StreamEnd delivered cursor failure) delivery follow = case failure of
  Just C.ClientClosed -> (follow', delivery, FollowClosed)
  Just (C.Refused 410 _) -> (follow', DeliveryResnapshot, FollowResnapshot)
  Just refusal@(C.Refused _ _) -> (backedOff, lost refusal, FollowPoll seconds)
  Just other | failures >= streamFailureLimit -> (backedOff, lost other, FollowPoll seconds)
  Just other -> (backedOff, disconnected now other delivery, FollowStream seconds)
  Nothing | failures >= streamFailureLimit -> (backedOff, lost C.TransportUnavailable, FollowPoll seconds)
  Nothing -> (backedOff, delivery, FollowStream seconds)
  where
    base = if delivered then C.initialBackoff else followBackoff follow
    failures = (if delivered then 0 else followFailures follow) + 1
    (seconds, next) = C.reconnectDelay base
    follow' = follow {followCursor = cursor}
    backedOff = Follow cursor next failures
    lost reason = case delivery of
      DeliveryPolling -> DeliveryPolling
      _ -> disconnected now reason delivery

-- | What the worker does after one JSON polling batch.
data PollStep
  = -- | The batch has more events. Poll again at once.
    PollNow
  | -- | Poll again after 'pollIntervalSeconds', or connect the stream when
    -- its backoff has passed.
    PollLater
  | -- | The manager refused the cursor with 410. A new overview is needed.
    PollResnapshot
  | -- | The client is closed. The worker ends.
    PollClosed
  deriving (Eq, Show)

-- | The step after one polling batch at this time, the next transport
-- state and the next delivery state. A batch gives the cursor of the next
-- poll and the polling state, and a batch with more events polls again at
-- once. A failed poll keeps the cursor and disconnects.
afterPoll :: UTCTime -> Either C.ClientFailure (Text, Bool) -> Delivery -> Follow -> (Follow, Delivery, PollStep)
afterPoll now outcome delivery follow = case outcome of
  Right (cursor, more) -> (follow {followCursor = cursor}, DeliveryPolling, if more then PollNow else PollLater)
  Left C.ClientClosed -> (follow, delivery, PollClosed)
  Left (C.Refused 410 _) -> (follow, DeliveryResnapshot, PollResnapshot)
  Left failure -> (follow, disconnected now failure delivery, PollLater)

-- | Whether an installed overview starts the event worker from its cursor:
-- only an overview read that started in the current fetch generation, and
-- only when no worker runs, before the first stream of the session or after
-- a 410 refusal. An overview read from before a resnapshot never starts the
-- stream from its earlier cursor.
overviewStartsStream :: C.FetchGeneration -> C.FetchGeneration -> Delivery -> Bool
overviewStartsStream started current delivery =
  started == current && delivery `elem` [DeliveryIdle, DeliveryResnapshot]

-- | The resources that invalidations named since the frontend last took the
-- set, at most 'invalidatedBound' of them. A further resource sets the
-- overflow mark, which invalidates every read.
data Invalidated = Invalidated
  { invalidatedResources :: !(Set.Set Text),
    invalidatedOverflow :: !Bool
  }
  deriving (Eq, Show)

noInvalidations :: Invalidated
noInvalidations = Invalidated Set.empty False

-- | The largest number of distinct resources that the set holds.
invalidatedBound :: Int
invalidatedBound = 1024

-- | Record the resource of one invalidation.
noteInvalidation :: Text -> Invalidated -> Invalidated
noteInvalidation resource invalidated@(Invalidated resources overflow)
  | overflow || Set.member resource resources = invalidated
  | Set.size resources >= invalidatedBound = Invalidated resources True
  | otherwise = Invalidated (Set.insert resource resources) False

-- | The reads that read an invalidated resource, given the resources of the
-- composite read of the selected request ('Agentic.Tui.Service.compositeResources').
-- The overview reads every overview member, and an invalidation names a
-- member as @/v1/requests/{id}@, @/v1/preparations/{id}@, @/v1/runs/{id}@
-- or @/v1/decisions/{id}@, or names a resource below a member, such as
-- @/v1/runs/{id}/snapshot@ when the runtime status of a run changes. The
-- overview shows that status, so a resource at or below a member
-- invalidates the overview. The composite read reads its resources and the
-- resources below them, such as the snapshot and the controls of its run,
-- so a resource invalidates it when one of the two resources is the other
-- or lies below it. The decision heads change with a decision, such as a
-- new head or an answered head, and with a run, whose end leaves its queue,
-- so a resource at or below a decision or a run invalidates them. The
-- History view lists every run and shows the detail of one run, so a
-- resource at or below a run invalidates it. An overflowing set invalidates
-- every read.
invalidatedFetches :: [Text] -> Invalidated -> [FetchKey]
invalidatedFetches composite (Invalidated resources overflow)
  | overflow = [minBound .. maxBound]
  | otherwise =
      [OverviewFetch | any (member ["requests", "preparations", "runs", "decisions"]) invalidated]
        <> [RequestFetch | any (\resource -> any (related resource) composite) invalidated]
        <> [DecisionsFetch | any (member ["runs", "decisions"]) invalidated]
        <> [HistoryFetch | any (member ["runs"]) invalidated]
  where
    invalidated = Set.toList resources
    member collections resource = case T.splitOn "/" resource of
      "" : "v1" : collection : ident : _ -> collection `elem` collections && not (T.null ident)
      _ -> False
    related one other = one == other || below one other || below other one
    below parent child = (parent <> "/") `T.isPrefixOf` child

-- | The fetches of live delivery that wait for the read lane, in order, and
-- the fetch that holds the read ticket with its ticket number.
data Fetches = Fetches
  { fetchesWaiting :: ![(FetchKey, C.FetchGeneration)],
    fetchesReading :: !(Maybe (Int, FetchKey, C.FetchGeneration))
  }
  deriving (Eq, Show)

noFetches :: Fetches
noFetches = Fetches [] Nothing

-- | Apply invalidations of these reads to the coordinator. A read whose
-- fetch waits for the read lane has read nothing yet, so its invalidation
-- changes nothing. Every other invalidation goes to the coordinator, which
-- starts a fetch of an idle read and only marks a read in flight dirty. A
-- started fetch waits for the read lane.
invalidateFetches :: [FetchKey] -> C.Refresh FetchKey -> Fetches -> (C.Refresh FetchKey, Fetches)
invalidateFetches keys refresh fetches = foldl step (refresh, fetches) keys
  where
    step (current, held) key
      | key `elem` map fst (fetchesWaiting held) = (current, held)
      | otherwise =
          let (next, actions) = C.invalidateResource key current
           in (next, foldl (flip queue) held actions)

-- | Add the fetch that a coordinator action starts to the waiting fetches.
queue :: C.RefreshAction FetchKey -> Fetches -> Fetches
queue action fetches = case action of
  C.StartFetch key generation | key `notElem` map fst (fetchesWaiting fetches) ->
    fetches {fetchesWaiting = fetchesWaiting fetches <> [(key, generation)]}
  _ -> fetches

-- | The first waiting fetch that may start now, given which reads may
-- start. Nothing starts while a fetch holds the read ticket or while any
-- read holds it.
takeFetch :: (FetchKey -> Bool) -> Lane pending location -> Fetches -> Maybe ((FetchKey, C.FetchGeneration), Fetches)
takeFetch startable lane fetches
  | isJust (fetchesReading fetches) || isJust (laneReadTicket lane) = Nothing
  | otherwise = case break (startable . fst) (fetchesWaiting fetches) of
      (before, first : after) -> Just (first, fetches {fetchesWaiting = before <> after})
      (_, []) -> Nothing

-- | Record that the read with this ticket number performs the fetch.
fetchStarted :: Int -> (FetchKey, C.FetchGeneration) -> Fetches -> Fetches
fetchStarted ticket (key, generation) fetches = fetches {fetchesReading = Just (ticket, key, generation)}

-- | Complete a taken fetch that started no read, because its read has
-- nothing to read, such as the composite read without a selected request.
fetchSkipped :: (FetchKey, C.FetchGeneration) -> C.Refresh FetchKey -> Fetches -> (C.Refresh FetchKey, Fetches)
fetchSkipped (key, generation) refresh fetches =
  let (next, actions) = C.completeFetch key generation refresh
   in (next, foldl (flip queue) fetches actions)

-- | Complete the read with this ticket number when it performs the fetch:
-- whether its result installs, and the next coordinator and fetches. A
-- result of an earlier generation does not install. When invalidations
-- arrived during the fetch, exactly one later fetch waits. A read that does
-- not perform the fetch gives 'Nothing'.
fetchCompleted :: Int -> C.Refresh FetchKey -> Fetches -> Maybe (Bool, C.Refresh FetchKey, Fetches)
fetchCompleted ticket refresh fetches = case fetchesReading fetches of
  Just (reading, key, generation) | reading == ticket ->
    let (next, actions) = C.completeFetch key generation refresh
     in Just (C.InstallFetch key generation `elem` actions, next, foldl (flip queue) fetches {fetchesReading = Nothing} actions)
  _ -> Nothing

-- | The fetch whose read no longer holds the read ticket without a
-- completion, because a mutation key or an exact resend ended and cancelled
-- that read, waits again at the front. Its coordinator flight stays.
fetchAbandoned :: Lane pending location -> Fetches -> Fetches
fetchAbandoned lane fetches = case fetchesReading fetches of
  Just (ticket, key, generation) | fmap ticketNumber (laneReadTicket lane) /= Just ticket ->
    Fetches ((key, generation) : filter ((/= key) . fst) (fetchesWaiting fetches)) Nothing
  _ -> fetches

-- | The resnapshot after a 410 refusal of the stream. The coordinator
-- advances its generation, so a fetch still in flight completes without
-- installing, and in particular an overview read from before the refusal
-- installs no old cursor. The waiting fetches of the earlier generation are
-- dropped, and every read is fetched again in the new generation. The
-- fetch in flight keeps the read ticket until it completes, so the new
-- fetches start after it.
resnapshotFetches :: C.Refresh FetchKey -> Fetches -> (C.Refresh FetchKey, Fetches)
resnapshotFetches refresh fetches =
  invalidateFetches [minBound .. maxBound] (C.advanceGeneration refresh) fetches {fetchesWaiting = []}

-- | The retry of an overview read of live delivery or of a resnapshot after
-- a refusal: the time of the next read, or 'Nothing' while that read waits
-- or runs, and the backoff of the next refusal. A refusal can answer the
-- last invalidation, and after a 410 no stream runs, so without this retry
-- no later invalidation reads the overview again.
data OverviewRetry = OverviewRetry
  { retryDue :: !(Maybe UTCTime),
    retryBackoff :: !C.Backoff
  }
  deriving (Eq, Show)

-- | A refused overview read at this time. The next read is due after the
-- delay of the backoff of the client, which doubles from one second up to
-- 'C.reconnectBackoffMaxSeconds'.
overviewRefused :: UTCTime -> Maybe OverviewRetry -> OverviewRetry
overviewRefused now previous =
  let (seconds, next) = C.reconnectDelay (maybe C.initialBackoff retryBackoff previous)
   in OverviewRetry (Just (addUTCTime (fromIntegral seconds) now)) next

-- | Whether the refused overview read is due again at this time.
overviewRetryDue :: Maybe OverviewRetry -> UTCTime -> Bool
overviewRetryDue retry now = maybe False (<= now) (retry >>= retryDue)

-- | The retry after its overview read was queued. It is due again only
-- after a further refusal.
overviewRetryStarted :: OverviewRetry -> OverviewRetry
overviewRetryStarted retry = retry {retryDue = Nothing}

-- | The shortest interval between two timer reads of the selected request
-- while the stream is live.
safetyReadInterval :: NominalDiffTime
safetyReadInterval = 5

-- | Whether the timer reads the selected request at this time, given the
-- delivery state and the time of the latest timer read. Without a live
-- stream, in particular while the worker polls or is disconnected, the timer
-- reads at every tick of one second.
safetyReadDue :: Delivery -> Maybe UTCTime -> UTCTime -> Bool
safetyReadDue delivery latest now = case (delivery, latest) of
  (DeliveryLive, Just previous) -> diffUTCTime now previous >= safetyReadInterval
  _ -> True

-- | The focus of a list of rows by the identity of the selected row, with
-- the index at which that row was last selected. A refresh, a selection
-- change and a resize keep the identity, so the same row stays selected
-- wherever it moves in the list.
data RowFocus key = RowFocus
  { focusKey :: !(Maybe key),
    focusIndex :: !Int
  }
  deriving (Eq, Show)

-- | The focus before any row is selected: the first row.
noFocus :: RowFocus key
noFocus = RowFocus Nothing 0

-- | The index of the selected row in these rows: the row with the focused
-- identity, or the last selected index bounded by the rows when no row has
-- that identity.
focusedIndex :: Eq key => [key] -> RowFocus key -> Int
focusedIndex keys (RowFocus key index) =
  fromMaybe (max 0 (min (length keys - 1) index)) (key >>= (`elemIndex` keys))

-- | Move the focus by this many rows from the selected row, bounded by the
-- rows, and focus the identity of the row reached.
moveFocus :: Eq key => Int -> [key] -> RowFocus key -> RowFocus key
moveFocus delta keys focus =
  let index = max 0 (min (length keys - 1) (focusedIndex keys focus + delta))
   in RowFocus (if null keys then focusKey focus else Just (keys !! index)) index

-- | The identity of one text draft of the service frontend: the input
-- editor text of one input of one request, or the answer text of one
-- decision of one run.
data DraftKey
  = InputDraft !Text !Text
  | AnswerDraft !Text !Text
  deriving (Eq, Ord, Show)

-- | The text drafts by identity. A refresh, a selection change and a resize
-- change no draft. Only typed text, a completed command and a change of the
-- answer head change them.
newtype Drafts = Drafts (Map.Map DraftKey Text)
  deriving (Eq, Show)

noDrafts :: Drafts
noDrafts = Drafts Map.empty

-- | The largest number of drafts that are kept. Each draft is bounded by its
-- editor.
draftsBound :: Int
draftsBound = 64

-- | The draft with this identity.
draftText :: DraftKey -> Drafts -> Maybe Text
draftText key (Drafts drafts) = Map.lookup key drafts

-- | The identities of the kept drafts.
draftKeys :: Drafts -> [DraftKey]
draftKeys (Drafts drafts) = Map.keys drafts

-- | Keep the typed text as the draft with this identity. Empty text removes
-- the draft. A new identity is not kept when 'draftsBound' drafts are kept,
-- and its text then stays only in the editor.
recordDraft :: DraftKey -> Text -> Drafts -> Drafts
recordDraft key text (Drafts drafts)
  | T.null text = Drafts (Map.delete key drafts)
  | Map.member key drafts || Map.size drafts < draftsBound = Drafts (Map.insert key text drafts)
  | otherwise = Drafts drafts

-- | Remove the draft with this identity, as after its command completed.
dropDraft :: DraftKey -> Drafts -> Drafts
dropDraft key (Drafts drafts) = Drafts (Map.delete key drafts)

-- | The drafts and the editor text after the displayed draft changes from
-- the first identity to the second. 'Nothing' keeps the editor when the
-- identity is the same. Otherwise the editor shows the draft of the new
-- identity, or 'Nothing' inside 'Just' when it has none. Only the decision
-- at the head of a run can be answered, so the display of the answer draft
-- of one decision removes the drafts of the other decisions of that run: a
-- draft for an earlier head is stale.
showDraft :: Maybe DraftKey -> Maybe DraftKey -> Drafts -> (Drafts, Maybe (Maybe Text))
showDraft before after drafts@(Drafts kept)
  | before == after = (drafts, Nothing)
  | otherwise = (current, Just (after >>= (`draftText` current)))
  where
    current = case after of
      Just (AnswerDraft run decision) -> Drafts (Map.filterWithKey (\key _ -> case key of
        AnswerDraft other earlier -> other /= run || earlier == decision
        InputDraft {} -> True) kept)
      _ -> drafts

-- | The fixed text that states that the decision of a draft changed and
-- that the draft is kept.
draftKeptText :: Text
draftKeptText = "decision changed; draft kept"

-- | The drafts after the displayed question head of a run changed from the
-- decision of the first identity while the live monitor still shows that
-- run, given the identity of the head that the monitor shows now. The caller
-- applies it only when this session holds no answer to the earlier decision,
-- so the earlier draft was never sent. 'Nothing' means that nothing is kept:
-- the earlier identity is not an answer draft, it has no draft, the head did
-- not change, or the new head has its own draft. A new head of the run takes the
-- earlier draft, so 'showDraft' shows it in the editor. A run without a head
-- keeps the earlier draft as it is. Nothing is sent, and the operator sends
-- the kept draft only with an explicit key.
keepDraft :: DraftKey -> Maybe DraftKey -> Drafts -> Maybe Drafts
keepDraft earlier after drafts@(Drafts kept) = case earlier of
  AnswerDraft run decision | Just text <- draftText earlier drafts, after /= Just earlier -> case after of
    Just later@(AnswerDraft other next) | other == run, next /= decision, not (Map.member later kept) ->
      Just (Drafts (Map.insert later text (Map.delete earlier kept)))
    Nothing -> Just drafts
    _ -> Nothing
  _ -> Nothing
