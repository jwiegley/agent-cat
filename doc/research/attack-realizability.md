# Attack: Lean-4 Realizability and the Adherence Proof

> **Historical — the code audited here no longer exists (2026-08-20).** This page
> audits the pre-re-derivation stratum: `Agentic/*.lean` outside `Core/` — the `Term`
> calculus, its two meaning functions, the `WEqR` quotient and the resource algebra
> under them. All of it was excised under obr `acat-q1i`, so every `file:line` below
> that names one of those modules resolves in git history only. The results that
> stratum established are transcribed in `doc/research/term-algebra-results.md`; read
> that page for *what was proved*, and this one for the reasoning that condemned it.
> Nothing here describes the code as it stands.

**Lens.** Every proposal is judged as a Lean 4 + Mathlib artifact. Three questions are asked of
each: do the structures it names exist, or must they be hand-rolled; can the meaning-as-fold
actually be *defined* (termination, universes, elimination); and what exact Lean proposition is
its runtime-adherence theorem — the owner's Path 2 — and can it be proved without axiomatizing
`IO`.

**Thesis.** Each of the three kernels is realizable in exactly one half, and the halves are
complementary. The meaning-first `Dlg` is the only kernel whose carrier, laws, morphism
equations and adherence theorem I was able to *compile today* — I did, from nothing, against an
adversarial history-dependent agent, with no Mathlib and no axiom beyond `propext` — but its
higher-order continuation makes the owner's static cost analysis undefinable except under
`Fintype` on every answer type, which the domain does not have. The two first-order kernels keep
analysis definable and rest on three things Lean does not possess: a graded inductive whose
computed index can be eliminated (Lean rejects it; I have the error), a lawful free *selective*
functor (does not exist in the literature, only the free **rigid** one), and a quotiented-free
monad that is still a `Monad` (requires `Classical.choice`; I have the axiom print). The repair
is not a choice between them: it is a two-layer artifact, a first-order **plan** whose grade is a
*fold and not an index*, denoting into `Dlg`. And the adherence theorem should not be an axiom
about `IO` at all — it can be a **decidable per-run certificate**, which I have also compiled.

---

## 0. Provenance of every claim below

Everything marked ✅ or ❌ was executed. Toolchain: `lean 4.30.0` from
`/nix/store/jpw7rsgz1g25m00n4d4zjb8nlbplv8k0-lean4-4.30.0/bin/lean`, run against the Mathlib
build tree already present at
`/Users/johnw/src/agent-cat/.lake/packages/mathlib` (`v4.30.0`, the revision `agent-cat` pins).
The compiling sources are saved, one file per claim, in

`/Users/johnw/.config/claude/positron/projects/-Users-johnw-src-incite/b3852883-ae82-40d8-8e0b-785c0a25998e/dossier/attack-realizability-lean/`

| file | what it establishes |
|---|---|
| `A_dlg_lawful.lean` | `Dlg` in `Type 0`; `Monad` + `LawfulMonad`; `run_bind`, `trace_bind` proved |
| `B_adequacy.lean` | the runtime-adherence theorem, proved, against an arbitrary history-dependent agent |
| `C_certificate.lean` | adequacy as a **computable** per-run check; `#print axioms` is empty |
| `D_graded_index_fails.lean` | Lean **refuses** to eliminate algebra-first's graded inductive |
| `E_grade_as_fold_works.lean` | the repair: grade as a fold, `asks` total at `ap` proved |
| `F_quotient_needs_choice.lean` | quotiented-free `bind` depends on `Classical.choice` |
| `G_cost_needs_fintype.lean` | `costMax : Dlg A → ℕ` exists **only** under `[∀ c, Fintype (El c)]` |
| `H_universe_probe.lean` | the free monad over a `Type → Type` signature cannot live in `Type 0` |

Claims marked ⚠ are reasoned, not executed, and are labelled as such.

---

## 1. Ground facts about the host, checked rather than recalled

These are the facts the three documents assume. Four of the assumptions are false.

