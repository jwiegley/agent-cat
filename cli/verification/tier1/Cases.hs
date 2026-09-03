-- | Tier 1: the rebuilt corpus cases.
--
-- Each case below is one /checked/ corpus entry, rebuilt in the combinators of
-- "Agentic.Builder" and paired with the basename of
-- the frozen entry it must reproduce. This module owns nothing but that list —
-- and one more, 'callVectorsW', which rebuilds three of the same entries in
-- the /authoring/ surface instead: @tier1/Main.hs@ owns every comparison.
--
-- One row of the list is not written here and not written in the builder
-- either: the yield vector's program is 'LoopVectors.semantic008W', in the
-- authoring surface, because @RebindableSyntax@ is module-wide and this module
-- is not an authoring module. It is a row of 'cases' rather than of
-- 'callVectorsW' because its entry is one no other case takes.
--
-- The surface source of each case is quoted above it, transcribed from the
-- corpus entry's @request.program@ rather than invented, so that a reading
-- disagreement shows up as a printed-Raw mismatch and not as a silently
-- different program. Positions are not transcribed: the builder prints @0:0@
-- everywhere and tier1 zeroes both sides.
--
-- __Worlds are not written here.__ A case is a program; the worlds it is run
-- against are read from the entry's @request.worlds@ by the runner. That is
-- why three entries below rebuild to a program another entry already rebuilds:
-- the corpus pairs one program with several worlds to reach several paths
-- through "Agentic.World", and duplicating the program text here would let the
-- two copies drift apart while both stayed green.
--
-- == What is deliberately absent
--
-- The guard vectors and every refused battery entry are /unrepresentable/ in
-- the builder, and that is the point — do not "fix" the builder to reach them:
--
--   * @vector-000@ (duplicate function names) is a duplicate Haskell binding;
--   * @vector-003@ (question budget) needs 8192 questions;
--   * @vector-004@ (empty panel) is not a 'Data.List.NonEmpty.NonEmpty', and
--     @battery-202@ (an empty /text/ panel) is not one either;
--   * @vector-005@ (served by on a tool) has no constructor, and neither does
--     @battery-218@ (served by on a tool that runs a command);
--   * @battery-212@ and @battery-213@ (a decider with no needles, and with an
--     empty one) are refused by 'Agentic.Workflow.decide' at the value level
--     and are not reachable through 'Agentic.Builder.decide'\'s
--     'Data.List.NonEmpty.NonEmpty' at all;
--   * @battery-203@ and @battery-204@ (two members of one name, and a label
--     with a bad character) are label well-formedness, which the builder does
--     not check — the labels it prints are the author's, and Lean refuses a
--     bad one;
--   * @battery-215@ (a decider whose subject is not text) is a type error,
--     because 'Agentic.Builder.decide' takes a @V h \'CodeText@;
--   * every @unbound@ / @freshName@ / kind refusal is a type error.
--
-- tier0 already replays all of them through "Agentic.Guards".
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Cases (cases, alphaNamed, callVectorsW) where

import Data.List.NonEmpty (NonEmpty (..))

import CallVectors (battery144W, battery147W, module000W)
import Harden (hardenProgram)
import Hello (helloProgram)
import LoopVectors (semantic008W)

import Agentic.Builder
  ( Args (ACons, ANil),
    Code (..),
    Fn,
    Program,
    SomeFn (SomeFn),
    act,
    actB,
    answerB,
    argName,
    askModel,
    askModelServed,
    askPerson,
    askTool,
    askToolRunning,
    bind,
    bindAsI,
    bindAs,
    bindB,
    callStmt,
    callV,
    caseVerdict,
    decide,
    draw,
    endB,
    function,
    hole,
    ifFlag,
    knownHere,
    lit,
    noParams,
    one,
    oneAt,
    panel,
    panelText,
    param,
    program,
    revisingCase,
    revisingOnCase,
    stop,
  )
import Agentic.DSL (Decider (LastNonEmptyLineIs))
import Agentic.Schema
  ( SCode (SStructured),
    Schema (SchemaInteger, SchemaObject, SchemaProperty, SchemaString),
    SchemaWitness,
    schemaInteger,
    schemaObject,
    schemaProperty,
    schemaString,
  )

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

