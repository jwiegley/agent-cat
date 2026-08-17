{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
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
-- > bind @"guide" @'CodeText (one (askTool "cat" [lit "…"])) $ …
--
-- it should read as @example\/harden.wf@ reads — a block of statements, binds
-- that are binds, prompts that are prose. Every combinator here is sugar: it
-- is an application of a "Agentic.Builder" entry point, so elaboration and
-- printing remain the single proven pairing and this layer cannot mean
-- anything the builder does not already mean.
--
-- An authoring module says exactly this:
--
-- > {-# LANGUAGE BlockArguments, DataKinds, OverloadedLabels,
-- >              OverloadedStrings, QualifiedDo, QuasiQuotes #-}
-- >
-- > import Agentic.Workflow
-- > import qualified Agentic.Workflow.Do as W
-- > import qualified Agentic.Workflow.Revision as R   -- only if it revises
--
-- and then writes:
--
-- > harden :: Program
-- > harden = workflow W.do
-- >   guide <- #guide =: ask (tool "cat")
-- >     [wf|Write out the house style guide, at most four short lines.|]
-- >
-- >   #result =: revising draft #patch (atMost 2) \patch -> R.do
-- >     verdict <- #verdict =: panel [ ask (model "reviewer-correct") [wf|{guide}…{patch}|] ]
-- >     amend (ask (model "author" `servedBy` "deep") [wf|…{verdict}…|])
-- >
-- >   caseResult #patch (\patch -> W.do …) stop
--
-- __Two names, on purpose.__ The label is the name the /program/ prints; the
-- Haskell binder is the name /the module/ reads. They are spelled the same by
-- convention and nothing enforces it, because enforcing it would mean reading
-- the author's Haskell with Template Haskell — a second surface language
-- living inside a bracket. A label that disagrees with its binder prints a
-- name the reader did not expect; it cannot make the program mean something
-- else.
--
-- __Three block grammars, three @do@ qualifiers.__ The language has three, and
-- each refuses what its 'Agentic.Raw.Raw' cannot express: a workflow block
-- branches and ends in a terminal ("Agentic.Workflow.Do"); a bounded revision
-- has exactly one review and exactly one amendment
-- ("Agentic.Workflow.Revision"); a function body is a straight line with no
-- branch and no loop. @QualifiedDo@ is per-block, so an authoring module still
-- has ordinary @do@, @if@ and numeric literals for everything else.
--
-- == What must not compile
--
-- GHC has no negative-test harness here, so the refusals are recorded as the
-- messages they produce. Each is the design and not an accident:
--
--   * a second bind of a live name —
--     @this name is already in scope, and a live name is not introduced twice@;
--   * a statement after @stop@, @if@ or @case@ —
--     @nothing follows a terminal: `stop`, `if` and `case` end a block@;
--   * a block that does not end in a terminal —
--     @Couldn't match type ‘()’ with ‘Term’@;
--   * @served by@ on a tool or a person —
--     @Couldn't match type ‘IsTool’ with ‘IsModel’@;
--   * a flag spliced into a prompt —
--     @only a text or a verdict answer interpolates into a prompt@;
--   * a name read where it is not live — @unbound name; nothing in scope
--     answers to that name@ (the type-level half) or GHC's own
--     @Variable not in scope@ (the Haskell half);
--   * a revision with two reviews, or none —
--     @a bounded revision reviews first … and then amends, and has no other
--     statement@;
--   * a workflow left pending its @case@, or a @caseResult@ with no revision
--     before it — neither has a stage the other can meet.
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
    hole,

    -- * Names
    Label,
    V,
    Named,
    (=:),

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
    bindW,
    thenW,

    -- * Statements and terminals
    stop,
    act,
    knownHere,
    ifFlag,
    caseVerdict,
    caseResult,

    -- * The bounded revision
    Bound,
    atMost,
    revising,
    Loop,
    Clauses,
    Amendment,
    amend,
    ReviewSrc (..),
    bindR,

    -- * The scope, as the block grammars' signatures need it
    Code (..),
    Scope,
    Fresh,
    LookupC,
    KnownVar,
    KnownScope,
    Blk,
    Rhs,
  )
where

import Agentic.Builder
  ( Ask (..),
    Blk,
    Code (..),
    Fresh,
    KnownScope,
    KnownVar (..),
    LookupC,
    Piece,
    Program,
    Rhs,
    Scope,
    Words,
    hole,
    lit,
  )
import qualified Agentic.Builder as B
import Agentic.Plan (KnownCode, SCode, sCode)
import Agentic.Raw (Addressee (..))
import Agentic.WF (Says (..), V (..), wf)
import Data.Kind (Constraint, Type)
import qualified Data.List.NonEmpty as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.OverloadedLabels (IsLabel (..))
-- The @ErrorMessage@ constructors are imported qualified, and only there:
-- @GHC.TypeLits@ spells its literal message @Text@, which is exactly the name
-- 'Answer' gives to the kind @text@, and one of the two has to give way.
import GHC.TypeLits (KnownSymbol, Symbol, TypeError, symbolVal)
import qualified GHC.TypeLits as TL

-- ---------------------------------------------------------------------------
-- Names: labels, handles, and (=:)
-- ---------------------------------------------------------------------------

-- | The author's name for a binding, written @#guide@. The phantom is the
-- whole value: a label carries no runtime content, and becomes a 'Text'
-- exactly once, in the 'Step' instance that prints it.
data Label (n :: Symbol) = Label

-- | The equality-in-the-context form, so that @#guide@ /unifies with/ an
-- expected @Label n@ rather than demanding one.
instance n ~ n' => IsLabel n (Label n') where
  fromLabel = Label