| Assumed | Reality (checked) |
|---|---|
| `FreeMonad` in Mathlib (decontaminate §7, `FreeMonad.foldMap`, `FreeMonad.hom_ext`) | ❌ **Does not exist.** `grep -rl "FreeMonad\|FreeApplicative\|FreeSelective" Mathlib` returns nothing. |
| `FreeApplicative` in Mathlib (decontaminate §3.4; ledger §4.1) | ❌ Does not exist. |
| `FreeSelective` in Mathlib (decontaminate §3.4; algebra-first §4) | ❌ Does not exist. Neither does the class `Selective`: `grep -rn "Selective" Mathlib` → 0 hits. |
| `Const S` applicative for the cost fold (algebra-first §5.3) | ✅ Exists: `Functor.Const`, `instance [One α] [Mul α] : Applicative (Const α)`, `instance [Monoid α] : LawfulApplicative (Const α)` (`Mathlib/Control/Applicative.lean:147,154`). |
| `traverse` usable for panels | ⚠ **Split.** Batteries' `List.traverse` is universe-flexible (`{F : Type u₁ → Type u₂}`) and works for any of the kernels. Mathlib's `Traversable` *class* is `(Type u → Type u)` and its `traverse` forces `m : Type u → Type u`. So `Dlg : Type → Type` inherits Mathlib's `Traversable`/`LawfulTraversable`/`foldMap` machinery; every `Type → Type 1` free structure does not, and must re-derive it. |
| A polynomial-functor free construction to lean on | ✅ `PFunctor.W` (`Mathlib/Data/PFunctor/Univariate/Basic.lean:84`) and `PFunctor.M` exist, plus univariate `QPF`. `PFunctor` is exactly the `(Code, El)` shape the meaning-first kernel already uses — the initial algebra of `P + const A` **is** `Dlg A`. This is the one free construction available off the shelf, and only the meaning-first kernel is in a position to use it. |
| `Quotient` gives a lawful-by-construction monad (algebra-first §8.1; decontaminate q9) | ❌ **Not computably.** `Quotient.out` `#print axioms` → `[Classical.choice]`; `qbind w k := ⟦T.bind w.out (fun a => (k a).out)⟧` inherits it (`F_quotient_needs_choice.lean`). A `Monad (Quotient ≈ ∘ W)` instance is necessarily `noncomputable`. |
| The runtime needs HTTP/TLS (host-lean4 §3 worry) | ✅ Not for ACP. ACP is line-delimited JSON-RPC over stdio. `Lean.Json`, `IO.Process.spawn`, `IO.mkRef`, `IO.asTask`, `Std.Channel` all `#check` clean in 4.30 core. The runtime layer is genuinely small; the thin-ecosystem worry does not bite here. |
| agent-cat's `CompleteCSemiring.csum` is universe-polymorphic | ⚠ It is `csum : {ι : Type} → (ι → S) → S` (`Agentic/Semiring.lean:122`) — `Type 0` indices only. Sufficient for `VS S A = A → S` with `A : Type 0`, which is all the domain needs, but it does not lift to a `Type 1` carrier. |

---

## 2. The universe ledger, and why it decides more than it looks

Checked in `H_universe_probe.lean`.

```lean
-- meaning-first: a small code universe, no `Type`-valued field
inductive Dlg (A : Type) : Type
  | done : A → Dlg A
  | ask  : (c : Code) → Q c → (El c → Dlg A) → Dlg A
#check @Dlg      -- Dlg : Type → Type          ✅

-- generic free monad over an arbitrary Type → Type signature
inductive FreeM (f : Type → Type) (A : Type) : Type where
  | roll : {α : Type} → f α → (α → FreeM f A) → FreeM f A
-- error: Parameter `α` has type Type at universe level 2, which is not ≤ 1   ❌
```

The bump is not cosmetic. `Type → Type 1` costs, concretely:

- **No Mathlib `Traversable`.** Panels lose `foldMap`, `sequence`, `LawfulTraversable` and every
  lemma attached to them; Batteries' `List.traverse` survives, its laws do not.
- **No `Monoid`/`Semiring`-valued instances at the workflow type itself.** Mathlib's algebraic
  hierarchy is `Type*`-polymorphic and will follow, but any structure that must live at the same
  universe as its index (the `Traversable`, `Monad`-transformer and `MonadLift` families) will not.
- **`Quotient` at `Type 1`,** so `Workflow` is `Type 1` and cannot be stored in ordinary `Type 0`
  containers (`List Workflow`, `Std.HashMap String Workflow`) without `ULift`.
- **Universe-polymorphic `Q`** is *not* an escape. `Q : Type u → Type u` makes `FreeM` land in
  `Type (u+1)`, and the `Monad` class then sits at `Type u → Type (u+1)`, which is legal but makes
  every downstream signature carry two universe variables.

`do`-notation is *not* a casualty: Lean's `Monad` is `(m : Type u → Type v)`, so `do` elaborates
for a `Type → Type 1` monad. I checked this. The blocker for grading is the *index*, not the
universe (§4).

**Consequence.** Meaning-first's decision to index questions by a small `Code` universe with
`El : Code → Type` — presented in that document as a modest hygiene note — is the single
highest-leverage engineering decision across all three proposals. It is also exactly Mathlib's
`PFunctor` shape, which is the only free construction in the library.

---

## 3. Can the meaning-as-fold be DEFINED? Proposal by proposal

### 3.1 Meaning-first (`rederive-meaning-first.md`): ✅ compiles, today

I built the whole §2–§7 core from scratch. `A_dlg_lawful.lean` contains, all accepted:

```lean
inductive Dlg (A : Type) : Type | done | ask …
def bind : Dlg A → (A → Dlg B) → Dlg B        -- structural recursion under the binder: accepted
instance : Monad Dlg
instance : LawfulMonad Dlg                    -- proved, by induction + funext
theorem run_bind   : run w (bind p k) = run w (k (run w p))
theorem trace_bind : trace w (bind p k) = trace w p ++ trace w (k (run w p))
#print axioms trace_bind   -- [propext]
```