-- | The rebuilt cases, each with the basename of the corpus entry it
-- reproduces. @tier1@ resolves each name against the corpus directory it is
-- given.
cases :: [(FilePath, Program)]
cases =
  [ ("semantic-000-sharing-one-binding-holed-three-times.json", semantic000),
    ("semantic-001-a-loop-that-settles-at-round-two.json", semantic001),
    ("semantic-002-draws-are-distinct-questions.json", semantic002),
    ("semantic-003-a-flag-carrier-loop.json", semantic003),
    ("schema-000-structured-answer.json", schema000),
    ("battery-113-three-panel-members-answered-differently.json", battery113),
    ("battery-117-two-draws-of-one-prompt-are-two-questions.json", battery117),
    ( "battery-119-served-by-and-independent-draw-together-in-every-ask-position.json",
      battery119
    ),
    ("battery-107-known-here-innermost-first.json", battery107),
    ("module-000-an-import-a-dotted-call-a-dotted-define-in-a-hole.json", module000),
    ("battery-144-a-statement-call-of-a-procedure.json", battery144),
    ("vector-002-blockasks-graft-at-depth.json", vector002),
    ("battery-121-a-bounded-revision-whose-candidate-is-not-text.json", battery121),
    -- The thirteenth is the first of two cheap extras beyond the twelve this
    -- runner was first scoped to: the bound-zero loop, whose unroll is the
    -- @| 0 =>@ clause and nothing else.
    ("battery-120-a-revision-bounded-at-zero-amendments.json", battery120),
    -- The second cheap extra: the parsed-surface twin of case 11, at
    -- bound 1 in both loops rather than 2 and 3.
    ("battery-090-a-loop-nested-in-a-settled-arm.json", battery090),
    -- Two cases beyond that list, added because those twelve leave the
    -- bottom of the level lattice and the empty term untested. See each note.
    ("battery-137-empty-prompts-and-an-empty-define.json", battery137),
    ("battery-147-a-function-may-answer-a-flag-the-caller-branches.json", battery147),
    -- The last three are the corpus's newest entries, and they are here for
    -- their __worlds__: between them they are the only reach into 'byPrefix',
    -- into a 'Agentic.World.Declined' verdict, into 'promptEq' and into a
    -- constant text world, and the only mid-loop settle in the corpus. Their
    -- programs are two of the programs already above (see each note).
    ( "semantic-004-a-loop-that-truly-settles-at-round-two-byprefix-objects-to-the-first-draft-only.json",
      semantic004
    ),
    ("semantic-005-a-declined-verdict-and-a-prompteq-flag.json", semantic005),
    ("semantic-006-a-constant-text-world.json", semantic006),
    -- The last two are the walked examples, and they are the only cases here
    -- whose program is not written in this module: they are shared with the
    -- @agentic-run@ executable, which plans, prices and runs them. See the note
    -- at case 20.
    ("example-000-the-flagship-single-file.json", hardenProgram),
    ("example-001-hello.json", helloProgram),
    -- Wave three's four shapes, one case each. tier0 replays their frozen
    -- entries through the codec, the guards and the two ask counts; only here
    -- are their /elaborations/ held against the oracle — the folds, the paths
    -- and, in two of the four, the bills that are the whole point.
    ("battery-193-a-three-way-revision-settles-amends-or-abandons.json", battery193),
    ("battery-198-a-text-panel-fences-its-members-in-order.json", battery198),
    ("battery-205-a-decider-reads-the-last-non-empty-line.json", battery205),
    ("battery-219-two-commands-at-one-tool-are-two-questions.json", battery219),
    -- The one case here whose program is written in "Agentic.Workflow" and is
    -- not a second rebuild of an entry another case already takes: the yield
    -- vector, whose /unsettled/ arm reads the candidate an exhausted loop
    -- handed it. See "LoopVectors" for why it is a module of its own and why
    -- the reading is worth a new entry rather than a rewritten arm.
    ( "semantic-008-an-exhausted-loop-yields-the-last-amendment-not-the-first-draft.json",
      semantic008W
    )
  ]

type StructuredSchema =
  'SchemaProperty
    "count"
    'SchemaInteger
    ('SchemaProperty "name" 'SchemaString 'SchemaObject)

structuredTail :: SchemaWitness ('SchemaProperty "name" 'SchemaString 'SchemaObject)
structuredTail = schemaProperty @"name" schemaString schemaObject

structuredSchema :: SchemaWitness StructuredSchema
structuredSchema = schemaProperty @"count" schemaInteger structuredTail

-- | A schema-indexed question whose semantic answer is the nested product
-- `(Integer, (Text, ()))`; the JSON bytes exist only in the corpus world.
schema000 :: Program
schema000 =
  program [] $
    bindAsI (SStructured structuredSchema) "value"
      (oneAt (SStructured structuredSchema) (askModel "structured" [lit "answer structurally"])) $
      act (askTool "sink" [lit "done"]) stop

-- | Which of 'cases' have their __printed program__ compared up to alpha: the
-- two walked examples and the yield vector, and nothing else. ('callVectorsW'
-- is compared that way too, and is not listed here — every entry of that list
-- is, by construction, so there is nothing to select.)
--
-- They are written in "Agentic.Workflow", which cannot read a Haskell binder's
-- spelling — nothing but Template Haskell can, and the surface uses none — so
-- it /generates/ the name each binding prints from the binding's depth: the
-- flagship's @guide@ prints as @b0@, its carrier and settled binder as @b2@,
-- its revision's result as @r2@. That is a different program text from the
-- frozen one and the same program: @tier1/Main.hs@ canonicalizes the binders
-- of both sides before comparing, so the pin is that the two agree on
-- everything except the spelling of names, including which binding every hole,
-- every scrutinee and every subject reads.
--
-- __The other twenty-three keep their exact comparison.__ They are written in
-- "Agentic.Builder" with explicit names, and there is nothing about them to
-- weaken. Every non-program comparand — the folds, the ask counts, the worlds,
-- the traces and the bills — stays exact for all twenty-nine; a trace never
-- carries a binder's name, which is why the yield vector's whole point — the
-- prompt @\"yielded: fix draft: thin\"@ in its unsettled arm — is pinned
-- exactly even though its binders are not.
alphaNamed :: [FilePath]
alphaNamed =
  [ "example-000-the-flagship-single-file.json",
    "example-001-hello.json",
    "semantic-008-an-exhausted-loop-yields-the-last-amendment-not-the-first-draft.json"
  ]

-- | The three frozen __call vectors__ a second time, rebuilt in
-- "Agentic.Workflow" instead of in "Agentic.Builder" (see "CallVectors").
--
-- They are a separate list rather than three more rows of 'cases' because a
-- row of 'cases' is keyed by the entry it rebuilds, and these three rebuild
-- entries that are already there: putting them in 'cases' would have meant
-- either naming the same entry twice — and then 'alphaNamed', which selects by
-- that name, would have loosened the builder-written twin along with the new
-- one — or inventing a second key. Two lists cost one line in @tier1/Main.hs@
-- and keep every existing pin exactly as strong as it was.
--
-- Each is run against the same frozen entry its builder-written twin is run
-- against, and against the same worlds; only the /rule for names/ differs, and
-- it is the up-to-alpha one for all three, because the surface generates them.
callVectorsW :: [(FilePath, Program)]
callVectorsW =
  [ ("module-000-an-import-a-dotted-call-a-dotted-define-in-a-hole.json", module000W),
    ("battery-144-a-statement-call-of-a-procedure.json", battery144W),
    ("battery-147-a-function-may-answer-a-flag-the-caller-branches.json", battery147W)
  ]

-- ---------------------------------------------------------------------------
-- 1. semantic-000 — one binding, holed three times
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   g <- ask tool "cat" "read the file"
-- >   ask tool "log" "{g}||{g}"
-- >   ask tool "audit" "seen: {g}"
-- > }
--
-- Two worlds (@echo@ and @wrap "<" ">"@). The two acts each build their prompt
-- at the scope @'[ '("g", 'CodeText) ]@, and it is the /continuation/, not the
-- prompt, that each act weakens past its own receipt slot.
semantic000 :: Program
semantic000 =
  program [] $
    bind @"g" @'CodeText (one (askTool "cat" [lit "read the file"])) $ \g ->
      act (askTool "log" [hole g, lit "||", hole g]) $
        act (askTool "audit" [lit "seen: ", hole g]) $
          stop

-- ---------------------------------------------------------------------------
-- 2. semantic-001 — a bounded revision at three amendments
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   d : text <- ask model "author" "draft"
-- >   r <- revising d as patch, at most 3 amendments {
-- >     v <- ask model "critic" "review {patch}"
-- >     amend patch { ask model "author" "amend {patch} given {v}" }
-- >   }
-- >   case r { settled final { ask tool "apply" "apply {final}" }
-- >            unsettled { ask tool "log" "gave up" } }
-- > }
--
-- @d@ is annotated, so 'bindAs'. Two worlds: the approving one settles at the
-- first check (3 events), the objecting one exhausts the unroll (9 events —
-- four checks and three amendments, "check first, revise in the recursive
-- call").
semantic001 :: Program
semantic001 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "author" [lit "draft"])) $ \d ->
      revisingCase @"patch" @"v" @"final" @"final"
        d
        "r"
        3
        Nothing
        (\patch -> one (askModel "critic" [lit "review ", hole patch]))
        ( \patch v ->
            one
              ( askModel
                  "author"
                  [lit "amend ", hole patch, lit " given ", hole v]
              )
        )
        (\final -> act (askTool "apply" [lit "apply ", hole final]) stop)
        -- The unsettled binder is the settled one repeated, which is what the
        -- frozen entry carries and what an authoring surface always writes:
        -- both arms are built at one depth, so one name serves both, and they
        -- are binders in disjoint scopes rather than one binder. This arm does
        -- not read it.
        (\_final -> act (askTool "log" [lit "gave up"]) stop)

