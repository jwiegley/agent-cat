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
-- over @Agentic/Core/Cost.lean@'s @CostTree@).
--
-- __What is not here.__ No parser, no typing judgment, no @CheckError@, no
-- positions. A 'Q' carries no position and a 'Plan' carries no position;
-- positions are oracle-only, like @message@ and @excerpt@. Nothing in this
-- module can refuse a program: well-formedness is the Haskell type checker's
-- job, via @Agentic.Builder@, and the @Raw@-level guards stay in
-- @Agentic.Guards@.
--
-- There is deliberately no @Sig@, no @compSig@ and no @Plan.under@: the DSL
-- elaboration never calls @Plan.under@ (@Dsl/Check.lean:170@'s @askShape@
-- applies @atModel@ to the leaf shape directly, and @Check.lean:179@'s
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
    exprVar,
    exprConst,
    Sub,
    subId,
    subComp,
    subWk,
    subLift,
    subCons,

    -- * The term language
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
    panel,
    revising,

    -- * The static folds
    Level (..),
    levelName,
    level,
    size,
    askNodes,
    codes,
    CostTree (..),
    costTree,
    costLeaves,
    costSummary,
  )
where

import Agentic.Raw (Addressee, Code (..))
import Agentic.Text (Verdict (..))
import Data.Kind (Type)
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- The answer universe
-- ---------------------------------------------------------------------------

-- | @Agentic/Core/Question.lean:228@'s @El@ — the set of things an addressee
-- can say in reply to a question of kind @c@ — as a closed type family over
-- 'Agentic.Raw.Code', promoted with @DataKinds@:
--
-- > def El : Code → Type
-- >   | .text => String
-- >   | .verdict => Verdict
-- >   | .flag => Bool
-- >   | .ack => Unit
--
-- 'Code' is not redefined here; it is @Agentic.Raw@'s, so one @Code@ serves the
-- codec, the guards and the term language alike.
type family El (c :: Code) :: Type where
  El 'CodeText = Text
  El 'CodeVerdict = Verdict
  El 'CodeFlag = Bool
  El 'CodeAck = ()

-- | The value-level witness of a promoted 'Code'. Lean writes @(c : Code)@ and
-- matches on it — @denote@, @eventJson@ and @answerJson@ all dispatch on the
-- code — and this is that argument. 'El' is not injective, so nothing else can
-- recover @c@ from an answer.
data SCode (c :: Code) where
  SText :: SCode 'CodeText
  SVerdict :: SCode 'CodeVerdict
  SFlag :: SCode 'CodeFlag
  SAck :: SCode 'CodeAck

-- | Forget the index: the singleton as ordinary data.
fromSCode :: SCode c -> Code
fromSCode = \case
  SText -> CodeText
  SVerdict -> CodeVerdict
  SFlag -> CodeFlag
  SAck -> CodeAck

-- | Recovering the singleton from the type, so a builder combinator whose code
-- is fixed by its result type need not be handed one.
class KnownCode (c :: Code) where
  sCode :: SCode c

instance KnownCode 'CodeText where sCode = SText

instance KnownCode 'CodeVerdict where sCode = SVerdict

instance KnownCode 'CodeFlag where sCode = SFlag

instance KnownCode 'CodeAck where sCode = SAck

-- | @Agentic/Core/Question.lean:237@, @instInhabitedEl@: every answer type is
-- inhabited, which is what lets an analysis substitute an answer it does not
-- have. @""@, approval, 'False', @()@.
--
-- The 'Verdict' default is Lean's @Inhabited Verdict = Option.some []@, which
-- @Verdict.default_eq_approve@ proves is @approve@ — so this is 'Approve', not
-- 'Declined'.
defaultEl :: SCode c -> El c
defaultEl = \case
  SText -> T.empty
  SVerdict -> verdictApprove
  SFlag -> False
  SAck -> ()

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

-- | @Agentic/Core/Question.lean:122@ — the unit @1@ of the verdict monoid.
verdictApprove :: Verdict
verdictApprove = Approve

-- | @Agentic/Core/Question.lean:130@ — the zero @0@, which annihilates.
verdictDeclined :: Verdict
verdictDeclined = Declined

-- | @Agentic/Core/Question.lean:133@ — @↑os@, the free-monoid element.
--
-- The Lean invariant @Object [] == Approve@ (@Verdict.approved_object_iff@) is
-- carried here: an empty objection list /is/ the unit, so it normalizes to
-- 'Approve'. Build objecting verdicts with this, never with the bare 'Object'
-- constructor.
verdictObject :: [Text] -> Verdict
verdictObject [] = Approve
verdictObject os = Object os

