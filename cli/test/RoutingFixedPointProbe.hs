{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Main (main) where

import Agentic.Cli (Registry (..), Row (..), cliMain)
import Agentic.Runtime.Facts (runFactName, runFactRoutes)
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
        [ ("convergent", row convergentExample),
          ("cyclic", row cyclicExample),
          ("controlled", row controlledExample),
          ("controlled-single", row controlledSingleExample)
        ]
    }
  where
    row example = Row example "fixture" "Routing fixed-point fixture." [("fixed-point", "ok")]

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

pinnedProgram :: Text -> Program
pinnedProgram pin = workflow W.do
  _answer <- ask (model "fixed-point" `servedBy` pin) [wf|fixed-point|]
  stop
