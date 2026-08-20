# Contamination Ledger

> **Historical — the code audited here no longer exists (2026-08-20).** This page
> audits the pre-re-derivation stratum: `Agentic/*.lean` outside `Core/` — the `Term`
> calculus, its two meaning functions, the `WEqR` quotient and the resource algebra
> under them. All of it was excised under obr `acat-q1i`, so every `file:line` below
> that names one of those modules resolves in git history only. The results that
> stratum established are transcribed in `doc/research/term-algebra-results.md`; read
> that page for *what was proved*, and this one for the reasoning that condemned it.
> Nothing here describes the code as it stands.

**A row-by-row audit of `/Users/johnw/src/agent-cat` against `/Users/johnw/src/agent-functor`, under Conal Elliott's denotational design discipline.**

Prepared 2026-08-12. Auditor role: ledger, not kernel. Every claim carries a `file:line`.

---

## 0. How to read this ledger

Two axes, deliberately kept apart, because conflating them is how "we independently arrived at the same thing" becomes an excuse.

**Axis 1 — precedent.** Does `agent-functor` contain the same construct? A citation, or `NONE`. Precedent is *evidence*, never a verdict. Convergence is admissible only when Axis 2 says FORCED, and then it is a confirmation, not a justification.

**Axis 2 — verdict.** Judged against the meaning alone:

- **FORCED** — the mathematical object admits no simpler alternative that loses nothing. An argument is given, and it must be an argument *from the denotation*, not from convenience, not from the host language, not from an existing implementation.
- **INDIFFERENT** — the mathematics permits several presentations of one object; this one is fine; nothing downstream depends on the choice.
- **INHERITED** — a simpler or more general alternative exists. The alternative is stated. This verdict is available even when precedent is `NONE`: an element can be over-built without anybody else having built it first.

The doctrine's four completion tests (Kernel, `/Users/johnw/Documents/Obsidian/conal-elliott-denotational-design.md:85–92`) supply the standard: every type has a stated meaning; every operation's meaning is forced; nothing is left to prove; efficiency lives elsewhere.

The thesis in one sentence, stated before the evidence so that it can be checked against it:

> **The specification's syntax is a point-free profunctor calculus because `Flow` is a profunctor optic, and nearly every hard part of the specification — labels, sites, keys, relabellings, the quotient-up-to-relabelling, the runner, the numeric grade — is the price of point-freeness, a price the meaning never asked anyone to pay.**

---

## 1. The meanings, as the specification currently states them

Before the ledger, the specification's own denotations, restated in the doctrine's notation so that each row below can be checked against one.

```
[[Term Op G L f i o]]_S   = Scoped G (Mat S i o)        -- Meaning.lean:175
[[Term Op G L f i o]]_ext = Runner → G → Key L → i ⇀ o  -- Meaning.lean:832
[[Mat S ι κ]]             = ι → κ → S                   -- Matrix.lean (Mat)
[[Scoped G R]]            = G → R                       -- Scope.lean:252
[[Frag]]                  = ℕ∞                          -- Frag.lean:119
[[LastOpt α]]             = Option α, right-zero + unit -- Scope.lean:86
[[Key L]]                 = abs Site ⊎ rel L Site       -- Meaning.lean:535
[[Env C O]]               = C → O                       -- Env.lean:64
[[Workflow]]              = Term / WEqR                 -- Meaning.lean:2498
```

Two of these are already diagnostic. `[[Frag]] = ℕ∞` is a meaning for the *carrier* of the grade, not for the grade: nowhere is there a `[[f : Frag]]` such that `grade` is a homomorphism into it, and the module that would have to supply one instead proves that the grade is incomparable with the quantity it names (`Meaning.lean:1636` `peak_not_le_grade`). And `[[·]]_ext` is indexed by a `Runner`, which is an interpreter, not a value — so no measure can sit on it, and the design's promised projection π (`doc/design.html`, §3: "the probability factor of ⟦w⟧S is the pushforward of ⟦w⟧ext along the measure on E") is not merely unproved but unstateable in the terms the fold provides.

---

## 2. The ledger

### 2.A — The syntax stratum: shape of the family

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| A1 | `inductive Term (Op : Type → Type → Type) (G L : Type) : Frag → Type → Type → Type 1` — `Term.lean:115` | `data Flow i o where …` — `Flow.hs:88`; the GADT-with-input-and-output arrow spine | **INHERITED** |
| A2 | `Op : Type → Type → Type`, the leaf signature — `Term.lean:14–18, 124` | `data Op a b where Prompt / Exec / Ask` — `Op.hs:314` | **INHERITED** |
| A3 | Eleven-plus-one constructor list — `Term.lean:124–264` | Fifteen `Flow` constructors — `Flow.hs:89–135`; explicit 1-to-1 mapping recorded at `doc/PLAN.org:1637` | **INHERITED** |

**A1/A2/A3 argued together, because they are one decision.**

`doc/PLAN.org:1637` is the load-bearing citation for this entire ledger. It records, in the specification repository's own tracker, a three-agent reconnaissance whose finding is:

> "agent-functor's Flow models our static/bounded fragment **constructor-for-constructor**: Leaf~prim (Prompt/Exec/Ask = our one consultation index), Dimap~pureT, Seq~seqT, Par~parT, LeftF/RightF~choiceT, Share Label~shareT (label-keyed, structural), WithScope~scopeT (innermost-wins per axis, = our LastOpt), LoopUntil Fuel~retryT, TraversePositions Bound~fanT, Unfold Depth~bounded recursion."

Nine of `Term`'s twelve constructors are named there against a `Flow` constructor. The note reads the correspondence as *vindication* ("Implementation-first repo converged on the axioms the spec chose — strong evidence for the design"). Read the other way — the way owner directive (2) requires — it is the finding that the representation formed the thinking.

The mathematical question is what shape the free object should have. The design's own §0 (`doc/design.html:50`) states the rule: "a free term algebra whose entire purpose is to admit several homomorphisms out." A free algebra is free *on a signature, for a structure*. The structure the meanings inhabit is stated in §4 (`doc/design.html:108–116`): Category, lax monoidal, Additive, LeftSemimodule, StarSemiring, Reader, Monad. So the free object is the free (complete-semiring-enriched, star-carrying, monoidal, biproduct) category on the leaf signature — and its generators would then include the identity, the zero, the associators and the symmetry, all of which are *absent* from `Term` (`Meaning.lean:158–170` lists exactly this: "There is no `idT`… no `zeroT`… no panel constructor… no `pinT`"). `Term` is not the free anything. It is `Flow`'s constructor list, with `bindT` added and `Unfold` dropped.

Now the alternative, and why it is simpler. The design's §2 says a Consultation is "one point of the index I" — a question. A question's answer type is determined by the question: `HardenPatch.lean:18–24` writes exactly this, `PatchOp : Type → Type → Type` with `draft : PatchOp Spec Patch`, and every leaf's *input* is supplied by whatever it is composed with. The input index is therefore redundant: `Op i o ≅ i → Q o` where `Q : Type → Type` is the functor of questions. That is not a repackaging; it changes what the free object is:

```lean
/-- A question. The answer type is part of the question, so an environment can
    be a dependent function and no decoding universe is needed. -/
-- Q : Type → Type

inductive Ap  (Q : Type → Type) : Type → Type 1      -- free applicative
  | pure {α} : α → Ap Q α
  | ap   {α β} : Q α → Ap Q (α → β) → Ap Q β

inductive Sel (Q : Type → Type) : Type → Type 1      -- free selective
  | ...
  | branch {α β γ} : Sel Q (α ⊕ β) → Sel Q (α → γ) → Sel Q (β → γ) → Sel Q γ

inductive Free (Q : Type → Type) : Type → Type 1     -- free monad
  | pure {α} : α → Free Q α
  | bind {α β} : Q α → (α → Free Q β) → Free Q β
```