-- | The monoid of @Agentic/Core/Question.lean:101@: a zero that annihilates
-- (@:149@, @:152@), and free-monoid concatenation otherwise (@:140@).
--
-- __Not commutative.__ An objection list is a record, and the order in which a
-- panel raised its objections is part of what it said.
verdictMul :: Verdict -> Verdict -> Verdict
verdictMul Declined _ = Declined
verdictMul _ Declined = Declined
verdictMul a b = verdictObject (objectionsOf a ++ objectionsOf b)

-- | @Verdict.approvedB@ (@Agentic/Core/Plan.lean:551@): @decide (v = approve)@,
-- the 'Bool' a 'caseB' branches on inside 'revising'.
--
-- Tests the normalized form, so a stray @Object []@ that escaped
-- 'verdictObject' still counts as approval, exactly as in Lean.
verdictApproved :: Verdict -> Bool
verdictApproved = \case
  Approve -> True
  Object [] -> True
  _ -> False

-- | @Verdict.render@ (@Agentic/Core/Dsl/Syntax.lean:63@):
--
-- > String.intercalate "; " (if h : v = 0 then [] else FreeMonoid.toList (WithZero.unzero h))
--
-- The objections joined by @"; "@. Approval and refusal both render as the
-- empty string — @Verdict.render_declined@ says so on purpose, and the two
-- collapse. This is what a @{v}@ prompt hole at a verdict means.
verdictRender :: Verdict -> Text
verdictRender = \case
  Declined -> T.empty
  Approve -> T.empty
  Object os -> T.intercalate "; " os

-- | @Agentic/Core/Plan.lean:495@ — the finite classifier of a verdict: the
-- three answers a @case@ can branch on, while the objections themselves ride in
-- the environment into the arm that was taken.
data VTag
  = VApprove
  | VObject
  | VDeclined
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @Verdict.tag@ (@Agentic/Core/Plan.lean:515@):
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

-- | @Agentic/Core/Question.lean:72@'s @QScope := Agentic.Scope String String@:
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

-- | The product of @Agentic/Scope.lean:86@, axis by axis.
--
-- Per axis: the __right__ operand wins when it is set, else the left survives
-- (@LastOpt.set_overrides@ / @LastOpt.unset_defers@). Read right-to-left as
-- outer-then-inner, that is innermost-wins. Getting the side wrong is exactly
-- the mistake @Agentic/Scope.lean@ warns about — it would make the outermost
-- @served by@ win.
scopeMul :: QScope -> QScope -> QScope
scopeMul (QScope m1 d1) (QScope m2 d2) =
  QScope (maybe m1 Just m2) (maybe d1 Just d2)

-- | @Scope.fst m@ (@Agentic/Scope.lean:160@): the model axis set, the mode axis
-- silent.
scopeFst :: Text -> QScope
scopeFst m = QScope (Just m) Nothing

-- | @Q.Shape c@ (@Agentic/Core/Question.lean:289@) — everything that fixes a
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

-- | @Q c@ (@Agentic/Core/Question.lean:263@) — the shape and the words.
--
-- @Q c ≅ Q.Shape c × String@, witnessed by 'shapeOf' and 'withPrompt'.
data Q (c :: Code) = Q
  { qAddressee :: !Addressee,
    qScope :: !QScope,
    qPrompt :: !Text,
    qDraw :: !Integer
  }
  deriving (Eq, Show)

-- | @Q.shape@ (@:301@): the question with its words forgotten.
shapeOf :: Q c -> Shape c
shapeOf q = Shape (qAddressee q) (qScope q) (qDraw q)

-- | @Q.Shape.withPrompt@ (@:304@): the question of this shape whose words are
-- the given text.
withPrompt :: Shape c -> Text -> Q c
withPrompt s p = Q (shAddressee s) (shScope s) p (shDraw s)

-- | @atModel m c s@ of @Agentic/Core/Question.lean:425@, at a single shape:
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

-- | @Agentic/Core/Plan.lean:52@ — what is known so far, as a list of answer
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

-- | @Expr Γ A@ (@:151@) — a pure function of what is known. Prompt construction
-- is ordinary data, so nothing about building a question is an effect, and a
-- question's words may mention every answer in scope.
type Expr (g :: Ctx) a = Env g -> a

