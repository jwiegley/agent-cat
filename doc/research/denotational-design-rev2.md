# A Denotational Design for Agentic Workflows

Working notes, revision 2.1, prepared for John Wiegley on 2026-08-11. This
revision superseded revision 1 ("A Categorical Lexicon"), whose syntax-first
ground rule it inverted. Method: Conal Elliott's denotational design, applied
after a full reading of the corpus distillation, three independent
denotation-first designs, a fidelity audit and a mathematical audit, and a
survey of Lean 4 and Haskell as realization hosts.

> **Status: superseded on 2026-08-26.** This page is an exploratory design
> record converted verbatim from `doc/design.html`. It is not the package
> specification. The current architecture uses the bare-question world
> `Ω = (c : Code) → Q c → El c`, the intent-erasing denotation of the
> five-form annotated Lean `Plan`, and the Haskell production runtime.
> `Request = Q × Intent` records executable `consult | observe | effect`
> policy; reuse, ordering, permission, routing, retries, timeouts and
> transport remain below meaning. The current account is
> [`../meaning-and-representation.md`](../meaning-and-representation.md) and
> the Texinfo manual.

*Meanings first: every concept in the agentic ontology given a simple, precise
mathematical object; the API derived by type class morphisms; the laws already
paid for; implementation, including agent-functor, Lean 4, and Haskell,
considered only afterward, as realizations of a denotation that does not move.*

## 0. The stance, and a retraction

Revision 1 of this document opened with the rule “syntax before semantics” and organized everything around a term algebra. That order is here reversed, deliberately, following the discipline distilled from thirty-five years of Elliott’s work: **give every type a simple, precise mathematical meaning, and let everything else be derived from it.** The governing asymmetry settles every argument below: *meaning constrains implementation; implementation never constrains meaning.* For each type T, name the object ⟦T⟧ and the meaning function ⟦·⟧ : T → ⟦T⟧; require it to be a homomorphism for every abstraction T inhabits (“the instance’s meaning follows the meaning’s instance”); *solve* the morphism equations for the operations rather than implementing and checking; read a morphism that will not close as a diagnosis, never as a reason to weaken the specification; and let the meaning be uncomputable — “a specification that cannot run cannot be confused with the artifact it constrains.”

Syntax survives in exactly one place, and it is downstream: a free term algebra whose entire purpose is to admit *several* homomorphisms out — the extensional meaning, the quantitative meanings, a rendering. That is a consequence of the design, not its starting point. The `agent-functor`/`incite` repositories, which Revision 1 treated as the frame, appear here only in §9 as a case study: one team’s partial, independently-arrived-at realization, valuable chiefly as evidence and as a source of failure data.

## 1. The domain in its own words

A person has a difficult job and no single pass at it will do. He writes prompts. Some he varies without asking anyone anything — substitute a name, add a rubric, wrap a brief. Others he hands to a model, which reads text and writes text, sometimes reaching out to tools that change the world. Models come in kinds — deep and slow and expensive, cheap, fast — and each runs inside a harness that supplies its tools and remembers what has been said, up to a limit, after which the memory is squeezed. He wants the same brief examined from several points of view at once, by different reviewers on different models, and the findings brought back together — sometimes in order, sometimes counted, sometimes deduplicated. He wants to retry what failed, to be asked before anything irreversible happens, to run a line of work again from the middle with one answer changed, and to know *before he starts* what it will cost, how long it will take, how many things will be in flight at once, and how likely it is to work.

## 2. The denotation table

Three independent designs were drafted and audited; what follows is the synthesis, with each entry the post-audit form. Two objects organize everything: an **environment** that answers consultations, and a **resource semiring** that prices transitions.

