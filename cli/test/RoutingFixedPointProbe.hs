{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Main (main) where

import Agentic.Cli (Registry (..), Row (..), cliMain)
import Agentic.Runtime.Facts (runFactEngine, runFactName, runFactRoutes, sharesOneSession)
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Prelude

main :: IO ()
main = cliMain registry

registry :: Registry
registry =
  Registry
    { regBinary = "routing-fixed-point-probe",
      regNoun = "fixture",
      regBanner = "routing fixed-point fixture",
      regRows =
        [ ("pinned", row (Fixed (pinnedProgram "deep"))),
          ("convergent", row convergentExample),
          ("cyclic", row cyclicExample),
          ("controlled", row controlledExample),
          ("controlled-single", row controlledSingleExample),
          ("person-controlled", row personControlledExample),
          ("parallel-person", row (Needs $ taking (input "input" :> noInputs) parallelPersonProgram)),
          ("prompt-source", row (Needs $ taking (input "input" :> noInputs) sourceProgram)),
          ("tail-source", row (Needs $ taking (argsInputAs "input" :> noInputs) sourceProgram)),
          ("stdin-source", row (Needs $ taking (stdinInputAs "input" :> noInputs) sourceProgram)),
          ("target-sensitive", row (Needs $ taking (input (runFactName runFactEngine) :> noInputs) targetSensitiveProgram))
        ]
    }
  where
    row example = Row example "fixture" "Routing fixed-point fixture." [("fixed-point", "ok")]

targetSensitiveProgram :: Text -> Program
targetSensitiveProgram engine
  | sharesOneSession engine = sourceProgram "shared"
  | otherwise = workflow W.do
      _first <- ask (model "fixed-point") [wf|fixed-point first|]
      _second <- ask (model "fixed-point") [wf|fixed-point second|]
      stop

sourceProgram :: Text -> Program
sourceProgram body = workflow W.do
  _answer <- ask (model "fixed-point") [wf|fixed-point source: {body}|]
  stop

convergentExample :: Example
convergentExample =
  Needs $ taking (input (runFactName runFactRoutes) :> noInputs) \_ -> pinnedProgram "deep"

cyclicExample :: Example
cyclicExample =
  Needs $ taking (input (runFactName runFactRoutes) :> noInputs) cyclicProgram

cyclicProgram :: Text -> Program
cyclicProgram routesText
  | "deep =" `T.isInfixOf` routesText = pinnedProgram "other"
  | otherwise = pinnedProgram "deep"

controlledExample :: Example
controlledExample =
  Needs $ taking (stdinInput :> noInputs) controlledProgram

controlledProgram :: Text -> Program
controlledProgram body = workflow W.do
  _approved <-
    confirm
      (model "controlled" `servedBy` "primary" `fallingBackTo` "spare")
      [wf|Apply this patch? {body}|]
  stop

controlledSingleExample :: Example
controlledSingleExample =
  Needs $ taking (stdinInput :> noInputs) controlledSingleProgram

controlledSingleProgram :: Text -> Program
controlledSingleProgram body = workflow W.do
  _approved <- confirm (model "controlled" `servedBy` "primary") [wf|Apply this patch? {body}|]
  stop

personControlledExample :: Example
personControlledExample =
  Needs $ taking (stdinInput :> noInputs) personControlledProgram

personControlledProgram :: Text -> Program
personControlledProgram body = workflow W.do
  _first <- confirm (person "first") [wf|First approval? {body}|]
  _second <- confirm (person "second") [wf|Second approval? {body}|]
  stop

-- Genuine independent branches for manager observation, not synthetic envelopes.
parallelPersonProgram :: Text -> Program
parallelPersonProgram body = workflow W.do
  _answers <- panelText
    [("engine", ask (model "reviewer") [wf|Review concurrently: {body}|]),
     ("person", ask (person "owner") [wf|Mandatory concurrent answer: {body}|])]
  stop

pinnedProgram :: Text -> Program
pinnedProgram pin = workflow W.do
  _answer <- ask (model "fixed-point" `servedBy` pin) [wf|fixed-point|]
  stop
