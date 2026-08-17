# PORTING2-core.md — the week-two spec for `Agentic.Plan` and `Agentic.World`

Companion to `PORTING.md` (week one: `Agentic.Raw`, `Agentic.Guards`,
`Agentic.Text`, `tier0`) and to `PORTING2-builder.md` (the production surface,
`Agentic.Builder`, and `tier1`). This file is the contract for exactly two
modules:

* `src/Agentic/Plan.hs` — the typed term language and its static folds.
* `src/Agentic/World.hs` — the world as data, the trace, the bills, and the
  oracle's event JSON.

Everything below is pinned against the Lean sources of truth, quoted inline,
and — where a number is claimed — against the frozen corpus at
`test/corpus`, checked mechanically. §6 records what
was checked, and where the mechanical check disagreed with a first reading.

Build, as always: `cd haskell/ && nix develop -c cabal build`.
GHC 9.10.3. No new dependencies: `base`, `aeson`, `text`, `containers` are
already in the shared `build-depends` list of `agentic.cabal`.

---

## 0 What these two modules are, and are not

`Agentic.Plan` is the port of `Agentic/Core/Plan.lean` (the five term formers,
substitution, grafting, the derived forms), plus the five static folds that the
oracle's reply record reports: `level` (`Agentic/Core/Level.lean`), `size` and
`askNodes` (`Agentic/Core/Explain.lean`), `codes` (`Agentic/Core/Cost.lean`)
and `costSummary` (`Agentic/Core/Explain.lean` over `Agentic/Core/Cost.lean`'s
`CostTree`).

`Agentic.World` is the port of the meaning: `Agentic/Core/Denote.lean`'s
`denote`/`Plan.trace` fused into one fold, `Agentic/Core/Dlg.lean`'s `Event`
and `Trace`, `Agentic/Core/Cost.lean`'s `billFresh`/`billMemo` at the counting
price `tick`, and the whole of `conformance/Conformance.lean`'s world DSL and
event serialization.

**Not here.** No parser, no typing judgment, no `CheckError`, no positions.
`Q` carries no `Pos`; a `Plan` carries no `Pos`; nothing in these two modules
can refuse a program. Well-formedness is Haskell's type checker's job, via
`Agentic.Builder`. The `Raw`-level guards (`blockAsks`, `fnAsks`, the five
refusals) stay in `Agentic.Guards`, where week one put them.

**Ownership.** The agent implementing `Agentic.Plan` and the agent implementing
`Agentic.World` code against this file and do not need to talk. `World` imports
`Plan`; `Plan` imports `Raw` (for `Code`, `Addressee`, `codeName`) and `Text`
(for `Verdict`, see §2.2). Neither imports `Builder` or `Guards`.

---

## 1 Conventions

Carried forward from `PORTING.md` §1 without change:

* Lean `Nat` is Haskell `Integer`. Never `Int`.
* Lean `String` is `Data.Text.Text`.
* JSON comparison is at the `Data.Aeson.Value` level, so **object key order is
  free**. Emit explicit `null` (never omit a key).
* Haskell constructor and field names may be idiomatic; the JSON is what must
  match.

Language extensions used by `Agentic/Plan.hs` (declare them all at the top of
the file, not in the cabal file):

```haskell
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
```

`Agentic/World.hs` needs `{-# LANGUAGE DataKinds, GADTs, LambdaCase,
OverloadedStrings, RankNTypes #-}`.

`-Wall` is on. `Plan` holds functions, so it derives no `Eq`, `Ord` or `Show`;
say so in a Haddock note rather than deriving something partial.

---

## 2 `Agentic.Plan` — the full API

### 2.0 Export list

```haskell
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
```

### 2.1 `Code`, `El`, and the code singleton

`Code` is **not** redefined. It is `Agentic.Raw`'s, promoted with `DataKinds`:

```lean
-- Agentic/Core/Question.lean:215
inductive Code where
  | text | verdict | flag | ack
  deriving DecidableEq, Repr, Inhabited

-- Agentic/Core/Question.lean:228
def El : Code → Type
  | .text => String
  | .verdict => Verdict
  | .flag => Bool
  | .ack => Unit
```

```haskell
import Agentic.Raw (Code (..), Addressee (..), codeName)

-- | @Agentic/Core/Question.lean:228@'s @El@, as a closed type family over the
-- promoted 'Code'.
type family El (c :: Code) :: Type where
  El 'CodeText    = Text
  El 'CodeVerdict = Verdict
  El 'CodeFlag    = Bool
  El 'CodeAck     = ()
```

Lean's `(c : Code)` arguments are value-level and are matched on (`denote`,
`eventJson`, `answerJson` all dispatch on the code). Haskell needs the
singleton for that:

```haskell
-- | The value-level witness of a promoted 'Code'. Lean writes @(c : Code)@ and
-- matches on it; this is that argument.
data SCode (c :: Code) where
  SText    :: SCode 'CodeText
  SVerdict :: SCode 'CodeVerdict
  SFlag    :: SCode 'CodeFlag
  SAck     :: SCode 'CodeAck

fromSCode :: SCode c -> Code

-- | Recovering the singleton from the type, so a builder combinator whose code
-- is fixed by its result type need not be handed one.
class KnownCode (c :: Code) where sCode :: SCode c
instance KnownCode 'CodeText    where sCode = SText
instance KnownCode 'CodeVerdict where sCode = SVerdict
instance KnownCode 'CodeFlag    where sCode = SFlag
instance KnownCode 'CodeAck     where sCode = SAck
```

`Agentic/Core/Question.lean:237`, `instInhabitedEl` — every answer type is
inhabited, which is what lets an analysis substitute an answer it does not
have:

```haskell
-- | Lean's @instInhabitedEl@: @"" @, approve, 'False', @()@.
defaultEl :: SCode c -> El c
```

The `Verdict` default is Lean's `Inhabited Verdict = Option.some []`, which
`Verdict.default_eq_approve` proves is `approve`. So `defaultEl SVerdict =
Approve`, not `Declined`.

### 2.2 Verdicts

**Reuse, do not redefine.** `Agentic.Text` already exports the type:

```haskell
data Verdict = Approve | Declined | Object [Text]
```

`Agentic.Plan` imports it (`import Agentic.Text (Verdict (..))`) and
re-exports it, and adds the algebra `Agentic.Text` kept private. One `Verdict`
in the program, so a tier1 reply built from a trace and a tier0 reply built
from `stringOp` are the same values.

The Lean invariant `Object [] == Approve` (`Verdict.approved_object_iff`)
is already documented on `Agentic.Text.Verdict`; every function below must
preserve it, so build objecting verdicts with `verdictObject`, never with the
bare `Object` constructor.

```lean
-- Agentic/Core/Question.lean:97  Verdict := WithZero (FreeMonoid Objection)
-- :122  approve = 1        :130  declined = 0        :133  object os = ↑os
-- :140  object a * object b = object (a ++ b)
-- :149  declined * v = declined        :152  v * declined = declined
```

```haskell
verdictApprove  :: Verdict                       -- ^ @1@
verdictDeclined :: Verdict                       -- ^ @0@
verdictObject   :: [Text] -> Verdict             -- ^ @↑os@; @[]@ normalizes to 'Approve'

-- | The monoid of @Agentic\/Core\/Question.lean:101@: a zero that annihilates,
-- and free-monoid concatenation otherwise. NOT commutative — an objection list
-- is a record.
verdictMul :: Verdict -> Verdict -> Verdict
```

with, verbatim:

```haskell
verdictMul Declined _ = Declined
verdictMul _ Declined = Declined
verdictMul a b = verdictObject (objectionsOf a ++ objectionsOf b)
```

```lean
-- Agentic/Core/Question.lean:166   Approved v := v = approve
-- Agentic/Core/Plan.lean:551       approvedB v := decide (v = approve)
-- Agentic/Core/Dsl/Syntax.lean:63
def render (v : Verdict) : String :=
  String.intercalate "; " (if h : v = 0 then [] else FreeMonoid.toList (WithZero.unzero h))
```

```haskell
-- | @Verdict.approvedB@ — the 'Bool' a 'caseB' branches on inside 'revising'.
verdictApproved :: Verdict -> Bool

-- | @Verdict.render@: the objections joined by @"; "@; approval and refusal
-- both render as the empty string. This is what a @{v}@ prompt hole means.
verdictRender :: Verdict -> Text
```

`verdictRender Declined == ""` and `verdictRender Approve == ""` — the two
collapse, and `Verdict.render_declined` says so on purpose.

The finite classifier (`Agentic/Core/Plan.lean:495`, `:515`):

```lean
inductive VTag where | approve | object | declined
def Verdict.tag (v : Verdict) : VTag :=
  if v = Verdict.declined then .declined else if v = Verdict.approve then .approve else .object
```

```haskell
data VTag = VApprove | VObject | VDeclined
  deriving (Eq, Ord, Show, Enum, Bounded)

verdictTag :: Verdict -> VTag
```

Note the decision order: `declined` first, then `approve`, then `object`. With
the `Object [] == Approve` invariant held, `verdictTag (Object []) = VApprove`
regardless.

### 2.3 Scope, shape, question

```lean
-- Agentic/Scope.lean:71,143  LastOpt α := Option α;  Scope μ α := LastOpt μ × LastOpt α
-- :86   mul x y = match y with | some b => some b | none => x     -- innermost (right) wins
-- Agentic/Core/Question.lean:72   abbrev QScope := Agentic.Scope String String
-- Agentic/Core/Question.lean:263
structure Q (c : Code) where
  addressee : Addressee
  scope : QScope
  prompt : String
  draw : Nat
-- Agentic/Core/Question.lean:289
structure Q.Shape (c : Code) where
  addressee : Addressee
  scope : QScope
  draw : Nat
-- :301 Q.shape q = ⟨q.addressee, q.scope, q.draw⟩
-- :304 Q.Shape.withPrompt s p = ⟨s.addressee, s.scope, p, s.draw⟩
-- :425 atModel m = fun _ s => { s with scope := Agentic.Scope.fst m * s.scope }
```

```haskell
-- | The two-axis scope. @axis1@ is the model, @axis2@ the mode; the oracle
-- serializes them as @"model"@ and @"mode"@ (see §3.5).
data QScope = QScope
  { scopeModelAxis :: !(Maybe Text)
  , scopeModeAxis  :: !(Maybe Text)
  }
  deriving (Eq, Ord, Show)

-- | The unit @1@ of the scope monoid: both axes silent.
scopeUnit :: QScope

-- | The product. Per axis: the RIGHT operand wins when it is set, else the
-- left survives ('LastOpt.set_overrides' / 'LastOpt.unset_defers'). Getting the
-- side wrong is exactly the mistake @Agentic\/Scope.lean@ warns about.
scopeMul :: QScope -> QScope -> QScope
scopeMul (QScope m1 d1) (QScope m2 d2) =
  QScope (maybe m1 Just m2) (maybe d1 Just d2)

-- | @Scope.fst m@: the model axis set, the mode axis silent.
scopeFst :: Text -> QScope

-- | @Q.Shape c@ — everything that fixes a question except its words. The type
-- index is phantom, exactly as in Lean (no field mentions @c@); it is kept so
-- an @ask@ node's shape is tied to its code.
data Shape (c :: Code) = Shape
  { shAddressee :: !Addressee
  , shScope     :: !QScope
  , shDraw      :: !Integer
  }
  deriving (Eq, Show)

-- | @Q c@ — the shape and the words.
data Q (c :: Code) = Q
  { qAddressee :: !Addressee
  , qScope     :: !QScope
  , qPrompt    :: !Text
  , qDraw      :: !Integer
  }
  deriving (Eq, Show)

shapeOf    :: Q c -> Shape c
withPrompt :: Shape c -> Text -> Q c

-- | @atModel m c s@ of @Agentic\/Core\/Question.lean:425@, at a single shape:
-- @scope := Scope.fst m * scope@. This is the whole of how @served by@ is
-- elaborated — the checker rewrites the shape, it never wraps the term.
atModelShape :: Text -> Shape c -> Shape c
atModelShape m s = s { shScope = scopeMul (scopeFst m) (shScope s) }
```

There is deliberately **no** `Sig`, no `compSig` and no `Plan.under`. The DSL
elaboration never calls `Plan.under`: `Dsl/Check.lean:170`'s `askShape` applies
`atModel` to the leaf shape directly, and `Check.lean:179`'s `under_ask1` is the
`rfl` that licenses it. Porting `under` would be dead code.

### 2.4 Contexts, environments, variables, expressions, substitutions

```lean
-- Agentic/Core/Plan.lean:52    abbrev Ctx := List Code
-- :81   inductive Env : Ctx → Type | nil | consBy (x : El c) (γ : Unit → Env Γ)
-- :128  inductive Var : Ctx → Code → Type | here | there
-- :137  Var.get .here γ = γ.head ; Var.get (.there v) γ = v.get γ.tail
-- :151  abbrev Expr (Γ) (A) := Env Γ → A
-- :169  abbrev Sub (Γ Δ) := Expr Δ (Env Γ)
-- :176  id ; :180 comp σ τ = fun θ => σ (τ θ) ; :183 wk = Env.tail
-- :191  lift σ = fun δ => .consBy δ.head fun _ => σ δ.tail
```

```haskell
type Ctx = [Code]

-- | @Env Γ@: one answer per code the context records, innermost first.
--
-- Lean's @Env@ delays its tail (@consBy@) to keep reading de Bruijn 0 a
-- projection; in Haskell the field is lazy by default, so the plain
-- constructor already has that property and no @consBy@ is needed. Do NOT add
-- strictness annotations here — the @2^n@ blow-up documented on
-- @Agentic\/Core\/Plan.lean:81@ is exactly what a strict tail costs.
data Env (g :: Ctx) where
  ENil  :: Env '[]
  ECons :: El c -> Env g -> Env (c ': g)

envHead :: Env (c ': g) -> El c
envTail :: Env (c ': g) -> Env g

data Var (g :: Ctx) (c :: Code) where
  VHere  :: Var (c ': g) c
  VThere :: Var g c -> Var (c' ': g) c

varGet :: Var g c -> Env g -> El c

type Expr (g :: Ctx) a = Env g -> a

exprVar   :: Var g c -> Expr g (El c)
exprConst :: a -> Expr g a

-- | A context morphism, semantically: @Env Δ -> Env Γ@.
type Sub (g :: Ctx) (d :: Ctx) = Env d -> Env g

subId   :: Sub g g
subComp :: Sub g d -> Sub d e -> Sub g e     -- ^ @\\e -> s (t e)@
subWk   :: Sub g (c ': g)                    -- ^ 'envTail'
subLift :: Sub g d -> Sub (c ': g) (c ': d)  -- ^ @\\d -> ECons (envHead d) (s (envTail d))@

-- | The idiom @fun δ => Env.cons (e δ) (σ δ)@, which @Dsl\/Check.lean@ writes
-- at every binding, every call argument and every revision continuation.
subCons :: Expr d (El c) -> Sub g d -> Sub (c ': g) d
subCons e s = \d -> ECons (e d) (s d)
```