> **Hypothesis · where randomness lives (stated, not assumed)**
>
> Consultation sites form a countable index set I; every answer space is standard Borel. By the randomization lemma (Kallenberg, *Foundations*, Lem. 3.22) every kernel then factors through a uniform sample, so the environment may be taken as E = I → Outcome with one probability measure on E ≅ \[0,1\]<sup>ℕ</sup> at the outermost edge. Randomness enters the design once, there, and nowhere else. (The alternative for a genuinely higher-order design is quasi-Borel spaces; plain **Meas** is not an option — Aumann 1961.)

| Concept | is a representation of… | notes |
|----|----|----|
| Prompt | an element of a monoid P, with a *subadditive* size ‖p•q‖ ≤ ‖p‖+‖q‖ | wording is semantic; the size is lax, as real tokenizers are |
| Rubric | a judgment A → S: which answers count, and how much | related to Prompt by a non-injective rendering judge : P → Rubric — two objects and a morphism, not one object |
| Consultation (Turn) | one point of the index I: a model call, a world command, or a human query — three faces of one thing | the un-privileging of the model (from the interaction design): model, tool, and human are answered by the same environment |
| Environment | ε : I → Outcome, one complete answer sheet for every consultation the run could make | a sample point; the measure over E sits at the edge |
| Model | a primitive S-matrix on prompts, P → P → S, row-(sub)stochastic in the probability factor | not a different kind of thing from a workflow; the invariant travels in the object (a (matrix, proof) pair) |
| Model Tier | a region of the **Pareto preorder** on S | partial by nature: “the best workflow” is not well-defined; any scalarization is an extra, named choice |
| Transform | a plain function P → P; its matrix is the 0-1 point matrix \[b = f a\] | exactly the deterministic (copy-natural) morphisms; central by construction |
| Tool | a matrix on the world-extended index (W×P), carrying a **footprint** in a commutative idempotent monoid of regions | the footprint is the licence for parallelism (§6b) |
| Workflow i o | two meanings, §3: an ε-indexed partial function *and* a scope-indexed S-matrix | the pair is the design’s answer to “caching vs. cost” |
| Panel | copy at *named indices*, a Kronecker/external product, then a **reducer monoid** — convolution in the free S-semimodule on the reducer’s monoid | Elliott’s b ← a applicative (Thm 16), *not* the pointwise Reader; the distinction is the whole content of his Figure 9 |
| Reducer | a monoid on findings; its algebra is a **licence on the scheduler** | commutative ⇒ may reorder; idempotent ⇒ may duplicate, retry, speculate (`unamb`); neither ⇒ declaration order is semantic |
| Context | an element of an information-ordered monoid K; **compaction** is an interior operator: deflationary (κk ⊑ k), idempotent, monotone | workflows are Atkey-parameterised by context indices; the collapse κ = const ε is one available choice with four derived consequences (§6e) |
| Session | an element of the monoid semiring Trace → S over the **Mazurkiewicz trace monoid** (independence = footprint disjointness); efficiently, its memo trie | independent turns commute, dependent ones do not, and Foata normal forms keep factorization unique — one object discharges both panel commutativity and convolution |
| Fork / Resume | the **Brzozowski derivative** ∂<sub>u</sub> f = λw. f(u⋅w) of a session at a prefix; editing a recorded answer is **counterfactual substitution** ε\[q ↦ a\] | run / resume / fork are three points in a lattice of pinnings: pin nothing, everything, some |
| Grant / Consent | a bounded distributive lattice acting on workflows through the semiring’s own {0,1}: gating is scalar multiplication, refusal is 0 | deny-by-default = 0; nested grants intersect; annihilation propagates refusal with no `Halt`, no exception, no bias to stipulate |
| Scope / Harness | an element of a monoid G (one `Last`-factor per independent axis); scoping is **precomposition** | a harness is not a morphism anywhere: it is an algebra — a point of the environment’s tool face plus a scope value |
| Command / Skill / Agent / Sub-agent | not types: a scoped leaf; a context transformer K → K; a scoped leaf at reset index; the index-reset itself | four domain nouns, zero new objects |

### The resource semiring, honestly

