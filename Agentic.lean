-- Per-axis `Last` monoids and the monoid's right action on a reader: the scope
-- algebra, with innermost-wins and the covariant composition law as theorems
-- rather than interpreter rules. The one module of the pre-re-derivation tree
-- that survives the `acat-q1i` excision, and it survives because
-- `Agentic/Core/Question.lean` imports it: Mathlib's `WithOne` adjoins a unit to
-- a semigroup but has no right-zero semigroup to adjoin it to, so the last-wins
-- monoid is genuinely ours.
import Agentic.Scope
-- The schema universe: format-independent structured values (`Schema.El`) built
-- from lists and products. JSON is a representation in `Schema.Json`, outside
-- this mathematical root.
import Agentic.Core.Schema
-- The rederivation kernel's mathematical space, Stage 1 (dossier
-- rederivation-kernel.md §1–§3): question space — the answer universe `El`,
-- including the schema-indexed structured family, and the question `Q c` that carries everything determining the reply
-- (scope included, so `under` is a fold and not a constructor), its
-- factorization `Q c ≅ Q.Shape c × String` into what is asked of whom and what
-- is said (which is what `Plan`'s `ask` node splits, and hence why the kernel's
-- C2 needs no side condition), and `Verdict` as `WithZero (FreeMonoid
-- Objection)`, in which refusal is an answer — together with the two
-- projections every renderer in the package shares, `Verdict.objections` and
-- `Verdict.render`, defined once here beside the algebra they read.
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
-- intrinsically-typed syntax. `ask` carries the question's *shape* as term-level
-- data and only its *words* as a pure `Expr` over the answers in scope, so an
-- answer reaches the prompt and nothing else by construction. Sequencing is
-- `graft` (substitution into the `ret` leaves), not a constructor; `under σ`,
-- `panel` and `revising` are derived, and only general value-sequencing
-- (`bindP`) needs the quarantined `dyn`.
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
-- `batch`, the exact count, code sequence and question *shapes* at `pipeline`
-- and the exact bill there under `PricesByShape` alone (the kernel's C2 holds
-- unconditionally now that the `ask` node carries its shape; the side predicate
-- that used to repair it is deleted), a finite `Multiset` of bills at `branch` with sound
-- bounds and attained best/worst achievable bills (the kernel's attainment claim
-- is refuted as written), and at `dynamic` an exhibited plan admitting no finite
-- set of bills at all. Plus the scheduling licence at the bill: reordering a
-- panel is free in a commutative carrier.
import Agentic.Core.Cost
-- The commuting squares, Stage 4: every operation of the representation stated
-- once against `denote` in standard vocabulary — the five leaf laws, the
-- substitution and scope squares (scope is reindexing of the world, on values
-- *and* on transcripts), grafting as the monad morphism into `Dlg`'s `bind`
-- with its unit and associativity halves, the panel's convolution law with the
-- honest order fact that a transcript is never permutation-invariant as a list
-- (what survives reordering is the multiset, the approval decision and the bill
-- in a commutative carrier), the check-then-revise unrolling, and C5: the level
-- fold is sound at `batch`, `pipeline` (for codes *and* for shapes, both
-- unconditionally) and `branch`, and at `dynamic` there is a witness that there
-- is nothing to be sound about. Plus the monad laws of the surface ops, descended from `Dlg`'s
-- `LawfulMonad` through the kernel of `denote`, and the theorem that the level
-- is *not* an invariant of that kernel — which is what "the fold classifies
-- terms, not meanings" means.
import Agentic.Core.Morphism
-- The initial algebra, spent. `PlanAlg` is the signature of the five formers,
-- `PlanAlg.fold` the homomorphism it induces out of the syntax and
-- `PlanAlg.fold_unique` initiality — all three stated in `Agentic/Core/Plan.lean`,
-- next to the inductive whose recursion scheme they are. Eleven of the twelve
-- structural recursions in this package *are* that fold at an algebra, by
-- definition: `sub`, `under`, `graft`, `denote`, `level`, `codes`, `shapes`,
-- `asks`, `size`, `askNodes`, `explain`. Each keeps its five defining equations
-- as named `rfl` theorems, so the proofs that used to unfold the recursion still
-- say what they said; `Cost.costM` is the one that does not fit, because its
-- signature absorbs the level bound and an algebra carrier may not mention `p`.
-- This module holds what the substitution makes cheap: the `X = fold XAlg`
-- equations, now `rfl` rather than inductions, and the uniqueness statements —
-- `denote_unique` being the half the kernel's morphism obligations assume and
-- never state. The substitution was gated on kernel reduction and not on line
-- count, because nine `decide +kernel` proofs in
-- `Agentic/Core/DslFlagship.lean` reduce through these definitions; its
-- elaboration was measured before and after and did not move.
import Agentic.Core.Alg
-- The flagship workload, Stage 5: the owner's workflow as a `Plan` — guide, a
-- deep-model draft, three review-and-revise rounds over a
-- shared guide, human consent and a gated act — with its meaning written first
-- as an ordinary `Dlg` recursion and joined to the term by one morphism
-- equation. Six theorems in the meaning space: consent gates the act (no `.ack`
-- event in a world that refuses), the guide is read exactly once in every
-- world, the level is `branch` (so the C3 cost theorems apply, and the workload
-- `attack-adequacy` A3 calls monadic in all four dossier kernels is not), at
-- most three drafts are asked for, the cost tree has nine leaves with
-- min 5 / max 15 while the seven *reachable* bills are 6, 7, 10, 11, 13, 14, 15
-- (so the tree's minimum is sound but not attained, the cheapest run costs six,
-- and the dearest costs fifteen and is exhibited), and `run` is total. The six
-- `ShapeStatic` closure lemmas this module used to carry are gone with the
-- predicate: the branch-rung cost theorems now need only `level ≤ branch`.
import Agentic.Core.HardenPatch

