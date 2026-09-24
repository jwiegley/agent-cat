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
-- lane facts, so no transition can change them. The lane values are
-- polymorphic in the pending command and receipt location. The lane only
-- retains them. It never inspects, rebuilds or retargets them.
module Agentic.Tui.ServiceLane
  ( CallOutcome (..),
    serviceCall,
    declaredCall,
    Attempt (..),
    Uncertainty (..),
    MutationState (..),
    Lane (..),
    faultLane,
    settleUncertain,
    declaredSendUncertain,
    ReadStep (..),
    readStep,
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
import Agentic.Tui.Service (Mutation, mutationOperation, mutationURI)
import Control.Exception (SomeAsyncException, SomeException, evaluate, fromException, throwIO, try)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

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

-- | The lane-owned facts of one service session: the read ticket, the one
-- command lane, whether an internal fault occurred in this session, and
-- whether an exact resend awaits confirmation. Observations, approvals and
-- receipts are not lane facts, so no lane transition can change them.
data Lane pending location = Lane
  { laneReadTicket :: !(Maybe Int),
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
  | laneReadTicket lane /= Just ticket = (ReadStale, lane)
  | otherwise = case outcome of
      InternalFault -> (ReadFaulted, faultLane lane)
      Declared (Left failure) -> (ReadRefused failure, lane {laneReadTicket = Nothing})
      Declared (Right value) -> (ReadDelivered value, lane {laneReadTicket = Nothing})

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
