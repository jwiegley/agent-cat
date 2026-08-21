{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}

-- |
-- Module      : Agentic.Workflow
-- Description : The authoring surface: a workflow reads as a block of binds.
--
-- "Agentic.Builder" is correct and stays. What this module replaces is the
-- thing a /human writes/: where the builder spells the flagship as
--
-- > bind @"guide" @'CodeText (one (askTool "cat" [lit "…"])) $ \guide -> …
--
-- it should read as prose reads — a block of statements, binds that are binds,
-- prompts that are prose (@Example.Harden@ is that program, and is the
-- authoring surface's text of record). Every combinator here is sugar: it
-- is an application of a "Agentic.Builder" entry point, so elaboration and
-- printing remain the single proven pairing and this layer cannot mean
-- anything the builder does not already mean.
--
-- An authoring module says exactly this:
--
-- > {-# LANGUAGE BlockArguments, OverloadedStrings, QualifiedDo, QuasiQuotes #-}
-- >
-- > import Agentic.Workflow
-- > import qualified Agentic.Workflow.Do as W
--
-- and then writes ordinary Haskell:
--
-- > harden :: Program
-- > harden = workflow W.do
-- >     guide <- ask (tool "cat") [wf|Write out the house style guide.|]
-- >     result <- revising draft (atMost 2) \patch -> W.do
-- >         verdict <- panel [ ask (model "reviewer") [wf|{guide}…{patch}|] ]
-- >         amend (ask (model "author") [wf|…{patch}…{verdict}|])
-- >     case result of
-- >       Settled patch -> W.do
-- >         ok <- confirm (person "owner") [wf|Apply this?…{patch}|]
-- >         when ok $ W.do
-- >           act (tool "apply") [wf|Apply: {patch}|]
-- >       Unsettled -> stop
--
-- That @when@ is the two-armed @if@ with both terminals supplied — 'ifThenElse'
-- with the body sealed by the implicit @stop@ an arm block's end is, and the
-- empty block for the other arm — and it prints the same @ifFlag@ node. An
-- author who wants both arms writes Haskell's own @if@, which is what 'when'
-- is written in.
--
-- There is no splice, no bracket and no label: a statement is a statement, a
-- binder is a Haskell binder, a branch is a @case@ and a @case@ is a @case@.
-- @W.do@ is @QualifiedDo@ — a plain extension that rebinds nothing beyond the
-- block it is written on — and the @if@ is Haskell's own @if@, reaching
-- 'ifThenElse' under @RebindableSyntax@ (see \"Two branches, two
-- mechanisms\").
--
-- == The one thing a library cannot read: a binder's spelling
--
-- A Haskell binder's name is not available to a library. Only Template
-- Haskell can read it, and program-level Template Haskell is out. So this
-- layer does not carry names at the type level at all — no @Symbol@, no
-- labels, no @'Fresh'@ over spellings — and it __generates__ the name each
-- binding prints:
--
--   * a binding made at depth @d@ (there are @d@ live bindings around it)
--     prints @b\<d\>@ — @b0@, @b1@, …;
--   * so does the carrier of a bounded revision, which is bound at the
--     enclosing depth, and so does the settled binder of its @case@, which is
--     bound at the same depth in a disjoint scope; the revision's own review
--     binding is one deeper;
--   * a bounded revision's /result/ — printed twice, in the @bind@ and in the
--     'Agentic.Raw.RawCaseResult' that consumes it, and never in scope —
--     prints @r\<d\>@, which no binding can collide with.
--
-- The depth a name is generated from is the length of the 'Live' list the
-- block is carrying, which every binding conses its own name onto — /not/ the
-- length of the scope index. The two agree everywhere but in one place, and
-- that place is the reason: a fork's unsettled arm is /typed/ at the settled
-- arm's scope (see 'Outcome') and /checked/ at the enclosing one, so only the
-- names it was handed say where it really stands.
--
-- Every generated name is a function of the program's shape alone, so a
-- program prints the same names on every machine and in every build. They are
-- fresh by construction: at depth @d@ the live names are exactly
-- @b0 … b(d-1)@.
--
-- 'named' overrides one, for an author who wants a program that reads well
-- when printed:
--
-- > guide <- named "guide" (ask (tool "cat") [wf|…|])
--
-- It is never required, and the walked examples do not use it.
--
-- __A hole prints the handle's name.__ @{guide}@ in a @[wf|…|]@ resolves to
-- the Haskell /value/ @guide@, and the chunk it writes carries that value's
-- own name — the very 'Text' its binder printed. Binder and hole agree by
-- construction, which is what the labelled surface could only ask for by
-- convention.
--
-- == Three block grammars, one @do@ qualifier
--
-- The language has three block shapes, and each refuses what its
-- 'Agentic.Raw.Raw' cannot express: a workflow block branches and ends in a
-- terminal; a bounded revision has exactly one review and exactly one
-- amendment; a function body is a straight line with no branch and no loop.
-- All three are written in @W.do@ ("Agentic.Workflow.Do"), because the /stage/
-- index already tells them apart: inside a revision only a review may stand,
-- and after it only 'amend'; inside a body there is no branch to write, and
-- the block ends at 'answer' or 'done' rather than at 'stop'.
--
-- A statement that stands at more than one stage — 'act', 'call_' — is a
-- __value__ with one 'Step' instance per stage ('Acting', 'Calling'), never a
-- class over stages, so every instance still dispatches on two heads and
-- nothing else.
--
-- == Functions, calls, and a program's inputs
--
-- A 'function' is a name, a parameter list and a body:
--
-- > libDrafted :: Fn '[ 'CodeText] 'CodeText
-- > libDrafted = function "lib.drafted" (takes @"goal" Text noParams) \goal -> W.do
-- >     d <- ask (model "author") [wf|draft: {goal}|]
-- >     answer d
-- >
-- > module000 :: Program
-- > module000 = defining [SomeFn libDrafted] W.do
-- >     guide <- ask (tool "cat") [wf|style guide|] `annotated` Text
-- >     x     <- call libDrafted (arg guide :> noArgs)
-- >     act (tool "t") [wf|use {x}|]
-- >     stop
--
-- 'takes' is the one place this surface asks an author for a name at the type
-- level, and it asks because a parameter's name is /printed/ — in the
-- signature, and again in every hole of the body — where a binding's is
-- generated. 'defining' is 'workflow' with a table, and it checks what the
-- type level cannot see (see there).
--
-- A __call__ costs what writing the callee's statements at the call site
-- costs: @rhsAsks@ prices it at the callee's own @bodyAsks@ with the arguments
-- ignored, and @graft@ splices the callee's nodes in rather than adding one.
-- What can move is 'Agentic.Plan.level': a prompt that was closed inline
-- becomes open when the literal it held becomes a parameter, and an open
-- prompt joins @pipeline@.
--
-- An __input__ ('taking', 'input') is a @define@ supplied at run time, so a
-- program with inputs is an ordinary Haskell function of them and nothing
-- type-level is needed: a define never enters a scope and cannot collide with
-- a binding. See 'Parameterized' for why @main@'s parameters are not the
-- mechanism. Four input names are the __runner's__ to bind rather than the
-- command line's — what the run reached, under which engine, which pin reached
-- which of them, and the line it generated for itself — and they are inputs
-- like any other: see 'runFacts'.
--
-- == Two branches, two mechanisms
--
-- A workflow branches twice, and the two branches are spelled with Haskell's
-- own @if@ and Haskell's own @case@ — but they reach the block by different
-- routes, and the difference is forced by the language, not chosen.
--
-- __@if@ forks at the @if@.__ 'ifThenElse' is an ordinary function of a flag
-- handle and two blocks, which @RebindableSyntax@ is what @if@ means. It has
-- to be: a flag may be bound, /acted past/, and only then branched on.
-- @battery-043@ in the frozen corpus does exactly that — it binds @f@ from a
-- person, binds another name after it, @act@s, and only on the next line
-- writes @if f { } else { }@ — so a fork at the flag's __bind__ would sweep
-- every statement in between into both arms and print a different program.
--
-- __@case@ forks at the bind.__ A bounded revision's result is not a value and
-- cannot be spliced, so there is nothing for 'Outcome' to /be/ except the
-- branch itself: 'revising'\''s bind runs the rest of the block twice, once
-- under @Settled@ with a fresh settled handle and once under @Unsettled@, and
-- hands the two blocks to "Agentic.Builder"\'s @revisingCase@ as the arms of
-- the @case result@ it prints. That is observationally the combinator it
-- replaces, because Lean refuses every statement between the two: while a
-- result is pending, @checkBlock@ answers @.empty@, @knownHere@, @act@,
-- @bind@, @callStmt@, @ifFlag@ and @caseVerdict@ alike with
--
-- > the revising result `x` is not yet consumed: `case x { settled …
-- > unsettled … }` is the next statement, and nothing else touches it
--
-- (@Check.lean:653@'s @pendingErr@, raised at @550@, @558@, @566@, @567@,
-- @568@, @680@ and @701@ — every statement form but @.caseResult@), so there
-- is nothing an author could legally have written between the bind and its
-- @case@ for the fork to swallow.
--
-- Where the two do differ, they differ in the /accepting/ direction and not in
-- what a program means. An author who writes a statement between the bind and
-- the @case@ is not refused here; the statement stands in __both__ arms, which
-- is the same term an author reaches by writing that statement twice — and
-- an author who ignores the result altogether has an unused binding and hears
-- so from @-Wunused-matches@.
--
-- 'caseVerdict' takes neither route and stays a combinator: a verdict /is/ a
-- value, it may be bound, spliced, acted past and branched on many statements
-- later, exactly as a flag may, and its three arms are positional rather than
-- a Haskell constructor's.
--
-- == What must not compile
--
-- GHC has no negative-test harness here, so the refusals are recorded as the
-- messages they produce. Each is the design and not an accident:
--
--   * a statement after @stop@, @if@, @when@, @unless@ or @case@ —
--     @nothing follows a terminal: `stop`, `if` and `case` end a block@;
--   * a @when@ body that ends in a terminal — @Couldn't match type ‘Term’ with
--     ‘()’@, because a body is an arm block /minus/ its terminal and 'when'
--     supplies that;
--   * a block that does not end in a terminal —
--     @Couldn't match type ‘()’ with ‘Term’@;
--   * @served by@ on a tool or a person —
--     @Couldn't match type ‘IsTool’ with ‘IsModel’@;
--   * a flag spliced into a prompt —
--     @only a text or a verdict answer interpolates into a prompt@;
--   * a handle read where its binding is not live —
--     @this binding is not live here; nothing in scope answers to it@ (the
--     type-level half) or GHC's own @Variable not in scope@ (the Haskell
--     half);
--   * a revision with two reviews, or none, or a statement between the review
--     and the amendment — @a bounded revision reviews first … and then
--     amends, and has no other statement@;
--   * a @case@ on anything but an 'Outcome' where a revision's result stands,
--     or an 'Outcome' pattern where no revision bound one — GHC's own
--     @Couldn't match type@ on the scrutinee, because @Settled@ and
--     @Unsettled@ are the constructors of one data type and nothing else
--     produces it;
--   * a revision's settled handle read in the unsettled arm — GHC's own
--     @Variable not in scope@, because the pattern binds it in one arm only.
--
-- And, with functions and calls:
--
--   * a branch, a loop or a @known here@ in a function body — @a function body
--     is a straight line: it has no bounded revision, no branch and no
--     `known here` — those belong to the workflow that calls it@ (the loop's
--     own message; @if@, @caseVerdict@, @knownHere@ and @stop@ stay typed at
--     @'Open'@ and give GHC's own @Couldn't match ‘Open’ with ‘Body’@);
--   * an @act@ or a @call_@ inside a bounded revision — @a bounded revision
--     reviews first … and then amends, and has no other statement@;
--   * two parameters of one name — "Agentic.Builder"'s @Fresh@: @this name is
--     already in scope, and a live name is not introduced twice@;
--   * a parameter or a 'named' binding taking a name the surface generates for
--     itself — 'reserved', on a CAF;
--   * an 'input' under the @run.@ prefix that is not one of the runner's own
--     facts — 'runFacts', on a CAF;
--   * 'done' in a value-returning body — @Couldn't match ‘'CodeText’ with
--     ‘'CodeAck’@; a body with no terminal — @Couldn't match ‘()’ with ‘Term’@;
--     a statement after @answer@ or @done@ — @nothing follows a terminal@;
--   * a value function standing as a statement call — @Couldn't match
--     ‘'CodeText’ with ‘'CodeAck’@ on 'call_'\''s first argument;
--   * an argument of the wrong kind — @Couldn't match ‘'CodeVerdict’ with
--     ‘'CodeText’@; the wrong number of arguments — @Couldn't match
--     ‘Args s '[]’ with ‘Args s '[ 'CodeText]’@;
--   * two functions of one name, or a call naming a function 'defining' was
--     not given or was given later — value-level refusals on a CAF, because
--     the /list/ is what says when a function was declared.
module Agentic.Workflow
  ( -- * Programs
    Program,
    workflow,
    defining,

    -- * A program's inputs
    Parameterized (..),
    Ins,
    noInputs,
    In,
    input,
    taking,
    Example (..),

    -- ** The facts the runner supplies
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

    -- * The chain both lists are written with
    Chain,
    pattern (:>),

    -- * Prompts
    wf,
    wft,
    Says (..),
    Words,
    Piece,
    lit,

    -- * Handles, and the names a program prints
    V,
    named,
    Nm,
    An,
    genName,
    resultName,
    Live,
    KnownIx,

    -- * Questions
    PartyK (..),
    Party,
    model,
    tool,
    person,
    servedBy,
    fallingBackTo,
    running,
    drawing,
    Ask,
    ask,
    confirm,
    panel,
    panelText,
    Decider (..),
    decide,
    Answer (..),
    answering,
    annotated,
    Ann,

    -- * The block
    Stage (..),
    Res,
    Arms,
    W,
    Term,
    NoFollow,
    Step (..),
    runW,
    runRev,
    bindW,
    thenW,

    -- * Statements and terminals
    stop,
    act,
    Acting,
    ask_,
    knownHere,
    ifThenElse,
    ifFlag,
    -- `when` and `unless` are not Prelude's: they are @Control.Monad@'s, which
    -- an authoring module does not import, so these two shadow nothing. They
    -- are also not that `when` — see their docstrings: these are terminal.
    when,
    unless,
    caseVerdict,

    -- * Functions
    Fn,
    SomeFn (..),
    Params,
    noParams,
    takes,
    function,
    answer,
    done,
    runBody,
    Curries (..),

    -- * Calls
    call,
    call_,
    Calling,
    Arg,
    Args (ANil),
    noArgs,
    Gives (..),

    -- * The bounded revision
    Bound,
    atMost,
    revising,
    Outcome (..),
    Loop,
    revisingOn,
    Ending (..),
    LoopOn,
    Arms3,
    Clauses,
    Amendment,
    amend,

    -- * The scope, as the block grammar's signatures need it
    Code (..),
    Scope,
    Entry,
    Blk,
    Rhs,
  )
where

import Agentic.Builder
  ( Arg,
    Args (ACons, ANil),
    Ask (..),
    Blk (..),
    Code (..),
    Codes,
    Decider (..),
    Entry,
    Fn,
    Fresh,
    ParamCtx,
    Params (..),
    Piece,
    Program,
    Rhs,
    Scope,
    SomeFn (..),
    Words,
    lit,
    noParams,
  )
import qualified Agentic.Builder as B
import Agentic.Plan
  ( KnownCode,
    SCode,
    Var (VHere),
    sCode,
  )
import Agentic.Raw
  ( Addressee (..),
    Raw (..),
    RawBodyStmt (..),
    RawFn (fnBody, fnName),
    RawProgram (..),
    RawRhs (..),
    RawSource (..),
    Served (..),
    servedBy1,
  )
import Agentic.WF (KnownIx, Says (..), V (..), wf, wft)
import Data.Char (isDigit)
import Data.Kind (Constraint, Type)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (catMaybes, fromMaybe, listToMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
-- The @ErrorMessage@ constructors are imported qualified, and only there:
-- @GHC.TypeLits@ spells its literal message @Text@, which is exactly the name
-- 'Answer' gives to the kind @text@, and one of the two has to give way.
import GHC.TypeLits (KnownSymbol, TypeError, symbolVal)
import qualified GHC.TypeLits as TL

-- ---------------------------------------------------------------------------
-- The scope, and the names it generates
-- ---------------------------------------------------------------------------

-- | One anonymous scope entry.
--
-- "Agentic.Builder" indexes everything by a 'Scope' of @(name, code)@ pairs,
-- because /it/ resolves names at the type level. This layer resolves nothing
-- by name, so every entry it pushes carries the same empty symbol and a scope
-- here is its list of codes and nothing else. (It is spelled as a 'Scope'
-- rather than as a bare @Ctx@ because @Codes@ is not injective: the builder's
-- types are the ones that must line up, and they are indexed by scopes.)
type An (c :: Code) = '("", c)

-- | The name a binding made at depth @d@ prints: @b\<d\>@, where @d@ is the
-- number of names the block is carrying.
--
-- Fresh by construction — at depth @d@ the live names are exactly
-- @b0 … b(d-1)@ — and a function of the program's shape alone, so a printed
-- program is reproducible.
--
-- The depth is read off the 'Live' names rather than off the scope index,
-- which is what makes a fork's unsettled arm print at the depth it is
-- /checked/ at rather than at the one it is /typed/ at. See 'Outcome'.
genName :: Live -> Text
genName live = T.pack ('b' : show (length live))

-- | The name a bounded revision's /result/ prints: @r\<d\>@.
--
-- A result is not a binding: it is printed in the @bind@ and in the
-- @case result@ that consumes it, and it never enters a scope. Its own letter
-- keeps it clear of the carrier, which /is/ a binding at the very same depth.
resultName :: Live -> Text
resultName live = T.pack ('r' : show (length live))

-- | The names this surface generates for itself, which an author may not take:
-- @b0, b1, …@ for bindings and @r0, r1, …@ for a bounded revision's result.
--
-- \"Fresh by construction\" is a claim about /generated/ names — at depth @d@
-- the live ones are exactly @b0 … b(d-1)@ — and there are two places an author
-- can spell a name of their own: 'named', and a function parameter, whose
-- symbol is what the body's holes and the printed signature carry. Neither
-- passes through 'Fresh' (a body binds through the index-level
-- 'Agentic.Builder.bindBI', which has none), so a parameter called @b2@ would
-- be accepted here and refused by Lean, at the depth-2 binding that then
-- shadows it. Both callers ask this first, so the claim stays exact.
reserved :: Text -> Bool
reserved t = case T.uncons t of
  Just (c, ds) -> (c == 'b' || c == 'r') && not (T.null ds) && T.all isDigit ds
  Nothing -> False

-- | The refusal both callers of 'reserved' make, in one place so they make it
-- in the same words. It sits on a CAF, like 'panel'\''s.
reservedError :: Text -> Text -> a
reservedError what x =
  error
    ( T.unpack what
      <> ": `"
      <> T.unpack x
      <> "` is a name this surface generates for itself — `b0`, `b1`, … for a "
      <> "binding and `r0`, `r1`, … for a bounded revision's result — and a "
      <> "generated name is fresh by construction only while no author takes one"
    )

-- ---------------------------------------------------------------------------
-- Naming a binding by hand
-- ---------------------------------------------------------------------------

-- | A statement whose binding prints a name the author chose.
data Nm st = Nm Text st

-- | @named "guide" (ask (tool "cat") [wf|…|])@ — the name this statement's
-- binding prints, in place of the generated one.
--
-- Never required, and nothing reads it but the printer: a program means
-- exactly what it meant before, and holes still print whatever their handle
-- carries, which is now this. A statement that binds nothing ignores it.
--
-- A 'reserved' name is refused: see there.
named :: Text -> st -> Nm st
named x st
  | reserved x = reservedError "named" x
  | otherwise = Nm x st

-- ---------------------------------------------------------------------------
-- Parties and questions
-- ---------------------------------------------------------------------------

-- | Which of the three parties a question is put to. The index is what makes
-- @askGuard@'s refusal unrepresentable: only a model is served by a model.
data PartyK = IsModel | IsTool | IsPerson

-- | Whom a question is put to, and how: the addressee, the @served by@
-- override, and the draw.
data Party (p :: PartyK) = Party
  { partyAddr :: Addressee,
    -- | the @served by@ chain: the model that serves, and the spares (D6)
    partyServe :: Maybe Served,
    partyDraw :: Integer
  }

-- | @ask model "m" …@.
model :: Text -> Party 'IsModel
model i = Party (AddrModel i) Nothing 0

-- | @ask tool "t" …@.
tool :: Text -> Party 'IsTool
tool i = Party (AddrTool i) Nothing 0

-- | @ask person "p" …@.
person :: Text -> Party 'IsPerson
person i = Party (AddrPerson i) Nothing 0

-- | @served by "deep"@ — the model that serves a model addressee. A tool or a
-- person is not served by one, and here that is a kind error rather than a
-- check.
servedBy :: Party 'IsModel -> Text -> Party 'IsModel
servedBy p m = p {partyServe = Just (servedBy1 m)}

-- | @model "r" \`servedBy\` "deep" \`fallingBackTo\` "broad"@ — the models
-- that may answer in the pinned one's place, appended in the order the runner
-- tries them (D6).
--
-- On a party with no pin this /makes/ the named model the primary, so
-- @model "r" \`fallingBackTo\` "deep"@ and @model "r" \`servedBy\` "deep"@
-- agree and no illegal state is reachable without a second kind index.
--
-- __An alternate is not part of the question.__ Two asks differing only here
-- elaborate to the same plan, put the same question and bill the same: the
-- chain is a property of the /model/ that the runner collects before the run
-- (@Agentic.Chains@), never a field of @Q.Shape@ — which is Isaac's own reading
-- that a fallback "is not part of that identity", at our types.
fallingBackTo :: Party 'IsModel -> Text -> Party 'IsModel
fallingBackTo p m =
  p
    { partyServe = Just $ case partyServe p of
        Nothing -> servedBy1 m
        Just (Served pr spares) -> Served pr (spares ++ [m])
    }

-- | @tool "green" \`running\` ("nix", ["flake", "check"])@ — the command the
-- runner puts in place of asking (D5), so that a check can be an exit code
-- rather than a model's claim about one.
--
-- A model or a person is not run, and here that is a kind error rather than a
-- refusal, exactly as 'servedBy' on a tool is.
--
-- The words stay the question: the executing world writes them to the child's
-- standard input, where a splice is data and is harmless. There is no
-- interpolation syntax at an argv — @cmd@ and its arguments are 'Text', never
-- 'Words' — and an authoring surface that offered one would reintroduce every
-- problem a capability lattice exists to bound. Do not write it.
running :: Party 'IsTool -> (Text, [Text]) -> Party 'IsTool
running p (cmd, args) = p {partyAddr = retarget (partyAddr p)}
  where
    retarget = \case
      AddrTool i -> AddrToolExec i cmd args
      AddrToolExec i _ _ -> AddrToolExec i cmd args
      other -> other

-- | @independent draw n@. Two draws of one prompt are two questions, which is
-- what the memo bill prices apart.
drawing :: Party p -> Integer -> Party p
drawing p n = p {partyDraw = n}

-- | One question, at no kind at all — exactly as 'Agentic.Raw.RawAsk' has no
-- kind field. It stands wherever a position imposes one: a panel member, an
-- act, a review, an amendment, or a binder.
ask :: Party p -> Words s -> Ask s
ask p w =
  Ask
    { askAddr = partyAddr p,
      askDraw = partyDraw p,
      askServe = partyServe p,
      askWords = w
    }

-- | A yes\/no question: the binding an @if@ can decide on.
--
-- A bare 'ask' in binding position is a /text/ question — that is
-- @usePrompt@'s "a name whose only use is being spliced is a text question"
-- (@Check.lean:213@) made structural — so the kind of anything else has to be
-- said, and this is how a flag says it.
confirm :: Party p -> Words s -> Rhs s 'CodeFlag
confirm p w = B.one (ask p w)

-- | @panel, all must approve […]@ — a verdict, positionally, folded right in
-- the noncommutative verdict monoid.
--
-- A plain list, so that the literal reads as a bracketed list of members. Its
-- emptiness is refused at the value level rather than by 'NE.NonEmpty',
-- because the language's own refusal for an empty panel belongs to tier0
-- (@vector-004@) and not to this layer; the @error@ sits on a CAF, so it fires
-- the first time anything touches the program.
panel :: [Ask s] -> Rhs s 'CodeVerdict
panel [] =
  error
    "panel: a panel needs at least one member — `panel []` asks no one and \
    \settles nothing"
panel (m : ms) = B.panel (m NE.:| ms)

-- | @panelText [("alpha", ask …), ("beta", ask …)]@ — 'panel'\'s twin at
-- @text@ (D2): the same fan-out, the same one question per member, the same
-- trace, and a different fold. Each member's answer is fenced under its own
-- name — @\<alpha\>\\n…\\n\<\/alpha\>\\n@ — and the blocks are
-- concatenated in member order, so the document's reader can tell which member
-- said what.
--
-- __The label is the author's and not the addressee's id.__ Two members of one
-- spread routinely share an addressee, and a document whose names change when
-- an operator repoints a lens is naming the wrong thing.
--
-- A plain list for the reason 'panel' takes one: the language's own refusal for
-- an empty fan belongs to tier0, not to this layer.
panelText :: [(Text, Ask s)] -> Rhs s 'CodeText
panelText [] =
  error
    "panelText: a text panel needs at least one member — `panelText []` asks no \
    \one and fences nothing"
panelText (m : ms) = B.panelText (m NE.:| ms)

-- | @decide LastNonEmptyLineIs status ["WORK COMPLETE"]@ — a pure
-- classification of text already in hand, answering a flag an @if@ can decide
-- on (D7).
--
-- It asks nothing and costs nothing in any fold, so the net effect of writing
-- one where an asked flag stood is __one fewer question on every path, the same
-- number of paths, and the same rung__. The needles are literal program text
-- and never words: a needle a model could author is a test a model chooses,
-- which is not a decider.
decide ::
  forall h s.
  (KnownIx h s) =>
  Decider ->
  V h 'CodeText ->
  [Text] ->
  Rhs s 'CodeFlag
decide _ _ [] =
  error
    "decide: a decider needs at least one needle to test for — a decider with \
    \none is a test that is constantly false, with nothing in the source to \
    \show it"
decide d v ws
  | any T.null ws =
      error
        "decide: a decider needs its needles to say something, and the empty \
        \needle tests nothing"
  | otherwise = B.decide @h @s d v (NE.fromList ws)

-- | The four answer kinds, as words an author can say. Capitalised because
-- @verdict@ is a name authors /bind/, and a lower-case singleton would be
-- shadowed by it. The data constructor @Text@ is in a different namespace from
-- the type @Data.Text.Text@ and does not clash with it.
data Answer (c :: Code) where
  Text :: Answer 'CodeText
  Flag :: Answer 'CodeFlag
  Verdict :: Answer 'CodeVerdict
  Receipt :: Answer 'CodeAck

-- | The kind, as evidence.
withAnswer :: forall c r. Answer c -> (KnownCode c => r) -> r
withAnswer a k = case a of
  Text -> k
  Flag -> k
  Verdict -> k
  Receipt -> k

-- | @ask … \`answering\` Verdict@: the kind, stated where nothing else fixes
-- it. Prints nothing — @ann@ stays @null@.
answering :: Ask s -> Answer c -> Rhs s c
answering a c = withAnswer c (B.one a)

-- | @ask … \`annotated\` Verdict@: the kind, printed — @x : verdict <- …@.
annotated :: Ask s -> Answer c -> Ann s c
annotated a c = withAnswer c (Ann sCode (B.one a))

-- | A source with its kind written out, which is the one thing that prints an
-- annotation.
data Ann (s :: Scope) (c :: Code) = Ann (SCode c) (Rhs s c)

-- ---------------------------------------------------------------------------
-- The block: an indexed CPS monad over a Stage
-- ---------------------------------------------------------------------------

-- | Where a block stands. One of the three is Lean's, and two are this
-- surface's way of holding a revision's two clauses apart:
--
--   * @'Open' s@ — an ordinary block over the live bindings @s@;
--   * @'Review' c s@ — inside a revision, awaiting its one review, with the
--     candidate live at index @0@;
--   * @'Amending' c s@ — the same revision, awaiting its one amendment, with
--     the verdict live too;
--   * @'Body' r s@ — a function body over its parameters @s@, at the result
--     kind @r@ the function declares.
--
-- Lean's fourth state, @Pend Γ@ (@Check.lean:639@) — a block /pending/ the
-- @case@ that consumes a bounded revision's result — has no stage here,
-- because the fork happens at the bind and the arms are ordinary open blocks.
-- Its refusal is not lost: see \"Two branches, two mechanisms\".
--
-- __The naming.__ The promoted @'Body'@ and "Agentic.Builder"\'s type @Body@
-- would clash in the type namespace, so Builder's is written @B.Body@ here,
-- which is how every other Builder entry point is written in this module.
data Stage
  = Open Scope
  | Review Code Scope
  | Amending Code Scope
  | Body Code Scope

-- | What a block at a given stage /is/. The family is injective because its
-- four results are distinct type constructors — and it has to be, or
-- unwrapping a 'W' could not recover its indices and @>>=@ would not typecheck
-- at all.
type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s) = Blk s
  Res ('Review c s) = Clauses c s
  Res ('Amending c s) = Amendment c s
  Res ('Body r s) = B.Body s r

-- | The two arms of a @case result@ as the fork produces them: the name the
-- exit binders print, and the two blocks the rest of the workflow is.
--
-- __Both are at the same scope__, because both are the one continuation run
-- twice — and since D3 that scope is honest at both, each arm binding the
-- candidate the loop was holding. One name, because both arms are built at one
-- depth and 'genName' is a function of the depth.
data Arms (c :: Code) (s :: Scope)
  = Arms Text (Blk (An c ': s)) (Blk (An c ': s))

-- | The three arms of a @case result@ over a @revising on@ (D4), as its fork
-- produces them: the names the three exit binders print, and the three blocks
-- the rest of the workflow is.
--
-- Three names rather than one, because an index-level caller may thread its own
-- supply; 'revisingOn' passes 'genName'\'s one answer three times, for the
-- reason 'Arms' carries one.
data Arms3 (c :: Code) (s :: Scope)
  = Arms3
      Text
      Text
      Text
      (Blk (An c ': s))
      (Blk (An c ': s))
      (Blk (An c ': s))

-- | A revision's two clauses: the review binding's name, what it prints as its
-- annotation, the review, and the amendment.
data Clauses (c :: Code) (s :: Scope)
  = Clauses
      Text
      (Maybe Code)
      (Rhs (An c ': s) 'CodeVerdict)
      (Rhs (An 'CodeVerdict ': An c ': s) c)

-- | The second clause of a revision, which sees the verdict at index @0@ and
-- the candidate at @1@.
newtype Amendment (c :: Code) (s :: Scope)
  = Amendment (Rhs (An 'CodeVerdict ': An c ': s) c)

-- | The live names, innermost first — what a block knows about itself that its
-- type does not.
--
-- The scope index says how many bindings are live and at which kinds; it
-- cannot say what they are /called/, because 'named' may have overridden a
-- generated name. Exactly one construct needs to know: @known here@, which
-- prints the live names. So a block is handed them, every binding conses its
-- own onto the list, and @knownHere@ reads it — rather than recomputing names
-- from the depth, which would print @b0@ for a binding the author named
-- @guide@.
type Live = [Text]

-- | A block, in continuation-passing style over the stage index: /given the
-- live names and what follows, the whole block/. It is the shape of every
-- builder block combinator, all of which take the rest of the block as their
-- last argument, so the desugaring below is a re-association and nothing more.
newtype W (i :: Stage) (j :: Stage) a = W {unW :: Live -> (a -> Res j) -> Res i}

-- | Uninhabited: a terminal has no value.
data Term

absurdTerm :: Term -> a
absurdTerm t = case t of {}

-- | Nothing follows a terminal. Without this the continuation would simply be
-- dropped and the statements after a @stop@ would vanish in silence.
type family NoFollow a :: Constraint where
  NoFollow Term =
    TypeError
      ('TL.Text "nothing follows a terminal: `stop`, `if` and `case` end a block")
  NoFollow a = ()

-- | The block a workflow's @do@ finally is, under the names live at its head.
runW :: Live -> W ('Open s) j Term -> Blk s
runW live (W f) = f live absurdTerm

-- | The two clauses a revision's @do@ finally is.
runRev :: Live -> W ('Review c s) ('Amending c s) Term -> Clauses c s
runRev live (W f) = f live absurdTerm

-- | The body a function's @do@ finally is, under the names its parameters are.
runBody :: Live -> W ('Body r s) j Term -> B.Body s r
runBody live (W f) = f live absurdTerm

-- | What a statement does to a block: which stage it takes, which stage it
-- leaves, and what it binds.
--
-- __Every instance dispatches on two heads and nothing else__ — the
-- statement's type constructor and the stage's — and states the rest as
-- equalities in its context. That is what keeps inference eager: a statement's
-- scope, its outgoing stage and the handle it binds are /improved/ from the
-- stage the block is already at, so a prompt with no hole in it still knows
-- which scope it is written in, and a @case@ arm is not a metavariable waiting
-- on the arm after it.
--
-- The 'Maybe' 'Text' is the name the binding prints: 'Nothing' at an ordinary
-- statement, which generates one from the depth, and @Just@ under 'named'.
-- The 'Live' names are the block's, and the continuation is handed them with
-- whatever this statement bound consed on.
class Step st (i :: Stage) (j :: Stage) a where
  step :: Maybe Text -> Live -> st -> (a -> Live -> Res j) -> Res i

-- | A statement that is already a block: an 'act', a 'knownHere', a terminal.
-- It binds nothing, so the names it leaves behind are the names it was given.
instance (i ~ i', j ~ j', a ~ a') => Step (W i' j' a') i j a where
  step _ live (W f) k = f live (`k` live)

-- | @named "x" statement@ — the same statement, printing the given name.
instance Step st i j a => Step (Nm st) i j a where
  step _ live (Nm x st) = step (Just x) live st

-- | @x <- ask …@ — a bare question in binding position __is__ a text
-- question, which is @usePrompt@'s "a name whose only use is being spliced is
-- a text question" (@Check.lean:213@) made structural.
instance
  ( s' ~ s,
    j ~ 'Open (An 'CodeText ': s),
    a ~ V (An 'CodeText ': s) 'CodeText
  ) =>
  Step (Ask s') ('Open s) j a
  where
  step mn live q k = B.bindI x (B.one @'CodeText q) (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @x <- panel […]@, @x <- confirm …@, @x <- ask … \`answering\` c@ — the
-- kind comes from the source, and the annotation stays @null@.
instance
  ( s' ~ s,
    j ~ 'Open (An c ': s),
    a ~ V (An c ': s) c
  ) =>
  Step (Rhs s' c) ('Open s) j a
  where
  step mn live r k = B.bindI x r (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @x <- ask … \`annotated\` c@ — the same elaboration, and the kind is
-- printed: @x : c <- …@.
instance
  ( s' ~ s,
    j ~ 'Open (An c ': s),
    a ~ V (An c ': s) c
  ) =>
  Step (Ann s' c) ('Open s) j a
  where
  step mn live (Ann sc r) k = B.bindAsI sc x r (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @x <- ask …@ in a function body: a bare question is a text question, here
-- as there. The three instances that follow are the exact mirrors of their
-- @'Open'@ twins above, with 'Agentic.Builder.bindI' and
-- 'Agentic.Builder.bindAsI' replaced by 'Agentic.Builder.bindBI' and
-- 'Agentic.Builder.bindAsBI'.
--
-- The index-level Builder forms are what let a body push an anonymous @'An' c@
-- entry onto a scope whose /parameter/ entries carry real symbols: 'Fresh' is
-- not consulted there, and must not be, since a parameter's name and a
-- generated binding name live in one namespace. 'reserved' is what keeps that
-- namespace clean.
instance
  ( s' ~ s,
    j ~ 'Body r (An 'CodeText ': s),
    a ~ V (An 'CodeText ': s) 'CodeText
  ) =>
  Step (Ask s') ('Body r s) j a
  where
  step mn live q k = B.bindBI x (B.one @'CodeText q) (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @x <- panel […]@, @x <- confirm …@, @x <- call f …@,
-- @x <- ask … \`answering\` c@, in a body.
instance
  ( s' ~ s,
    j ~ 'Body r (An c ': s),
    a ~ V (An c ': s) c
  ) =>
  Step (Rhs s' c) ('Body r s) j a
  where
  step mn live r k = B.bindBI x r (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @x : c <- …@ in a body.
instance
  ( s' ~ s,
    j ~ 'Body r (An c ': s),
    a ~ V (An c ': s) c
  ) =>
  Step (Ann s' c) ('Body r s) j a
  where
  step mn live (Ann sc r) k = B.bindAsBI sc x r (k (V x VHere) (x : live))
    where
      x = fromMaybe (genName live) mn

-- | @result <- revising …@ — __the fork__. What this binds is not a value but
-- the branch itself, and the rest of the block is run twice: once under
-- @Settled@, with the settled binder live and its name consed onto the block's
-- own, and once under @Unsettled@, with neither. The two blocks that come back
-- are the arms of the @case result@ 'revising' prints.
--
-- The outgoing stage is the settled arm's, which is what lets one @case@ have
-- two arms in Haskell: a Haskell @case@ has one type, and the arm that binds
-- nothing is the arm that can stand at either scope.
instance
  ( s' ~ s,
    c' ~ c,
    j ~ 'Open (An c ': s),
    a ~ Outcome c s
  ) =>
  Step (Loop c' s') ('Open s) j a
  where
  step mn live lp k =
    loopRun
      lp
      live
      (fromMaybe (resultName live) mn)
      ( Arms
          x
          (k (Settled (V x VHere)) (x : live))
          (k (Unsettled (V x VHere)) (x : live))
      )
    where
      x = genName live

-- | @result <- revisingOn …@ — __the three-way fork__ (D4). The rest of the
-- block is run three times, once per ending, each with the candidate bound; the
-- three blocks that come back are the arms of the @case result@ 'revisingOn'
-- prints.
--
-- It is the same instance as 'Loop'\'s with one more arm, which is the whole
-- of what D4 costs the surface — and the whole of what it costs a program, at
-- compile time and in the term, is that the tail is built three times and
-- replicated @2n+1@ times.
instance
  ( s' ~ s,
    c' ~ c,
    j ~ 'Open (An c ': s),
    a ~ Ending c s
  ) =>
  Step (LoopOn c' s') ('Open s) j a
  where
  step mn live lp k =
    loopOnRun
      lp
      live
      (fromMaybe (resultName live) mn)
      ( Arms3
          x
          x
          x
          (k (SettledOn (V x VHere)) (x : live))
          (k (UnsettledOn (V x VHere)) (x : live))
          (k (AbandonedOn (V x VHere)) (x : live))
      )
    where
      x = genName live

-- | @verdict <- ask …@ inside a revision: the review, elaborated at @verdict@
-- by position, exactly as @checkMembers@ does.
instance
  ( s' ~ (An c ': s),
    j ~ 'Amending c s,
    a ~ V (An 'CodeVerdict ': An c ': s) 'CodeVerdict
  ) =>
  Step (Ask s') ('Review c s) j a
  where
  step mn live q k = clausesOf mn live (Nothing @Code) (B.one @'CodeVerdict q) k

-- | @verdict <- panel […]@ inside a revision — a panel, or a call, or a
-- question whose kind is already said.
instance
  ( s' ~ (An c ': s),
    c' ~ 'CodeVerdict,
    j ~ 'Amending c s,
    a ~ V (An 'CodeVerdict ': An c ': s) 'CodeVerdict
  ) =>
  Step (Rhs s' c') ('Review c s) j a
  where
  step mn live r k = clausesOf mn live (Nothing @Code) r k

-- | @verdict <- panel […] \`annotated\` Verdict@ — the review with its kind
-- printed.
instance
  ( s' ~ (An c ': s),
    c' ~ 'CodeVerdict,
    j ~ 'Amending c s,
    a ~ V (An 'CodeVerdict ': An c ': s) 'CodeVerdict
  ) =>
  Step (Ann s' c') ('Review c s) j a
  where
  step mn live (Ann _ r) k = clausesOf mn live (Just CodeVerdict) r k

-- | The review clause, whichever source wrote it: its name, its printed
-- annotation, itself, and the amendment the rest of the block is.
clausesOf ::
  forall c s.
  Maybe Text ->
  Live ->
  Maybe Code ->
  Rhs (An c ': s) 'CodeVerdict ->
  (V (An 'CodeVerdict ': An c ': s) 'CodeVerdict -> Live -> Amendment c s) ->
  Clauses c s
clausesOf mn live annot review k = case k (V x VHere) (x : live) of
  Amendment am -> Clauses x annot review am
  where
    x = fromMaybe (genName live) mn

-- | A second statement in a revision, which the grammar has no room for.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Ask s') ('Amending c s) j a
  where
  step = error "Step (Ask s) ('Amending c s): unreachable, the instance is a TypeError"

-- | As above, for a source that is not a bare question.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Rhs s' c') ('Amending c s) j a
  where
  step = error "Step (Rhs s c) ('Amending c s): unreachable, the instance is a TypeError"

-- | A bounded revision inside a function body, which
-- 'Agentic.Raw.RawBodyStmt' has no constructor for.
instance
  TypeError
    ( 'TL.Text "a function body is a straight line: it has no bounded \
               \revision, no branch and no `known here` — those belong to the \
               \workflow that calls it"
    ) =>
  Step (Loop c' s') ('Body r s) j a
  where
  step = error "Step (Loop c s) ('Body r s): unreachable, the instance is a TypeError"

-- | A three-way bounded revision inside a function body, which
-- 'Agentic.Raw.RawBodyStmt' has no constructor for either.
instance
  TypeError
    ( 'TL.Text "a function body is a straight line: it has no bounded \
               \revision, no branch and no `known here` — those belong to the \
               \workflow that calls it"
    ) =>
  Step (LoopOn c' s') ('Body r s) j a
  where
  step = error "Step (LoopOn c s) ('Body r s): unreachable, the instance is a TypeError"

-- | A statement-position question, as a value rather than as a block.
--
-- 'act' is written once and stands at two stages — a workflow block and a
-- function body — and the way this module says that is one statement value per
-- construct with one 'Step' instance per stage, never a class over stages.
-- Every instance still dispatches on two heads and nothing else.
newtype Acting (s :: Scope) = Acting (Ask s)

-- | A statement-position call. Only a @-> receipt@ function may stand here,
-- which is the type, and — unlike an 'act' — it adds __no__ context slot. That
-- contrast is what @battery-144@ pins.
data Calling (s :: Scope) where
  Calling :: Fn ps 'CodeAck -> Args s ps -> Calling s

-- | @act …@ in a workflow block.
instance (s' ~ s, j ~ 'Open s, a ~ ()) => Step (Acting s') ('Open s) j a where
  step _ live (Acting q) k = B.act q (k () live)

-- | @act …@ in a function body — @battery-144@'s @applied@ is a body that /is/
-- one act.
instance (s' ~ s, j ~ 'Body r s, a ~ ()) => Step (Acting s') ('Body r s) j a where
  step _ live (Acting q) k = B.actB q (k () live)

-- | @call_ f …@ in a workflow block.
instance (s' ~ s, j ~ 'Open s, a ~ ()) => Step (Calling s') ('Open s) j a where
  step _ live (Calling f as) k = B.callStmt f as (k () live)

-- | @call_ f …@ in a function body.
instance (s' ~ s, j ~ 'Body r s, a ~ ()) => Step (Calling s') ('Body r s) j a where
  step _ live (Calling f as) k = B.callSB f as (k () live)

-- | An act inside a bounded revision, which 'Agentic.Raw.RawRhs' cannot
-- express.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Acting s') ('Review c s) j a
  where
  step = error "Step (Acting s) ('Review c s): unreachable, the instance is a TypeError"

-- | As above, after the review.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Acting s') ('Amending c s) j a
  where
  step = error "Step (Acting s) ('Amending c s): unreachable, the instance is a TypeError"

-- | A statement call inside a bounded revision, refused for 'Acting'\''s
-- reason: a revision's two clauses are sources, and a statement is not one.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Calling s') ('Review c s) j a
  where
  step = error "Step (Calling s) ('Review c s): unreachable, the instance is a TypeError"

-- | As above, after the review.
instance
  TypeError
    ( 'TL.Text "a bounded revision reviews first — `verdict <- panel […]` — \
               \and then amends, and has no other statement"
    ) =>
  Step (Calling s') ('Amending c s) j a
  where
  step = error "Step (Calling s) ('Amending c s): unreachable, the instance is a TypeError"

-- | The block's bind. See "Agentic.Workflow.Do", which is where an author
-- meets it.
bindW ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  (a -> W j k b) ->
  W i k b
bindW m f = W (\live kk -> step Nothing live m (\a live' -> unW (f a) live' kk))

-- | The block's sequencing.
thenW ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  W j k b ->
  W i k b
thenW m n = bindW @st @i @j @a m (\_ -> n)

-- ---------------------------------------------------------------------------
-- Statements and terminals
-- ---------------------------------------------------------------------------

-- | @stop@ — the end of a block.
stop :: W ('Open s) j Term
stop = W (\_ _ -> B.stop)

-- | A statement-position question: it binds nothing, and its answer is a
-- receipt. The scope is unchanged; the plan is weakened past the slot.
--
-- It is an 'Acting' and not a block, which is what lets the same word stand in
-- a workflow block and in a function body; see 'Acting'.
act :: Party p -> Words s -> Acting s
act p w = Acting (ask p w)

-- | @ask_ party words@ — the terminal, answer-discarding question: 'act' and
-- then 'stop', said once.
--
-- The underscore is Haskell's own convention and means here what it means in
-- @mapM_@: the answer is discarded. The difference from 'act' is where it may
-- stand — 'act' is a statement with a block after it, @ask_@ /is/ the end of
-- one — and the two are the same term:
--
-- > ask_ p w  ≡  W.do { act p w; stop }
--
-- literally, not merely observationally: both sides are @B.act (ask p w)
-- B.stop@, because 'act' hands the builder its continuation and the only
-- continuation @stop@ makes is @B.stop@. So the printed 'Agentic.Raw.Raw', the
-- elaborated 'Agentic.Plan.Plan', the bills and the generated names are
-- unchanged by rewriting one into the other — @ask_@ buys a line and costs a
-- program nothing. Nothing needed refreezing when the walked examples took it.
--
-- __Where it does not go.__ A @when@ or @unless@ body is an arm block /minus/
-- its terminal (those combinators supply it), so a body ends in 'act' and an
-- @ask_@ there is a type error — @Couldn't match type ‘Term’ with ‘()’@ — which
-- is the right refusal and not a limitation to work around. Mid-block, where
-- statements follow, 'act' is likewise the only thing that typechecks. @ask_@
-- is for the one shape it names: the block whose last statement is a question
-- nobody reads the answer to.
ask_ :: Party p -> Words s -> W ('Open s) j Term
ask_ p w = W (\_ _ -> B.act (ask p w) B.stop)

-- | @known here: …@ — an assertion, and no node at all. The names are the
-- ones the block is carrying, innermost first, so this prints what the
-- bindings actually print — generated or 'named' — and cannot print a wrong
-- one.
knownHere :: W ('Open s) ('Open s) ()
knownHere = W (\live k -> B.knownHereI live (k ()))

-- | Haskell's @if@, over a flag handle and two blocks — which is what
--
-- > if ok
-- >   then W.do
-- >     act (tool "apply") [wf|Apply: {patch}|]
-- >     stop
-- >   else stop
--
-- means in an authoring module, because such a module enables
-- @RebindableSyntax@ and this is the @ifThenElse@ it then finds. There is no
-- @ifFlag ok (…) (…)@ to write and no combinator to remember: an @if@ is an
-- @if@, its two branches are blocks, and the flag's kind comes from the
-- handle, so a question that is not a 'confirm' cannot be decided on.
--
-- __It forks here, at the @if@__, and not at the flag's bind — because a flag
-- may be bound, acted past, and only then branched on. See \"Two branches, two
-- mechanisms\".
--
-- @RebindableSyntax@ costs an authoring module its implicit @Prelude@ (import
-- it, and @Data.String (fromString)@ beside it if the module also enables
-- @OverloadedStrings@) and costs a @W.do@ block nothing at all: @QualifiedDo@
-- rebinds the block it is written on, and @RebindableSyntax@ rebinds only
-- unqualified syntax.
ifThenElse ::
  forall h s j.
  KnownIx h s =>
  V h 'CodeFlag ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
ifThenElse = ifFlag

-- | @if x { … } else { … }@ — a terminal, and the combinator 'ifThenElse' is.
-- Exported because it is the desugaring and a reader of a printed program
-- should be able to find it by name; an author writes the @if@.
ifFlag ::
  forall h s j.
  KnownIx h s =>
  V h 'CodeFlag ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
ifFlag v yes no =
  W
    ( \live _ ->
        B.ifFlag @h @s v (runW live yes) (runW live no)
    )

-- | @when ok $ W.do …@ — the one-armed @if@, for the shape an author writes
-- most often:
--
-- > when ok $ W.do
-- >     act (tool "apply") [wf|Apply: {patch}|]
--
-- which is exactly
--
-- > if ok
-- >   then W.do
-- >     act (tool "apply") [wf|Apply: {patch}|]
-- >     stop
-- >   else stop
--
-- and prints the very same 'Agentic.Raw.RawIfFlag' — an @ifFlag@ whose else
-- arm is the empty block, and whose then arm is the body followed by the same
-- empty block. Nothing is added to the language: this is 'ifThenElse' with
-- both terminals supplied.
--
-- __It is terminal, and that is not Haskell's @when@.__ In this language every
-- branching is terminal — each arm /is/ the rest of the workflow — so there is
-- no continuation for the two arms to share. A continuing @when@, the one
-- @Control.Monad@ exports, would have to take the statements after it and
-- print them __twice__, once in each arm: the program a reader met would not
-- be the program the author wrote, and a long tail after a short @when@ would
-- print at double length. So this one seals its body with the implicit @stop@
-- that an arm block's end is, and its result type is the
-- terminal: a statement written after a @when@ is the same
-- @nothing follows a terminal@ error a statement after @stop@ or after an @if@
-- already is.
--
-- The body is what an @if@ arm may hold /minus/ its terminal — acts, binds,
-- @known here@ — and it is unit-valued, so a body that ends in @stop@ or in a
-- branch does not typecheck here: that block is already whole, and it belongs
-- to the @if@ this sugars.
--
-- __The body is a statement, not a block__, because a one-statement @W.do@
-- /is/ that statement: @QualifiedDo@ leaves a block's last statement alone, so
-- @when ok $ W.do act …@ hands this an 'Acting' and never a 'W'. A 'W' is a
-- statement too (its 'Step' instance is the first one above), so a body of two
-- statements or twenty reaches this by the same door.
when ::
  forall h s s' st j.
  (KnownIx h s, Step st ('Open s) ('Open s') ()) =>
  V h 'CodeFlag ->
  st ->
  W ('Open s) j Term
when v body = ifThenElse v (thenW @st @('Open s) @('Open s') @() body stop) stop

-- | @unless ok $ W.do …@ — 'when' on the other arm, and terminal for the same
-- reason.
--
-- __The flag is not negated; the arms are swapped.__ There is no negation to
-- reach for: 'Agentic.Raw.RawIfFlag' branches on a flag /binding/ and neither
-- the @Raw@ nor the @Plan@ has a @not@, so inventing one here would be a
-- construct neither of them can express. What this prints is the same
-- @ifFlag@ 'when' prints with its two arms exchanged — the body in the else
-- arm, the empty block in the then arm — which is a program the two-armed
-- 'ifThenElse' prints too.
unless ::
  forall h s s' st j.
  (KnownIx h s, Step st ('Open s) ('Open s') ()) =>
  V h 'CodeFlag ->
  st ->
  W ('Open s) j Term
unless v body = ifThenElse v stop (thenW @st @('Open s) @('Open s') @() body stop)

-- | @case x { approved … objected … no answer … }@ — a terminal, its arms
-- positional, in Lean's order.
--
-- __This one stays a combinator__, where a revision's result became a Haskell
-- @case@ and a flag became a Haskell @if@. A verdict is a value: it may be
-- bound, spliced into a later prompt, acted past, and branched on many
-- statements after its bind, so nothing may fork at its binding — and its
-- three arms are Lean's three tags in Lean's order rather than the
-- constructors of any Haskell type, so nothing may fork at a pattern either.
caseVerdict ::
  forall h s j.
  KnownIx h s =>
  V h 'CodeVerdict ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
caseVerdict v approved objected noAnswer =
  W
    ( \live _ ->
        B.caseVerdict @h @s
          v
          (runW live approved)
          (runW live objected)
          (runW live noAnswer)
    )

-- ---------------------------------------------------------------------------
-- The bounded revision, and the case that consumes it
-- ---------------------------------------------------------------------------

-- | @at most n amendments@.
newtype Bound = Bound Integer

-- | The bound: @0 <= n <= 64@, which is Lean's @maxRevisions@ and is checked
-- where the loop is built.
atMost :: Integer -> Bound
atMost = Bound

-- | The loop, awaiting the two things its statement cannot give it: the
-- result's name, and the two arms of the @case@ that consumes it.
newtype Loop (c :: Code) (s :: Scope) = Loop
  {loopRun :: Live -> Text -> Arms c s -> Blk s}

-- | What a bounded revision binds, and the one thing a workflow's @case@ is
-- written on:
--
-- > result <- revising draft (atMost 2) \patch -> W.do …
-- > case result of
-- >   Settled   patch -> W.do …
-- >   Unsettled patch -> stop
--
-- A regular data type, matched by a regular pattern, whose arms happen to be
-- @W.do@ blocks. __Both constructors carry the candidate__ (D3): @Settled@ the
-- artefact a review approved, @Unsettled@ the one the loop ran out holding —
-- the artefact the last amendment produced and the final review objected to.
-- Each is a handle like any other, live in its own arm and in no other, so a
-- hole that splices one arm's binder in the other is GHC's own
-- @Variable not in scope@ and not a rule this library has to state.
--
-- __The bind forks.__ There is no value here to case on at run time: the
-- @case@ is the branch, and 'revising'\''s 'Step' runs the rest of the block
-- twice — once under @Settled@ and once under @Unsettled@ — to obtain the two
-- arms it prints. That is exact, because Lean refuses every statement between
-- a revision's bind and its @case@ (@Check.lean:653@), so the two runs can
-- differ only in the arms themselves.
--
-- __Both runs are typed at the same scope, and now that scope is honest.__ A
-- Haskell @case@ has one type, so the fork always built both arms at
-- @'An' c ': s@; before D3 the unsettled run had no handle to bind there and an
-- unexported @unsettledArm@ undid the weakening by closing the slot with the
-- kind's default. The slot is now a binder the arm may read, both arms are
-- checked at @pd.code :: Γ@ in Lean too, and that function has no reason to
-- exist. What is left is 'genName', which reads the depth off the 'Live' names
-- so that both arms print the binder the frozen programs print.
data Outcome (c :: Code) (s :: Scope)
  = -- | the loop settled, and this is what it settled on
    Settled (V (An c ': s) c)
  | -- | the bound ran out, and this is the candidate it ran out holding — the
    -- artefact the last amendment produced and the final review objected to,
    -- and not one that would have been produced by amending in response to that
    -- objection, which was never asked for
    Unsettled (V (An c ': s) c)

-- | @amend patch { … }@ — at the candidate's kind, reading the verdict beside
-- it.
amend ::
  KnownCode c =>
  Ask (An 'CodeVerdict ': An c ': s) ->
  W ('Amending c s) j Term
amend q = W (\_ _ -> Amendment (B.one q))

-- | @result <- revising draft (atMost n) \\patch -> W.do …@, and the
-- @case result of@ that follows it.
--
-- The candidate's kind is the __subject's__ kind, so it is read off the
-- handle and not chosen; the carrier is bound by the clauses' lambda, and the
-- name it prints is the generated one for the enclosing depth — the same name
-- the settled binder prints, one scope over, exactly as the flagship calls
-- both @patch@.
--
-- What this /returns/ is a loop and not a block, because a bounded revision
-- and the @case@ that consumes it are __one__ node: the intermediate has type
-- @Plan Γ (El c, Bool)@ and @Ctx@ has no code for a candidate-and-ending pair.
-- Lean carries it as a @Pend Γ@ that the next statement must consume
-- (@Check.lean:639@); here the 'Step' at 'Loop' forks the rest of the block
-- into the two arms and this closes over both. See 'Outcome'.
revising ::
  forall h c s.
  (KnownIx h s, KnownCode c) =>
  V h c ->
  Bound ->
  (V (An c ': s) c -> W ('Review c s) ('Amending c s) Term) ->
  Loop c s
revising subj (Bound n) clauses = Loop $ \live result arms ->
  let carrier = genName live
   in case (runRev (carrier : live) (clauses (V carrier VHere)), arms) of
        (Clauses revName revAnn review am, Arms settledName settled unsettled) ->
          B.revisingCaseI @c
            (vName subj)
            (B.readV @h @s subj)
            carrier
            revName
            settledName
            -- The unsettled binder's printed name is the settled one: both arms
            -- are built at the same depth, so 'genName' answers alike for both,
            -- and the two are binders in disjoint scopes rather than one binder.
            -- That is what every frozen entry carries.
            settledName
            result
            n
            revAnn
            review
            am
            settled
            unsettled

-- ---------------------------------------------------------------------------
-- The three-way bounded revision
-- ---------------------------------------------------------------------------

-- | The three-way loop, awaiting the two things its statement cannot give it:
-- the result's name, and the three arms of the @case@ that consumes it.
newtype LoopOn (c :: Code) (s :: Scope) = LoopOn
  {loopOnRun :: Live -> Text -> Arms3 c s -> Blk s}

-- | What a three-way bounded revision binds (D4), and the one thing a
-- workflow's @case@ over one is written on:
--
-- > result <- revisingOn draft (atMost 3) \patch -> W.do …
-- > case result of
-- >   SettledOn   patch -> W.do …
-- >   UnsettledOn patch -> W.do …   -- the bound ran out; the tree keeps the edits
-- >   AbandonedOn _     -> stop     -- the reviewer would not answer
--
-- Each constructor carries the candidate in hand, exactly as 'Outcome'\'s two
-- do.
--
-- __Why the names are not @Settled@ \/ @Unsettled@ \/ @Abandoned@.__ They
-- would be, and the design writes them that way; but Haskell has one
-- constructor namespace per module and 'Outcome' already spells the first two.
-- Renaming 'Outcome'\'s would move the pattern every existing program writes.
-- So the three-way endings take the suffix their loop already carries, and a
-- reader who sees @UnsettledOn@ knows it belongs to a @revisingOn@ and not to a
-- @revising@ — which is the distinction the two spellings exist to keep.
data Ending (c :: Code) (s :: Scope)
  = -- | a review approved
    SettledOn (V (An c ': s) c)
  | -- | the bound ran out with an objection outstanding
    UnsettledOn (V (An c ': s) c)
  | -- | a review declined: no answer, and no more trips
    AbandonedOn (V (An c ': s) c)

-- | @result \<- revisingOn draft (atMost n) \\patch -> W.do …@, and the
-- @case result of@ that follows it — the same bounded revision, whose round
-- reads the review's __verdict tag__ three ways rather than one predicate two
-- ways (D4).
--
-- 'revising' tests approval, so an objection and a refusal are the same thing
-- to it: a refusal buys a trip it should end. This one maps the verdict's three
-- tags onto three fates — approval settles, an objection amends (or, at the
-- last round, leaves the loop unsettled), a refusal abandons — which is
-- Isaac's @WORK COMPLETE@ \/ @WORK REMAINS@ \/ protocol-violation distinction
-- made expressible.
--
-- __Two prices, both real.__ The rest of the block is built three times at the
-- Haskell level and the 'Blk' it produces is replicated @2n+1@ times in the
-- plan, so a @revisingOn@ with a long tail is a compile-time cost and a
-- term-size cost that a @revising@ is not — and the answer when it bites is to
-- put the tail in a 'function' and call it once per arm. And @stop@ in an arm
-- is still an arm the author must write: the @case@ is total, so only the data
-- is added.
revisingOn ::
  forall h c s.
  (KnownIx h s, KnownCode c) =>
  V h c ->
  Bound ->
  (V (An c ': s) c -> W ('Review c s) ('Amending c s) Term) ->
  LoopOn c s
revisingOn subj (Bound n) clauses = LoopOn $ \live result arms ->
  let carrier = genName live
   in case (runRev (carrier : live) (clauses (V carrier VHere)), arms) of
        (Clauses revName revAnn review am, Arms3 sname uname aname st un ab) ->
          B.revisingOnCaseI @c
            (vName subj)
            (B.readV @h @s subj)
            carrier
            revName
            sname
            uname
            aname
            result
            n
            revAnn
            review
            am
            st
            un
            ab

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- | The handles a parameter list hands its body, as a curried function.
--
-- "Agentic.Builder" hands a body its handles as a nested tuple ending in @()@
-- (@paramHandles@), and a six-parameter tuple pattern is not something to ask
-- an author for. @hs@ is concrete the moment the parameter list is written, so
-- @'Curried' hs r@ reduces before the body is elaborated and each lambda
-- binder's type is known — which is what keeps a @[wf|{goal}|]@ hole's
-- inference eager, exactly as the 'Step' instances' head-dispatch discipline
-- does elsewhere in this module.
--
-- The instance head is @(V h c, hs)@ rather than @(a, hs)@ so that the family
-- reduces only on a real handle tuple, and so that an input list's tuple of
-- 'Text's takes its own instance rather than this one.
class Curries (hs :: Type) where
  -- | @r@, behind one arrow per element of @hs@.
  type Curried hs (r :: Type) :: Type

  -- | Feed the tuple to the curried function, left to right.
  applyTo :: Curried hs r -> hs -> r

instance Curries () where
  type Curried () r = r
  applyTo r () = r

instance Curries hs => Curries (V h c, hs) where
  type Curried (V h c, hs) r = V h c -> Curried hs r
  applyTo f (v, hs) = applyTo (f v) hs

-- | One parameter, named and kinded: @takes \@"goal" Text@.
--
-- The name is a type-level 'GHC.TypeLits.Symbol' because that is what makes
-- two parameters of one name a compile error (@Fresh@), and it is the very
-- 'Text' the printed signature and every hole in the body carry. This is the
-- one place the authoring surface asks an author for a name at the type level,
-- and it asks because a parameter's name is /printed/ — in @params@, and again
-- in every hole of the body — where a binding's is generated.
--
-- A parameter list is a function from /the rest of the list/ to /the whole
-- list/, so lists compose with @(.)@ and end at 'noParams':
--
-- > (takes @"correctness" Text . takes @"haskell" Text) noParams
takes ::
  forall n c cs acc s hs.
  (KnownSymbol n, Fresh n acc) =>
  Answer c ->
  Params cs ('(n, c) ': acc) s hs ->
  Params (c ': cs) acc s (V ('(n, c) ': acc) c, hs)
takes a rest
  | reserved nm = reservedError "takes" nm
  | otherwise = withAnswer a (B.param @n @c rest)
  where
    nm = T.pack (symbolVal (Proxy @n))

-- | The parameter names, in source order.
--
-- "Agentic.Builder" computes the same list for the printed signature;
-- walking the GADT here is what keeps that module untouched. A body has no
-- @known here@ — 'Agentic.Raw.RawBodyStmt' has no such constructor — so the
-- only thing these names are is 'genName'\''s depth.
paramNames :: Params ps acc s hs -> [Text]
paramNames PNil = []
paramNames (PCons p _ rest) = T.pack (symbolVal p) : paramNames rest

-- | A function: a name, a parameter list, and a body that is a straight-line
-- @W.do@ block over exactly those parameters.
--
-- > libDrafted :: Fn '[ 'CodeText] 'CodeText
-- > libDrafted = function "lib.drafted" (takes @"goal" Text noParams) \goal -> W.do
-- >     d <- ask (model "author") [wf|draft: {goal}|]
-- >     answer d
--
-- The result kind is read off the body's terminal — @answer x@ at @x@'s kind,
-- 'done' at @receipt@ — so nothing has to be said twice.
--
-- @Codes s ~ ParamCtx ps@ is "Agentic.Builder"\'s own constraint; both sides
-- reduce to the same concrete list once the parameter list is written, so it
-- discharges by reduction and never appears in an author's error.
function ::
  forall r ps s hs.
  (KnownCode r, Codes s ~ ParamCtx ps, Curries hs) =>
  Text ->
  Params ps '[] s hs ->
  Curried hs (W ('Body r s) ('Body r s) Term) ->
  Fn ps r
function nm ps body =
  B.function nm ps $ \hs ->
    runBody
      (reverse (paramNames ps))
      (applyTo body hs :: W ('Body r s) ('Body r s) Term)

-- | @answer x@ — the body's value, at the kind the handle carries, which is
-- the function's declared result.
answer :: forall h s c j. KnownIx h s => V h c -> W ('Body c s) j Term
answer v = W (\_ _ -> B.answerB @h @s v)

-- | The end of a @-> receipt@ body: it answers nothing, and the caller gets a
-- receipt.
--
-- Not 'stop': a block that stops ends the workflow, and a body that is done
-- hands control back to its caller. Overloading one word for the two would
-- make it mean two things in two places; here a @done@ written in a workflow
-- block is @Couldn't match ‘Open’ with ‘Body’@ and a @stop@ written in a body
-- is the same error the other way, and a @done@ in a value-returning body is
-- @Couldn't match ‘CodeAck’ with ‘CodeText’@, which is the right refusal.
done :: W ('Body 'CodeAck s) j Term
done = W (\_ _ -> B.endB)

-- ---------------------------------------------------------------------------
-- The chain both lists are written with
-- ---------------------------------------------------------------------------

-- | The cons of a chain — @x :> rest@ — at both of the chains this surface
-- has: a call's arguments, @arg guide :> arg goal :> noArgs@, and a program's
-- inputs, @input "request" :> input "base" :> noInputs@.
--
-- __One spelling, because they are one shape__: an element, the rest, and an
-- end that names itself ('noArgs', 'noInputs'). An author who has written the
-- one has written the other, and neither reads as what the inputs chain used
-- to read as — a function applied to its own tail, nesting to the right in
-- parentheses while the argument list beside it stayed flat.
--
-- The result is __determined__ by the element and the tail, which is what lets
-- a chain of any length infer with no annotation of any kind: an end is a
-- concrete type, so each link fixes the link above it, out to the type the
-- call site or 'taking' expects.
--
-- __Why 'In' exists.__ That determination reads the element's type, so an
-- element must have one. An argument has one — 'arg' answers an 'Arg'
-- whatever it was given — and a name written as a literal does not: under
-- @OverloadedStrings@ a bare @"request"@ is any string type at all, and an
-- element of unknown type is a link this class cannot close. 'input' is what
-- gives a name its type, and is the only thing that makes an 'In'.
--
-- The methods are not exported: an author writes @:>@, and the two chains
-- this module defines are the two there are.
class Chain e t r | e t -> r where
  -- | @x :> rest@, built.
  chainCons :: e -> t -> r

  -- | @x :> rest@, read back. It is total at each instance — a chain whose
  -- type says it has a head cannot be the empty one — and it exists because
  -- Haskell requires an explicitly bidirectional synonym to carry a matcher
  -- for @:>@ to stand in expressions at all. Matching through @:>@ is /not/
  -- supported surface: the fundep runs @e t -> r@ only, so a match is
  -- ambiguous without annotations on both bound variables — an annotation
  -- burden construction never has, and nothing in either repository matches
  -- a chain. Chains are built, and read back by the elaborator through the
  -- constructors.
  chainUncons :: r -> (e, t)

-- | The element, onto the rest of the chain: 'Chain'\'s cons, at both chains.
--
-- __It is a pattern synonym because it has to be.__ An operator that begins
-- with @:@ /is/ a constructor name in Haskell, so an overloaded @:>@ cannot be
-- a class method — the one thing a constructor name may also be is a pattern
-- synonym, and a pattern synonym may carry a class context. That context is
-- 'Chain', so @:>@ means at each use exactly what the instance chosen there
-- means, and means nothing anywhere else.
pattern (:>) :: Chain e t r => e -> t -> r
pattern x :> rest <-
  (chainUncons -> (x, rest))
  where
    x :> rest = chainCons x rest

infixr 5 :>

-- | One argument, onto the rest of an argument list.
--
-- The scope equality sits in the context rather than in the head, as it does
-- in 'Gives': the link is chosen on the shape alone and /then/ says the two
-- scopes are one, rather than waiting to be told that they already are.
instance s ~ s' => Chain (Arg s c) (Args s' ps) (Args s' (c ': ps)) where
  chainCons = ACons
  chainUncons (ACons a as) = (a, as)

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

-- | A value call: the callee's questions, inlined at the call site in body
-- order, with the caller's arguments in their prompts. __No node is added.__
--
-- It is an 'Rhs', so it binds wherever an 'Rhs' binds — in a workflow block, in
-- a function body, and as a bounded revision's /review/, which is what makes a
-- shared review tier one 'Fn' that several workflows call.
call :: Fn ps r -> Args s ps -> Rhs s r
call = B.callV

-- | A statement call: @call_ f args@, where @f@ answers a receipt.
--
-- @X@ binds and @X_@ stands as a statement, which is 'ask_'\''s convention and
-- @mapM_@'s.
call_ :: Fn ps 'CodeAck -> Args s ps -> Calling s
call_ = Calling

-- | The end of an argument list, for symmetry with 'noParams'.
noArgs :: Args s '[]
noArgs = ANil

-- | What may stand as one argument at a call site.
--
-- __Not 'Says'.__ A handle passed as an argument prints as a /name/
-- (@{"name": {"x": "b1"}}@), where the same handle in a prompt prints as an
-- @interp@ chunk. The two classes therefore differ in exactly the instance
-- that matters, and reusing 'Says' here would silently pass a binding by its
-- rendered text instead of by reference.
--
-- The kind equalities sit in the context rather than in the head, so an
-- argument of the wrong kind is @Couldn't match ‘'CodeVerdict’ with
-- ‘'CodeText’@ rather than a missing instance.
class Gives a (s :: Scope) (c :: Code) where
  -- | This value, as an argument at the parameter's kind.
  arg :: a -> Arg s c

-- | A binding in scope, which must answer the parameter's kind exactly — no
-- silent rendering, so a verdict does not fill a @text@ parameter.
instance (KnownIx h s, c' ~ c) => Gives (V h c') s c where
  arg = B.argName

-- | A @define@ written as a fence, elaborated in the /caller's/ bindings, so a
-- hole in it reads the caller's names.
instance (s ~ s', c ~ 'CodeText) => Gives [Piece s'] s c where
  arg = B.argWords

-- | A @define@ that is a string. It prints as an @ArgLit@, which is the only
-- non-name argument 'Agentic.Raw.RawArg' has.
instance c ~ 'CodeText => Gives Text s c where
  arg t = B.argWords [lit t]

-- ---------------------------------------------------------------------------
-- Programs
-- ---------------------------------------------------------------------------

-- | A whole program: the function table in declaration order, and the
-- workflow.
--
-- > reviewLite = defining [SomeFn reviewReport] W.do …
--
-- __What this checks, and why it is here.__ A 'Fn' is a Haskell value, so a
-- /call/ cannot name something that does not exist. Two things about the
-- /table/ are not decidable from the call sites, and both print a program the
-- language refuses while GHC is content: a duplicate name, and a callee that
-- is not declared strictly earlier — @callAsks@ answers @0@ for a name it does
-- not find (@Guards.hs:101@), so such a program silently prices wrong and Lean
-- refuses it as @unbound@. 'tableProblem' is both, on a CAF, so it fires the
-- first time anything touches the program — the idiom 'panel' already uses.
defining :: [SomeFn] -> W ('Open '[]) ('Open '[]) Term -> Program
defining fns b = case tableProblem prog of
  Just msg -> error (T.unpack msg)
  Nothing -> prog
  where
    prog = B.program fns (runW [] b)

-- | A whole program with no functions — 'defining' at the empty table, which
-- is what it has always been.
workflow :: W ('Open '[]) ('Open '[]) Term -> Program
workflow = defining []

-- | 'Nothing' if the table is one the language accepts: no name twice, and
-- every call naming an entry that precedes it.
--
-- Neither is decidable from the 'Fn' values — a call names a Haskell binding,
-- and the /list/ is what says when it was declared — so this walks the printed
-- program instead: every 'RhsCall', 'BodyCallS' and 'RawCallStmt', through
-- every arm, and through both clauses of a bounded revision.
--
-- @guardCheck@ is deliberately not called here: it answers a different
-- question (which of five refusals @checkProgram@ fires first), and an empty
-- panel is already an @error@ at its own site.
tableProblem :: Program -> Maybe Text
tableProblem prog =
  firstOf
    [ dup names,
      firstOf
        [ badCall (Just (fnName f)) (take i names) callee
        | (i, f) <- zip [0 ..] fns,
          callee <- concatMap bodyCalls (fnBody f)
        ],
      firstOf [badCall Nothing names callee | callee <- rawCalls (progMain raw)]
    ]
  where
    raw = B.progRawOut prog
    fns = progFns raw
    names = map fnName fns

    firstOf = listToMaybe . catMaybes

    dup (x : xs)
      | x `elem` xs = Just ("two functions answer to one name: \"" <> x <> "\"")
      | otherwise = dup xs
    dup [] = Nothing

    -- `earlier` is what the caller may name: the entries declared before it,
    -- or the whole table for the workflow, which is checked last.
    badCall caller earlier callee
      | callee `elem` earlier = Nothing
      | callee `elem` names,
        Just from <- caller =
          Just
            ( "\""
                <> from
                <> "\" calls \""
                <> callee
                <> "\", which defining lists after it — a function may call \
                   \only a function declared before it, so that the table can \
                   \be priced"
            )
      | otherwise =
          Just
            ( who
                <> " calls \""
                <> callee
                <> "\", which defining was not given — list it, or the printed \
                   \program names a function that does not exist"
            )
      where
        who = maybe "the workflow" (\f -> "\"" <> f <> "\"") caller

    rhsCalls (RhsCall f _ _) = [f]
    rhsCalls _ = []

    srcCalls (SrcRhs r) = rhsCalls r
    srcCalls (SrcRevising _ _ _ _ _ review am _) = rhsCalls review ++ rhsCalls am
    srcCalls (SrcRevisingOn _ _ _ _ _ review am _) = rhsCalls review ++ rhsCalls am

    bodyCalls (BodyBind _ _ r _) = rhsCalls r
    bodyCalls (BodyAct _ _) = []
    bodyCalls (BodyCallS f _ _) = [f]

    rawCalls = \case
      RawEmpty _ -> []
      RawBind _ _ src rest _ -> srcCalls src ++ rawCalls rest
      RawAct _ rest _ -> rawCalls rest
      RawIfFlag _ yes no _ -> rawCalls yes ++ rawCalls no
      RawCaseVerdict _ a o d _ -> rawCalls a ++ rawCalls o ++ rawCalls d
      RawCaseResult _ _ _ st un _ -> rawCalls st ++ rawCalls un
      RawCaseEnding _ _ _ _ st un ab _ -> rawCalls st ++ rawCalls un ++ rawCalls ab
      RawKnownHere _ rest _ -> rawCalls rest
      RawCallStmt f _ rest _ -> f : rawCalls rest

-- ---------------------------------------------------------------------------
-- A program's inputs
-- ---------------------------------------------------------------------------

-- | A program that needs inputs before it is a program.
--
-- __An input is a @define@ supplied at run time.__ The language already has a
-- construct for author-supplied text that reaches a prompt as data and leaves
-- no node behind, and that is the @define@ — so a program with inputs is an
-- ordinary Haskell function of them, and needs no type-level machinery at all:
-- a define never enters a scope, is never @Fresh@-checked, cannot be shadowed
-- and cannot collide with a binding name.
--
-- __Why not @main@'s parameters.__ 'Agentic.Raw.RawProgram' is @progFns@ and
-- @progMain@, and there is nowhere to print @main@'s parameters; a @main@
-- whose prompts hole a name no printed binder introduces is a program Lean
-- refuses. Making it legal is a change to 'Agentic.Raw', which is not this
-- surface's to make.
--
-- __Inputs are text__, because 'Agentic.Raw.RawArg' has no other literal and
-- because a define is spliced by @Says Text@. An author who wants to select
-- between two /programs/ on a boolean writes an ordinary Haskell function.
data Parameterized = Parameterized
  { -- | the names, in source order, that the CLI binds by
    inputNames :: [Text],
    -- | the program, given one text per name in that order
    supply :: [Text] -> Either Text Program
  }

-- | The inputs a program takes. The type index counts them, so the body may be
-- an ordinary curried Haskell function.
data Ins (hs :: Type) where
  INil :: Ins ()
  ICons :: Text -> Ins hs -> Ins (Text, hs)

-- | The end of an input list.
noInputs :: Ins ()
noInputs = INil

-- | One input's name, on its way into an input list. 'input' makes one, and
-- nothing else does; see 'Chain' for why the name is wrapped rather than
-- passed as the 'Text' it is.
--
-- A @data@ and not a @newtype@, with the field strict: 'input' refuses a
-- misspelled run fact, and a newtype's pattern match is a coercion that forces
-- nothing — so the refusal would have waited until somebody looked at the name,
-- which on a good day is a printed plan and on a bad one is a run that already
-- started. Boxed, @'chainCons'@'s own pattern match is what raises it, at the
-- @:>@ where the mistake was typed.
data In = In !Text

-- | One input, by the name a command line binds it under:
-- @input "request" :> input "base" :> noInputs@.
--
-- A name under the @run.@ prefix is a __run fact__ and is not the command
-- line's to bind: see 'runFacts'. One that is not one of the four is refused
-- here, on a CAF, exactly as 'reserved' refuses a generated binding name — a
-- program declaring @input \"run.whatever\"@ would otherwise elaborate fine and
-- then refuse every @run@ of itself, because the runner has no such fact to
-- bind and @run@ needs every input.
input :: Text -> In
input n
  | reservedInput n, n `notElem` runFacts =
      error
        ( "input: `"
            <> T.unpack n
            <> "` is under the `run.` prefix, which names the facts the runner "
            <> "supplies about the run it is making, and the facts there are "
            <> T.unpack (T.intercalate ", " runFacts)
        )
  | otherwise = In n

-- | Whether an input name is under the prefix the runner owns.
--
-- The prefix and not the list, because the two refusals differ: an /author/ who
-- writes an unknown @run.@ name has misspelled a fact ('input' says so), and an
-- /operator/ who supplies a known one has misunderstood who binds it
-- ('runFactRefusal' says so).
reservedInput :: Text -> Bool
reservedInput = T.isPrefixOf "run."

-- | __The facts a runner supplies about the run it is making__, as the names a
-- program declares them under and a prompt holes them by.
--
-- These are inputs and nothing else: a @define@ supplied at run time, spliced
-- into prompts as literal chunks, invisible to every static fold. What makes
-- them different from @subject@ or @base@ is only /who binds them/ — the runner
-- always does, and no command line may ('runFactRefusal') — because each is a
-- fact about the run rather than about the work:
--
--   * @run.backends@ — how many answerers this run reaches, and which. The
--     roster line the run's header prints, in one line.
--   * @run.engine@ — the engine and its session policy: a canned table, a new
--     session per question, or one session for the whole run. This is the fact
--     that decides whether two answers were reached independently, and it is
--     the runner's to state.
--   * @run.routes@ — the run's route table as the runner resolved it, one line
--     per answerer: the label, @\" = \"@, and the backend's own spelling, with
--     'routeDefaultLabel' first. @run.backends@ is the /roster/, deduplicated
--     and nameless; this is the /mapping/, and no arithmetic over the roster
--     can answer which pin reaches which answerer. Nor can it be derived from
--     @run.engine@, or the other way about: __@run.routes@ says where a
--     question goes and @run.engine@ says whether going there means sharing__ —
--     two pins routed to one @acp:@ adapter share a process and not a
--     conversation. A gate that must know its evaluator is somewhere its
--     workers are not needs both facts, and 'routedBackend' is how it reads
--     this one.
--   * @run.sentinel@ — a line this run generated for itself and put in no other
--     place than the prompts that hole it. An independence probe that asserts
--     such a line without one having been generated asserts nothing; this is
--     what makes the premise true.
--
-- __Why a closed set.__ An open one would be a configuration language: every
-- program would declare its own facts, the runner would grow a flag per fact,
-- and a prompt could come to depend on something the runner learns only
-- halfway through a run. These four are known before the first question is
-- put — they are properties of the command line and of the clock — which is
-- what lets them be /inputs/, bound once, at the moment the program is built.
-- The set is one larger than it was and the argument is unchanged, which is the
-- membership test a fifth will have to pass against a longer list.
--
-- __A run fact a program only holes moves no fold.__ An input reaches the term
-- only as literal chunks inside prompts ('Agentic.Plan.level',
-- 'Agentic.Plan.size', 'Agentic.Plan.askNodes' and 'Agentic.Plan.costM' read no
-- prompt), so a program that splices a run fact prices exactly as it did before
-- — which is why @plan@ and @cost@, where no run is being made, leave them
-- unbound and still answer.
--
-- __A program may also branch on one in Haskell, and then the shape is the
-- value's.__ 'supply' builds the 'Agentic.Builder.Program' after the inputs are
-- known, so a run fact is available to ordinary Haskell before there is a
-- program to fold — which is the cheapest tier there is: zero questions and zero
-- paths, because the arm not taken is not in the term at all. 'sharesOneSession'
-- exists for exactly that, and the honest reading of an unbound fact is what
-- makes it safe: @plan@ and @cost@ print the shape a run with an unknown engine
-- would take, which is the shape that keeps every check the fact was going to
-- gate.
runFacts :: [Text]
runFacts = [runFactBackends, runFactEngine, runFactRoutes, runFactSentinel]

-- | @run.backends@ — the roster line, in the words the header prints.
runFactBackends :: Text
runFactBackends = "run.backends"

-- | @run.engine@ — the engine and its session policy.
runFactEngine :: Text
runFactEngine = "run.engine"

-- | @run.routes@ — the route table, in the words the header prints.
runFactRoutes :: Text
runFactRoutes = "run.routes"

-- | @run.sentinel@ — the line this run generated for itself.
runFactSentinel :: Text
runFactSentinel = "run.sentinel"

-- | __Whether a question is put in a session of its own__, in the one wording
-- every reader of that fact shares.
--
-- It is here and not in "Agentic.Cli" for 'runFactRefusal''s reason: this is a
-- statement about what @run.engine@ /means/, and the runner that prints it, the
-- header that announces it and the program that branches on it must be reading
-- one sentence. Three readers, one spelling — the run's header
-- (@Agentic.Cli.sayBackends@), the fact itself (@Agentic.Cli.runFactsOf@), and
-- any program that gates on 'sharesOneSession'.
--
-- The argument is the policy and not a transport config, because the two
-- transports arrive at it differently and must not each get a wording: an
-- @acp:@ backend reads @Agentic.Acp.acpFreshPerQuestion@, and a @deck:@ backend
-- is 'False' by construction — it sends into a session somebody else started,
-- so there is no per-question session for it to open.
sessionPolicy :: Bool -> Text
sessionPolicy freshPerQuestion
  | freshPerQuestion = "a new session per question"
  | otherwise = oneSessionPhrase

-- | The words 'sessionPolicy' says when every question of a run shares one
-- conversation.
--
-- Named because it is matched as well as printed: 'sharesOneSession' is the
-- match, and a phrase spelled twice would be a gate that stopped agreeing with
-- the header the moment either was reworded.
oneSessionPhrase :: Text
oneSessionPhrase = "one session for the run"

-- | The label the answerer every unclaimed question takes goes under, in
-- @run.routes@ and in the run's own header.
--
-- Named for 'oneSessionPhrase''s reason — it is matched as well as printed, by
-- 'routedBackend' — and __parenthesised__ because a route @NAME@ is a serving
-- model and a bare @default@ could in principle be one. No @--route@ the CLI
-- accepts can produce this line for a program that does not pin a model
-- literally called @(default)@, and it reads as a label rather than as a name.
routeDefaultLabel :: Text
routeDefaultLabel = "(default)"

-- | __Does this @run.engine@ value say that some answerer shares one
-- conversation with the rest of the run?__
--
-- The one machine-readable question a program may ask of that fact, and the
-- reason it is answerable at all is that both halves of the fact are built from
-- 'sessionPolicy'.
--
-- __It is an @isInfixOf@ and not an equality, on purpose.__ A mixed run states
-- both policies in one value (@\"acp: a new session per question; deck: one
-- session for the run\"@), and the honest reading of that is 'True': one of the
-- answerers this run reaches has read everything else it was asked, and a
-- program that needs a separate evaluator cannot tell which of them it got.
--
-- __An unbound fact is 'False'__, which is 'T.isInfixOf''s own answer at the
-- empty text and the right one: @plan@ and @cost@ leave the run facts unbound
-- because no run is being made, and a program priced against a run that does
-- not exist must price the run that might. A gate on this predicate therefore
-- costs a static fold nothing — it is decided in Haskell before the
-- 'Agentic.Builder.Program' exists, so it adds no question and no path — and
-- @cost@ prints the shape a run with an unknown engine would take.
sharesOneSession :: Text -> Bool
sharesOneSession = T.isInfixOf oneSessionPhrase

-- | __The backend a pin reaches__, from a @run.routes@ value: the line that
-- names it, else the default line, else the empty text when the table is empty.
--
-- The fact's one machine-readable question, and it is here for
-- 'sessionPolicy''s reason — __three readers, one spelling__. The runner that
-- prints the fact (@Agentic.Cli.routesFact@), the header that announces the
-- same table (@Agentic.Cli.sayBackends@) and the program that gates on it are
-- reading one sentence; a workflow that wrote its own line-splitter would be a
-- gate that stopped agreeing with the header the moment the separator was
-- reworded.
--
-- __The separator is the first @=@__, both halves trimmed, which is
-- @Agentic.Route.parseRoute@'s own rule and for its reason: a backend value may
-- contain an @=@ (a path) and a label never does.
--
-- __The empty answer is honest and is not a failure.__ @plan@, @cost@ and
-- @--scripted@ have no table at all, and a gate over an unbound fact must
-- decide the shape a run with an unknown table would take — which is the shape
-- that keeps every check the fact was going to gate, exactly as
-- 'sharesOneSession' reads an unbound engine as 'False'.
--
-- __Falling through to the default is the whole point of the default__, and it
-- is why the fact carries that line even on a run with no @--route@ at all: a
-- pin no route claims is answered by the default answerer, so a gate asking
-- where two pins land must be told, and told in one place, that both landed
-- there.
routedBackend :: Text -> Text -> Text
routedBackend table name = case lookup name rows of
  Just b -> b
  Nothing -> fromMaybe "" (lookup routeDefaultLabel rows)
  where
    rows =
      [ (T.strip l, T.strip (T.drop 1 r))
      | ln <- T.lines table,
        let (l, r) = T.breakOn "=" ln,
        not (T.null r)
      ]

-- | The refusal an operator gets for naming a run fact on the command line,
-- and 'Nothing' for every name that is theirs to give.
--
-- It is here rather than in "Agentic.Cli" because it is a statement about what
-- an input /is/, and because a second runner over a second registry must refuse
-- it in the same words. The wording names who binds it, because the operator's
-- next move depends on that: there is no flag to fix, and the fact will be
-- there.
runFactRefusal :: Text -> Maybe Text
runFactRefusal n
  | n `elem` runFacts =
      Just
        ( "input '"
            <> n
            <> "' is a run fact: the runner binds it from the run it is making, "
            <> "and a command line cannot say what a run did. The facts are "
            <> T.intercalate ", " runFacts
            <> ", and every one of them is bound for you"
        )
  | otherwise = Nothing

-- | One input, onto the rest of an input list. The index gains a @Text@,
-- which is what 'taking' curries the body over.
instance Chain In (Ins hs) (Ins (Text, hs)) where
  chainCons (In n) ins = ICons n ins
  chainUncons (ICons n ins) = (In n, ins)

instance Curries hs => Curries (Text, hs) where
  type Curried (Text, hs) r = Text -> Curried hs r
  applyTo f (t, hs) = applyTo (f t) hs

-- | @taking (input "subject" :> noInputs) \\subject -> workflow W.do …@
taking :: forall hs. Curries hs => Ins hs -> Curried hs Program -> Parameterized
taking ins k =
  Parameterized
    { inputNames = insNames ins,
      supply = \ts -> applyTo k <$> insTuple ins ts
    }
  where
    insNames :: Ins hs' -> [Text]
    insNames INil = []
    insNames (ICons n rest) = n : insNames rest

    -- The CLI is the only caller, and it has already refused every wrong
    -- count by name; this is what makes that a fact rather than a comment.
    insTuple :: Ins hs' -> [Text] -> Either Text hs'
    insTuple INil [] = Right ()
    insTuple INil _ = Left tooMany
    insTuple (ICons _ rest) (t : ts) = (,) t <$> insTuple rest ts
    insTuple (ICons _ _) [] = Left tooMany

    tooMany =
      "this program takes "
        <> T.pack (show (length (insNames ins)))
        <> " input(s), named "
        <> T.intercalate ", " (insNames ins)
        <> ", and was given a different number of texts"

-- | What a registry holds: a program, or a program that needs its inputs
-- first.
--
-- It lives here rather than beside a registry because both registries in this
-- repository would otherwise have to import each other: the sum is the union
-- of two of this module's own types, and naming it here is what keeps
-- @Example.Harden@ and @Example.Isaac@ able to list programs of either kind.
data Example
  = -- | a program, whole
    Fixed Program
  | -- | a program, once its inputs are given
    Needs Parameterized