### 2.5 The `Plan` GADT — the five formers

```lean
-- Agentic/Core/Plan.lean:238
inductive Plan : Ctx → Type → Type 1 where
  | ret  {Γ A} (e : Expr Γ A) : Plan Γ A
  | askC {Γ A} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) : Plan Γ A
  | ask  {Γ A} (c : Code) (s : Q.Shape c) (e : Expr Γ String) (k : Plan (c :: Γ) A) : Plan Γ A
  | case {Γ A} {T : Type} [FinEnum T] [DecidableEq T] (e : Expr Γ T) (arms : T → Plan Γ A) : Plan Γ A
  | dyn  {Γ A} {B : Type} (e : Expr Γ B) (f : B → Plan Γ A) : Plan Γ A
```

**Which tag types the elaboration actually produces.** Read
`Agentic/Core/Dsl/Check.lean` end to end for every construction of a `case`
node. There are exactly three sites, and they use exactly two tag types:

| site | Lean | tag type | arms |
| --- | --- | --- | --- |
| `if x { … } else { … }` | `Check.lean:679` `.ok (Plan.caseB e y' n')` | `Bool` | `False → else`, `True → then` |
| `case v { approved … objected … no answer … }` | `Check.lean:699` `Plan.caseV e (fun t => match t with \| .approve => a' \| .object => o' \| .declined => d')` | `VTag` | three |
| the `revising` unroll and its `settled`/`unsettled` exit | `Plan.lean:630` `caseB (fun θ => Verdict.approvedB (v θ)) …` and `Check.lean:508` `finishCont`'s `Plan.caseB (fun δ => (final δ).isSome) …` | `Bool` | two |

Nothing else. `Bool` and `VTag`, and no third. (`Check.lean:55` also records
that **no clause emits `Plan.dyn`** — the DSL never reaches the dynamic rung.)

So the tag set is closed and is rendered as a closed singleton GADT rather than
as a `FinEnum` class with an existential dictionary:

```haskell
-- | The tag types a 'PCase' may branch on. Closed, because the elaboration
-- produces exactly these two (@Dsl\/Check.lean@: @caseB@ at @Bool@ three times,
-- @caseV@ at 'VTag' once). Lean's @FinEnum@ instance is 'tagValues'.
data Tag t where
  TBool :: Tag Bool
  TVTag :: Tag VTag

-- | Lean's @FinEnum.toList@, in Lean's order:
--
-- > scoped instance instFinEnumBool : FinEnum Bool := FinEnum.ofList [false, true]
-- > instance instFinEnumVTag : FinEnum VTag := FinEnum.ofList [.approve, .object, .declined]
tagValues :: Tag t -> [t]
tagValues TBool = [False, True]
tagValues TVTag = [VApprove, VObject, VDeclined]
```

The enumeration order is unobservable in every fold ported here — `size` and
`askNodes` sum over it, `level` joins over it, `costLeaves` is read only through
`minimum`, `maximum` and `length`. It is Lean's order anyway; keep it.

```haskell
-- | The five formers of @Agentic\/Core\/Plan.lean:238@.
--
-- No 'Eq', 'Ord' or 'Show': every former but 'PRet' holds a function.
data Plan (g :: Ctx) a where
  PRet  :: Expr g a -> Plan g a
  PAskC :: SCode c -> Q c -> Plan (c ': g) a -> Plan g a
  PAsk  :: SCode c -> Shape c -> Expr g Text -> Plan (c ': g) a -> Plan g a
  PCase :: Tag t -> Expr g t -> (t -> Plan g a) -> Plan g a
  PDyn  :: Expr g b -> (b -> Plan g a) -> Plan g a
```

`PDyn` is present for fidelity with the fifth former and to give `level` a
`Dynamic` to return. The builder cannot construct one and tier1 never sees one;
§2.7 and §2.8 say what each fold does at it.

### 2.6 Substitution, grafting, and the derived forms

```lean
-- Agentic/Core/Plan.lean:309
def sub : Plan Γ A → Sub Γ Δ → Plan Δ A
  | .ret e, σ => .ret (fun δ => e (σ δ))
  | .askC c q k, σ => .askC c q (sub k (Sub.lift σ))
  | .ask c s e k, σ => .ask c s (fun δ => e (σ δ)) (sub k (Sub.lift σ))
  | .case e arms, σ => .case (fun δ => e (σ δ)) (fun t => sub (arms t) σ)
  | .dyn e f, σ => .dyn (fun δ => e (σ δ)) (fun b => sub (f b) σ)
```

```haskell
subP :: Plan g a -> Sub g d -> Plan d a

-- | @subP p subWk@: read a plan under one more binding. This is what an @act@
-- statement does with its continuation (@Check.lean:565@:
-- @form (Plan.sub k Sub.wk)@) — the receipt is bound and then ignored.
weakenP :: Plan g a -> Plan (c ': g) a
```

```lean
-- Agentic/Core/Plan.lean:410
abbrev Cont (Γ : Ctx) (A B : Type) : Type 1 := ∀ Δ : Ctx, Sub Γ Δ → Expr Δ A → Plan Δ B
-- :421
def graft : Plan Γ A → Cont Γ A B → Plan Γ B
  | .ret e, k => k _ Sub.id e
  | .askC c q p, k => .askC c q (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  | .ask c s d p, k => .ask c s d (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  | .case d arms, k => .case d (fun t => graft (arms t) k)
  | .dyn d f, k => .dyn d (fun b => graft (f b) k)
```

Lean's `Cont` is a Π-type over contexts; Haskell needs a `newtype` for it
(the rank-2 argument is passed to a recursive function and rebuilt inside):

```haskell
newtype Cont (g :: Ctx) a b = Cont
  { runCont :: forall (d :: Ctx). Sub g d -> Expr d a -> Plan d b }

graft :: Plan g a -> Cont g a b -> Plan g b
```

with the `PAskC`/`PAsk` clauses rebuilding the continuation as
`Cont (\s e -> runCont k (subComp subWk s) e)`.

The derived forms (`Plan.lean:432`–`:481`, `:595`, `:621`), all needed by the
builder:

```haskell
mapP     :: (a -> b) -> Plan g a -> Plan g b
zipWithP :: (a -> b -> c) -> Plan g a -> Plan g b -> Plan g c
pairP    :: Plan g a -> Plan g b -> Plan g (a, b)
seqP     :: Plan g a -> Plan g b -> Plan g b
bindP    :: Plan g a -> (a -> Plan g b) -> Plan g b   -- ^ the ONLY one using 'PDyn'

askC1 :: SCode c -> Q c -> Plan g (El c)
ask1  :: SCode c -> Shape c -> Expr g Text -> Plan g (El c)

-- | @Plan.caseB e t f = .case e (fun b => cond b t f)@ — note the arm order:
-- 'True' takes @t@.
caseB :: Expr g Bool -> Plan g a -> Plan g a -> Plan g a
caseB e t f = PCase TBool e (\b -> if b then t else f)

-- | @Plan.caseV e arms = .case (fun γ => Verdict.tag (e γ)) arms@.
caseV :: Expr g Verdict -> (VTag -> Plan g a) -> Plan g a
caseV e arms = PCase TVTag (verdictTag . e) arms
```