-- ---------------------------------------------------------------------------
-- 3. semantic-002 — draws are distinct questions
-- ---------------------------------------------------------------------------

-- |
-- > workflow { a : text <- ask model "m" "one"
-- >            b : text <- ask model "m" independent draw 1 "one"
-- >            ask tool "t" "{a} {b}" }
--
-- The corpus's only @byDraw@ world: the same words at two draws are two
-- questions, and the world answers each with its draw index.
semantic002 :: Program
semantic002 =
  program [] $
    bindAs @"a" @'CodeText (one (askModel "m" [lit "one"])) $ \a ->
      bindAs @"b" @'CodeText (one (draw 1 (askModel "m" [lit "one"]))) $ \b ->
        act (askTool "t" [hole a, lit " ", hole b]) $
          stop

-- ---------------------------------------------------------------------------
-- 4. semantic-003 — an if on a flag (the entry's name says "loop", and the
--    corpus's own program has none: the flag-carrier loop the name describes
--    is the one frozen as @battery-121@, which case 12 takes)
-- ---------------------------------------------------------------------------

-- |
-- > workflow { d : text <- ask tool "t" "w"
-- >   ok <- ask person "o" "go?"
-- >   if ok { ask tool "a" "went {d}" } else { stop } }
--
-- @ok@ carries no annotation: Lean infers @flag@ from the @if@, and here the
-- author supplies it at the type level. Two worlds take the two arms.
semantic003 :: Program
semantic003 =
  program [] $
    bindAs @"d" @'CodeText (one (askTool "t" [lit "w"])) $ \d ->
      bind @"ok" @'CodeFlag (one (askPerson "o" [lit "go?"])) $ \ok ->
        ifFlag
          ok
          (act (askTool "a" [lit "went ", hole d]) stop)
          stop

-- ---------------------------------------------------------------------------
-- 5. battery-113 — three panel members, then a case on the verdict
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   p <- panel, all must approve [ ask model "alpha" "check one",
-- >                                 ask model "beta" "check two",
-- >                                 ask model "gamma" "check three" ]
-- >   ask tool "log" "objections: {p}"
-- >   case p { approved { ask tool "t" "went-approved" }
-- >            objected { ask tool "t" "went-objected" }
-- >            no answer { ask tool "t" "went-noanswer" } }
-- > }
--
-- @p@ carries no annotation — a panel's kind is positional, never inferred.
-- All three members approve, so the verdict renders as the empty string and
-- the logged prompt is @"objections: "@.
battery113 :: Program
battery113 =
  program [] $
    bind @"p" @'CodeVerdict
      ( panel
          ( askModel "alpha" [lit "check one"]
              :| [ askModel "beta" [lit "check two"],
                   askModel "gamma" [lit "check three"]
                 ]
          )
      )
      $ \p ->
        act (askTool "log" [lit "objections: ", hole p]) $
          caseVerdict
            p
            (act (askTool "t" [lit "went-approved"]) stop)
            (act (askTool "t" [lit "went-objected"]) stop)
            (act (askTool "t" [lit "went-noanswer"]) stop)

