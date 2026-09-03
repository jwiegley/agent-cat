-- |
-- Module      : Structured
-- Description : Model-generated JSON decoded into typed Haskell data.
--
-- 'structuredProgram' shows the normal authoring path: 'deriveSchema' derives
-- the carried schema, witness, and total conversion from the record declaration.
-- Execution accepts only matching JSON; 'consumeModelJson' decodes the same
-- bytes directly into the ordinary Haskell record.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Structured
  ( structuredProgram,
    structuredResultProgram,
    producerBrief,
    ReleasePlan (..),
    consumeModelJson,
    summarizeReleasePlan,
  )
where

import Agentic.Schema.Json (decodeAs)
import Agentic.Schema.TH (deriveSchema)
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import Prelude

data ReleasePlan = ReleasePlan
  { title :: Text,
    priority :: Integer,
    steps :: [Text]
  }
  deriving (Eq, Show)

$(deriveSchema ''ReleasePlan)

consumeModelJson :: Text -> Maybe ReleasePlan
consumeModelJson = decodeAs @ReleasePlan

summarizeReleasePlan :: ReleasePlan -> Text
summarizeReleasePlan plan =
  title plan
    <> " (priority "
    <> T.pack (show (priority plan))
    <> "): "
    <> T.intercalate "; " (steps plan)

-- | The same typed question, returned from the whole program rather than only
-- retained in its trace.
structuredResultProgram :: ProgramOf ('CodeStructured (SchemaOf ReleasePlan))
structuredResultProgram = workflow W.do
  plan <-
    ask (model "structured-producer") [wf|{producerBrief}|]
      `annotated` (structured @ReleasePlan)
  answer plan

producerBrief :: Text
producerBrief =
  [wft|
  Produce a small release plan with concise, actionable steps. Reply only in
  the structured format requested by the attached schema.|]

-- | A model question whose answer schema is derived from 'ReleasePlan'.
structuredProgram :: Program
structuredProgram = workflow W.do
  _plan <-
    ask (model "structured-producer") [wf|{producerBrief}|]
      `annotated` (structured @ReleasePlan)
  stop
