{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Main (main) where

import Agentic.Cli (Registry (..), Row (..), cliMain)
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
          ("cyclic", row cyclicExample)
        ]
    }
  where
    row example = Row example "fixture" "Routing fixed-point fixture." [("fixed-point", "ok")]

convergentExample :: Example
convergentExample =
  Needs $ taking (input runFactRoutes :> noInputs) \_ -> pinnedProgram "deep"

cyclicExample :: Example
cyclicExample =
  Needs $ taking (input runFactRoutes :> noInputs) cyclicProgram

cyclicProgram :: Text -> Program
cyclicProgram routesText
  | "deep =" `T.isInfixOf` routesText = pinnedProgram "other"
  | otherwise = pinnedProgram "deep"

pinnedProgram :: Text -> Program
pinnedProgram pin = workflow W.do
  _answer <- ask (model "fixed-point" `servedBy` pin) [wf|fixed-point|]
  stop