Against this, `Term`'s twelve constructors collapse as follows. `pureT` is `pure` and `fmap`. `seqT` is `<*>` (or `>>=`). `parT` is `liftA2 (,)`. `choiceT` is `branch`, i.e. `Selective` — a *recognized standard class* (Mokhov–Lukyanov–Marlow–Dimino, ICFP 2019) whose entire published motivation is the thing §4 says branching is for: static over-approximation of a computation's dependencies when the shape is fixed but the choice is not. `fanT` is `List.traverse`, free for any `Traversable` and any `Applicative`. `sumT` is `<|>` and `gateT false` is `empty` — `Alternative`. `retryT` is a section of the Kleene star. `scopeT` is a fold (§2.F). `shareT` is `let`-binding (§2.G). `bindT` is `>>=`.

What remains genuinely new after that collapse is: the leaf class `Q`, the semiring-valued pricing of leaves, and the panel's reducer monoid. Three objects, not twelve constructors.

The doctrine's anti-pattern 8 (`Kernel:81`): "Bespoke names for standard operations… Each one forfeits every library and law attached to the standard class." `seqT`/`parT`/`sumT`/`choiceT`/`fanT` are `<*>`, `liftA2`, `<|>`, `branch`, `traverse` under bespoke names, and the forfeit is visible: `Meaning.lean:158–170` has to *report* that the Category's unit and the Additive's zero have no constructor, which is a statement no free-applicative presentation could make, because `pure id` and `empty` are constructors of the class.

---

### 2.B — The constructors, individually

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| B1 | `prim : Op i o → Term … .static i o` — `Term.lean:124` | `Leaf :: Op a b -> Flow a b` — `Flow.hs:101`; `leaf` — `Flow.hs:138` | **FORCED** (that a consultation is a generator), **INHERITED** (the arrow shape; see A2) |
| B2 | `pureT : (i → o) → Term … .static i o` — `Term.lean:135` | **Anti-correspondence**: `Flow` has *no* `arr`, by design — `Flow.hs:6–11`; pure functions enter only through `Dimap :: (a→b) → (c→d) → Flow b c → Flow a d` (`Flow.hs:91`) | **FORCED** |
| B3 | `seqT : Term f i j → Term g j o → Term (f ⊔ g) i o` — `Term.lean:138` | `Seq :: Flow a b -> Flow b c -> Flow a c` — `Flow.hs:90` | **FORCED** as composition; **INHERITED** in its grade (see §2.C) |
| B4 | `parT : … → Term (f + g) (i × k) (j × l)` — `Term.lean:150` | `Par :: Flow a b -> Flow a' b' -> Flow (a,a') (b,b')` — `Flow.hs:92`; `par'` — `Flow.hs:233` | **INDIFFERENT** as the monoidal tensor; **INHERITED** as a *primitive* |
| B5 | `sumT : Term f i o → Term g i o → Term (f ⊔ g) i o` — `Term.lean:155` | `NONE` — `Flow` has no alternation at all | **INHERITED** |
| B6 | `choiceT : Term f i o → Term g j o → Term (f ⊔ g) (i ⊕ j) o` — `Term.lean:164` | `LeftF` / `RightF` — `Flow.hs:95–96`; `left''`/`right''` — `Flow.hs:253,258` (`Choice` profunctor) | **INHERITED** |
| B7 | `gateT : Bool → Term f i o → Term f i o` — `Term.lean:173` | `NONE` at the `Flow` level. `Agent.Grant` is a set lattice enforced at the ACP boundary — `Grant.hs:41–56`; `humanGate` is a `Prompt` leaf — `Combinators.hs:322` | **INHERITED** |
| B8 | `scopeT : G → Term f i o → Term f i o` — `Term.lean:178` | `WithScope :: ScopeDecl -> Flow a b -> Flow a b` — `Flow.hs:119`; `applyScope` — `Op.hs:222` | **INHERITED** |
| B9 | `shareT : L → Term f i o → Term f i o` — `Term.lean:216` | `Share :: Label -> Flow a b -> Flow a b` — `Flow.hs:105`; `share` — `Flow.hs:204`; `newtype Label` — `Flow.hs:80` | **INHERITED** |
| B10 | `retryT : Nat → Term f i (o ⊕ i) → Term f i o` — `Term.lean:223` | `LoopUntil :: Fuel -> Flow a (Either a b) -> Flow a b` — `Flow.hs:130`; `Fuel` — `Bounds.hs`; `runPure` loop — `Normalize.hs:110–116` | **INHERITED** |
| B11 | `fanT : (n : Nat) → Term f i o → Term (f.scale n) (List i) (List o)` — `Term.lean:254` | `TraversePositions :: Bound -> View s a -> Flow a b -> Flow s (Positions b)` — `Flow.hs:123`; `boundedFocus` truncation — `Normalize.hs:105` | **INHERITED** |
| B12 | `bindT : Term f i k → (k → Term g PUnit o) → Term … .monadic i o` — `Term.lean:263` | **Anti-correspondence**: `Flow` is "deliberately __not__ 'Monad', not @ArrowApply@" — `Flow.hs:5–6` | **FORCED** |

**B1 — `prim`.** That a consultation is a generator of the free object is forced: it is the only thing the environment answers, and §2's un-privileging of the model (`doc/design.html:70`) says model, tool and human are one index, which `Op` correctly does not distinguish. What is inherited is the *bidirectional* shape, argued at A2. Note also that `prim`'s grade is `.static` while `Meaning.lean:1796` `grade_zero_not_indep` proves that a `.static` term's meaning depends on the world — i.e. the grade's bottom element does not mean what its name says.

**B2 — `pureT`.** A genuine divergence and a correct one. `Flow` refuses `arr` because "it injects opaque Haskell as a node in its own right, and static inspectability is what every other feature depends on" (`Flow.hs:8–9`). That is a *machine* argument — it protects the `agent-functor plan` command and the TUI. The meaning has no such requirement: a Transform is "a plain function P → P; its matrix is the 0-1 point matrix [b = f a]" (`doc/design.html:74`), and a point matrix is a perfectly good meaning whether or not a renderer can print it. agent-cat correctly refused the inheritance here, and the docstring at `Term.lean:126–134` gives the denotational reason (Transforms are central by construction, and copying a *value* is not re-asking a *question*). This row is the specification's best moment: an inherited constraint identified as a fact about a machine and dropped. Note that `Flow`'s own escape hatch (`purePP = dimap' (const ()) (const b) Id`, `Flow.hs:291`) proves the refusal never held anyway.

**B4 — `parT`.** Juxtaposition is the monoidal tensor and its meaning is the Kronecker product; both are forced. What is inherited is that it is a *primitive*. In any applicative presentation, `liftA2 (,)` is derived from `pure` and `<*>`, and the design's own §4 row is an *inequality*, `⟦f ⊗ g⟧ ≤ ⟦f⟧ ∥ ⟦g⟧`, "equality on disjoint footprints" (`doc/design.html:109`). `muS_parT` (`Meaning.lean:227`) is an equality — the fold has no order on it at all, as `Meaning.lean:170` admits. So the specification has kept `Flow`'s primitive `Par` and dropped the one thing the design said was interesting about it. The simpler alternative: derive the tensor from the applicative, and recover the lax-monoidal inequality as a theorem about the *footprint-carrying* leaf signature, which is where §6b said it lives.

**B5 — `sumT`, and B7 — `gateT`, argued together.** These are the two rows where a missing generator has been replaced by two present ones. The design's Additive row is `⟦0⟧ = 0` *and* `⟦f ⊕ g⟧ = ⟦f⟧ + ⟦g⟧` (`doc/design.html:110`); the syntax has the second and not the first, and `Meaning.lean:164` records the gap as `acat-1xo`. Meanwhile `gateT false` denotes exactly `Mat.zeroMat` (`Gate.lean`, and `muS_gateT_false`, `Meaning.lean:318`). So the syntax *does* have a zero — it is spelled `gateT false t`, a two-argument constructor carrying a redundant body. Add `zeroT` and gating becomes a definition, not a constructor:

```lean
def gate (b : Bool) (t : F α) : F α := if b then t else zero
-- [[gate b t]]_S = indicator b • [[t]]_S     -- LeftSemimodule row, now a theorem
```

