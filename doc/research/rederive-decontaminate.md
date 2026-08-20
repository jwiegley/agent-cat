# Rederive / Decontaminate — an adversarial reconstruction of the agentic kernel

> **Historical — the code audited here no longer exists (2026-08-20).** This page
> audits the pre-re-derivation stratum: `Agentic/*.lean` outside `Core/` — the `Term`
> calculus, its two meaning functions, the `WEqR` quotient and the resource algebra
> under them. All of it was excised under obr `acat-q1i`, so every `file:line` below
> that names one of those modules resolves in git history only. The results that
> stratum established are transcribed in `doc/research/term-algebra-results.md`; read
> that page for *what was proved*, and this one for the reasoning that condemned it.
> Nothing here describes the code as it stands.

**Status.** Independent reconstruction. Read: `agent-cat` (`Term.lean`, `Frag.lean`,
`Meaning.lean`, `Scope.lean`, `Panel.lean`, `Semiring.lean`, `Keys.lean`, `Env.lean`) and the
seed it may be contaminated by (`agent-functor` `Flow.hs`, `Op.hs`, `Interpret.hs`). No other
dossier file was read, deliberately.

**Thesis.** One wrong denotational choice — *the world is a table indexed by syntactic
positions* — generated every unresolved problem in the current specification; replacing it with
*the world is a table indexed by questions* collapses eleven constructors to one generator plus
standard classes, deletes labels, sites, keys and the relabelling quotient, and turns the
runtime-adherence theorem into a one-line initiality argument.

---

## Part 0 — Method note

Elliott's discipline, applied literally. I asked of every decision in `agent-cat`: *a
mathematician who had never seen `agent-functor` — what object would they have named?* Where the
answer differs from what is there, I constructed the alternative in full and kept whichever is
simpler by his criteria (fewer bespoke names, more standard classes, fewer side conditions, laws
by morphism rather than by proof). Convergence with `agent-functor` appears below only where the
meaning forces it, and I say so each time.

The most valuable input was `agent-cat`'s own honesty. It records, in its own docstrings, six
failed morphisms. Elliott: *"a morphism equation that will not close is the method's most
valuable output."* All six point at one place.

---

## Part 1 — The diagnostic: six failed morphisms, one root

| # | What `agent-cat` records | Where | What it means |
|---|---|---|---|
| 1 | `Term.peak_not_le_grade` — the grade does **not** bound semantic width, in either direction | `Meaning.lean` §width | The index is measuring the wrong thing. A type index that provably fails to bound the quantity it was introduced for is not a specification, it is a decoration. |
| 2 | No projection π between `μ_S` and `μ_ext`, in either direction | `Meaning.lean` header | Two meanings for one type. Elliott's rule is one meaning; two incomparable ones means neither is *the* meaning. |
| 3 | `μ_S` and `μ_ext` **disagree** on `parT` (symmetric `kron` vs left-short-circuiting `Option`-bind) and on `sumT` (symmetric `matAdd` vs left-biased `orElse`) and on `shareT` (transparent vs rebasing) | `muExt_parT`, `muExt_sumT`, `muS` table | Not a gap — a contradiction. The two folds assign different meanings to the same constructor. |
| 4 | Three congruences missing (`retryT`, `fanT`, `bindT`) and one impossible in kind (`shareT`) | `Workflow.seq` "honest remainder" | `WEqR` is not the kernel of any function, so congruence must be proved per constructor and cannot be proved for four of them. |
| 5 | `acat-bmc`: one label over two different bodies collides; "body agreement is the designer's obligation, not a checked property" | `Term.shareT` docstring | Anti-pattern 9 verbatim: *an invariant maintained by documentation.* |
| 6 | `acat-qtv`: sharing cannot be charged, because "a matrix has no room to record a site" | `muS` docstring | The quantitative meaning has forgotten consultation identity, so it cannot see what the extensional meaning is about. |

**The common cause.** In `agent-cat` a consultation is identified by *its path through the term*
(`Key`, `Site`, `Step`, `push`, `rebase`, `relocate`, `splice`). That is Elliott's anti-pattern 2
(*the representation becoming the concept*) crossed with anti-pattern 6 (*a fact about machines
promoted into the meaning*). Its provenance is visible: `agent-functor` interprets a `Flow` by
walking it and assigning node ids, with a *fresh session per leaf* to keep leaves pure; the node
id is an artefact of the interpreter's traversal. `agent-cat` promoted that artefact to the index
of the world.

Everything downstream is the price:

- Because meanings are indexed by position, structurally-equal-but-differently-placed terms have
  different meanings ⇒ **`WEqR` had to be invented** to quotient the damage away.
- Because `WEqR` is `∃σ. …` and not a kernel, **congruence is not free** ⇒ four gaps.
- Because positions are not names, sharing across positions needs **labels** ⇒ `acat-bmc`.
- Because a matrix has no position, the quantitative fold **cannot see sharing** ⇒ `acat-qtv`.
- Because the position calculus is only in `μ_ext`, the two folds **disagree** ⇒ no π.

Elliott's repair table: *"the equation requires an argument that is not available ⇒ the
specification is not compositional ⇒ augment the specification until it is."* The unavailable
argument is *which consultation is this?* The augmentation is not a path; it is the question.

