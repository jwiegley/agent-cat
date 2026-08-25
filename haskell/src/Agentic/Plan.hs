{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Plan
-- Description : The typed term language and its static folds.
--
-- A port of @Agentic/Core/Plan.lean@ — the five term formers, substitution,
-- grafting and the derived authoring forms — together with the five static
-- folds the oracle's reply record reports: 'level' (@Agentic/Core/Level.lean@),
-- 'size' and 'askNodes' (@Agentic/Core/Explain.lean@), 'codes'
-- (@Agentic/Core/Cost.lean@) and 'costSummary' (@Agentic/Core/Explain.lean@
-- over @Agentic/Core/Cost.lean@'s @costM@).
--
-- __What is not here.__ No parser, no typing judgment, no @CheckError@, no
-- positions. A 'Q' carries no position and a 'Plan' carries no position;
-- positions are oracle-only, like @message@ and @excerpt@. Nothing in this
-- module can refuse a program: well-formedness is the Haskell type checker's
-- job, via @Agentic.Builder@, and the @Raw@-level guards stay in
-- @Agentic.Guards@.
--
-- There is deliberately no @Sig@, no @compSig@ and no @Plan.under@: the DSL
-- elaboration never calls @Plan.under@ (@Dsl/Check.lean:172@'s @askShape@
-- applies @atModel@ to the leaf shape directly, and @Check.lean:185@'s
-- @under_ask1@ is the @rfl@ that licenses it), so porting it would be dead
-- code. 'atModelShape' is the whole of how @served by@ is elaborated.
--
-- There is also no 'Functor', 'Applicative' or 'Monad' instance for 'Plan'. A
-- 'Plan' is a /syntax/; 'mapP' and 'zipWithP' are the functorial and
-- applicative actions and are deliberately not instances, because 'bindP' would
-- then look free when in fact it costs the 'PDyn' quarantine.
--
-- __No 'Eq', 'Ord' or 'Show' for 'Plan', 'Env', 'Expr' or 'Cont'.__ Every
-- former but 'PRet' holds a function, and an 'Env' holds answers behind a lazy
-- tail; a partial instance would be worse than none.
module Agentic.Plan
  ( -- * The answer universe
    El,
    SCode (..),
    fromSCode,
    KnownCode (..),
    defaultEl,

    -- * Verdicts
    Verdict (..),
    verdictApprove,
    verdictDeclined,
    verdictObject,
    verdictMul,
    verdictApproved,
    verdictRender,
    VTag (..),
    verdictTag,

    -- * Questions
    QScope (..),
    scopeUnit,
    scopeMul,
    scopeFst,
    Shape (..),
    Q (..),
    shapeOf,
    withPrompt,
    atModelShape,

    -- * Contexts, environments, variables, expressions
    Ctx,
    Env (..),
    envHead,
    envTail,
    Var (..),
    varGet,
    Expr,
    evalExpr,
    exprUses,
    exprVar,
    exprConst,
    Sub,
    subNil,
    subId,
    subComp,
    subWk,
    subLift,
    subCons,

    -- * The term language
    Ending (..),
    endingOfVTag,
    Tag (..),
    tagValues,
    Plan (..),
    Cont (..),
    subP,
    weakenP,
    graft,
    mapP,
    zipWithP,
    pairP,
    seqP,
    bindP,
    askC1,
    ask1,
    caseB,
    caseV,
    caseE,
    panel,
    panelText,
    revising,
    revisingOn,

    -- * The static folds
    Level (..),
    levelName,
    level,
    size,
    askNodes,
    codes,
    schemaRequirements,
    costM,
    costSummary,
  )
where

import Agentic.Raw (Addressee)
import Agentic.Schema
  ( Code (..),
    El,
    KnownCode (..),
    SCode (..),
    SomeCode,
    SomeSchema (..),
    defaultEl,
    fromSCode,
  )
import Agentic.Text (Verdict (..), block)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- The answer universe lives in Agentic.Schema and is re-exported here.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Verdicts
-- ---------------------------------------------------------------------------

-- The type is @Agentic.Text@'s, imported and re-exported rather than redefined,
-- so a tier1 reply built from a trace and a tier0 reply built from @stringOp@
-- are the same values. What is added here is the algebra @Agentic.Text@ kept
-- private.

-- | The objection record of a verdict. Refusal carries none: it is the monoid's
-- zero, not a one-element list.
objectionsOf :: Verdict -> [Text]
objectionsOf = \case
  Approve -> []
  Declined -> []
  Object os -> os

-- | @Agentic/Core/Question.lean:137@ — the unit @1@ of the verdict monoid.
verdictApprove :: Verdict
verdictApprove = Approve

-- | @Agentic/Core/Question.lean:145@ — the zero @0@, which annihilates.
verdictDeclined :: Verdict
verdictDeclined = Declined

-- | @Agentic/Core/Question.lean:148@ — @↑os@, the free-monoid element.
--
-- The Lean invariant @Object [] == Approve@ (@Verdict.approved_object_iff@) is
-- carried here: an empty objection list /is/ the unit, so it normalizes to
-- 'Approve'. Build objecting verdicts with this, never with the bare 'Object'
-- constructor.
verdictObject :: [Text] -> Verdict
verdictObject [] = Approve
verdictObject os = Object os

-- | The monoid of @Agentic/Core/Question.lean:116@: a zero that annihilates
-- (@:164@, @:167@), and free-monoid concatenation otherwise (@:155@).
--
-- __Not commutative.__ An objection list is a record, and the order in which a
-- panel raised its objections is part of what it said.
verdictMul :: Verdict -> Verdict -> Verdict
verdictMul Declined _ = Declined
verdictMul _ Declined = Declined
verdictMul a b = verdictObject (objectionsOf a ++ objectionsOf b)

-- | @Verdict.approvedB@ (@Agentic/Core/Plan.lean:931@): @decide (v = approve)@,
-- the 'Bool' a 'caseB' branches on inside 'revising'.
--
-- Tests the normalized form, so a stray @Object []@ that escaped
-- 'verdictObject' still counts as approval, exactly as in Lean.
verdictApproved :: Verdict -> Bool
verdictApproved = \case
  Approve -> True
  Object [] -> True
  _ -> False

-- | @Verdict.render@ (@Agentic/Core/Question.lean:269@), over
-- @Verdict.objections@ (@:244@):
--
-- > def objections (v : Verdict) : List Objection :=
-- >   if h : v = 0 then [] else FreeMonoid.toList (WithZero.unzero h)
-- > def render (v : Verdict) : String := String.intercalate "; " (objections v)
--
-- The objections joined by @"; "@. Approval and refusal both render as the
-- empty string — @Verdict.render_declined@ says so on purpose, and the two
-- collapse. This is what a @{v}@ prompt hole at a verdict means.
--
-- One definition on each side. Lean used to carry three copies of this pair —
-- in @Dsl/Syntax.lean@, @HardenPatch.lean@ and @Report.lean@ — glued by an
-- @rfl@ theorem; obr @acat-j61@ folded them into the verdict algebra's own
-- module, which is where this citation now points.
verdictRender :: Verdict -> Text
verdictRender = \case
  Declined -> T.empty
  Approve -> T.empty
  Object os -> T.intercalate "; " os

-- | @Agentic/Core/Plan.lean:297@ — the finite classifier of a verdict: the
-- three answers a @case@ can branch on, while the objections themselves ride in
-- the environment into the arm that was taken.
data VTag
  = VApprove
  | VObject
  | VDeclined
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @Verdict.tag@ (@Agentic/Core/Plan.lean:895@):
--
-- > if v = Verdict.declined then .declined else if v = Verdict.approve then .approve else .object
--
-- Note the decision order — refusal first, then approval, then objection. With
-- the @Object [] == Approve@ invariant held, @verdictTag (Object []) = VApprove@
-- regardless.
verdictTag :: Verdict -> VTag
verdictTag v
  | v == Declined = VDeclined
  | verdictApproved v = VApprove
  | otherwise = VObject

-- ---------------------------------------------------------------------------
-- Scope, shape, question
-- ---------------------------------------------------------------------------

-- | @Agentic/Core/Question.lean:87@'s @QScope := Agentic.Scope String String@:
-- the two-axis scope, each axis independently either unset or set. @axis₁@ is
-- the model and @axis₂@ the mode; the oracle serializes them as @"model"@ and
-- @"mode"@.
data QScope = QScope
  { scopeModelAxis :: !(Maybe Text),
    scopeModeAxis :: !(Maybe Text)
  }
  deriving (Eq, Ord, Show)

-- | The unit @1@ of the scope monoid: both axes silent.
scopeUnit :: QScope
scopeUnit = QScope Nothing Nothing

-- | The product of @Agentic/Scope.lean:101@, axis by axis.
--
-- Per axis: the __right__ operand wins when it is set, else the left survives
-- (@LastOpt.set_overrides@ / @LastOpt.unset_defers@). Read right-to-left as
-- outer-then-inner, that is innermost-wins. Getting the side wrong is exactly
-- the mistake @Agentic/Scope.lean@ warns about — it would make the outermost
-- @served by@ win.
scopeMul :: QScope -> QScope -> QScope
scopeMul (QScope m1 d1) (QScope m2 d2) =
  QScope (maybe m1 Just m2) (maybe d1 Just d2)

-- | @Scope.fst m@ (@Agentic/Scope.lean:175@): the model axis set, the mode axis
-- silent.
scopeFst :: Text -> QScope
scopeFst m = QScope (Just m) Nothing

-- | @Q.Shape c@ (@Agentic/Core/Question.lean:363@) — everything that fixes a
-- question except its words: who is asked, under what standing conditions, and
-- which independent draw it is.
--
-- The type index is phantom, exactly as in Lean (no field mentions @c@); it is
-- kept so an 'PAsk' node's shape is tied to its code.
data Shape (c :: Code) = Shape
  { shAddressee :: !Addressee,
    shScope :: !QScope,
    shDraw :: !Integer
  }
  deriving (Eq, Show)

-- | @Q c@ (@Agentic/Core/Question.lean:337@) — the shape and the words.
--
-- @Q c ≅ Q.Shape c × String@, witnessed by 'shapeOf' and 'withPrompt'.
data Q (c :: Code) = Q
  { qAddressee :: !Addressee,
    qScope :: !QScope,
    qPrompt :: !Text,
    qDraw :: !Integer
  }
  deriving (Eq, Show)

-- | @Q.shape@ (@:375@): the question with its words forgotten.
shapeOf :: Q c -> Shape c
shapeOf q = Shape (qAddressee q) (qScope q) (qDraw q)

-- | @Q.Shape.withPrompt@ (@:378@): the question of this shape whose words are
-- the given text.
withPrompt :: Shape c -> Text -> Q c
withPrompt s p = Q (shAddressee s) (shScope s) p (shDraw s)

-- | @atModel m c s@ of @Agentic/Core/Question.lean:499@, at a single shape:
--
-- > scope := Agentic.Scope.fst m * s.scope
--
-- This is the whole of how @served by@ is elaborated — the checker rewrites the
-- shape, it never wraps the term. The new setting goes on the __left__, so the
-- question's own written scope, being innermost, keeps the last word.
atModelShape :: Text -> Shape c -> Shape c
atModelShape m s = s {shScope = scopeMul (scopeFst m) (shScope s)}

-- ---------------------------------------------------------------------------
-- Contexts, environments, variables, expressions, substitutions
-- ---------------------------------------------------------------------------

-- | @Agentic/Core/Plan.lean:53@ — what is known so far, as a list of answer
-- codes, innermost binding first, so de Bruijn index @0@ is the most recently
-- received answer.
type Ctx = [Code]

-- | @Env Γ@ (@Agentic/Core/Plan.lean:81@): one actual answer for each code the
-- context records, innermost first.
--
-- Lean delays its tail (@consBy@) to keep reading de Bruijn @0@ a projection; in
-- Haskell the constructor field is lazy by default, so the plain constructor
-- already has that property and no @consBy@ is needed. __Do not add strictness
-- annotations here__: the @2^n@ blow-up documented on
-- @Agentic/Core/Plan.lean:81@ is exactly what a strict tail costs, and
-- 'revising' is where it is paid.
data Env (g :: Ctx) where
  ENil :: Env '[]
  ECons :: El c -> Env g -> Env (c ': g)

-- | @Env.head@: the most recent answer.
envHead :: Env (c ': g) -> El c
envHead (ECons x _) = x

-- | @Env.tail@: everything but the most recent answer.
envTail :: Env (c ': g) -> Env g
envTail (ECons _ g) = g

-- | @Agentic/Core/Plan.lean:128@ — a de Bruijn index: membership as data, which
-- is the same thing as a projection out of an 'Env'.
data Var (g :: Ctx) (c :: Code) where
  VHere :: Var (c ': g) c
  VThere :: Var g c -> Var (c' ': g) c

-- | @Var.get@ (@:137@): the projection a variable names.
varGet :: Var g c -> Env g -> El c
varGet VHere g = envHead g
varGet (VThere v) g = varGet v (envTail g)

-- | @Expr Γ A@ (@:151@) — a pure function of what is known, paired with the
-- de Bruijn indices its syntax reads. The function is still the denotation; the
-- finite support is operational metadata used only to decide when a runtime may
-- evaluate it. 'Functor' and 'Applicative' preserve that support structurally.
data Expr (g :: Ctx) a = Expr (Env g -> a) !IntSet

instance Functor (Expr g) where
  fmap f (Expr e uses) = Expr (f . e) uses

instance Applicative (Expr g) where
  pure a = Expr (const a) IntSet.empty
  Expr f fUses <*> Expr x xUses =
    Expr (\g -> f g (x g)) (IntSet.union fUses xUses)

-- | Evaluate an expression in an ordinary environment.
evalExpr :: Expr g a -> Env g -> a
evalExpr (Expr e _) = e

-- | The zero-based de Bruijn indices an expression may read.
exprUses :: Expr g a -> IntSet
exprUses (Expr _ uses) = uses

-- | @Expr.var@: the expression that reads a variable.
exprVar :: Var g c -> Expr g (El c)
exprVar v = Expr (varGet v) (IntSet.singleton (varIndex v))
  where
    varIndex :: Var h b -> Int
    varIndex VHere = 0
    varIndex (VThere w) = 1 + varIndex w

-- | @Expr.const@: the expression that ignores what is known.
exprConst :: a -> Expr g a
exprConst = pure

-- | @Sub Γ Δ@ (@:182@) — a context morphism, semantically a way of reading a
-- @Γ@-environment out of a @Δ@-environment, together with its action on finite
-- supports. Keeping those two actions together makes dependency information
-- survive the same weakening, contraction and substitution as the expression.
data Sub (g :: Ctx) (d :: Ctx) =
  Sub (Env d -> Env g) (IntSet -> IntSet)

applySub :: Sub g d -> Env d -> Env g
applySub (Sub s _) = s

mapSubUses :: Sub g d -> IntSet -> IntSet
mapSubUses (Sub _ f) = f

subExpr :: Expr g a -> Sub g d -> Expr d a
subExpr (Expr e uses) s =
  Expr (e . applySub s) (mapSubUses s uses)

-- | The unique substitution out of the empty context.
subNil :: Sub '[] g
subNil = Sub (const ENil) (const IntSet.empty)

-- | @Sub.id@ (@:189@).
subId :: Sub g g
subId = Sub id id

-- | @Sub.comp@ (@:193@): @\e -> s (t e)@, going @Γ → Δ → Ε@ on contexts and
-- @Env Ε → Env Δ → Env Γ@ on environments.
subComp :: Sub g d -> Sub d e -> Sub g e
subComp s t =
  Sub
    (applySub s . applySub t)
    (mapSubUses t . mapSubUses s)

-- | @Sub.wk@ (@:196@): forget the most recently bound answer. This is 'envTail'.
subWk :: Sub g (c ': g)
subWk = Sub envTail shiftUses

-- | @Sub.lift@ (@:204@): going under a binder — keep the new answer, act with
-- the substitution on the rest.
subLift :: Sub g d -> Sub (c ': g) (c ': d)
subLift s =
  Sub
    (\d -> ECons (envHead d) (applySub s (envTail d)))
    ( \uses ->
        (if 0 `IntSet.member` uses then IntSet.singleton 0 else IntSet.empty)
          `IntSet.union` shiftUses (mapSubUses s (tailUses uses))
    )

-- | The idiom @fun δ => Env.cons (e δ) (σ δ)@, which @Dsl/Check.lean@ writes at
-- every binding, every call argument and every revision continuation.
subCons :: Expr d (El c) -> Sub g d -> Sub (c ': g) d
subCons e s =
  Sub
    (\d -> ECons (evalExpr e d) (applySub s d))
    ( \uses ->
        (if 0 `IntSet.member` uses then exprUses e else IntSet.empty)
          `IntSet.union` mapSubUses s (tailUses uses)
    )

shiftUses :: IntSet -> IntSet
shiftUses = IntSet.mapMonotonic (+ 1)

tailUses :: IntSet -> IntSet
tailUses = IntSet.mapMonotonic (subtract 1) . IntSet.delete 0

-- ---------------------------------------------------------------------------
-- The term language
-- ---------------------------------------------------------------------------

-- | How a three-way bounded revision left off (D4,
-- @Agentic/Core/Plan.lean:330@).
--
-- The exit tag of 'revisingOn': a review's verdict tag decides the fate rather
-- than a single approval predicate, so a refusal ends the loop instead of
-- buying it another trip. Ordinary data, so adding a fourth ending later is a
-- local, total edit — and see 'revisingOn' for why the /classifier/ does not
-- extend for free.
--
-- The constructors are spelled @End…@ because the authoring surface's
-- three-way @case@ patterns ("Agentic.Workflow"'s @Ending@) live in one
-- namespace with its two-way @Outcome@ patterns and one of the two families
-- has to give way. This is the term-language tag; the surface's is the one an
-- author writes.
data Ending
  = -- | A review approved.
    EndSettled
  | -- | The bound ran out with an objection outstanding.
    EndUnsettled
  | -- | A review declined: no answer, and no more trips.
    EndAbandoned
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @Ending.ofVTag@ (@Agentic/Core/Plan.lean:342@) — the fate a verdict tag
-- names at the last round: approval settles, an objection leaves the loop
-- unsettled, a refusal abandons it. Total today, and deliberately so.
endingOfVTag :: VTag -> Ending
endingOfVTag = \case
  VApprove -> EndSettled
  VObject -> EndUnsettled
  VDeclined -> EndAbandoned

-- | The tag types a 'PCase' may branch on.
--
-- Closed, because the elaboration produces exactly these three. Reading
-- @Agentic/Core/Dsl/Check.lean@ end to end, there are four sites that build a
-- @case@ node and three tag types between them:
--
-- * @if x { … } else { … }@ — @Check.lean:830@, @Plan.caseB@ at 'Bool'.
-- * @case v { approved … objected … no answer … }@ — @Check.lean:846@,
--   @Plan.caseV@ at 'VTag'.
-- * the @revising@ unroll and its @settled@/@unsettled@ exit —
--   @Plan.lean:1056@ and @Check.lean:618@, @Plan.caseB@ at 'Bool' again.
-- * the @revising on@ unroll's @caseV@ and its three-way exit —
--   @Plan.lean:1099@ and @Check.lean:618@, at 'VTag' and at 'Ending'.
--
-- Nothing else; and @Check.lean:57@ records that no clause emits @Plan.dyn@, so
-- the DSL never reaches the dynamic rung.
--
-- __A tag is added, not opened.__ 'Ending' (D4) was the first constructor since
-- the universe was closed at two, and adding it cost exactly what the closure
-- promised: one 'tagValues' clause here, one @El@ clause and three instances in
-- Lean, and nothing at all in 'level', 'size', 'askNodes', 'codes' or 'costM',
-- which fold over 'tagValues' generically.
--
-- __Lean writes the same type.__ It used to quantify @case@ over an arbitrary
-- @[FinEnum T] [DecidableEq T]@ and this port was the closure read off the
-- elaborator by hand; @Agentic/Core/Plan.lean:353@ closes it there too, so
-- 'Tag' and @Tag.El@ (@:366@) are the two signatures transliterated rather than
-- one signature and one reading of it. That closure is what puts Lean's @Plan@
-- in @Type 0@, and it is why its @case@ node mentions no enumeration at all:
-- the enumeration is @Tag.values@, and it lives in the analyses.
data Tag t where
  TBool :: Tag Bool
  TVTag :: Tag VTag
  TEnding :: Tag Ending

-- | @Tag.values@ (@Agentic/Core/Plan.lean:393@), in Lean's order:
--
-- > def Tag.values : (t : Tag) → List t.El
-- >   | .bool => [false, true]
-- >   | .vtag => [.approve, .object, .declined]
-- >   | .ending => [.settled, .unsettled, .abandoned]
--
-- Lean's @Tag.finEnum_toList@ (@:401@) is the machine-checked statement that
-- this hand-written order /is/ the order @FinEnum.toList@ enumerates each tag
-- in, which is what keeps @Explain.planLines@ byte-identical across the
-- closure.
--
-- The order is unobservable in every fold ported here — 'size' and 'askNodes'
-- sum over it, 'level' joins over it, 'costM' is read only through @minimum@,
-- @maximum@ and @length@. It is Lean's order anyway; keep it.
tagValues :: Tag t -> [t]
tagValues TBool = [False, True]
tagValues TVTag = [VApprove, VObject, VDeclined]
tagValues TEnding = [EndSettled, EndUnsettled, EndAbandoned]

-- | The five formers of @Agentic/Core/Plan.lean:432@.
--
-- > inductive PlanF (A : Type) : Ctx → Type where
-- >   | ret  (e : Expr Γ A) : PlanF A Γ
-- >   | askC (c : Code) (q : Q c) (k : PlanF A (c :: Γ)) : PlanF A Γ
-- >   | ask  (c : Code) (s : Q.Shape c) (e : Expr Γ String) (k : PlanF A (c :: Γ)) : PlanF A Γ
-- >   | case (t : Tag) (e : Expr Γ t.El) (arms : t.El → PlanF A Γ) : PlanF A Γ
-- >   | dyn  (b : Code) (e : Expr Γ (El b)) (f : El b → PlanF A Γ) : PlanF A Γ
--
-- @abbrev Plan (Γ : Ctx) (A : Type) : Type := PlanF A Γ@ (@:489@) is the name
-- the package writes; the answer type is a /parameter/ there for a universe
-- reason that has no Haskell counterpart, and the argument order is Lean's
-- spelling of the same five formers.
--
-- 'PAskC' is a __closed__ question: its words are written down, so it needs no
-- environment to put. 'PAsk' computes its words from what is known, which is
-- why it, and not 'PAskC', forces the pipeline rung.
--
-- 'PDyn' is present for fidelity with the fifth former and to give 'level' a
-- 'Dynamic' to return. @Agentic.Builder@ cannot construct one and tier1 never
-- sees one; 'bindP' is the only thing here that makes one. Its answer type is a
-- 'Code' and not an existential 'Type': Lean closed it for the same universe
-- reason it closed @case@'s tag, and nothing is lost, because @El 'CodeText@ is
-- 'Text' and is already unbounded — which is the whole content of
-- @Cost.no_finite_bill_set_at_dyn@ (@Agentic/Core/Cost.lean:1033@).
--
-- No 'Eq', 'Ord' or 'Show': every former but 'PRet' holds a function.
data Plan (g :: Ctx) a where
  PRet :: Expr g a -> Plan g a
  PAskC :: SCode c -> Q c -> Plan (c ': g) a -> Plan g a
  PAsk :: SCode c -> Shape c -> Expr g Text -> Plan (c ': g) a -> Plan g a
  PCase :: Tag t -> Expr g t -> (t -> Plan g a) -> Plan g a
  PDyn :: SCode b -> Expr g (El b) -> (El b -> Plan g a) -> Plan g a

-- | @Plan.sub@ (@Agentic/Core/Plan.lean:641@): act on a term by a context
-- morphism. Substitution is not a constructor — it is a fold that rewrites
-- every expression in the term and lifts under every binder.
subP :: Plan g a -> Sub g d -> Plan d a
subP p s = case p of
  PRet e -> PRet (subExpr e s)
  PAskC c q k -> PAskC c q (subP k (subLift s))
  PAsk c sh e k -> PAsk c sh (subExpr e s) (subP k (subLift s))
  PCase t e arms -> PCase t (subExpr e s) (\x -> subP (arms x) s)
  PDyn b e f -> PDyn b (subExpr e s) (\x -> subP (f x) s)

-- | @subP p subWk@: read a plan under one more binding.
--
-- This is what an @act@ statement does with its continuation
-- (@Check.lean:763@: @form (Plan.sub k Sub.wk)@) — the receipt is bound and then
-- ignored, which still shifts every de Bruijn index after it.
weakenP :: Plan g a -> Plan (c ': g) a
weakenP p = subP p subWk

-- | @Cont Γ A B@ (@Agentic/Core/Plan.lean:780@) — a continuation that can be
-- grafted onto every leaf of a @Γ@-plan.
--
-- Context-polymorphic because the leaves of a plan do not all sit in @Γ@: each
-- ask on the way to a leaf has bound one more answer. The 'Sub' argument is how
-- a continuation written against @Γ@ reaches the leaf, and the 'Expr' is the
-- value the leaf produced — as an expression, not as a value, which is
-- precisely why grafting need not go through 'PDyn'.
--
-- Lean's @Cont@ is a Π-type over contexts; Haskell needs a @newtype@ for it,
-- because the rank-2 argument is passed to a recursive function and rebuilt
-- inside.
newtype Cont (g :: Ctx) a b = Cont
  {runCont :: forall (d :: Ctx). Sub g d -> Expr d a -> Plan d b}

-- | @Plan.graft@ (@Agentic/Core/Plan.lean:807@): @p@ with every 'PRet' leaf
-- replaced by the continuation at that leaf.
--
-- This is sequencing, and it is substitution rather than a constructor. Under
-- an ask the continuation is rebuilt with one more weakening in front of its
-- reaching substitution, which is how a continuation written outside the ask
-- still reads the environment at the leaf.
graft :: Plan g a -> Cont g a b -> Plan g b
graft p k = case p of
  PRet e -> runCont k subId e
  PAskC c q p' -> PAskC c q (graft p' (Cont (\s e -> runCont k (subComp subWk s) e)))
  PAsk c sh d p' -> PAsk c sh d (graft p' (Cont (\s e -> runCont k (subComp subWk s) e)))
  PCase t d arms -> PCase t d (\x -> graft (arms x) k)
  PDyn b d f -> PDyn b d (\x -> graft (f x) k)

-- | @Plan.mapP@ (@:835@): the functorial action, derived from 'graft' and — the
-- point — without 'PDyn', so mapping a plan does not move its rung.
mapP :: (a -> b) -> Plan g a -> Plan g b
mapP f p = graft p (Cont (\_ e -> PRet (fmap f e)))

-- | @Plan.zipWith@ (@:845@): the applicative action, again without 'PDyn'. The
-- second plan is moved under the first's binders by 'subP', which is the sense
-- in which two questions that do not mention each other's variables are
-- independent.
zipWithP :: (a -> b -> c) -> Plan g a -> Plan g b -> Plan g c
zipWithP f p q =
  graft
    p
    ( Cont
        ( \s e ->
            graft
              (subP q s)
              (Cont (\t e' -> PRet ((f <$> subExpr e t) <*> e')))
        )
    )

-- | @Plan.pairP@ (@:849@).
pairP :: Plan g a -> Plan g b -> Plan g (a, b)
pairP = zipWithP (,)

-- | @Plan.seq@ (@:853@): run the first, discard its answer, run the second. No
-- 'PDyn', because the answer is discarded.
seqP :: Plan g a -> Plan g b -> Plan g b
seqP p q = graft p (Cont (\s _ -> subP q s))

-- | @Plan.bindP@ (@:865@): monadic sequencing, and the __only__ derived form
-- that needs 'PDyn'.
--
-- That it needs 'PDyn' is the content, not an implementation accident: the
-- continuation is a genuine function of an unrestricted answer, so the plan that
-- follows is computed from an answer, which is the definition of the dynamic
-- rung. Everything the domain actually does with an answer — putting it into the
-- next prompt ('PAsk'), branching on a finite classifier of it ('PCase'),
-- folding a panel of them ('zipWithP') — is available without it.
--
-- The 'SCode' argument is Lean's @{c : Code}@: since 'PDyn' names the code of
-- the answer it branches on, so does the only thing that builds one. It is what
-- bounds this form to an /answer/ rather than to any Haskell value, which is the
-- sense in which the quarantine is a node of the syntax and not a hole in it.
bindP :: SCode c -> Plan g (El c) -> (El c -> Plan g b) -> Plan g b
bindP c p k = graft p (Cont (\s e -> PDyn c e (\a -> subP (k a) s)))

-- | @Plan.askC1@ (@:872@): put a closed question and answer with the reply.
askC1 :: SCode c -> Q c -> Plan g (El c)
askC1 c q = PAskC c q (PRet (exprVar VHere))

-- | @Plan.ask1@ (@:876@): put the question of this shape whose words are built
-- from what is known, and answer with the reply.
ask1 :: SCode c -> Shape c -> Expr g Text -> Plan g (El c)
ask1 c s e = PAsk c s e (PRet (exprVar VHere))

-- | @Plan.caseB@ (@:882@): @.case e (fun b => cond b t f)@.
--
-- Note the arm order — 'True' takes the first plan. Both arms are in the term.
caseB :: Expr g Bool -> Plan g a -> Plan g a -> Plan g a
caseB e t f = PCase TBool e (\b -> if b then t else f)

-- | @Plan.caseV@ (@:943@): @.case (fun γ => Verdict.tag (e γ)) arms@ — branching
-- on the finite classifier, with the verdict itself still available to every arm
-- as an expression.
caseV :: Expr g Verdict -> (VTag -> Plan g a) -> Plan g a
caseV e arms = PCase TVTag (fmap verdictTag e) arms

-- | Branching on an 'Ending': @.case .ending e arms@, the node
-- @Check.exitCont@ emits at 'TEnding' for a @revising on@'s three-way exit.
--
-- There is no Lean @caseE@ — @exitCont@ writes @Plan.case t@ directly at
-- whichever tag it was instantiated at — and this is that application named,
-- so the three-armed exit and the two-armed one read alike here.
caseE :: Expr g Ending -> (Ending -> Plan g a) -> Plan g a
caseE e arms = PCase TEnding e arms

-- | @Plan.panel@ (@:975@): ask each member and combine the replies with the
-- monoid.
--
-- > def panel [Monoid (El c)] (ps : List (Plan Γ (El c))) : Plan Γ (El c) :=
-- >   ps.foldr (zipWith (· * ·)) (.ret (fun _ => 1))
--
-- Lean states this at any code carrying a @Monoid (El c)@ and installs that
-- instance __only__ at @.verdict@ (@Plan.lean:952@); @Check.lean:485@ admits a
-- panel only at @Code.verdict@. So the port is monomorphic and needs no class.
--
-- @panel [] = PRet (const verdictApprove)@ — Lean's @1@. The checker refuses an
-- empty panel (@Check.lean:484@) before this is ever reached, but the clause is
-- the unit of the fold and must be written.
panel :: [Plan g Verdict] -> Plan g Verdict
panel = foldr (zipWithP verdictMul) (PRet (exprConst verdictApprove))

-- | @Plan.panelText@ (@Agentic/Core/Plan.lean:1008@) — 'panel'\'s twin at
-- @.text@: the same fan-out, the same one question per member, the same trace,
-- and a different fold. 'panel' folds into the verdict monoid; 'panelText'
-- folds into the free monoid over __fenced blocks__, in member order, so the
-- result is a document whose reader can tell which member said what.
--
-- > def panelText (parts : List (String × Plan Γ (El .text))) : Plan Γ (El .text) :=
-- >   parts.foldr
-- >     (fun p acc => zipWith (fun a rest => String.append (Dsl.block p.1 a) rest) p.2 acc)
-- >     (.ret (fun _ => ""))
--
-- __No @Monoid (El .text)@ instance is installed__ — the port is monomorphic
-- for the same reason 'panel' is, and for a sharper one: an instance at @.text@
-- would make 'panel' typecheck at @.text@ and fold member answers /unfenced/,
-- giving the language two ways to fold a text fan, one of which throws away the
-- names.
--
-- Derived from 'zipWithP', so it is 'graft'-based, reaches no 'PDyn', and is
-- invisible to 'level', 'costM' and the rest — it is ordinary nodes by the time
-- any fold sees it. With /n/ members: 'askNodes' is /n/, 'size' is /n+1/, the
-- rung is 'Batch' if every member's prompt is closed, and the path count does
-- not move. The __trace__ holds /n/ events carrying each member's raw reply
-- verbatim, and the fenced document appears nowhere in it: the trace is what
-- was asked and what was answered; the document is what the program then
-- computed.
panelText :: [(Text, Plan g Text)] -> Plan g Text
panelText =
  foldr
    (\(n, p) acc -> zipWithP (\a rest -> block n a <> rest) p acc)
    (PRet (exprConst T.empty))

-- | @Plan.revising@ (@Agentic/Core/Plan.lean:1056@): check the artefact; if it
-- is approved, stop with it; otherwise revise it and go again, at most @n@
-- times; if the last check still objects, hand back the candidate it ran out
-- holding, marked unsettled.
--
-- __The ending carries the candidate__ (D3). The result is @(El c, Bool)@ —
-- /the candidate always, and whether it settled/ — and not @Maybe (El c)@: on
-- exhaustion the loop is holding the artefact the @n@-th amendment produced and
-- the @n+1@-th review objected to, and the @Maybe@ threw it away. It is not the
-- candidate that /would have been/ produced by amending in response to the
-- final objection, which was never asked for and must not be invented. A pair
-- of an answer and a tag costs nothing structurally, so __not one term node
-- moves__ against the @Maybe@ spelling and 'size', 'askNodes' and 'costM'
-- cannot see the change.
--
-- __Check first, revise in the recursive call.__ @revising chk rev n@ performs
-- @n + 1@ checks and at most @n@ amendments, and never pays for a revision it
-- does not check — which is what \"revise up to twice\" means in English.
-- @n <= 0@ is the base clause. The checker refuses @n > 64@
-- (@Check.lean:631 maxRevisions@) before elaborating, so no bound on @n@ is
-- enforced here.
--
-- The objections are threaded: @rev@ receives the artefact /and/ the verdict, so
-- a revision knows what it is answering. The 'subComp' chains are what makes the
-- artefact expression readable at the leaf it reaches.
--
-- 'El' is not injective, so @c@ cannot be inferred at a call site: apply this at
-- a code, as in @revising \@'CodeText chk rev 2@.
revising ::
  forall (c :: Code) (g :: Ctx).
  Cont g (El c) Verdict ->
  Cont g (El c, Verdict) (El c) ->
  Integer ->
  Cont g (El c) (El c, Bool)
revising chk rev n
  | n <= 0 =
      Cont
        ( \s a ->
            graft
              (runCont chk s a)
              (Cont (\t v -> PRet ((\x verdict -> (x, verdictApproved verdict)) <$> subExpr a t <*> v)))
        )
  | otherwise =
      Cont
        ( \s a ->
            graft
              (runCont chk s a)
              ( Cont
                  ( \t v ->
                      caseB
                        (fmap verdictApproved v)
                        (PRet (fmap (\x -> (x, True)) (subExpr a t)))
                        ( graft
                            (runCont rev (subComp s t) ((,) <$> subExpr a t <*> v))
                            ( Cont
                                ( \r a' ->
                                    runCont
                                      (revising @c @g chk rev (n - 1))
                                      (subComp (subComp s t) r)
                                      a'
                                )
                            )
                        )
                  )
              )
        )

-- | @Plan.revisingOn@ (@Agentic/Core/Plan.lean:1099@) — the same bounded
-- revision, whose round reads the review's __verdict tag__ three ways rather
-- than one predicate two ways: approval settles, an objection buys another trip
-- (or, at the last round, leaves the loop unsettled), and a refusal
-- __abandons__ it at once.
--
-- 'revising' tests 'verdictApproved', so @object@ and @declined@ are the same
-- thing to it — a refusal buys a trip it should end. 'revisingOn' branches on
-- 'verdictTag', the finite classifier 'caseV' already uses, and maps its three
-- values onto three fates ('endingOfVTag').
--
-- Note the base clause needs __no__ @case@: the ending is a pure function of
-- the verdict, so round @n@ is one 'PRet', exactly as 'revising'\'s is. What
-- the extra exit edge costs is leaves: @L 0 = 1@ and @L (k+1) = L k + 2@ — the
-- approve-@ret@ and the declined-@ret@ — so an unrolled @revisingOn … n@ has
-- __@2n+1@__ leaves against 'revising'\'s @n+1@, and the consuming exit is
-- replicated once per leaf. @maxQuestions@ is checked against that count, so a
-- @revisingOn@ with a wide tail reaches the budget refusal at roughly half the
-- bound a @revising@ does.
revisingOn ::
  forall (c :: Code) (g :: Ctx).
  Cont g (El c) Verdict ->
  Cont g (El c, Verdict) (El c) ->
  Integer ->
  Cont g (El c) (El c, Ending)
revisingOn chk rev n
  | n <= 0 =
      Cont
        ( \s a ->
            graft
              (runCont chk s a)
              ( Cont
                  ( \t v ->
                      PRet
                        ( (\x verdict -> (x, endingOfVTag (verdictTag verdict)))
                            <$> subExpr a t
                            <*> v
                        )
                  )
              )
        )
  | otherwise =
      Cont
        ( \s a ->
            graft
              (runCont chk s a)
              ( Cont
                  ( \t v ->
                      caseV
                        v
                        ( \tag -> case tag of
                            VApprove -> PRet (fmap (\x -> (x, EndSettled)) (subExpr a t))
                            VDeclined -> PRet (fmap (\x -> (x, EndAbandoned)) (subExpr a t))
                            VObject ->
                              graft
                                (runCont rev (subComp s t) ((,) <$> subExpr a t <*> v))
                                ( Cont
                                    ( \r a' ->
                                        runCont
                                          (revisingOn @c @g chk rev (n - 1))
                                          (subComp (subComp s t) r)
                                          a'
                                    )
                                )
                        )
                  )
              )
        )

-- ---------------------------------------------------------------------------
-- The static folds: level, size, askNodes, codes
-- ---------------------------------------------------------------------------

-- | @Agentic/Core/Level.lean:53@ — the four rungs, as a chain. The 'Ord'
-- instance derived from this constructor order is Lean's @LinearOrder@, the
-- pullback of @toNat@ (batch 0, pipeline 1, branch 2, dynamic 3).
data Level
  = Batch
  | Pipeline
  | Branch
  | Dynamic
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @levelName@ (@Agentic/Core/Explain.lean:69@) — the rung as the one word a
-- report and the MCP wire both carry.
levelName :: Level -> Text
levelName = \case
  Batch -> "batch"
  Pipeline -> "pipeline"
  Branch -> "branch"
  Dynamic -> "dynamic"

-- | @level@ (@Agentic/Core/Level.lean:133@): each clause is the rung its former
-- forces, joined with what the subterms force.
--
-- Lean writes it as an algebra and takes the fold (@levelAlg@, @Level.lean:123@),
-- so the recursive positions arrive already folded — @l@ below /is/ @level k@:
--
-- > def levelAlg : PlanAlg (fun _ _ => Level) where
-- >   ret _ := .batch
-- >   askC _ _ l := l
-- >   ask _ _ _ l := max .pipeline l
-- >   case := fun _ _ arms => max .branch (Finset.univ.sup fun x => arms x)
-- >   dyn _ _ _ := .dynamic
--
-- The port keeps the direct recursion: there is one @Plan@ here and no theorem
-- to state about it, so the algebra record would buy nothing that
-- @PlanAlg.fold_unique@ buys in Lean.
--
-- __'PAskC' is @level k@, not @max Batch (level k)@__ — a closed question adds
-- nothing. The two are equal ('Batch' is @⊥@), but writing the join invites
-- writing @max Pipeline@ there too, which would make every closed-question
-- program 'Pipeline'; sixteen corpus entries are @batch@ and would all break.
--
-- The 'PCase' fold seeds with 'Branch' and joins, because @Finset.univ.sup@ over
-- an empty tag type is @⊥ = Batch@: an arm-less branch is still a branch. Both
-- tag types here are inhabited, so that is a fidelity point only.
level :: Plan g a -> Level
level = \case
  PRet _ -> Batch
  PAskC _ _ k -> level k
  PAsk _ _ _ k -> max Pipeline (level k)
  PCase t _ arms -> foldr (max . level . arms) Branch (tagValues t)
  PDyn {} -> Dynamic

-- | @Plan.size@ (@Agentic/Core/Explain.lean:152@): how many nodes the term has,
-- a 'PDyn' counting as one because the number of nodes below it is not a number.
--
-- A @case@ __counts itself__ (the @1 +@); compare 'askNodes', which does not.
-- The asymmetry is not a typo — @battery-085@'s @size 11@ against
-- @askNodes 4@ only comes out with it.
size :: Plan g a -> Integer
size = \case
  PRet _ -> 1
  PAskC _ _ k -> 1 + size k
  PAsk _ _ _ k -> 1 + size k
  PCase t _ arms -> 1 + sum (map (size . arms) (tagValues t))
  PDyn {} -> 1

-- | @Plan.askNodes@ (@Agentic/Core/Explain.lean:194@): how many consultations
-- are /written/ in the term, both arms of every branching counted.
--
-- Not a bill — a run pays for the questions on the path it takes, and that is
-- what 'costM'\'s bag counts. The two coincide exactly where there is no
-- branching (@Plan.length_trace_eq_askNodes@). A @case@ contributes only its
-- arms, and a 'PDyn' contributes nothing.
askNodes :: Plan g a -> Integer
askNodes = \case
  PRet _ -> 0
  PAskC _ _ k -> 1 + askNodes k
  PAsk _ _ _ k -> 1 + askNodes k
  PCase t _ arms -> sum (map (askNodes . arms) (tagValues t))
  PDyn {} -> 0

-- | @codes@ (@Agentic/Core/Cost.lean:329@): the sequence of answer codes the
-- term will ask for, if that sequence is fixed by the term.
--
-- 'Nothing' at a 'PCase' and at a 'PDyn' — those are the two places the
-- sequence is not fixed. A fold of the term alone: no environment, no world.
--
-- The reply serializes each existential `SomeCode`; built-ins retain their old
-- strings and schema-indexed codes carry the schema that is part of their identity.
codes :: Plan g a -> Maybe [SomeCode]
codes = \case
  PRet _ -> Just []
  PAskC c _ k -> (fromSCode c :) <$> codes k
  PAsk c _ _ k -> (fromSCode c :) <$> codes k
  PCase {} -> Nothing
  PDyn {} -> Nothing

schemaRequirements :: Plan g a -> [SomeSchema]
schemaRequirements = \case
  PRet _ -> []
  PAskC code _ rest -> at code ++ schemaRequirements rest
  PAsk code _ _ rest -> at code ++ schemaRequirements rest
  PCase tag _ arms -> concatMap (schemaRequirements . arms) (tagValues tag)
  PDyn {} -> []
  where
    at :: SCode c -> [SomeSchema]
    at (SStructured schema) = [SomeSchema schema]
    at _ = []

-- ---------------------------------------------------------------------------
-- costSummary
-- ---------------------------------------------------------------------------

-- | @Cost.costM@ (@Agentic/Core/Cost.lean:803@) at the counting price: the
-- finite __bag__ of every bill the term can run up, one element per path
-- through its branchings.
--
-- > costM (ret e)       γ = {1}
-- > costM (askC c q k)  γ = map (price c q *)                    (costM k γ)
-- > costM (ask c s e k) γ = map (price c (s.withPrompt (e γ)) *) (costM k γ)
-- > costM (case _ arms) γ = Finset.univ.val.bind (fun t => costM (arms t) γ)
--
-- A bag and not a tree: Lean used to build a @CostTree@ and read its @leaves@,
-- and what the tree was /for/ was the bag at its leaves —
-- @Cost.bill_mem_leaves@ quantifies the path existentially, so the branch
-- structure was never read. The two intermediate types are gone on both sides.
--
-- Three simplifications carry over, each licensed and each load-bearing:
--
-- 1. The price is always @tick@ (@Cost.lean:272@), and @tick@ ignores its
--    question. So the @Env@/@default@ threading of Lean's @costM@ is dead:
--    nothing in the tick bag depends on the environment, and neither
--    @s.withPrompt (e γ)@ nor a @case@ scrutinee is ever evaluated. 'costM'
--    therefore takes no environment and works in any context.
-- 2. @Multiplicative Nat@ read through @Multiplicative.toAdd@ is ordinary
--    addition: @{1}@ is the singleton bag of additive @0@, and each ask adds
--    @1@ to every element. So a bill is an 'Integer' and it counts
--    consultations.
-- 3. @Multiset@ is only ever read through @min@, @max@ and @card@ — and
--    @Explain.leafBills@ sorts it before printing — so a list is faithful.
--
-- The empty bag at a 'PDyn' is the position where Lean has @absurd@, because
-- @costM@ is defined only at @level p ≤ branch@. It admits no bill, which is
-- exactly what Lean's @WithTop@\/@WithBot@ folds report for it, so 'costSummary'
-- stays total and honest instead of partial. @Agentic.Builder@ cannot produce a
-- 'PDyn', and a caller must assert @'level' p <= 'Branch'@ before printing a
-- summary.
costM :: Plan g a -> [Integer]
costM = \case
  PRet _ -> [0]
  PAskC _ _ k -> map (+ 1) (costM k)
  PAsk _ _ _ k -> map (+ 1) (costM k)
  PCase t _ arms -> concatMap (costM . arms) (tagValues t)
  PDyn {} -> []

-- | @costSummary@ (@Agentic/Core/Explain.lean:422@): the cheapest bill, the
-- dearest bill and the number of paths, from 'costM' at @tick@.
--
-- The first two are @Cost.minFold@ and @Cost.maxFold@ (@Cost.lean:864@,
-- @:870@) read through @WithTop@/@WithBot@, so they are 'Nothing' exactly when
-- the bag is empty — Lean's @⊤@/@⊥@, which cannot arise from an elaborated
-- program. They are __bounds__: @Cost.minFold_not_attained@ exhibits a plan
-- whose @minFold@ no world pays.
--
-- The third is @Multiset.card@, not @Finset.card@: the bill count with
-- repetitions, not the number of distinct bills. @battery-042@ has @paths 2@
-- with @minFold = maxFold = 3@ — two paths at the same price.
costSummary :: Plan g a -> (Maybe Integer, Maybe Integer, Integer)
costSummary p =
  ( if null ls then Nothing else Just (minimum ls),
    if null ls then Nothing else Just (maximum ls),
    toInteger (length ls)
  )
  where
    ls = costM p