S must be a **complete (Conway) commutative semiring** — stars and countable row-sums are used, so say so. The working instances: `Bool` (possibility); ℝ<sub>≥0</sub>∪{∞} (cost); the Viterbi semiring (\[0,1\], max, ×) (consensus weight — *not* (\[0,1\],+,×), which is not closed under addition); max-plus *with* -∞ adjoined as the true zero (latency); and Eisner’s **expectation semiring** P ⋉ M — the square-zero/dual-number extension, the same object that gives forward-mode AD — whose product computes *expected* cost through a composite. Two corrections the audit forced: **peak width is not a semiring factor at all** (its would-be one and zero coincide); it is a separate monoid fold. And sequential/parallel composition satisfy **exchange only as an inequality, per factor, in opposite directions** — barrier-synchronizing two pipelines *raises* latency and *lowers* peak width. The premonoidal defect of Revision 1 returns here quantified: a measured gap rather than a yes/no.

## 3. Two meaning functions and one fibration

The deepest disagreement among the three designs was where nondeterminism lives, and the audits showed each pure position fails somewhere: distributions *inside* the meaning make caching a falsehood (“the cache serves one sample as the kernel”); a bare environment-indexed function loses the quantities. The synthesis keeps both, as two homomorphisms out of one term algebra:

    ⟦·⟧ext :: Workflow i o → E → (W × i) ⇀ (W × o)     -- extensional, per sample point
    ⟦·⟧S   :: Workflow i o → G → (W × i) → (W × o) → S  -- quantitative, a matrix

with a projection π relating them: the probability factor of ⟦w⟧<sub>S</sub> is the pushforward of ⟦w⟧<sub>ext</sub> along the measure on E. **Semantic equality is equality of ⟦·⟧<sub>ext</sub>** (the audit rejected weakening equality to protect a caching story); optimization is *refinement* in the quantitative meanings alone. What Revision 1 of the quantitative design asserted as a redefinition of equality survives as a theorem about two morphisms — a fibration whose one law has teeth:

An optimisation moves down a fibre. A change that moves between fibres is not an optimisation, whatever the commit message says.

Two immediate dividends. **Caching:** for a fixed ε, replaying a recorded answer *is the identity* — ⟦cached w⟧<sub>ext</sub> = ⟦w⟧<sub>ext</sub> on the nose, because the sample lives in the environment, not in the meaning; quantitatively it is a move down the cost fibre. The one caveat is semantic and must be kept: the *index* at which ε is consulted is part of the meaning, so `share` (consult once, reuse) and `dup` (consult twice) are different terms — the ε-indexed category is cartesian pointwise, but the pushforward is not, exactly as before. **Fork:** ε\[q ↦ a\] makes “edit one answer, rerun the cone” a substitution theorem instead of a storage discipline.

## 4. The derived API: type class morphisms

The meanings inhabit standard structures; the API is read off them — no operation is named that a standard class supplies. One equation per operation; the laws arrive already paid for.

    Category:        ⟦id⟧ = I                ⟦g ∘ f⟧ = ⟦g⟧ · ⟦f⟧          -- matrix product / composition
    Lax monoidal:    ⟦f ⊗ g⟧ ≤ ⟦f⟧ ∥ ⟦g⟧    (equality on disjoint footprints)   -- juxtaposition
    Additive:        ⟦0⟧ = 0                 ⟦f ⊕ g⟧ = ⟦f⟧ + ⟦g⟧          -- alternatives / fallback
    LeftSemimodule:  ⟦s ·> f⟧ = s · ⟦f⟧                                      -- gating; refusal = 0, annihilating
    StarSemiring:    ⟦retry f⟧ = ⟦f⟧∗        (defined iff the star exists in S)  -- iteration
    Panel:           ⟦panel R ws⟧ = convolution in S⟨K_R⟩   (the b ← a applicative)
    Reader (scope):  ⟦scope g f⟧ h = ⟦f⟧ (h ⊕ g)                             -- precomposition; innermost-wins is a theorem
    Comonad (fork):  ⟦∂_u s⟧ = ⟦s⟧ ∘ (u ⋅ −)                              -- Brzozowski / coKleisli