**One further contamination, worth naming because the benefit was stripped and the cost kept.**
`agent-functor`'s `Flow i o` is a profunctor optic *and has no `arr`* — that is the entire stated
reason for the arrow shape ("`arr` is `Arrow`'s defect: it injects opaque Haskell as a node in
its own right, and static inspectability is what every other feature depends on"). `agent-cat`
kept the `i → o` indexing **and added `pureT : (i → o) → Term`, which is `arr`.** The shape
survived; its justification did not. So the arrow indexing is now paying for itself with nothing:
it forces `parT` to be `(i×k) → (j×l)` instead of `liftA2`, `choiceT` to be `Sum i j → o` instead
of the `Sum` eliminator, `fanT` to be `List i → List o` instead of `traverse`, and it forces the
whole `Key` path calculus to have a `Step` per constructor.

And one citation of the seed *as justification*, which directive (2) forbids: `Runner`'s
docstring reads *"So the runner is exactly agent-functor's `LeafRunner`."*

---

## Part 2 — The domain, in the domain's own words

> A workflow is a plan for putting questions to things that answer — a model, a tool, a person —
> and combining what comes back. Running it draws answers, spends resources, and may come away
> with nothing. Two plans are the same plan when nothing you could ask of them tells them apart.

Every noun in that sentence gets a mathematical object below. Nothing else does.

---

## Part 3 — The kernel: types and their meanings

### 3.1 Questions

```lean
/-- A question: everything that determines what comes back. -/
variable (Q : Type)
/-- What each question answers with. -/
variable (Ans : Q → Type)
```

`[[Q]] = the set of questions.` A question carries the addressee (model / tool / human), the
payload, **and the scope** — model, temperature, mode, backend. There is no separate notion of
"where this ran"; *where it ran is part of what was asked.* (See q3.)

This is the load-bearing replacement. `agent-cat`'s world is `Key L → Answer`, keyed by paths
through the term. Mine is keyed by questions. A mathematician asked "what does the oracle depend
on?" answers *what it was asked* — never *where in the caller's source it was asked from*.

### 3.2 Weightings

```lean
/-- The weighting monad. -/
class Weighting (V : Type → Type) extends Monad V, Alternative V where
  comm    : ∀ {A B} (x : V A) (y : V B), (do let a ← x; let b ← y; pure (a,b))
                                        = (do let b ← y; let a ← x; pure (a,b))
  distrib : ∀ {A B} (x y : V A) (k : A → V B), (x <|> y) >>= k = (x >>= k) <|> (y >>= k)
  zero_bind : ∀ {A B} (k : A → V B), (failure : V A) >>= k = failure
```

`[[V A]] = an S-weighted measure on A.` The concrete workhorse is the free semimodule:

```lean
abbrev VS (S A : Type) := A → S            -- S a complete commutative semiring
-- pure a      = fun b => if b = a then 1 else 0
-- (m >>= k) b = ∑ a, m a * k a b            -- Chapman–Kolmogorov
-- (x <|> y)   = fun b => x b + y b
-- failure     = fun _ => 0
```

Instances that matter: `S = ℝ≥0` probability; `S = Bool` possibility; `S = (ℝ∪{∞}, min, +)`
best-case cost; `S = (ℝ∪{-∞}, max, +)` worst-case cost; products of these, giving several
readings at once. `PMF`/Giry may be substituted for `VS` where measurability matters.

**Survivor, promoted.** `agent-cat`'s `Mat S i o = i → o → S` is exactly the Kleisli arrow
`i → VS S o`, and its `comp` is Chapman–Kolmogorov. This is right and I keep it — but as a
*derived* object (the Kleisli category of a standard monad, whose category laws are therefore
free) rather than as a primitive with hand-built laws, and as *the* meaning rather than one of
two.

### 3.3 Oracles

```lean
abbrev Oracle := (q : Q) → V (Ans q)
```

`[[Oracle]] = an S-kernel from questions to answers.` "Randomness at the edge" — `agent-cat`'s
best idea — survives intact: the whole uncertainty is one object chosen once at the outside, and
downstream nothing is random. What changes is only the index set.

### 3.4 Workflows: three types, three standard classes

```lean
inductive Sig : Type → Type where
  | ask : (q : Q) → Sig (Ans q)

abbrev WApp := FreeApplicative Sig     -- static
abbrev WSel := FreeSelective  Sig      -- branching visible   (Mokhov–Lukyanov–Marlow–Dimino)
abbrev WMon := FreeMonad      Sig      -- dynamic
```

with the two canonical inclusions

```lean
def liftAS : WApp A → WSel A     -- free applicative ↪ free selective
def liftSM : WSel A → WMon A     -- free selective  ↪ free monad
```

These are not "weakening constructors" needing justification (`agent-cat` refuses one and then
reintroduces it as `toMonadic`). They are the unit maps of the adjunctions between the theories
App ⊆ Sel ⊆ Mon; they exist because the theories are nested, and they are unique.

**The meaning, for all three at once:**

$$\boxed{\;[\![w]\!] : \mathrm{Oracle} \to V\,A, \qquad [\![w]\!]\,\omega \;=\; \text{the unique
class morphism sending } \texttt{ask } q \mapsto \omega\, q\;}$$

```lean
def den (ω : Oracle) : W A → V A     -- the unique App-/Sel-/Monad-morphism with den ω (ask q) = ω q
```

**`[[·]]` is uncomputable, and that is correct.** `VS S A` sums over all of `A`; for `A = String`
this is a genuine infinite sum in a complete semiring. Elliott: *"write the meaning function
down, and let it be uncomputable."*

### 3.5 The arrow layer, derived

`agent-cat`'s `Term i o` shape is recovered, not assumed:

```lean
abbrev Static (i o : Type) := WApp (i → o)     -- the "static arrow" / Cayley construction
-- >>>  =  liftA2 (· ∘ ·)     -- Category laws are the Applicative laws; nothing to prove
-- ***  =  liftA2 Prod.map
-- +++  =  liftA2 Sum.map
-- arr  =  pure                -- and pure hides nothing, because effects live outside it
```

`Static i o` is exactly "a workflow whose consultations do not depend on the input" — which is
the property `agent-functor` wanted `arr`-freedom for, obtained here *from the type* rather than
from a prohibition. `Category`, `Strong`, `Choice`, `Traversing` all come free from `Applicative`.
Elliott, step 6, verbatim: *"no operation is named that a standard class already supplies."*

---

## Part 4 — Every operation, with its morphism equation

The whole interface. Nine equations; eight are standard class morphisms; one is the generator.

```
Generator     [[ask q]] ω          = ω q
Functor       [[f <$> w]] ω        = f <$> [[w]] ω
Applicative   [[pure a]] ω         = pure a
              [[liftA2 f x y]] ω   = liftA2 f ([[x]] ω) ([[y]] ω)
Selective     [[select x y]] ω     = select ([[x]] ω) ([[y]] ω)
Monad         [[w >>= k]] ω        = [[w]] ω >>= (fun a => [[k a]] ω)
Alternative   [[failure]] ω        = 0
              [[x <|> y]] ω        = [[x]] ω + [[y]] ω
Reader        [[local g w]] ω      = [[w]] (ω ∘ scopeMap g)
```

Elliott's slogan applies unmodified: *the instance's meaning follows the meaning's instance.* All
class laws transfer from `V` to `W` and are never proved for `W`.

### Everything `agent-cat` made a constructor, derived here in one line each

| `agent-cat` | here | equation |
|---|---|---|
| `prim` | `ask q` | *the* generator |
| `pureT f` | `pure f` (at `Static`), `f <$> ·` | Functor/Applicative |
| `seqT` | `liftA2 (· ∘ ·)` / `>>=` | Applicative/Monad |
| `parT` | `liftA2 Prod.map` | `[[·]] = ` tensor of measures |
| `sumT` | `<|>` | `[[·]] = ` sum in the semimodule |
| `choiceT` | `liftA2 Sum.elim` | Applicative |
| `gateT b` | `if b then w else failure` | `[[gate b w]] ω = ⟦b⟧ · [[w]] ω` (scalar action) |
| `scopeT g` | `local (· * g)` at the surface | Reader; **not in the kernel** |
| `shareT ℓ` | *deleted* — sharing is `fmap` / binding | see q2 |
| `retryT n` | `Nat.rec` unrolling | `[[retry n b]] = Σ_{k<n} b_↪^k · b_↩` |
| `fanT n` | `traverse f (as.take n)` | Traversable |
| `bindT` | `>>=` | Monad |

Eleven constructors and a twelfth become **one generator and eight class methods**, none of them
named by us.

---

## Part 5 — The ten questions

### q1. Same question twice: same answer, or independent samples? What is resampling? What does caching MEAN?

**Independent samples, by the monad's own semantics.** In `V`, `liftA2 (,) (ask q) (ask q)` is
the *product* measure; two syntactic occurrences are two draws because the monad's tensor is a
product, not a diagonal. Nothing has to be legislated, keyed, or defaulted. `agent-cat` reaches
the same conclusion by fiat ("duplication is the default"), enforced by a positional key; here it
is a consequence.

**Same answer** is obtained by *binding*: `do let a ← ask q; pure (a, a)`, or applicatively
`(fun a => (a,a)) <$> ask q`. The diagonal is a pure function; pushing a measure forward along it
is not the same as tensoring it with itself.

**Deliberate resampling / best-of-n on one prompt:**

```lean
def bestOf (n : Nat) (q : Q) (score : Ans q → ℝ) : WApp (Ans q) :=
  argmax score <$> replicateA n (ask q)
```

`replicateA` is `Applicative`'s. `[[bestOf n q]] ω = argmax score _* (ω q)^{⊗n}`. Cost is exactly
`n · c(q)`, by the App-level fold. No constructor, no bound index, no `fanT`.

**What caching MEANS.** Here I part company with `agent-cat` sharply, and I think its statement
is an equivocation worth flagging. `Env.cached_eq` proves *replaying one key returns the same
answer* — true, because `Env` is a function. The prose then generalises to "caching is invisible
extensionally", and the caching actually in view (inherited from `agent-functor`'s
content-addressed `leafKey`) is **content-addressed across occurrences**, which is a different
operation and is *not* invisible: it replaces two independent draws by one, exactly the silent
correlation the design elsewhere refuses.

