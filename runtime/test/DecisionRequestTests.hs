{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | The runtime translation of a decision question: 'engineRequest' carries a
-- neutral decision exactly for a model question whose prompt parses as a
-- valid decision prompt and whose answer schema is that decision's record,
-- and the scripted world answers such a question as it answers any other.
module DecisionRequestTests (decisionRequestTests) where

import Agentic.Engine (EngineRequest (..), decodeEngineRequest, encodeEngineRequest)
import Agentic.Engine.Decision
  ( EngineDecision (..),
    EngineDecisionForm (EngineChoice, EngineScale, EngineYesNo),
    EngineOption (..),
  )
import Agentic.Plan (Q (..), Request, SCode (SFlag, SStructured, SText), consultRequest, observeRequest, scopeUnit)
import Agentic.Plan.Decision
  ( DecisionForm (ChoiceForm, ScaleForm, YesNoForm),
    DecisionQuestion (..),
    renderDecisionPrompt,
  )
import Agentic.Planning (Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec), Code (CodeStructured))
import Agentic.Runtime (WorldIO (worldAskIO), engineRequest, renderRequest, scriptedWorld)
import Agentic.Schema (Schema (SchemaNumber, SchemaObject, SchemaProperty), schemaNumber, schemaObject, schemaProperty)
import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)

decisionRequestTests :: IO ()
decisionRequestTests = do
  expect "a yes/no model ask carries its decision" $
    decisionAt yesNoCode (ask (AddrModel "probe") yesNoPrompt) == Just yesNoDecision
  expect "a choice model ask carries its decision, with descriptions" $
    decisionAt choiceCode (ask (AddrModel "probe") choicePrompt) == Just choiceDecision
  expect "a scale model ask carries its decision" $
    decisionAt scaleCode (ask (AddrModel "probe") scalePrompt) == Just scaleDecision
  expect "an observation at a model carries its decision" $
    engineDecision (engineRequest yesNoCode (observeRequest (question (AddrModel "probe") yesNoPrompt))) == Just yesNoDecision
  expect "the decision leaves the prompt the engine reads unchanged" $
    enginePrompt (engineRequest yesNoCode (ask (AddrModel "probe") yesNoPrompt))
      == renderRequest yesNoCode (ask (AddrModel "probe") yesNoPrompt)
  expect "a request with a decision survives the engine request codec" $
    let request = engineRequest choiceCode (ask (AddrModel "probe") choicePrompt)
     in decodeEngineRequest (encodeEngineRequest request) == Right request

  expect "the same prompt at a schema with the options reordered carries none" $
    decisionAt reversedCode (ask (AddrModel "probe") yesNoPrompt) == Nothing
  expect "the same prompt at another decision's schema carries none" $
    decisionAt choiceCode (ask (AddrModel "probe") yesNoPrompt) == Nothing
  expect "the same prompt at text carries none" $
    decisionAt SText (ask (AddrModel "probe") yesNoPrompt) == Nothing
  expect "the same prompt at a flag carries none" $
    decisionAt SFlag (ask (AddrModel "probe") yesNoPrompt) == Nothing
  expect "the same prompt to a tool carries none" $
    decisionAt yesNoCode (ask (AddrTool "probe") yesNoPrompt) == Nothing
  expect "the same prompt to an executed tool carries none" $
    decisionAt yesNoCode (ask (AddrToolExec "probe" "true" []) yesNoPrompt) == Nothing
  expect "the same prompt to a person carries none" $
    decisionAt yesNoCode (ask (AddrPerson "owner") yesNoPrompt) == Nothing
  expect "a plain ask at the decision's schema carries none" $
    decisionAt yesNoCode (ask (AddrModel "probe") "Is this message about billing?\n") == Nothing
  expect "a plain text ask carries none" $
    decisionAt SText (ask (AddrModel "probe") "Summarize the message.") == Nothing
  expect "a parsing prompt for an invalid question carries none" $
    decisionAt invalidCode (ask (AddrModel "probe") invalidPrompt) == Nothing

  let world = scriptedWorld [(yesNoInstructions, "{\"False\":0.1,\"True\":0.9}"), ("Which team should handle this message?", "{\"Billing\":2,\"Outage\":1,\"Other\":1}")]
  yesNoAnswer <- worldAskIO world yesNoCode (ask (AddrModel "probe") yesNoPrompt)
  expect ("the scripted world answers a yes/no decision by its instructions: " <> show yesNoAnswer) $
    yesNoAnswer == (1 / 10, (9 / 10, ()))
  choiceAnswer <- worldAskIO world choiceCode (ask (AddrModel "probe") choicePrompt)
  expect ("the scripted world answers a choice by the first line of its instructions: " <> show choiceAnswer) $
    choiceAnswer == (2, (1, (1, ())))
  putStrLn "decision request checks passed: the engine decision is carried exactly for a model ask with a decision prompt at its schema, and the scripted world answers it"

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