Deliberately *stratified*, not absent: **`Monad`**. Revision 2.0 refused bind outright; the refusal does not survive the objection that a later turn’s direction may depend on the tokens an earlier turn generated — and the fidelity audit had already condemned the refusal’s ancestor (its Finding 6: a computability rationale dressed as a semantic one inverts “meaning constrains implementation”). The meaning space *is* monadic: Chapman–Kolmogorov is bind, and over a complete semiring the matrix of w \>\>= k is the well-defined sum Σ<sub>b</sub> μw(a,b)·μ(k b)(c); the Monad TCM equation ⟦w \>\>= k⟧ = ⟦w⟧ \>\>= ⟦·⟧∘k is available and honest. What full bind costs is not meaning but *instruments*: cost, width, and plan are folds over the term, and a term containing an opaque b → Term has no finite fold. So the language is stratified, with the fragment as a type index (anti-pattern 9’s antidote — an object, not a prohibition): **(i) static** — branching by `Choice` through a decoding Transform (the huge token space factors onto a finite coproduct of verdicts; the payload flows as data while the verdict steers), fueled loops; every fold exact. **(ii) bounded** — data-dependent width ≤ N; folds return honest suprema. **(iii) monadic** — plan-then-execute, unbounded dynamic fan-out; the meaning is a perfectly good kernel, the static instruments answer “no a-priori cost,” *which is the truth* — though the prefix’s own matrix is a prior over the intermediate, so expected cost remains estimable by sampling, as a runtime instrument honestly labeled. The corpus’s own precedent is Fran’s `untilB`/`switch`: value-dependent continuation *given a denotation*, not refused. Design guidance: write in the lowest fragment that expresses the job.

Genuinely absent: **`Cartesian`** — the comonoid (copy/discard) exists on every object but copy is natural only on the deterministic subcategory (Fritz Def. 10.1); instantiating the class would assert the law the domain most famously lacks. And note what the lax monoidal row does: it converts Revision 1’s all-or-nothing interchange story into an ordered structure map, with equality restored exactly on the footprint-disjoint fragment — *interchange is not a law; it is a law of a computed sub-algebra.*

## 5. Three solved forms

The method’s heart is that combinators are *solved for*, not designed. Three solvings, each audited.

### 5.1 The panel

Posit only copy, tensor, and a reducer R; compute what ⟦w₁ ⋈ w₂⟧ must be. The deltas collapse to convolution: (⟦w₁⟧a ⊛ ⟦w₂⟧a) c = Σ<sub>b₁⋅b₂=c</sub> ⟦w₁⟧a b₁ ∥ ⟦w₂⟧a b₂. Then strengthen by generalizing — nothing used the concatenation; replace it with any bilinear R — and three consequences fall out that are the whole of panel design: **R must be a monoid** or the n-ary panel is ambiguous; **its unit is the empty panel**, whose absence predicts special cases; and **its algebra licenses the scheduler** (commutative ⇒ reorder; idempotent ⇒ speculate and race). Sums, meanwhile, are *alternatives* (fallback, beam search) — a different combinator, not a variant. The audit’s type correction stands guard here: this applicative is Elliott’s b ← a (free semimodule on the index monoid), and on the Reader a → b the same `liftA2` computes the pointwise product instead. Fan-out over a lens×backend grid is the *external* product with a separate fan-in Σ — and Σ : (K→S) → S is genuinely a semiring homomorphism (the augmentation of the monoid semiring).

### 5.2 Retry — and the bounds check, derived

