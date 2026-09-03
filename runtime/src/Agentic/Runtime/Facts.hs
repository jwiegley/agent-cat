{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Runtime.Facts
-- Description : Engine-neutral run facts and presentation helpers.
--
-- Hosts use this module to name and render facts supplied by a runner.  It has
-- no dependency on the workflow DSL or any concrete engine.
module Agentic.Runtime.Facts
  ( runFactName,
    runFacts,
    runFactBackends,
    runFactEngine,
    runFactRoutes,
    runFactSentinel,
    reservedInput,
    runFactRefusal,
    sessionPolicy,
    oneSessionPhrase,
    sharesOneSession,
    routeDefaultLabel,
    routedBackend,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | Validate one of the closed set of inputs supplied by the runner.
runFactName :: Text -> Text
runFactName name
  | name `elem` runFacts = name
  | otherwise =
      error
        ( "input: `"
            <> T.unpack name
            <> "` is under the `run.` prefix, which names the facts the runner supplies about the run it is making, and the facts there are "
            <> T.unpack (T.intercalate ", " runFacts)
        )

runFacts :: [Text]
runFacts = [runFactBackends, runFactEngine, runFactRoutes, runFactSentinel]

runFactBackends, runFactEngine, runFactRoutes, runFactSentinel :: Text
runFactBackends = "run.backends"
runFactEngine = "run.engine"
runFactRoutes = "run.routes"
runFactSentinel = "run.sentinel"

reservedInput :: Text -> Bool
reservedInput = T.isPrefixOf "run."

runFactRefusal :: Text -> Maybe Text
runFactRefusal name
  | name `elem` runFacts =
      Just
        ( "input '"
            <> name
            <> "' is a run fact: the runner binds it from the run it is making, and a command line cannot say what a run did. The facts are "
            <> T.intercalate ", " runFacts
            <> ", and every one of them is bound for you"
        )
  | otherwise = Nothing

sessionPolicy :: Bool -> Text
sessionPolicy freshPerQuestion
  | freshPerQuestion = "a new session per question"
  | otherwise = oneSessionPhrase

oneSessionPhrase :: Text
oneSessionPhrase = "one session for the run"

sharesOneSession :: Text -> Bool
sharesOneSession = T.isInfixOf oneSessionPhrase

routeDefaultLabel :: Text
routeDefaultLabel = "(default)"

routedBackend :: Text -> Text -> Text
routedBackend table name = case lookup name rows of
  Just backend -> backend
  Nothing -> fromMaybe "" (lookup routeDefaultLabel rows)
  where
    rows =
      [ (T.strip label, T.strip (T.drop 1 value))
      | line <- T.lines table,
        let (label, value) = T.breakOn "=" line,
        not (T.null value)
      ]