Every claim in §5 q9 ("lawful by construction, no quotient") and §7.1–7.2 (the two morphism
equations that *are* the specification) is verified. `under : Sig → Dlg A → Dlg A` also
typechecks with `Sig := (c : Code) → Q c → Q c` staying in `Type 0`
(`G_cost_needs_fintype.lean`). Termination is structural; no `termination_by` is needed; no
universe issue arises; `do`-notation attaches with no metaprogram.

This is a genuinely strong result and it should be said plainly: **of the three kernels, one of
them is three hours of work away from existing, and it is this one.**

**And here is what it cannot do.** `G_cost_needs_fintype.lean`:

```lean
def costMax [∀ c, Fintype (El c)] (price : (c : Code) → Q c → ℕ) : Dlg A → ℕ
  | .done _ => 0
  | .ask c q f => price c q + Finset.univ.sup (fun x => costMax price (f x))
#check @costMax
-- @costMax : [(c : Code) → Fintype (El c)] → … → Dlg A → ℕ        ← the instance is mandatory
```

The continuation is a Lean function. To see past an `ask` you must *apply* it, and to bound the
result you must range over all of `El c`. Therefore:

1. **`cost` does not exist for free-text answers.** `El c = String` has no `Fintype`. The
   document's §8.2 tri-partite theorem, §8.3's worked "min 7, max 15", and §8.4's graded subtype
   `W γ A = { p : Dlg A // cost p ≤ γ }` are all *unstatable* as written for the very answer type
   the domain is built on. §8.4 in particular defines the budget index by a function that does not
   exist.
2. **Even where `El c` is finite, the fold is exponential.** Three verdicts and depth 4 is
   `3⁴ = 81` continuation applications; the document's own `loop 2` example over a 3-way verdict
   monoid with a list-of-objections payload is already unbounded.
3. **The semantic grade is undecidable.** §5 q4 defines `Batch p := ∀ w w'. map fst (trace w p) =
   map fst (trace w' p)`. That is a Π over `World = (c : Code) → Q c → El c`. It is a perfectly
   good *specification* and there is no `Decidable` instance and no derivation of one. Nothing
   computes it.
4. **The witnesses reintroduce the problem.** §5 q4 Part B says the four levels are *witnessed*
   by the free applicative, the free static arrow, the free selective and the free monad,
   "embedding into `Dlg` by maps that commute with `run`". That is correct, and it means the
   deliverable is not `Dlg`; it is four first-order types plus four embeddings plus `Dlg` — at
   which point every objection in §3.2 and §3.3 below applies to the analyzable layer, and
   `Dlg`'s simplicity is the simplicity of the *target*, not of the artifact.

**Two internal defects found while formalizing.**

- **§8's cost carrier contradicts §11.3's memoization requirement.** §11.3 proves that the
  interpreter *must* memoize on question identity or adequacy is vacuous. Under memoization, a
  workflow that asks `q` twice pays once. But §8.1's spend semiring has `⊗ = ∥ = +`, so `cost`
  reports two. Therefore §8.2 clause 1 — "`Batch p` ⇒ `cost` is an exact semiring homomorphism …
  a single value" — is **false for the bill** whenever a `Batch` workflow repeats a question,
  which §5 q2's own "ask twice" example does. The bound survives as an over-approximation; the
  word *exact* does not. Algebra-first found and repaired precisely this (its §9 Attempt D, with
  `S = Finset Q`, the free *idempotent* monoid). Meaning-first should adopt that repair; it costs
  nothing and it is the only one of the two documents that is self-consistent here.
- **§11.2's `Functional τ` hypothesis is redundant given §11.3, and stating it weakens the
  theorem.** I proved a strictly stronger statement without it (§5 below): if the interpreter
  memoizes, functionality is not a hypothesis to be *assumed of the transcript*, it is an
  invariant of the table, and the theorem then holds against an agent that is allowed to answer
  differently every time and to depend on everything asked so far.

### 3.2 Algebra-first (`rederive-algebra-first.md`): ❌ the carrier as written does not eliminate

§8.1 chooses the initial (inductive) carrier "because Lean has no parametricity theorem, so the
final encoding's laws would need axioms". That reasoning is right. The carrier is then

```lean
inductive W : Grade → Type → Type 1 where
  | ap     : W g (A → B) → W g' A → W (max g g') B
  | select : W g (A ⊕ B) → W g' (A → B) → W (max (max g g') .sel) B
  | bind   : W g A → (A → W g' B) → W .mon B
```

and §8.1 says `costTree` and `asks` "pattern-match on" it. **They cannot.**
`D_graded_index_fails.lean`:

```
error: Dependent elimination failed: Failed to solve equation
  Grade.ap = match g✝, g'✝ with | Grade.mon, x => Grade.mon | … | Grade.ap, Grade.ap => Grade.ap
```