That is one generator instead of two, it closes the Additive row, and it makes `Alternative` (`empty`, `<|>`) the recognized class instead of two bespoke names. Separately: `Gate.lean` takes a bare `Prop` with no `Decidable` instance, on the explicit ground that "the meaning of a guard is a proposition about the world, and deciding it is an implementation's job" — but `gateT : Bool → …` has already decided it, so the generality of `Gate.lean` is unreachable from any written term. And `doc/PLAN.org:1299` records that `gateT` never appears in author text at all: it is "a DESIGNER construct for stating impossibility theorems". A constructor that no author writes and whose meaning is the additive zero is the additive zero.

**B6 — `choiceT`.** More general than `Flow`'s `LeftF`/`RightF` (a copairing rather than two injections), which is an improvement. Still INHERITED, because the class it instantiates has a name: `branch` of `Selective`. Taking the standard class buys the exact thing §4 claims for the static fragment — "the huge token space factors onto a finite coproduct of verdicts; the payload flows as data while the verdict steers" (`doc/design.html:117`) — as the published semantics of an existing abstraction, together with its laws, its over-approximating static analysis, and the `Applicative < Selective < Monad` chain which *is* owner directive (1) as a tower of standard classes rather than as an arithmetic index. See §4.

**B8 — `scopeT`.** See §2.F.

**B9 — `shareT`.** See §2.G. This is the ledger's number-one entry.

**B10 — `retryT`.** The meaning is right and is one of the specification's genuine derivations: §5.2's `L = M_A·(d·L) + M_B` solved by star-semiring elimination to `(M_A d)* M_B` (`doc/design.html:129`), realized in `Star.lean` with `retry_fixed` and, under Kleene induction, `retry_least`. The design's own words are that "fuel is the star's truncation, and 'unbounded' is its divergence". The specification then puts the fuel in the *syntax* (`retryT : Nat → …`) and makes the *meaning* the truncated star `Mat.retryTrunc n` (`Meaning.lean:~185`, `muS_retryT` at `:267`), because the grade calls a fueled loop `.static` and an unbounded star would make a `.static` term denote an unbounded cost (`Meaning.lean:~150`, the docstring's "commitments kept rather than choices made"). That reasoning is circular: the meaning is truncated in order to make an index true. The doctrine's step 9 is explicit — "never move the denotation" (`Kernel:57`). The honest form: the loop denotes the star; divergence at the Cost carrier is the truth about a loop with no bound; a fuel is a *policy* applied at realization, or, if exhaustion-is-refusal is a real behavioral commitment (it is defensible), then the fuel belongs to a `revising` combinator defined from the star and the gate, not to a constructor of the free object. Precedent is exact: `Fuel` is `Bounds.hs`'s bare count and `runPure` errors on exhaustion (`Normalize.hs:112`).

**B11 — `fanT`.** The most consequential single-constructor inheritance. `Flow`'s `TraversePositions` carries a mandatory `Bound` (`Bounds.hs`: "an unbounded dynamic construct is a static error"), and `boundedFocus` enforces it by truncating the position list. `fanT n` copies both halves: the number is syntax, and *the meaning truncates the input list at `n`* (`Meaning.lean:~193`, `muS_fanT`; `fanRun`/`take n` at `:832`+). The consequences are stated proudly at `Term.lean:243–252` — "the bound is a contract on the MEANING, not the type, and the contract is now kept" — but what is kept is that a workflow given eleven files when it declared eight *silently reviews eight*. That is a machine fact (a scheduler cap) promoted into the denotation; it is the doctrine's anti-pattern 3 and 6 at once ("arrays plus index arithmetic as the substrate: Factor types, not numbers!", `Kernel:76`).

The alternative is smaller and more general in three ways. First, the operation is `traverse`, free for `Traversable List` and any `Applicative` — no constructor. Second, the cost of a traversal is honestly a *function of the input*: `cost (traverse f xs) = ∏ cost (f x)`, which is what a fold into a `Const Cost` applicative computes. Third, if an a-priori *number* is wanted, it is the supremum over inputs, and the way to make that finite is to bound the *type* (`Vector i n`), which the specification names as "the alternative repair" and rejects with "truncation did not prove surprising enough to need it" (`Term.lean:245`). Truncation of the meaning is surprising exactly once, and then it is load-bearing forever: it is why `Frag` needs a numeric payload at all, why `Frag.scale` needs its `max 1` fudge (`Frag.lean:144–159`), why `Term.peak` exists, and why `peak_not_le_grade` is a theorem.

**B12 — `bindT`.** Correct, forced, and a real divergence from `Flow`. `Flow` refuses `Monad` and `ArrowApply` to preserve static inspectability (`Flow.hs:5–6`), and `doc/design.html:117` withdraws that refusal on the right grounds: "the refusal does not survive the objection that a later turn's direction may depend on the tokens an earlier turn generated", and the fidelity audit's Finding 6 condemned "a computability rationale dressed as a semantic one". Chapman–Kolmogorov is bind; the matrix of `w >>= k` is a well-defined countable sum over a complete semiring. `Mat.dependentSeq` realizes it (`Meaning.lean:279`, `muS_bindT`). Nothing to fix here except the *grade* that surrounds it (§2.C).

---

### 2.C — The grade

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| C1 | `abbrev Frag := ℕ∞` — `Frag.lean:119`; `static = 0`, `bounded n = n`, `monadic = ⊤` — `:126,130,135` | `data Cost = Finite !Int \| Unbounded` — `Cost.hs:38`; `addCost`/`mulCost` — `:42,46`; `FUnfold _ _ -> Unbounded` — `:87` | **INHERITED** |
| C2 | The grade as a *type index* on `Term` — `Term.lean:115` | `Flow`'s wall is the *absence* of `arr` and `Monad` — `Flow.hs:5–11`; self-identified as the same wall at `doc/PLAN.org:1637` | **INHERITED** |
| C3 | `Frag.copies = max 1 f`, `Frag.scale n f = n * copies f` — `Frag.lean:144,159` | `mulCost (boundMax b)` / `mulCost (fuelMax f)` — `Cost.hs:83–86` | **INHERITED** |
| C4 | `Term.peak`, `writtenSites`, `peak ≤ writtenSites * copies` — `Meaning.lean:1436,1461,1502` | `NONE` | **INHERITED** (as a symptom; see below) |

**The argument.** Trace where `Frag`'s numeric payload comes from. Every constructor is grade-`0` (`prim`, `pureT`), grade-transparent (`gateT`, `scopeT`, `shareT`, `retryT`), a join (`seqT`, `sumT`, `choiceT`), a sum (`parT`), or `⊤` (`bindT`). **Only `fanT` ever introduces a finite non-zero grade** (`Term.lean:254`), and only `bindT` ever introduces `⊤`. So `Frag`'s entire ℕ∞ content is `fanT`'s syntactic `n`, propagated by `⊔`, `+` and `*`. That is `Cost.hs`'s `worstCaseCost` — `addCost` for `FSeq`/`FPar`, `mulCost boundMax` for `FTraverse`, `Unbounded` for `FUnfold` — lifted out of a runtime fold and into a type index. The lift is precisely what `doc/PLAN.org:1637` says it is: "our Frag grading formalizes their wall".

The specification's own instruments then refute it, and to its great credit it publishes the refutation:

- `peak_not_le_grade` (`Meaning.lean:1636`): `peak t ≤ f` is **false**, in both directions. `dupPair` has two consultations in flight at grade `static`; `fanT 7 (pureT id)` has zero at grade `bounded 7`.
- `grade_zero_not_indep` (`Meaning.lean:1796`): a grade-`0` term's meaning *does* depend on the world, whereas a `peak`-`0` term's does not (`muExt_indep_of_peak_eq_zero`, `:1704`).
- What survives is `peak t ≤ writtenSites t * Frag.copies f` (`:1502`) — an inequality with a second, syntactic factor doing most of the work.

By the doctrine, a failed morphism is the most valuable output and is never a reason to weaken the specification (`Kernel:59–70`). The diagnosis here is row 4 of the repair table: *a whole class that cannot be instantiated at all — the representation is wrong for that job.* `Frag` has no denotation, so `grade` cannot be a homomorphism into anything, so the index carries a claim that the model cannot make good.

