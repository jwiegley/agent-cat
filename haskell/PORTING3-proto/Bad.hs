{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}

module Bad where

import Quote (wf)
import Surface
import qualified W

-- 1. a block that does not end in a terminal
noTerminal :: Raw
noTerminal = workflow W.do
  _guide <- #guide =: ask (tool "cat") [wf|hello|]
  #x =: ask (tool "cat") [wf|hello|]

-- 2. shadowing a live name
shadow :: Raw
shadow = workflow W.do
  _a <- #guide =: ask (tool "cat") [wf|hello|]
  _b <- #guide =: ask (tool "cat") [wf|hello|]
  stop

-- 3. a hole naming something that is not in scope here
outOfScope :: Raw
outOfScope = workflow W.do
  ok <- #ok =: confirm (person "owner") [wf|yes or no?|]
  ifFlag ok stop stop
  where
    _unused = ()

-- 4. served by on a tool
servedTool :: Ask s
servedTool = ask (tool "cat" `servedBy` "deep") [wf|hello|]

-- 5. something after a terminal
afterStop :: Raw
afterStop = workflow W.do
  stop
  _x <- #x =: ask (tool "cat") [wf|hello|]
  stop

-- 6. a flag spliced into a prompt
flagHole :: Raw
flagHole = workflow W.do
  ok <- #ok =: confirm (person "owner") [wf|yes or no?|]
  act (tool "t") [wf|{ok}|]
  stop