The honest statement, in my kernel:

> A content-addressed cache is **sound for `w` iff `[[w]] = [[share-normal-form of w]]`** — i.e.
> iff every pair of occurrences the cache would merge was already written as a shared binding.

Caching is therefore not an identity but a **proof obligation**, and a workflow that says what it
means (binds what it shares, repeats what it resamples) *never needs a semantic cache at all*.
What remains for caching is pure efficiency — Elliott's step 9, living where it should.

Determinism for replay and debugging is a different operation and survives cleanly: it is
**pinning the oracle**, `ω[q ↦ pure a]`, which is `Function.update` with Mathlib's five laws —
`agent-cat`'s `pin`, re-indexed from sites to questions, where it now means something a user can
state ("fix what the model says to *this prompt*") rather than something only the compiler knows
("fix what happens at `[seqL, parR, retry 2]`").

### q2. What IS sharing? Labels, or structural?

**Structural — it is binding, and nothing else.** A shared consultation is a variable; two uses
of a variable are one consultation, by the ordinary meaning of variables. This is the answer every
functional language already gives, and it needs neither labels nor sites.

```lean
def dup   (x : W A) : W (A × A) := liftA2 Prod.mk x x        -- two draws
def share (x : W A) : W (A × A) := (fun a => (a, a)) <$> x    -- one draw, read twice
```