**The alternative, and it is exactly what the owner asked for.** Owner directive (1): "retain monad in cases where decision branching on answers is needed, and thus statically analyze costs requires a tree structure whenever monad is genuinely involved. However, when monad is not necessary, then downgrading to applicative should be sufficient." That is not a request for a number. It is a request for a *tower of classes*, and the tower is standard:

| fragment | class | the fold | what the fold answers |
|---|---|---|---|
| static | `Applicative` | the `Const M` applicative homomorphism | **exact** |
| bounded | `Selective` | `branch` over-approximates: both arms | **honest over-approximation** |
| monadic | `Monad` | none: `Const M` is not a `Monad` | **"no a-priori cost", truthfully** |

The trichotomy `static / bounded / monadic` is reproduced *from standard classes*, with no arithmetic, no `scale`, no `copies`, no `max 1`. And the reason the fold exists in the first two rows is a theorem everyone already has: the free applicative on `Q` is the free monoid on `Q`, so `shape : Ap Q α → List Q` is a monoid homomorphism, and a cost fold is `shape` followed by the leaf pricing. In morphism form:

```
[[pure a]]_M      = 1                          -- the monoid unit
[[f <*> x]]_M     = [[f]]_M * [[x]]_M          -- Const M is an Applicative
[[ask q]]_M       = price q
[[branch c l r]]_M = [[c]]_M * ([[l]]_M + [[r]]_M)   -- Selective; `+` is the semiring's alternation
[[t >>= k]]_M     = ⊥                          -- no such homomorphism exists, and that is the content
```

Two further symptoms confirm the index is over-built. `Term.lean` needs `castGrade` (`:278`) and `toMonadic` (`:296`) — transport and weakening machinery that exists solely to move terms between indices that denote nothing. And every literal workflow whose stored sub-grades mention `⊔` is `noncomputable` (`Term.lean:323, 347, 353, 360, 366, 380`), because `⊔` on `ℕ∞` comes from a noncomputable complete lattice. A *written workflow* that cannot be constructed by computation is an unmistakable sign that the index is carrying weight the meaning never assigned it.

`Term.peak` (C4) is INHERITED only in the sense that it is a repair-in-place for a defect that should have been repaired at the model. It is a good fold — it is anchored to `muExt` (`:1704`), which is exactly right — but a count of consultations in flight is a *quantity*, and quantities in this design live on transitions in a semiring (`doc/design.html:184`, "width is a monoid fold, not a semiring factor"). The whole of Stage 2b is a second, parallel instrument built beside `muS` because `muS` cannot see width. Under the applicative/selective account, width is `[[·]]_M` at the `Width` monoid that `Keys.lean` already defines (`Keys.lean`, `Width` as `SupMon ℕ`), computed by the same homomorphism as cost. One instrument, two carriers.

---

### 2.D — The quantitative meaning

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| D1 | `Mat S ι κ = ι → κ → S` over arbitrary index types, with `csum` — `Matrix.lean`, `Semiring.lean` (`CompleteCSemiring`) | `Cost = Finite Int \| Unbounded`, one hard-coded semiring — `Cost.hs:38`. `doc/design.html:177` lists "parameterize the semiring" as rebuild item #1 | **FORCED** |
| D2 | `muS : Interp → Term → Scoped G (Mat S i o)` — `Meaning.lean:175`, twelve clauses each `rfl` | `worstCaseCost :: Rooted -> Cost` — `Cost.hs:52`, a fold over the reified skeleton | **FORCED** (that it is a homomorphic fold), **INHERITED** (the clause list, via A3) |
| D3 | `Interp Op G S := G → {a b} → Op a b → Mat S a b` — `Meaning.lean:121` | The backend/model registry; `LeafRunner`'s `Scope` argument — `Interpret.hs:78` | **INDIFFERENT** |
| D4 | `muS (shareT l t) = muS t` — quantitative transparency, `Meaning.lean:261` | `FShare _ a -> go a` — `Cost.hs:80` (identical transparency) | **INHERITED** |
| D5 | Carriers: `Prop` (possibility), `Cost = Multiplicative (WithBot ℕ∞)`, Viterbi, `SqZero P M` (expectation) — `Instances.lean:76,236,…` | `Cost` only — `Cost.hs:38` | **FORCED** (the list), **INDIFFERENT** (the encodings) |
| D6 | `CompleteCSemiring` / `StarSemiring` as survivors — `Semiring.lean` header | `NONE` | **FORCED** |

**D1/D2/D5/D6 — the specification's strongest territory.** The argument that pairs `(kernel, cost)` do not compose because the second stage's cost depends on the first stage's output, and that the quantity therefore lives on the transition (`doc/design.html:154`), is a genuine failed-morphism repair in Elliott's sense, and everything downstream of it — matrices over a complete semiring, Chapman–Kolmogorov as composition, retry as a star, `x* = ∞ unless x = 0` at worst-case cost as the derivation of "every cycle must pass a bounded node" — is derived rather than asserted. The `Matrix.lean` header's survivor argument (Mathlib's `Matrix` product needs `Fintype`; every index here is an arbitrary `Type`) is exactly the discipline the doctrine asks for: name what the library lacks, and take everything else from it. Same for `CompleteCSemiring` and the `Prop`-mixin form of `StarSemiring`. These rows are not contaminated and should be preserved verbatim under any rebuild.

One small INDIFFERENT note on D5: `Cost := Multiplicative (WithBot ℕ∞)` with `+ = max`, `* = (+)` is the max-plus tropical semiring, for which Mathlib has `Tropical` (on the order dual). `Instances.lean` argues for a `def` on instance-control grounds, which is a legitimate reason to keep a private carrier; the row is INDIFFERENT and stays.

**D4 — the shared consultation is billed twice.** `muS` is transparent to `shareT`, so `muS_dupPair_eq_sharedPair` is `rfl` (`Meaning.lean:2769`): a workflow that asks once and reads twice has *literally the same matrix* as one that asks twice. `Meaning.lean:67–86` is candid about it — "until it lands the quantitative layer over-charges sharing by exactly the number of extra reads" — and records the obstruction as `acat-qtv`: "a matrix has no room to record a site". `Cost.hs:80` has the same transparency for the same reason. This is not a small gap; §6a's whole point is that "share costs one, dup costs two", and half of the design's headline distinction is therefore unpriced.

The obstruction is not real. It is an artefact of the label representation. Under a binding presentation, `share` and `dup` are *different terms in the free applicative* — `ap q (pure (fun a => (a,a)))` versus `ap q (ap q (pure Prod.mk))` — with different shapes (`[q]` vs `[q,q]`), so the monoid fold prices them differently with no site-indexed carrier and no second fold. `acat-qtv` closes by deleting labels, not by building a free semimodule on `Key`.

---

### 2.E — The extensional meaning

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| E1 | `Runner Op G L := G → Key L → {a b} → Op a b → a → Option b` — `Meaning.lean:669` | `type LeafRunner m = forall x y. Scope -> Op x y -> x -> m y` — `Interpret.hs:78`. The docstring at `Meaning.lean:669` says so itself: *"the runner is exactly agent-functor's `LeafRunner`"* | **INHERITED** |
| E2 | `muExt : Runner → Term → G → Key L → i → Option o` — `Meaning.lean:832` | `runPure :: Oracle -> Flow a b -> a -> b` — `Normalize.hs:88` (total, unkeyed) | **INHERITED** |
| E3 | `Option` as the outcome; `parT` left-first short-circuiting — `Meaning.lean:890` | fail-fast; `concurrentStrategy` — "a throwing branch cancels its siblings, matching the sequential first-failure behaviour" — `Interpret.hs:100–101` | **INHERITED** |
| E4 | `sumT` leftmost-defined via `orElse`, breaking the symmetry `muS` has (`Mat.matAdd_comm`) — `Meaning.lean:~820`, documented as "a genuine departure" | `NONE` (no alternation in `Flow`) | **INHERITED** |
| E5 | `Env C O := C → O`, `pin = Function.update`, `share_ne_dup` — `Env.lean:64,88,336` | `NONE`; `ForkSet` as a store edit, criticized at `doc/design.html:177` | **FORCED** (the object), **INHERITED** (its disuse) |