```lean
-- Agentic/Core/Plan.lean:595
def panel [Monoid (El c)] (ps : List (Plan Γ (El c))) : Plan Γ (El c) :=
  ps.foldr (zipWith (· * ·)) (.ret (fun _ => 1))
```

Lean states `panel` at any code carrying a `Monoid (El c)`, and installs that
instance **only** at `.verdict` (`Plan.lean:572`). The checker agrees:
`Check.lean:438` admits a panel only at `Code.verdict`. So the Haskell port is
monomorphic and needs no class:

```haskell
-- | @Plan.panel@ at the one code the monoid lives at.
-- @panel [] = PRet (const verdictApprove)@ — Lean's @1@. The checker refuses an
-- empty panel (@Check.lean:437@) before this is ever reached, but the clause is
-- the unit of the fold and must be written.
panel :: [Plan g Verdict] -> Plan g Verdict
panel = foldr (zipWithP verdictMul) (PRet (const verdictApprove))
```

```lean
-- Agentic/Core/Plan.lean:621
def revising {Γ c} (check : Cont Γ (El c) Verdict) (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (Option (El c))
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => if Verdict.approvedB (v θ) then some (a (τ θ)) else none)
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseB (fun θ => Verdict.approvedB (v θ))
          (.ret (fun θ => some (a (τ θ))))
          (graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
            revising check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')
```

```haskell
-- | Bounded revision, check-first. @revising chk rev n@ performs @n+1@ checks
-- and at most @n@ amendments. @n <= 0@ is the base clause. The checker refuses
-- @n > 64@ (@Check.lean:520 maxRevisions@) before elaborating, so no bound on
-- @n@ is enforced here.
revising ::
  Cont g (El c) Verdict ->
  Cont g (El c, Verdict) (El c) ->
  Integer ->
  Cont g (El c) (Maybe (El c))
```

Transliterate the two clauses literally, including the `Sub.comp` chains — they
are what makes the artefact expression readable at the leaf it reaches.

### 2.7 The static folds — `level`, `size`, `askNodes`, `codes`

```lean
-- Agentic/Core/Level.lean:53
inductive Level where | batch | pipeline | branch | dynamic
-- :69   toNat: batch 0, pipeline 1, branch 2, dynamic 3; the LinearOrder is its pullback
-- :120
def level : Plan Γ A → Level
  | .ret _ => .batch
  | .askC _ _ k => level k
  | .ask _ _ _ k => max .pipeline (level k)
  | .case _ arms => max .branch (Finset.univ.sup fun t => level (arms t))
  | .dyn _ _ => .dynamic
-- Agentic/Core/Explain.lean:69
def levelName : Level → String
  | .batch => "batch" | .pipeline => "pipeline" | .branch => "branch" | .dynamic => "dynamic"
```

```haskell
data Level = Batch | Pipeline | Branch | Dynamic
  deriving (Eq, Ord, Show, Enum, Bounded)   -- ^ the chain, in this order

levelName :: Level -> Text

level :: Plan g a -> Level
level = \case
  PRet _          -> Batch
  PAskC _ _ k     -> level k                              -- NOT `max Batch`; askC adds nothing
  PAsk _ _ _ k    -> max Pipeline (level k)
  PCase t _ arms  -> foldr (max . level . arms) Branch (tagValues t)
  PDyn _ _        -> Dynamic
```

`Finset.univ.sup` over the empty tag type is `⊥ = Batch`, which is why the
`PCase` fold seeds with `Branch` and joins: an arm-less branch is still
`Branch`. Both tag types here are inhabited, so this is a fidelity point only.

```lean
-- Agentic/Core/Explain.lean:140
def Plan.size : Plan Γ A → Nat
  | .ret _ => 1
  | .askC _ _ k => 1 + Plan.size k
  | .ask _ _ _ k => 1 + Plan.size k
  | @Plan.case _ _ T _ _ _ arms => 1 + (FinEnum.toList T).foldl (fun acc t => acc + Plan.size (arms t)) 0
  | .dyn _ _ => 1
-- Agentic/Core/Explain.lean:155
def Plan.askNodes : Plan Γ A → Nat
  | .ret _ => 0
  | .askC _ _ k => 1 + Plan.askNodes k
  | .ask _ _ _ k => 1 + Plan.askNodes k
  | @Plan.case _ _ T _ _ _ arms => (FinEnum.toList T).foldl (fun acc t => acc + Plan.askNodes (arms t)) 0
  | .dyn _ _ => 0
```

```haskell
size     :: Plan g a -> Integer
askNodes :: Plan g a -> Integer
```

Note the asymmetry, which is not a typo: a `case` **counts itself** in `size`
(the `1 +`) and **does not** in `askNodes`; a `dyn` is one node and zero asks.

```lean
-- Agentic/Core/Cost.lean:304
def codes : Plan Γ A → Option (List Code)
  | .ret _ => some []
  | .askC c _ k => (c :: ·) <$> codes k
  | .ask c _ _ k => (c :: ·) <$> codes k
  | .case _ _ => none
  | .dyn _ _ => none
```

```haskell
-- | The code sequence, where the term fixes it. 'Nothing' at a 'PCase' and at a
-- 'PDyn' — those are the two places the sequence is not fixed by the term.
codes :: Plan g a -> Maybe [Code]
```

The reply serializes it with **`codeName`**, so `CodeAck` prints as
`"receipt"` (`Conformance.lean:254`: `cs.map (fun c => Json.str (codeName c))`).
That is `PORTING.md` §3.4's trap in its reply-side form; tier1 owns the
printing, but say it here so nobody stores the wrong spelling in the fold.

### 2.8 `costSummary` — the cost tree, the two folds and the path count

```lean
-- Agentic/Core/Cost.lean:610
inductive CostTree (S : Type) : Type 1 where
  | leaf : S → CostTree S
  | node (T : Type) (inst : Fintype T) (f : T → CostTree S) : CostTree S
-- :631
def leaves : CostTree S → Multiset S
  | .leaf s => {s}
  | .node T inst f => (@Finset.univ T inst).val.bind (fun t => (f t).leaves)
-- :668
def costTree [CommMonoid S] (price : Price S) :
    (p : Plan Γ A) → level p ≤ Level.branch → Env Γ → CostTree S
  | .ret _, _, _ => .leaf 1
  | .askC c q k, h, γ => (costTree price k h (.cons default γ)).map (price c q * ·)
  | .ask c s e k, h, γ =>
      (costTree price k _ (.cons default γ)).map (price c (s.withPrompt (e γ)) * ·)
  | @Plan.case _ _ T _ _ _ arms, h, γ => .node T inferInstance (fun t => costTree price (arms t) _ γ)
  | .dyn _ _, h, _ => absurd h (by simp only [level_dyn]; decide)
-- :723
def CostTree.minFold : CostTree S → WithTop S
  | .leaf s => (s : WithTop S)
  | .node T inst f => (@Finset.univ T inst).inf (fun t => (f t).minFold)
-- :730
def CostTree.maxFold : CostTree S → WithBot S
  | .leaf s => (s : WithBot S)
  | .node T inst f => (@Finset.univ T inst).sup (fun t => (f t).maxFold)
-- Agentic/Core/Cost.lean:258
def tick : Price (Multiplicative Nat) := fun _ _ => Multiplicative.ofAdd 1
-- Agentic/Core/Explain.lean:445
def costSummary (p : Plan [] A) (h : level p ≤ Level.branch) : Option Nat × Option Nat × Nat :=
  let τ := costTree tick p h Env.nil
  ( τ.minFold.recTopCoe none (fun s => some (Multiplicative.toAdd s))
  , τ.maxFold.recBotCoe none (fun s => some (Multiplicative.toAdd s))
  , Multiset.card τ.leaves )
```

