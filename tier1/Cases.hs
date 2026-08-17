-- | Tier 1: the rebuilt corpus cases.
--
-- Each case below is one /checked/ corpus entry, rebuilt in the combinators of
-- "Agentic.Builder" (@PORTING2-elab.md@ §2.2) and paired with the basename of
-- the frozen entry it must reproduce. This module owns nothing but that list:
-- @tier1/Main.hs@ owns every comparison (@PORTING2-elab.md@ §4.1).
--
-- The surface source of each case is quoted above it, transcribed from the
-- corpus entry's @request.program@ rather than invented, so that a reading
-- disagreement shows up as a printed-Raw mismatch and not as a silently
-- different program. Positions are not transcribed: the builder prints @0:0@
-- everywhere and tier1 zeroes both sides (@PORTING2-elab.md@ §3).
--
-- == What is deliberately absent
--
-- The five guard vectors and every refused battery entry are /unrepresentable/
-- in the builder, and that is the point — do not "fix" the builder to reach
-- them:
--
--   * @vector-000@ (duplicate function names) is a duplicate Haskell binding;
--   * @vector-003@ (question budget) needs 8192 questions;
--   * @vector-004@ (empty panel) is not a 'Data.List.NonEmpty.NonEmpty';
--   * @vector-005@ (served by on a tool) has no constructor;
--   * every @unbound@ / @freshName@ / kind refusal is a type error.
--
-- tier0 already replays all of them through "Agentic.Guards".
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Cases (cases) where

import Data.List.NonEmpty (NonEmpty (..))