**E1/E5 — the environment was designed and then not used.** `doc/design.html:71` fixes the extensional parameter: "Environment — `ε : I → Outcome`, one complete answer sheet for every consultation the run could make — a sample point; the measure over E sits at the edge." `Env.lean` builds exactly that object and proves the two theorems the design draws from it: `cached_eq` (`Env.lean:259`) and `share_ne_dup` (`:336`). Then `muExt` does not take an `Env`. It takes a `Runner`, and `Meaning.lean:669` gives the reason: "`Agentic.Env`'s `Env C O` assigns one outcome type `O` to every consultation, while an `Op a b` answers in `b` and the `b`s vary from leaf to leaf; bridging the two requires either a universe of decodable answers or a dependent answer sheet, and neither belongs in the first fold."

Two things are wrong with that. First, a dependent answer sheet is one line in the host that was chosen precisely for dependent types:

```lean
def World (Q : Type → Type) : Type 1 := ∀ {α}, History → Q α → α
```

Second, the choice is not cost-free, it is the choice that kills the design's promised projection. A `Runner` is a rank-2 dependent function — an interpreter. You cannot put a probability measure on the type of interpreters (and §2's own hypothesis, `doc/design.html:62`, exists to make the measure live on `E ≅ [0,1]ℕ`). So §3's π — "the probability factor of ⟦w⟧S is the pushforward of ⟦w⟧ext along the measure on E" — has no `E` to push forward along. `Meaning.lean:29–38` reports a fibration failure, but reports a *different* one: that `muS` does not factor through the extensional quotient (true, and expected, since cost is not an extensional invariant — `one_add_one_of_muS_respects_WEq`, `:2814`, shows a quantitative meaning that respected extensional equality would force `1 + 1 = 1`). The projection §3 actually promised was never attempted and cannot be, in the representation chosen. That is the ledger's sharpest causal claim: **an implementation-shaped parameter displaced the design's central object, and the design's central theorem went with it.**

Consequence worth flagging for anyone acting on `doc/PLAN.org:1290`, which proposes making `Workflow` (the quotient) the author-facing type: `one_add_one_of_muS_respects_WEq` says no cost fold descends to that quotient. Making the quotient author-facing removes the instrument owner directive (1) exists to preserve. The quotient is the right home for *equational reasoning*; the term is the right home for *analysis*; they should not be the same type.

**E3/E4 — the biases.** `muExt` at `parT` runs the left branch first and never runs the right if the left refuses; `sumT` takes the leftmost defined alternative. Both are honestly documented as departures (`Meaning.lean:890`, and the `sumT` note in the `muExt` docstring), and the second is admitted to contradict `Mat.matAdd_comm`. The doctrine's diagnostic (`Kernel:66`): *a bias or ordering silently lost — the element type of the model is wrong; wrap the element so the bias is in the signature.* The repair is standard and it unifies two meanings into one: let the extensional meaning be **relational**, `i → Set o` (equivalently `Mat Bool i o`, equivalently the possibility carrier). Then `sumT` is union and is commutative; `parT` is the product of sets and is symmetric; `gateT false` is `∅`; and the extensional meaning is no longer a second kind of object but *the quantitative meaning at the Boolean semiring, under a world reader*. `Option` was chosen because a runner returns one answer, i.e. because of E1. Delete E1 and E3/E4 delete themselves.

---

### 2.F — Scope

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| F1 | `Scoped G R := G → R`; `withScope g f = actR g f` — `Scope.lean:252,262` | The interpreter threads `Scope` as its only context — `Interpret.hs:173` | **FORCED** |
| F2 | `LastOpt α := Option α` with right-wins `*` — `Scope.lean:86–139`; `Scope μ α` the product of axes — `:158` | `applyScope (ModeScope m) sc = sc {scopeMode = m}` — `Op.hs:222–224`, "Innermost wins, __per axis__" | **INDIFFERENT** |
| F3 | `scopeT` as a *constructor* — `Term.lean:178` | `WithScope` as a *constructor* — `Flow.hs:119` | **INHERITED** |
| F4 | `innermost_wins`, `axis_independence` as theorems — `Scope.lean:298,313` | `applyScope`'s per-axis record update, asserted in a docstring | **FORCED** |

The Reader account is right and the theorems are real wins: innermost-wins is the `Last` monoid rather than an interpreter rule, and axis-independence is bifunctoriality of the product (`Scope.lean:29–37, 313`). `Scope.lean`'s survivor note — Mathlib has `WithOne` but no right-zero semigroup to feed it — is the correct discipline. F2 is INDIFFERENT: the mathematics permits any monoid of scope-updates (the maximally general choice is the monoid of endomorphisms of the environment, of which `LastOpt`-per-axis is a submonoid); `Term` correctly leaves `G` abstract with no structure demanded (`Term.lean:20–24`), so nothing is over-committed.

F3 is the inherited row, and the argument against it is the specification's own. `Term.lean:92–100` refuses a weakening constructor on the ground that "if a later stratum wants `Term f i o → Term g i o`… that is a **fold** over the term, defined where the recursion's target lives, not a constructor. Adding it here would put a second term with the same meaning into the syntax and make every fold prove it respects the relabelling, for no gain." Every word of that applies to `scopeT`. Pushing a scope inward is a fold: `muS (scopeT h t) g = muS t (g * h)` (`:253`) says precisely that scoping distributes into every clause, so `scopeT h t` has the same meaning as the term with `h` composed into each leaf's scope. If the leaf signature carries its addressee — and `doc/design.html:84` already says it should: "Command / Skill / Agent / Sub-agent — **not types**: a scoped leaf; a context transformer; a scoped leaf at reset index… four domain nouns, zero new objects" — then `under g` is surface sugar over that fold, and `Step.scope`, the `scope` clause of both meanings, the `g * h` threading, and `WEqR_scopeT_unit` all go away.

---

### 2.G — Sharing, labels, sites, keys, and the quotient

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| G1 | `L : Type` sharing labels, no structure demanded — `Term.lean:26–31` | `newtype Label = Label Text` — `Flow.hs:80` | **INHERITED** |
| G2 | `Step` (14 constructors), `Site := List Step` — `Meaning.lean:450,486` | The interpreter's `[Int]` structural path; `mkRunId (label, child-ids, path)` — `Interpret.hs:263`; `renderKey` — `Skeleton.hs:130` | **INHERITED** |
| G3 | `Key L = abs Site \| rel L Site`, `rebase l = .rel l []` — `Meaning.lean:535,558` | `rsLabels`/`rsActive` label→(NodeId, Rendered) tables; label collapse — `Skeleton.hs:104–110, 289` | **INHERITED** |
| G4 | `Relabels σ ↔ ∀ l s, σ (rel l s) = rel l s` — `Meaning.lean:682` | `NONE` | **INHERITED** |
| G5 | `WEq` (fine), `WLe`, `WEqR` (quotient-up-to-relabelling) — `Meaning.lean:1909,1965,2004`; `Workflow` — `:2498`; `staticCategory` — `:2713` | `render`/`Rendered` structural equality — `Normalize.hs:60`; normalising `seq'` making "Category laws hold on the nose" — `Flow.hs:220–224` | **INHERITED** |
| G6 | `acat-bmc`: one label over two different bodies collides; "the designer's obligation, not a checked property" — `Term.lean:80,183,200` | `ShareCollision` — an *enforced* check via `renderKey` body comparison — `Skeleton.hs:113, 203–235` | **INHERITED** (and strictly weaker than the precedent) |

**The argument, and it is the ledger's centre.**

What the meaning forces is exactly one sentence, and `Env.share_ne_dup` (`Env.lean:336`) proves it: *the index at which the environment is consulted is part of the meaning; asking once and copying is not asking twice.* Equivalently, copy is not natural (Fritz Def. 10.1), so the meaning category is a Markov category and not Cartesian — `doc/design.html:119, 138` gets this exactly right and refuses to instantiate `Cartesian`.