**Three simplifications, each licensed and each load-bearing.**

1. The price is always `tick`, and `tick` ignores its question. So the
   `Env`/`default` threading in `costTree` is dead: nothing in the tick tree
   depends on the environment, and neither `s.withPrompt (e γ)` nor a `case`
   scrutineee is ever evaluated. The Haskell fold therefore takes **no
   environment** and works in any context.
2. `Multiplicative Nat` read through `Multiplicative.toAdd` is ordinary
   addition: `leaf 1` is additive `0`, and each `askC`/`ask` adds `1`. So a
   leaf is `Integer` and the tree's leaf bill is a count of consultations.
3. `Multiset` is only ever read through `min`, `max` and `card`, so a `[]` in
   leaf order is faithful.

```haskell
data CostTree = CostLeaf !Integer | CostNode [CostTree]

-- | The tick cost tree of a term. @'CostNode' []@ at a 'PDyn': that is the
-- position where Lean has @absurd@, because @costTree@ is defined only at
-- @level p ≤ branch@. An arm-less node admits no bill, which is exactly what
-- Lean's @WithTop@/@WithBot@ folds report for it, so the summary below stays
-- total and honest instead of partial. The builder cannot produce a 'PDyn',
-- and tier1 must assert @'level' p <= 'Branch'@ before printing a summary.
costTree :: Plan g a -> CostTree
costTree = \case
  PRet _         -> CostLeaf 0
  PAskC _ _ k    -> bump (costTree k)
  PAsk _ _ _ k   -> bump (costTree k)
  PCase t _ arms -> CostNode (map (costTree . arms) (tagValues t))
  PDyn _ _       -> CostNode []
  where bump (CostLeaf n) = CostLeaf (n + 1)
        bump (CostNode ts) = CostNode (map bump ts)

costLeaves :: CostTree -> [Integer]

-- | @(minFold, maxFold, paths)@. 'Nothing' exactly when the leaf bag is empty,
-- which is Lean's @⊤@/@⊥@ and cannot arise from an elaborated program.
costSummary :: Plan g a -> (Maybe Integer, Maybe Integer, Integer)
costSummary p =
  let ls = costLeaves (costTree p)
  in ( if null ls then Nothing else Just (minimum ls)
     , if null ls then Nothing else Just (maximum ls)
     , fromIntegral (length ls)
     )
```

`paths` is the leaf **count with repetitions** (`Multiset.card`), not the number
of distinct bills. `battery-042` has `paths 2` with `minFold = maxFold = 3`:
two paths, the same price.

#### Worked example: `battery-085-a-review-annotated-at-verdict`

The program (`test/corpus/battery-085-a-review-annotated-at-verdict.json`), in
surface terms:

```
d : text <- ask model "a" "draft"
r <- revising d as c at most 1 amendments
       review v : verdict <- ask model "m" "review {c}"
       amend            <- ask model "a" "fix {c} {v}"
case r { settled x { } unsettled { } }
```

Elaborate by the rules above:

* `check` = `ask1 SVerdict … "review {c}"` — one `PAsk`, leaves `[1]`.
* `revise` = `ask1 SText … "fix {c} {v}"` — one `PAsk`, leaves `[1]`.
* `revising check revise 0` = `graft check (PRet …)` — leaves `[1]`.
* `revising check revise 1` = `graft check (caseB _ (PRet …) (graft revise (revising … 0)))`
  — leaves `[1 + 0, 1 + 1 + 1] = [1, 3]`.
* `caseResult` = `graft (revising … 1) (caseB _ settled unsettled)` with both
  arms `PRet` — each leaf splits in two at `+0`: `[1, 1, 3, 3]`.
* the outer closed `d <- ask …` is a `PAskC` (its prompt has no hole), adding
  `1` to every leaf: `[2, 2, 4, 4]`.

So `costSummary = (Just 2, Just 4, 4)`; `size = 11`; `askNodes = 4`;
`level = Branch`; `codes = Nothing`. The corpus reply:

```json
"size": 11, "level": "branch", "askNodes": 4, "codes": null,
"costSummary": {"paths": 4, "minFold": 2, "maxFold": 4}
```

This reading was checked mechanically, not by eye: a python transcription of
the elaboration rules and of all five folds reproduces
**`level`, `size`, `askNodes`, `codes` and `costSummary` for all 59 checked
corpus entries, with zero mismatches** (§9).

Two more entries worth having in tier1's smoke set, both verified the same way:

| entry | shape | level | size | askNodes | costSummary |
| --- | --- | --- | --- | --- | --- |
| `battery-063-a-panel-needs-no-annotation` | one-member panel, then `caseV` with three empty arms | `branch` | 5 | 1 | `(1, 1, 3)` |
| `semantic-003-a-flag-carrier-loop` | `askC`, `ask` at flag, `caseB`, one act in the `then` arm | `branch` | 6 | 3 | `(2, 3, 2)` |

`battery-063` is the one that shows `paths` counting arms rather than prices:
three `VTag` arms, all free, so `minFold = maxFold = 1` and `paths = 3`.

---

## 3 `Agentic.World` — the full API

### 3.0 Export list

```haskell
module Agentic.World
  ( -- * The world, as data
    VLit (..),
    vLitToVerdict,
    TextSpec (..),
    VerdictSpec (..),
    FlagSpec (..),
    WorldSpec (..),
    defaultWorldSpec,
    World (..),
    toWorld,

    -- * The meaning
    Event (..),
    Trace,
    trace,
    traceIn,
    runPlan,
    runIn,

    -- * The bills
    EventKey (..),
    eventKey,
    billFresh,
    billMemo,

    -- * The oracle's JSON
    verdictJson,
    answerJson,
    scopeJson,
    eventJson,
    worldObservation,
  )
where
```

### 3.1 `WorldSpec`, quoted

```lean
-- conformance/Conformance.lean:73
inductive VLit where
  | approve
  | declined
  | object (objections : List String)
  deriving FromJson, ToJson

-- :85
inductive TextSpec where
  | echo
  | wrap (pre post : String)
  | const (s : String)
  | byDraw
  | byPrefix (table : List (String × String)) (default : String)
  deriving FromJson, ToJson

-- :99
inductive VerdictSpec where
  | const (v : VLit)
  | byPrefix (table : List (String × VLit)) (default : VLit)
  deriving FromJson, ToJson

-- :105
inductive FlagSpec where
  | const (b : Bool)
  | promptEq (s : String)
  | byPrefix (table : List (String × Bool)) (default : Bool)
  deriving FromJson, ToJson

-- :112
structure WorldSpec where
  text : TextSpec := .echo
  verdict : VerdictSpec := .const .approve
  flag : FlagSpec := .const true
  deriving FromJson, ToJson
```