-- ---------------------------------------------------------------------------
-- 6. battery-117 — two draws of one prompt are two questions
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   a <- ask model "oracle" "same words"
-- >   b <- ask model "oracle" "same words"
-- >   c <- ask model "oracle" independent draw 1 "same words"
-- >   ask tool "log" "{a}|{b}|{c}"
-- > }
--
-- One of only two corpus entries where the memo bill is strictly below the
-- fresh one: @billFresh 4@, @billMemo 3@ — the two draw-0 questions collapse,
-- the draw-1 one does not.
battery117 :: Program
battery117 =
  program [] $
    bind @"a" @'CodeText (one (askModel "oracle" [lit "same words"])) $ \a ->
      bind @"b" @'CodeText (one (askModel "oracle" [lit "same words"])) $ \b ->
        bind @"c" @'CodeText (one (draw 1 (askModel "oracle" [lit "same words"]))) $ \c ->
          act (askTool "log" [hole a, lit "|", hole b, lit "|", hole c]) $
            stop

-- ---------------------------------------------------------------------------
-- 7. battery-119 — served by and independent draw in every ask position
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   a : text <- ask model "author" served by "deep" independent draw 2 "draft it"
-- >   ask model "logger" served by "cheap" independent draw 1 "note {a}"
-- >   p <- panel, all must approve [
-- >     ask model "one" served by "deep" independent draw 3 "review {a}",
-- >     ask tool "lint" independent draw 1 "lint {a}",
-- >     ask person "owner" independent draw 2 "ok? {a}"
-- >   ]
-- >   case p { approved { stop } objected { stop } no answer { stop } }
-- > }
--
-- The corpus's only non-unit traced scopes: @served by@ reaches the shape
-- through @atModel@, setting the model axis and leaving the mode axis silent.
-- Note that the panel mixes all three parties, so an 'Agentic.Builder.Ask'
-- may not be indexed by its addressee's party.
battery119 :: Program
battery119 =
  program [] $
    bindAs @"a" @'CodeText
      (one (draw 2 (askModelServed "author" "deep" [lit "draft it"])))
      $ \a ->
        act (draw 1 (askModelServed "logger" "cheap" [lit "note ", hole a])) $
          bind @"p" @'CodeVerdict
            ( panel
                ( draw 3 (askModelServed "one" "deep" [lit "review ", hole a])
                    :| [ draw 1 (askTool "lint" [lit "lint ", hole a]),
                         draw 2 (askPerson "owner" [lit "ok? ", hole a])
                       ]
                )
            )
            $ \p -> caseVerdict p stop stop stop

-- ---------------------------------------------------------------------------
-- 8. battery-107 — known here, innermost first
-- ---------------------------------------------------------------------------

-- |
-- > workflow { a : text <- ask tool "c" "a"
-- >            b : text <- ask tool "c" "b {a}"
-- >            known here: b, a
-- >            ask tool "log" "{a} {b}" }
--
-- The assertion elaborates to nothing at all — size 4, not 5 — and its printed
-- names are computed from the type-level scope, so @b, a@ cannot be got wrong.
battery107 :: Program
battery107 =
  program [] $
    bindAs @"a" @'CodeText (one (askTool "c" [lit "a"])) $ \a ->
      bindAs @"b" @'CodeText (one (askTool "c" [lit "b ", hole a])) $ \b ->
        knownHere $
          act (askTool "log" [hole a, lit " ", hole b]) $
            stop

-- ---------------------------------------------------------------------------
-- 9. module-000 — a function, a value call, dotted names
-- ---------------------------------------------------------------------------