The index `max g g'` is a *computed* term, not a constructor application, so `cases w` on
`w : W .ap A` cannot refine. This is not a tactic weakness; it is the standard limitation of
dependent pattern matching on non-injective indices. Every one of §5.3's theorems — exact cost at
`ap`, the tight `Over`/`Under` bounds, `costTree`, the finite-tree theorem, the schedule-
independence theorem at `ap` — is stated as a fact about `W .ap A` or `W .sel A` and therefore
does not get off the ground as written.

**The repair, verified.** `E_grade_as_fold_works.lean` un-indexes the term and makes the grade a
fold, then proves the totality theorem that the index was supposed to give by typing:

```lean
inductive T : Type → Type 1 | pure | ask | ap | select | bind
def grade : T A → Grade                                  -- the grade is a FOLD
def asks (price : Q → S) : T A → Option S                -- total everywhere, junk above ap
theorem asks_total_at_ap (price) (w : T A) : grade w = .ap → (asks price w).isSome   -- ✅ proved
```

The alternative repair — carrying an explicit equation field, `| ap {h} : h = max g g' → …` —
also eliminates cleanly (same file, `V`), at the cost of an equation argument in every
constructor, every `rw`, and every congruence.

Note what the working repair *is*: the grade stops being an index and becomes a fold with a
theorem attaching it to a property of the term. That is precisely the contamination ledger's
verdict on `Frag` ("a type index that provably fails to bound the quantity it was introduced for
is not a specification, it is a decoration") — turned around and applied to the proposal that
made the accusation. The lesson generalizes: **in Lean, a semilattice-valued index on an
inductive family is nearly always a mistake; make it a fold and prove the theorem.**

**Three further liabilities.**

- **`Selective` must be built, and the free one may not exist.** Mathlib has no `Selective`
  class. Worse, the literature has no *free selective functor*: Mokhov et al. give the free
  **rigid** selective functor, `data Select f a where Select :: Select f (Either a b) -> f (a -> b)
  -> Select f b` — note the right-hand argument is `f`, not `Select f` — and the `selective`
  package's own source still carries `TODO: Prove that this is a lawful 'Functor'`. The general
  free construction is open, precisely because the selective law set is deliberately incomplete
  (no Pure-Left / Pure-Right laws). Algebra-first's `select : W g (A ⊕ B) → W g' (A → B) → …` is
  the **non-rigid** shape, so it is not the known-good construction. This is research, not
  library work, and it sits underneath the level the owner most cares about.
- **`Over`/`Under` are not lawful instances of the meaning.** §3.4 defines the meaning as
  `∀ F ∈ Class(g)`, quantified over *lawful* members. §5.3 then instantiates at `Over S` and
  `Under S` to get the cost bounds. But `Over` runs both branches by design; it is an
  over-approximating instance, not a law-abiding one. If the quantifier really ranges over lawful
  functors, `⟦·⟧_{Over S}` is not an instance of the meaning and the bounds are **not** corollaries
  of the morphism — they must be proved by induction on the term, exactly the work the design
  claims to have avoided. ⚠ (Reasoned; I did not build `Selective` to test it.)
- **§7 q9's equality is a `Prop` quantifying over `Type → Type`, and quotienting by it makes the
  monad noncomputable.** Impredicative `Prop` makes the definition legal, and `Quotient.out`
  makes `bind` illegal-to-compute (`F_quotient_needs_choice.lean`). §8.1's plan to "provide
  `Monad (Quotient ≈ ∘ W .mon)`" yields a `noncomputable` monad, so the *interpreter* cannot run
  on the semantic type. The three-layer stack host-lean4 §2 predicts (syntax → normal form →
  quotient) is unavoidable, and the quotient layer is proof-only.

The honest scorecard for this document: its §7 q10 **Part A** — "commutation is `rfl` because
`run` *is* `⟦·⟧` at `m`" — is exactly right, is the sharpest observation in any of the three
documents, and is the reason a very large amount of anticipated proof work evaporates. Its Part B
is also right in shape. Everything between §4 and §5.3 needs the index-to-fold surgery first.

### 3.3 Decontaminate (`rederive-decontaminate.md`): ❌ its Lean sketch names four things that do not exist

Part 7's sketch is:

```lean
abbrev WApp := FreeApplicative (Sig Q Ans)
abbrev WSel := FreeSelective   (Sig Q Ans)
abbrev WMon := FreeMonad       (Sig Q Ans)
noncomputable def den (ω) : WMon Q Ans A → V A := FreeMonad.foldMap …
theorem adherence … := FreeMonad.hom_ext (hρ.comp runW_isHom) (den_isHom ω) h
```

`FreeApplicative`, `FreeSelective`, `FreeMonad`, `FreeMonad.foldMap` and `FreeMonad.hom_ext` are
**all** absent from Mathlib. The module-inventory table ("`Term.lean` (535) → `Sig` (3 lines) +
three free-structure instantiations") is therefore off by the cost of building three free
structures with their folds, their uniqueness theorems, their `LawfulApplicative`/`LawfulMonad`
instances and — for the selective — a class that does not exist and a construction that is open.
Realistically that is not 3 lines; it is the larger part of the module it replaces, and one third
of it is a research problem.

Two more:

- **`den` into `VS S A = A → S` is uncomputable by design** (the document says so, correctly),
  which means the *only* executable tier is q10's **T1** (`S = Bool`, `M = Except E`,
  `ρ = support`) and even that needs `csum` at `Bool` to reduce, i.e. decidable existential
  quantification over `A`. For `A = String` that is `∃ a : String, …`, not decidable. So T1 as
  stated is not runnable either without restricting to finite answer types. ⚠
- **q10's "proof: one line, by initiality" is right in mathematics and misleading in Lean.**
  `hom_ext` for the free monad on a signature with functional continuations is an induction plus
  `funext` — perhaps twenty lines, not one — and it must be *written*, since Mathlib has no such
  lemma. More seriously, the theorem's hypothesis is `ρ : ∀ {A}, M A → V A` with `M = IO` and
  `ρ` = "the law of". **There is no such Lean function and no way to define one.** `ρ` must be an
  opaque `axiom`, and then `IsMonadHom ρ` is a second axiom about that axiom. So decontaminate's
  adherence theorem, at the live-run tier, is a conditional whose antecedent cannot be
  instantiated by any Lean term. That is a strictly larger trust boundary than the one I prove in
  §5 below, and it is the opposite of what the document claims for itself.
- **The `Weighting` class is heavier than it reads.** `Weighting V extends Monad V, Alternative V`
  with `comm`, `distrib`, `zero_bind` — and the workhorse instance `VS S` requires
  `LawfulMonad (VS S)`, whose associativity is `csum_swap` (Fubini) and whose left/right units are
  `csum_point`. agent-cat has those axioms (`Agentic/Semiring.lean:120–136`); the `LawfulMonad`
  instance itself is unwritten anywhere and is a real, if routine, obligation.

What decontaminate gets uniquely right, and should be kept: **q7's observation that acting leaves
break the passive-oracle picture**, and the state-kernel repair. It is the only document that
notices, and it turns out to be free in the adherence theorem I prove below, because a
history-dependent strategy already models an agent that acts.

### 3.4 Contamination ledger §4: the same three gaps

§4.1's `Ap Q / Sel Q / Free Q` sketch is written directly at `Type → Type 1` (it says so), so it
carries the universe cost of §2 knowingly. §4.4's four obligations are all well-posed. Obligation
2 — "the analysis homomorphism `[[·]]_M` exists for `Ap` and `Sel` and does **not** for `Free` —
the honest form of the grade, and a *theorem* rather than an index" — is the correct statement of
the owner's directive (1), and it is the one formulation among all four documents that is both
provable and *decidable on terms*, because `Ap`/`Sel`/`Free` are three types and inhabitation is a
typing fact rather than a semantic predicate. That is a genuine advantage over meaning-first's
undecidable trace predicates (§3.1 item 3) and over algebra-first's non-eliminable index (§3.2).

Its `World Q := (h : History) → ∀ {α}, Q α → α` (§4.1) is a `Type 1` object with a rank-2 field,
which reintroduces exactly the objection it makes against `Runner` at ledger §5 row 3 — you
cannot easily put a measure on it either. ⚠ The dependent-but-*small* form
`World := (c : Code) → Q c → El c`, which is what I used and what compiles, is `Type 0` and does
not have that problem.

---

## 4. `do`-notation: what attaches, and what needs a metaprogram

| kernel | `do` | cost |
|---|---|---|
| `Dlg` (meaning-first) | ✅ out of the box; `Monad`/`LawfulMonad` instances proved | none |
| ungraded `T` + grade-as-fold (§3.2 repair) | ✅ out of the box | the grade is then computed *after* elaboration, which is fine, and is how the analysis should work anyway |
| `W : Grade → Type → Type 1` (algebra-first as written) | ❌ | Lean's `do` desugars to `Bind.bind : m α → (α → m β) → m β`, a shape a graded family cannot inhabit. A custom syntax category + elaborator, 200–400 lines and permanent maintenance (host-lean4 §2 estimates the same). And it must be written *after* the index problem of §3.2 is solved, or there is nothing to elaborate into. |
| three separate types `WApp/WSel/WMon` (decontaminate) | partial | `do` at `WMon` only. Lean has no `ApplicativeDo` and no selective-do. Authors writing at the analyzable levels write `<*>`, `traverse` and `ifS` by hand — which decontaminate §8.5 concedes ("the discipline is not free, and pretending it is would be the first step back toward making everything monadic"). This is the honest position and it is a real usability cost, since the whole point is that *most* workflows should be written at `App`/`Sel`. |

Practical note: an applicative-do elaborator for Lean is a smaller job than a graded-do
elaborator (it is a dependency analysis over the `do` block's binders, no index arithmetic), and
it is the piece that makes the tower usable. It is not optional work; it should be budgeted.

---

## 5. The adherence theorem — the owner's Path 2

This is the section the lens exists for. The question: *what exact Lean proposition says "each
operation commutes with the denotation" when `run : W α → IO α` speaks ACP JSON-RPC to live
agents, and is it provable without axiomatizing `IO` beyond a small trusted interface?*

### 5.1 The three candidate shapes, and what each actually costs

**(a) Per-operation commuting squares against an abstract monad.** Algebra-first §7 q10 Part A:
define the interpreter *as* the fold, `run query := ⟦·⟧_m query`; then the five commutation
equations are `rfl`. ✅ This is correct, it is free, and it should be adopted by whichever kernel
wins. It is also, by itself, *empty of empirical content*: it says the interpreter is the fold,
not that the fold is the agent.

**(b) A monad morphism from `IO` into the meaning.** Decontaminate q10: `ρ : IO A → V A`, "the
law of". ❌ Not a Lean object. Both `ρ` and `IsMonadHom ρ` must be axioms, and no term can
discharge them. Maximum trust, minimum content.

**(c) Log the sampled world and prove `run t = μ_ext t (loggedWorld)`.** Meaning-first §11.2, and
the owner's own third suggestion. ✅ **This is the one that works, and it works better than the
document claims.** I proved it.

### 5.2 What I proved (`B_adequacy.lean`)

The live agent is modelled as the weakest honest object: an arbitrary function that may answer
differently every time and may depend on everything asked so far.

```lean
abbrev Hist     := List ((c : Code) × Q c)
abbrev Strategy := Hist → (c : Code) → (q : Q c) → El c        -- adversarial, history-dependent
abbrev Table    := List ((c : Code) × (q : Q c) × El c)        -- the memo table = a finite world

def exec (σ : Strategy) : Table → Dlg A → Table × A            -- the MEMOIZING interpreter
  | t, .done a  => (t, a)
  | t, .ask c q f =>
      match lookupT t c q with
      | some a => exec σ t (f a)                               -- memo hit: no consultation
      | none   => exec σ (⟨c, q, σ (hist t) c q⟩ :: t) (f (σ (hist t) c q))

def Extends (w : World) (t : Table) : Prop := ∀ c q a, lookupT t c q = some a → w c q = a

theorem adequacy (σ : Strategy) : ∀ (p : Dlg A) (t : Table),
    (∀ w, Extends w (exec σ t p).1 → Extends w t) ∧
    (∀ w, Extends w (exec σ t p).1 → run w p = (exec σ t p).2)
```

`#print axioms adequacy` → `[Code, El, Q, propext]` (the first three are the domain's opaque
parameters). No Mathlib. No `sorry`. No `Classical.choice`. No `funext`. No assumption whatsoever
about the agent.

