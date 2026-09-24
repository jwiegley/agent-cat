{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Main (main) where

import Agentic.Cli (Registry (..), Row (..), Tool, cliMain, receiptTool, textTool)
import Agentic.Runtime.Facts (runFactName, runFactRoutes)
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.FilePath ((</>))
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
          ("in-process", toolRow inProcessProgram [("record", recordTool)]),
          ("in-process-mismatch", toolRow mismatchProgram [("record", textTool (\_ words' -> pure words'))]),
          ("plain-tool", toolRow plainToolProgram [])
        ]
    }
  where
    row example = Row example "fixture" "Routing fixed-point fixture." [("fixed-point", "ok")] []
    toolRow program = Row (Fixed program) "fixture" "In-process tool fixture." [("fixed-point", "ok")]

-- | Writes its words to @record.txt@ in the run's working directory.
recordTool :: Tool
recordTool = receiptTool (\dir words' -> TIO.writeFile (dir </> "record.txt") words')

-- | A pinned model question whose answer an in-process tool records. Routing
-- covers the model, and nothing routes the tool.
inProcessProgram :: Program
inProcessProgram = workflow W.do
  capital <- ask (model "geographer" `servedBy` "deep") [wf|What is the capital of France?|]
  ask_ (tool "record") [wf|{capital}|]

-- | A tool no row answers in process, so a routing-only run has no backend for
-- it.
plainToolProgram :: Program
plainToolProgram = workflow W.do
  ask_ (tool "lookup") [wf|hello|]

-- | A tool registered to answer text, asked in statement position.
mismatchProgram :: Program
mismatchProgram = workflow W.do
  ask_ (tool "record") [wf|hello|]

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

pinnedProgram :: Text -> Program
pinnedProgram pin = workflow W.do
  _answer <- ask (model "fixed-point" `servedBy` pin) [wf|fixed-point|]
  stop