-- | @function lib.drafted (goal : text) -> text { d <- ask model "author"
-- "draft: {goal}"; answer d }@ — the library function after the import walk.
libDrafted :: Fn '[ 'CodeText] 'CodeText
libDrafted =
  function "lib.drafted" (param @"goal" @'CodeText noParams) $ \(goal, ()) ->
    bindB @"d" @'CodeText (one (askModel "author" [lit "draft: ", hole goal])) $ \d ->
      answerB d

-- |
-- > import lib
-- > workflow {
-- >   x <- lib.drafted lib.guide
-- >   ask tool "t" "use {x} {lib.greeting}"
-- > }
--
-- Written in the post-import-walk form the checker sees: the library's priming
-- question is spliced ahead of the workflow as an annotated binding, the
-- @define@ has already expanded into its own literal chunk (so @"use "@,
-- @{x}@, @" "@ and @"hello"@ are four chunks, two of them adjacent literals
-- that are /not/ fused), and the call inlines the callee's question with the
-- caller's argument in its prompt.
module000 :: Program
module000 =
  program [SomeFn libDrafted] $
    bindAs @"lib.guide" @'CodeText (one (askTool "cat" [lit "style guide"])) $ \guide ->
      bind @"x" @'CodeText (callV libDrafted (ACons (argName guide) ANil)) $ \x ->
        act (askTool "t" [lit "use ", hole x, lit " ", lit "hello"]) $
          stop

-- ---------------------------------------------------------------------------
-- 10. battery-144 — a statement call of a procedure
-- ---------------------------------------------------------------------------

-- | @function mk (goal : text) -> text@ — declared, never called.
fnMk :: Fn '[ 'CodeText] 'CodeText
fnMk =
  function "mk" (param @"goal" @'CodeText noParams) $ \(goal, ()) ->
    bindB @"d" @'CodeText (one (askModel "author" [lit "draft: ", hole goal])) $ \d ->
      answerB d

-- | @function judged (patch : text) -> verdict@ — declared, never called.
fnJudged :: Fn '[ 'CodeText] 'CodeVerdict
fnJudged =
  function "judged" (param @"patch" @'CodeText noParams) $ \(patch, ()) ->
    bindB @"v" @'CodeVerdict (one (askModel "judge" [lit "judge: ", hole patch])) $ \v ->
      answerB v

-- | @function applied (patch : text) -> receipt@ — a body that is a single
-- act and whose printed @answer@ is @null@.
fnApplied :: Fn '[ 'CodeText] 'CodeAck
fnApplied =
  function "applied" (param @"patch" @'CodeText noParams) $ \(patch, ()) ->
    actB (askTool "apply" [lit "apply: ", hole patch]) endB

-- |
-- > workflow { d : text <- ask tool "t" "w"
-- >  applied d }
--
-- The statement call adds no context slot (contrast the act, which does), and
-- @fnAsks@ counts all three declared functions though only one is called.
battery144 :: Program
battery144 =
  program [SomeFn fnMk, SomeFn fnJudged, SomeFn fnApplied] $
    bindAs @"d" @'CodeText (one (askTool "t" [lit "w"])) $ \d ->
      callStmt fnApplied (ACons (argName d) ANil) $
        stop

-- ---------------------------------------------------------------------------
-- 11. vector-002 — a graft at depth
-- ---------------------------------------------------------------------------

-- |
-- > workflow { d : text <- ask model "a" "draft"
-- >   r <- revising d as c, at most 2 amendments {
-- >     v <- ask model "m" "review {c}"
-- >     amend c { ask model "a" "fix {c} {v}" }
-- >   }
-- >   case r { settled x {
-- >     r2 <- revising x as c2, at most 3 amendments {
-- >       v2 <- ask model "m2" "review again {c2}"
-- >       amend c2 { ask model "a" "refix {c2} {v2}" }
-- >     }
-- >     case r2 { settled y { ask tool "t" "apply {y}" }
-- >               unsettled { stop } }
-- >   } unsettled { stop } }
-- > }
--
-- The inner loop and both of its arms are replicated once per exit of the
-- outer unroll, which is what takes the term to size 92 and 39 ask nodes. Two
-- worlds: one settles both loops at their first check (4 events), one exhausts
-- the outer loop (6 events, ending on the third review).
vector002 :: Program
vector002 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $ \d ->
      revisingCase @"c" @"v" @"x" @"x"
        d
        "r"
        2
        Nothing
        (\c -> one (askModel "m" [lit "review ", hole c]))
        (\c v -> one (askModel "a" [lit "fix ", hole c, lit " ", hole v]))
        ( \x ->
            revisingCase @"c2" @"v2" @"y" @"y"
              x
              "r2"
              3
              Nothing
              (\c2 -> one (askModel "m2" [lit "review again ", hole c2]))
              (\c2 v2 -> one (askModel "a" [lit "refix ", hole c2, lit " ", hole v2]))
              (\y -> act (askTool "t" [lit "apply ", hole y]) stop)
              (\_y -> stop)
        )
        (\_x -> stop)

-- ---------------------------------------------------------------------------
-- 12. battery-121 — a bounded revision whose candidate is a flag
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   ready : flag <- ask person "owner" "is the release ready?"
-- >   r <- revising ready as cand, at most 2 amendments {
-- >     v <- ask model "m" "does the release look ready?"
-- >     amend cand { ask person "owner" "is it ready now?" }
-- >   }
-- >   case r {
-- >     settled done { if done { ask tool "ship" "ship it" } else { stop } }
-- >     unsettled { stop }
-- >   }
-- > }
--
-- The candidate's kind is the subject's, so the amend clause elaborates at
-- @flag@ and the settled binder is a flag an @if@ may branch on. Both loop
-- clauses have closed prompts, so the unroll is full of @askC@ nodes.
battery121 :: Program
battery121 =
  program [] $
    bindAs @"ready" @'CodeFlag (one (askPerson "owner" [lit "is the release ready?"])) $
      \ready ->
        revisingCase @"cand" @"v" @"done" @"done"
          ready
          "r"
          2
          Nothing
          (\_cand -> one (askModel "m" [lit "does the release look ready?"]))
          (\_cand _v -> one (askPerson "owner" [lit "is it ready now?"]))
          (\done -> ifFlag done (act (askTool "ship" [lit "ship it"]) stop) stop)
          (\_done -> stop)

-- ---------------------------------------------------------------------------
-- 13. battery-120 — a revision bounded at zero amendments
-- ---------------------------------------------------------------------------

-- |
-- > workflow { d : text <- ask model "a" "draft"
-- >   r <- revising d as c, at most 0 amendments {
-- >     v <- ask model "m" "review {c}"
-- >     amend c { ask model "a" "fix {c} {v}" }
-- >   }
-- >   case r { settled x { ask tool "log" "settled {x}" }
-- >            unsettled { ask tool "log" "unsettled" } } }
--
-- The first cheap extra, and the only shape where the unroll is
-- the @| 0 =>@ clause /as the whole loop/: one check, then a @ret@, with no
-- per-round @caseB@ and no amendment at all. The amend clause is still
-- elaborated — it is a clause of the term, not of the trace — but no path
-- reaches it, which is why the term is size 7 with two paths and the only
-- branch is @exitCont@'s.
battery120 :: Program
battery120 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $ \d ->
      revisingCase @"c" @"v" @"x" @"x"
        d
        "r"
        0
        Nothing
        (\c -> one (askModel "m" [lit "review ", hole c]))
        (\c v -> one (askModel "a" [lit "fix ", hole c, lit " ", hole v]))
        (\x -> act (askTool "log" [lit "settled ", hole x]) stop)
        (\_x -> act (askTool "log" [lit "unsettled"]) stop)

-- ---------------------------------------------------------------------------
-- 14. battery-090 — a loop nested in a settled arm
-- ---------------------------------------------------------------------------