For w : A → A ⊕ B with policy scalar d, the fixed point L = M<sub>A</sub>·(d·L) + M<sub>B</sub> solves by star-semiring Gaussian elimination to L = (M<sub>A</sub> d)∗ M<sub>B</sub>. Read it per factor, changing only the semiring: at `Bool`, termination possibility; at worst-case cost, x∗ = ∞ unless x = 0 — so *“every cycle must pass a bounded node” is not a graph algorithm to design; it is the existence of the star in this semiring*, fuel is the star’s truncation, and “unbounded” is its divergence; at probability, absorption of a Markov chain; at the expectation semiring, the expected cost of a retry loop is p∗ m p∗, in three lines. This is the one place any of the three designs *deduced* a load-bearing piece of existing machinery rather than re-describing it.

### 5.3 Scoping

Scope acts on the *domain* of a reader, so it is precomposition — one TCM equation, ⟦scope g f⟧ h = ⟦f⟧(h ⊕ g), with ⊕ the per-axis `Last` monoid. Innermost-wins is then a theorem, axis-commutation (mode × agent) is bifunctoriality of the product, and “a model key travels with its backend” is *derived*: they are one coordinate, not two. Mind the classic direction error the audit caught elsewhere: local σ ∘ local τ = local (τ ∘ σ) — precomposition is contravariant.

## 6. Failed morphisms and their repairs

“A morphism equation that will not close is the method’s most valuable output.” Five closed, two resisted.

**(a) Copy-naturality fails** — a model run once and copied is not a model run twice. Repair (weakest sufficient class): do not instantiate `Cartesian`; keep the comonoid, state that copy is natural exactly on the deterministic subcategory, and make sharing an *operation*: `share` reuses a consultation index, `dup` spends two. Both meanings see the difference — extensionally by the index, quantitatively by the cost — and a “callers must ensure determinism” contract is deleted in favour of two combinators.

**(b) Tools act on a shared world** — the equation demands an argument the meaning lacked. Repair (augment): thread W through the index (Róman’s runtime wire, now derived rather than invoked), carry a **footprint** per tool, and prove exchange on the footprint-disjoint sub-algebra. The same independence relation generates the Mazurkiewicz trace monoid of §2 — one choice, two obligations discharged. Parallelism of two world-touching steps is then *total on its typed domain*, not a convention.

**(c) The human (Ask)** — an answer drawn from no distribution we own. Repair (augment): index the meaning by a *human strategy* H; equality is “for every strategy.” A prediction falls out: two Asks under one tensor are *cacheable but not central* — a strategy may depend on arrival order — independently reproducing the earlier finding that cacheability and centrality are distinct predicates. The not-yet-answered human is ⊥ in a pointed CPO of answers, which also gives the design its missing race combinator: reducers monotone in the information order, first-past-the-post as `unamb`.

**(d) The cache** — resolved by the two-meaning split of §3: identity extensionally, refinement quantitatively. What remains of the failed equation is honest vocabulary: `pin` (counterfactual substitution) is for fork and resume, and is not the denotation of a cache.

**(e) Bounded context** — composition needs composable context indices. Repair (augment): Atkey-parameterise, Workflow k k′ i o; compaction is a morphism in the index category, an interior operator whose loss is visible in exactly one factor — *information flow is not a fifth decoration; it is the factor that measures what compaction destroys.* The collapse κ = const ε (fresh context per turn) is one point in this space, with four consequences derived, not designed: the parameterised monad becomes ordinary; each leaf’s matrix is history-free; the matrix is finite-dimensional in the prompt; and pinning is well-defined. **The absence of first-class multi-turn context and the soundness of content-addressed caching are one decision.**

**Resisting repair, reported:** (i) the probability factor is unobservable — ⟦·⟧<sub>S</sub> can only ever be sampled, so every test is a statement about one path; (ii) the resource preorder is Pareto, hence partial — “the best workflow” does not exist without a scalarization the denotation does not supply and must not pretend to.

## 7. What the audits killed

Corrections carried forward — so they stay dead