In English: **a run exhibits a finite world; every total world extending it assigns the workflow
exactly the value the run returned.** This is meaning-first §11.2, minus its `Functional τ`
hypothesis, which the memo table discharges structurally — as §11.3 predicted, and which I can now
report is not merely a good argument but a mechanically checked one.

Three things worth noting about the proof.

- The one lemma that needed strengthening is `lookup_cons_of`: prepending an entry preserves
  lookups **only if the prepended key was absent**. That hypothesis is exactly the memoization
  discipline, and it is the formal residue of §11.3's corollary. A non-memoizing interpreter
  cannot supply it and the theorem genuinely fails.
- The theorem is *stronger* than a Markov/probabilistic reading. It does not assume the agent is
  a distribution, is stationary, is independent across draws, or is even consistent with itself.
  Decontaminate §8.6 and algebra-first §7 q10's "Axiom (Oracle fidelity)" both introduce an
  unprovable independence axiom at this point. **For the value semantics that axiom is not
  needed.** It is needed only for the *distributional* results (algebra-first §5.4), and it should
  be quarantined there rather than stated as a hypothesis of adherence.
- Because the strategy is history-dependent, an *acting* agent (decontaminate q7's `Exec`) is
  already covered for the value semantics. What acting costs is the reordering licence and
  replayability, not adequacy.

### 5.3 The residue, and how to eliminate it: a per-run certificate

`adequacy` is about a pure `exec` over a pure `Strategy`. The real interpreter is
`execIO : Dlg A → StateT Table IO A`, differing only in that `σ (hist t) c q` becomes an ACP
round trip. The bridging proposition — "the IO run is `exec` at *some* strategy" — is not
provable in Lean, and no formulation makes it provable, because Lean has no `IO` semantics.

But it does not have to be assumed either. `C_certificate.lean`:

```lean
def worldOf (t : Table) : World := fun c q => (lookupT t c q).getD default
def certify {A} [DecidableEq A] (p : Dlg A) (t : Table) (a : A) : Bool :=
  decide (run (worldOf t) p = a)
theorem certify_sound (p t a) : certify p t a = true → ∃ w : World, run w p = a
#print axioms certify_sound      -- [Code, El, Q]   — nothing else at all
```

After every live run, take the logged memo table, extend it to a total world by defaulting, and
*re-evaluate the denotation purely*. `run` is computable; the finite-observation property means it
only ever consults keys the table holds; the check is linear in the trace. If it passes, the run
is certified: there provably exists a world at which the workflow means what the run returned.

This is the correct answer to the owner's Path 2, and it is materially better than any of the
three documents propose:

| approach | trust boundary |
|---|---|
| decontaminate q10 | `ρ : IO ⇒ V` and its morphism property, both axioms, neither instantiable |
| algebra-first q10 Part B | operational semantics for `IO` as a state transformer (must be written and is not Lean's), plus the oracle-fidelity axiom |
| meaning-first §11.2 | `Functional τ` assumed of live agents (false) unless memoizing; adequacy proved by induction ✅ |
| **certificate (§5.3)** | **none for the value claim.** Each run carries its own machine-checked proof. `IO` is never modelled. |

The only thing left outside the proof is meaning-first §11.4's genuine trust boundary: `perform q`
returns *some* element of `El c`. That is one total parsing function per answer code, and it is
the entire trusted interface. Adopt §5 q8's discipline (`Declined` is an answer, not an
exception) and it is discharged by construction.

### 5.4 What the certificate does **not** give

Stated so it is not oversold.

- It certifies the *value*, not the *cost*. Comparing `|t|` against a static bound requires the
  static bound to exist, which is §3.1's problem.
- It certifies *this* run, not the workflow. It does not say a second run agrees.
- It requires `DecidableEq` on the result type and on questions. Both are true for the domain
  (records over strings) and both must be threaded.
- It is only as good as the log. If the ACP shim answers from somewhere the table does not
  record, the certificate is checking the wrong thing. The shim must be the only path to `perform`
  — a code-organization obligation, not a proof obligation.

---

## 6. Flagged: unimplementable, or research rather than engineering

Ranked by how much of a proposal falls if the item does not land.

1. **A lawful free selective functor** (decontaminate §3.4; algebra-first §4/§5.3; ledger §4.1).
   Only the free **rigid** selective is known; the general construction is open, the law set is
   deliberately incomplete, and the reference Haskell implementation has an unproved functor law.
   Both first-order proposals put the owner's "tree structure where branching is visible" on top
   of it. **This is the single largest unlanded dependency in the whole dossier.** The available
   retreat is to use the *rigid* shape (`select : W (A ⊕ B) → Sig (A → B) → W B`) and accept the
   restriction, or to define a bespoke branch node with a hand-proved cost tree and stop calling
   it a standard class.
2. **Static cost from a HOAS carrier** (meaning-first §8, §8.3, §8.4). Requires
   `[∀ c, Fintype (El c)]`; the domain does not have it; §8.4's graded subtype is defined by a
   function that does not exist for free-text answers. Not repairable within `Dlg`; repairable
   only by adding a first-order analyzable layer.
3. **A graded inductive with a computed index** (algebra-first §4, §8.1). ❌ refuted by the
   compiler; repairs exist (grade-as-fold ✅ verified, equation-field ✅ verified) but the
   document's §5 theorems must all be restated over the repaired carrier.
4. **A computable `Monad` on a quotient of a free monad** (algebra-first §8.1; decontaminate q9).
   `Classical.choice`, verified. Proof-only layer; the interpreter must run on representatives.
5. **`ρ : IO ⇒ V` ("the law of an IO action")** (decontaminate q10, tier T3). Not definable.
   Requires two axioms and cannot be instantiated. Delete the tier or restate it as §5.3's
   certificate.
6. **Graded `do`-notation** (algebra-first §8.2). Custom elaborator, 200–400 lines, permanent
   maintenance against Lean releases. Feasible, not free, and frequently underestimated.
7. **`pin` as `Function.update`** (meaning-first §14.1; decontaminate q1; ledger §4). Mathlib's
   `Function.update` and its five laws are for *one* level. `World = (c : Code) → Q c → El c` is
   two levels and dependent, so `pin` is a nested update whose laws must be re-derived (routine,
   half a day, but do not budget zero).
8. **Measure theory over worlds** (algebra-first §5.4; decontaminate §8.2). `World` is a
   dependent function space; Mathlib has no measurable structure on it out of the box, and
   quasi-Borel spaces are not in Mathlib. Restrict to `PMF` over countable answer types or defer.
   Both documents already rank this last; that ranking is correct.

---

## 7. What survives, and the shape I would actually build

The three documents disagree about which layer is the artifact. The Lean evidence says the answer
is *two* layers, and that each document is right about one of them.

**Layer 1 — the plan (first-order, analyzable).** An ungraded inductive over the question
signature, with the grade as a **fold** and not an index (`E_grade_as_fold_works.lean`). This is
where cost, width, the branch tree and the budget live, because it is the only layer whose
continuations can be inspected. Take the ledger §4.4 obligation 2 as the statement of the owner's
directive (1): the analysis homomorphism into `Const M` exists at the applicative fragment, over-
approximates at the branching fragment, and provably does not exist at the monadic one. Keep
algebra-first's `S = Finset Q` idempotent cost carrier (its §9 Attempt D), because §3.1 shows the
additive one is inconsistent with the memoization that adequacy requires.

**Layer 2 — the meaning (`Dlg`, higher-order).** Exactly meaning-first §2.3, in `Type 0`, over a
small `Code` universe — which is also Mathlib's `PFunctor` shape, the only free construction the
library offers. `Monad`, `LawfulMonad`, `run`, `trace`, `under` all verified. Semantic equality is
plain `=` (no quotient, no `Classical.choice`), and the Forcing Lemma says that is the right
equality. `denote : Plan A → Dlg A` is the unique fold, and the *only* proof obligation crossing
the layers is that `denote` commutes with each analysis — one square per fold, which is
algebra-first's §7 q10 Part A cashed at the layer boundary rather than at the runtime boundary.

**Layer 3 — the runtime.** The memoizing `exec` of §5.2, instantiated at `StateT Table IO` with
`perform` an ACP JSON-RPC call over `IO.Process.spawn` + `Lean.Json` (both core, both `#check`ed).
Adherence is not an axiom: it is `certify` (§5.3), run after every execution, with
`certify_sound` as its warrant.

### Proof-obligation ledger, with difficulty from having attempted it

| # | Obligation | Status |
|---|---|---|
| 1 | `Dlg` in `Type 0`; `Monad`, `LawfulMonad` | ✅ **done**, `A_dlg_lawful.lean` |
| 2 | `run`/`trace` morphism equations (§7.1–7.2) | ✅ **done**, same file |
| 3 | Memoizing `exec`; adequacy against an adversarial strategy | ✅ **done**, `B_adequacy.lean` |
| 4 | Per-run certificate + soundness | ✅ **done**, `C_certificate.lean`, zero axioms |
| 5 | `under` as a monad morphism; monoid-action laws | easy; `under` typechecks, laws are the same induction as 2 |
| 6 | Forcing Lemma (`p = p' ↔ ∀w. run,trace agree`) | ⚠ moderate: needs `Nonempty (El c)`, a 2-level dependent `update`, `funext` |
| 7 | `Plan` carrier + `grade` fold + `asks` at `Const (Finset Q)` | ⚠ moderate; the shape is verified (`E_…`), the carrier is not written |
| 8 | `denote : Plan → Dlg` commutes with `run`, `trace`, `asks` | ⚠ moderate; one induction each, no quotient in the way |
| 9 | Branching level: a hand-rolled `Selective` **or** a bespoke branch node with a proved cost tree | ❌ **research** if "free selective" is insisted on (§6 item 1) |
| 10 | Applicative-`do` elaborator | engineering, unavoidable if the tower is to be usable |
| 11 | Distributional layer (`PMF`, convolution, star) | defer; agent-cat's `Semiring`/`Star`/`Matrix` are the survivors and drop in unchanged |

Items 1–4 are the kernel and they exist. Items 5–8 are a week. Item 9 is where the schedule risk
lives, and no amount of denotational clarity moves it, because it is a gap in the literature and
not in the design.

---

## 8. Answers to the lens's questions, compactly

- **Do the free/graded structures exist in Mathlib?** No. Not one of `FreeMonad`,
  `FreeApplicative`, `FreeSelective`, `Selective`. `Const`, `PFunctor.W`, `QPF`, `Quotient`,
  `Tropical`, the semiring/order hierarchy and Batteries' universe-flexible `List.traverse` do.
- **Universe issues with `(Type → Type)`-indexed frees?** Real and decisive: any free structure
  over an arbitrary `Type → Type` signature lands in `Type 1` and loses Mathlib's `Traversable`.
  Indexing by a small `Code` universe keeps everything in `Type 0`. Verified both ways.
- **Quotiented-free for lawful-by-construction?** Legal, `noncomputable`, and unnecessary: the
  HOAS carrier's laws hold propositionally with no quotient at all. Verified.
- **How does `do` attach?** Freely to `Dlg` and to any ungraded free monad, including at
  `Type → Type 1`. Not at all to a graded family; that needs a custom elaborator. Applicative-do
  does not exist and must be written.
- **Can the meaning-as-unique-fold be DEFINED?** For `Dlg`: yes, structurally, in `Type 0`,
  verified. For the graded family: **no**, as written — the computed index blocks elimination;
  verified, with two verified repairs.
- **Do the cost-factorization theorems have provable statements?** At the applicative fragment of
  a first-order carrier, yes, and I proved the totality half. Over `Dlg` directly, no: `cost` does
  not exist without `Fintype` on every answer type, so meaning-first §8.2–§8.4 are unstatable for
  free-text answers.
- **What exact proposition is runtime adherence, and is it provable without axiomatizing `IO`?**
  `∀ w ⊒ loggedTable, run w p = returnedValue`, proved by induction over the memoizing
  interpreter against an arbitrary history-dependent agent, with `#print axioms` = `[propext]`;
  and, better, its decidable per-run form `certify p t a = true → ∃ w, run w p = a` with
  `#print axioms` empty. **`IO` is never modelled, and nothing about the agents is assumed.**