```haskell
data VLit = VLitApprove | VLitDeclined | VLitObject [Text]
  deriving (Eq, Show)

vLitToVerdict :: VLit -> Verdict          -- ^ @VLitObject []@ normalizes to 'Approve'

data TextSpec
  = TEcho
  | TWrap !Text !Text                     -- ^ @pre@, @post@
  | TConst !Text
  | TByDraw
  | TByPrefix [(Text, Text)] !Text        -- ^ table, default
  deriving (Eq, Show)

data VerdictSpec
  = VConst !VLit
  | VByPrefix [(Text, VLit)] !VLit
  deriving (Eq, Show)

data FlagSpec
  = FConst !Bool
  | FPromptEq !Text
  | FByPrefix [(Text, Bool)] !Bool
  deriving (Eq, Show)

data WorldSpec = WorldSpec
  { wsText    :: !TextSpec
  , wsVerdict :: !VerdictSpec
  , wsFlag    :: !FlagSpec
  }
  deriving (Eq, Show)

-- | The Lean structure's field defaults: @echo@, @const approve@, @const true@.
defaultWorldSpec :: WorldSpec
```

**JSON**, by `PORTING.md` §3.1's rules (this is the same `deriving ToJson`
strategy; nothing new):

| Lean | JSON |
| --- | --- |
| `VLit.approve` / `.declined` | `"approve"` / `"declined"` |
| `VLit.object os` | `{"object": {"objections": [...]}}` |
| `TextSpec.echo` / `.byDraw` | `"echo"` / `"byDraw"` |
| `TextSpec.wrap p q` | `{"wrap": {"pre": p, "post": q}}` |
| `TextSpec.const s` | `{"const": {"s": s}}` |
| `TextSpec.byPrefix t d` | `{"byPrefix": {"table": [[k,v],…], "default": d}}` |
| `VerdictSpec.const v` | `{"const": {"v": <VLit>}}` |
| `VerdictSpec.byPrefix t d` | `{"byPrefix": {"table": [[k,<VLit>],…], "default": <VLit>}}` |
| `FlagSpec.const b` | `{"const": {"b": b}}` |
| `FlagSpec.promptEq s` | `{"promptEq": {"s": s}}` |
| `FlagSpec.byPrefix t d` | `{"byPrefix": {"table": [[k,b],…], "default": d}}` |
| `WorldSpec` | `{"text": …, "verdict": …, "flag": …}` — bare object, no tag |

Liberal in, strict out, as in week one: decode a nullary constructor from a
bare string (also accept the one-key object form), decode a missing `WorldSpec`
field as its Lean default; **encode all three fields always**, and encode a
nullary constructor as the bare string. The reply's `"world"` field is a
re-serialization of the request's world spec and must come back byte-equal at
the `Value` level — verified for all 63 world blocks in the corpus.

Only four distinct world specs occur in the frozen corpus:

```json
{"text": "echo",                        "verdict": {"const": {"v": "approve"}},                                  "flag": {"const": {"b": true}}}
{"text": "byDraw",                      "verdict": {"const": {"v": "approve"}},                                  "flag": {"const": {"b": true}}}
{"text": {"wrap": {"pre":"<","post":">"}}, "verdict": {"const": {"v": "approve"}},                               "flag": {"const": {"b": true}}}
{"text": "echo",                        "verdict": {"const": {"v": {"object": {"objections": ["not good enough"]}}}}, "flag": {"const": {"b": false}}}
```

`byPrefix` (all three), `promptEq` and `VLitDeclined` are **not exercised by
the corpus**. Implement them anyway — tier1's rebuilt cases may add worlds —
but do not expect the corpus to catch a mistake in them.

### 3.2 `toWorld`

```lean
-- Agentic/Core/World.lean:47   abbrev Ω := (c : Code) → Q c → El c
-- conformance/Conformance.lean:118
def WorldSpec.toWorld (w : WorldSpec) : Ω
  | .text, q => match w.text with
    | .echo => q.prompt
    | .wrap pre post => pre ++ q.prompt ++ post
    | .const s => s
    | .byDraw => "draw:" ++ toString q.draw
    | .byPrefix table d => match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2 | none => d
  | .verdict, q => match w.verdict with
    | .const v => v.toVerdict
    | .byPrefix table d => match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2.toVerdict | none => d.toVerdict
  | .flag, q => match w.flag with
    | .const b => b
    | .promptEq s => q.prompt == s
    | .byPrefix table d => match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2 | none => d
  | .ack, _ => ()
```

```haskell
-- | @Ω = (c : Code) → Q c → El c@. A rank-2 newtype, because the answer type
-- depends on the code.
newtype World = World { worldAnswer :: forall (c :: Code). SCode c -> Q c -> El c }

toWorld :: WorldSpec -> World
```

Details that matter: `byPrefix` is **first match wins** over the table in
order, testing `key` as a prefix of the prompt (`Data.Text.isPrefixOf`);
`promptEq` is exact equality on the whole prompt, with no normalization;
`byDraw` is the literal `"draw:" <> pack (show draw)`; `ack` is `()` with no
inspection of the spec at all.

### 3.3 `Event`, `Trace`, `trace`

```lean
-- Agentic/Core/Dlg.lean:112
structure Event where
  c : Code
  q : Q c
  a : El c
abbrev Trace : Type := List Event      -- :124
-- Agentic/Core/Dlg.lean:146
def Dlg.trace (ω : Ω) : Dlg A → Trace
  | .done _ => []
  | .ask c q f => ⟨c, q, ω c q⟩ :: trace ω (f (ω c q))
-- Agentic/Core/Denote.lean:64
def denote : Plan Γ A → Env Γ → Dlg A
  | .ret e, γ => .done (e γ)
  | .askC c q k, γ => .ask c q (fun x => denote k (.cons x γ))
  | .ask c s e k, γ => .ask c (s.withPrompt (e γ)) (fun x => denote k (.cons x γ))
  | .case e arms, γ => denote (arms (e γ)) γ
  | .dyn e f, γ => denote (f (e γ)) γ
-- Agentic/Core/Denote.lean:109
def Plan.trace (ω : Ω) (p : Plan Γ A) (γ : Env Γ) : Trace := Dlg.trace ω (denote p γ)
```

`Dlg` is **not** ported. `Plan.trace` is `Dlg.trace ∘ denote` and the
composite's five clauses are the four `simp` lemmas at `Denote.lean:123`-`:141`
plus the shared `case`/`dyn` clause; port the fused fold directly:

```haskell
type Trace = [Event]

-- | @Σ c, Q c × El c@: one question put and the reply it got.
data Event where
  Event :: SCode c -> Q c -> El c -> Event

-- | @Plan.trace@ in the empty context — what tier1 calls.
trace :: World -> Plan '[] a -> Trace
trace w = traceIn w ENil

-- | The general fold. Clause for clause:
--
-- > traceIn _ _ (PRet _)          = []
-- > traceIn w y (PAskC c q k)     = Event c q a : traceIn w (ECons a y) k    where a = ω c q
-- > traceIn w y (PAsk c s e k)    = Event c q a : traceIn w (ECons a y) k
-- >                                   where q = withPrompt s (e y); a = ω c q
-- > traceIn w y (PCase _ e arms)  = traceIn w y (arms (e y))
-- > traceIn w y (PDyn e f)        = traceIn w y (f (e y))
traceIn :: World -> Env g -> Plan g a -> Trace

-- | @Plan.run@ — the answer rather than the transcript. Not part of the
-- oracle's record, but free from the same fold and useful in tier1 assertions.
runPlan :: World -> Plan '[] a -> a
runIn   :: World -> Env g -> Plan g a -> a
```

Three things the fold must get right, all of which the corpus catches:

