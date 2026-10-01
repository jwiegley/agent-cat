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
-- retrieved verified bytes are retained ('Retrieval'). A refusal or a
-- retrieval without a verified result is a retryable failure: an automatic
-- refresh retries it after the next installed composite read, and an
-- explicit refresh retries it at once ('retrievalDue').
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
    resendDeferredText,
    resendUnofferedText,
    keyHelpText,
    unobservedText,
    KeyOutcome (..),
    Deferral (..),
    deferral,
    keyOutcomeLine,
    retainKeyOutcome,
    refreshPauseLimit,
    refreshPaused,
    RefreshCause (..),
    Retrieval (..),
    RetrievalState (..),
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
  )
where

import qualified Agentic.Manager.Client as C
import Agentic.Tui.Service (Mutation, ReadVerdict (..), missingScope, mutationOperation, mutationURI)
import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, throwIO, try)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)

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
  | -- | At least one page set: the profiles, the workflows, or the composite
    -- read of an associated request with its snapshot page set.
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
  | SendDelivered !(Attempt pending location) !response

-- | Complete the send that holds the given ticket.
sendStep :: Int -> CallOutcome response -> Lane pending location -> (SendStep pending location response, Lane pending location)
sendStep ticket outcome lane = case laneMutation lane of
  MutationSending expected attempt | ticket == expected -> case outcome of
    InternalFault -> (SendFaulted, faultLane (settleUncertain attempt FaultUncertainty lane))
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
startupFailureText failure = "--tui --service: " <> case failure of
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

-- | The retrieval of the verified result of one run, by its run identifier.
data Retrieval result = Retrieval
  { retrievalRun :: !Text,
    retrievalState :: !(RetrievalState result)
  }
  deriving (Eq, Show)

-- | The latest retrieval of the verified result of a run.
data RetrievalState result
  = -- | The exact verified bytes. They are never retrieved again.
    Retrieved !result
  | -- | The latest retrieval was refused with this code, or it found no
    -- verified result. The flag records whether a composite read was
    -- installed after that retrieval, which makes an automatic retry due.
    RetrievalFailed !Text !Bool
  deriving (Eq, Show)

-- | Whether a refresh for this cause retrieves the verified result of this
-- run now, given the retained retrieval. A run without a retrieval is
-- retrieved. Retrieved bytes are never retrieved again. After a failure, an
-- explicit refresh retries at once, and an automatic refresh retries only
-- after the next installed composite read, so each automatic refresh starts
-- at most one retrieval and the observation keeps its refresh.
retrievalDue :: RefreshCause -> Text -> Maybe (Retrieval result) -> Bool
retrievalDue cause run retrieval = case retrieval of
  Just (Retrieval ident state) | ident == run -> case state of
    Retrieved _ -> False
    RetrievalFailed _ observed -> observed || cause == ExplicitRefresh
  _ -> True

-- | The retrieval after one completed retrieval of this run: the verified
-- bytes, or a retryable failure with the refusal code or the fixed text
-- @no verified result@.
retrievalStep :: Text -> Either C.ClientFailure (Maybe result) -> Retrieval result
retrievalStep run outcome = Retrieval run $ case outcome of
  Right (Just result) -> Retrieved result
  Right Nothing -> RetrievalFailed "no verified result" False
  Left failure -> RetrievalFailed (refusalCode failure) False

-- | The retrieval after an installed composite read. A failed retrieval
-- becomes due for an automatic retry. Retrieved bytes stay.
retrievalObserved :: Maybe (Retrieval result) -> Maybe (Retrieval result)
retrievalObserved retrieval = case retrieval of
  Just (Retrieval run (RetrievalFailed code _)) -> Just (Retrieval run (RetrievalFailed code True))
  _ -> retrieval

-- | The retained verified bytes of this run.
retrievedResult :: Text -> Maybe (Retrieval result) -> Maybe result
retrievedResult run retrieval = case retrieval of
  Just (Retrieval ident (Retrieved result)) | ident == run -> Just result
  _ -> Nothing

-- | The retrieval of this run for display: none yet, the failure code of the
-- latest retrieval, or the verified bytes.
retrievalShown :: Text -> Maybe (Retrieval result) -> Maybe (Either Text result)
retrievalShown run retrieval = case retrieval of
  Just (Retrieval ident state) | ident == run -> Just $ case state of
    Retrieved result -> Right result
    RetrievalFailed code _ -> Left code
  _ -> Nothing

-- | The status line after one completed retrieval.
retrievalStatus :: Retrieval result -> Text
retrievalStatus retrieval = case retrievalState retrieval of
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
