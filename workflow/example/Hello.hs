-- | The smallest complete workflow, frozen as corpus entry @example-001@.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Hello (helloProgram) where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)
import Data.Text (Text)
-- ---------------------------------------------------------------------------
-- The small one
-- ---------------------------------------------------------------------------

-- | The small one, corpus entry @example-001@: two questions and an act.
--
-- Level @pipeline@, size 4, one path, @codes [text, text, receipt]@ and both
-- bills 3. It exists so that the CLI has a subject that is not the flagship:
-- no branch, no loop, and a bill the analysis knows exactly rather than
-- bounds.
--
-- @brief@ is a @define@ — here a @where@ binding, which the @[wf|…|]@ holes
-- find in the ordinary lexical scope, exactly as they find the block's own
-- binders — so it contributes a chunk of its own to each of the first two
-- prompts, unfused with the literal beside it.
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
    -- @define brief = "Reply in one short line."@
    brief :: Text
    brief = "Reply in one short line."
