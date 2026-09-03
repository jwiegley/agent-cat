# Four Ideas, Six Strata

A walkthrough of the agent-cat formalization as it stood on 2026-08-12: its
theoretical structure, its mathematical architecture, and the case that this
is the simplest, purest representation of agentic workflows. Prepared for John
Wiegley, grounded in the tree as of that date: 17 modules, a 19-job clean
build, zero `sorry`, zero axiom declarations, classical axioms only
(`propext`, `Classical.choice`, `Quot.sound`). Companion to
[`denotational-design-rev2.md`](denotational-design-rev2.md). Issue ids refer
to the obr tracker (prefix `acat`, surface `doc/PLAN.org`).

> **Status: historical since 2026-08-20.** This page is converted verbatim
> from `doc/walkthrough.html`. It describes the superseded pre-rederivation
> design. The stratum it walks, the `Term` calculus, its two meaning
> functions, and the resource algebra, was excised under obr `acat-q1i`; its
> results are preserved in [`term-algebra-results.md`](term-algebra-results.md).
> Names and line numbers below resolve in git history only, at or before
> commit `b98e25f`. The seven-pass review this code was hardened against is
> [`reviews/2026-08-12-heavy-review.md`](reviews/2026-08-12-heavy-review.md).
> The living design is the Texinfo manual, the `model/Agentic/Core` modules,
> and the Haskell authoring surface.

> **Four ideas carry everything: a monoid (whatever composes), a complete semiring (whatever aggregates), a matrix over it (whatever means), and a quotient (whatever equals).** The agentic domain — models, panels, retries, sessions, scopes, grants, budgets — never contributes new mathematical machinery. It contributes only *choices of carrier and index* for those four ideas. That is the purity claim, and the code enforces it by construction. *As of the Mathlib migration (§VIII), two of the four now come from the shelf: the monoid and the aggregation tower are Mathlib’s, with three documented survivors filling genuine gaps — and the axioms this package asserts fell from 52 to 16.*

## 0. The dictionary — from your workflows to the objects

Intuition runs concrete → abstract. Start from what you already do every day, and watch each practice become one of the four ideas:

| What you do | What it is | Why that object |
|----|----|----|
| send a prompt | a **weighted arrow** `M : Mat S Prompt Reply` | don’t model the one reply you got; model the table of all replies with their weights — every before-you-run question is a question about the table |
| chain prompts | **matrix multiplication** | “the weight of `a` becoming `c`” sums over every intermediate `b` — Chapman–Kolmogorov is not an analogy, it is the bookkeeping of *all the ways through* |
| spawn sub-agents | the **tensor** (and copy is free) | independent work in flight = the pair of tables; a panel = copy the value, tensor the agents |
| merge their findings | a **monoid** — and its algebra *is* your scheduler policy | concatenate ⇒ order is semantic; count ⇒ commutative, reorder freely; dedup ⇒ idempotent, speculate and race — one algebraic property per operational freedom, zero configuration flags |
| retry until it passes | the **star**, `x* = 1 + x·x*` | “zero attempts, or one more and retry”; fuel truncates the series; “does my loop cost finitely” = “does the star exist in this semiring” |
| estimate cost / check feasibility / bound risk | **the same fold, different carrier** | one computation, four number systems — `Cost`, `Prop`, `Prob`, expectation — you do not write four analyzers, you swap the semiring |
| session files, replay, fork-with-one-answer-changed | the **environment** `ε`, and `pin` | all randomness is one answer sheet decided in advance; a session file *is* ε restricted to the questions asked; replay is the identity; forking is editing one cell |
| two sub-agents ask the same question | **dup vs share** | by default they are two draws (independent samples); reusing one answer is an explicit label — the difference is observable, so it must be syntax, not convention |
| “what will this cost before I run it?” | the **grade** | `static`: price it exactly; `bounded n`: price a supremum; `monadic`: the model writes the plan — honestly unknowable a priori, estimable by sampling the prefix |
| “did my refactor change anything?” | the **quotient** | two terms are the same workflow iff no runner can tell them apart — “this changed nothing” becomes a theorem, not a diff review |

The strata below are these ten rows, organized: rows 4 and 9’s algebra is Stratum I; rows 5 and 6 are Stratum II; rows 1–3 are Stratum III; rows 7–8 are Stratum IV; row 9 is Stratum V; row 10 is Stratum VI. Section VII then reassembles all ten into one worked workflow.

## I. The monoid — `Monoid.lean`