What the meaning does **not** force is a syntactic namespace of labels, a positional path type, a two-constructor key, a class of key-relabellings, a runner-renaming operation, a preorder `WLe`, its antisymmetrization `WEqR`, and a quotient — roughly a thousand lines of `Meaning.lean` and the entirety of Stage 3.

The reason all of that exists is that `Flow` is **point-free**. In a profunctor optic there is no way to say "use this value twice"; you can only make a node be the same node, which requires naming nodes, which is `Share Label`. `Flow.hs:74` states the purpose plainly: "A repeated label collapses two occurrences to one skeleton node." And the purpose *of the purpose* is inspectability — `Flow.hs:8–9`, "static inspectability is what every other feature depends on" — which serves `agent-functor plan`, the TUI, and the run graph. Those are facts about a machine, and the doctrine's rule 2 (`Kernel:110`) says to suspect exactly them.

In a *binding* presentation, sharing is `let`:

```lean
-- one consultation, read twice
do let guide ← ask style
   pure (guide, guide)

-- two consultations
do let g₁ ← ask style
   let g₂ ← ask style
   pure (g₁, g₂)
```

These are different terms of `Free Q` / different terms of `Ap Q` (shapes `[style]` and `[style, style]`), they have different matrices at every carrier including Cost (closing `acat-qtv`, D4), and they have different extensional meanings under any world — with **no labels, no sites, no keys, no relabellings, no quotient, and no unchecked designer obligation.** The specification's own tracker already reached this conclusion: `doc/PLAN.org:1299` records "**SHARING IS BINDING**: `let guide <- ask ...` used twice = one consultation — the surface needs no labels; shareT/labels remain the point-free representation underneath (bears on acat-0vv/bmc/d1t)." The alternative is known, is written down, and is retained anyway because `Flow` has `Share`.

Three further observations sharpen the verdict.

*G4 and G5 exist only to undo G2.* `WEq` — "no runner, at any scope, from any key, can tell them apart" — is the design's stated equality (§3: "Semantic equality is equality of ⟦·⟧ext"). `Meaning.lean:1938–1946` then reports that `WEq` is *too fine to be the equality of a category*: associativity of `seqT`, the units, and the absorption of an open gate all fail, because every structural rearrangement moves a positional key. That is a failed morphism of the first magnitude — the meaning function distinguishes terms that the design says are equal — and the repair chosen is to coarsen the equality by quantifying over site-relabellings that fix labelled keys. Under binding, no rearrangement moves any index, `WEq` is already a congruence, and Stage 3 is `Quotient (Setoid.ker denote)` in the one line `doc/design.html:165` promised.

*G6 is strictly weaker than its own precedent.* `agent-functor` **checks** body agreement: `toSkeletonEither` compares `renderKey body` against the stored key and returns `Left (ShareCollision lbl)` (`Skeleton.hs:113, 235`). `agent-cat` declines to compare bodies at all — "the fold rebases on the label **alone**" (`Term.lean:78`) — and books the resulting collision as a designer obligation (`acat-bmc`). The doctrine's anti-pattern 9 (`Kernel:82`): "An invariant maintained by documentation, assertions, or 'callers must ensure…'. Make the constrained type an *object* and constraint-preservation a *component of the morphism*." Inheriting a mechanism and dropping the check that made it safe is the worst of the three available positions.

*The keying decisions are visibly conservative guesswork.* `Meaning.lean:426–444` explains why `retry trip` and `fan ix` key each iteration separately ("the conservative reading is the safe one"), why there is no `share` step, and why `bindL`/`bindR` must be two steps rather than one (otherwise "the two continuations would then collide on the very same key"). Each is a correct local judgement; collectively they are a reminder that the whole apparatus is a hand-built naming scheme for something a binder gives for free — and that `Meaning.lean:438` still leaves open (`acat-0vv`) whether a labelled body under a loop should be asked once or once per trip, a question that under binding is answered by where the `let` sits.

---

### 2.H — What was designed and never reached the syntax

| # | Spec element | agent-functor precedent | Verdict |
|---|---|---|---|
| H1 | The panel: monoid semiring `S⟨K⟩`, convolution, `conv_delta`, the two scheduler licences — `Panel.lean`; keys — `Keys.lean` | `exploreWith`/`mergeWith` — `Combinators.hs:90,128`; reducers `unionFindings` (free monoid, `:377`), `hierarchical` (`:400`) | **FORCED** (the algebra) |
| H2 | No `panelT` constructor; `parT` is "juxtaposition only" — `Meaning.lean:166` (`acat-x9v`) | `TraversePositions` + an explicit reducer function | **INHERITED** (the omission) |
| H3 | `Context`: compaction as an interior operator, Atkey-parameterised indices — `Context.lean` | fresh-session-per-leaf, `κ = const ε`, held as a documented contract — criticized at `doc/design.html:177` | **FORCED** |
| H4 | `Trace` (Mazurkiewicz), footprints, the premonoidal defect | `ParStrategy` — two realizers of one tensor — `Interpret.hs:88` | **FORCED**, unreached |
| H5 | `pin` / fork / Brzozowski derivative — `Env.lean:88`; no `pinT` (`acat-vgz`) | `ForkSet` as a store edit — criticized at `doc/design.html:177` | **FORCED**, unreached |

The pattern across H1–H5 is worth naming because it is the doctrine's own warning about denotationally-designed code (`doc/design.html:168`): "the mathematically prettiest modules are the ones still unwired." `Panel.lean` derives the design's headline solved form — the deltas collapsing to convolution, `δ a ⋆ δ b = δ (a * b)`, and the two scheduler licences distinguished (commutative keys let members be exchanged; idempotent keys let a certain member be duplicated) — and no term can invoke it. `Context.lean` gives compaction its interior operator and no term is indexed by a context. `Env.pin` is counterfactual substitution and no term can fork.

Under the applicative account, H1 requires no constructor at all: `panel : List (F V) → F V` for `[Monoid V]` is `List.foldr (liftA2 (*)) (pure 1)`, i.e. `List.prod` under the applicative, and the convolution theorem becomes a type-class-morphism theorem about it. `doc/PLAN.org:1290` reaches this too ("reviewers form a Monoid pointwise from Verdict… panel := List.prod"). H5 likewise: with a `World` parameter rather than a `Runner`, `pin` is `Function.update` applied to the meaning's argument, and forking is a substitution theorem, exactly as §6d says.

---

## 3. Anti-correspondences: where the specification already diverged, and what drove it

Divergence is the evidence of independent thought, so it deserves as careful a reading as convergence.

**3.1 `pureT` against `Flow`'s no-`arr`.** Driven by a correct identification of the constraint's nature. `Flow.hs:8` gives a machine reason (inspectability for `plan`/TUI); `Term.lean:126` gives a meaning (a Transform is a point matrix, central by construction). The specification also killed the audit's competing reading — "Transform as monoid endomorphism forces compaction to emit only empty prompts" (`doc/design.html:154`) — by a three-line size argument. This is denotational design working as advertised: an inherited prohibition examined, found to be about a machine, and dropped. **Generalize the move**: the same test applied to `Share`, to `TraversePositions`'s mandatory `Bound`, and to `LoopUntil`'s `Fuel` gives the same answer, and was not applied.

**3.2 `bindT` against `Flow`'s no-`Monad`.** Driven by an owner objection ("a later turn's direction may depend on the tokens an earlier turn generated") and by the fidelity audit's Finding 6 ("a computability rationale dressed as a semantic one inverts 'meaning constrains implementation'"), `doc/design.html:117, 216`. Correct, and the most important single correction in the design's history. **But the correction stopped at the constructor.** The instrument that `bind` costs was then reintroduced as a numeric type index (§2.C) rather than as the class tower the objection actually implies, so the same computability rationale returned wearing an index's clothes: `Frag`'s job is to say which terms an a-priori fold can measure, and it says it with a number that the repo's own theorems show measures nothing.

**3.3 Matrices against `Cost.hs`'s fold.** Driven by the failed equation "cost as a pair-component does not compose" (`doc/design.html:154`, called "the best single page in the three drafts"). Genuinely independent, genuinely forced, and the specification's most valuable asset. Note what it cost `agent-functor` not to have it: `Cost.hs` hard-codes its semiring, so `doc/design.html:177` correctly lists "parameterize the semiring" as rebuild item #1, and the same document at `:184` derives width as a monoid fold rather than a semiring factor. All of that is right.