import Agentic.Builder
  ( Args (ANil, (:>)),
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
    bind,
    bindAs,
    bindB,
    callStmt,
    callV,
    caseVerdict,
    draw,
    endB,
    function,
    hole,
    ifFlag,
    knownHere,
    lit,
    noParams,
    one,
    panel,
    param,
    program,
    revisingCase,
    stop,
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
    -- The thirteenth is §4.2's first "cheap extra": the bound-zero loop, whose
    -- unroll is the @| 0 =>@ clause and nothing else.
    ("battery-120-a-revision-bounded-at-zero-amendments.json", battery120),
    -- §4.2's second "cheap extra": the parsed-surface twin of case 11, at
    -- bound 1 in both loops rather than 2 and 3.
    ("battery-090-a-loop-nested-in-a-settled-arm.json", battery090),
    -- Two cases beyond the spec's list, added because §4.2's twelve leave the
    -- bottom of the level lattice and the empty term untested. See each note.
    ("battery-137-empty-prompts-and-an-empty-define.json", battery137),
    ("battery-147-a-function-may-answer-a-flag-the-caller-branches.json", battery147)
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
    bind @"g" @'CodeText (one (askTool "cat" [lit "read the file"])) $
      act (askTool "log" [hole @"g", lit "||", hole @"g"]) $
        act (askTool "audit" [lit "seen: ", hole @"g"]) $
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
    bindAs @"d" @'CodeText (one (askModel "author" [lit "draft"])) $
      revisingCase @"d" @"patch" @"v" @"final"
        "r"
        3
        Nothing
        (one (askModel "critic" [lit "review ", hole @"patch"]))
        ( one
            ( askModel
                "author"
                [lit "amend ", hole @"patch", lit " given ", hole @"v"]
            )
        )
        (act (askTool "apply" [lit "apply ", hole @"final"]) stop)
        (act (askTool "log" [lit "gave up"]) stop)

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
    bindAs @"a" @'CodeText (one (askModel "m" [lit "one"])) $
      bindAs @"b" @'CodeText (one (draw 1 (askModel "m" [lit "one"]))) $
        act (askTool "t" [hole @"a", lit " ", hole @"b"]) $
          stop

-- ---------------------------------------------------------------------------
-- 4. semantic-003 — an if on a flag (the entry's name says "loop"; §5 says why
--    that is the corpus's mistake and not this case's)
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
    bindAs @"d" @'CodeText (one (askTool "t" [lit "w"])) $
      bind @"ok" @'CodeFlag (one (askPerson "o" [lit "go?"])) $
        ifFlag @"ok"
          (act (askTool "a" [lit "went ", hole @"d"]) stop)
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
      $ act (askTool "log" [lit "objections: ", hole @"p"])
      $ caseVerdict @"p"
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
    bind @"a" @'CodeText (one (askModel "oracle" [lit "same words"])) $
      bind @"b" @'CodeText (one (askModel "oracle" [lit "same words"])) $
        bind @"c" @'CodeText (one (draw 1 (askModel "oracle" [lit "same words"]))) $
          act (askTool "log" [hole @"a", lit "|", hole @"b", lit "|", hole @"c"]) $
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
      $ act (draw 1 (askModelServed "logger" "cheap" [lit "note ", hole @"a"]))
      $ bind @"p" @'CodeVerdict
        ( panel
            ( draw 3 (askModelServed "one" "deep" [lit "review ", hole @"a"])
                :| [ draw 1 (askTool "lint" [lit "lint ", hole @"a"]),
                     draw 2 (askPerson "owner" [lit "ok? ", hole @"a"])
                   ]
            )
        )
      $ caseVerdict @"p" stop stop stop

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
    bindAs @"a" @'CodeText (one (askTool "c" [lit "a"])) $
      bindAs @"b" @'CodeText (one (askTool "c" [lit "b ", hole @"a"])) $
        knownHere $
          act (askTool "log" [hole @"a", lit " ", hole @"b"]) $
            stop

-- ---------------------------------------------------------------------------
-- 9. module-000 — a function, a value call, dotted names
-- ---------------------------------------------------------------------------

-- | @function lib.drafted (goal : text) -> text { d <- ask model "author"
-- "draft: {goal}"; answer d }@ — the library function after the import walk.
libDrafted :: Fn '[ 'CodeText] 'CodeText
libDrafted =
  function "lib.drafted" (param @"goal" @'CodeText noParams) $
    bindB @"d" @'CodeText (one (askModel "author" [lit "draft: ", hole @"goal"])) $
      answerB @"d"

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
    bindAs @"lib.guide" @'CodeText (one (askTool "cat" [lit "style guide"])) $
      bind @"x" @'CodeText (callV libDrafted (argName @"lib.guide" :> ANil)) $
        act (askTool "t" [lit "use ", hole @"x", lit " ", lit "hello"]) $
          stop

-- ---------------------------------------------------------------------------
-- 10. battery-144 — a statement call of a procedure
-- ---------------------------------------------------------------------------

-- | @function mk (goal : text) -> text@ — declared, never called.
fnMk :: Fn '[ 'CodeText] 'CodeText
fnMk =
  function "mk" (param @"goal" @'CodeText noParams) $
    bindB @"d" @'CodeText (one (askModel "author" [lit "draft: ", hole @"goal"])) $
      answerB @"d"

-- | @function judged (patch : text) -> verdict@ — declared, never called.
fnJudged :: Fn '[ 'CodeText] 'CodeVerdict
fnJudged =
  function "judged" (param @"patch" @'CodeText noParams) $
    bindB @"v" @'CodeVerdict (one (askModel "judge" [lit "judge: ", hole @"patch"])) $
      answerB @"v"

-- | @function applied (patch : text) -> receipt@ — a body that is a single
-- act and whose printed @answer@ is @null@.
fnApplied :: Fn '[ 'CodeText] 'CodeAck
fnApplied =
  function "applied" (param @"patch" @'CodeText noParams) $
    actB (askTool "apply" [lit "apply: ", hole @"patch"]) endB

-- |
-- > workflow { d : text <- ask tool "t" "w"
-- >  applied d }
--
-- The statement call adds no context slot (contrast the act, which does), and
-- @fnAsks@ counts all three declared functions though only one is called.
battery144 :: Program
battery144 =
  program [SomeFn fnMk, SomeFn fnJudged, SomeFn fnApplied] $
    bindAs @"d" @'CodeText (one (askTool "t" [lit "w"])) $
      callStmt fnApplied (argName @"d" :> ANil) $
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
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $
      revisingCase @"d" @"c" @"v" @"x"
        "r"
        2
        Nothing
        (one (askModel "m" [lit "review ", hole @"c"]))
        (one (askModel "a" [lit "fix ", hole @"c", lit " ", hole @"v"]))
        ( revisingCase @"x" @"c2" @"v2" @"y"
            "r2"
            3
            Nothing
            (one (askModel "m2" [lit "review again ", hole @"c2"]))
            (one (askModel "a" [lit "refix ", hole @"c2", lit " ", hole @"v2"]))
            (act (askTool "t" [lit "apply ", hole @"y"]) stop)
            stop
        )
        stop

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
      revisingCase @"ready" @"cand" @"v" @"done"
        "r"
        2
        Nothing
        (one (askModel "m" [lit "does the release look ready?"]))
        (one (askPerson "owner" [lit "is it ready now?"]))
        (ifFlag @"done" (act (askTool "ship" [lit "ship it"]) stop) stop)
        stop

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
-- The spec's first cheap extra (§4.2), and the only shape where the unroll is
-- the @| 0 =>@ clause /as the whole loop/: one check, then a @ret@, with no
-- per-round @caseB@ and no amendment at all. The amend clause is still
-- elaborated — it is a clause of the term, not of the trace — but no path
-- reaches it, which is why the term is size 7 with two paths and the only
-- branch is @finishCont@'s.
battery120 :: Program
battery120 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $
      revisingCase @"d" @"c" @"v" @"x"
        "r"
        0
        Nothing
        (one (askModel "m" [lit "review ", hole @"c"]))
        (one (askModel "a" [lit "fix ", hole @"c", lit " ", hole @"v"]))
        (act (askTool "log" [lit "settled ", hole @"x"]) stop)
        (act (askTool "log" [lit "unsettled"]) stop)

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
-- §4.2's second cheap extra, and the parsed-surface twin of 'vector002': the
-- same nesting at bound 1 in both loops instead of 2 and 3, which is a
-- different arithmetic on the same unroll — size 33 and 10 paths against 92 and
-- 27. A graft that replicated the inner loop the wrong number of times could
-- still hit one of the two; it cannot hit both.
battery090 :: Program
battery090 =
  program [] $
    bindAs @"d" @'CodeText (one (askModel "a" [lit "draft"])) $
      revisingCase @"d" @"c" @"v" @"x"
        "r"
        1
        Nothing
        (one (askModel "m" [lit "review ", hole @"c"]))
        (one (askModel "a" [lit "fix ", hole @"c", lit " ", hole @"v"]))
        ( revisingCase @"x" @"y" @"w" @"z"
            "r2"
            1
            Nothing
            (one (askModel "m" [lit "again ", hole @"y"]))
            (one (askModel "a" [lit "more ", hole @"y", lit " ", hole @"w"]))
            (act (askTool "log" [hole @"z"]) stop)
            stop
        )
        stop

-- ---------------------------------------------------------------------------
-- 15. battery-137 — empty prompts and an empty define
-- ---------------------------------------------------------------------------

-- |
-- > define empty = ""
-- > workflow { ask tool "t" ""
-- >            ask tool "t" "{empty}"
-- >            ask tool "t" "pre{empty}post" }
--
-- Beyond §4.2's list, for three things the twelve never reach:
--
--   * the __bottom of the level lattice__ — every case above is @pipeline@ or
--     @branch@, and nothing pins @batch@, which is what a program of nothing
--     but closed questions folds to. All three prompts here are closed, so all
--     three elaborate to @askC@ and the whole term is one straight line;
--   * the __empty prompt__, twice: @""@ and a hole on an empty define both
--     print as @[]@ and render as @""@ (the expansion contributes no chunk,
--     rather than an empty @lit@);
--   * @billMemo@ __strictly below__ @billFresh@ /at receipt/ — 2 against 3.
--     The corpus has only two entries where the bills differ at all
--     (@PORTING2-elab.md@ §5); 'battery117' is the other, and there the
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
  function "f" (param @"p" @'CodeText noParams) $
    bindB @"x" @'CodeFlag (one (askModel "m" [hole @"p"])) $
      answerB @"x"

-- |
-- > function f (p : text) -> flag {
-- >   x <- ask model "m" "{p}"
-- >   answer x
-- > }
-- > workflow { stop }
--
-- Beyond §4.2's list, for the __empty term__: @stop@ alone elaborates to a bare
-- @ret@, so this is the corpus's only entry at size 1 with @askNodes 0@,
-- @codes []@ (the empty list, which is not @null@ — a batch program with no
-- questions), @costSummary (0, 0, 1)@ and an __empty trace__ billing @(0, 0)@.
-- Every fold and both bills are exercised at their base case here and nowhere
-- else. The declared-but-uncalled function still shows up in @fnAsks@ as
-- @[["f", 1]]@, which is what makes it a count over the table rather than over
-- the reachable term.
battery147 :: Program
battery147 = program [SomeFn fnF] stop