**Theorem (sharing ≠ duplication), two lines:**

```lean
theorem share_ne_dup (ω : Oracle) (x : W A) :
    [[dup x]] ω  = ([[x]] ω) ⊗ ([[x]] ω)       ∧
    [[share x]] ω = Δ_* ([[x]] ω)
-- and these differ whenever [[x]] ω is not a point mass:
--   Δ_* μ is supported on the diagonal;  μ ⊗ μ is not.
```

This is `agent-cat`'s `Env.share_ne_dup` — the theorem the entire label/key apparatus exists to
support — obtained for free from the standard structure. The general statement has a standard
name: **the Kleisli category of `V` is symmetric monoidal but not cartesian** (copying is not
natural). No bespoke vocabulary; anti-pattern 8 avoided.

Consequences of deleting labels: `Label`/`L`, `Key.rel`, `Key.rebase`, `Relabels`, `Runner.rename`,
`Key.relocate`, `Key.splice`, `WLe`, `WEqR`, `acat-bmc` and the `shareT` congruence gap all cease
to exist. This is the single largest simplification in the proposal, and it is *forced by the
meaning*: once the world is indexed by questions rather than positions, there is nothing for a
label to name.

**What is genuinely lost, stated honestly.** Sharing a consultation between two *distant* parts of
a workflow now requires threading the bound value, where a label could act at a distance. That is
a burden on the author's plumbing, and it is the correct burden: action-at-a-distance sharing by
an unchecked name is exactly `acat-bmc`. If it becomes intolerable, the standard repair is *not* a
label but a **reader/environment layer** (`W` composed with `Reader Ctx`), where the shared value
is an ordinary environment entry with an ordinary scope — still no new constructor.

### q3. What is scoping? Primitive, index transformation, or part of the question?

**Part of the question.** Which model answers, at what temperature, in which mode, on which
backend — these determine the answer. An object that determines the answer belongs in `Q`.

The *ambient-scope convenience* (write it once, have it apply to a region) is then the **Reader**,
at the surface, never in the kernel:

```lean
abbrev Scoped (G : Type) (A : Type) := G → W A
def local [Monoid G] (g : G) (w : Scoped G A) : Scoped G A := fun h => w (h * g)
-- [[local g w]] ω h = [[w]] ω (h * g)
```

`G` is a product of `LastOpt` axes. **`LastOpt` survives** — it is a real gap in Mathlib (the
right-zero semigroup with unit adjoined; `WithOne` supplies the unit half and nothing supplies the
other), and its non-commutativity *is* innermost-wins. `agent-cat` got this exactly right and I
keep it verbatim, including `axis_independence` (the product monoid).

What I delete is `scopeT` as a **term constructor**. Evidence it should never have been one:
`agent-cat` must *prove* `WEqR (scopeT 1 t) t` (`WEqR_scopeT_unit`), and must carry a `scope`
`Step` in every key, and must make the entire quantitative fold land in `Scoped G (Mat S i o)`
rather than `Mat S i o`. With Reader at the surface, `local 1 = id` is the Reader monad's own law,
free; the `scope` step does not exist; the fold's target is unchanged. `withScope_compose` becomes
`actR_compose` on the surface layer — which is where `agent-cat` already put it, one stratum too
deep.

### q4. The hierarchy: which STANDARD structures, and how does cost factor?

This is the owner's directive (1), and it has a precise standard answer.

| level | structure | what is statically visible | cost reading |
|---|---|---|---|
| static | **Applicative** (free applicative on `Sig`) | the *list* of consultations, exactly | a **scalar in `S`**, exact, by a fold |
| branching | **Selective applicative** (Mokhov et al. 2019) | a **finite tree**: branch points visible, both alternatives present, exactly one taken | best/worst-case **interval**, by a fold at two semirings |
| dynamic | **Monad** (free monad on `Sig`) | nothing finite | `[[w]]` is still a total kernel; no structural fold exists |

**Why Selective and not `choiceT`+`sumT`+`retryT`+`fanT`.** The owner asked for "a tree structure
whenever monad is genuinely involved," with branching visible. That is the *published purpose* of
the free selective applicative: `select : f (Either a b) → f (a → b) → f b` says "the second effect
*may* run, depending on the first's answer," its normal form is a tree, and it comes with over- and
under-approximating static analyses. `agent-cat` invented four constructors to cover the territory
one standard class already covers, and got the pieces individually right while missing that they
are one thing. Anti-pattern 8.

**How cost factors — and this is the sharpest result available.** Cost analysis is not a second
artefact. *Cost is the meaning, evaluated at a different semiring.*

```lean
def costOracle : Oracle := fun q => (fun _ => c q)     -- every answer weighs c q
theorem cost_is_meaning (w : W A) : costOf w = [[w]] costOracle
```

- **App**: `S` any semiring ⇒ `cost (pure a) = 1`, `cost (liftA2 f x y) = cost x * cost y`,
  `cost (ask q) = c q`. Exact.