**Convolution on the wrong type.** All three designs cited Elliott’s Theorem 16 while using the Reader applicative; the theorem is about b ← a, and on a → b the same formula is the pointwise product. **“Concurrent semiring” misattribution.** The latency factor violates CKA’s exchange inequality in the required direction, and peak width is not a semiring at all (its 0 and 1 coincide) — width is a monoid fold. **Function-space measures.** Two designs put a measure on a space of interpretations; in **Meas** no such σ-algebra exists (Aumann 1961) — hence the countable-index randomization hypothesis, stated in §2. **Transform as monoid endomorphism** forces compaction to emit only empty prompts (the size argument is three lines) — Transforms are plain functions. **Halting via `Choice`** confuses value-routing with effect short-circuiting — gating as semimodule scalar replaced three mechanisms and an exception path. **“Fan-out is free”** in a Kleisli-of-State category is false; the panel is a primitive, and the trace monoid must be commutative *and* idempotent (or Mazurkiewicz) for it to mean what it claims. **(\[0,1\],+,×) is not a semiring.** **Cost as a pair-component** does not compose (the second stage’s cost depends on the first’s output) — the quantity goes on the transition; that failed equation, met honestly, is what forced the matrix meaning and is the best single page in the three drafts.

## 8. Realization: Lean 4 and Haskell

Only now, with the denotation fixed, the hosts — per the corpus’s own Step 9: efficiency is a refinement of, or a compiler for, a denotation that has not moved.

### What the corpus itself testifies

Elliott ran this comparison one proof-assistant generation early. On the Haskell side: the GHC plugin behind *Compiling to Categories* exists because lambda and application cannot be overloaded — a language-level workaround; the flagship deck “asserts the laws and exhibits instances, but *proves nothing*”; abstraction is a module convention. On the Agda side: “dependent types carry \[the morphism property\] *in the type index*. The type checker then enforces it” — implementations indexed by the semantic object they denote, so “nothing of the wrong meaning is constructible”; invariants “compose by the same operations as the values”; whole timing matrices become a `refl` proof. The costs, in his own record: 25 pages of machine-checked proof for one result, and isomorphism transport carried as a *constructor of the syntax* because propositional equality is too coarse.

### Lean 4

The survey’s headline: the meaning spaces of §2 largely *exist in Mathlib today*. `ProbabilityTheory.Kernel` with Markov instances and the full compositional algebra (`∘ₖ`, `∥ₖ`, `×ₖ`, `⊗ₖ`, plus `copy`/`discard`/`swap`/`deterministic`); the categories `Stoch` and `SFinKer` with copy-discard structure — the Markov-category home for §6(a) — and the Giry monad; semirings, semimodules, `Tropical`. The highest-leverage decision: prompts are countable, so **`PMF`** — a genuinely lawful monad with `do`-notation — can carry the edge measure with near-zero measurability tax. Two features answer the method’s two chronic pains directly: **kernel-level quotients** make “equality is semantic equality” a definable type (`Quotient (Setoid.ker denote)`), with `Quot.lift` turning respect-for-meaning into a proof obligation — dissolving exactly the transport pain Agda paid; and the TCM equations become *theorems* (`def cost : WorkflowMonoid →* Tropical ℝ≥0∞` does not typecheck without the proof). `@[csimp]` is Step 9 as a language feature: the fast replacement is admitted only with a proved equality. Sober costs: thin LLM/HTTP ecosystem; the noncomputable-denotation/computable-implementation seam is permanent and must be bridged by stated correspondence; no graded `do` without a custom elaborator; no quasi-Borel spaces in Mathlib; weak coinduction — and the corpus’s favourite structures are coinductive.

### Haskell

The working-system champion: the algebraic core is nearly free (reducers law-checked in four lines via `quickcheck-classes`; content-addressed replay from one stable hash; green-thread concurrency and Nix deployment best-in-class), with a 25K-line existence proof on disk. What it costs is the proofs: laws are properties tested on generators against a mock interpreter; the quotient is normalising-constructors-plus-render-equality with an untheorized congruence; semirings are a fringe dependency; the LLM client layer is hand-rolled. And the survey’s sharpest sociological finding, generalizing from the case study: *the mathematically prettiest modules are the ones still unwired* — denotationally-designed Haskell’s core is cheap to write and structurally at risk of staying ornamental.