-- | @Expr.var@: the expression that reads a variable.
exprVar :: Var g c -> Expr g (El c)
exprVar = varGet

-- | @Expr.const@: the expression that ignores what is known.
exprConst :: a -> Expr g a
exprConst a = \_ -> a

-- | @Sub Γ Δ@ (@:169@) — a context morphism, semantically: a way of reading a
-- @Γ@-environment out of a @Δ@-environment. Weakening, exchange, contraction
-- and genuine substitution are all inhabitants of this one type.
type Sub (g :: Ctx) (d :: Ctx) = Env d -> Env g

-- | @Sub.id@ (@:176@).
subId :: Sub g g
subId = id

-- | @Sub.comp@ (@:180@): @\\e -> s (t e)@, going @Γ → Δ → Ε@ on contexts and
-- @Env Ε → Env Δ → Env Γ@ on environments.
subComp :: Sub g d -> Sub d e -> Sub g e
subComp s t = \e -> s (t e)

-- | @Sub.wk@ (@:183@): forget the most recently bound answer. This is 'envTail'.
subWk :: Sub g (c ': g)
subWk = envTail

-- | @Sub.lift@ (@:191@): going under a binder — keep the new answer, act with
-- the substitution on the rest.
subLift :: Sub g d -> Sub (c ': g) (c ': d)
subLift s = \d -> ECons (envHead d) (s (envTail d))

-- | The idiom @fun δ => Env.cons (e δ) (σ δ)@, which @Dsl/Check.lean@ writes at
-- every binding, every call argument and every revision continuation.
subCons :: Expr d (El c) -> Sub g d -> Sub (c ': g) d
subCons e s = \d -> ECons (e d) (s d)

-- ---------------------------------------------------------------------------
-- The term language
-- ---------------------------------------------------------------------------

-- | The tag types a 'PCase' may branch on.
--
-- Closed, because the elaboration produces exactly these two. Reading
-- @Agentic/Core/Dsl/Check.lean@ end to end, there are three sites that build a
-- @case@ node and two tag types between them:
--
-- * @if x { … } else { … }@ — @Check.lean:679@, @Plan.caseB@ at 'Bool'.
-- * @case v { approved … objected … no answer … }@ — @Check.lean:699@,
--   @Plan.caseV@ at 'VTag'.
-- * the @revising@ unroll and its @settled@/@unsettled@ exit —
--   @Plan.lean:630@ and @Check.lean:508@, @Plan.caseB@ at 'Bool' again.
--
-- Nothing else; and @Check.lean:55@ records that no clause emits @Plan.dyn@, so
-- the DSL never reaches the dynamic rung. Lean's @FinEnum@ instance is
-- 'tagValues'.
data Tag t where
  TBool :: Tag Bool
  TVTag :: Tag VTag

-- | Lean's @FinEnum.toList@, in Lean's order:
--
-- > scoped instance instFinEnumBool : FinEnum Bool := FinEnum.ofList [false, true]
-- > instance instFinEnumVTag : FinEnum VTag := FinEnum.ofList [.approve, .object, .declined]
--
-- The order is unobservable in every fold ported here — 'size' and 'askNodes'
-- sum over it, 'level' joins over it, 'costLeaves' is read only through
-- @minimum@, @maximum@ and @length@. It is Lean's order anyway; keep it.
tagValues :: Tag t -> [t]
tagValues TBool = [False, True]
tagValues TVTag = [VApprove, VObject, VDeclined]

-- | The five formers of @Agentic/Core/Plan.lean:238@.
--
-- > inductive Plan : Ctx → Type → Type 1 where
-- >   | ret  (e : Expr Γ A) : Plan Γ A
-- >   | askC (c : Code) (q : Q c) (k : Plan (c :: Γ) A) : Plan Γ A
-- >   | ask  (c : Code) (s : Q.Shape c) (e : Expr Γ String) (k : Plan (c :: Γ) A) : Plan Γ A
-- >   | case [FinEnum T] [DecidableEq T] (e : Expr Γ T) (arms : T → Plan Γ A) : Plan Γ A
-- >   | dyn  (e : Expr Γ B) (f : B → Plan Γ A) : Plan Γ A
--
-- 'PAskC' is a __closed__ question: its words are written down, so it needs no
-- environment to put. 'PAsk' computes its words from what is known, which is
-- why it, and not 'PAskC', forces the pipeline rung.
--
-- 'PDyn' is present for fidelity with the fifth former and to give 'level' a
-- 'Dynamic' to return. @Agentic.Builder@ cannot construct one and tier1 never
-- sees one; 'bindP' is the only thing here that makes one.
--
-- No 'Eq', 'Ord' or 'Show': every former but 'PRet' holds a function.
data Plan (g :: Ctx) a where
  PRet :: Expr g a -> Plan g a
  PAskC :: SCode c -> Q c -> Plan (c ': g) a -> Plan g a
  PAsk :: SCode c -> Shape c -> Expr g Text -> Plan (c ': g) a -> Plan g a
  PCase :: Tag t -> Expr g t -> (t -> Plan g a) -> Plan g a
  PDyn :: Expr g b -> (b -> Plan g a) -> Plan g a

-- | @Plan.sub@ (@Agentic/Core/Plan.lean:309@): act on a term by a context
-- morphism. Substitution is not a constructor — it is a fold that rewrites
-- every expression in the term and lifts under every binder.
subP :: Plan g a -> Sub g d -> Plan d a
subP p s = case p of
  PRet e -> PRet (e . s)
  PAskC c q k -> PAskC c q (subP k (subLift s))
  PAsk c sh e k -> PAsk c sh (e . s) (subP k (subLift s))
  PCase t e arms -> PCase t (e . s) (\x -> subP (arms x) s)
  PDyn e f -> PDyn (e . s) (\b -> subP (f b) s)

-- | @subP p subWk@: read a plan under one more binding.
--
-- This is what an @act@ statement does with its continuation
-- (@Check.lean:565@: @form (Plan.sub k Sub.wk)@) — the receipt is bound and then
-- ignored, which still shifts every de Bruijn index after it.
weakenP :: Plan g a -> Plan (c ': g) a
weakenP p = subP p subWk

-- | @Cont Γ A B@ (@Agentic/Core/Plan.lean:410@) — a continuation that can be
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

-- | @Plan.graft@ (@Agentic/Core/Plan.lean:421@): @p@ with every 'PRet' leaf
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
  PDyn d f -> PDyn d (\b -> graft (f b) k)

-- | @Plan.mapP@ (@:432@): the functorial action, derived from 'graft' and — the
-- point — without 'PDyn', so mapping a plan does not move its rung.
mapP :: (a -> b) -> Plan g a -> Plan g b
mapP f p = graft p (Cont (\_ e -> PRet (f . e)))

-- | @Plan.zipWith@ (@:442@): the applicative action, again without 'PDyn'. The
-- second plan is moved under the first's binders by 'subP', which is the sense
-- in which two questions that do not mention each other's variables are
-- independent.
zipWithP :: (a -> b -> c) -> Plan g a -> Plan g b -> Plan g c
zipWithP f p q =
  graft
    p
    ( Cont
        ( \s e ->
            graft (subP q s) (Cont (\t e' -> PRet (\th -> f (e (t th)) (e' th))))
        )
    )

-- | @Plan.pairP@ (@:446@).
pairP :: Plan g a -> Plan g b -> Plan g (a, b)
pairP = zipWithP (,)

-- | @Plan.seq@ (@:450@): run the first, discard its answer, run the second. No
-- 'PDyn', because the answer is discarded.
seqP :: Plan g a -> Plan g b -> Plan g b
seqP p q = graft p (Cont (\s _ -> subP q s))

-- | @Plan.bindP@ (@:462@): monadic sequencing, and the __only__ derived form
-- that needs 'PDyn'.
--
-- That it needs 'PDyn' is the content, not an implementation accident: the
-- continuation is a genuine function of an unrestricted answer, so the plan that
-- follows is computed from an answer, which is the definition of the dynamic
-- rung. Everything the domain actually does with an answer — putting it into the
-- next prompt ('PAsk'), branching on a finite classifier of it ('PCase'),
-- folding a panel of them ('zipWithP') — is available without it.
bindP :: Plan g a -> (a -> Plan g b) -> Plan g b
bindP p k = graft p (Cont (\s e -> PDyn e (\a -> subP (k a) s)))

-- | @Plan.askC1@ (@:469@): put a closed question and answer with the reply.
askC1 :: SCode c -> Q c -> Plan g (El c)
askC1 c q = PAskC c q (PRet (exprVar VHere))

-- | @Plan.ask1@ (@:473@): put the question of this shape whose words are built
-- from what is known, and answer with the reply.
ask1 :: SCode c -> Shape c -> Expr g Text -> Plan g (El c)
ask1 c s e = PAsk c s e (PRet (exprVar VHere))

-- | @Plan.caseB@ (@:479@): @.case e (fun b => cond b t f)@.
--
-- Note the arm order — 'True' takes the first plan. Both arms are in the term.
caseB :: Expr g Bool -> Plan g a -> Plan g a -> Plan g a
caseB e t f = PCase TBool e (\b -> if b then t else f)

-- | @Plan.caseV@ (@:563@): @.case (fun γ => Verdict.tag (e γ)) arms@ — branching
-- on the finite classifier, with the verdict itself still available to every arm
-- as an expression.
caseV :: Expr g Verdict -> (VTag -> Plan g a) -> Plan g a
caseV e arms = PCase TVTag (verdictTag . e) arms

-- | @Plan.panel@ (@:595@): ask each member and combine the replies with the
-- monoid.
--
-- > def panel [Monoid (El c)] (ps : List (Plan Γ (El c))) : Plan Γ (El c) :=
-- >   ps.foldr (zipWith (· * ·)) (.ret (fun _ => 1))
--
-- Lean states this at any code carrying a @Monoid (El c)@ and installs that
-- instance __only__ at @.verdict@ (@Plan.lean:572@); @Check.lean:438@ admits a
-- panel only at @Code.verdict@. So the port is monomorphic and needs no class.
--
-- @panel [] = PRet (const verdictApprove)@ — Lean's @1@. The checker refuses an
-- empty panel (@Check.lean:437@) before this is ever reached, but the clause is
-- the unit of the fold and must be written.
panel :: [Plan g Verdict] -> Plan g Verdict
panel = foldr (zipWithP verdictMul) (PRet (exprConst verdictApprove))

-- | @Plan.revising@ (@Agentic/Core/Plan.lean:621@): check the artefact; if it is
-- approved, stop with it; otherwise revise it and go again, at most @n@ times;
-- if the last check still objects, give up with 'Nothing'.
--
-- __Check first, revise in the recursive call.__ @revising chk rev n@ performs
-- @n + 1@ checks and at most @n@ amendments, and never pays for a revision it
-- does not check — which is what \"revise up to twice\" means in English.
-- @n <= 0@ is the base clause. The checker refuses @n > 64@
-- (@Check.lean:520 maxRevisions@) before elaborating, so no bound on @n@ is
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
  Cont g (El c) (Maybe (El c))
revising chk rev n
  | n <= 0 =
      Cont
        ( \s a ->
            graft
              (runCont chk s a)
              ( Cont
                  ( \t v ->
                      PRet
                        ( \th ->
                            if verdictApproved (v th) then Just (a (t th)) else Nothing
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
                      caseB
                        (verdictApproved . v)
                        (PRet (\th -> Just (a (t th))))
                        ( graft
                            (runCont rev (subComp s t) (\th -> (a (t th), v th)))
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

-- | @level@ (@Agentic/Core/Level.lean:120@): each clause is the rung its former
-- forces, joined with what the subterms force.
--
-- > | .ret _ => .batch
-- > | .askC _ _ k => level k
-- > | .ask _ _ _ k => max .pipeline (level k)
-- > | .case _ arms => max .branch (Finset.univ.sup fun t => level (arms t))
-- > | .dyn _ _ => .dynamic
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
  PDyn _ _ -> Dynamic

-- | @Plan.size@ (@Agentic/Core/Explain.lean:140@): how many nodes the term has,
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
  PDyn _ _ -> 1

-- | @Plan.askNodes@ (@Agentic/Core/Explain.lean:155@): how many consultations
-- are /written/ in the term, both arms of every branching counted.
--
-- Not a bill — a run pays for the questions on the path it takes, and that is
-- what 'costTree'\'s leaves count. The two coincide exactly where there is no
-- branching (@Plan.length_trace_eq_askNodes@). A @case@ contributes only its
-- arms, and a 'PDyn' contributes nothing.
askNodes :: Plan g a -> Integer
askNodes = \case
  PRet _ -> 0
  PAskC _ _ k -> 1 + askNodes k
  PAsk _ _ _ k -> 1 + askNodes k
  PCase t _ arms -> sum (map (askNodes . arms) (tagValues t))
  PDyn _ _ -> 0

-- | @codes@ (@Agentic/Core/Cost.lean:304@): the sequence of answer codes the
-- term will ask for, if that sequence is fixed by the term.
--
-- 'Nothing' at a 'PCase' and at a 'PDyn' — those are the two places the
-- sequence is not fixed. A fold of the term alone: no environment, no world.
--
-- The reply serializes this with 'Agentic.Raw.codeName', so 'CodeAck' prints as
-- @"receipt"@ (@Conformance.lean:254@). The fold stores the 'Code' itself;
-- whoever prints it owes the @receipt@ spelling.
codes :: Plan g a -> Maybe [Code]
codes = \case
  PRet _ -> Just []
  PAskC c _ k -> (fromSCode c :) <$> codes k
  PAsk c _ _ k -> (fromSCode c :) <$> codes k
  PCase {} -> Nothing
  PDyn {} -> Nothing

-- ---------------------------------------------------------------------------
-- costSummary
-- ---------------------------------------------------------------------------

-- | @Cost.CostTree@ (@Agentic/Core/Cost.lean:610@) at the counting price, with
-- three simplifications, each licensed and each load-bearing:
--
-- 1. The price is always @tick@ (@Cost.lean:258@), and @tick@ ignores its
--    question. So the @Env@/@default@ threading of Lean's @costTree@ is dead:
--    nothing in the tick tree depends on the environment, and neither
--    @s.withPrompt (e γ)@ nor a @case@ scrutinee is ever evaluated. 'costTree'
--    therefore takes no environment and works in any context.
-- 2. @Multiplicative Nat@ read through @Multiplicative.toAdd@ is ordinary
--    addition: @leaf 1@ is additive @0@, and each ask adds @1@. So a leaf is an
--    'Integer' and the tree's leaf bill is a count of consultations.
-- 3. @Multiset@ is only ever read through @min@, @max@ and @card@, so a list in
--    leaf order is faithful.
data CostTree
  = CostLeaf !Integer
  | CostNode [CostTree]
  deriving (Eq, Show)

-- | The tick cost tree of a term (@Agentic/Core/Cost.lean:668@).
--
-- @'CostNode' []@ at a 'PDyn': that is the position where Lean has @absurd@,
-- because @costTree@ is defined only at @level p ≤ branch@. An arm-less node
-- admits no bill, which is exactly what Lean's @WithTop@/@WithBot@ folds report
-- for it, so 'costSummary' stays total and honest instead of partial.
-- @Agentic.Builder@ cannot produce a 'PDyn', and a caller must assert
-- @'level' p <= 'Branch'@ before printing a summary.
costTree :: Plan g a -> CostTree
costTree = \case
  PRet _ -> CostLeaf 0
  PAskC _ _ k -> bump (costTree k)
  PAsk _ _ _ k -> bump (costTree k)
  PCase t _ arms -> CostNode (map (costTree . arms) (tagValues t))
  PDyn _ _ -> CostNode []
  where
    -- Lean's `CostTree.map (price c q * ·)`, at a price that is always one tick.
    bump (CostLeaf n) = CostLeaf (n + 1)
    bump (CostNode ts) = CostNode (map bump ts)

-- | @CostTree.leaves@ (@Agentic/Core/Cost.lean:631@) as a list in leaf order:
-- the bill at every path, __with repetitions__.
costLeaves :: CostTree -> [Integer]
costLeaves = \case
  CostLeaf n -> [n]
  CostNode ts -> concatMap costLeaves ts

-- | @costSummary@ (@Agentic/Core/Explain.lean:445@): the cheapest bill, the
-- dearest bill and the number of paths, from 'costTree' at @tick@.
--
-- The first two are @CostTree.minFold@ and @CostTree.maxFold@ read through
-- @WithTop@/@WithBot@, so they are 'Nothing' exactly when the leaf bag is empty
-- — Lean's @⊤@/@⊥@, which cannot arise from an elaborated program. They are
-- __bounds__: @Cost.minFold_not_attained@ exhibits a plan whose @minFold@ no
-- world pays.
--
-- The third is @Multiset.card@, not @Finset.card@: the leaf count with
-- repetitions, not the number of distinct bills. @battery-042@ has @paths 2@
-- with @minFold = maxFold = 3@ — two paths at the same price.
costSummary :: Plan g a -> (Maybe Integer, Maybe Integer, Integer)
costSummary p =
  ( if null ls then Nothing else Just (minimum ls),
    if null ls then Nothing else Just (maximum ls),
    toInteger (length ls)
  )
  where
    ls = costLeaves (costTree p)