- **Sel**: evaluate at min-plus for best case, at max-plus for worst case, at their **product** for
  the interval. This is Elliott's toolbox entry verbatim — *"an interval or bound ⇒ a product of
  tropical semirings"* — and the "tree" is the free selective's normal form, whose evaluation at
  the product semiring *is* the interval. Nothing invented.
- **Mon**: no structural fold. But `[[w]]` at min-plus is still defined, as an infinite sum in a
  complete semiring, so *best-case cost is still a well-defined number* — it is just not computed
  by recursion on syntax. That is the honest and complete answer to "what remains at full monad."

**Therefore: delete `Frag := ℕ∞`.** It conflates two things a mathematician separates:

1. *which algebraic theory the term lives in* — qualitative, three elements, determines what kind
   of statement the analysis can make;
2. *a numeric bound on data-dependent width* — quantitative, and an **output** of the analysis, not
   an index on the type.

`agent-cat` proves its own index fails at (2): `peak_not_le_grade`, both directions
(`dupPair` peaks at 2 at grade `static`; `fanT 7 (pureT id)` peaks at 0 at grade `bounded 7`), and
`grade_zero_not_indep`. The salvage — `peak ≤ writtenSites * copies` — is a true theorem about two
folds, not a meaning for an index. Meanwhile the index's arithmetic costs a noncomputable `⊔` on
`ℕ∞`, `Frag.scale` with a `max 1` that has to be argued for, a `castGrade` transport, and
`noncomputable example` on every literal term.

Replace with either three types plus two canonical inclusions (simplest), or, if a uniform type is
wanted, `W : Lvl → Type → Type` with `Lvl` the 3-element chain — in which case **only `⊔` is
needed**; `+` and `scale` vanish along with the width bound they existed to carry.

### q5. Retry / bounded iteration: primitive or derived?

**Derived.** Bounded iteration is `Nat.rec` in the meta-language:

```lean
def retry : Nat → (i → W (o ⊕ i)) → i → W o
  | 0,     _, _ => failure
  | n+1,   b, x => b x >>= Sum.elim pure (retry n b)
-- [[retry n b]] ω = Σ_{k < n} (b_↩)^k · b_↪         -- the truncated star, as a lemma
```

Its meaning is *derived*, not stipulated: `agent-cat`'s `Mat.retryTrunc n` is the theorem
`[[retry n b]] = Σ_{k<n} …` rather than a definition. Unbounded retry is the Kleene star
`(b_↩)* · b_↪`, which exists when `S` is complete — `agent-cat`'s `Star`/`KleeneAlgebra` work is a
**survivor** and is the right mathematics, relocated from the definition of a constructor to a
lemma about a recursively defined workflow.

Deleting the constructor deletes `retryLoop`, `retryLoop_congr`, the `retry trip` `Step`, and one
of the four missing `WEqR` congruences.

At which level does `retry` sit? `retry n` at Sel level for fixed `n` (finite tree of `n`
unrollings — the tree grows, which is the honest fact about bounded loops). Unbounded retry is Mon.

### q6. Panels: what structure, where does the reducer enter, is 'parallel' semantic or runtime?

**Structure: `traverse` then `foldMap`. Both standard.**

```lean
def panel [Monoid K] (qs : List Q) (verdict : ∀ q, Ans q → K) : WApp K :=
  foldMap ... <$> traverse (fun q => verdict q <$> ask q) qs
```

**Where the reducer enters: in the pure part.** `foldMap` over a `Monoid K`. Not in the effect
layer, not as a constructor.

**And the deep fact `agent-cat` found is right — it is just not new.** `[[panel]] ω` lives in
`VS S K`, and combining two independent panellists is **convolution** over `K`. But convolution in
`VS S K` *is* `liftA2 (*_K)` — this is Elliott's own listed toolbox correspondence: *"a
monoid-indexed semiring-valued function ⇒ the monoid semiring, whose multiplication IS convolution
AND IS `liftA2` of the index operation."* So `Panel.lean` (843 lines: `MSemiring`, `conv`, `delta`,
`conv_delta`, `convFold`, `convFold_perm`, `convFold_dup`, `panelOf`) is **the applicative
instance of `VS S`, written out by hand**. Its theorems are `liftA2`'s: `conv_delta` is
`liftA2 f (pure a) (pure b) = pure (f a b)`; `convFold_perm` is commutativity of the applicative;
`convFold_dup` is idempotence of `K`'s `*`. All free.

**Is 'parallel' semantic or runtime? Runtime.** Parallelism is a *scheduling licence*, and the
licence is exactly **commutativity of the applicative**:

```lean
theorem may_reorder [CommSemiring S] (x y : W A) :
    liftA2 f x y = liftA2 (flip f) y x
```

This is a derived permission, granted by the meaning, exercised by the scheduler. `agent-cat`'s
`parT`-with-grade-`+` mixes the two: `+` is a *cost* fact about running both, wearing a type
index. And `agent-cat`'s own `Panel.lean` makes the right distinction internally (reordering
*contributions* is free; reordering *convolution factors* needs `CommMonoid K`) — that distinction
survives, and it is `Alternative`-commutativity vs `Applicative`-commutativity, two standard
notions.

**Caveat that the meaning forces** (see q7): commutativity holds only for *observing* leaves. A
leaf that acts on the world does not commute, and the licence must be withheld. This is a real
consequence of getting the meaning right, and neither existing design states it.