The recommendation all three surveys converge on

**Fix the semantics in Lean 4; treat execution as Step 9.** State the denotation over `PMF`/kernels, define workflow equality as the quotient by the meaning, prove the type-class-morphism equations as theorems (Mathlib supplies the “already lawful” target category the corpus’s footnote-13 technique wants), and keep the model uncomputable where that is simplest. Then either compile the checked algebra from Lean, or write the orchestrator in Haskell as a separately-realized shadow tied back by shared property tests — in the corpus’s words about every such mechanism: ugly *and confined*. What must not happen is transliterating either host’s idiom into the other; the denotation, not the notation, is what transfers.

## 9. Case study: agent-functor

One team’s independent realization of a neighbouring design, audited against §2–6. **Homomorphic image, arrived at independently:** `runPure` with an `Oracle` *is* ⟦·⟧<sub>ext</sub> at a deterministic sample — all three designs, on different representations, put “promote it from the test suite to the specification” first on their rebuild lists; when three designs agree on the first move, that is the move. `applyScope`’s innermost-wins is the solved form of §5.3; the reducers (`unionFindings` free monoid, `posConsensus` commutative and permutation-tested, `Grant` semilattice) are the convolution-monoid parameter discovered empirically — the best-designed part of the system. **Correctly-placed implementation:** `ParStrategy` as two realizers of one tensor; the normalising smart constructors; the wire protocols and the store. **Implementation bias, by the corpus’s symptoms:** fresh-session-per-leaf is the right decision (κ = const ε) held as a documented contract instead of a type index; `Cached` promotes memoisation into the observable value; `ForkSet` is counterfactual substitution described as a store edit; the cost fold hard-codes its semiring, so every new quantity needs a new fold instead of a new instance; `isCacheable` conflates *deterministic* (licenses pinning) with *central* (licenses parallelism); and the uncapped `parPair` is a schedule detail extensionally but a semantic inconsistency under any width-carrying meaning. The rebuild list, in order of consequence: parameterize the semiring; make `pin` a term constructor; type the context index; make `Grant` the gating scalar and footprints the parallelism licence; split `isCacheable`; publish each reducer’s algebra as the scheduler’s licence.

## 10. Takeaways

1.  **One environment, three faces.** Model, tool, and human are consultations answered by one sample point ε, with the measure at the edge. This single move makes caching an identity, fork a substitution, and the session tree a memo trie — and it deletes `World` as a type.
2.  **Two meanings, one fibration.** Extensional (per-ε, fixes equality) and quantitative (an S-matrix, fixes cost/latency/probability), related by projection. Optimisation is movement down a fibre; anything else is a semantic change wearing an optimisation’s commit message.
3.  **The quantity lives on the transition.** Pairs (kernel, cost) do not compose; matrices over a complete semiring do. Retry is a star, bounds-checking is the star’s existence, expected cost is p∗mp∗ — and width is a monoid fold, not a semiring factor.
4.  **Panels are convolution in the reducer’s monoid; sums are alternatives.** The reducer’s algebra is the scheduler’s licence: commutative may reorder, idempotent may speculate and race (`unamb`), neither means declaration order is semantic.
5.  **Copy is never free.** Naturality of copy is determinism; `share` and `dup` are different terms with different meanings in both layers. Parallelism of world-touching steps is licensed by footprint disjointness — a type, not a convention — and the same independence relation defines which schedules are *equal* (Mazurkiewicz).
6.  **Context is an index; compaction is an interior operator.** Collapsing the index to a constant is the same decision as content-addressed caching being sound. Make it a choice with derived consequences, not a hygiene rule.
7.  **Value-dependence is stratified, not refused.** Branching on generated tokens is `Choice` through a decoder and costs nothing; bounded dynamic shape costs a supremum; full `bind` keeps its full kernel meaning and honestly forfeits only the a-priori instruments. The fragment is a type index — a fact the type system states, not a rule the designer enforces.
8.  **Prove in Lean 4, run as Step 9.** The meaning spaces exist in Mathlib; quotients and law-carrying classes give what Haskell can only assert and what cost Agda dearly. The executable orchestrator — Lean-compiled or Haskell — is a refinement of a denotation that has not moved.

