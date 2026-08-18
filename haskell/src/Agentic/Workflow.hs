{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Agentic.Workflow
-- Description : The authoring surface: a workflow reads as a block of binds.
--
-- "Agentic.Builder" is correct and stays. What this module replaces is the
-- thing a /human writes/: where the builder spells the flagship as
--
-- > bind @"guide" @'CodeText (one (askTool "cat" [lit "…"])) $ \guide -> …
--
-- it should read as @example\/harden.wf@ reads — a block of statements, binds
-- that are binds, prompts that are prose. Every combinator here is sugar: it
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
-- == Two block grammars, one @do@ qualifier
--
-- The language has three block shapes, and each refuses what its
-- 'Agentic.Raw.Raw' cannot express: a workflow block branches and ends in a
-- terminal; a bounded revision has exactly one review and exactly one
-- amendment; a function body is a straight line with no branch and no loop.
-- The first two are both written in @W.do@ ("Agentic.Workflow.Do"), because
-- the /stage/ index already tells them apart: inside a revision only a review
-- may stand, and after it only 'amend'.
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
-- (@Check.lean:537@'s @pendingErr@, raised at @550@, @558@, @566@, @567@,
-- @568@, @680@ and @701@ — every statement form but @.caseResult@), so there
-- is nothing an author could legally have written between the bind and its
-- @case@ for the fork to swallow.
--
-- Where the two do differ, they differ in the /accepting/ direction and not in
-- what a program means. An author who writes a statement between the bind and
-- the @case@ is not refused here; the statement stands in __both__ arms, which
-- is a program the @.wf@ language can also write — by writing it twice — and
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
module Agentic.Workflow
  ( -- * Programs
    Program,
    workflow,

    -- * Prompts
    wf,
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
    drawing,
    Ask,
    ask,
    confirm,
    panel,
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
    knownHere,
    ifThenElse,
    ifFlag,
    -- `when` and `unless` are not Prelude's: they are @Control.Monad@'s, which
    -- an authoring module does not import, so these two shadow nothing. They
    -- are also not that `when` — see their docstrings: these are terminal.
    when,
    unless,
    caseVerdict,

    -- * The bounded revision
    Bound,
    atMost,
    revising,
    Outcome (..),
    Loop,
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
  ( Ask (..),
    Blk (..),
    Code (..),
    Entry,
    Piece,
    Program,
    Rhs,
    Scope,
    Words,
    lit,
  )
import qualified Agentic.Builder as B
import Agentic.Plan
  ( KnownCode,
    SCode,
    Var (VHere),
    defaultEl,
    sCode,
    subCons,
    subId,
    subP,
  )
import Agentic.Raw (Addressee (..))
import Agentic.WF (KnownIx, Says (..), V (..), wf)
import Data.Kind (Constraint, Type)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
-- The @ErrorMessage@ constructors are imported qualified, and only there:
-- @GHC.TypeLits@ spells its literal message @Text@, which is exactly the name
-- 'Answer' gives to the kind @text@, and one of the two has to give way.
import GHC.TypeLits (TypeError)
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
named :: Text -> st -> Nm st
named = Nm

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
    partyServe :: Maybe Text,
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
servedBy p m = p {partyServe = Just m}

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
-- (@Check.lean:207@) made structural — so the kind of anything else has to be
-- said, and this is how a flag says it.
confirm :: Party p -> Words s -> Rhs s 'CodeFlag
confirm p w = B.one (ask p w)

-- | @panel, all must approve […]@ — a verdict, positionally, folded right in
-- the noncommutative verdict monoid.
--
-- A plain list, so that the literal reads like the @.wf@'s bracket list. Its
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
--     the verdict live too.
--
-- Lean's fourth state, @Pend Γ@ (@Check.lean:527@) — a block /pending/ the
-- @case@ that consumes a bounded revision's result — has no stage here,
-- because the fork happens at the bind and the arms are ordinary open blocks.
-- Its refusal is not lost: see \"Two branches, two mechanisms\".
data Stage
  = Open Scope
  | Review Code Scope
  | Amending Code Scope

-- | What a block at a given stage /is/. The family is injective because its
-- three results are distinct type constructors — and it has to be, or
-- unwrapping a 'W' could not recover its indices and @>>=@ would not typecheck
-- at all.
type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s) = Blk s
  Res ('Review c s) = Clauses c s
  Res ('Amending c s) = Amendment c s

-- | The two arms of a @case result@ as the fork produces them: the name the
-- settled binder prints, and the two blocks the rest of the workflow is.
--
-- __Both are at the settled arm's scope__, because both are the one
-- continuation run twice — the second run simply had no @Settled@ handle to
-- bind. 'revising' is where the second is put back at the scope Lean checks it
-- in; see 'unsettledArm'.
data Arms (c :: Code) (s :: Scope)
  = Arms Text (Blk (An c ': s)) (Blk (An c ': s))

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
-- a text question" (@Check.lean:207@) made structural.
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
      (Arms x (k (Settled (V x VHere)) (x : live)) (k Unsettled live))
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
act :: Party p -> Words s -> W ('Open s) ('Open s) ()
act p w = W (\_ k -> B.act (ask p w) (k ()))

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
-- that a @.wf@ arm block's closing brace is, and its result type is the
-- terminal: a statement written after a @when@ is the same
-- @nothing follows a terminal@ error a statement after @stop@ or after an @if@
-- already is.
--
-- The body is what an @if@ arm may hold /minus/ its terminal — acts, binds,
-- @known here@ — and it is unit-valued, so a body that ends in @stop@ or in a
-- branch does not typecheck here: that block is already whole, and it belongs
-- to the @if@ this sugars.
when ::
  forall h s s' j.
  KnownIx h s =>
  V h 'CodeFlag ->
  W ('Open s) ('Open s') () ->
  W ('Open s) j Term
when v body = ifThenElse v (thenW body stop) stop

-- | @unless ok $ W.do …@ — 'when' on the other arm, and terminal for the same
-- reason.
--
-- __The flag is not negated; the arms are swapped.__ There is no negation to
-- reach for: 'Agentic.Raw.RawIfFlag' branches on a flag /binding/ and neither
-- the @Raw@ nor the @Plan@ has a @not@, so inventing one here would be a
-- construct the @.wf@ language cannot print. What this prints is the same
-- @ifFlag@ 'when' prints with its two arms exchanged — the body in the else
-- arm, the empty block in the then arm — which is a program a @.wf@ author can
-- write by hand today.
unless ::
  forall h s s' j.
  KnownIx h s =>
  V h 'CodeFlag ->
  W ('Open s) ('Open s') () ->
  W ('Open s) j Term
unless v body = ifThenElse v stop (thenW body stop)

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
-- >   Settled patch -> W.do …
-- >   Unsettled     -> stop
--
-- A regular data type, matched by a regular pattern, whose arms happen to be
-- @W.do@ blocks. @Settled@ carries the artefact the loop settled on — a handle
-- like any other, live in that arm and in no other, so a hole that splices it
-- in the @Unsettled@ arm is GHC's own @Variable not in scope@ and not a rule
-- this library has to state.
--
-- __The bind forks.__ There is no value here to case on at run time: the
-- @case@ is the branch, and 'revising'\''s 'Step' runs the rest of the block
-- twice — once under @Settled@ and once under @Unsettled@ — to obtain the two
-- arms it prints. That is exact, because Lean refuses every statement between
-- a revision's bind and its @case@ (@Check.lean:537@), so the two runs can
-- differ only in the arms themselves.
--
-- __Both runs are typed at the settled arm's scope__, which is the price a
-- Haskell @case@ charges: its arms have one type. The @Unsettled@ arm has no
-- handle to the settled slot — the pattern binds it in the other arm — so it
-- is exactly the block that would have been written one scope out, weakened;
-- 'unsettledArm' is where that weakening is undone, and 'genName' reads the
-- depth off the 'Live' names so that the arm prints the depth it is /checked/
-- at rather than the one it is /typed/ at.
data Outcome (c :: Code) (s :: Scope)
  = -- | the loop settled, and this is what it settled on
    Settled (V (An c ': s) c)
  | -- | the bound ran out
    Unsettled

-- | The unsettled arm, put back at the scope Lean checks it in.
--
-- The fork hands both arms back at the settled arm's scope, so this one has a
-- slot at index @0@ that it cannot name and never reads: the only handle to it
-- is the @Settled@ pattern's binder, which is not in scope here. Every read it
-- /does/ make is of a name live one scope out, and @KnownIx h ('(n, c) ': s)@
-- is @VThere@ of @KnownIx h s@ — so this block is, index for index, the
-- weakening of the block that would have been built at @s@.
--
-- Closing the slot with the kind's default undoes exactly that weakening:
-- @subP (subP p subWk) (subCons d subId) = subP p (subWk . subCons d subId) =
-- subP p subId = p@. What reaches @revisingCase@ is therefore the very
-- @Plan (Codes s) ()@ Lean's @checkBlock fns Γ S none unsettled@ elaborates,
-- and the @Raw@ — which carries names and not indices — is untouched.
--
-- Deliberately not exported, and deliberately not in "Agentic.Builder": at
-- this one call site the premise is a theorem of Haskell's scoping, and
-- anywhere else it would be an unguarded @Blk (e ': s) -> Blk s@.
unsettledArm :: forall c s. KnownCode c => Blk (An c ': s) -> Blk s
unsettledArm (Blk raw plan) =
  Blk raw (subP plan (subCons (const (defaultEl (sCode @c))) subId))

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
-- @Plan Γ (Option (El c))@ and @Ctx@ has no code for "settled-or-not". Lean
-- carries it as a @Pend Γ@ that the next statement must consume
-- (@Check.lean:527@); here the 'Step' at 'Loop' forks the rest of the block
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
            result
            n
            revAnn
            review
            am
            settled
            (unsettledArm @c unsettled)

-- ---------------------------------------------------------------------------
-- Programs
-- ---------------------------------------------------------------------------

-- | A whole program: the block, over the empty scope, at the empty function
-- table.
workflow :: W ('Open '[]) ('Open '[]) Term -> Program
workflow b = B.program [] (runW [] b)