Three classes in strict succession: `PMonoid` (a *combinable verdict*: `⋄`, unit, three laws), `CMonoid` (+commutativity), `IdemCMonoid` (+idempotence). Two generic actions on readers — `actR g f = fun h => f (h ⋄ g)` and `actL u f = fun w => f (u ⋄ w)` — with unit and composition laws proved once; note the asymmetry: `actR` composes covariantly, `actL` contravariantly. And the order *induced* by idempotence: `le a b := a ⋄ b = b`, with reflexivity = idempotence, transitivity and antisymmetry equational, and `op_le` making `⋄` a genuine least upper bound.

Why this is first: scoping (`withScope := actR`), session derivatives (`deriv := actL` — fork and resume are the *same action on the other side*), panel reducers, grade arithmetic, and every carrier’s order are all instantiations of this one 227-line module.

## II. Aggregation — `Semiring.lean`, `Instances.lean`

A tower: `NSemiring` (both distributivities, both annihilations, `*` *not* commutative — the base matrices live on) → `CSemiring` (+`mul_comm`, whose one real consumer is the middle-four interchange Kronecker needs) → `CompleteCSemiring`, the load-bearing class: `csum : {ι : Type} → (ι → S) → S` over an *arbitrary* index type — countability is a remark about models, not a premise of meanings, and the code proves it by never needing it. Seven axioms, each purchased by a downstream theorem: `csum_point` → matrix identities; `csum_swap`/`csum_prod` (Fubini) → associativity of composition and the mixed product; `csum_mul_left` → distributivity through aggregation; `csum_pair` (`csum` over `Bool` = binary `+`) → the axiom an adversarial review proved *missing*, from which binary additivity is now derived for every carrier rather than fenced.

Iteration: `StarSemiring` assumes exactly one law, `star x = 1 + x·star x` — and its docstring says what it does *not* assume, because the unrolling equation has multiple solutions (memorialized in-tree: `retry_cost_ambiguous`, three `rfl`s). `KleeneStar` adds leastness — `b + a·x ≤+ x → star a · b ≤+ x` — over the additive order `≤+`, proved *by `rfl`* to be the Stratum-I monoid order. Satisfaction becomes characterization: `retry_least`.

| Carrier | Reading | Signature fact |
|----|----|----|
| `Prop` | possibility | `csum = ∃`; `≤+` is implication; full Kleene |
| `Cost` | worst-case bound | three-tier max-plus with genuine `⊥`; complete because suprema are *attained* |
| `Prob` | most-probable (Viterbi) | dyadic sub-semiring, exact arithmetic; idempotent `+`, so Kleene |
| `SqZero P M` | expectation | square-zero extension; `star ⟨p,m⟩ = ⟨p*, (p*·p*)•m⟩` — the design’s `p* m p*` proved; `pi_star`/`pi_retry`: the projection commutes with the whole solve |

## III. The meaning space — `Matrix.lean`, `Star.lean`, `Gate.lean`

`Mat S ι κ := ι → κ → S`. **A model is such a matrix; so is a workflow** — at the semantic level there is no separate notion of “program,” only resource-weighted transitions. Composition is Chapman–Kolmogorov (`csum` over the middle index; associativity from Fubini), and the `NSemiring (Mat S ι ι)` instance makes the category laws and the semiring laws *one statement*. Value-dependent sequencing lives here as a definitional equality — `dependentSeq_eq_comp := rfl` — the monadic structure of the meaning space, by unfolding.

Structured citizens: `pointMat` (0-1 matrices = Transforms = the deterministic, central fragment), `caseMat` (coproduct branching), `fanMat` (the truncating fan), `retryTrunc` (the *fueled* star `(I + L + ⋯ + Lⁿ)·E` with provably finite cost — “checkBounds” as the existence of a star, not a graph algorithm), and `reach` (the genuine `Prop`-matrix star: `csum` of powers, proved the least reflexive-transitive relation containing `M` and the least solution of `X = I + M·X`). `Gate` prices permission: `gate = smul ∘ indicator`, refusal is `0`, and `0` annihilates both compositions — one scalar replacing halt, exception, and bias.

## I. VThe domain, as carrier and index choices