-- |
-- > workflow { d : text <- ask model "a" "draft"
-- >   r <- revising d as c, at most 1 amendment {
-- >     v <- ask model "m" "review {c}"
-- >     amend c { ask model "a" "fix {c} {v}" }
-- >   }
-- >   case r {
-- >     settled x {
-- >       r2 <- revising x as y, at most 1 amendment {
-- >         w <- ask model "m" "again {y}"
-- >         amend y { ask model "a" "more {y} {w}" }
-- >       }
-- >       case r2 { settled z { ask tool "log" "{z}" } unsettled { stop } }
-- >     }
-- >     unsettled { stop } }
-- > }
--
-- The second cheap extra, and the parsed-surface twin of 'vector002': the
-- same nesting at bound 1 in both loops instead of 2 and 3, which is a
-- different arithmetic on the same unroll — size 33 and 10 paths against 92 and
-- 27. A graft that replicated the inner loop the wrong number of times could
-- still hit one of the two; it cannot hit both.
battery090 :: Program
battery090 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $ \d ->
      revisingCase @"c" @"v" @"x" @"x"
        d
        "r"
        1
        Nothing
        (\c -> one (askModel "m" [lit "review ", hole c]))
        (\c v -> one (askModel "a" [lit "fix ", hole c, lit " ", hole v]))
        ( \x ->
            revisingCase @"y" @"w" @"z" @"z"
              x
              "r2"
              1
              Nothing
              (\y -> one (askModel "m" [lit "again ", hole y]))
              (\y w -> one (askModel "a" [lit "more ", hole y, lit " ", hole w]))
              (\z -> act (askTool "log" [hole z]) stop)
              (\_z -> stop)
        )
        (\_x -> stop)

-- ---------------------------------------------------------------------------
-- 15. battery-137 — empty prompts and an empty define
-- ---------------------------------------------------------------------------

-- |
-- > define empty = ""
-- > workflow { ask tool "t" ""
-- >            ask tool "t" "{empty}"
-- >            ask tool "t" "pre{empty}post" }
--
-- Beyond the twelve, for three things they never reach:
--
--   * the __bottom of the level lattice__ — every case above is @pipeline@ or
--     @branch@, and nothing pins @batch@, which is what a program of nothing
--     but closed questions folds to. All three prompts here are closed, so all
--     three elaborate to @askC@ and the whole term is one straight line;
--   * the __empty prompt__, twice: @""@ and a hole on an empty define both
--     print as @[]@ and render as @""@ (the expansion contributes no chunk,
--     rather than an empty @lit@);
--   * @billMemo@ __strictly below__ @billFresh@ /at receipt/ — 2 against 3.
--     The corpus has only two entries where the bills differ at all;
--     'battery117' (4 against 3) is the other, and there the
--     collapsing pair is two @text@ questions distinguished by draw. Here it is
--     the two empty-prompt receipts to the same tool, which are the same
--     question in every component of the memo key.
--
-- Written in the post-define-expansion form the checker sees: @"pre{empty}post"@
-- is __two adjacent literals that are not fused__, exactly as in 'module000'.
battery137 :: Program
battery137 =
  program [] $
    act (askTool "t" []) $
      act (askTool "t" []) $
        act (askTool "t" [lit "pre", lit "post"]) $
          stop

-- ---------------------------------------------------------------------------
-- 16. battery-147 — a function answering a flag, and an empty workflow
-- ---------------------------------------------------------------------------