**3.4 `choiceT` as a copairing against `LeftF`/`RightF`.** A mild generalization, driven by having a coproduct in the meaning category. Right direction, insufficient distance: the standard class is `Selective`.

**3.5 `Frag` against `Flow`'s constructor-absence wall.** A divergence in *form* that preserves the *content*: `doc/PLAN.org:1637` says so ("our Frag grading formalizes their wall"). Formalizing a wall is not the same as asking what the wall is for.

**3.6 `Op` abstract against `Op`'s three fixed constructors.** A clear improvement — the syntax is parametric in the leaf signature and does not know Prompt/Exec/Ask. Undercut only by keeping the bidirectional shape (A2).

**3.7 `Unfold` not inherited.** `Flow.hs:135`'s recursive decomposition (depth-bounded, width-unbounded, the source of `Cost.hs`'s `Unbounded`) has no counterpart in `Term`. Correct: it is `bindT` plus recursion, and refusing to add a constructor for it is consistent with the no-weakening-constructor principle. This is the one place where the principle was applied to an inherited construct.

---

## 4. The kernel proposal

Stated as the doctrine requires: meanings first, one equation per operation, standard classes recognized, and nothing named that a class already supplies. This is the shape a rebuilt specification would take; it is offered as the ledger's constructive half, not as a design decree.

### 4.1 Types and their meanings

```
Q : Type → Type
  a `Q α` is a representation of one CONSULTATION whose answer lies in α.
  Model call, tool invocation and human question are three inhabitants of one Q;
  the answer type is part of the question, so no decoding universe is needed.

[[W : Type 1]]  -- the world
  a World is a representation of ONE COMPLETE ANSWER SHEET:
      World Q  =  (h : History) → ∀ {α}, Q α → α
  History is the sequence of consultations already made with their answers.
  History-indexing is what makes a second draw a second draw; it is the
  design's `ε : I → Outcome` with I = occurrences, and it is a VALUE, so the
  measure of §2 can sit on it.

[[F Q α]]  -- a workflow answering in α, at three fragments
  Ap Q  ⊂  Sel Q  ⊂  Free Q      (free applicative ⊂ free selective ⊂ free monad)

  [[t : Ap Q α]]   = Σ (qs : List Q), (Answers qs → α)      -- shape × continuation
  [[t : Sel Q α]]  = the same, with the shape a decision TREE over ⊕-verdicts
  [[t : Free Q α]] = World ⇀ α                              -- a partial function of the world

[[·]]_S : F Q α → Mat S Unit α        -- the quantitative meaning, one per carrier S
  Mat S ι κ = ι → κ → S, S a complete commutative semiring;
  composition is Chapman–Kolmogorov with csum over an arbitrary index type.

[[·]]_ext : F Q α → World ⇀ α         -- the extensional meaning, one value per world
```

Equality is `[[·]]_ext`, full stop — `t ≈ u ⟺ ∀ ω, [[t]]_ext ω = [[u]]_ext ω`. No coarsening is needed because no meaning mentions a position.

The three fragments are the owner's directive as a tower of standard classes: use `Ap` when nothing branches, `Sel` when a verdict steers but the shape is fixed, `Free` when an answer chooses the shape. The grade is *which type the term inhabits*; there is no arithmetic and no index.

### 4.2 The derived API, one morphism equation per operation

```
Functor / Applicative (both meanings)
  [[pure a]]_ext ω        = a
  [[f <*> x]]_ext ω       = ([[f]]_ext ω) ([[x]]_ext ω)          -- with ω threaded left-to-right
  [[pure a]]_S            = δ a                                   -- the point mass
  [[f <*> x]]_S           = [[f]]_S ⊛ [[x]]_S                     -- convolution / Kronecker-then-apply

Consultation (the one generator)
  [[ask q]]_ext ω         = ω h q                                 -- h the history at this point
  [[ask q]]_S             = price q                               -- the Interp of Meaning.lean:121

Alternative  (replaces sumT AND gateT; supplies the missing additive zero)
  [[empty]]_S             = 0
  [[t <|> u]]_S           = [[t]]_S + [[u]]_S
  [[empty]]_ext ω         = ⊥                                     -- refusal is partiality
  gate b t                := if b then t else empty               -- LeftSemimodule row, DERIVED

Selective  (replaces choiceT; buys value-dependence at applicative cost)
  [[branch c l r]]_S      = [[c]]_S · ([[l]]_S ⊕ [[r]]_S)         -- block matrix; over-approximation

Traversable  (replaces fanT; no constructor, no bound in the syntax)
  [[traverse f xs]]_S     = ∏_{x ∈ xs} [[f x]]_S
  -- the a-priori width/cost of a traversal is a FUNCTION of xs, which is the truth.
  -- A number is wanted ⇒ bound the TYPE (Vector i n), not truncate the meaning.

Star / retry
  [[loop t]]_S            = ([[t]]_S · d)* · exit                 -- design §5.2, unchanged
  revising n t            := the n-th truncation, DEFINED from the star and gate

Reader (scope)
  scope is carried by the leaf: Q' α = G × Q α
  under g t               := the fold that composes g into every leaf's scope
  [[under g t]]_S h       = [[t]]_S (h * g)                        -- theorem, not clause

Monad (the top fragment only)
  [[t >>= k]]_S           = Σ_b [[t]]_S(⋆,b) · [[k b]]_S(b,·)      -- Chapman–Kolmogorov
  [[t >>= k]]_ext ω       = [[k ([[t]]_ext ω)]]_ext (ω after t)

Panel (no constructor; recognized structure)
  panel : List (F V) → F V  for [Monoid V] := List.foldr (liftA2 (*)) (pure 1)
  [[panel rs]]_S          = convolution fold in S⟨V⟩                -- Panel.lean's theorem, now reachable

Analysis (the fold owner directive (1) asks for)
  [[·]]_M : Ap Q α → M     for a monoid M — the Const applicative homomorphism
  exists for Ap (exact), for Sel (over-approximating), and PROVABLY NOT for Free.
```

### 4.3 What survives from `agent-cat` unchanged

`Matrix.lean` (`Mat`, `comp`, `kron`, `caseMat`, `dependentSeq`, the arbitrary-index `csum`), `Semiring.lean` (`CompleteCSemiring`, the `Prop`-mixin `StarSemiring`, `KleeneAlgebra.ofSupDistrib`), `Star.lean` (`retry_fixed`, `retry_least`, the cost-boundedness lemmas), `Gate.lean` (the scalar action and its annihilation theorems — now the semantics of `empty` and `gate`), `Instances.lean` (all four carriers), `Panel.lean` and `Keys.lean` (the convolution algebra and its inhabitants), `Context.lean` (the interior operator), `Env.lean`'s `pin` (now applied to `World`), and `Scope.lean`'s `LastOpt` monoid. That is the majority of the mathematics and essentially all of the derivation. What the rebuild deletes is the syntax stratum, the grade, the site/key/relabelling apparatus, and Stage 3.

### 4.4 What the rebuild must prove that the current one does not

1. `[[·]]_S` is an `Applicative` / `Selective` / `Monad` morphism at every carrier — one theorem per equation above, each a `rfl` or a short calculation, exactly as `muS_*` already are.
2. The analysis homomorphism `[[·]]_M` exists for `Ap` and `Sel` and does not for `Free` — the honest form of the grade, and a *theorem* rather than an index.
3. `share ≠ dup` — now a corollary of shape inequality, not a design axiom needing a labelled key.
4. π: the possibility factor of `[[t]]_Bool` is the image of `[[t]]_ext` over worlds, and the probability factor is the pushforward along the measure on `World`. This is §3's promise, and it is stateable only once the parameter is a value.

---

## 5. The ten most load-bearing INHERITED verdicts, ranked by how much of the library they infect

Ranked by the number of declarations and design decisions that would change if the row were repaired. Line counts are of `agent-cat`.

