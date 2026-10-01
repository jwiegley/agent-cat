{-# LANGUAGE OverloadedStrings #-}

-- | Admissibility of the approval keys on the exact manager review.
--
-- Only the review screen has approval keys, as 'reviewApprovalKey' states.
-- The review screen has two views and can lie under the key help. The summary
-- shows the complete exact selectors, and the detail view shows the whole
-- review in a scrolling pane. Enter and y are the approval keys there, and
-- 'approvalDecision' decides the one outcome of each press. Forbidden keys and
-- views are refused first, before any command-lane, read-lane or review fact
-- is consulted. No key approves under the key help, Enter never approves, and
-- y never approves in the detail view. A y in the summary then requires every
-- scope that the manager requires for approval in the credential scopes, the
-- mutation-key admission of 'mutationAdmission' to start, and a displayed
-- review that is current, live, bound to the request and its literals, and
-- complete on the screen.
--
-- A single-resource read in flight does not decide any outcome. An approval
-- start ends its read ticket and cancels it, so that read delivers nothing
-- afterwards. A page-set read in flight defers a summary y visibly, so no
-- page set is abandoned. On the review screen the refresh reads only the
-- request, its preparation and a receipt, which are single resources.
--
-- Every press yields a 'KeyNotice' with a fixed text and the sequence number
-- of the press among the approval-key presses of the session. 'retainNotice'
-- states how long a notice lasts, and it replaces the approval-start notice
-- when the preflight refuses that approval before any send.
module Agentic.Tui.Approval
  ( ApprovalKey (..),
    approvalKey,
    reviewApprovalKey,
    ReviewView (..),
    reviewView,
    ReviewCheck (..),
    checkReview,
    Refusal (..),
    ApprovalDecision (..),
    approvalDecision,
    approvalOffered,
    KeyNotice (..),
    decisionNotice,
    refusalText,
    approvalStartText,
    preflightRefusedText,
    unscopedText,
    noticeLine,
    noticeTexts,
    unsentApproval,
    NoticeEvent (..),
    retainNotice,
  )
where

import qualified Agentic.Manager.Client as C
import Agentic.Tui.Model (Screen (..))
import Agentic.Tui.Service (Workflow, literalInputs, reviewLive, reviewMatches)
import qualified Agentic.Tui.Service as Service
import Agentic.Tui.ServiceLane (KeyAdmission (..), Lane, MutationState (..), mutationAdmission)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import qualified Graphics.Vty as Vty

-- | A key that concerns approval on the review screen.
data ApprovalKey
  = -- | Enter, which never approves.
    EnterKey
  | -- | y, which approves only the exact summary review.
    ApproveKey
  deriving (Eq, Show)

-- | The approval key that a key press denotes. Only an unmodified Enter or
-- an unmodified lowercase y is an approval key.
approvalKey :: Vty.Key -> [Vty.Modifier] -> Maybe ApprovalKey
approvalKey Vty.KEnter [] = Just EnterKey
approvalKey (Vty.KChar 'y') [] = Just ApproveKey
approvalKey _ _ = Nothing

-- | The approval key that a key press on this screen denotes, with the
-- displayed preparation and validator. Only the exact review screen has
-- approval keys, so a key press on any other screen keeps its other meaning.
reviewApprovalKey :: Screen -> Vty.Key -> [Vty.Modifier] -> Maybe (ApprovalKey, C.Preparation, Text)
reviewApprovalKey screen key modifiers = case screen of
  ServiceReviewScreen displayed tag -> (\approval -> (approval, displayed, tag)) <$> approvalKey key modifiers
  _ -> Nothing

-- | What the operator sees of the review screen.
data ReviewView
  = -- | The summary with the complete exact selectors.
    SummaryView
  | -- | The detail view of the complete review.
    DetailView
  | -- | The key help, which covers the review.
    KeyHelpView
  deriving (Eq, Show, Enum, Bounded)

-- | The view, given whether the key help is open and whether the detail view
-- is shown. The key help covers either view.
reviewView :: Bool -> Bool -> ReviewView
reviewView keyHelp detail
  | keyHelp = KeyHelpView
  | detail = DetailView
  | otherwise = SummaryView

-- | The displayed review, checked against the installed observations.
data ReviewCheck a
  = -- | The installed request or preparation is absent, or the displayed
    -- preparation or validator differs from the installed one.
    ReviewStale
  | -- | The preparation has expired or is no longer live.
    ReviewExpired
  | -- | The preparation does not bind the request, the workflow, the
    -- operator literals and the capture receipts of the session.
    ReviewMismatched
  | -- | The complete review does not fit the terminal.
    ReviewClipped
  | -- | The review may be approved. The value is what the approval needs.
    ReviewCurrent !a
  deriving (Eq, Show)

-- | Check the displayed review and validator against the installed
-- observations. The first argument reads the validator of an installed
-- preparation observation. The second is the current time, and the third
-- states whether the complete review fits the terminal. The operator
-- literals and the capture receipts of the session by capture identifier
-- follow the observations. A current review yields the installed request
-- and the installed preparation observation.
checkReview ::
  (observed -> Text) ->
  UTCTime ->
  Bool ->
  Maybe Workflow ->
  Maybe (requestObserved, C.DraftView) ->
  Maybe (observed, C.Preparation) ->
  Map.Map Text Text ->
  Map.Map Text C.CaptureReceipt ->
  C.Preparation ->
  Text ->
  ReviewCheck (C.DraftView, observed)
checkReview validator now fits workflow request preparation literals captures displayed tag =
  case (workflow, request, preparation) of
    (Just row, Just (_, draft), Just (observed, installed))
      | installed /= displayed || validator observed /= tag -> ReviewStale
      | not (reviewLive now displayed) -> ReviewExpired
      | not (reviewMatches captures row draft displayed) || literalInputs draft /= literals -> ReviewMismatched
      | not fits -> ReviewClipped
      | otherwise -> ReviewCurrent (draft, observed)
    _ -> ReviewStale

-- | Why an approval-key press does not approve.
data Refusal
  = -- | Enter in the summary.
    EnterRefused
  | -- | Enter in the detail view.
    EnterDetailRefused
  | -- | y in the detail view.
    DetailRefused
  | -- | Any approval key under the key help.
    HelpRefused
  | CommandBusy
  | FaultStopped
  | -- | A summary y while the credential of the session is refused.
    CredentialStopped
  | -- | A summary y while a page-set read is in flight.
    ReadDeferred
  | StaleReview
  | ExpiredReview
  | MismatchedReview
  | ClippedReview
  deriving (Eq, Show, Enum, Bounded)

-- | The one outcome of an approval-key press.
data ApprovalDecision a
  = -- | Start the approval with this value.
    Approve !a
  | Refuse !Refusal
  | -- | A summary y whose credential lacks this scope, which the manager
    -- requires for approval. Nothing is prepared or sent.
    Unscoped !Text
  deriving (Eq, Show)

-- | Decide one approval-key press, given the credential scopes, the view, the
-- service lane and the checked review.
--
-- The view and the key decide first, so no forbidden-key refusal depends on
-- the scopes, the lane or the review. A summary y then requires the scopes
-- that 'Service.missingScope' names for approval, then takes the mutation-key
-- admission of the lane, and only a start consults the review.
approvalDecision :: [Text] -> ApprovalKey -> ReviewView -> Lane pending location -> ReviewCheck a -> ApprovalDecision a
approvalDecision scopes key view lane review = case (view, key) of
  (KeyHelpView, _) -> Refuse HelpRefused
  (DetailView, EnterKey) -> Refuse EnterDetailRefused
  (SummaryView, EnterKey) -> Refuse EnterRefused
  (DetailView, ApproveKey) -> Refuse DetailRefused
  (SummaryView, ApproveKey) | Just scope <- Service.missingScope scopes "approve" -> Unscoped scope
  (SummaryView, ApproveKey) -> case mutationAdmission lane of
    KeyBusy -> Refuse CommandBusy
    KeyFaulted -> Refuse FaultStopped
    KeyCredentialRefused -> Refuse CredentialStopped
    KeyDeferred -> Refuse ReadDeferred
    KeyStart -> case review of
      ReviewStale -> Refuse StaleReview
      ReviewExpired -> Refuse ExpiredReview
      ReviewMismatched -> Refuse MismatchedReview
      ReviewClipped -> Refuse ClippedReview
      ReviewCurrent value -> Approve value

-- | Whether y would approve in the current view. The approval hint is shown
-- exactly when this holds.
approvalOffered :: [Text] -> ReviewView -> Lane pending location -> ReviewCheck a -> Bool
approvalOffered scopes view lane review = case approvalDecision scopes ApproveKey view lane review of
  Approve _ -> True
  Refuse _ -> False
  Unscoped _ -> False

-- | The visible outcome of one approval-key press: the sequence number of the
-- press and a fixed text.
data KeyNotice = KeyNotice
  { noticeKey :: !Int,
    noticeText :: !Text
  }
  deriving (Eq, Show)

-- | The notice for the decision of the press with the given sequence number.
decisionNotice :: Int -> ApprovalDecision a -> KeyNotice
decisionNotice serial decision = KeyNotice serial $ case decision of
  Approve _ -> approvalStartText
  Refuse refusal -> refusalText refusal
  Unscoped scope -> unscopedText scope

-- | The fixed text of each refusal.
refusalText :: Refusal -> Text
refusalText refusal = case refusal of
  EnterRefused -> "Enter does not approve; y approves the exact review"
  EnterDetailRefused -> "Enter does not approve; Esc returns to the summary, where y approves"
  DetailRefused -> "y does not approve in the detail view"
  HelpRefused -> "Approval did not start: the key help is open. Esc closes it."
  CommandBusy -> "Approval did not start: a manager command is in progress or unresolved."
  FaultStopped -> "Approval did not start: an internal frontend fault stopped all mutations."
  CredentialStopped -> "Approval did not start: the credential was refused."
  ReadDeferred -> "Approval did not start: a manager page-set read is in progress. Press y again."
  StaleReview -> "Approval did not start: the displayed review is stale."
  ExpiredReview -> "Approval did not start: the displayed review has expired or is no longer live."
  MismatchedReview -> "Approval did not start: the review does not match the request and its literals."
  ClippedReview -> "Approval did not start: the complete review does not fit. Resize the terminal."

-- | The fixed text of a summary y whose credential lacks the given scope.
unscopedText :: Text -> Text
unscopedText scope = "Approval did not start: this credential lacks " <> scope <> "."

-- | The fixed text of an approval start.
approvalStartText :: Text
approvalStartText = "Approval started for the exact displayed review."

-- | The fixed text that replaces the approval-start notice when the preflight
-- refuses that approval and the command lane returns to idle before any send.
preflightRefusedText :: Text
preflightRefusedText = "Approval was not sent: the preflight check refused it before any send."

-- | The displayed line of a notice.
noticeLine :: KeyNotice -> Text
noticeLine notice = "Approval key " <> T.pack (show (noticeKey notice)) <> ": " <> noticeText notice

-- | Every fixed notice text, with the scope refusal for each scope that the
-- manager requires for approval. The summary review reserves room for the
-- longest.
noticeTexts :: [Text]
noticeTexts = approvalStartText : preflightRefusedText : map refusalText [minBound .. maxBound]
  <> map unscopedText (maybe [] (map C.scopeName . C.requiredScopes) (C.parseOperation "approve"))

-- | The press whose approval one service event returned to idle before any
-- send, given the press that started the latest approval and the command
-- lane before and after the event. Only a preparing approval that becomes
-- idle qualifies, which is what a preflight refusal does. The lane admits no
-- other mutation while an approval is preparing, so the preparing approval is
-- the one that the latest approval press started.
unsentApproval :: Maybe Int -> MutationState pending location -> MutationState pending location -> Maybe Int
unsentApproval press before after = case (before, after) of
  (MutationPreparing _ Service.Approve {}, MutationIdle) -> press
  _ -> Nothing

-- | The facts of one service event that decide the notice lifetime.
data NoticeEvent view = NoticeEvent
  { -- | The event was a key press.
    eventKeyPress :: !Bool,
    -- | The screen and mode before the event.
    eventViewBefore :: !view,
    -- | The screen and mode after the event.
    eventViewAfter :: !view,
    -- | The review is on the screen after the event.
    eventReviewShown :: !Bool,
    -- | The press whose approval the event returned to idle before any send,
    -- as 'unsentApproval' decides.
    eventUnsentApproval :: !(Maybe Int)
  }
  deriving (Eq, Show)

-- | The notice that remains after one service event, given the notice before
-- and after the event.
--
-- Only the handling of an approval key produces a notice. A notice lasts
-- while the review stays on the screen, until a key changes the screen or the
-- mode. Observation installs and ticks that keep the review on the screen do
-- not remove it. When the preflight refuses an approval before any send, the
-- notice of that press becomes the fixed not-sent notice, so the approval
-- start is never reported after the approval stopped.
retainNotice :: (Eq view) => NoticeEvent view -> Maybe KeyNotice -> Maybe KeyNotice -> Maybe KeyNotice
retainNotice event previous current
  | not (eventReviewShown event) = Nothing
  | Just press <- eventUnsentApproval event = Just (KeyNotice press preflightRefusedText)
  | current /= previous = current
  | eventKeyPress event && eventViewBefore event /= eventViewAfter event = Nothing
  | otherwise = current