### q7. Human-in-the-loop: distinct construct or same effect, different addressee?

**Same effect, different addressee.** `askHuman q = ask q` where `q`'s addressee field says
*human*. `agent-cat` says this well ("three faces of one thing, and the design insists on the
identification, because every operator that treats them alike would otherwise have to be written
three times") and I keep it verbatim: it is forced by the meaning, and the fact that
`agent-functor` also has three leaf kinds is convergence, not derivation.

**But there is a real distinction both designs miss, and it is not the human one.** `agent-functor`
has `Prompt`, `Exec`, `Ask`. `Prompt` and `Ask` *observe*. `Exec` **acts on the world.** Two
executions of `rm -rf` are not two draws from a distribution; they are two state transitions. The
passive-oracle picture — `Oracle = (q : Q) → V (Ans q)` — is simply false for acting leaves, in
both designs.

The repair is standard and cheap:

```lean
abbrev Oracle := (q : Q) → World → V (Ans q × World)     -- an S-weighted state kernel
-- [[W A]] = Oracle → World → V (A × World)
```

Still a monad (state ∘ weighting), still all nine morphism equations, and the passive case is
`World = Unit`. **What it costs is exactly the right thing:** the commutativity of `V` no longer
lifts to `W`, so the parallel/reorder licence of q6 is withheld precisely for acting leaves. That
is the meaning telling the scheduler what it may not do — which is what `gateT`/Grant was
gesturing at without being able to say it. Gating (`gate b w = if b then w else failure`) then
belongs to *acting* questions and is a scalar `0`/`1` action, exactly as `agent-cat` has it.

I recommend the state-kernel form as the specification, and the passive form (`World = Unit`) as
the fragment in which observing workflows are proved.

### q8. Failure / partiality: where does 'no outcome' live?

**In the zero of the semimodule. Partiality is missing mass.** There is no `Option` anywhere in
the meaning.

```
[[failure]] ω    = 0
[[x <|> y]] ω    = [[x]] ω + [[y]] ω
[[gate b w]] ω   = ⟦b⟧ · [[w]] ω
```

`failure >>= k = failure` is `0 · M = 0` — refusal annihilates downstream, which is exactly
`agent-cat`'s `LeftSemimodule` reading of `gateT`. At `S = Bool` missing mass is the empty set; at
`S = ℝ≥0` it is a sub-probability, the standard object.

**Two things this fixes that `agent-cat` records as defects.**

1. `agent-cat`'s `μ_ext` is `Option`-valued and therefore *left-biased and short-circuiting* at
   `parT` and `sumT`, while `μ_S` is symmetric (`kron`, `matAdd`). The two folds contradict each
   other. With one meaning and `+`, the question does not arise.
2. `agent-cat` has no `zeroT` (`acat-1xo`): the additive monoid's unit is missing from the syntax.
   Here `failure` is `Alternative`'s `empty` and the unit laws are `Alternative`'s.

**Where does left-bias go, if you want it?** Into the *element type*, which is Elliott's own repair
row: *"a bias silently lost ⇒ the element type of the model is wrong ⇒ wrap the element so that the
bias is in the signature (`Maybe v ⇒ First v`)."* Left-biased fallback is `<|>` at a
`First`-flavoured / lexicographic semiring, not a different combinator. Retry-with-fallback is then
the same `<|>` with a different `S`.

### q9. What makes equality semantic?

**The kernel of `[[·]]`, quantified over all weightings and oracles:**

```lean
def WEq (w₁ w₂ : W A) : Prop := ∀ (V) [Weighting V] (ω : Oracle V), den ω w₁ = den ω w₂
```

Two structural facts, and the second is why the current design cannot get there:

- **The kernel of a compositional meaning function is automatically a congruence, for every
  constructor, with no proof.** `agent-cat`'s four missing congruences (`retryT`, `fanT`, `bindT`,
  `shareT`) are missing *because `WEqR` is not the kernel of anything* — it is `∃σ. …`, a relation
  invented to repair the positional indexing, and congruence for it must be shown per constructor
  by splicing relabellings, which cannot be done for a countable family (`fanT`, `retryT`), for an
  opaque continuation (`bindT`), or for a labelled base (`shareT`).
- Because `WEq` quantifies over *all* `V` and `ω`, it is precisely equality in the **free** theory:
  two workflows are equal iff they are equal modulo the App/Sel/Monad laws. Nothing coarser (which
  would merge sharing with duplication) and nothing finer (which would distinguish two bracketings
  of a composite).

**Better still: lawful-by-construction, so the quotient is nearly empty.** Present `W` in normal
form — the free applicative as `⟨effect list, pure combining function⟩`, the free selective as its
tree normal form, the free monad as its Kleisli-normal tree — so that the class laws hold by `rfl`
and `WEq` has nothing left to identify except genuine semantic coincidences (e.g. `x <|> x = x`
when `S` is idempotent). Elliott's completion test 3: *nothing left to prove.*

`agent-cat`'s `Workflow := Quotient wSetoidR` and `Workflow.staticCategory` are the right
*ambition* — "the obligation to respect meaning is discharged at the definition of every operation,
by the elaborator, or the operation does not exist." I keep the ambition and change the relation.

### q10. What must the runtime-adherence theorem SAY?

Let the live agent process be an effectful `run : (q : Q) → M (Ans q)` in some execution monad `M`
(`IO`, or `StateT Session IO`). Let `ρ : M ⇒ V` be the **realization** — for a probabilistic
process, "the law of"; for a deterministic transcript, "the Dirac at the observed value".