/-!
# Agentic — the denotational design of agentic workflows

Root module. Each import formalizes one stratum of the semantic space; see
README.md for the mapping to the design document.

**What this root used to be, and what the excision did.** Until 2026-08-20 the
imports above were preceded by sixteen more: `Agentic.Monoid`,
`Agentic.Semiring`, `Agentic.Instances`, `Agentic.Matrix`, `Agentic.Env`,
`Agentic.Panel`, `Agentic.Keys`, `Agentic.Trace`, `Agentic.Gate`,
`Agentic.Context`, `Agentic.Star`, `Agentic.Pareto`, `Agentic.Frag`,
`Agentic.Term`, `Agentic.Meaning` and `Agentic.Surface` — the
pre-re-derivation stratum: a graded syntax of workflows (`Term`, twelve
constructors indexed by `Frag = ℕ∞`), two meaning functions over it (`muS` into
resource matrices, `muExt` into site-keyed partial functions), the `WEqR`
quotient on which the static fragment is a category, and the resource algebra
underneath. Obr `acat-q1i` retired all of it on the owner's ruling: roughly
9,900 lines with **no consumer anywhere** — the last one died in the `75c277c`
excision of `example/HardenPatch.lean` — and one import into the certified
spine, `Agentic.Scope`, which is kept above and is the only survivor.

The code is retired, not lost: git history is the archive, and
`doc/research/term-algebra-results.md` is the permanent record of what that
stratum *established*, transcribed from the live sources at HEAD `b98e25f`
before they went. The results there are mostly negative — no projection from the
quotient to matrices, the two meanings incomparable, the width/grade bound false
as assumed, sharing's over-charge — and negative results are the expensive kind,
which is why they are written down rather than left in a deleted file. Cite that
page, not these module names.

(Lean's header rule puts the imports above this docstring: a module's `import`
commands must precede every other command, module documentation included.)
-/