| Module | The choice it makes | The theorem that pays |
|----|----|----|
| `Env` | one sample point `ε : C → O`; model, tool, human = three faces of one index; `pin` = counterfactual substitution | `share_ne_dup` — copy-naturality refuted by a two-point witness; `pin_pin_comm` — fork-by-pin-set well-defined |
| `Panel` | the monoid semiring `K → S`; fan-in = a reducer monoid | `conv (delta a) (delta b) = delta (a ⋄ b)`; licences priced by algebra: contributions reorder free, factors cost `CMonoid`, speculation costs `IdemCMonoid` — with a negative example |
| `Trace` | which schedules are *equal*, as a genuine `Quot` (Mazurkiewicz) | `indep_comm` by one `Quot.sound`; the converse gives it content; `deriv := actL` — fork/resume as the Brzozowski derivative |
| `Scope` | `Last`-monoids per axis; scoping = `actR` | innermost-wins *is* the monoid’s non-commutativity; axes commute by the product |
| `Context` | compaction = an interior operator on an ordered index | the `const ε` collapse’s consequences, each `rfl` |
| `Pareto` | tiers = regions of a partial order | “the best workflow” provably does not exist without a named scalarization |

## V. Syntax, graded — `Frag.lean`, `Term.lean`

Only now, syntax — downstream of the meanings by design. `Frag` (`static | bounded n | monadic`) is itself an `IdemCMonoid` with **three arithmetics matched to three composition shapes**: `join` = max (sequencing/alternation — one thing in flight at a time), `par` = `+` (tensor — widths in flight add), `scale n` = `n · max 1 m` (fans — multiplicities multiply, and the static shell always counts as itself). `Term` has twelve constructors, each grading itself in its result index so every smoke example elaborates at a literal grade with no coercion; `bindT` is `.monadic` unconditionally (value-dependence, honestly graded); `shareT` carries an abstract label with duplication as the default; and there is deliberately no weakening constructor.

## V. ITwo meanings, one quotient — `Meaning.lean`

The syntax exists to admit multiple homomorphisms out. **`μ_S`** sends terms to matrices; its twelve clauses *are* the design’s TCM table, each equation theorem genuinely `rfl` because the fold was defined by the rows — specify by homomorphism, then solve. **`μ_ext`** sends terms to per-runner partial functions over a `Site`/`Key` calculus, where the crown theorem — `muExt_key_irrelevant`, a twelve-constructor induction — establishes that *key-sensitivity of the runner is exactly the observability of sharing*, and `muExt_dupPair_ne_sharedPair` makes the share/dup decision observable rather than conventional. Equality is the quotient: `WEq`, `Workflow := Quotient wSetoid`, with `seqT` lifted through it — Lean’s quotients doing the one thing no other host could: making “equal iff equal in meaning” a *type*. The two meanings’ independence is an impossibility theorem: `one_add_one_of_muS_respects_WEq` — any carrier whose quantitative meaning respected extensional equality could not count.

## V. IIA worked example — *harden a patch*

A workflow with everything you asked the framework to carry: multiple prompts, sub-agents, a shared consultation, value-dependent branching, human consent, and a bounded revise loop. First the leaves — five prompts and one tool, declared as a signature (the syntax is semiring-free; leaves mean nothing until an `Interp` is chosen):

    inductive Ops : Type → Type → Type
      | draft   : Ops Spec Patch        -- prompt: write the patch (deep model)
      | style   : Ops Unit Guide        -- prompt: recall the style guide
      | correct : Ops (Guide × Patch) Findings   -- prompt: correctness review
      | secure  : Ops (Guide × Patch) Findings   -- prompt: security review
      | simple  : Ops Patch Findings    -- prompt: simplicity review
      | applyP  : Ops Patch Unit        -- tool: apply to the working tree

The three-lens panel. Copying the *patch* to all three reviewers is a Transform — copying a value is free, it is not re-asking a question. But two reviewers also consult the style guide, and that *is* a question: without annotation each `prim .style` occurrence would be a distinct consultation (dup-by-default — two independent samples of the guide). `shareT` makes it one consultation, twice read:

    def panel : Term Ops G L .static Patch Findings :=
      .seqT (.pureT fun p => (((), p), (((), p), p)))          -- Δ : the free copy
        (.seqT
          (.parT (.seqT (.parT (.shareT sg (.prim .style)) (.pureT id))
                        (.prim .correct))                        -- sub-agent 1
                 (.parT (.seqT (.parT (.shareT sg (.prim .style)) (.pureT id))
                        (.prim .secure))                         -- sub-agent 2
                        (.prim .simple)))                        -- sub-agent 3
          (.pureT mergeFindings))                                -- fan-in: the reducer