```lean
def runW : W A → M A            -- the unique class morphism extending `run`
```

**The theorem:**

$$\boxed{\;\Big(\forall q,\; \rho\,(\mathrm{run}\;q) = \omega\,q\Big) \;\Longrightarrow\;
\rho \circ \mathrm{runW} \;=\; [\![\cdot]\!]_\omega\;}$$

**Proof: one line.** `ρ ∘ runW` and `[[·]]_ω` are both class morphisms `W → V` (composites of
morphisms); `W` is free on `Sig`; they agree on generators; therefore they are equal by
initiality. *This is only available because the syntax is free over a signature.* An
eleven-constructor GADT that is free over nothing requires a twelve-case induction for every such
theorem, and every new constructor invalidates every existing proof. This is the strongest single
argument for the reconstruction.

**The per-operation corollaries — the owner's "each operation commutes with the denotation":**

```
ρ (runW (pure a))        = pure a
ρ (runW (f <$> w))       = f <$> ρ (runW w)
ρ (runW (liftA2 f x y))  = liftA2 f (ρ (runW x)) (ρ (runW y))
ρ (runW (select x y))    = select (ρ (runW x)) (ρ (runW y))
ρ (runW (w >>= k))       = ρ (runW w) >>= (ρ ∘ runW ∘ k)
ρ (runW (ask q))         = ω q
ρ (runW failure)         = 0
ρ (runW (x <|> y))       = ρ (runW x) + ρ (runW y)
```

**Three tiers, in order of what Lean can carry today:**

- **T1 — pathwise (provable now, no measure theory).** `M = Except E`, `S = Bool`, `ω = δ ∘ o` for
  a deterministic oracle table `o`, `ρ = support`. Then
  `runW o w = .ok a ↔ [[w]]_{δ∘o} a = true`. This is the theorem an integration test *is*.
- **T2 — resource.** `S` tropical, `ρ = ` observed cost of the branch taken. Then
  `observedCost (runW w) ≥ [[w]]_{minplus}` and `≤ [[w]]_{maxplus}`. Static analysis validated
  against a live run, by the same equation.
- **T3 — distributional.** `M = ` probabilistic IO, `V = PMF`, `ρ = ` law. Then
  `law (runW w) = [[w]]_ω`. Needs Mathlib's `PMF`/`Giry`.

**What must be assumed rather than proved, stated honestly.** `ρ` being a *monad morphism* on `M`
encodes exactly two assumptions about the live process: (i) each invocation of `run q` has law
`ω q`, and (ii) distinct invocations are independent. Neither is provable in Lean about a network
service; both are the operational content of "the runtime adheres". `agent-functor` buys (ii) by
*fresh session per leaf*, and that is the correct engineering — the point is that it is a
**hypothesis of the adherence theorem**, not a fact about the meaning. `agent-cat` imported it as
a fact about the meaning (world cells keyed per site), and that is the contamination.

---

## Part 6 — What survives from `agent-cat`, and why

I am not claiming the current specification is wrong throughout. Ten things are right, and I keep
every one; several are keepers *because the meaning forces them*, and I say so.

1. **Randomness at the edge** — one sample point chosen at the outside, everything downstream
   deterministic. Forced by the meaning (a workflow's answer must be a function of what the oracles
   said). Kept; re-indexed by questions.
2. **Semiring-valued meaning; `Mat` = Chapman–Kolmogorov.** Forced. Promoted to *the* meaning; its
   category laws become free (Kleisli of a monad).
3. **Complete semirings / Kleene star for iteration.** Forced by unbounded retry. Kept, as the
   lemma about a recursive workflow.
4. **`LastOpt` and per-axis innermost-wins.** Forced (a genuine Mathlib gap; the non-commutativity
   *is* the override discipline). Kept verbatim, moved to the surface.
5. **Refusal is `0` and annihilates.** Forced. Kept, and promoted to the *only* partiality.
6. **Convolution over a key monoid for panels.** Forced. Kept — as `liftA2`, per Elliott's own
   correspondence, at 1/40th the code.
7. **`pin` = `Function.update`, with fork/resume/cache-edit as three uses of one operation.**
   Forced. Kept; re-indexed by questions, where it becomes user-meaningful.
8. **Sharing ≠ duplication as a genuine semantic fact.** Forced. Kept, as a two-line consequence.
9. **Model / tool / human are one effect.** Forced. Kept.
10. **Lean, so that respecting meaning is checked at the definition of every operation.** Kept, and
    strengthened: with a free syntax it is checked by *initiality*, not by twelve cases.

---

## Part 7 — The Lean sketch