-- | @#x =: source@ — a statement awaiting the block's @>>=@.
data Named (n :: Symbol) src = Named src

-- | Name a source. The label is what the program prints; what the statement
-- /is/ is decided by the source, through 'Step'.
(=:) :: Label n -> src -> Named n src
_ =: src = Named src

infix 1 =:

-- | The name, as the printer writes it.
nameText :: forall n. KnownSymbol n => Text
nameText = T.pack (symbolVal (Proxy @n))

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

-- | Lean's @Pend Γ@ (@Check.lean:527@), at the type level: after a bounded
-- revision a block is /pending/ its @case@, and no other statement may stand
-- there.
data Stage = Open Scope | Pending Code Scope

-- | What a block at a given stage /is/. The family is injective because @Blk@
-- and @Arms@ are distinct type constructors — and it has to be, or unwrapping
-- a 'W' could not recover its indices and @>>=@ would not typecheck at all.
type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s) = Blk s
  Res ('Pending c s) = Arms c s

-- | The two arms a pending @case result@ still owes. The settled binder's
-- symbol is existential, exactly as 'B.revisingCaseI' leaves it free.
data Arms (c :: Code) (s :: Scope) where
  Arms :: Text -> Blk ('(ns, c) ': s) -> Blk s -> Arms c s

-- | A block, in continuation-passing style over the stage index: /given what
-- follows, the whole block/. It is the shape of every builder block
-- combinator, all of which take the rest of the block as their last argument,
-- so the desugaring below is a re-association and nothing more.
newtype W (i :: Stage) (j :: Stage) a = W {unW :: (a -> Res j) -> Res i}

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

-- | The block a workflow's @do@ finally is.
runW :: W ('Open s) j Term -> Blk s
runW (W f) = f absurdTerm

-- | What a statement does to a block: which stage it takes, which stage it
-- leaves, and what it binds.
--
-- The functional dependency is not decoration. Without it the stage of a
-- statement is only determined once the /previous/ statement's instance is
-- solved, so inside a @case@ arm the scope is still a metavariable and the
-- constraints from a hole float apart into ambiguity. With it, the improvement
-- is eager: as soon as a statement's type is known, its two stages and its
-- bound value are known.
class Step st (i :: Stage) (j :: Stage) a | st -> i j a where
  step :: st -> (a -> Res j) -> Res i

-- | A statement that is already a block: an 'act', a 'knownHere', a terminal.
instance Step (W i j a) i j a where
  step = unW

-- | @x <- #x =: ask …@ — a bare question in binding position __is__ a text
-- question, which is @usePrompt@'s "a name whose only use is being spliced is
-- a text question" (@Check.lean:207@) made structural.
instance
  (KnownSymbol n, Fresh n s) =>
  Step (Named n (Ask s)) ('Open s) ('Open ('(n, 'CodeText) ': s)) (V n 'CodeText)
  where
  step (Named a) k = B.bindI (nameText @n) (B.one @'CodeText a) (k V)

-- | @x <- #x =: panel […]@, @… =: confirm …@, @… =: ask … \`answering\` c@ —
-- the kind comes from the source, and the annotation stays @null@.
instance
  (KnownSymbol n, Fresh n s) =>
  Step (Named n (Rhs s c)) ('Open s) ('Open ('(n, c) ': s)) (V n c)
  where
  step (Named r) k = B.bindI (nameText @n) r (k V)

-- | @x <- #x =: ask … \`annotated\` c@ — the same elaboration, and the kind is
-- printed: @x : c <- …@.
instance
  (KnownSymbol n, Fresh n s) =>
  Step (Named n (Ann s c)) ('Open s) ('Open ('(n, c) ': s)) (V n c)
  where
  step (Named (Ann c r)) k = B.bindAsI c (nameText @n) r (k V)

-- | @#result =: revising …@ — the block becomes pending its @case@, and binds
-- nothing: the loop's result is not a value.
instance
  KnownSymbol n =>
  Step (Named n (Loop c s)) ('Open s) ('Pending c s) ()
  where
  step (Named lp) k = loopRun lp (nameText @n) (k ())

-- | The workflow block's bind. See "Agentic.Workflow.Do", which is where an
-- author meets it.
bindW ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  (a -> W j k b) ->
  W i k b
bindW m f = W (\kk -> step m (\a -> unW (f a) kk))

-- | The workflow block's sequencing.
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
stop = W (\_ -> B.stop)

-- | A statement-position question: it binds nothing, and its answer is a
-- receipt. The scope is unchanged; the plan is weakened past the slot.
act :: Party p -> Words s -> W ('Open s) ('Open s) ()
act p w = W (\k -> B.act (ask p w) (k ()))

-- | @known here: …@ — an assertion, and no node at all. The names are
-- computed from the type-level scope, so this cannot print a wrong one.
knownHere :: forall s. KnownScope s => W ('Open s) ('Open s) ()
knownHere = W (\k -> B.knownHere @s (k ()))

-- | @if x { … } else { … }@ — a terminal. The flag's kind comes from the
-- handle, so a question that is not a 'confirm' cannot be decided on.
ifFlag ::
  forall n s j.
  (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeFlag) =>
  V n 'CodeFlag ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
ifFlag _ yes no =
  W (\_ -> B.ifFlagI (nameText @n) (varOf @n @s) (runW yes) (runW no))

-- | @case x { approved … objected … no answer … }@ — a terminal, its arms
-- positional, in Lean's order.
caseVerdict ::
  forall n s j.
  (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeVerdict) =>
  V n 'CodeVerdict ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
caseVerdict _ approved objected noAnswer =
  W
    ( \_ ->
        B.caseVerdictI
          (nameText @n)
          (varOf @n @s)
          (runW approved)
          (runW objected)
          (runW noAnswer)
    )

-- ---------------------------------------------------------------------------
-- The bounded revision, and the pending case
-- ---------------------------------------------------------------------------

-- | @at most n amendments@.
newtype Bound = Bound Integer

-- | The bound: @0 <= n <= 64@, which is Lean's @maxRevisions@ and is checked
-- where the loop is built.
atMost :: Integer -> Bound
atMost = Bound

-- | The loop, awaiting the two things its statement cannot give it: the
-- result's name, from the label, and the two arms of the @case@ that must
-- consume it.
newtype Loop (c :: Code) (s :: Scope) = Loop
  {loopRun :: Text -> Arms c s -> Blk s}

-- | The review and the amendment. The review binding's symbol is existential,
-- exactly the freedom 'B.revisingCaseI' already leaves in its @nr@.
data Clauses (nc :: Symbol) (c :: Code) (s :: Scope) where
  Clauses ::
    Text ->
    Maybe Code ->
    Rhs ('(nc, c) ': s) 'CodeVerdict ->
    Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c ->
    Clauses nc c s

-- | The second clause of a revision, which sees the verdict at index @0@ and
-- the candidate at @1@.
newtype Amendment (nc :: Symbol) (nr :: Symbol) (c :: Code) (s :: Scope)
  = Amendment (Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c)

-- | @amend patch { … }@ — at the candidate's kind, reading the verdict beside
-- it.
amend ::
  KnownCode c =>
  Ask ('(nr, 'CodeVerdict) ': '(nc, c) ': s) ->
  Amendment nc nr c s
amend = Amendment . B.one

-- | What may review: a question (elaborated at @verdict@ by position, as
-- @checkMembers@ does), a panel or a call, or either with the kind printed.
class ReviewSrc src (s :: Scope) where
  -- | The review, at @verdict@.
  reviewRhs :: src -> Rhs s 'CodeVerdict

  -- | What the review prints as its annotation.
  reviewAnn :: src -> Maybe Code

instance s ~ s' => ReviewSrc (Ask s') s where
  reviewRhs = B.one
  reviewAnn _ = Nothing

instance (s ~ s', c ~ 'CodeVerdict) => ReviewSrc (Rhs s' c) s where
  reviewRhs r = r
  reviewAnn _ = Nothing

instance (s ~ s', c ~ 'CodeVerdict) => ReviewSrc (Ann s' c) s where
  reviewRhs (Ann _ r) = r
  reviewAnn _ = Just CodeVerdict

-- | The revision block's bind: exactly one review, then exactly one
-- amendment. See "Agentic.Workflow.Revision", which is where an author meets
-- it, and which has no @>>@ at all.
bindR ::
  forall nr src nc c s.
  (KnownSymbol nr, Fresh nr ('(nc, c) ': s), ReviewSrc src ('(nc, c) ': s)) =>
  Named nr src ->
  (V nr 'CodeVerdict -> Amendment nc nr c s) ->
  Clauses nc c s
bindR (Named src) f = case f V of
  Amendment am ->
    Clauses
      (nameText @nr)
      (reviewAnn @src @('(nc, c) ': s) src)
      (reviewRhs @src @('(nc, c) ': s) src)
      am

-- | @result <- revising draft as patch, at most n amendments { … }@.
--
-- The candidate's kind is the __subject's__ kind, so it is looked up and not
-- chosen; the carrier's label names both the printed carrier and the handle
-- the clauses are handed, so the two cannot disagree.
--
-- What this /returns/ is a loop and not a block: a bounded revision's result
-- is not a value, and the very next statement must consume it. That is Lean's
-- @Pend Γ@, and here it is the stage index — no statement but 'caseResult' has
-- a 'Step' at a @Pending@ stage, 'caseResult' alone is ill-typed because
-- nothing else produces one, and 'workflow' wants an @Open@ block at the end.
revising ::
  forall subj carrier c s.
  ( KnownSymbol subj,
    KnownSymbol carrier,
    KnownVar subj s,
    c ~ LookupC subj s,
    KnownCode c,
    Fresh carrier s
  ) =>
  V subj c ->
  Label carrier ->
  Bound ->
  (V carrier c -> Clauses carrier c s) ->
  Loop c s
revising _ _ (Bound n) clauses = Loop $ \resultName arms ->
  case (clauses V, arms) of
    (Clauses revName revAnn review am, Arms settledName settled unsettled) ->
      B.revisingCaseI @c @carrier
        (nameText @subj)
        (varOf @subj @s)
        (nameText @carrier)
        revName
        settledName
        resultName
        n
        revAnn
        review
        am
        settled
        unsettled

-- | @case result { settled p { … } unsettled { … } }@ — a terminal, and the
-- only statement a pending block accepts.
caseResult ::
  forall sname c s j.
  (KnownSymbol sname, Fresh sname s) =>
  Label sname ->
  (V sname c -> W ('Open ('(sname, c) ': s)) j Term) ->
  W ('Open s) j Term ->
  W ('Pending c s) j Term
caseResult _ settled unsettled =
  W (\_ -> Arms (nameText @sname) (runW (settled V)) (runW unsettled))

-- ---------------------------------------------------------------------------
-- Programs
-- ---------------------------------------------------------------------------

-- | A whole program: the block, over the empty scope, at the empty function
-- table.
workflow :: W ('Open '[]) ('Open '[]) Term -> Program
workflow b = B.program [] (runW b)