type YesNo = 'SchemaProperty "False" 'SchemaNumber ('SchemaProperty "True" 'SchemaNumber 'SchemaObject)

type Reversed = 'SchemaProperty "True" 'SchemaNumber ('SchemaProperty "False" 'SchemaNumber 'SchemaObject)

type Choice = 'SchemaProperty "Billing" 'SchemaNumber ('SchemaProperty "Outage" 'SchemaNumber ('SchemaProperty "Other" 'SchemaNumber 'SchemaObject))

type Scale = 'SchemaProperty "Low" 'SchemaNumber ('SchemaProperty "Medium" 'SchemaNumber ('SchemaProperty "High" 'SchemaNumber 'SchemaObject))

type Invalid = 'SchemaProperty "Yes" 'SchemaNumber ('SchemaProperty "No" 'SchemaNumber 'SchemaObject)

yesNoCode :: SCode ('CodeStructured YesNo)
yesNoCode = SStructured (schemaProperty @"False" schemaNumber (schemaProperty @"True" schemaNumber schemaObject))

reversedCode :: SCode ('CodeStructured Reversed)
reversedCode = SStructured (schemaProperty @"True" schemaNumber (schemaProperty @"False" schemaNumber schemaObject))

choiceCode :: SCode ('CodeStructured Choice)
choiceCode =
  SStructured
    (schemaProperty @"Billing" schemaNumber (schemaProperty @"Outage" schemaNumber (schemaProperty @"Other" schemaNumber schemaObject)))

scaleCode :: SCode ('CodeStructured Scale)
scaleCode =
  SStructured
    (schemaProperty @"Low" schemaNumber (schemaProperty @"Medium" schemaNumber (schemaProperty @"High" schemaNumber schemaObject)))

invalidCode :: SCode ('CodeStructured Invalid)
invalidCode = SStructured (schemaProperty @"Yes" schemaNumber (schemaProperty @"No" schemaNumber schemaObject))

question :: Addressee -> Text -> Q c
question addressee prompt = Q addressee scopeUnit prompt 0

ask :: Addressee -> Text -> Request c
ask addressee = consultRequest . question addressee

decisionAt :: SCode c -> Request c -> Maybe EngineDecision
decisionAt code = engineDecision . engineRequest code

yesNoInstructions :: Text
yesNoInstructions = "Is this message about billing?"

yesNoEvidence :: Text
yesNoEvidence = "Options (exactly one is right):\n  Billing\nThe invoice is wrong.\n"

-- | The evidence imitates a header, which the codec keeps as evidence.
yesNoPrompt :: Text
yesNoPrompt =
  renderDecisionPrompt
    (DecisionQuestion YesNoForm yesNoInstructions (("False", "") :| [("True", "")]))
    yesNoEvidence

yesNoDecision :: EngineDecision
yesNoDecision =
  EngineDecision
    { engineDecisionForm = EngineYesNo,
      engineDecisionInstructions = yesNoInstructions,
      engineDecisionOptions = EngineOption "False" Nothing :| [EngineOption "True" Nothing],
      engineDecisionEvidence = yesNoEvidence
    }

choiceInstructions :: Text
choiceInstructions = "Which team should handle this message?\nChoose the team that owns the fix."

choicePrompt :: Text
choicePrompt =
  renderDecisionPrompt
    ( DecisionQuestion
        ChoiceForm
        choiceInstructions
        (("Billing", "a charge or a refund") :| [("Outage", ""), ("Other", "anything else\nincluding spam")])
    )
    "The service has been down since noon."

choiceDecision :: EngineDecision
choiceDecision =
  EngineDecision
    { engineDecisionForm = EngineChoice,
      engineDecisionInstructions = choiceInstructions,
      engineDecisionOptions =
        EngineOption "Billing" (Just "a charge or a refund")
          :| [EngineOption "Outage" Nothing, EngineOption "Other" (Just "anything else\nincluding spam")],
      engineDecisionEvidence = "The service has been down since noon."
    }

scalePrompt :: Text
scalePrompt =
  renderDecisionPrompt
    (DecisionQuestion ScaleForm "How urgent is this message?" (("Low", "") :| [("Medium", ""), ("High", "")]))
    ""

scaleDecision :: EngineDecision
scaleDecision =
  EngineDecision
    { engineDecisionForm = EngineScale,
      engineDecisionInstructions = "How urgent is this message?",
      engineDecisionOptions = EngineOption "Low" Nothing :| [EngineOption "Medium" Nothing, EngineOption "High" Nothing],
      engineDecisionEvidence = ""
    }

-- | A yes/no header over options other than False and True parses, and
-- 'Agentic.Plan.Decision.validDecisionQuestion' refuses it.
invalidPrompt :: Text
invalidPrompt =
  renderDecisionPrompt
    (DecisionQuestion YesNoForm "Is this message about billing?" (("Yes", "") :| [("No", "")]))
    "The invoice is wrong."

expect :: String -> Bool -> IO ()
expect label ok = unless ok (fail ("decision request: " <> label))