-- | @function f (p : text) -> flag { x <- ask model "m" "{p}"; answer x }@ —
-- declared, never called, and the only case whose function answers a @flag@.
-- @x@ carries no annotation: its kind is fixed by the @answer@ against the
-- declared result, which here is the type-level result of the 'Fn'.
fnF :: Fn '[ 'CodeText] 'CodeFlag
fnF =
  function "f" (param @"p" @'CodeText noParams) $ \(p, ()) ->
    bindB @"x" @'CodeFlag (one (askModel "m" [hole p])) $ \x ->
      answerB x

-- |
-- > function f (p : text) -> flag {
-- >   x <- ask model "m" "{p}"
-- >   answer x
-- > }
-- > workflow { stop }
--
-- Beyond the twelve, for the __empty term__: @stop@ alone elaborates to a bare
-- @ret@, so this is the corpus's only entry at size 1 with @askNodes 0@,
-- @codes []@ (the empty list, which is not @null@ — a batch program with no
-- questions), @costSummary (0, 0, 1)@ and an __empty trace__ billing @(0, 0)@.
-- Every fold and both bills are exercised at their base case here and nowhere
-- else. The declared-but-uncalled function still shows up in @fnAsks@ as
-- @[["f", 1]]@, which is what makes it a count over the table rather than over
-- the reachable term.
battery147 :: Program
battery147 = program [SomeFn fnF] stop

-- ---------------------------------------------------------------------------
-- 17. semantic-004 — the same loop, under a byPrefix world that objects once
-- ---------------------------------------------------------------------------

-- | @semSrc1@ again — byte for byte the program of 'semantic001', which is why
-- this is an alias and not a second transcription. What is new is the entry's
-- single world, and it is the only place the corpus reaches three things at
-- once:
--
--   * __'Agentic.World.ByPrefix'__, the only prompt-sensitive verdict oracle.
--     Its table has one row, @\"review draft\"@, and its default is
--     @approve@ — so the /first/ check objects and every later one approves.
--     A verdict oracle that matched on equality rather than on prefix, or that
--     consulted the default first, would answer this world differently at the
--     very first event.
--
--   * __a genuine mid-loop settle__. 'semantic001' pins only the two ends of
--     its bound-3 unroll: its approving world settles at the first check (3
--     events) and its objecting world exhausts the bound (9 events). Here the
--     loop objects once and settles on the second check — 5 events, the middle
--     of the ladder — so an unroll that mis-sequenced "check first, revise in
--     the recursive call" could still hit both of 'semantic001''s worlds and
--     cannot hit this one.
--
--   * __an objecting verdict rendered into a later prompt__. The amendment's
--     @{v}@ hole renders @Object [\"too plain\"]@, so the third event's prompt
--     is @\"amend draft given too plain\"@ and the fourth's is
--     @\"review amend draft given too plain\"@ — the objection is carried
--     forward through 'Agentic.Plan.verdictRender' and through the echo text
--     world, and a wrong rendering shows up as a wrong prompt two events later
--     rather than as a wrong answer.
semantic004 :: Program
semantic004 = semantic001

-- ---------------------------------------------------------------------------
-- 18. semantic-005 — a declined verdict, and a flag that reads its own prompt
-- ---------------------------------------------------------------------------

-- |
-- > workflow {
-- >   t : text <- ask tool "reader" "read"
-- >   v : verdict <- ask model "judge" "judge"
-- >   f : flag <- ask person "owner" "yes or no?"
-- >   ask tool "recorder" "record {t} and {v}"
-- >   if f { ask tool "t" "went-yes" } else { ask tool "t" "went-no" }
-- > }
--
-- All three bindings are annotated, so all three are 'bindAs' — including
-- @f@, which 'semantic003' leaves to the @if@ to fix. One straight line of
-- three questions, an act, and a branch: size 9, two paths, both folding to 5.
--
-- The entry's single world is why this case is here. It is the corpus's only
-- reach into two world constructors:
--
--   * __a @const \"declined\"@ verdict__, the one 'Agentic.Plan.Verdict' no
--     other world produces. It matters twice over: 'Agentic.Plan.verdictRender'
--     sends @Declined@ to the /empty string/, so the recorded prompt is
--     @\"record read and \"@ with a trailing space and nothing after it — a
--     renderer that spelled the tag out, or that treated @declined@ like
--     @objected@, would be caught by that one prompt.
--
--   * __a @promptEq@ flag__, the only flag oracle that looks at the question
--     instead of answering a constant. It answers @true@ exactly when the
--     prompt is @\"yes or no?\"@; the owner's prompt is, so the trace takes
--     the @yes@ arm and ends on @\"went-yes\"@. Point the same world at any
--     other prompt and it says @false@, which is what makes it a test of the
--     prompt the plan actually asks with rather than of the arm the plan
--     happens to prefer.
semantic005 :: Program
semantic005 =
  program [] $
    bindAs @"t" @'CodeText (one (askTool "reader" [lit "read"])) $ \t ->
      bindAs @"v" @'CodeVerdict (one (askModel "judge" [lit "judge"])) $ \v ->
        bindAs @"f" @'CodeFlag (one (askPerson "owner" [lit "yes or no?"])) $ \f ->
          act
            ( askTool
                "recorder"
                [lit "record ", hole t, lit " and ", hole v]
            )
            $ ifFlag
              f
              (act (askTool "t" [lit "went-yes"]) stop)
              (act (askTool "t" [lit "went-no"]) stop)

-- ---------------------------------------------------------------------------
-- 19. semantic-006 — the same three acts, under a constant text world
-- ---------------------------------------------------------------------------

-- | @semSrc0@ again — byte for byte the program of 'semantic000', aliased for
-- the same reason 'semantic004' is. The entry's single world is the corpus's
-- only @const@ /text/ oracle: every question, whatever its prompt, is answered
-- @\"fixed answer\"@.
--
-- That is a sharper test of the sharing than either of 'semantic000''s worlds.
-- @echo@ and @wrap@ both answer a function of the prompt, so a plan that asked
-- the wrong question would be caught by the answer it got back; a constant
-- world answers the same thing either way, and the only surviving evidence is
-- the __prompt each later act builds from the shared binding__ —
-- @\"fixed answer||fixed answer\"@ and @\"seen: fixed answer\"@. The one
-- binding is still holed three times and still asked once (@billFresh 3@,
-- @billMemo 3@), so a term that re-asked @cat@ per hole would show up as a
-- longer trace even though every answer in it would be identical.
semantic006 :: Program
semantic006 = semantic000

-- ---------------------------------------------------------------------------
-- 22. battery-193 — the three-way loop (D4)
-- ---------------------------------------------------------------------------

-- |
-- > workflow { d : text <- ask model "a" "draft"
-- >   r <- revising on d as c, at most 2 amendments {
-- >     v <- ask model "m" "review {c}"
-- >     amend c { ask model "a" "fix {c} {v}" }
-- >   }
-- >   case r { settled x { ask tool "log" "settled {x}" }
-- >            unsettled y { stop }
-- >            abandoned z { stop } } }
--
-- The arithmetic D4 exists to pin, and the reason this case is worth its
-- weight: the unroll has @2n+1 = 5@ @ret@ leaves rather than @n+1 = 3@ — the
-- approve-@ret@ and the declined-@ret@ per round above the base — and the
-- three-armed exit is replicated once per leaf. So @blockAsks@ is
-- @3·1 + 2·1 + 5·(1+0+0) = 10@, @paths@ is @5·3 = 15@, and @size@ is
-- @3 + 2 + 2 + 5·5 = 32@ over the loop, plus the leading ask. A graft that
-- replicated the exit @n+1@ times instead would still typecheck and would show
-- up here as three numbers at once.
--
-- Its three binders are __three different names__ where every frozen
-- two-way loop repeats one, which is what pins that they are binders in
-- disjoint scopes rather than one binder read three ways.
battery193 :: Program
battery193 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $ \d ->
      revisingOnCase @"c" @"v" @"x" @"y" @"z"
        d
        "r"
        2
        Nothing
        (\c -> one (askModel "m" [lit "review ", hole c]))
        (\c v -> one (askModel "a" [lit "fix ", hole c, lit " ", hole v]))
        (\x -> act (askTool "log" [lit "settled ", hole x]) stop)
        (\_y -> stop)
        (\_z -> stop)

-- ---------------------------------------------------------------------------
-- 23. battery-198 — the text panel (D2)
-- ---------------------------------------------------------------------------

-- |
-- > workflow { doc : text <- panel as text [ alpha: ask model "a" "BODY-A"
-- >                                        , beta:  ask model "b" "BODY-B" ]
-- >            ask tool "log" "{doc}" }
--
-- The __document's bytes__, which nothing else pins: the world answers the two
-- members @one@ and @two@, and the act's prompt — an event of the frozen trace,
-- compared verbatim — is
-- @\<alpha\>\\none\\n\<\/alpha\>\\n\<beta\>\\ntwo\\n\<\/beta\>\\n@.
-- Member order, the fence's newlines and the fold's direction are all in that
-- one string, and the trace holds the two raw replies beside it: __the trace is
-- what was asked and what was answered; the document is what the program then
-- computed.__
battery198 :: Program
battery198 =
  program [] $
    bindAs @"doc" @'CodeText
      ( panelText
          ( ("alpha", askModel "a" [lit "BODY-A"])
              :| [("beta", askModel "b" [lit "BODY-B"])]
          )
      )
      $ \doc -> act (askTool "log" [hole doc]) stop

-- ---------------------------------------------------------------------------
-- 24. battery-205 — a decider (D7)
-- ---------------------------------------------------------------------------

-- |
-- > workflow { t : text <- ask model "a" "status"
-- >            f <- decide lastNonEmptyLineIs t ["WORK COMPLETE"]
-- >            if f { ask tool "log" "yes" } else { ask tool "log" "no" } }
--
-- Two worlds, and they are the case: one answers
-- @"progress\\n**WORK COMPLETE**\\r\\n"@ and the other
-- @"progress\\nWORK REMAINS\\n"@, so the two traces take the two arms — which
-- means the decider's own algorithm is being compared against the oracle's
-- through the /branch it decides/, decorations and CRLF included, and not only
-- through the string-layer vectors.
--
-- What it pins about cost is the other half of D7: @askNodes@ is 3 and not 4,
-- and @size@ is 6, because a decider's value is a @ret@ and @graft_ret@ leaves
-- __no node at all__. @vector-006@ and @vector-007@ are the same program with
-- and without it; this is the one tier1 rebuilds.
battery205 :: Program
battery205 =
  program [] $
    bindAs @"t" @'CodeText (one (askModel "a" [lit "status"])) $ \t ->
      bind @"f" @'CodeFlag (decide LastNonEmptyLineIs t ("WORK COMPLETE" :| [])) $ \f ->
        ifFlag
          f
          (act (askTool "log" [lit "yes"]) stop)
          (act (askTool "log" [lit "no"]) stop)

-- ---------------------------------------------------------------------------
-- 25. battery-219 — two commands at one tool are two questions (D5)
-- ---------------------------------------------------------------------------

-- |
-- > workflow { ask tool "green" running "nix" "flake" "check" "gate"
-- >            ask tool "green" running "nix" "build" "gate" }
--
-- __The most important fixture D5 owes__, and the reason the argv rides in the
-- addressee rather than beside it: two acts saying the same words to the same
-- tool id with /different/ commands are __two questions__, so @billMemo@ is 2
-- and not 1. Were the argv anywhere outside @Q.Shape@ the second command would
-- be answered from the memo table without running — a gate that silently does
-- not run while the table reports it did, which is the ordinary case of a gate
-- run twice in one program and not a corner of it.
--
-- The kernel executes nothing here: a pure world dispatches on the /code/ and
-- never on the addressee, so this observation is computed exactly as any
-- other. What it is testing is the ordering key, which must mention @cmd@ and
-- @args@ or the two questions would collapse into one.
battery219 :: Program
battery219 =
  program [] $
    act (askToolRunning "green" "nix" ["flake", "check"] [lit "gate"]) $
      act (askToolRunning "green" "nix" ["build"] [lit "gate"]) stop

-- ---------------------------------------------------------------------------
-- 20 and 21. example-000 and example-001 — the walked examples
-- ---------------------------------------------------------------------------

-- $examples
--
-- 'Example.Harden.hardenProgram' and 'Example.Harden.helloProgram' are the
-- only cases in this list whose program is written somewhere else, and the
-- exception is deliberate: they are the two programs the @agentic-run@
-- executable plans, prices and /runs/, so they live in a module both
-- executables import. Pinning them here is what makes running them
-- trustworthy — the value the CLI hands to the interpreter is the same value
-- the oracle has already agreed with, printed Raw and whole reply, rather than
-- a second transcription of the same @.wf@ file that could drift from it.
--
-- They are worth pinning on their own account too. @harden@ is the corpus's
-- only program that:
--
--   * __reviews with a panel__. Every other @revising@ here — 'semantic001',
--     'vector002', 'battery121', 'battery120', 'battery090' — reviews with a
--     single question, so the panel's right fold from the unit of the verdict
--     monoid has never before been under a loop's @caseB@, replicated once per
--     round of the unroll;
--
--   * __reuses one name for the carrier and the settled binder__. Both are
--     @patch@, which is legal because they are binders in disjoint scopes and
--     'Agentic.Builder.revisingCase' checks each for freshness against the
--     enclosing scope alone. Nothing else in the corpus exercises that;
--
--   * __holes a name bound outside the loop from inside both clauses__.
--     @{guide}@ is read by two of the three panel members and by the
--     amendment, so every round re-reads it through the accumulated
--     substitutions. A graft that re-asked instead of re-reading would still
--     produce a well-typed term and would show up here as a longer trace and a
--     larger fresh bill.
--
-- @hello@ is the opposite end, and it is here for the runner rather than for
-- the folds: @pipeline@, size 4, one path, @minFold == maxFold == 3@ and both
-- bills 3 — a program whose whole cost the analysis knows exactly. It shares
-- that shape with 'semantic000' and 'battery137', and adds nothing to the
-- lattice; what it adds is a subject the CLI can run in three events, so a
-- scripted or live run that produces any other number is wrong without anyone
-- having to read a bound.

-- (The two programs themselves are in "Example.Harden"; the list at the head
-- of this module names them directly.)