```lean
namespace Agentic

variable (Q : Type) (Ans : Q → Type)

/-- The signature: one generator. -/
inductive Sig : Type → Type 1 where
  | ask : (q : Q) → Sig (Ans q)

/-- The weighting monad: commutative, additive, with an annihilating zero. -/
class Weighting (V : Type → Type) extends Monad V, Alternative V, LawfulMonad V where
  comm      : ∀ {A B} (x : V A) (y : V B),
                (x >>= fun a => y >>= fun b => pure (a,b))
              = (y >>= fun b => x >>= fun a => pure (a,b))
  distribR  : ∀ {A B} (x y : V A) (k : A → V B), (x <|> y) >>= k = (x >>= k) <|> (y >>= k)
  zero_bind : ∀ {A B} (k : A → V B), (failure : V A) >>= k = failure

/-- The workhorse instance: the free S-semimodule on A. -/
abbrev VS (S : Type) [CompleteCommSemiring S] (A : Type) := A → S
instance : Weighting (VS S) := ...     -- pure = δ, bind = Chapman–Kolmogorov, <|> = +, failure = 0

abbrev Oracle (V) := (q : Q) → V (Ans q)

/-- Three carriers, three theories, two canonical inclusions. -/
abbrev WApp := FreeApplicative (Sig Q Ans)
abbrev WSel := FreeSelective   (Sig Q Ans)
abbrev WMon := FreeMonad       (Sig Q Ans)

/-- THE MEANING. Uncomputable, and correct. -/
noncomputable def den {V} [Weighting V] (ω : Oracle Q Ans V) : WMon Q Ans A → V A :=
  FreeMonad.foldMap (fun _ s => match s with | .ask q => ω q)

/-- Semantic equality: the kernel of the meaning. A congruence, by construction. -/
def WEq (w₁ w₂ : WMon Q Ans A) : Prop :=
  ∀ V [Weighting V] (ω : Oracle Q Ans V), den ω w₁ = den ω w₂

/-- The derived arrow layer. Category / Strong / Choice for free. -/
abbrev Static (i o : Type) := WApp Q Ans (i → o)

/-- Adherence, by initiality. -/
theorem adherence {M V} [Monad M] [Weighting V]
    (run : (q : Q) → M (Ans q)) (ρ : ∀ {A}, M A → V A) (hρ : IsMonadHom ρ)
    (ω : Oracle Q Ans V) (h : ∀ q, ρ (run q) = ω q) :
    ∀ {A} (w : WMon Q Ans A), ρ (runW run w) = den ω w :=
  FreeMonad.hom_ext (hρ.comp runW_isHom) (den_isHom ω) h

end Agentic
```

Module inventory, against `agent-cat`'s 10,145 lines:

| module | fate |
|---|---|
| `Term.lean` (535) | → `Sig` (3 lines) + three free-structure instantiations |
| `Frag.lean` (285) | **deleted**; replaced by three types (or a 3-chain) |
| `Meaning.lean` (2831) | → `den` (5 lines) + the nine equations (all `rfl`) |
| `Keys.lean` (344) | **deleted** (sites/keys gone); the concrete verdict monoids move to a small `Verdicts` |
| `Panel.lean` (843) | → a `def panel` and a remark that convolution is `liftA2` |
| `Scope.lean` (247) | `LastOpt` kept (~60 lines); the rest becomes Reader |
| `Matrix.lean` (763) | → Kleisli of `VS`; laws free |
| `Semiring.lean`/`Star.lean` (1545) | kept, trimmed to the genuine Mathlib gaps |
| `Env.lean` (342) | → `pin = Function.update` on oracles (~40 lines) |
| `Gate.lean`, `Trace.lean`, `Pareto.lean` | → `gate` one-liner; instances |

---

## Part 8 — Where this kernel strains (reported, not hidden)

1. **Acting leaves.** The passive-oracle picture is *wrong* for `Exec`. The state-kernel repair
   (q7) is standard and cheap but withdraws the reordering licence. Both designs are silent here;
   I flag it as the one place the domain analysis, not the algebra, is at fault.
2. **Measurability.** `VS S A = A → S` needs a complete semiring to sum over infinite answer types.
   For probability over strings, `PMF` (countable support) or Giry is the honest carrier. The
   kernel is parametric in `V`, so this is a choice of instance, not a change of design — but it is
   a real choice and Lean will feel it.
3. **Selective's guarantee is about the term, not the meaning.** `[[w]]` for a `WSel` term is just
   its monadic meaning; the level index tells you what may be *asked about* the term. That is the
   correct role for a grade, and it is strictly better than `Frag`, which claimed a semantic bound
   and provably lacked it — but it should not be oversold.
4. **`Q` must be rich.** Deciding what makes two questions the same is a genuine modelling burden.
   It is, however, a burden in the *domain's* vocabulary (prompt, addressee, model, temperature,
   draw-index) rather than in the syntax's (paths, labels), and it is checkable by the author
   rather than assumed by a docstring.
5. **Notation.** Writing in the weakest class costs `do`-notation at App and Sel. The mitigation is
   an applicative-do / selective-do elaboration; the discipline is not free, and pretending it is
   would be the first step back toward making everything monadic.
6. **Independence in the adherence theorem is an axiom about the process.** It cannot be proved in
   Lean. Stating it as a hypothesis is the honest form; hiding it in the meaning (as fresh-session
   purity or per-site world cells) is not.

---

## Part 9 — The four completion tests

1. **Every type has a stated meaning.** `Q`, `Ans`, `V`, `Oracle`, `W`, `Static` — six types, six
   one-line meanings. ✔
2. **Every operation's meaning is forced.** Nine equations; eight are standard class morphisms; one
   is the generator. No operation is named that a standard class supplies. ✔
3. **Nothing is left to prove.** Class laws transfer from `V`; `Mat`'s category laws are Kleisli's;
   the equality is a kernel, so congruence is free; adherence is initiality. The only remaining
   proofs are *lemmas from* the denotation: `share_ne_dup`, `retry`'s truncated star,
   `cost_is_meaning`. ✔
4. **Efficiency lives elsewhere.** `[[·]]` is an uncomputable infinite sum. Caching, scheduling,
   parallelism, session reuse and content-addressing are all refinements licensed by theorems about
   a denotation that has not moved. ✔