## 11. References (verified during the audits)

- C. Elliott, corpus distillation: *Denotational Design, 1988–2023* (local, 10,145 ll.); *Generalized Convolution and Efficient Language Recognition* (arXiv:1903.10677) — Thm 16, Figs 8–9; *Denotational design with type class morphisms*; *The Simple Essence of Automatic Differentiation* (ICFP 2018); *Compiling to Categories* (ICFP 2017); *Timely Computation* (2023).
- R. J. Aumann, *Borel structures for function spaces*, Ill. J. Math. 5 (1961).
- O. Kallenberg, *Foundations of Modern Probability*, 3e — randomization/transfer, Lem. 3.22.
- C. Heunen, O. Kammar, S. Staton, H. Yang, *A convenient category for higher-order probability theory*, LICS 2017 (quasi-Borel spaces).
- T. Fritz, *A synthetic approach to Markov kernels…*, Adv. Math. 370 (2020) — Def. 10.1, C<sub>det</sub>; with Gadducci, Perrone, Trotta, *Free gs-monoidal and free Markov categories* (2023).
- A. Corradini & F. Gadducci, *An algebraic presentation of term graphs via gs-monoidal categories*, Appl. Cat. Struct. 7 (1999).
- J. Eisner, *Parameter estimation for probabilistic finite-state transducers*, ACL 2002 (the expectation semiring).
- C. A. R. Hoare, B. Möller, G. Struth, I. Wehrman, *Concurrent Kleene Algebra*, CONCUR 2009 / JLAP 2011 — cited here as the structure the resource semiring is *not*.
- A. Mazurkiewicz, trace theory (1977–); Foata normal form — the free partially commutative monoid.
- R. Atkey, *Parameterised notions of computation*, JFP 19 (2009); D. Orchard, P. Wadler, H. Eades, *Unifying graded and parameterised monads*, MSFP 2020.
- J. Power & E. Robinson, *Premonoidal categories and notions of computation*, MSCS 7(5) (1997); M. Román, *Promonads and string diagrams for effectful categories*, ACT’22.
- A. Kock (1970, 1972), commutative strong monads; B. Eckmann & P. Hilton, Math. Ann. 145 (1962); T. Fox (1976).
- Mathlib: `ProbabilityTheory.Kernel`, `Kernel.Category.Stoch`, `MeasureTheory.Measure.GiryMonad`, `PMF`, `Tropical`; R. Degenne, *Markov kernels in Mathlib* (arXiv:2510.04070).

Revision 2 · Synthesized by Claude (Fable 5) in Claude Code on 2026-08-11. Pipeline: full-coverage read of the Elliott corpus distillation (6 readers, all 10,145 lines) → methodology charter → three independent denotation-first designs (kernel / interaction / quantitative stances) → fidelity audit + mathematical audit (19 + 24 findings; all corrections folded in or quoted in §7) → host survey (Lean 4, Haskell, corpus precedent). The winning stance is quantitative’s, repaired; the environment move is interaction’s; the scoping solve is kernel’s. agent-functor and incite serve as case study only. Revision 2.1: the outright refusal of `Monad` withdrawn after John’s objection (later turns’ direction depends on earlier turns’ tokens) and replaced by the stratified account in §4, vindicating the fidelity audit’s Finding 6. Full reports: session dossier, `dd-*.md`, `host-*.md`, `ct-*.md`.
