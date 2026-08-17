{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}

module Bad2 where

import Quote (wf)
import Surface
import qualified W

-- a block whose last statement is an act, not a terminal
endsInAct :: Raw
endsInAct = workflow W.do
  _guide <- #guide =: ask (tool "cat") [wf|hello|]
  act (tool "t") [wf|do it|]
