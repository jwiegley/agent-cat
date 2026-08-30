{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}

module Hello (helloProgram) where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.Text (Text)

helloProgram :: Program
helloProgram = workflow W.do
    subject <- ask (tool "cat") [wf|
        Name one thing worth greeting.
        {brief}|]

    greeting <- ask (model "greeter") [wf|
        Write a greeting for this, and nothing else:
        {subject}
        {brief}|]

    ask_ (tool "say") [wf|
        Say it:
        {greeting}|]
  where
    brief :: Text
    brief = "Reply in one short line."