**1. The point-free profunctor spine — `Term` as an arrow calculus over `Op i o` rather than a free applicative/selective/monad over a question functor `Q α`.**
`Term.lean:115`; precedent `Flow.hs:88` and the constructor-for-constructor mapping at `doc/PLAN.org:1637`. Infects: all 535 lines of `Term.lean`, all 2831 of `Meaning.lean`, the grade, the sites, the quotient, and every combinator the surface must define (`example/Combinators.lean`, four rounds of owner rejection at `doc/PLAN.org:1213–1299`). Alternative: §4.1. Everything below is a consequence of this row.

**2. Label-keyed `shareT`, and the `Step`/`Site`/`Key`/`Relabels`/`Runner.rename` apparatus built to give it a meaning.**
`Term.lean:216`, `Meaning.lean:450, 486, 535, 558, 682, 709`; precedent `Flow.hs:80, 105` and `Skeleton.hs:104–235`. Infects: ~1000 lines of `Meaning.lean`, `acat-bmc` (an unchecked designer obligation that the precedent *does* check), `acat-qtv` (the unpriced half of §6a), `acat-0vv` (the open ask-once-across-trips question), `peak`'s admitted over-count (`Meaning.lean:1673`), and the existence of Stage 3. Alternative: sharing is `let`-binding; the specification's own tracker says so at `doc/PLAN.org:1299`.

**3. `Runner` in place of the design's `Env` — an interpreter where a sample point was specified.**
`Meaning.lean:669`, whose docstring says "the runner is exactly agent-functor's `LeafRunner`"; precedent `Interpret.hs:78`. Infects: the type of `muExt` and every one of its 30-odd theorems; `WEq`'s quantification (over runners rather than worlds); `Env.lean`'s theorems, which are proved about a separate toy `Ext` type and never reach the fold; and §3's projection π, which becomes unstateable because there is no measurable `E`. Alternative: a dependent `World`, one line in Lean.

**4. `Frag = ℕ∞` as a type index — `Cost.hs`'s worst-case fold promoted into the type of every term.**
`Frag.lean:119`, `Term.lean:115`; precedent `Cost.hs:38–87`, self-identified at `doc/PLAN.org:1637`. Infects: the type of all twelve constructors, `castGrade`, `toMonadic`, the noncomputability of literal workflows, and the whole of Stage 2b, whose punchline is `peak_not_le_grade` (`Meaning.lean:1636`) — the index does not bound the quantity it is named after. Alternative: the `Applicative < Selective < Monad` tower, which reproduces the trichotomy from standard classes and delivers owner directive (1) as a theorem about the existence of a `Const M` homomorphism.

**5. `fanT n` — a syntactic width bound whose meaning truncates the input.**
`Term.lean:254`, `Meaning.lean:~193`; precedent `Flow.hs:123` + `Normalize.hs:105` (`boundedFocus`). Infects: `Frag`'s entire numeric payload (it is the only source of a finite non-zero grade), `Frag.copies`/`scale` and their `max 1`, `fanMat`, `fanRun`, the truncation lemmas, `peak`'s fan clause, and the semantic falsehood that a nine-file input to an eight-wide fan denotes eight reviews. Alternative: `traverse`, with cost a function of the input and boundedness a property of the input *type*.

**6. `WEqR`, the quotient up to site relabelling.**
`Meaning.lean:1965, 2004, 2498, 2713`; precedent, in spirit, `Normalize.hs:60` (`render` structural equality) and `Flow.hs:220` (normalising `seq'` making "Category laws hold on the nose"). Infects: ~900 lines, including `muExt_transport`, `WEqR.of_shift`, every congruence, and the `Category` instance. Exists solely because positional keys make `WEq` too fine to be a congruence — i.e. it is entirely a consequence of row 2. Note the hazard for `doc/PLAN.org:1290`'s proposal to make this quotient author-facing: `one_add_one_of_muS_respects_WEq` (`Meaning.lean:2814`) proves no cost fold descends to it.

**7. `scopeT` as a constructor, and `Scoped` as a wrapper around every meaning.**
`Term.lean:178`, `Scope.lean:252`; precedent `Flow.hs:119`, `Op.hs:222`. Infects: the target type of `muS` (`Scoped G (Mat S i o)` rather than `Mat S i o`), the scope argument of `Interp` and `Runner`, `Step.scope`, both folds' scope clauses, and `WEqR_scopeT_unit`. Violates the specification's own no-weakening-constructor rule (`Term.lean:92–100`): `scopeT` is a fold. Alternative: the leaf carries its addressee, as `doc/design.html:84` already prescribes.

**8. `muExt` into `Option`, with left-first and leftmost-defined biases.**
`Meaning.lean:832, 890`; precedent `Interpret.hs:100–101` (fail-fast, cancel siblings). Infects: the symmetry of `sumT` (broken against `Mat.matAdd_comm`), the symmetry of `parT`, and the possibility of a projection between the two meanings. Diagnostic: the doctrine's "a bias or ordering silently lost ⇒ the element type is wrong". Alternative: a relational meaning `i → Set o`, which *is* the quantitative meaning at the Boolean carrier, collapsing two meaning functions into one meaning at two carriers.

**9. `Op : Type → Type → Type`, the arrow-shaped leaf signature.**
`Term.lean:14–18`; precedent `Op.hs:314`. Infects: every constructor's type, the rank-2 shape of `Interp` and `Runner`, and — critically — the stated obstruction to using `Env` ("the `b`s vary from leaf to leaf", `Meaning.lean:669`), which is an obstruction only because the input index prevents `Q α` from being the question type. Alternative: `Q : Type → Type`, with the input supplied by composition. `HardenPatch.lean:18–24` writes leaves that already have this shape in all but the redundant first index.

**10. `retryT`'s fuel in the syntax, and the truncated star as the meaning.**
`Term.lean:223`, `muS_retryT` at `Meaning.lean:267`; precedent `Flow.hs:130`, `Bounds.hs` (`Fuel`), `Normalize.hs:110`. Infects: `Star.lean`'s `retryTrunc` and its finiteness lemmas, `retryLoop`, `Step.retry trip`, and the claim that a fueled loop is `.static` — a claim that only holds because the meaning was truncated to make it hold. Alternative: the star is the meaning (design §5.2's own words), divergence at the Cost carrier is the truth, and `revising n` is a defined combinator.

**Honorable mentions**, ranked below the ten because they infect less, not because they are less clear: the missing `zeroT` (`acat-1xo`) with `gateT` standing in for it; the missing `panelT` (`acat-x9v`) leaving the design's headline solved form unreachable from any term; the missing `pinT` (`acat-vgz`) leaving fork and resume unreachable; and `gateT`'s `Bool` decided in the syntax against `Gate.lean`'s deliberately undecided `Prop`.

---

## 6. What this ledger does not claim

That the mathematics is wrong. It is not: `Matrix.lean`, `Semiring.lean`, `Star.lean`, `Gate.lean`, `Panel.lean`, `Keys.lean`, `Context.lean` and the carriers of `Instances.lean` are careful, well-cited, and in several places genuinely derived rather than asserted — the retry star, the convolution collapse, the interior operator, and the matrix meaning forced by the failure of the pair-of-(kernel, cost). The contamination is not in the meanings. It is in the **syntax stratum and everything built to give that syntax a meaning**: twelve constructors chosen from a Haskell profunctor optic, a grade that formalizes that optic's constructor-absence wall, a naming scheme for consultation sites that a binder would supply for free, an interpreter standing where a sample point was specified, and a quotient built to undo the damage of the naming scheme.

The doctrine's own test is the fairest closing (`Kernel:92`): "When a library not only type-checks, but also morphism-checks, it is free of abstraction leak, and so the library's users can safely treat a program value as being its meaning." `agent-cat` morphism-checks its *quantitative* fold beautifully — every `muS_*` clause is `rfl`. It cannot morphism-check its grade, because the grade has no meaning to check against; and it cannot morphism-check its extensional fold's equality, because `WEq` is not a congruence and had to be coarsened. Both failures point at the same row: the syntax was inherited, and the meaning was made to fit it.
