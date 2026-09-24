-- |
-- Module      : Capital
-- Description : A model's answer processed by tools the runner answers in process.
--
-- 'capitalProgram' asks a model one question, saves the answer, transforms it,
-- and passes the transformed text to the next statement. The three tools are
-- named symbolically here. The registry binds each name to a Haskell function,
-- and a live run calls those functions in place of any backend.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}

module Capital (capitalProgram) where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import Data.String (fromString)

-- | Ask for a capital, save the answer, shout it, and announce the shouted
-- form.
--
-- Level @pipeline@, size 5, four ask nodes, @codes [text, receipt, text,
-- receipt]@, and both bills 4. The save is an act, so the shout that follows
-- it starts only after the file is written.
capitalProgram :: Program
capitalProgram = workflow W.do
    capital <- ask (model "geographer") [wf|
        What is the capital of France?
        Reply with the city name only.|]

    act (tool "save") [wf|{capital}|]

    shouted <- ask (tool "shout") [wf|{capital}|]

    ask_ (tool "announce") [wf|
        Announce this:
        {shouted}|]
