{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- |
-- Module      : Example.TriageInfo
-- Description : The registry half of the @triage@ example: its page and table.
--
-- "Triage" asks a decision model three questions about one support ticket and
-- routes the ticket by weighing the answers. A scripted run answers the three
-- questions from 'triageScript', and a routed run puts them to a decisions
-- engine.
module Example.TriageInfo
  ( triageBlurb,
    triageHelp,
    triageScript,
  )
where

import Agentic.Workflow (wft)
import Data.Text (Text)

-- | The canned replies, one per decision question, keyed by prefix.
--
-- A decision prompt opens with the first line of its instructions, so each
-- key is the instructions of one question. Each reply is the number record of
-- that question's options. Under this table the ticket is most likely a
-- billing ticket, and the customer asks for money back with probability 0.96,
-- which is at least 0.9, so the run takes the @refund-desk@ path and puts four
-- questions. The fourth question is a plain model question, which the
-- scripted default answers.
triageScript :: [(Text, Text)]
triageScript =
  [ ("Which team should handle this ticket?", "{\"Billing\":0.88,\"Technical\":0.11,\"Account\":0.01,\"Other\":0}"),
    ("The customer explicitly asks for money back.", "{\"False\":0.04,\"True\":0.96}"),
    ("How urgent is this ticket?", "{\"Routine\":0.1,\"Soon\":0.7,\"Urgent\":0.2}")
  ]

triageBlurb :: Text
triageBlurb = "three decision questions about a ticket, weighed to route it (takes the ticket)"

triageHelp :: Text
triageHelp =
  [wft|
  A decision model answers three questions about one support ticket: which
  team owns it, whether the customer asks for money back, and how urgent it
  is. Each answer is a probability for each option. The program weighs the
  answers and puts the ticket to one desk, which is a model. A billing ticket
  that asks for money back with probability at least 0.9 goes to
  `refund-desk`, and any other billing ticket to `billing-desk`. A ticket of
  another team whose expected urgency is at least `Soon` goes to `on-call`,
  and any other ticket to `support-desk`. An answer that is not a
  distribution goes to `triage-desk`.

  **Inputs.** `ticket`, the text of the ticket, which a direct run reads from
  standard input. It reaches every prompt as the evidence.

  **Transport.** The three decision questions are served by the profile
  `triage`, which a version 2 routing file may route to a decisions engine.
  The desks are served by the profile `balanced`, which the same file routes
  to a generative engine. Every question names its profile, so the routing
  file alone routes the run.

  ```sh
  agentic-run run triage --routing --input-file ticket=./ticket.txt
  ```

  **Rehearsal.** The ticket named empty, and the three decision questions
  answered from the row's own canned table:

  ```sh
  agentic-run run triage --scripted --input-arg ticket=
  ```

  **Caveats.** A decisions engine answers only the questions that `decide`
  asks, so a routing file that sends a desk to one is refused before the run
  starts. A weighing reads no threshold into the memo key, so a run with a
  changed threshold reuses the answers already paid for.
  |]
