-- | Triage a support ticket with a decision model: which team owns it, whether the
-- customer asks for money back, and how urgent it is.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Triage (triageProgram, Team (..), Urgency (..)) where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import GHC.Generics (Generic)
import Prelude

data Team = Billing | Technical | Account | Other
  deriving (Bounded, Enum, Eq, Ord, Show, Generic)

data Urgency = Routine | Soon | Urgent
  deriving (Bounded, Enum, Eq, Ord, Show, Generic)

team :: Question Team
team =
  choice "Which team should handle this ticket?" \case
    Billing -> "Payments, charges, invoices, and refunds."
    Technical -> "Errors, outages, and problems using the product."
    Account -> "Sign-in, profile, and subscription settings."
    Other -> "Anything that fits none of the teams above."

urgency :: Question Urgency
urgency =
  scale "How urgent is this ticket?" \case
    Routine -> "It can wait for the normal queue."
    Soon -> "It should be handled today."
    Urgent -> "It blocks the customer now."

refund :: Question Bool
refund = yesNo "The customer explicitly asks for money back."

triageProgram :: Parameterized
triageProgram =
  taking (stdinInputAs "ticket" :> noInputs) \ticket -> workflow W.do
    routed <- decide (model "triage") team [wf|{ticket}|]
    asked <- decide (model "triage") refund [wf|{ticket}|]
    pressing <- decide (model "triage") urgency [wf|{ticket}|]
    readable <- isDistribution routed
    if readable
      then W.do
        billing <- mostLikely Billing routed
        if billing
          then W.do
            refunding <- chanceYes asked `atLeast` 0.9
            if refunding
              then ask_ (model "refund-desk") [wf|
                Prepare the refund this ticket asks for.
                {ticket}|]
              else ask_ (model "billing-desk") [wf|
                Answer this billing ticket.
                {ticket}|]
          else W.do
            urgent <- levelAtLeast Soon pressing
            if urgent
              then ask_ (person "on-call") [wf|
                An urgent ticket needs you.
                {ticket}|]
              else ask_ (model "support-desk") [wf|
                Answer this ticket.
                {ticket}|]
      else ask_ (person "triage-desk") [wf|
        The triage model gave no usable answer for this ticket.
        {ticket}|]
