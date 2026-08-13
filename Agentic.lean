-- The package's one monoid is Mathlib's, and is now spelled Mathlib's way:
-- binders say `Monoid`/`CommMonoid`/`Std.IdempotentOp (· * ·)`, combination is
-- `*`, and the order an idempotent join induces is `SemilatticeSup` +
-- `OrderBot`. Two things survive: the pair of actions on a reader (`actR` for
-- scoping, `actL` for the derivative), with the docstring saying exactly why
-- Mathlib's `DomMulAct` cannot serve; and `SupMon`, the join presented as a
-- monoid (`* = ⊔`, `1 = ⊥`), which is what both join reducers of `Keys` are
-- and which Mathlib has in no form.
import Agentic.Monoid
-- The resource algebra is Mathlib's, and is now spelled Mathlib's way:
-- `Semiring`/`CommSemiring`/`IdemSemiring`/`KleeneAlgebra`, the canonical
-- additive order written `≤`, and iteration written `x∗` (`KStar.kstar`).
-- Two things survive with survivor docstrings: `StarSemiring` (one unrolling
-- law and nothing else, for the expectation semiring, whose `+` is not
-- idempotent and which is therefore outside `KleeneAlgebra`) and
-- `CompleteCSemiring` (arbitrary-index `csum`, which Mathlib has in no form
-- covering both the lattice carriers and expectation); also why countability
-- is a remark about the models rather than a premise of the meanings.
import Agentic.Semiring
-- Carriers, now Mathlib's: possibility (`Prop`, whose semiring is `scoped` in
-- `Agentic.Possibility` — importing this package must not install arithmetic on
-- propositions; `test/Pollution.lean` is the standing check)), worst-case cost (`Cost`,
-- max-plus on `Multiplicative (WithBot ℕ∞)`, the genuine ⊥ being `WithBot`'s),
-- consensus weight (`Prob`, Viterbi `(max, ×)` on `ℝ≥0∞` — real probabilities,
-- with `[0,1]` appearing as the hypothesis it is), and the expectation
-- semiring `P ⋉ M` as Mathlib's `TrivSqZeroExt` — complete over any complete
-- module of moments (`CompletePMod`) and starred by `⟨p*, p* m p*⟩`.
-- Aggregation at the three lattice carriers is Mathlib's `iSup`, and saying so
-- (`CsumIsSup`) is the whole of what each contributes to the star: the first
-- three are Kleene algebras by one construction, `x∗ = ⊕ₙ xⁿ`; the fourth
-- carries a star that only answers the unrolling law, its `+` not being
-- idempotent.
import Agentic.Instances
-- `S`-matrices as resource-weighted transitions: identity, zero,
-- Chapman–Kolmogorov composition (a semiring), Kronecker product,
-- value-dependent sequencing = composition — and, over any carrier whose
-- aggregation is a supremum, the matrix Kleene star `M∗ = ⨆ₙ Mⁿ`, both
-- inductions included even though composition does not commute.
import Agentic.Matrix
-- Consultations and environments `ε`, pinning `ε[q ↦ a]` (Mathlib's
-- `Function.update`, with its five laws), the extensional meaning space,
-- caching-as-identity, and `share` ≠ `dup`.
import Agentic.Env
-- The monoid semiring (convolution over panel keys, a semiring in its own
-- right), the augmentation homomorphism, point masses and the collapse of the
-- deltas to convolution, the scheduler licences stated about the weighting
-- rather than about a list, and the two bridges (`panelOf`, `convFold`) from a
-- list representation to the panel it denotes.
import Agentic.Panel
-- Inhabitants for the panel keys: the free monoid on names (Mathlib's
-- `FreeMonoid`, transported to `List`), `Tally` as `Multiplicative ℕ`, and the
-- two joins Mathlib carries as lattices but not as monoids — `Width` (`max` on
-- ℕ) and `Race` (`or` on `Bool`, the speculate/race witness) — both of them
-- `SupMon`, so that neither `ℕ`'s arithmetic nor `Bool`'s is ours to decide.
import Agentic.Keys
-- Mazurkiewicz traces as a genuine quotient — Mathlib's `FreeMonoid` modulo
-- the congruence `conGen Swap`, so the quotient monoid is `Con.monoid` and only
-- `Swap` and the two exactness theorems are ours; sessions `Trace → S`, and the
-- Brzozowski derivative that fork and resume share.
import Agentic.Trace
-- Per-axis `Last` monoids (the survivor: Mathlib's `WithOne` adjoins a unit to
-- a semigroup, but has no right-zero semigroup to adjoin it to); scoping as the
-- monoid's right action on a reader, with innermost-wins and the covariant
-- composition law as theorems.
import Agentic.Scope
-- Gating as the scalar action of an indicator: refusal is `0` and annihilates
-- downstream, and nested guards intersect.
import Agentic.Gate
-- The information-ordered context: compaction as an interior operator —
-- Mathlib's `ClosureOperator` on the order dual — the context-parameterised
-- index family, and the `const ε` collapse.
import Agentic.Context
-- The retry solve `(M_A · d)* · M_B`, its loop equation and — under
-- `KleeneAlgebra` — its leastness, at matrices as well as scalars, with the
-- matrix algebra constructed rather than assumed; reachability as the read-out
-- of that star at possibility, its closure facts read off the Kleene laws; the
-- read-outs at `Prop`, `Cost` (including the three-answer loop the leastness
-- principle was written for), `Prob` (Viterbi absorption) and expectation
-- (`p* m p*`, and the projection commuting with the solve); fuel as
-- truncation, bounded at the retry matrix.
import Agentic.Star
-- The Pareto preorder on resource factors: Mathlib's product order, with the
-- incomparability witness — the one thing Mathlib does not have — and the
-- reading of a scalarization as an `OrderHom`.
import Agentic.Pareto
-- The fragment grade, which is Mathlib's `ℕ∞`: static is 0 (the bottom),
-- bounded n is the numeral, monadic is ⊤, sequencing joins by ⊔ and a tensor
-- adds by +, so the order and every law of the two operations are Mathlib's.
-- One operation survives, the one the shelf has no name for: scale n f =
-- n * max 1 f, the fan, whose `max 1` is the written shape counting as one
-- copy of itself — and whose arithmetic in ℕ∞ grades a zero-fan of an opaque
-- body `static`, because 0 * ⊤ = 0.
import Agentic.Frag
-- The syntax stratum: workflow terms as an inductive family indexed by Frag,
-- semiring-free; consultation identity is positional, so duplication is the
-- default and sharing is the explicit labeled shareT (§6a, Env.share_ne_dup).
import Agentic.Term
-- The meaning stratum: the two folds of §3 out of one syntax — the
-- quantitative muS into matrices (each clause a §4 type-class-morphism row)
-- and the site-keyed extensional muExt into partial functions — the semantic
-- width `peak` that counts consultations in flight, incomparable with the
-- grade index it was meant to bound (what the grade bounds is
-- `peak ≤ writtenSites * Frag.copies f`), sharing made observable, and
-- workflow equality as the quotient by extensional meaning up to a
-- relabelling of consultation sites, on which the static fragment is a
-- category.
import Agentic.Meaning
-- The authoring surface: the words a workflow is actually written in — `ask`,
-- `askHuman`, `model`, `panel`, `revising`, and a `Monad` instance so that
-- sharing an answer is variable binding. Its signature is the stable contract;
-- its internals are scaffolding over the current Term calculus, which the
-- re-derivation condemns (dossier rederivation-kernel.md; obr acat-o8s).
import Agentic.Surface
-- The rederivation kernel's mathematical space, Stage 1 (dossier
-- rederivation-kernel.md §1–§3): question space — the small universe of answer
-- types `El`, the question `Q c` that carries everything determining the reply
-- (scope included, so `under` is a fold and not a constructor), and `Verdict`
-- as `WithZero (FreeMonoid Objection)`, in which refusal is an answer.
import Agentic.Core.Question
-- Worlds: the total answer sheet `Ω = (c : Code) → Q c → El c`, the finite
-- partial sheets a run accumulates (`Table`, its extension preorder, and the
-- defaulting totalization `worldOf`), and `pin` as `Function.update` at the two
-- levels `Ω` actually has, with the fork law re-derived rather than assumed.
import Agentic.Core.World
-- Dialogues: the coherent world-indexed (answer, transcript) pair, `Monad` and
-- `LawfulMonad` with no quotient, `run`/`trace` as the two morphisms that are
-- the meaning, `under σ` as a monoid action, and the Forcing Lemma — proved on
-- the repeat-free fragment and *refuted* in general (`Dlg.not_forcing`).
import Agentic.Core.Dlg
-- Plans, Stage 2: the representation. Contexts as lists of codes, environments
-- as their products, variables as de Bruijn membership proofs, and the five
-- term formers — `ret`, `askC`, `ask`, `case`, `dyn` — of a first-order,
-- intrinsically-typed syntax in which a question is built by a pure `Expr` over
-- the answers in scope. Sequencing is `graft` (substitution into the `ret`
-- leaves), not a constructor; `under σ`, `panel` and `revising` are derived, and
-- only general value-sequencing (`bindP`) needs the quarantined `dyn`.
import Agentic.Core.Plan
-- The meaning of a plan: `denote : Plan Γ A → Env Γ → Dlg A`, the fold whose
-- five clauses are the kernel's five morphism equations, with `run`/`trace` of a
-- plan *defined* as `run`/`trace` of its denotation (so the interpreter is the
-- fold and commutation is `rfl`), the substitution and scope lemmas, the master
-- grafting equation every derived form is checked against, and the acceptance
-- test that `revising 2` performs three reviews and two revisions.
import Agentic.Core.Denote
-- The level, Stage 3: which analyses apply, as a fold of the finished term and
-- never an index on the family (the compiled refutation is
-- `D_graded_index_fails.lean`, the repair `E_grade_as_fold_works.lean`). Four
-- rungs — `batch ≤ pipeline ≤ branch ≤ dynamic` — joined along the structure by
-- Mathlib's `max` and `Finset.sup`, invariant under renaming and scope, and
-- unmoved by `mapP`/`zipWith` while `bindP` sits at the top.
import Agentic.Core.Level
-- The bill, Stage 3: prices as functions of the question, the transcript's two
-- bills (`billFresh`, `billMemo`, related by divisibility), and the kernel's
-- cost obligations proved where they are true — the exact question list at
-- `batch`, the exact count at `pipeline` and the exact bill there under the
-- missing hypothesis `ShapeStatic` (the kernel's C2 is refuted as written), a
-- finite `CostTree` at `branch` with sound bounds and attained best/worst
-- achievable bills (the kernel's attainment claim is refuted as written), and
-- at `dynamic` the non-existence of any finite set of bills at all.
import Agentic.Core.Cost
-- The commuting squares, Stage 4: every operation of the representation stated
-- once against `denote` in standard vocabulary — the five leaf laws, the
-- substitution and scope squares (scope is reindexing of the world, on values
-- *and* on transcripts), grafting as the monad morphism into `Dlg`'s `bind`
-- with its unit and associativity halves, the panel's convolution law with the
-- honest order fact that a transcript is never permutation-invariant, the
-- check-then-revise unrolling, and C5: the level fold is sound at `batch`,
-- `pipeline` (for codes unconditionally, for shapes only under `ShapeStatic` —
-- the kernel's C2 is refuted here as written) and `branch`, and vacuous at
-- `dynamic`. Plus the monad laws of the surface ops, descended from `Dlg`'s
-- `LawfulMonad` through the kernel of `denote`, and the theorem that the level
-- is *not* an invariant of that kernel — which is what "the fold classifies
-- terms, not meanings" means.
import Agentic.Core.Morphism
-- The flagship workload, Stage 5: `example/HardenPatch.lean`'s twelve lines as
-- a `Plan` — guide, a deep-model draft, three review-and-revise rounds over a
-- shared guide, human consent and a gated act — with its meaning written first
-- as an ordinary `Dlg` recursion and joined to the term by one morphism
-- equation. Six theorems in the meaning space: consent gates the act (no `.ack`
-- event in a world that refuses), the guide is read exactly once in every
-- world, the level is `branch` (so the C3 cost theorems apply, and the workload
-- `attack-adequacy` A3 calls monadic in all four dossier kernels is not), at
-- most three drafts are asked for, the cost tree has nine leaves with
-- min 5 / max 15 while the seven *reachable* bills are 6, 7, 10, 11, 13, 14, 15
-- (so the tree's minimum is sound but not attained, the cheapest run costs six,
-- and the dearest costs fifteen and is exhibited), and `run` is total. Plus the six `ShapeStatic` closure lemmas that make the
-- branch-rung hypothesis usable on an authored workflow.
import Agentic.Core.HardenPatch

/-!
# Agentic — the denotational design of agentic workflows

Root module. Each import formalizes one stratum of the semantic space; see
README.md for the mapping to the design document.

(Lean's header rule puts the imports above this docstring: a module's `import`
commands must precede every other command, module documentation included.)
-/
