-- | The three frozen __call vectors__, rewritten in the authoring surface.
--
-- @Cases@ already rebuilds @module-000@, @battery-144@ and @battery-147@ in
-- "Agentic.Builder", where a function's parameters, a call's arguments and
-- every binder are spelled by hand. These are the same three entries written
-- the way an /author/ writes them — "Agentic.Workflow"'s @W.do@ block, with
-- 'Agentic.Workflow.function', 'Agentic.Workflow.call',
-- 'Agentic.Workflow.call_' and 'Agentic.Workflow.defining' — and they are here
-- because those four combinators arrived in wave 2 with nothing frozen behind
-- them: 'Example.Harden' exercises the block, and no pinned case exercised a
-- /call/ written in the surface at all.
--
-- Each one is checked exactly as its builder-written twin is — printed program
-- against @request.program@, and the whole reply against @reply@ — with the
-- one difference the surface forces: the printed program is compared __up to
-- alpha__, because the surface cannot read a Haskell binder's spelling and
-- generates @b0@, @b1@, … from depth. Function and /parameter/ names are not
-- generated and are compared exactly, which is what makes these cases say
-- something the two walked examples cannot: @lib.drafted@, @goal@,
-- @applied@ and @patch@ all print, and the argument each call passes is
-- pinned by name.
--
-- __These are conformance fixtures, not examples.__ They are private to
-- @tier1@ — not in the @examples@ internal library, so @agentic-run@ cannot
-- see them and its registry cannot grow a row nobody would want to run.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}

module CallVectors
  ( module000W,
    battery144W,
    battery147W,
  )
where

-- `RebindableSyntax` is what makes an authoring module an authoring module,
-- and it costs this one its implicit `Prelude` — hence `fromString` by name,
-- which is what `OverloadedStrings` then reaches for. Unlike
-- "Example.Harden", nothing here needs `Prelude` itself back: these three
-- programs use no operator and no literal that is not a string.
import Data.String (fromString)
import Data.Text (Text)

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W

-- ---------------------------------------------------------------------------
-- module-000 — a value call, and a define spliced beside a hole
-- ---------------------------------------------------------------------------

-- | @function lib.drafted (goal : text) -> text { d <- ask model "author"
-- "draft: {goal}"; answer d }@ — the library function after the import walk.
--
-- @'takes' \@\"goal\"@ is the one place this surface asks for a name at the
-- type level, and it asks because a parameter's name is printed twice: in
-- @params@, and in every hole of the body that reads it.
libDrafted :: Fn '[ 'CodeText] 'CodeText
libDrafted = function "lib.drafted" (takes @"goal" Text noParams) \goal -> W.do
  d <- ask (model "author") [wf|draft: {goal}|]
  answer d

-- |
-- > import lib
-- > workflow {
-- >   x <- lib.drafted lib.guide
-- >   ask tool "t" "use {x} {lib.greeting}"
-- > }
--
-- The post-import-walk form, which is what the checker sees and what the
-- frozen entry holds: the library's priming question is an annotated binding
-- ahead of the block, and the @define@ has already expanded into a literal
-- chunk of its own. @greeting@ below is an ordinary Haskell binding and
-- @[wf|…|]@ splices it as that separate chunk, so the act's prompt is four
-- chunks — @\"use \"@, the hole, @\" \"@, @\"hello\"@ — with two adjacent
-- literals that are deliberately not fused.
module000W :: Program
module000W = defining [SomeFn libDrafted] W.do
  guide <- ask (tool "cat") [wf|style guide|] `annotated` Text
  x <- call libDrafted (arg guide :> noArgs)
  act (tool "t") [wf|use {x} {greeting}|]
  stop
  where
    greeting :: Text
    greeting = "hello"

-- ---------------------------------------------------------------------------
-- battery-144 — a statement call of a procedure
-- ---------------------------------------------------------------------------

-- | @function mk (goal : text) -> text@ — declared, never called.
fnMk :: Fn '[ 'CodeText] 'CodeText
fnMk = function "mk" (takes @"goal" Text noParams) \goal -> W.do
  d <- ask (model "author") [wf|draft: {goal}|]
  answer d

-- | @function judged (patch : text) -> verdict@ — declared, never called. Its
-- body's one question has no other way to say what kind it answers, which is
-- what @\`answering\` Verdict@ is for; it prints nothing, and @ann@ stays
-- @null@.
fnJudged :: Fn '[ 'CodeText] 'CodeVerdict
fnJudged = function "judged" (takes @"patch" Text noParams) \patch -> W.do
  v <- ask (model "judge") [wf|judge: {patch}|] `answering` Verdict
  answer v

-- | @function applied (patch : text) -> receipt@ — a body that is a single act
-- and whose printed @answer@ is @null@. 'done' is the terminal that says so.
fnApplied :: Fn '[ 'CodeText] 'CodeAck
fnApplied = function "applied" (takes @"patch" Text noParams) \patch -> W.do
  act (tool "apply") [wf|apply: {patch}|]
  done

-- |
-- > workflow { d : text <- ask tool "t" "w"
-- >  applied d }
--
-- 'call_' is the statement call: it adds no context slot (contrast the act,
-- which does), and @fnAsks@ counts all three declared functions though only
-- one is called.
battery144W :: Program
battery144W = defining [SomeFn fnMk, SomeFn fnJudged, SomeFn fnApplied] W.do
  d <- ask (tool "t") [wf|w|] `annotated` Text
  call_ fnApplied (arg d :> noArgs)
  stop

-- ---------------------------------------------------------------------------
-- battery-147 — a function answers a flag, and the block is empty
-- ---------------------------------------------------------------------------

-- | @function f (p : text) -> flag { x <- confirm model "m" "{p}"; answer x }@.
-- 'confirm' fixes the kind by itself, so no annotation is needed anywhere.
fnF :: Fn '[ 'CodeText] 'CodeFlag
fnF = function "f" (takes @"p" Text noParams) \p -> W.do
  x <- confirm (model "m") [wf|{p}|]
  answer x

-- |
-- > workflow { }
--
-- The bottom of the level lattice with a function table above it: @batch@,
-- size 1, no ask node at all, and @fnAsks@ still counting @f@'s one question.
battery147W :: Program
battery147W = defining [SomeFn fnF] stop
