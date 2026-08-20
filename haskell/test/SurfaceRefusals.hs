-- | Four programs the authoring surface __refuses to make__, each written the
-- way an author would write the mistake.
--
-- Every one of these is a bottom: forcing the 'Program' raises an 'ErrorCall'
-- carrying the refusal's wording. They are values here rather than expressions
-- inside @PolicyProbe@ because @RebindableSyntax@ is what an authoring module
-- is, and it is module-wide — a probe harness that enabled it would find its
-- own @if@ reaching 'Agentic.Workflow.ifThenElse'. So the mistakes live in the
-- surface, and @PolicyProbe@ forces them from ordinary Haskell.
--
-- What each pins is not that /an/ error is raised but /which/ one: these are
-- refusals a person reads at the point of the mistake, and their words are the
-- whole of what they are worth. The first two cannot be type errors — a
-- function table is a list, and a list cannot say in its type that no name
-- repeats or that every call names an entry of it — and the last two are names
-- the surface reserves rather than kinds it rejects.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}

module SurfaceRefusals
  ( twoOfOneName,
    callsAnUnlistedFunction,
    namedIsReserved,
    takesIsReserved,
    inputIsMisspelledRunFact,
  )
where

-- As in @tier1/CallVectors.hs@: `RebindableSyntax` costs this module its
-- implicit `Prelude`, and `OverloadedStrings` then needs `fromString` by name.
import Data.Either (Either (..))
import Data.Function (const)
import Data.List (map)
import Data.String (fromString)
import Data.Text (Text, unpack)
import GHC.Err (error)

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W

-- | An ordinary, well-formed function under whatever name it is given, so that
-- what each program below is refused /for/ is the one thing that program does
-- wrong.
drafted :: Text -> Fn '[ 'CodeText] 'CodeText
drafted nm = function nm (takes @"goal" Text noParams) \goal -> W.do
  d <- ask (model "author") [wf|draft: {goal}|]
  answer d

-- | Two entries of the table answering to one name.
--
-- Not a duplicate Haskell binding — it is one value listed twice, which is how
-- the mistake actually happens: a table assembled from a list somebody edited.
-- @tier0@ replays the corresponding corpus refusal (@vector-000@); this pins
-- that the /authoring/ surface says so too, before anything is printed.
twoOfOneName :: Program
twoOfOneName = defining [SomeFn (drafted "twin"), SomeFn (drafted "twin")] stop

-- | A block that calls a function the table was not given.
--
-- The call type-checks — a 'Fn' is a Haskell value and calling it is ordinary
-- application — so nothing but this check stands between the author and a
-- printed program naming a function that does not exist.
callsAnUnlistedFunction :: Program
callsAnUnlistedFunction = workflow W.do
  goal <- ask (tool "cat") [wf|what to draft|]
  d <- call (drafted "unlisted") (arg goal :> noArgs)
  act (tool "t") [wf|use {d}|]
  stop

-- | 'named', given one of the names the surface generates for itself.
namedIsReserved :: Program
namedIsReserved = workflow W.do
  x <- named "b1" (ask (tool "cat") [wf|style guide|])
  act (tool "t") [wf|use {x}|]
  stop

-- | A function whose /parameter/ is one of those same names.
--
-- The other half of the claim 'Agentic.Workflow.reserved' makes: a parameter's
-- name is written by the author and never passes through the generator, so a
-- parameter called @b1@ would be a second @b1@ wherever the generator reaches
-- depth 1, and the two would print alike.
reservedParam :: Fn '[ 'CodeText] 'CodeText
reservedParam = function "shadowing" (takes @"b1" Text noParams) \p -> W.do
  d <- ask (model "author") [wf|draft: {p}|]
  answer d

-- | 'reservedParam', in a table, which is where it is first forced.
takesIsReserved :: Program
takesIsReserved = defining [SomeFn reservedParam] stop

-- | An 'input' under the runner's own prefix, misspelled.
--
-- @run.backends@ is a fact the runner binds; @run.backend@ is nothing at all,
-- and a program declaring it would elaborate, price and print perfectly well
-- and then refuse every @run@ of itself — because @run@ needs every input and
-- the runner has no such fact to give. So the refusal belongs where the name is
-- written, which is here.
--
-- It is forced the way the runner forces it: 'inputNames' is the first thing a
-- command line reads, and a program is what the harness knows how to force, so
-- the inputs are read and then supplied empty.
inputIsMisspelledRunFact :: Program
inputIsMisspelledRunFact =
  case supply par (map (const "") (inputNames par)) of
    Right p -> p
    Left why -> error (unpack why)
  where
    par = taking (input "run.backend" :> noInputs) \b -> workflow W.do
      act (tool "t") [wf|reach: {b}|]
      stop
