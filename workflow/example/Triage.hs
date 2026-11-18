-- | Triage a support ticket with a decision model: which team owns it, whether the
-- customer asks for money back, and how urgent it is.
--
-- Every question names the profile that serves it. The three decisions name
-- the profile @triage@, and every desk is a model that names the profile
-- @balanced@.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
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
import Data.Text (Text)
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

-- | The model that answers the three decisions.
triager :: Party 'IsModel
triager = model "triage" `servedBy` "triage"

-- | The model that answers a ticket at one desk.
desk :: Text -> Party 'IsModel
desk name = model name `servedBy` "balanced"

triageProgram :: Parameterized
triageProgram =
  taking (stdinInputAs "ticket" :> noInputs) \ticket -> workflow W.do
    routed <- decide triager team [wf|{ticket}|]
    asked <- decide triager refund [wf|{ticket}|]
    pressing <- decide triager urgency [wf|{ticket}|]
    readable <- isDistribution routed
    if readable
      then W.do
        billing <- mostLikely Billing routed
        if billing
          then W.do
            refunding <- chanceYes asked `atLeast` 0.9
            if refunding
              then ask_ (desk "refund-desk") [wf|
                Prepare the refund this ticket asks for.
                {ticket}|]
              else ask_ (desk "billing-desk") [wf|
                Answer this billing ticket.
                {ticket}|]
          else W.do
            urgent <- levelAtLeast Soon pressing
            if urgent
              then ask_ (desk "on-call") [wf|
                An urgent ticket needs you.
                {ticket}|]
              else ask_ (desk "support-desk") [wf|
                Answer this ticket.
                {ticket}|]
      else ask_ (desk "triage-desk") [wf|
        The triage model gave no usable answer for this ticket.
        {ticket}|]