Note the grade: `static` — by `rfl`. A *fixed* three-agent panel has zero data-dependent width (`par static static = static`: widths in flight add, and three known branches add nothing unknown); every fold over it is exact. Contrast the dynamic form — one reviewer per file the draft touched, a width the *values* choose — which is precisely what `fanT` grades:

    def perFile : Term Ops G L (.bounded 8) (List Patch) (List Findings) :=
      .fanT 8 (.prim .simple)     -- at most 8 sub-agents; the input list picks how many

The revise loop: panel verdict decoded by a Transform into a coproduct — value-dependent branching on generated tokens, at grade `static`, because the alternatives are enumerated even though the token space is not — then a fueled retry, and finally the consent gate before the tool runs:

    def attempt : Term Ops G L .static Spec (Sum Patch Spec) :=
      .seqT (.scopeT deepModel (.prim .draft))                   -- prompt under a scope
        (.seqT (.seqT (.pureT fun p => (p, p))
                      (.parT (.pureT id) panel))                 -- keep the patch beside its review
               (.pureT decodeVerdict))                           -- Findings → approved patch ⊕ revised spec

    def harden : Term Ops G L .static Spec Unit :=
      .seqT (.retryT 2 attempt)                                  -- ≤ 3 attempts; grade unchanged
            (.gateT consent (.prim .applyP))                     -- refusal = 0, annihilates downstream

**One term, four instruments.** `μ_S harden` reads the same syntax in any complete semiring; choosing the carrier chooses the question:

| Carrier | The question `μ_S harden` answers | Where the theorems bite |
|----|----|----|
| `Cost` | worst-case spend: sequencing adds, the panel’s branches add, the retry is the *truncated* star — `retryTrunc 2`, provably finite (`retryTrunc_cost_finite`) | the static grade promises exact folds, and `widthT harden = some 0` confirms no data-dependent width |
| `Prob` | the most-probable run (Viterbi): the likeliest path through draft–review–revise | idempotent `+` ⇒ full Kleene: `retry_least` pins the loop’s meaning as the least solution |
| `SqZero Prob Cost` | expected spend given success weights — the moment component of the star is literally `p* · m · p*` | `pi_retry`: the probability projection commutes with the whole solve |
| `Prop` | can it succeed at all — reachability through the gate | `gateT false` collapses the meaning to `zeroMat`: consent withheld annihilates the tool call and everything after it |

**What `μ_ext` sees.** Extensionally the term is a partial function per sample point, and the site calculus makes the sub-agent structure literal: the three reviewers sit at distinct `Key`s (`parL`/`parR`-paths under each `retry trip`), so they are *independent samples* — exactly `dupPair`’s semantics, and `muExt_dupPair_ne_sharedPair` is the theorem that the runner can tell. The two `shareT sg` occurrences rebase to the *same* key, so the style guide is consulted once and read twice — while each retry trip re-draws everything else, because the trip index is part of every absolute key. Sharing survives the copy; independence survives the loop; neither is a convention of the interpreter, both are theorems of the fold.

**What the scheduler may do** is priced by the reducer’s algebra, not guessed: if `mergeFindings` is commutative, the panel’s three sub-agents may run and land in any order (`foldPanel_perm`); if it is idempotent, the runtime may speculate and race duplicates (`foldPanel_dup`); if it is the free monoid, declaration order is semantic and the scheduler must preserve it. Three operational freedoms, three algebraic hypotheses, zero configuration flags.

Honesty note

The listing is written against the current twelve-constructor API, so the three-lens panel is spelled with nested `parT` — the n-ary `panelT` with its reducer-carrying convolution is tracked (acat-x9v, with its semantic groundwork already landed in `Panel.lean`). The consent gate takes the syntax’s `Bool`; the grant-lattice version is acat-755.

## V. IIIThe Mathlib migration — what the shelf replaced

On the owner’s directive the package stopped replicating standard constructions. The migration ran as six build-gated phases (hierarchy, carriers, order pieces, then the quotient and width theorems on the new foundation, then an adversarial purity review with a constant-dependency-graph audit). The scoreboard:

| Ours (deleted or aliased) | Mathlib’s | What fell away |
|----|----|----|
| `PMonoid`/`CMonoid` | `Monoid`/`CommMonoid` | eight law fields |
| `IdemCMonoid` + its order | `Std.IdempotentOp` mixin; the order via `SemilatticeSup`+`OrderBot` | the whole seven-lemma order development |
| `NSemiring`/`CSemiring` | `Semiring`/`CommSemiring` | fourteen fields, eleven law wrappers |
| `IdemAdd` + `addLe` + `KleeneStar` | `IdemSemiring`/`KleeneAlgebra` | the ten-lemma `≤+` development — and `star_le_left`, once our axiom, is now Mathlib’s theorem `kstar_mul_le` |
| `PMod` (11 fields) | `Module` | the “fifth monoid presentation” dissolved: its additive half *is* `AddCommMonoid` |
| `Cost` + its supremum machinery | `Multiplicative (WithBot ℕ∞)` | the attained-suprema construction (~40 lines of the hardest proofs) — `IdemSemiring.ofSemiring` in one call |
| dyadic `Prob` workaround | `ℝ≥0∞` | the real probability carrier lands; the workaround retires |
| `SqZero` | `TrivSqZeroExt` | the expectation semiring was on the shelf all along |
| `Interior` | `ClosureOperator (OrderDual _)` | interior *is* closure, upside down |
| `Pareto` laws, `pin`, `Tally`, key monoid | `Prod` orders, `Function.update`, `Multiplicative ℕ`, `Monoid (List α)` | hand-passed order laws; five pinning proofs become library lemmas |
| `Trace`’s hand-rolled closure | `Con.Quotient (conGen Swap)` | the congruence machinery — while the Mazurkiewicz quotient itself survives |

**The survivors’ registry** — hand-written only where the audit re-verified (by grep of Mathlib itself, not trust) that the object is absent: `CompleteCSemiring`/`CompletePMod` (no arbitrary-index complete semiring; quantales come closest and exclude the expectation carrier), `Mat` (Mathlib’s `Matrix` multiplication is `Fintype`-bound), `MSemiring` (`MonoidAlgebra` is finitely supported), `StarSemiring` (Mathlib’s weakest lawful star is `KleeneAlgebra`, whose idempotent `+` the expectation semiring lacks), `actR`/`actL` (vs `DomMulAct`, with the trade-off argued in the docstring), `LastOpt` (no right-zero semigroup), and the Mazurkiewicz trace monoid. Each is either the domain’s genuine contribution or an upstream candidate.

**Landed on the new foundation:** the coarsened quotient — `WEqR`, under which `Workflow` finally has laws (associativity, units, gate/scope absorption; probed clean on `propext, Quot.sound` alone) while `dupPair ≉ sharedPair` survives on `propext` — honestly scoped to the six-constructor sub-algebra pending `Key.splice`; and the width bound with its strictness witness: `peak (fanT 7 (pureT id)) = 0 < 7`, because `peak` counts only sites that reach a `prim` — the grade and the count are finally two different instruments.

The closing arc, filed

The review’s eight-step shortest list to make “four ideas, two from the shelf, none replicated” simply true is in the tracker: delete 89 zero-consumer wrappers; retire the 31 live aliases (the private vocabulary is itself a representational choice); four remaining stdlib replications (`Site.strip` *is* `List.dropPrefix?` — behind a false absence claim, the audit’s sharpest catch); `Frag := ℕ∞` (the grade type is `ℕ∞` encoded four times, and the collapse fixes the one remaining grade lie, `scale 0 monadic`); and **one star** — `kstar x := csum (x ^ ·)` over a `CsumIsSup` mixin, replacing four hand-built Kleene instances and making iteration a *derived* notion of the resource algebra, which is the design’s own claim made true in the Lean.

## Why this is the simplest, purest form — and where it honestly is not yet

The purity is enforced by discipline you can grep for: meanings are allowed to be uncomputable (exactly the classical uses the design predicts — suprema and point-masses — and no others); decidability was *evicted* from the semantic layer after four independent review passes converged on it, which is what re-admitted the trace monoid as a panel key; every law is inherited from a named structure rather than asserted (the order from idempotence, additivity from `csum_pair`, licences from the reducer’s algebra); and the negative results are theorems — the retry ambiguity, the share/dup separation, the label collision, the `1+1=1` impossibility — so the design’s boundaries are as machine-checked as its content.

The honest impurities, tracked

`WEq` is currently too fine: the quotient has one operation and no laws until key-renaming invariance lands (acat-5b7). `widthT` is a syntax-to-syntax homomorphism check until the semantic width bound `peak t ≤ widthT t` exists (acat-vbl). The projection π between the two meanings awaits both (acat-qtv). `shareT` trusts the designer about body agreement (acat-bmc). The simplest representation is not the one with nothing left to do — it is the one where everything left to do is a stated theorem with a tracker id, and nothing anywhere claims more than it proves.

A monoid, a complete semiring, a matrix, and a quotient — everything agentic is a choice of carrier or index.