* the answer is computed **once** and both recorded in the event and pushed
  onto the environment (a world is a function, so recomputing gives the same
  value, but do not write it twice — `ask`'s prompt is rebuilt otherwise);
* an `ask` node's question is `withPrompt s (e γ)` — the prompt is evaluated in
  the environment **before** the answer is bound;
* `case` and `dyn` record **nothing**; the branch taken is the whole of their
  contribution (`Denote.lean:58`: they share a meaning clause on purpose).

### 3.4 The bills, and what makes two events the same question

```lean
-- Agentic/Core/Cost.lean:90
abbrev Key : Type := (c : Code) × Q c
def Event.key (e : Event) : Key := ⟨e.c, e.q⟩      -- :110
-- :156
def billOfKeys [Monoid S] (price : Price S) (ks : List Key) : S := (ks.map (priceKey price)).prod
-- :166
def billFresh [Monoid S] (price : Price S) (t : Trace) : S := billOfKeys price (t.map Event.key)
-- :176
def billMemo [Monoid S] (price : Price S) (t : Trace) : S :=
  billOfKeys price ((t.map Event.key).dedup)
-- :258   tick := fun _ _ => Multiplicative.ofAdd 1
-- conformance/Conformance.lean:236  toJson (Multiplicative.toAdd (billFresh tick t))
```

The oracle serializes only the tick bills, so the port is monomorphic:

```haskell
-- | Lean's @Key = Σ c, Q c@, flattened. Equality is on all five components and
-- on nothing else: the ANSWER is not part of the key (a world is a function, so
-- equal questions have equal answers anyway — @Agentic\/Core\/Question.lean@ §3
-- q1), and there is no position and no site.
data EventKey = EventKey
  { ekCode      :: !Code
  , ekAddressee :: !Addressee
  , ekScope     :: !QScope
  , ekPrompt    :: !Text
  , ekDraw      :: !Integer
  }
  deriving (Eq, Ord, Show)

eventKey :: Event -> EventKey

-- | @Multiplicative.toAdd (billFresh tick t)@ = @t.length@
-- (@Cost.lean:263 billFresh_tick@). Charge every event.
billFresh :: Trace -> Integer
billFresh = fromIntegral . length

-- | @Multiplicative.toAdd (billMemo tick t)@ = the number of DISTINCT keys.
-- Charge each distinct question once.
billMemo :: Trace -> Integer
```

**The memo equality, stated.** Two events are "the same question" exactly when
their `EventKey`s are equal: same code, same addressee, same scope (both axes),
same prompt text, same draw index. Consequences the corpus pins:

* `battery-117-two-draws-of-one-prompt-are-two-questions`: three `text`
  questions to `model "oracle"` with the identical prompt `"same words"`,
  drawn at `0`, `0`, `1`, then one receipt. `billFresh 4`, `billMemo 3` — the
  two draw-`0` questions collapse; the draw-`1` one does not. This is
  `Q.draw`'s entire reason for existing: resampling is a *different question*.
* `battery-137-empty-prompts-and-an-empty-define`: three receipts to
  `tool "t"` with prompts `""`, `""`, `"prepost"`. `billFresh 3`,
  `billMemo 2`.

Those are the **only two** corpus entries where `billMemo < billFresh`;
everywhere else the two agree. In particular
`vector-001-billmemo-below-billfresh` — the entry whose *name* says otherwise —
reports `billFresh 3, billMemo 3` (see §9).

**One subtlety, harmless here and dangerous if generalized.** Lean's
`List.dedup` is `pwFilter (· ≠ ·)` and keeps the **last** occurrence
(`Mathlib/Data/List/Defs.lean:241`: *"removes duplicates from `l` (taking only
the last occurrence)"*), while Haskell's `nub` keeps the first. The two agree on
**length**, which is all `billMemo` at `tick` observes, so
`billMemo = genericLength . nubOrd . map eventKey` is correct. If anything ever
needs the deduplicated key *list* (a non-commutative price carrier would),
it must reproduce Lean's last-wins order instead.

### 3.5 The event JSON, field by field

```lean
-- conformance/Conformance.lean:152
def verdictJson (v : Verdict) : Json :=
  match Verdict.tag v with
  | .approve => Json.mkObj [("tag", "approve")]
  | .declined => Json.mkObj [("tag", "declined")]
  | .object => Json.mkObj [("tag", "object"), ("objections", toJson (… : List Objection))]
-- :163
def answerJson : (c : Code) → El c → Json
  | .text, s => Json.str s
  | .verdict, v => verdictJson v
  | .flag, b => Json.bool b
  | .ack, _ => Json.null
-- :169
def scopeJson (s : QScope) : Json :=
  Json.mkObj [ ("model", match s.1 with | some m => Json.str m | none => Json.null)
             , ("mode",  match s.2 with | some m => Json.str m | none => Json.null) ]
-- :174
def eventJson (e : Event) : Json :=
  Json.mkObj
    [ ("code", Json.str (codeName e.c))
    , ("addressee", toJson e.q.addressee)
    , ("scope", scopeJson e.q.scope)
    , ("prompt", Json.str e.q.prompt)
    , ("draw", toJson e.q.draw)
    , ("answer", answerJson e.c e.a) ]
```

```haskell
verdictJson :: Verdict -> Value
answerJson  :: SCode c -> El c -> Value
scopeJson   :: QScope -> Value
eventJson   :: Event -> Value
```

Field by field:

| key | value | trap |
| --- | --- | --- |
| `code` | `codeName` of the event's code | **`"receipt"`, never `"ack"`** — this is the reply-side half of `PORTING.md` §3.4 |
| `addressee` | `Agentic.Raw`'s `ToJSON Addressee` | `{"tool":{"id":"cat"}}`; do not invent a flat form |
| `scope` | `{"model": … , "mode": …}` | **both keys always present**, `null` when the axis is silent; the key is `mode`, not `mode2`/`axis2` |
| `prompt` | the rendered words, as a JSON string | the *evaluated* prompt, not the chunk list |
| `draw` | the draw index, a number | `0` unless the author resampled |
| `answer` | `answerJson` at the code | `text` → string; `verdict` → the tagged object; `flag` → a JSON bool; `ack` → **explicit `null`** |

`verdictJson` on a verdict that approves is `{"tag":"approve"}` with **no**
`objections` key; only the `object` case carries the array. `Object []` must
never be produced (§2.2) — but normalize in `verdictJson` too, belt and braces,
exactly as `Agentic.Text.verdictJson` already does.

Only one corpus entry has a non-unit scope on the wire:
`battery-119-served-by-and-independent-draw-together-in-every-ask-position`,
whose events carry `{"model":"deep","mode":null}` and
`{"model":"cheap","mode":null}` — the `served by` override reaching the shape
through `atModelShape`. The `mode` axis is never set by anything in this
language; it exists because the scope monoid has two axes.

### 3.6 `worldObservation`

```lean
-- conformance/Conformance.lean:232
def worldObservation (p : Plan [] Unit) (w : WorldSpec) : Json :=
  let t := Plan.trace w.toWorld p Env.nil
  Json.mkObj
    [ ("world", toJson w)
    , ("trace", Json.arr (t.map eventJson).toArray)
    , ("billFresh", toJson (Multiplicative.toAdd (billFresh tick t)))
    , ("billMemo", toJson (Multiplicative.toAdd (billMemo tick t))) ]
```

```haskell
-- | One entry of the checked reply's @"worlds"@ array. Argument order is
-- Lean's: the plan, then the spec.
worldObservation :: Plan '[] () -> WorldSpec -> Value
```

The enclosing record — `level`, `size`, `askNodes`, `codes`, `costSummary`,
`blockAsks`, `fnAsks`, `worlds` (`Conformance.lean:240` `observe`) — is
**tier1's** to assemble, from `Agentic.Plan`'s folds, `Agentic.Guards`'
`askCounts`, and this function. It is not built here, so that `Agentic.World`
depends on neither `Agentic.Guards` nor `Agentic.Raw`'s program type.

---

## 4 What neither module contains

* No `Dlg`, no `Ω` as a table, no `pin`, no `worldOf`, no memo table.
* No `Sig`, `compSig`, `atModel` as a relabelling, or `Plan.under` (§2.3).
* No `shapes`, `asks`, `PricesByShape`, `Price` polymorphism, `billOfKeys`,
  `CostTree.map`, `leafBills`, `Env.probe`, `costLines` or any renderer. The
  oracle serializes none of them.
* No `Pos` anywhere. `Q` has no position; positions are oracle-only, like
  `message` and `excerpt`.
* No `Monad`/`Applicative`/`Functor` instance for `Plan`. `Plan` is a syntax
  (`Agentic/Core/Plan.lean` module docstring); `mapP`/`zipWithP` are the
  functorial and applicative actions and are deliberately *not* instances,
  because `bindP` would then look free when it costs the `PDyn` quarantine.

---

## 5 Acceptance for these two modules

`Agentic.Plan` and `Agentic.World` are done when, for every one of the 59
checked corpus entries, a plan built by `Agentic.Builder` and folded by these
modules reproduces the reply's `level`, `size`, `askNodes`, `codes`,
`costSummary`, and — per world — `trace`, `billFresh` and `billMemo`, compared
as `Data.Aeson.Value`. That comparison is tier1's harness; these modules owe it
the functions above and nothing else.

Until tier1 exists, the two modules are checkable on their own: build a plan by
hand in GHCi for `battery-085` (§2.8) and check the six numbers, and for
`battery-117` and `battery-137` (§3.4) and check the two bills.

---

## 6 Mechanical verification record

Everything numeric in this file was checked by transliterating the elaboration
rules of `Dsl/Check.lean` and the folds of `Level.lean`, `Explain.lean`,
`Cost.lean`, `Denote.lean` and `Conformance.lean` into python and running them
over the frozen corpus (scripts in this session's scratchpad; they are throwaway
oracles for the spec, not deliverables):

1. **Static folds.** `level`, `size`, `askNodes`, `codes` and
   `costSummary` recomputed from each request's `RawProgram` for all
   **59 checked entries** (22 `branch`, 21 `pipeline`, 16 `batch`): 59 exact
   matches, 0 mismatches.
2. **Traces and bills.** The trace fold plus `WorldSpec.toWorld` run over all
   **63 world blocks**: every event — code, addressee, scope, prompt, draw,
   answer — byte-equal to the corpus after JSON key sorting, and
   `billFresh = length` on every one.
3. **Memo equality.** `billMemo` recomputed as the number of distinct
   `(code, addressee, scope, prompt, draw)` tuples: 63 of 63 exact.
4. **World specs.** The reply's `"world"` is the request's world spec verbatim
   in all 63 blocks; only four distinct specs occur, and the `byPrefix`,
   `promptEq` and `declined` constructors are unexercised.

### Where the mechanical check disagreed with a first reading

* **`vector-001-billmemo-below-billfresh` does not have `billMemo` below
  `billFresh`.** The name says it does; the entry reports `billFresh 3,
  billMemo 3`. Its three questions go to three different tools
  (`cat`, `log`, `audit`), so no two keys collide, and one binding read three
  times is still one question — which is the *sharing* property, not the memo
  property. The entries that actually separate the two bills are
  `battery-117-two-draws-of-one-prompt-are-two-questions` (4 vs 3) and
  `battery-137-empty-prompts-and-an-empty-define` (3 vs 2). Anyone writing a
  memo test against the file whose name promises one will write a test that
  passes with `billMemo = billFresh`.
* **`List.dedup` keeps the last occurrence, not the first.** The obvious
  Haskell reading (`nub`) keeps the first. Card is equal so `billMemo` at `tick`
  is unaffected, but the deduplicated *list* differs, and a future
  non-commutative price carrier would diverge. Recorded in §3.4.
* **`level` at `askC` is `level k`, not `max Batch (level k)`** — the first
  reading of "each clause is the rung its former forces, joined with what the
  subterms force" suggests a join at every node. `Level.lean:122` has no join at
  `askC`. It happens to be equivalent (`Batch` is `⊥`), but writing the join
  invites writing `max Pipeline` there too, which would make every closed-
  question program `pipeline`. Sixteen corpus entries are `batch`
  (e.g. `battery-137`, `battery-118`) and would all have broken.
* **`size` counts a `case` node; `askNodes` does not.** `Explain.lean`'s two
  folds differ by that `1 +`, and `battery-085`'s `size 11` versus
  `askNodes 4` only comes out with the asymmetry.
* **`act` is a binding, not a bare effect.** `Check.lean:559` elaborates it
  through `bindForm … Code.ack` and then weakens the continuation
  (`form (Plan.sub k Sub.wk)`). It therefore pushes an `El 'CodeAck` onto the
  context, which shifts every de Bruijn index after it. Reading it as "an ask
  whose answer is discarded, with no binder" reproduces `size` and `askNodes`
  but produces the wrong environment, and `battery-115-names-straddling-an-act`
  is the entry that catches it.
* **The prompt decides `askC` versus `ask`, and therefore the level.** A prompt
  with no `interp` chunk elaborates to `Plan.askC` (`Check.lean:566`
  `Prompt.closed`), so `battery-137` is `batch` even though its source contains
  `define` holes — a `define` is resolved by the parser, not by the checker.
  A reading in which every ask is a `Plan.ask` gives `pipeline` everywhere and
  fails on all sixteen `batch` entries.
* **`costTree` needs no environment at `tick`.** Lean threads `Env` and
  `default` answers through the fold; at the counting price the question is
  never read, so the Haskell fold takes no environment. This was verified rather
  than assumed — the environment-free fold reproduces all 59 `costSummary`
  triples.
* **`paths` counts leaves with repetition.** `battery-042` reports
  `paths 2, minFold 3, maxFold 3`: two paths at the same price, not one path
  and not two distinct bills. `Multiset.card`, not `Finset.card`.

---

## ADDENDUM (coordinator, mid-implementation — binding)

§2.6's `revising` signature cannot be implemented as written: every occurrence
of `c` sits under `El`, which is non-injective, so the definition fails the
ambiguity check and its own recursive call. Builder.hs is already written and
calls it as `revising @(Codes s) @c ...`. Binding resolution, in order of
preference:

1. `{-# LANGUAGE AllowAmbiguousTypes #-}` + explicit `forall g c.` on the
   signature (quantifier order g THEN c) + `revising @g @c` at the recursive
   call — zero changes elsewhere; or
2. a `KnownCode c`/`SCode c` CONSTRAINT with the same forall order — also zero
   changes elsewhere; or
3. an explicit `SCode c` value argument — requires a one-line edit at
   Builder.hs's single call site in `revisingCase` (verifier: make it if you
   find this form).

Also binding, from the Builder implementer, for tier1 and the verifier:
Cases.hs imports `Agentic.Builder` alone (it re-exports `Code (..)`);
Main.hs imports Agentic.Plan and Agentic.Raw with explicit lists —
`Agentic.Builder.panel` shadows `Agentic.Plan.panel`, and `Agentic.Raw`'s
field accessor `askModel` shadows the `askModel` combinator.
