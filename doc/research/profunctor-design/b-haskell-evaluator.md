# B — The Haskell evaluator, as a profunctor

*A concrete redesign of `haskell/src/Agentic/{Plan,World,Exec,Builder}.hs`. Every
type below is written to compile in spirit: the extensions are named, the classes
are closed, and each clause has been checked against the fold it replaces. No code
in the repository is changed by this document.*

---

## 0. The one-page answer

### 0.1 The interpreter

```haskell
-- | Everything an interpretation must say about the two question formers, and
--   nothing else. Note the input types: a closed question needs no input; an
--   open one is handed its /evaluated words/, never the environment.
data Handler p = Handler
  { onClosed :: forall (c :: Code). SCode c -> Q c        -> p ()   (El c)
  , onOpen   :: forall (c :: Code). SCode c -> Shape c    -> p Text (El c)
  }

interp
  :: forall p x y
   . (Branching p, Applying p)      -- superclasses: Monoidal, Category, Strong
  => Handler p
  -> Flow x y
  -> p x y
interp h = go
  where
    go :: forall a b. Flow a b -> p a b
    go = \case
      Ret  f       -> pureP f
      AskC c q   k -> (lmap (const ()) (onClosed h c q) |*| id) >>> go k
      Ask  c s e k -> (lmap e          (onOpen   h c s) |*| id) >>> go k
      Case t e  ks -> (pureP e                          |*| id) >>> branching t (go . ks)
      Dyn  e f     -> (pureP (go . f . e)               |*| id) >>> applying
```

Five clauses. The `|*| id` in every effectful clause is the whole of the de Bruijn
plumbing: it is what makes the continuation see the answer *and* everything that was
already in scope, and it replaces `Env`, `Var`, `Sub`, `subLift`, `subWk`, `subCons`,
`Cont` and `graft`.

### 0.2 The instantiation table

| evaluator today | file | target `p` | `Handler p` is | structure used |
|---|---|---|---|---|
| `runIn` / `runPlan` | `World.hs:365` | `Star Identity` ≅ `(->)` | **`World` verbatim** | all four classes |
| `traceIn` / `trace` | `World.hs:345` | `Star (Writer Trace)` | `World` + one `Event` | all four |
| `execIn` / `runPlanIO` | `Exec.hs:265` | `Star (StateT Memo IO)` | `askOrMemo` — memo table and `questionKey` unchanged | all four |
| `level` | `Plan.hs:738` | `Tally Level` at `(max, Batch)` | `Tally Batch` / `Tally Pipeline` | all four |
| `askNodes` | `Plan.hs:767` | `Tally (Sum Integer)` | `Tally 1` | all four |
| `costTree` | `Plan.hs:822` | `Tally CostTree` at the graft monoid | `Tally (CostLeaf 1)` | `Branching`, **not** `Applying` |
| `codes` | `Plan.hs:784` | `Partial (Tally [Code])` | `Tally [c]` | `Monoidal`+`Category`+`Strong` only |
| `shapes` (Lean-only) | `Cost.lean:321` | `Partial (Tally [Shape])` | `Tally [⟨c,s⟩]` | same |
| `asks` (Lean-only) | `Cost.lean:336` | — | — | **not a fold at all**: it is `trace` at `ωDefault` (§1.6) |
| `size` | `Plan.hs:752` | — | — | **not an interpretation**; stays a hand-written syntax fold (§1.5) |
| `billFresh`/`billMemo` | `World.hs:427` | — | — | unchanged: monoid morphisms out of `Trace` |

### 0.3 The single biggest simplification

**The order in which a run evaluates a prompt, records an event and binds an answer
stops being a comment and becomes a type.** `Exec.hs:255` today reads:

> *The prompt is evaluated before the answer is bound, so a splice reads what was
> already answered and never what this question will answer. Getting that backwards
> is the one way this fold can differ from `traceIn` while still typechecking.*

There are four independent copies of that ordering — `runIn`, `traceIn`, `execIn`
and the Lean `denote` they are all supposed to agree with — and nothing but that
comment holds them together. In the profunctor form there is one `Ask` clause,
`lmap e (onOpen h c s)`: the prompt function `e` is applied to the *input* of the
node, and the input of the node is a type that does not contain the answer. The
hazard is not merely detected, it is **unstateable**. Everything else — the ~160
lines of five-clause dispatch collapsing to ~70 (§1.7) — follows from that and is
worth less.

### 0.4 The single biggest cost

**The algebra is a discipline, not a type, and it must stay that way because the
frozen corpus pins `size`.**

`size` counts syntax nodes, so it is not invariant under the `Category` laws
(`f >>> id` has strictly larger `size` than `f`). Therefore `Flow`'s `Category`,
`Strong` and `Monoidal` instances must be **skeleton-preserving smart constructors**
— `(>>>)` *is* today's `graft`, `lmap` *is* today's `subP` — and can never be
constructors of the GADT. Nothing in Haskell's type system enforces that. A future
contributor who adds a `Comp :: Flow x z -> Flow z y -> Flow x y` former for
convenience gets a lawful profunctor, a green typechecker, and a silently different
`size`, `askNodes` and `costSummary` on every corpus entry. The profunctor structure
buys uniformity at the price of a new, unenforced invariant that only the
conformance suite can catch — and only if it is run.

---

## 1. The profunctor core

### 1.1 The re-indexing, which is the whole move

`Plan Γ A` denotes `Env Γ → Dlg A` (`Plan.lean:221`). It is already a *hom*: an
arrow from what is known to what is answered. The de Bruijn context is nothing but
a normal form for the domain. Unfold it:

```haskell
Env '[]        ≅ ()
Env (c ': g)   ≅ (El c, Env g)
```

and `Plan g a` becomes `Flow (Env g) a`. The five formers survive **unchanged in
arity, order and field content**:

```haskell
{-# LANGUAGE DataKinds, GADTs, RankNTypes, ScopedTypeVariables, LambdaCase,
             TypeFamilies, KindSignatures, ConstraintKinds, FlexibleInstances #-}

data Flow x y where
  Ret  :: (x -> y)                                              -> Flow x y
  AskC :: SCode c -> Q c        -> Flow (El c, x) y             -> Flow x y
  Ask  :: SCode c -> Shape c -> (x -> Text) -> Flow (El c, x) y -> Flow x y
  Case :: Tag t -> (x -> t) -> (t -> Flow x y)                  -> Flow x y
  Dyn  :: (x -> b) -> (b -> Flow x y)                           -> Flow x y
```

Compare `Plan.hs:502`. The diff is one substitution — `Plan (c ': g) a` for
`Flow (El c, x) y` — applied three times. `Ctx`, `Env`, `Var`, `varGet`, `Expr`,
`Sub` and its five combinators do not appear.

The dictionary, each entry checked against the definition it replaces:

| today (`Plan.hs`) | after | note |
|---|---|---|
| `Expr g a = Env g -> a` | `x -> a` | a bare function; `exprConst = const`, `exprVar` = a projection |
| `Sub g d = Env d -> Env g` | `d -> x` | a bare function |
| `subId`, `subComp` | `id`, `flip (.)` | |
| `subWk :: Sub g (c ': g)` | `snd` | |
| `subLift s = \d -> ECons (envHead d) (s (envTail d))` | `second s` | **this is `Strong`'s `second'` at `(->)`** |
| `subCons e s = \d -> ECons (e d) (s d)` | `e &&& s` | the cartesian fanout |
| `subP p s` (`:512`, 7 lines, 5 clauses) | `lmap s p` | `Profunctor` |
| `weakenP p` (`:525`) | `lmap snd p` | |
| `Cont g a b` (`:540`, rank-2 newtype) | `Flow (a, x) b` | rank-2 quantification **deleted** |
| `graft p k` (`:550`, 7 lines, 5 clauses) | `p >>> k` | `Category` |
| `mapP f p` (`:560`) | `rmap f p` | `Profunctor` |
| `zipWithP f p q` (`:567`, 9 lines) | `rmap (uncurry f) (p \|*\| q)` | `Monoidal` |
| `seqP p q` (`:583`) | `p >>> lmap snd q` | |
| `bindP p k` (`:595`) | `p >>> Dyn fst (k' . …)` | still the only `Dyn` |
| `Var g c` / `varGet` (`:399`, `:404`) | `first'` / `second' . _` (§3.2) | de Bruijn indices are lens paths |

Two of these deserve a sentence each, because they are the ones that carry the
weight.

**`subP` is `lmap`, and Lean's `sub_id`/`sub_comp` are the `Profunctor` laws.**
`Plan.lean:319` and `:328` are two structural inductions proving
`sub p Sub.id = p` and `sub (sub p σ) τ = sub p (comp σ τ)`. Those are precisely
`dimap id id = id` and `dimap (f . g) id = dimap g id . dimap f id`. They stop
being theorems about a bespoke operation and become the instance obligations of a
named class, which is worth exactly as much as one is willing to trust that the
class is right — but the statement of the presheaf property in `Plan.lean:302`
("`Plan` is a presheaf on contexts") is *literally* "`Flow` is a profunctor,
contravariantly", and it should be written in the vocabulary that says so.

**`graft` is `>>>`, and the rank-2 `Cont` disappears.** `Plan.lean:410` motivates
`Cont` this way: the leaves of a plan do not all sit in `Γ`, so a continuation must
be polymorphic in the leaf's context and take a `Sub Γ Δ` to reach back. In the
profunctor form the reaching-back is not needed, because **the environment rides in
the input type of every node**: `AskC c q k` gives `k` the type
`Flow (El c, x) y`, which mentions the outer `x` explicitly. A continuation for a
`Flow x a` is therefore just a `Flow (a, x) b` — first-order, rank-1, and composed
with `>>>` after the value has been paired with the environment.

The `Sub` chains this deletes are not decorative. `Plan.hs`'s `graft` carries
`subComp subWk s` through both ask clauses; that expression is exactly
`lmap snd` on the reaching substitution, and it is the entire reason `Cont`'s
lambda has three arguments. `revising` (`Plan.hs:652`, 45 lines) is dominated by
`subComp (subComp s t) r` chains; §1.8 rewrites it in twelve.

### 1.2 The classes

Four, and the boundaries between them are the rungs — with one honest exception,
recorded in §2.1.

```haskell
-- | A shared-input monoidal product. This is the /applicative/ structure: it
--   combines two computations over the same input without letting either see
--   the other's output. Free-applicative shaped (Capriotti & Kaposi 2014).
class Profunctor p => Monoidal p where
  pureP :: (x -> y) -> p x y
  (|*|) :: p x a -> p x b -> p x (a, b)

-- | Arrow, spelled as the profunctor triple: a monoid in Prof under profunctor
--   composition (Rivas & Jaskelioff 2017 §6; Jacobs, Heunen & Hasuo 2009).
--   @pureP@ is @arr@, and @(|*|)@ becomes derivable here — see the default.
type Flowing p = (Monoidal p, Category p, Strong p)

-- | The finite-tag branch, n-ary at a 'Tag', with the tag consumed. NOT
--   'Choice' — see below, this is the one place the standard hierarchy does not
--   fit and the difference is load-bearing.
class (Monoidal p, Category p, Strong p) => Branching p where
  branching :: Tag t -> (t -> p x y) -> p (t, x) y

-- | The dynamic rung: @ArrowApply@, which is a monad
--   (Hughes 2000; Lindley, Wadler & Yallop 2011).
class (Monoidal p, Category p, Strong p) => Applying p where
  applying :: p (p x y, x) y
```

**Why `Branching` is not `Choice`, and why that matters.** For the two-element tag,
`(Bool, x) ≅ Either x x` by distributivity, so one would expect
`branching TBool f = arr distrib >>> (f True ||| f False)` and `Choice` to suffice.
It does at the runtime targets. It fails at the analysis targets, for a reason that
is structural rather than incidental: `(|||)` is *derived* from `left'`, `right'`
and `(>>>)`,

```haskell
f ||| g = rmap (either id id) (left' f >>> right' g)
```

so at any `Tally s` (where `p x y = s`, `left' = right' = coerce` and `(>>>) = (<>)`)
it is forced to be `s_yes <> s_no` — the *sequential* composition of the two arms.
For `askNodes` that is accidentally right (`<>` is `+`, both arms counted, which is
what `Plan.hs:772` does). For `costTree` it is wrong: a branch must produce
`CostNode [t_yes, t_no]`, whose leaf bag is the *union*, and `<>` at the graft monoid
is leaf *substitution*. No lawful `Choice (Tally CostTree)` yields `CostNode`.

The correct categorical reading: `Choice`'s codiagonal `either id id` says *"both
branches produce the same `y`, so merge them"*. An analysis needs *"both branches
are possible, so keep them apart"*, and that is not a map into a single `y`. It is a
genuinely extra n-ary operation on the target, which is why Lean's `costTree`
returns a `CostTree` rather than folding into a monoid, and why
`Selective.branch` (Mokhov et al. 2019) — which `Plan.lean:263` already names — is a
separate structure from `Applicative` and from `Monad` rather than derivable from
either.

So `Branching` is primitive. Runtime targets get it for free:

```haskell
choiceBranch :: (Choice p, Flowing p) => Tag t -> (t -> p x y) -> p (t, x) y
choiceBranch TBool  f = lmap (\(b, x) -> if b then Left x else Right x)
                              (f True ||| f False)
choiceBranch TVTag  f = lmap distribute3 (f VApprove ||| (f VObject ||| f VDeclined))
  where distribute3 (t, x) = case t of
          VApprove  -> Left x
          VObject   -> Right (Left x)
          VDeclined -> Right (Right x)
```

`Tag` is closed at two constructors (`Plan.hs:468` documents why: the elaboration
produces exactly `Bool` and `VTag`), so this is two lines and not a `FinEnum`
metaprogram. If the tag set ever opens, the generic form is the composite of the
`t ≅ Fin n` enumeration with `n-1` nested `(|||)`s — the same construction, written
once.

### 1.3 The handler, and where `PricesByShape` went

```haskell
data Handler p = Handler
  { onClosed :: forall (c :: Code). SCode c -> Q c     -> p ()   (El c)
  , onOpen   :: forall (c :: Code). SCode c -> Shape c -> p Text (El c)
  }
```

Two fields, one per ask former, and the split is exactly `Cost.lean`'s "correction
1": `Q c ≅ Q.Shape c × String`, the shape is term-level data and only the prompt is
an expression. Read it off the types:

- `onClosed` receives the **whole question**, because a closed question's words are
  in the term. A `Tally`-valued handler may therefore price by content. That is
  `bill_exact_batch` (`Cost.lean:425`) and its striking hypothesis-freedom: *"with
  no hypothesis on the price at all. Content-dependent pricing is fine here: the
  content is in the term."*
- `onOpen` receives the **shape statically and the words as the profunctor's
  input**. A `Tally s` has `p Text (El c) = s`: the `Text` is unreachable. So a
  `Tally`-valued handler can only price by shape.

**`PricesByShape` (`Cost.lean:142`) is precisely the statement that `onOpen`
factors through `Tally`.** It stops being a side hypothesis carried through six
theorems and becomes the type of the one field an analysis has to fill in. That is
the tightest single payoff in this document for the Lean side, and it is visible in
Haskell as: `codes`, `shapes` and `costTree` can all supply `onOpen`, and none of
them can look at the prompt, because their target's hom does not have the prompt in
it.

The one existing type that is already a handler:

```haskell
-- World.hs:274, verbatim
newtype World = World { worldAnswer :: forall (c :: Code). SCode c -> Q c -> El c }

worldHandler :: World -> Handler (->)
worldHandler w = Handler
  { onClosed = \c q -> \() -> worldAnswer w c q
  , onOpen   = \c s -> \t  -> worldAnswer w c (withPrompt s t)
  }
```

`Handler (->)`'s two fields are `World`'s one field, split by whether the prompt is
already known. Nothing is invented.

### 1.4 The nine instantiations

**`runPlan` — `Star Identity`, i.e. `(->)`.**

```haskell
runPlan :: World -> Flow () a -> a
runPlan w p = interp (worldHandler w) p ()
```

Deletes `runIn` (`World.hs:365`, 10 lines).

**`trace` — `Star (Writer Trace)`.**

```haskell
type Traced = Star (Writer Trace)

tracedHandler :: World -> Handler Traced
tracedHandler w = Handler
  { onClosed = \c q -> Star $ \()  -> let a = worldAnswer w c q in
                                      writer (a, [Event c q a])
  , onOpen   = \c s -> Star $ \txt -> let q = withPrompt s txt
                                          a = worldAnswer w c q
                                      in writer (a, [Event c q a])
  }

trace :: World -> Flow () a -> Trace
trace w p = execWriter (runStar (interp (tracedHandler w) p) ())
```

Deletes `traceIn` (`World.hs:345`, 10 lines) **and** makes `runPlan` derivable
(`fst . runWriter`), though it is cheaper to keep the `(->)` instantiation than to
build a trace and throw it away. Two folds that differ only in whether they cons an
event become one fold at two targets — and the sentence in `World.hs`'s header,
*"Three things this fold has to get right, all of which the corpus catches"*, has
one place to be got right instead of two.

Note the ordering, since it is the point of §0.3: `(lmap e (onOpen h c s) |*| id)`
applies `e` to the node's input; the answer is not in that input; the `Writer`'s
`<>` is left-to-right, so the event precedes the continuation's events. The
transcript order is `>>>`'s associativity, not a convention.

**`runPlanIO` — `Star (StateT Memo IO)`, and the memo survives untouched.**

This is the instantiation worth showing in full, because §1's brief asks for the
memo table and the `billMemo` key to survive the refactor. They do not merely
survive: **they become the only thing this target adds, and they never touch the
interpreter.**

```haskell
type Running = Star (StateT Memo IO)

-- Memo, memoLookup, questionKey, sameCode: unchanged from Exec.hs:217-:327.
--   data Memo = Memo { memoTable :: !(Map EventKey Event), memoSaid :: [Event] }
--   questionKey c q = eventKey (Event c q (defaultEl c))   -- Exec.hs:301

runningHandler :: WorldIO -> Handler Running
runningHandler w = Handler
  { onClosed = \c q -> Star $ \()  -> askOrMemoS w c q
  , onOpen   = \c s -> Star $ \txt -> askOrMemoS w c (withPrompt s txt)
  }

-- Exec.hs:283's askOrMemo, restated in StateT. Look up before asking; record
-- after answering; one Event per node walked, hit or not.
askOrMemoS :: WorldIO -> SCode c -> Q c -> StateT Memo IO (El c)
askOrMemoS w c q = do
  m <- get
  let key = questionKey c q
  a <- case memoLookup c key (memoTable m) of
         Just a  -> pure a
         Nothing -> do a <- liftIO (worldAskIO w c q)
                       modify $ \m' -> m' { memoTable = Map.insert key (Event c q a)
                                                                      (memoTable m') }
                       pure a
  modify $ \m' -> m' { memoSaid = Event c q a : memoSaid m' }
  pure a

runPlanIO :: WorldIO -> Flow () a -> IO (a, Trace)
runPlanIO w p = do
  (a, m) <- runStateT (runStar (interp (runningHandler w) p) ()) (Memo Map.empty [])
  pure (a, reverse (memoSaid m))
```

`execIn` (`Exec.hs:265`, 11 lines) is deleted. `askOrMemo` is not: it moves from
being a helper *of the fold* to being the *whole content of the handler*, which is
the correct location and is what `Exec.hs:44` already argues for in prose — *"the
table is Lean's `Table` … the trace is `Plan.trace` … reading them off the memo
table would make `billFresh` and `billMemo` the same number by construction"*. In
the profunctor form that separation is not a discipline: `memoSaid` is appended once
per handler invocation (one `Event` per node, hit or miss), the table is consulted
inside, and no other code in the module can see either.

The invariant `Exec.hs:49` asks a test to pin —

```
billFresh t == the number of ask nodes the run walked
billMemo  t == the number of times the WorldIO was actually invoked
```

— becomes, after the refactor, a statement relating two *different instantiations*
of one `interp`: `billFresh` is `askNodes` at `Tally (Sum Integer)`, and `billMemo`
counts the `Nothing` branches of `memoLookup`. It is still a test and not a theorem,
but the two sides are now folds of the same term by the same recursion.

**`level` — `Tally Level` at the join semilattice.**

```haskell
newtype Tally s x y = Tally { unTally :: s }

instance Profunctor (Tally s)                where dimap _ _ (Tally s) = Tally s
instance Strong     (Tally s)                where first' (Tally s) = Tally s
                                                   second'(Tally s) = Tally s
instance Monoid s => Category (Tally s)      where id = Tally mempty
                                                   Tally g . Tally f = Tally (f <> g)
instance Monoid s => Monoidal (Tally s)      where pureP _ = Tally mempty
                                                   Tally a |*| Tally b = Tally (a <> b)
```

Note the `Category` direction: `(>>>)` is `<>` left-to-right, so `Tally [Code]`
records codes in ask order. (`Data.Functor.Const` would compose the other way; that
is why this is a local newtype and not `Const`.)

```haskell
instance Branching (Tally Level) where
  branching t f = Tally (foldr (max . unTally . f) Branch (tagValues t))
instance Applying (Tally Level) where
  applying = Tally Dynamic

levelHandler :: Handler (Tally Level)
levelHandler = Handler { onClosed = \_ _ -> Tally Batch
                       , onOpen   = \_ _ -> Tally Pipeline }

level :: Flow x y -> Level
level = unTally . interp levelHandler          -- at Monoid = (max, Batch)
```

Check it against `Plan.hs:738` clause by clause, because this is the fold the oracle
reply serializes and it must not move:

| former | `interp` produces | `Plan.hs:738` says |
|---|---|---|
| `Ret` | `pureP f = Batch` | `Batch` ✓ |
| `AskC c q k` | `(Batch \|*\| Batch) >>> level k` = `Batch ⊔ level k` | `level k` ✓ (`Batch` is `⊥`) |
| `Ask c s e k` | `Pipeline ⊔ level k` | `max Pipeline (level k)` ✓ |
| `Case t e ks` | `Batch ⊔ (Branch ⊔ ⨆ arms)` | `foldr (max . level . arms) Branch` ✓ |
| `Dyn e f` | `Batch ⊔ Dynamic` = `Dynamic`, body discarded by `pureP` | `Dynamic`, `f` ignored ✓ |

Exact, including the two subtleties `Plan.hs`'s docstring flags: `AskC` adds nothing
(sixteen corpus entries are `batch`), and `Dyn` ignores its body.

**`askNodes` — `Tally (Sum Integer)`; `size` — not an interpretation.**

```haskell
instance Branching (Tally (Sum Integer)) where
  branching t f = Tally (foldMap (unTally . f) (tagValues t))
instance Applying (Tally (Sum Integer)) where
  applying = Tally 0

askNodes :: Flow x y -> Integer
askNodes = getSum . unTally . interp (Handler (\_ _ -> Tally 1) (\_ _ -> Tally 1))
```

`Ret` → `0`; `AskC`/`Ask` → `1 + k`; `Case` → `Σ arms` with no self-count; `Dyn` →
`0`. Every clause of `Plan.hs:767`, ✓.

`size` does **not** come out, and the reason is worth recording because it explains
a "not a typo" note in the existing docstring. `Plan.hs:749` says:

> *A `case` **counts itself** (the `1 +`); compare `askNodes`, which does not. The
> asymmetry is not a typo — `battery-085`'s `size 11` against `askNodes 4` only
> comes out with it.*

The profunctor reading names the asymmetry: **`askNodes` is invariant under the
`Category` laws and `size` is not.** `arr f` contributes `0` asks, so
`askNodes (f >>> arr id) = askNodes f`; but `size (f >>> arr id) > size f`, so `size`
distinguishes terms that any lawful `p` identifies. A fold that separates
law-equal terms cannot be an interpretation into a lawful target. `size` is a fold
of the *signature*, not of the *theory*, and it stays a hand-written five-clause
recursion — one of nine.

That is not a defect of the refactor; it is the refactor telling the truth about
which of the reply's fields are semantic. `size` is the one observation in
`observeValue` (`Observe.hs:87`) that is a fact about the term rather than about the
conversation, and it is exactly the one that resists.

**`costTree` — `Tally CostTree` at the graft monoid.**

```haskell
instance Semigroup CostTree where
  CostLeaf n  <> u = bumpBy n u                 -- substitute u at the leaf, adding
  CostNode ts <> u = CostNode (map (<> u) ts)
instance Monoid CostTree where mempty = CostLeaf 0

bumpBy :: Integer -> CostTree -> CostTree
bumpBy n (CostLeaf m)  = CostLeaf (n + m)
bumpBy n (CostNode ts) = CostNode (map (bumpBy n) ts)

instance Branching (Tally CostTree) where
  branching t f = Tally (CostNode (map (unTally . f) (tagValues t)))
instance Applying (Tally CostTree) where
  applying = Tally (CostNode [])                -- an arm-less node admits no bill

costTree :: Flow x y -> CostTree
costTree = unTally . interp (Handler (\_ _ -> Tally (CostLeaf 1))
                                     (\_ _ -> Tally (CostLeaf 1)))
```

Two things to notice.

`bump` (`Plan.hs:831`) disappears: it is `CostLeaf 1 <> ·`. The monoid is
substitution-into-leaves-with-addition, which is the *same operation* `graft` is on
terms. So the cost tree is the image of the term under the unique monoid
homomorphism that sends every question to one tick — which is what
`Cost.lean:668`'s `costTree` is, said in one sentence instead of a five-clause fold
with an `absurd` in it.

`Applying (Tally CostTree) = CostNode []` is `Plan.hs:828`'s deliberate choice
(*"that is the position where Lean has `absurd`… an arm-less node admits no bill,
which is exactly what Lean's `WithTop`/`WithBot` folds report"*). It is now an
*instance*, so the claim "`costTree` is not defined at `dynamic`" can be made
sharper: **delete the `Applying (Tally CostTree)` instance and a dynamic program
fails to typecheck at that target.** That is `no_cost_tree_at_dyn`
(`Cost.lean:926`) as a type error rather than a theorem — see §2.4.

**`codes` and `shapes` — `Partial`, and the three `Option` folds become one.**

Lean writes three `Option`-valued folds (`codes`, `shapes`, `asks`) and three
totality theorems (`codes_isSome_of_le_pipeline`, `shapes_isSome_…`,
`asks_isSome_…`, `Cost.lean:358–:386`), each a five-case induction with two `absurd`
branches. Haskell writes `codes` with an inline `Maybe` (`Plan.hs:784`). All of that
is one target:

```haskell
newtype Partial p x y = Partial { unPartial :: Maybe (p x y) }

instance Profunctor p => Profunctor (Partial p) where
  dimap f g (Partial m) = Partial (dimap f g <$> m)
instance Strong p => Strong (Partial p) where
  first' (Partial m) = Partial (first' <$> m)
  second'(Partial m) = Partial (second' <$> m)
instance Category p => Category (Partial p) where
  id = Partial (Just id)
  Partial g . Partial f = Partial (liftA2 (.) g f)
instance Monoidal p => Monoidal (Partial p) where
  pureP f = Partial (Just (pureP f))
  Partial a |*| Partial b = Partial (liftA2 (|*|) a b)

-- The rung boundary, as an instance that gives up.
instance Flowing p => Branching (Partial p) where branching _ _ = Partial Nothing
instance Flowing p => Applying  (Partial p) where applying      = Partial Nothing

codes :: Flow x y -> Maybe [Code]
codes = fmap unTally . unPartial
      . interp (Handler (\c _ -> Partial (Just (Tally [fromSCode c])))
                        (\c _ -> Partial (Just (Tally [fromSCode c]))))
```

`Partial p` is `Flowing` whenever `p` is, and is `Branching`/`Applying`
unconditionally by refusing. **One target expresses "this analysis is defined below
`branch`", once, instead of three `Option` plumbings and three totality
inductions.** `shapes` is the same three lines at `Tally [Shape]`; it is currently
Lean-only and would cost nothing to add.

`Partial (Tally (Sum Integer))` would give the pipeline-restricted ask count, and
so on: any analysis can be restricted to a rung by wrapping its target. The rung is
a property of the target, which is §2's thesis in miniature.

### 1.5 What is not an interpretation, stated honestly

Three things resist, and each resistance is informative rather than embarrassing.

1. **`size`** — not law-invariant (§1.4). Stays a fold. 7 lines.
2. **`billFresh` / `billMemo`** — folds of `Trace`, not of `Flow`. They should stay
   folds of `Trace`: `Cost.lean:166`'s whole argument is that the bill is a monoid
   morphism *out of the transcript*, so that a memoizing policy is a property of the
   runtime and not of the carrier. Making the bill an interpretation of the term
   would put the policy back in the denotation, which is the mistake
   `billMemo_not_monoid_hom` (`Cost.lean:276`) exists to prevent.
3. **`asks` (Lean-only)** — `Cost.lean:336` folds the term under `default` answers
   and returns `Option (List Key)`. But `asks_eq_default` (`Cost.lean:574`) proves
   `asks p γ = some ((trace ωDefault p γ).map Event.key)` at `pipeline`. In the
   profunctor form that theorem is *the definition*: `asks` is `trace` at the
   default world, projected through `Event.key`. The fold and its induction both
   disappear.

### 1.6 `Forget`, and a correction to the seed

The brief's seed observation says the analyses live at `Const`/`Forget` and that
`Forget` is *"monoidal but not compositional, hence cost dies at dyn"*. Half of that
is right and the halves belong to different rungs. Precisely:

- `Forget r x y = x -> r` is `Monoidal` when `r` is a monoid
  (`pureP _ = Forget (const mempty)`, `Forget k |*| Forget k' = Forget (k <> k')`)
  and is `Strong`. **It is not a `Category`**: composing `Forget r b c` after
  `Forget r a b` would need a `b` from an `a`, and there is none.
- `Tally s` **is** a `Category` when `s` is a monoid, and is exactly where every
  input-blind analysis in this repository lives.

So `Forget`'s non-compositionality separates **batch from pipeline**, not branch
from dynamic. What dies at `dyn` is something else: `Tally s` has an `Applying`
instance only if the target can say something about a plan it cannot see, and for
`CostTree` the only honest answer is `CostNode []` — which is the *non-existence*
result `no_finite_bill_set_at_dyn` (`Cost.lean:908`), not a failure of monoidality.

And the deeper point, which is a genuine refutation of the tidy version of the
story: **`Forget` is not reachable by `interp` at all**, because `interp` uses
`(>>>)` in every effectful clause and `Forget` has none. An interpretation of a
batch flow that avoids `(>>>)` exists, but only after renormalizing
`AskC q₁ (AskC q₂ (Ret f))` into free-applicative form `(q₁ |*| q₂) ⋅ f` — and
renormalizing changes the skeleton, hence `size`, hence the corpus (§4). On the
A-normal representation the language actually has, **batch is not a class boundary.**
See §2.1.

That is a real limit and it should not be smoothed over: the elegant statement
"the rung is the algebraic structure of the target" is true at three of the four
boundaries and false at the first one, for a representational reason that the
conformance regime makes expensive to remove.

### 1.7 What the refactor deletes, counted

Line counts are of `haskell/src/Agentic/` as it stands.

| deleted | where | lines |
|---|---|---|
| `runIn` | `World.hs:365` | 10 |
| `traceIn` | `World.hs:345` | 10 |
| `execIn` | `Exec.hs:265` | 11 |
| `level`, `askNodes`, `codes`, `costTree` bodies | `Plan.hs:738–:832` | 32 |
| `Env` GADT, `envHead`, `envTail`, `Var`, `varGet` | `Plan.hs:385–:406` | 14 |
| `Sub`, `subId`, `subComp`, `subWk`, `subLift`, `subCons` | `Plan.hs:424–:447` | 12 |
| `subP`, `weakenP`, `Cont`, `graft` | `Plan.hs:512–:556` | 21 |
| `mapP`, `zipWithP`, `pairP`, `seqP`, `bindP` bodies | `Plan.hs:560–:596` | 16 |
| `revising`'s `subComp` scaffolding | `Plan.hs:652–:696` | ~33 of 45 |
| `bump` | `Plan.hs:830` | 3 |
| **total removed** | | **≈ 162** |
| `interp` | new | 10 |
| four classes + `Tally`/`Partial`/`choiceBranch` | new | ~40 |
| nine handler/instance blocks | new | ~35 |
| `size` (kept as a fold) | `Plan.hs:752` | 7 |
| **total added** | | **≈ 92** |

Net −70 lines, which is not the point. The point is the shape: **adding an
evaluator costs one instance block instead of five clauses, and adding a former
costs three class methods instead of `5 × 9` clauses.** The current file has nine
five-clause folds over a five-constructor GADT and they are held in agreement by
review.

### 1.8 `revising`, rewritten

The current definition (`Plan.hs:652`) is 45 lines, of which the `Cont` wrappers,
`runCont` unwrappers and `subComp` chains are ~33. In the profunctor form, with
`type K x a b = Flow (a, x) b` for "a continuation that sees a value and the
environment":

```haskell
revising
  :: forall c x
   . K x (El c) Verdict                     -- review:  candidate, environment
  -> K x (El c, Verdict) (El c)             -- amend:   candidate+verdict, environment
  -> Integer
  -> K x (El c) (Maybe (El c))
revising review amend n
  | n <= 0    = keep review >>> pureP settle
  | otherwise = keep review >>> caseF (verdictApproved . fst)
                                  (pureP (\(_, (a, _)) -> Just a))
                                  (keep (lmap reassoc amend) >>> lmap forget rest)
  where
    rest       = revising review amend (n - 1)
    keep f     = f |*| id                                     -- Flow z (w, z)
    settle  (v, (a, _))            = if verdictApproved v then Just a else Nothing
    reassoc (v, (a, x))            = ((a, v), x)
    forget  (a', (_, (a, x)))      = (a', x)

caseF :: (x -> Bool) -> Flow x y -> Flow x y -> Flow x y
caseF e t f = Case TBool e (\b -> if b then t else f)
```

Twelve lines against forty-five, with the three environment shuffles named
(`settle`, `reassoc`, `forget`) instead of spelled as `subComp (subComp s t) r`.
The check-first-revise-in-the-recursive-call discipline (`Plan.lean:621`,
`n+1` checks and at most `n` amendments) is unchanged and is visible in the
`| n <= 0` guard, exactly as before.

**And the skeleton is identical**, provided `|*|` and `>>>` are the smart
constructors of §4.2. `keep f = f |*| id` expands, at a leaf, to
`Ret (\z -> (e z, z))` and, under an ask, to `k |*| lmap snd id` — which is
character-for-character what `graft`'s `subComp subWk s` produces today.

---

## 2. Levels as constraints

### 2.1 Three of the four boundaries are class boundaries; the first is not

| boundary | what changes | where it lives |
|---|---|---|
| batch → pipeline | the handler needs `onOpen`, whose input is `Text` | **the handler**, not the classes |
| pipeline → branch | `Branching p` | a class |
| branch → dynamic | `Applying p` | a class |

The batch→pipeline boundary is a handler boundary because both fragments are
`AskC`/`Ask` chains in the same A-normal shape and both need `(>>>)` to sequence
them. What distinguishes batch is *what the analysis is allowed to see*: at `AskC`
the whole `Q c` is in the term (so a content-dependent price is fine), and at `Ask`
only the `Shape c` is (so the price must factor through the shape). Written as
two handler fields, that is the entire content of `bill_exact_batch`'s
hypothesis-freedom versus `bill_exact_pipeline`'s `PricesByShape`.

Seed observation 1 claims "batch ≅ free Applicative over the question functor". The
*fragment* is free-applicative shaped — a fixed list of independent closed questions
and a pure combine — and Capriotti & Kaposi's `Ap` is exactly that shape. But
recovering it as a `Monoidal`-only constraint requires the free-applicative normal
form, and the A-normal `Flow` is not in it. This document does not propose
renormalizing, for the reason in §4.3.

### 2.2 What type a batch-only program gets

Two answers, because there are two representations and they are for different
things.

**(a) The initial (GADT) representation — the production one.** A batch program has
type `Flow x y` like every other program. The rung is a *value*, computed by
`level`, and the analysis restriction is a *target*, via `Partial`. GHC infers
nothing about the rung, because the term carries no evidence of it.

**(b) The final (tagless) representation — the specification one.** Write the same
program as a polymorphic term (Kiselyov 2012; Gibbons & Wu 2014 for the
deep/shallow duality) and GHC infers the rung as the constraint context:

```haskell
-- batch: two closed questions and a pure combine
pairOfReadings :: (Flowing p, Puts p) => p x (Text, Text)

-- pipeline: a prompt built from an earlier answer
draftThenReview :: (Flowing p, Puts p, Opens p) => p x Verdict

-- branch: a verdict decides the shape
hardenPatch     :: (Flowing p, Puts p, Opens p, Branching p) => p x ()

-- dynamic: a plan computed from an unbounded answer
unbounded       :: (Flowing p, Puts p, Branching p, Applying p) => p x ()
```

where `Puts`/`Opens` are the handler's two fields as classes:

```haskell
class Profunctor p => Puts  p where closedP :: SCode c -> Q c     -> p ()   (El c)
class Puts p       => Opens p where openP   :: SCode c -> Shape c -> p Text (El c)
```

**How GHC infers the minimum.** With `NoMonomorphismRestriction` and no signature,
GHC collects the wanted constraints from the constructors actually used and
simplifies by superclass entailment. `Flowing` (a `ConstraintKind` synonym) expands
to `(Monoidal p, Category p, Strong p)`; `Branching` and `Applying` have those as
superclasses, so a branching program's inferred context is
`(Branching p, Puts p, Opens p)` — the *antichain of maximal classes used*, exactly
the join `level` computes. This is what the brief's seed calls "the analysis-
availability theorems become one schema", and it is real: **the level lattice is the
lattice of inferred contexts, ordered by entailment.**

The reason (b) cannot be the production representation is not subtle: a final term
is a function, and `Agentic.Builder` must carry the printed `Raw` beside the term
(`Rhs`'s two fields, `Builder.hs:519`), must compute `size` off the skeleton, and
must be storable in `Blk`/`Body`/`Fn` records. A `forall p. C p => p x y` field
would have to name its constraint set in the record's type, which reintroduces the
rung as an index and defeats the inference that made (b) attractive. The honest
architecture is (a) for the artefact and (b) for the argument — and the two are
interconvertible by the standard folding/unfolding (`interp` in one direction, the
`Flow` instance of the classes in the other), so a claim proved in (b) transports.

### 2.3 What replaces the runtime `level` fold: nothing, and both coexist

The oracle's reply carries `"level": "batch" | "pipeline" | "branch" | "dynamic"`
(`Observe.hs:90`, `Conformance.lean:240`). That is a **value in a JSON document**.
No constraint context can produce it, because constraint contexts are erased. So:

| | the runtime fold | the constraint context |
|---|---|---|
| what it is | `level :: Flow x y -> Level`, `interp` at `Tally Level` | the inferred `C p =>` of a final term |
| what it answers | *"what rung is this term at?"* — an exact join | *"what must a target support to run this term?"* — a lower bound |
| who needs it | the oracle reply; the nullability of `codes`; a caller checking `level p <= Branch` before printing a summary (`Plan.hs:820`) | the author, at compile time; the analysis-availability argument |
| when it runs | at observation time | at typecheck time |
| can it be eliminated | **no** | it is not there to be eliminated |

The two are adjoint in the informal sense that `level p` is the least rung whose
constraint set the term needs, and the constraint set is the least structure a
target must have to interpret a term at that rung. They agree; they are not
substitutes. The document's position: **keep `level`, and keep it as an
instantiation of `interp`** (§1.4), so that it is one four-line instance rather than
a ninth independent fold. That is the entire change to it.

One consequence worth flagging for the reply: `codes` must keep its outer `Maybe`
at the boundary, because the corpus pins `"codes": null` on every branch-level
entry — which is every entry with an `if`, a `case` or a `revising`
(`connection.md` §3.1). `Partial` produces exactly that `Maybe`; nothing at the
wire changes.

### 2.4 The analysis-availability theorems as instantiation-existence

Lean states four totality/availability results by induction with `absurd` branches:
`codes_isSome_of_le_pipeline`, `shapes_isSome_…`, `asks_isSome_…` (`Cost.lean:358`,
`:368`, `:379`) and the `costTree` signature's `level p ≤ Level.branch` argument
(`Cost.lean:668`). The schema that replaces them:

> **An interpretation of a term into `p` exists iff `p` carries the structure of
> every former the term uses.**

In (b) that is a typing derivation, in the strict sense that removing an instance
removes a program: delete `Applying (Tally CostTree)` and
`unbounded :: (…, Applying p) => p x ()` cannot be instantiated at
`Tally CostTree`, which is `no_cost_tree_at_dyn` (`Cost.lean:926`) as a type error.
Delete `Branching (Tally [Code])` — there is none to delete, and that is the point —
and `codes` is available exactly on the `Case`-free fragment.

What this schema does **not** give, and no amount of class hierarchy will, is the
*content* of the cost theorems: `bill_mem_leaves` (`Cost.lean:691`) says the run's
bill is among the tree's leaves, and that is a relation between two targets, not the
existence of one. The right generalization there is a **logical relation between
interpretations**: a family `R :: forall x y. p x y -> q x y -> Prop` closed under
`pureP`, `(|*|)`, `(>>>)`, `first'`, and *lax* at `branching` (the `q`-side result is
`R`-related to *one* of the `p`-side arms). One induction over `Flow` then gives the
simulation for related handlers, and `asks_eq_of_le_batch`,
`codes_eq_of_le_pipeline`, `shapes_eq_trace_of_le_pipeline` and `bill_mem_leaves`
are four instances at four relations. Four inductions become one. That is a Lean-side
prize and belongs to document A; it is recorded here because it is the reason the
Haskell refactor is worth doing on both sides rather than one.

### 2.5 A note on the free-theorem claim

The brief's seed hopes for "free theorems from a class-polymorphic interpreter,
replacing bespoke proofs". Parametricity does give something here (Wadler 1989):
a term of type `forall p. C p => p x y` is a natural family, so it commutes with any
**profunctor homomorphism** — a `forall a b. p a b -> q a b` preserving `pureP`,
`|*|`, `>>>`, `first'`, `branching` and `applying`. That is genuinely free and it
is what licenses "run in the memoizing target, observe in the tracing target, get
the same trace".

But it is not free in Haskell without a caveat, and the caveat is `Dyn`: `Applying`'s
`applying :: p (p x y, x) y` has `p` in a *negative* position, so a homomorphism
into `q` cannot transport it — you would need a map `q x y -> p x y` as well. This
is the well-known reason `ArrowApply` is not a well-behaved algebraic structure
(Lindley–Wadler–Yallop's "monads are promiscuous"), and it is the same fact as
`Cost.lean`'s `no_finite_bill_set_at_dyn`: at `dyn`, nothing transports. The class
hierarchy reproduces the theorem's shape rather than replacing its content, and the
honest claim is that the *statement* becomes schematic while the *witness*
(`unbounded`, `Cost.lean:871`) stays a hand-built counterexample.

---

## 3. The authoring layer

### 3.1 Does the core sit beneath the do-notation surface unchanged? Yes.

Checked against the imports, not asserted. `Agentic.Workflow` (639 lines, the
indexed CPS surface) imports from `Agentic.Plan` exactly this:

```haskell
import Agentic.Plan (KnownCode, SCode, sCode)          -- Workflow.hs:191
```

Three names, all about the *code* singleton, none about the term. `Agentic.Workflow.Do`
and `.Revision` import only from `Agentic.Workflow`. `Agentic.Notation` is Template
Haskell over the surface's own vocabulary and mentions no term type at all. So the
do-notation layer is already insulated from the term representation, and the answer
to §3's first question is **yes, with no signature change in `Agentic.Workflow`**.

What does change is `Agentic.Builder`, in two mechanical ways:

1. The four record types' term fields change type:
   `Rhs`'s `rhsPlan :: Plan (Codes s) (El c)` → `Flow (Envs s) (El c)`;
   `rhsForm :: forall a. Plan (c ': Codes s) a -> Plan (Codes s) a` →
   `forall a. Flow (El c, Envs s) a -> Flow (Envs s) a`; likewise `Blk`, `Body`, `Fn`.
2. Every `graft`/`subP`/`subCons`/`subLift` call becomes `(>>>)`/`lmap`/`(&&&)`/
   `second'`. `graftForm` (`Builder.hs:533`) — currently
   `graft v (Cont (\sigma e -> subP k (subCons e sigma)))` — becomes
   `\v k -> (v |*| id) >>> k`.

**One trap, and it is load-bearing.** `Workflow.hs:347` declares

```haskell
type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s)      = Blk s
  Res ('Pending c s) = Arms c s
```

with an **injectivity annotation**, and its comment says why: *"it has to be, or
unwrapping a `W` could not recover its indices and `>>=` would not typecheck at
all"*. If `Blk` is re-indexed by the environment type — `Blk (Envs s)` — injectivity
fails, because `Envs` is a non-injective closed type family, and the whole indexed
CPS block collapses. The mitigation is trivial and must be written down: **keep
`Blk`, `Rhs`, `Body` indexed by the `Scope`, and change only the type of their
term-valued fields.** `Res ('Open s) = Blk s` is then unchanged, injectivity holds,
and `Envs s` appears only inside the record.

### 3.2 Handles as lenses

A de Bruijn index is a projection out of a nested product. `Var`'s two constructors
(`Plan.hs:399`) are the two moves of a lens path:

```haskell
-- A read-only handle is enough: nothing in the language writes to a binding.
type Handle e a = forall p. Strong p => p a a -> p e e     -- Lens' e a

here  :: Handle (a, e) a
here   = first'

outer :: Handle e a -> Handle (b, e) a
outer l = second' . l

peek :: Handle e a -> e -> a
peek l = runForget (l (Forget Prelude.id))
```

`VHere` is `first'`, `VThere` is `second' .`, and `varGet` is `peek`. This is the
standard profunctor encoding of a lens (Pickering, Gibbons & Wu 2017; the
correctness of the encoding, via Yoneda and Tambara modules, is Boisseau & Gibbons
2018 over Pastro & Street 2008). The relevant fact here is not the theory but the
operational one: **a lens is a value that composes with `(.)`, whereas `Var` is a
GADT whose inhabitant is currently *recomputed by instance resolution at every
use*.**

The handle then carries its printed name beside its lens:

```haskell
data V (n :: Symbol) (c :: Code) (e :: Type) = V
  { vName :: !Text                       -- what the program prints
  , vRead :: Handle e (El c)             -- how the term reads it
  }
```

and `hole`/`argName`/`ifFlag`/`caseVerdict`/`answerB` take the handle instead of
resolving a `Symbol`:

```haskell
hole :: Spliceable c => V n c e -> Piece e
hole v = Piece (Interp (vName v)) (splice . peek (vRead v))
```

Compare `Builder.hs:366`, which needs `(KnownSymbol n, KnownVar n s, Spliceable (LookupC n s))`
and reconstructs both the text and the index from the type.

**What this deletes.** `SymEq`, `LookupC`, `KnownVar`, `KnownVar'` and its two
instances, `Codes`, `Var`, `varGet`, `nameExpr` — `Builder.hs:199–:251`, about 55
lines of type-level machinery and three classes.

**What it must keep.** `Fresh` (`Builder.hs:259`) and `KnownScope`
(`Builder.hs:271`). `Fresh` refuses a second bind of a live name; Haskell's own
binders do not refuse that (a `W.do` block would happily shadow, and the *printed*
program would then contain a duplicate name that Lean refuses). `KnownScope`
computes the name list `known here` prints. Neither is a projection, so neither is a
lens. **`Fresh` and `KnownScope` are exactly what the nominal machinery buys that a
structural design cannot.** That is a small, checkable claim and it is the answer to
"is the type-family scope machinery load-bearing": half of it is, and it is the half
about *names*, not the half about *positions*.

The scope index therefore stays as it is — `Scope = [(Symbol, Code)]` — because
`Fresh` and `KnownScope` both need it. Only `Codes`/`LookupC`/`KnownVar` go.

### 3.3 The honest comparison

| | nominal (today) | structural (handles-as-lenses) |
|---|---|---|
| **reading a name** | `KnownVar n s` instance walk: one `SymEq` reduction and one instance head per entry stepped over, **re-run at every mention**. In a 20-binding block with 40 mentions that is O(800) instance resolutions. | a lens built once at the bind, carried in the handle. Zero constraint solving at use. |
| **compile time** | quadratic in block length | linear |
| **inference** | `LookupC n s` is a non-injective type family application appearing in the *result* type of `hole`, `argName`, `answerB`. Where `s` is not yet determined — inside a `case` arm before the previous statement's `Step` instance is solved — this floats into ambiguity. `Workflow.hs:389` already carries a functional dependency `st -> i j a` on `Step` **specifically to force eager improvement**, and its comment says so. | the handle's type is fully determined at the bind. No type-family application in a result type; the `Step` fundep becomes an optimization rather than a necessity. |
| **error: unbound name** | `LookupC`'s custom `TypeError`: *"unbound name; nothing in scope answers to `guiide`"* — but only when the name reaches `LookupC`. Under the TH surface (`Notation.hs`) and under `[wf\|…\|]` (which emits `varE (mkName n)`, `WF.hs:170`), a typo is already GHC's *"Variable not in scope: guiide"*, which `WF.hs:59` explicitly prefers. | always GHC's own *"Variable not in scope"*, at the right source span. **Strictly better**, and it is the error the surface already documents as the goal. |
| **error: wrong kind** | `Couldn't match type 'CodeVerdict with 'CodeFlag` inside a `LookupC n s` application, with `s` printed as a 20-entry promoted list | `Couldn't match type` on `V n 'CodeVerdict e` vs `V n 'CodeFlag e` — the handle's own type, short |
| **error: name shadowed** | `Fresh`'s `TypeError`, unchanged | `Fresh`'s `TypeError`, unchanged |
| **environment in messages** | `Codes '[ '("guide",'CodeText), … ]` — a promoted assoc list | `(Text, (Verdict, (Text, ())))` — a nested tuple, **worse to read**, and the reason to keep the `Scope` index on `Blk` (§3.1) rather than let `Envs s` surface |
| **runtime producers (`Agentic.Gen`)** | need the `I`-suffixed twins (`bindI`, `holeI`, …) because a generator cannot conjure a `Symbol` (`Builder.hs:1248`) | the handle *is* the `I`-form's `(Text, Var)` pair, packaged. **The twin split largely disappears**: `hole` and `holeI` become one function. |

**What the corpus pin does to a purely structural design.** The frozen entries pin
author names in five printed positions: `RawBind.x`, `RawKnownHere.names`,
`ArgName.x`, `Chunk.Interp`'s name, and `SrcRevising`'s four names
(`Raw.hs`, `Builder.hs:1182`). A handle with no `Text` in it cannot print any of
them. So the structural design is not "delete the names" — it is **"move the name
from the type to the value"**, which is precisely what the existing `I`-suffixed
entry points already do and what `Agentic.Notation` already exploits (it takes each
printed name off the Haskell binder). The corpus therefore does not obstruct the
lens design; it obstructs only the *nameless* version of it, which nobody is
proposing.

The one place names must stay at the type level is `Fresh`, whose whole content is a
comparison of two `Symbol`s, and `KnownScope`, whose whole content is a list of
them. Which is the conclusion of §3.2, arrived at from the other end.

### 3.4 Recommendation for the authoring layer

Adopt the lens handles; keep `Fresh` and `KnownScope`; keep the `Scope` index on the
block types. Do not attempt a nameless structural design. Expect the `I`/named split
to shrink to `Fresh`-carrying wrappers, and expect `Agentic.Gen` to get simpler
rather than harder.

---

## 4. Migration under the conformance regime

### 4.1 What is pinned, exactly

From `Observe.hs:87` and `connection.md` §3.1, a checked reply is:

```
level, size, askNodes, codes, costSummary{minFold,maxFold,paths},
blockAsks, fnAsks, worlds[ { world, trace[Event], billFresh, billMemo } ]
```

plus the printed `RawProgram`, compared after `zeroPos` on both sides. `blockAsks`
and `fnAsks` are read off the **printed Raw** by `Agentic.Guards`, not off the term
(`Observe.hs:78`), so they are untouched by anything in this document.

Everything else is a fold of the term. Three of them — `size`, `askNodes`,
`costSummary` — are counts of the **current `Plan` skeleton**, and are therefore the
gate on every proposal below.

### 4.2 Observation-preserving (safe now)

Each of these is an *extensional* rewrite: same function, different spelling.

| change | why it preserves observations |
|---|---|
| `Env` GADT → nested tuples | `Env` is never serialized, never compared, never printed. Its laziness — `Plan.hs:384`'s "do **not** add strictness annotations here" — is preserved: `(,)` fields are lazy, exactly as `ECons`'s are. |
| `Var`/`varGet` → lens handles | same projections, by `first'`/`second'`/`Forget` |
| `Sub` combinators → `id`/`(.)`/`snd`/`second`/`(&&&)` | same functions |
| `subP` → `lmap`, `graft` → `>>>`, `zipWithP` → `\|*\|` | **only if** they are smart constructors producing the same skeleton — see the box below |
| `runIn`/`traceIn`/`execIn` → `interp` at three targets | same recursion, same order; the `Writer`'s `<>` and `>>>`'s associativity fix event order, and `lmap e` fixes prompt-before-answer |
| `level`/`askNodes`/`codes`/`costTree` → `interp` at four targets | verified clause-by-clause in §1.4 |
| `asks` (Lean) → `trace` at `ωDefault` | `asks_eq_default` is the proof it is the same list |
| `Partial` replacing three inline `Option`s | same `Nothing` at the same formers |

> **The one invariant the whole plan rests on.** `Flow`'s `Profunctor`, `Category`,
> `Strong` and `Monoidal` instances must be **smart constructors that fuse into the
> neighbouring `Ret`**, never new GADT formers:
>
> ```haskell
> Ret f  >>> g      = lmap f g
> f      >>> Ret g  = <push g into every leaf of f>
> lmap s (Ret e)    = Ret (e . s)
> lmap s (AskC c q k) = AskC c q (lmap (second s) k)      -- second = subLift
> f |*| Ret g       = <pair g's result at every leaf of f>
> ```
>
> These are, line for line, today's `graft` (`Plan.hs:550`) and `subP`
> (`Plan.hs:512`). Under this discipline the skeleton is bit-identical and `size`,
> `askNodes` and `costSummary` do not move. The `Category` laws hold **on the nose**
> — `Ret id >>> f = lmap id f = f`, and `f >>> Ret id` pushes `id` into leaves,
> which is `f` — which is Lean's `sub_id`/`sub_comp` plus one new `graft_assoc`.

### 4.3 Observation-changing (spec regeneration = owner decision)

These are **not proposed**. They are listed so that nobody adopts one by accident.

| change | what moves | scale |
|---|---|---|
| **Making `>>>`, `first'` or `lmap` constructors** of `Flow` (the free-arrow / free-strong-monoid presentation of Rivas–Jaskelioff) | `size` grows on every term; `askNodes` and `costSummary` survive (they are law-invariant) but `size` does not | every corpus entry |
| **Free-applicative normal form for batch** (§1.6), so that batch is a class boundary | reassociates `AskC` chains; `size` and possibly `codes` order move | the 16 batch entries |
| **Deriving `zipWithP` generically** as `arr dup >>> f *** g` instead of by recursion | inserts `Ret` nodes; `size` grows at every `panel` | every entry with a panel |
| **Deriving `revising`'s `keep` generically** rather than as `f \|*\| id` fused | `size` grows by `2(n+1)` per revision; `vector-002` is already size 92 | every `revising` entry |
| **Dropping `PDyn`** because the builder cannot make one | `level`'s `Dynamic` becomes unreachable; the reply's vocabulary shrinks; `costTree`'s `CostNode []` clause loses its meaning | none of the corpus, but the *language* changes and the Lean `no_finite_bill_set_at_dyn` witness loses its Haskell counterpart. **Do not.** |

Every row of this table is a decision the owner has to make, because each requires
regenerating the frozen corpus against a Lean side that has been changed to match —
and the corpus is the only thing holding the two implementations together.

### 4.4 The two-step adoption plan

**Step 1 — the core (observation-preserving, no surface change).**

*Scope:* `Agentic.Plan` → split into `Agentic.Flow` (term + classes + `interp`) and
`Agentic.Analysis` (the seven instantiations + `size`); `Agentic.World` and
`Agentic.Exec` lose their folds and gain handlers; `Agentic.Builder`'s four record
types change their term-field types and their `graft`/`subP` calls.

*Not touched:* `Agentic.Workflow`, `.Do`, `.Revision`, `Agentic.Notation`,
`Agentic.WF`, `Agentic.Raw`, `Agentic.Guards`, `Agentic.Observe`, `Agentic.Oracle`,
`Agentic.Text`, `Agentic.AgentDeck`. No Lean change. No corpus regeneration.

*Gates, in order:*
1. `tier0` green (it does not touch the term at all — pure regression signal).
2. `tier1` byte-identical on every frozen entry, comparing the full reply, not just
   `level`. Any move in `size`, `askNodes` or `costSummary.paths` means a smart
   constructor is not fusing; **fix the constructor, never the corpus**.
3. `bisim` green against a live `conformance-oracle`, with the generators driving
   the `I`-forms as they do now.
4. A new unit assertion, cheap and worth having: for a handful of terms,
   `trace w p == snd (runWriter …)` and `runPlan w p == fst (…)` — i.e. that the two
   `Star` instantiations agree, which is the property the two deleted folds used to
   assert by construction.

*Risk:* the smart-constructor discipline. Mitigation: a property in `Agentic.Gen`
asserting `size (f >>> Ret Prelude.id) == size f` and
`size (lmap Prelude.id f) == size f` over generated terms — a direct test that the
`Category`/`Profunctor` units are fusing, which is the exact failure mode.

**Step 2 — the handles (observation-preserving, surface types change).**

*Scope:* `Agentic.Builder`'s `V`/`hole`/`argName`/`answerB`/`ifFlag`/`caseVerdict`
take lens handles; delete `SymEq`, `LookupC`, `KnownVar`, `KnownVar'`, `Codes`;
`Agentic.WF`'s `Says (V n c)` instance loses its `KnownVar`/`LookupC` constraints;
`Agentic.Workflow`'s combinator signatures lose `KnownVar n s` and
`LookupC n s ~ 'CodeFlag` in favour of a handle argument that already has the code.

*Not touched:* the term, the printer, `Fresh`, `KnownScope`, `Agentic.Notation`
(it emits `#label`/`=:`/`bindW`, none of which changes).

*Gates:* the same four, plus: `Example.Harden` — the module `Notation.hs` documents
as the proof — must still print `example-000` statement for statement.

*Risk:* the `Res` injectivity trap (§3.1). Mitigation is a design constraint, not a
test: keep the `Scope` index on `Blk`/`Rhs`/`Body`.

**Anything else is step 3 and is not proposed here.** In particular: level-indexing
`Flow`, the free-arrow presentation, and the final-tagless production surface. The
first is available and would cost a `Level` index on `Stage` with a type-level
`Max` at every branch — which is precisely the "grade as index" shape Lean rejected
(`Level.lean:14`, *"Dependent elimination failed"*), and while Haskell would accept
it, the inference and error-message cost falls on the authoring surface, which is the
part of the system a human touches.

---

## 5. The other two seeds, adjudicated

Brief, because they are documents A and C's, and because one of them does not
survive contact.

**`revising` is a lens-shaped pair that is not a lens, and the failure is the
content.** `review : c → Verdict` is `get` and `amend : (c, Verdict) → c` is `put`,
so `(review, amend)` has exactly the concrete signature of a `Lens' (El c) Verdict`.
The laws then say: *PutGet* — re-reviewing an amended artefact returns the verdict
you amended against — and *GetPut* — amending against your own verdict is a no-op.
PutGet is **false and must be**, because the loop's entire purpose is that the second
review differs from the first; `Plan.lean:621`'s "check first, revise in the
recursive call" is a statement about a `get` that is not determined by the preceding
`put`. GetPut is plausible only on the approving branch. So calling the pair a lens
is decorative: the lens laws are what make optics compose, and these do not hold, so
nothing composes.

What *is* load-bearing in that seed is the carrier plumbing, and it is `Strong`
exactly as claimed: `checkCont`/`reviseCont`/`finishCont` (`Builder.hs:1016`, `:1021`,
`:1029`) are three `subCons`-chains threading the artefact and the verdict past the
loop's binders, and §1.8 replaces all three with `|*| id` plus three named tuple
shuffles. The optic vocabulary earns its keep at `first'`/`second'` and not at
`Lens'`.

The open-games connection (Ghani, Hedges, Winschel & Zahn 2018; Hedges 2017) is real
in shape — a play/coplay pair over a bidirectional composition — and inert in
practice, because the language has **no backward pass**: `amend` does not compose
backwards through a `panel`, and there is no equilibrium condition to solve. Record
it as an analogy; do not build on it.

**Panels are the shared-input monoidal product and the fold direction is normative.**
`panel = foldr (zipWithP verdictMul) (PRet (const Approve))` (`Plan.hs:632`) is
`rmap (foldr verdictMul Approve) (p₁ |*| (p₂ |*| … |*| pureP (const ())))`. Day
convolution (Day 1970) is the right ambient story for *why* the applicative product
of a free structure exists; the operative fact for this codebase is narrower and
sharper: `|*|` is not commutative at any target that records order — `Writer Trace`
and `Verdict` both — and `Builder.hs:552` is right to call the fold's direction
normative. The profunctor rewrite adds one thing worth having: the scheduling licence
(`Cost.lean:247`, `billFresh_panel_perm`) becomes a statement about which targets
have a *symmetric* `|*|`, which is a property of the target and is checkable per
target rather than per theorem.

---

## 6. Citations

Precise where I am confident; flagged where I am not.

- Philip Wadler, *Theorems for free!*, FPCA 1989, pp. 347–359. **Confident.**
- Brian Day, *On closed categories of functors*, Reports of the Midwest Category
  Seminar IV, Lecture Notes in Mathematics 137, Springer 1970, pp. 1–38.
  **Confident** on venue; *unsure of the exact page range*.
- John Hughes, *Generalising monads to arrows*, Science of Computer Programming
  37(1–3):67–111, 2000. **Confident.**
- Robert Atkey, *What is a categorical model of arrows?*, MSFP 2008; published in
  ENTCS 229(5):19–37, 2011. **Confident** on venue; *unsure of page range*.
- Sam Lindley, Philip Wadler, Jeremy Yallop, *Idioms are oblivious, arrows are
  meticulous, monads are promiscuous*, MSFP 2008; ENTCS 229(5):97–117, 2011.
  **Confident.**
- Bart Jacobs, Chris Heunen, Ichiro Hasuo, *Categorical semantics of arrows*,
  Journal of Functional Programming 19(3–4):403–438, 2009. **Confident on the
  result** (arrows = monoids in a category of profunctors / Freyd categories);
  *moderately confident on the exact volume and pages*.
- Kazuyuki Asada, *Arrows are strong monads*, MSFP 2010, ACM, pp. 33–42.
  **Confident on venue**; *unsure of pages*.
- Exequiel Rivas, Mauro Jaskelioff, *Notions of computation as monoids*, Journal of
  Functional Programming 27, e21, 2017. **Confident.** (An earlier version
  circulated as arXiv:1406.4823.)
- Paolo Capriotti, Ambrus Kaposi, *Free Applicative Functors*, MSFP 2014; EPTCS 153,
  pp. 2–30. **Confident on venue**; *unsure of pages*.
- Andrey Mokhov, Georgy Lukyanov, Simon Marlow, Jeremie Dimino, *Selective
  applicative functors*, ICFP 2019; PACMPL 3(ICFP), article 90. **Confident.**
  (This is the `Selective.branch` `Plan.lean:263` names.)
- Matthew Pickering, Jeremy Gibbons, Nicolas Wu, *Profunctor Optics: Modular Data
  Accessors*, The Art, Science, and Engineering of Programming 1(2), article 7,
  2017. **Confident.**
- Guillaume Boisseau, Jeremy Gibbons, *What You Needa Know about Yoneda: Profunctor
  Optics and the Yoneda Lemma*, ICFP 2018; PACMPL 2(ICFP), article 84.
  **Confident.**
- Craig Pastro, Ross Street, *Doubles for monoidal categories*, Theory and
  Applications of Categories 21(6):61–75, 2008. **Confident on the paper** (this is
  the source of Tambara modules as used by the optics literature); *unsure of the
  issue and page numbers*.
- Mitchell Riley, *Categories of optics*, arXiv:1809.00738, 2018. **Confident on the
  identifier**; unrefereed preprint.
- Oleg Kiselyov, *Typed Tagless Final Interpreters*, in Generic and Indexed
  Programming (Spring School, Oxford 2010), LNCS 7470, Springer 2012, pp. 130–174.
  **Confident on venue**; *unsure of pages*.
- Jeremy Gibbons, Nicolas Wu, *Folding domain-specific languages: deep and shallow
  embeddings (functional pearl)*, ICFP 2014, pp. 339–347. **Confident.**
- Neil Ghani, Jules Hedges, Viktor Winschel, Philipp Zahn, *Compositional game
  theory*, LICS 2018, pp. 472–481. **Confident on venue**; *unsure of pages*.
- Jules Hedges, *Coherence for lenses and open games*, arXiv:1704.02230, 2017.
  **Moderately confident on the identifier**; unrefereed preprint.
- Edward Kmett et al., the `profunctors` package (`Data.Profunctor`,
  `Data.Profunctor.Strong`, `Data.Profunctor.Choice`, `Star`, `Forget`). The classes
  named in this document are that package's, except `Monoidal`, `Branching` and
  `Applying`, which are local.

Repository references are by file and line as of the working tree this document was
written against: `Agentic/Core/{Plan,Level,Cost,Denote}.lean`,
`haskell/src/Agentic/{Plan,World,Exec,Builder,Workflow,WF,Notation,Observe}.hs`,
`doc/research/connection.md` §0.1, §3.1, §3.5.
