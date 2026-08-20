# Profunctors and agent-cat

> **Note (2026-08-20).** Where this page says the package "already owns" a piece of
> vocabulary in `Agentic/Star.lean`, `Agentic/Panel.lean`, `Agentic/Meaning.lean`,
> `Agentic/Trace.lean` or `Agentic/Surface.lean`, it no longer does: those modules
> were excised under obr `acat-q1i`, and what they established is recorded in
> `doc/research/term-algebra-results.md` rather than in code. A proposal here that
> leans on one of them as an existing asset must re-derive it in `Agentic/Core/**`
> instead. The rest of the page, which is about `Agentic/Core/**`, stands — with the
> ordinary caveat that `Core/**` has moved on since it was written: the same pass that
> retired the stratum also deleted `Plan.size_eq_askNodes_succ`, `CheckError.render`,
> `Dsl.Prompt.normalize` and `DslFlagship.render_eq_harden_render`, and folded
> `Verdict.render`/`Verdict.objections` into `Agentic/Core/Question.lean` and
> `Dsl.RawBlock.revisionBounds` into `Agentic/Core/Dsl/Check.lean` (obr `acat-j61`,
> `acat-o5o`, `acat-1t1`). An inventory below that lists one of those is an inventory
> of the tree as it then stood.

*A decision page for the owner, answering the question "think about profunctors and
how they might be used to improve the design and the term language and evaluator."
Four commissioned working papers sit in `doc/research/profunctor-design/`: **A**
`a-categorical-frame.md` (the mathematics), **B** `b-haskell-evaluator.md` (a
concrete Haskell redesign), **C** `c-lean-side.md` with `c-lean-side-probes.lean`
(the Lean side, 421 lines of compiled probes), and **D** `d-attack.md` (an
adversarial pass over the other three, checked against the sources). They are the
working papers and they stay; this page is the document of record and supersedes
their recommendations where it contradicts them.*

*Independently re-verified for this page, in this checkout, rather than taken from
the papers: the frozen corpus record (`test/corpus/*.json`, 128 vectors,
`python3 -m json.tool` over the key tree) against `Observe.hs:88`; `Explain.lean`'s
`Plan.explain` and `test/CliSmoke.lean:181`; `Check.lean:491–505`'s de Bruijn order;
`Level.lean:120`'s five clauses; `Explain.lean:140`/`:155`'s `size`/`askNodes`;
`Cost.lean:425`/`:596`'s two `bill_exact` hypothesis lists; `Cost.lean:974`'s
`no_static_bill_at_branch`; `Denote.lean:683`'s definition of `≈ᵖ`; the ten
`Plan.Denotes` hypothesis occurrences and `HardenPatch`'s four hand discharges;
Mathlib's `Profunctor/Basic.lean` "Future work: Define composition of profunctors"
and the empty `Tambara` grep. Four contested citations were resolved against the
literature (§5). Not re-verified: D's re-run of C's probe file (D reports exit 0 and
seven axiom footprints matching C §5.1 exactly; the probes were not re-elaborated
here), and no `lake build`, `corpus-gen` or GHC invocation was made in producing
this page.*

---

## 0. The one-paragraph answer

**The profunctor framing is a good question that has a better answer than
profunctors.** Asked what algebraic structure organizes `Plan`, the honest reply is
three facts, none of which is a profunctor theorem: `Cont Γ (El c) B ≅ Plan (c :: Γ) B`
on natural families is a **Yoneda/representability** fact about context extension,
compiled, and it deletes the ten `Plan.Denotes` hypothesis occurrences and
`HardenPatch`'s four hand discharges; `Plan` has an **initial-algebra fold** and
eleven of its twelve structural recursions are instances of it, which is Allais et
al.'s "N bespoke traversals become one generic semantics" and not Rivas–Jaskelioff's
tower; and the analyses are **interpretations into ordered monoids**, where the rung
boundary is an order-theoretic condition on the target — that a case's interpretation
dominate each arm — and not, as the seed brief and working paper A both claim, a
condition of idempotence, which `Plan.size` and `Plan.askNodes` refute twice at
`(ℕ,+)`. Every object that is genuinely profunctor-specific is disposed of by the
dossier's own evidence: Tambara modules and profunctor composition are priced at
3,000–6,000 Lean lines for zero theorems and are absent from a Mathlib whose own
header lists profunctor composition under *Future work*; all three lens laws fail on
`revising` and each failure is the combinator's purpose; `Sub.lift = second'` is
`id × −` at `(->)`; handles-as-lenses reduces to "carry the name in the value", which
the existing `I`-suffixed builder API already does. The one place a profunctor
*representation* would buy something real — B's `Flow x y`, where the rank-2 `Cont`
becomes rank-1 and A's `Option (El c)` obstruction evaporates for free — pays in the
wrong currency: it re-indexes the Haskell term language off the Lean one in a
repository whose correctness architecture is "Lean is normative, Haskell is a
transliteration, the corpus catches the rest", where the corpus provably cannot reach
`dyn`, arbitrary continuations, or tags beyond `Bool`/`VTag` — the exact list of
places two cores diverge first. **So: adopt the Yoneda collapse and the fold, both
compiled and both additive; adopt six docstrings that name what is already there;
adopt the one Haskell simplification that needs no profunctor; refuse the tower, the
optics, and the re-indexing; and record the corrected meta-theorem as understanding,
with its ceiling stated exactly — the frame computes precisely the `≈ᵖ`-invariant
facts, and five of the eight fields in the frozen reply record, plus the printed
`RawProgram`, are not `≈ᵖ`-invariant.**

### 0.1 The decisions, numbered

| # | Decision | Tier | Where argued |
|---|---|---|---|
| **P1** | **Adopt `Cont.Natural` + `Cont.ofPlan`/`toPlan` + the two round trips + `sub_graft_of_natural` + `sub_mapP` + `denotes_ofPlan`, as an additive theorem layer.** Do not rewrite `revising`'s definition. | now | §1.3, §2.2, §4.1 |
| **P2** | **Adopt `PlanAlg` + `fold` + `fold_unique` additively**, with `level = levelAlg.fold` and `denote = denoteAlg.fold` as *theorems*, not as replacements. | now | §2.3, §4.1 |
| **P3** | **Adopt `codes_eq_map_shapes` and `shapes_eq_map_asks`**, both hypothesis-free; derive the two `isSome` corollaries from them. | now | §2.3, §4.1 |
| **P4** | **Adopt `Monoid (Dlg M)`, `runHom`, `traceHom`, `panel = List.prod`**, retiring `run_panel`/`trace_panel`'s inductions and `flatten_perm`. | now | §2.4, §4.1 |
| **P5** | **Adopt the syntactic `mapP_id`/`mapP_comp`** (currently proved only up to `≈ᵖ`) **and the missing bifunctor square `sub_mapP`.** | now | §2.3, §4.1 |
| **P6** | **Adopt six docstrings and no code**: `askC`'s nullary arity as the answer to kernel open question 3; `PricesByShape` as object-blindness of a `Const` target; `Cost.asks` reclassified as the semantics at `ωDefault`; the corrected domination condition beside `level`; `Sub.lift = second'` as the strength; the premonoidal centre as what the four scheduling-licence theorems compute. | now | §2.5, §4.1 |
| **P7** | **Adopt the value-carrying handle in the Haskell builder** — carry `(Text, Var g c)` in `V n c g`, delete `SymEq`/`LookupC`/`KnownVar`/`KnownVar'` — **without profunctors, without `Flow`, keeping `Fresh` and `KnownScope`.** | now | §2.6, §4.1 |
| **P8** | **Record the conformance surface as three surfaces, correctly.** The frozen record is `Observe.hs:88`'s eight keys and does **not** contain `shapes` or `asks`; `Explain.planLines` is pinned byte-for-byte by `CliSmoke.lean:181` and is named in no working paper. | now | §3.3, §4.1 |
| **P9** | **Fusing `revising` with its consuming `case` was attempted 2026-08-18 and REFUSED by its own gate.** The fusion was implemented to measure, the corpus regenerated to scratch, and the invariance audit found `askNodes` moved 16→13 on the three revising-loop entries (battery-112, semantic-001, semantic-004; `size` 31→22, `paths` 8→5): fusion changes the **enumerable question tree**, not just node bookkeeping — a movement this table did not predict (it lists only `size`/`paths`/`planLines`). Reverted; recorded as refused-with-evidence. Reopen only with a decision that `askNodes` may move, which is a semantics question, not a re-pinning question. | refused (measured) | §3.2, §4.2 |
| **P10** | **Closing the `case` tag universe (and `dyn`'s `B`) to demote `Plan` to `Type 0` waits behind a spec regeneration.** A's "corpus impact: none" is wrong: `planLines` prints `FinEnum.toList` arm counts in enumeration order. | gated | §3.2, §4.2 |
| **P11** | **Replacing `CostTree` with a `Multiset`-valued fold waits on a `corpus-gen` diff**, not on the argument. It is argued corpus-safe and was not compiled. | gated | §3.2, §4.2 |
| **P12** | **Replacing the twelve recursion bodies with `PlanAlg.fold` (as opposed to adding the fold) waits on a kernel-reduction timing diff**, not on line counts. | gated | §3.1, §4.2 |
| **P13** | **The full tower is refused**: monoids in `Prof`, Tambara modules, profunctor composition, four free constructions, one meta-theorem. Recorded as understanding only. | refused | §2.1, §3.1, §4.3 |
| **P14** | **The optics reading of `revising` is refused**, and so are open games. Recorded as understanding, with a reopen condition. | refused | §1.2, §4.3 |
| **P15** | **B's step 1 — re-indexing the Haskell core to `Flow x y` — is refused.** This is the two-core hazard and it is the strongest objection in the dossier. | refused | §3.4, §4.3 |
| **P16** | **The final-tagless representation is refused as a production surface** and is recorded as a proof device whose transport claim is asserted and unargued. | refused | §2.1, §4.3 |

### 0.2 What this page changes about the working papers

Six corrections, each of which moves a verdict rather than a detail.

| Correction | The paper said | Actual |
|---|---|---|
| **The `Const`-crosses-`case` mechanism** (A §5.1(4b), billed by A as "the load-bearing sentence of the whole document") | a sound over-approximating `Const M` analysis exists **iff** `M` is a join-semilattice | false. `Plan.askNodes` (`Explain.lean:155`) and `Plan.size` (`:140`) are sound over-approximations at `(ℕ,+)`, which is not idempotent. The condition is **order-theoretic**: the interpretation of the copair must dominate each arm, for which a positively ordered monotone monoid suffices and `sup` is the tight case. §1.1 |
| **The pipeline "isomorphism"** (A §2.3, tabled as "iso given") | `{p ∣ level p ≤ pipeline} ≅ Hom_{Freyd(Σ_pipe)}(Env Γ, A)` | not injective. `askC_coherent` (`Denote.lean:151`) makes `askC c q k` and `ask c q.shape (const q.prompt) k` the same meaning and different terms. The map is a **surjection**; A's own §5.3(7) says a presentation modulo `≈ᵖ` can never replace the term, and §2.3 and §5.3(7) cannot both stand. §1.1 |
| **What the corpus pins** (A §5.4 and C §5.3) | `shapes` and `asks` are frozen | they are not. `grep '"shapes"'` and `'"asks"'` return nothing across all 128 vectors; `Observe.hs:88` emits eight keys and its docstring says "the five static folds". This *loosens* the constraint. Separately, **`Explain.planLines` is pinned and no paper mentions it.** §3.3 |
| **The de Bruijn order in the fused `revising`** (C §7.1) | `Plan (c :: Γ) Verdict → Plan (c :: .verdict :: Γ) (El c)` | reversed. `Check.lean:498` is `reviseCont (rev : Plan (.verdict :: c :: Γ) (El c))`; `Builder.hs:1021` agrees. A §4.1 has it right. §4.2 |
| **"Every author-written `Cont` ignores its `Sub` argument"** (C §6.1) | as stated | false for the three that matter: `checkCont`, `reviseCont`, `finishCont` all use `σ`. The true and stronger statement — the one the Yoneda argument needs — is *"every author-written `Cont` is `ofPlan` of a plan"*. §1.3 |
| **The line-count case for `Flow`** (B §1.7) | adding a former costs three class methods instead of `5 × 9` clauses | negated by B's own §0.4. If `Flow`'s `Category`/`Strong`/`Monoidal`/`Branching`/`Applying` instances must be skeleton-preserving smart constructors — and they must, because `size` is pinned — then they are themselves five-clause recursions, and a former costs one clause in each of ~8 instances plus `interp` plus `size`. §3.4 |

---

## 1. The three correspondences, and their status

Each seed observation, stated exactly, then given a verdict: **exact**, **needs
weakening** (with the weakened form), or **broken** (with what replaces it).

### 1.1 The level lattice ↔ the idiom/arrow/monad hierarchy

**Seed:** batch ≅ free Applicative over the question functor; pipeline ≅ free Arrow ≅
free monoid in Strong profunctors under profunctor composition; branch adds
Choice/cocartesian structure; dynamic ≅ ArrowApply ≅ Kleisli. The analysis-availability
theorems become one schema.

**Status: the reading is exact; three of the four "isomorphisms" need weakening; the
schema is half-real and its mechanism was wrong.**

#### (a) What is exactly right

The four rungs sit in Lindley–Wadler–Yallop's hierarchy, and LWY's actual theorem is
sharper than the informal "static arrows correspond to idioms" gloss that A quotes.
LWY characterise idioms and monads as arrows satisfying **type isomorphisms**:

```
idiom:   A ⇝ B  ≅  1 ⇝ (A → B)
monad:   A ⇝ B  ≅  A → (1 ⇝ B)
```

with arrows strictly between. Both isomorphisms are checkable here, and the check is
the content of the `askC`/`ask` split:

> **Claim (batch is an idiom, in LWY's own criterion).** For `p` with
> `level p ≤ batch`, `p` is `askC c₁ q₁ (… (askC cₙ qₙ (ret e)) …)` with
> `e : Expr (cₙ :: … :: c₁ :: Γ) A` (`Level.lean:120`, `level_askC` returning `level k`
> with no join). None of the `qᵢ` reads `Γ`, so currying `e` through
> `Env (cₙ::…::c₁::Γ) ≅ El cₙ × ⋯ × El c₁ × Env Γ` gives a plan
> `p̂ : Plan [] (Env Γ → A)` with the same question list and
> `denote p γ = Dlg.map (· γ) (denote p̂ Env.nil)`. That is
> `Hom(X,Y) ≅ Hom(1, X → Y)` at the meaning. It **fails at pipeline** for the exact
> reason `ask` exists: `e : Expr Γ String` reads the environment, so the question
> list is a function of `γ` and cannot be pulled out of the hom.

This is not proved in Lean. It is a one-paragraph induction and it is a better
statement of "batch ≅ idiom" than "batch ≅ FreeA F", because it is a statement about
denotations and a syntactic transformation — both of which exist — rather than an
isomorphism modulo a quotient the package cannot afford (below). *I am confident of
the computation; I have not machine-checked it.*

`dyn` is `ArrowApply`, hence Kleisli of a monad, by Hughes's theorem, and the
package's own "the only derived form that needs `dyn` is `bindP`" (`Plan.lean:462`)
is the arrow-side statement of it. `case` at a `FinEnum` tag is the n-ary copair
after the `Set` distributive law `Env Γ × T ≅ Σ_{t:T} Env Γ` — both arms see the same
`Γ` because the payload rides in the environment (`Plan.lean:494`) — so `branch` adds
finite distributive choice, exactly as the seed says.

#### (b) Where "isomorphism" must become "surjection"

A's §0 table records `batch`, `pipeline` and `branch` as "iso given". They are not
isomorphisms, and A's own §5.3(7) is the refutation:

> The meta-theorem is stated modulo `≈ᵖ`, but `Plan.size`, `Plan.askNodes`,
> `Plan.explain` and `paths` are **not** `≈ᵖ`-invariant. So the free-structure
> presentation can never replace the *term*.

Concretely: `askC_coherent` (`Denote.lean:151`) says `askC c q k` and
`ask c q.shape (fun _ => q.prompt) k` denote the same dialogue and are different
terms. Any free-Freyd presentation identifies them; `Explain.planLines` prints them
as *distinct keywords* (`Explain.lean:230–243`) and `CliSmoke.lean:181` pins the
rendering byte-for-byte. So the correct statement is:

> **The fragment `{p ∣ level p ≤ ℓ}` maps onto the free `ℓ`-structure; the map is
> surjective and not injective; its kernel is generated by `askC_coherent` at
> `pipeline` and by whatever `case` identities a presentation chooses at `branch`.
> Every `≈ᵖ`-invariant observation factors through it. No other observation does.**

And the arithmetic of "no other observation" is exact, because `≈ᵖ` is the kernel of
`denote` (`Denote.lean:683`): of the eight fields in the frozen reply record,
`worlds[].trace`, `worlds[].billFresh` and `worlds[].billMemo` are functions of the
meaning and therefore `≈ᵖ`-invariant; `level`, `size`, `askNodes`, `codes` and
`costSummary` are not (`level_not_equiv_invariant`, `Morphism.lean:646`, exhibits
`ret` versus `bindP ret` at opposite ends of the chain), and neither is the printed
`RawProgram`. **Five of eight fields plus the whole printed program are term-facts,
not meaning-facts.** That is the frame's ceiling and it is not a small one.

One refinement neither A nor D has, and it matters for the `pipeline` row. Atkey's
"What is a categorical model of arrows?" does **not** say arrows are Freyd
categories; its abstract says the folklore equivalence "is more subtle than that",
and derives instead *enriched* and *indexed* Freyd categories, with a further
condition characterising when an indexed Freyd category is isomorphic to a Freyd
category — the differentiating point being "the number of inputs available to a
computation and the structure available on them". agent-cat lands in the degenerate
case, and it lands there **because `Sub` is semantic**: `Sub Γ Δ = Env Δ → Env Γ` is
any function (`Plan.lean:169`), so `E` is the full image of `Env` in `Set`,
weakening/exchange/contraction/substitution are one operation, and every pure map
between environment types is available — which is precisely "arbitrary structure on
the inputs". The Freyd reading of `pipeline` is therefore exact *here* and would
break the moment anyone replaced `Sub` with a syntactic renaming category. That is
worth one sentence in `Plan.lean:161–169`'s docstring and is P6's sixth item's
neighbour. *Read from Atkey's abstract, not from the printed proof.*

#### (c) The mechanism, corrected — this is the central error in the dossier

A stakes its meta-theorem on:

> **`level` survives `case` because `max` is idempotent and commutative; `billFresh`
> does not because `Multiplicative ℕ`'s product is neither.**

Both clauses are wrong, in different ways.

`billFresh` is not an analysis of the term at all — it is a fold of the *transcript*
(`Cost.lean:166`), and a transcript belongs to a run. The static analysis it is being
compared with is `asksBill`, which returns `none` at `case`.

And the package contains two counterexamples to the idempotence claim.
`Plan.askNodes` (`Explain.lean:155`) interprets `>>>` as `+` and `case` as `Σ` over
`FinEnum.toList`, in `(ℕ,+)`; `Plan.size` (`:140`) does the same with a `1 +`. Neither
monoid is idempotent, and both are sound over-approximations of
`(Plan.trace ω p γ).length` at `level p ≤ branch` — a run walks one path, and every ask
node on that path is a node of the term. What makes them sound is that `(ℕ,+,0)` is
**positively ordered** (`0 ≤ n` for every `n`, so each arm's value is dominated by the
sum) and monotone in each argument. Stated correctly:

> **A `Const M` interpretation with `M` an ordered monoid over-approximates soundly
> across `case` iff the interpretation of the copair dominates each arm. `sup` and
> `∏` in a positively ordered monotone monoid both qualify; `∏` in a monoid with
> inverses does not. `sup` is the special case where the bound is tight arm by arm.**

Two consequences that the incorrect version obscured. First, a crude sound
over-approximating bill at `branch` *does* exist — the product of all arms' prices,
in `Multiplicative ℕ`, which is positively ordered. What does not exist at `branch` is
an **exact** static bill, and that is `no_static_bill_at_branch` (`Cost.lean:974`),
witnessed by `coinBranch` costing `ofAdd 2` under `heads` and `ofAdd 1` under `tails`.
Exactness, not soundness, is what `case` destroys, which is why `costTree` exists at
all. Second, A's own §5.1 preamble concedes that "`Const M` … satisfies Paterson's
stated `ArrowChoice` laws with `left' = id`" — which is precisely the non-idempotent
interpretation the next paragraph declares impossible.

The seed's own version of the mechanism — "`Const`/`Forget` is monoidal but not
compositional, hence cost dies at `dyn`" — is refuted independently by all three
papers, and B's refutation is the sharp one: `Forget r x y = x → r` is `Monoidal` and
`Strong` for a monoid `r` but has **no `Category` instance** (composing
`Forget r b c` after `Forget r a b` would need a `b` from an `a`), while `Tally s`
*is* a `Category`. So non-compositionality separates **batch from pipeline**, not
branch from dynamic. What actually dies at `dyn` is not compositionality but
*finiteness*: `no_finite_bill_set_at_dyn` (`Cost.lean:908`) is a cardinality theorem
about one exhibited plan.

#### (d) The schema, half-real

"An interpretation into `p` exists iff `p` carries the rung's structure" splits.

The **⇐ half is real and is a fold.** `PlanAlg.fold` (C §6.2, compiled,
universe-polymorphic, footprint `[Quot.sound]` — i.e. `funext` and nothing else)
delivers it in six lines, with `fold_unique` as the uniqueness half. It needs no
`Prof`, no `Strong`, no `Choice`; the algebra's five fields *are* the structure, in
the package's own vocabulary. The prior art is Allais, Atkey, Chapman, McBride,
McKinna — "N bespoke traversals become one generic semantics", formalised — and it is
not a profunctor paper.

The **⇒ half cannot be a schema**, in Lean or in Haskell. Lean has no parametricity,
so nothing is free. But B's §2.5 concedes the deeper reason and it applies to both
languages: `Applying`'s `applying :: p (p x y, x) y` has `p` in a *negative* position,
so a profunctor homomorphism cannot transport it — which is the well-known reason
`ArrowApply` is not a well-behaved algebraic structure, and is the same fact as
`no_finite_bill_set_at_dyn`. B's §2.4 nonetheless claims that deleting the
`Applying (Tally CostTree)` instance makes `no_cost_tree_at_dyn` "a type error rather
than a theorem". That is a category error and it should be withdrawn: the Lean theorem
says *no finite-leaf tree exists* containing the bills of `unbounded` — a statement
about the cardinality of a semantic image — whereas a missing instance says only that
nobody wrote one, and B supplies a sound one three paragraphs earlier
(`applying = Tally (CostNode [])`, matching `Plan.hs:828`'s deliberate choice).
**Non-existence results are witnesses. No structure-existence schema produces a
counterexample; it is the wrong shape of statement.** The package's five —
`no_finite_bill_set_at_dyn`, `no_cost_tree_at_dyn`, `no_static_bill_at_branch`,
`minFold_not_attained`, `billMemo_not_monoid_hom` — stay exactly as they are.

### 1.2 `revising` ↔ lens

**Seed:** `review = get`, `amend = put`, the bounded loop is an iterated get–put
dialogue, the carrier plumbing is Tambara/`Strong` `first'`; also connects to
Hedges-style open games.

**Status: the lens clause is broken. The strength clause is exact and is already in
the kernel. Open games are inert, with a stated reopen condition.**

All three papers refute the lens independently, and they are right, but only B and C
refute it correctly. The pair `review : c → Verdict`, `amend : (c, Verdict) → c` has
exactly the concrete signature of `Lens' (El c) Verdict`. What fails is the laws, and
each failure is the combinator's purpose:

| law | reading here | holds? |
|---|---|---|
| GetPut `put (s, get s) = s` | amending an artefact against its own verdict returns it unchanged | **no** — that is what an amendment is not |
| PutGet `get (put (s, a)) = a` | re-reviewing an amended artefact returns the old verdict | **no** — `trace_upToTwice_stubborn` (`Denote.lean:598`) is a machine-checked instance of three reviews, all objecting, all distinct |
| PutPut | amendments do not accumulate | **no** — `revise` receives the artefact *and* the verdict (`Plan.lean:620`) precisely so that they do |

A lens with no lens laws is a pair of functions with suggestive names, and the
profunctor-optics machinery buys exactly nothing without them, because the laws are
what make optics compose.

A's §3.1 reaches the right conclusion by a bad argument and should not be quoted:
it claims "the pair is not of lens type: the second component consumes the very `a`
the first produced, not an independent `b`". That is a type-level claim and it is
false — `revise : Cont Γ (El c × Verdict) (El c)` has exactly the shape `s × b → t`
with `b = Verdict`, and nothing in the *type* forces the verdict fed to `put` to be
the one `get` produced. That is a fact about the loop's use site, not its type.

A's positive identification — `revising` as a Moore coalgebra `S → V × S` unrolled
`n+1` times — is also weaker than advertised, because both maps are **effectful**:
`check : Cont Γ (El c) Verdict` asks a question. The coalgebra is at best
`S → Dlg (V × S)`, i.e. in a Kleisli category, and once said properly "Moore machine"
adds nothing to "`Nat.rec` writes the unrolling", which `Plan.lean:616–621` already
says. C's alternative — the `n`-th approximant of a least fixed point, with
`Agentic/Star.lean` as the categorical home the package already owns — is the better
pointer, and the receipt for why the star lost is in that file:
`retry_cost_ambiguous`, where under a bare `StarSemiring` the same loop equation is
answered by `fin 3`, `fin 5` and `inf`, each by `rfl`. **The design deliberately has
no traced structure, and `level_upToTwice = branch` (`Level.lean:332`) is the payoff.**

What *is* load-bearing in the seed's second sentence is the **strength**, and it is
already proved: `Sub.lift σ = id_{El c} × σ = second' σ`, `Sub.wk = π₂`, and
`wk_lift : comp wk (lift σ) = comp σ wk` (`Plan.lean:214`) is the naturality square.
D is right that this names three `rfl`s and unlocks nothing on its own — see §4.3's
recorded dissent for the one place where naming it did unlock something.

Open games (Ghani–Hedges–Winschel–Zahn) have lens structure because utilities flow
backward. agent-cat has no backward flow: `denote : Plan Γ A → Env Γ → Dlg A` is
covariant end to end, and `PlanUpTo` (`Cost.lean:996`) is a **subtype of the term**
defined by `maxFold ∘ costTree`, not a resource threaded through a run. A's standing
note is the right one and is adopted as P14's reopen condition: *if budgets ever
become dynamic — spend as you go, return the residual — the optic becomes
load-bearing overnight.*

### 1.3 `Plan Γ A` ↔ profunctor

**Seed:** `Plan` is a profunctor `Ctxᵒᵖ × Type → Type`, `Sub` is the contravariant
action, the Builder's graft/weaken machinery is its composition; handles could be
profunctor lenses into a structural environment.

**Status: the profunctor sentence is exact and worth one sentence. The composition
clause is broken. The handles clause is broken with a salvage. The real content is a
Yoneda lemma, and it is the highest-value result in the dossier.**

`Plan` is a `Type`-enriched bimodule: contravariant in `Γ` via `sub`
(`sub_id`/`sub_comp`, `Plan.lean:319`/`:328`, are exactly the two functor laws),
covariant in `A` via `mapP`. C's variance note is the one to record: with
`E` = environment maps and `C = Eᵒᵖ` (so `Hom_C Γ Δ = Sub Γ Δ`), `sub_comp` says
`Plan (−) A : C ⥤ Type 1` is **covariant on C**, so the seed's phrasing is right once
you say the base is `E` and backwards if you say `C`. It is not an endoprofunctor on
one category, so profunctor composition is not available on it and no optics
machinery applies to `Plan` directly.

The composition clause is wrong on the Lean side: `graft` is **not** profunctor
composition. Profunctor composition is a coend `(P ⋄ Q)(Γ,A) = ∫^Δ P(Γ,Δ) × Q(Δ,A)`,
which is a quotient; `graft` is the Kleisli extension of a **relative monad** over
`Expr` (Altenkirch–Chapman–Uustalu), which is precisely the phrase
`Morphism.lean:218–226` reaches for without citing — "`Plan`'s sequencing is a
genuine monad structure relative to `Expr`" — and its three laws hold at the syntax
unconditionally (`graft_ret`, `graft_pure`, `graft_assoc`).

The fourth expected law fails, the package compiles the counterexample
(`sub_graft_not_natural`, `Morphism.lean:324`, with `wobbly` at `:310` asking once per
binding in scope), and the repair is where the whole exercise pays off:

> **Theorem (Yoneda for `Cont`).** `Env (c :: Γ) ≅ El c × Env Γ` (`cons_head_tail`,
> `Plan.lean:117`) makes `c :: Γ` represent `Δ ↦ Expr Δ (El c) × Hom_C(Γ, Δ)`, with
> universal element `(Sub.wk, Expr.var .here)`. Hence
> `{k : Cont Γ (El c) B // Cont.Natural k} ≅ Plan (c :: Γ) B`, where
> `Cont.toPlan k = k (c::Γ) Sub.wk (Expr.var .here)` and
> `Cont.ofPlan q = fun _ σ e => sub q (fun δ => Env.cons (e δ) (σ δ))`.
> `toPlan_ofPlan` holds **unconditionally** (`cons_head_tail` then `sub_id`);
> `ofPlan_toPlan` holds **exactly on the natural families** — the round trip *is* the
> naturality condition.

C compiled all of it (`c-lean-side-probes.lean`; D re-ran the file and reports exit 0
with the seven axiom footprints C printed). `Cont Γ A B` is the right Kan extension
of `Plan(−) B` along `E ↪ Set` evaluated at `Env Γ × A`, and because that inclusion is
fully faithful the extension collapses wherever `Env Γ × A` is itself an environment
type. This uses no profunctor, no Tambara module, and no optic. The methodological
precedent — a higher-rank type *is* a Yoneda/representability fact, and collapsing it
is the intended move rather than a trick — is Boisseau and Gibbons.

Three corrections to the papers' framing of it.

1. **The premise C states is false and the true one is stronger.** C §6.1 writes
   "Every author-written `Cont` in the repository ignores its `Sub` argument."
   `checkCont`, `reviseCont` and `finishCont` (`Check.lean:491`, `:498`, `:505`;
   `Builder.hs:1016`, `:1021`, `:1029`) all use `σ`, via `Plan.sub … (Env.cons … (σ δ))`.
   The true statement is *"every author-written `Cont` is `ofPlan` of a plan"* — which
   is exactly what the Yoneda argument needs, and is what makes the collapse a
   description of the implementation rather than a proposal for it.
2. **`Morphism.wobbly` is now classified, not merely exhibited.** `wobbly Δ _ _ =
   ticks Δ.length` reads the *length of the context it lands in*, which is precisely
   the data a natural family may not see. `sub_graft_not_natural` becomes "the
   presheaf `Δ ↦ Sub Γ Δ × Expr Δ A` has non-natural sections", and stays beside
   `sub_graft_of_natural` as a matched pair, which is `Morphism.lean`'s own house
   style.
3. **Where the collapse stops is a fact about the design.** `A` must be
   representable — a finite product of answer types. `finishCont`'s
   `A = Option (El c)` is not, because `revising` returns `Option (El c)`
   (`Plan.lean:624`). So the one place the language leaves the "answers only" universe
   is exactly the one place Yoneda fails to apply. The theorem *locates* that; nothing
   else in the development does. Removing it is P9 and costs a spec regeneration.

**Handles as profunctor lenses: broken, with a salvage that needs no profunctor.**
Three objections, in increasing severity. A lens is over-powered — `Env` is
append-only, nothing updates a binding, only `get` is ever used, and the `get` half
*is* `Var Γ c` with `Var.get`. The nominal layer is not plumbing but diagnosis —
`LookupC`'s `TypeError` reproduces `Check.lean:99`'s `unbound` and `Fresh`'s
reproduces `freshName`'s refusal, and those messages are the product. And names are
observable — the printed `RawProgram` carries the author's name in five positions and
that `Raw` is what the oracle checks. On the Lean side the question does not arise at
all: the environment is already structural, `Var` is already a projection, and there
is no nominal scope machinery to replace.

The salvage is real and is P7: **move the name from the type to the value.** Carry
`(Text, Var g c)` in `V n c g`; `Var g c` with `varGet` *is* the projection; delete
`SymEq`, `LookupC`, `KnownVar`, `KnownVar'`. This is what the existing `I`-suffixed
entry points already do (`Builder.hs:1248` ff.) and what `Agentic.Notation` already
exploits. It needs no `Strong` constraint anywhere, and it answers B §3.3's O(n²)
instance-resolution complaint on its own. **`Fresh` and `KnownScope` stay** — `Fresh`
refuses a second bind of a live name, which Haskell's own binders will not do, and
`KnownScope` computes the name list `known here` prints. Neither is a projection, so
neither is a lens; that is the exact boundary of what the nominal machinery buys.

---

## 2. What it buys

### 2.1 The meta-theorem, corrected and stated

Fix `Σ_batch = { g_{c,q} : 1 ⇝ El c }` (labelled by the whole question
`q : Q c`, i.e. `Cost.Key`) and `Σ_pipe = { g_{c,s} : String ⇝ El c }` (labelled by
the shape only, i.e. `Cost.Shape`). An **observable** is a monoid morphism out of
`FreeMonoid Event`; an **analysis into `T`** is a structure homomorphism out of the
fragment.

> **(0) Presentation.** For each rung, `{p ∣ level p ≤ ℓ}` maps **onto** the free
> `ℓ`-structure. The map is not injective; `askC_coherent` generates the failure at
> `pipeline`. `level` is a sound and (kernel open question 1) not complete membership
> test. *Weakened from A's "iso given" in three rows.*
>
> **(1) Existence and uniqueness.** For any carrier with the five clauses, the
> interpretation exists and is unique: `PlanAlg.fold` + `fold_unique`. *This is a
> fold, not a profunctor theorem.*
>
> **(2) `ℓ ≤ batch`.** Generators are nullary, so *every* function `Key → M` — content
> dependent pricing included — induces an **exact** analysis, with no hypothesis on
> the price. `bill_exact_batch` (`Cost.lean:425`) carries exactly the level bound and
> nothing else; verified.
>
> **(3) `ℓ ≤ pipeline`.** A `Const M` target is object-blind — it has no argument
> position — so an interpretation is exactly a function of the generator label, i.e.
> `PricesByShape` (`Cost.lean:142`). The universal target is `Const (List Shape)`,
> whose interpretation is `Cost.shapes`; `bill_exact_pipeline` (`:596`) carries
> `PricesByShape` and the level bound; verified. **The residual hypothesis is not an
> assumption about terms — it is the statement that the target is a `Const`.**
>
> **(4) `ℓ ≤ branch`.**
> (a) No **exact** `Const M` analysis: `no_static_bill_at_branch`, witnessed by
> `coinBranch`. This has nothing to do with idempotence.
> (b) A **sound over-approximating** `Const M` analysis exists iff the copair's
> interpretation dominates each arm. `sup` (that is `level`) and `∏` in a positively
> ordered monotone monoid (that is `size` and `askNodes` at `(ℕ,+)`) both qualify.
> (c) The universal **enveloping** target is the free finite-**family** completion —
> finite trees of leaves *with multiplicity* — i.e. `CostTree`. `bill_mem_leaves` is
> its unit; `minFold`/`maxFold` are the min-plus and max-plus tropical homomorphisms.
> Multiplicity is not optional: `paths = Multiset.card leaves` and `battery-042` pins
> `paths 2` at equal prices, so the *most natural* categorical presentation — the free
> semilattice — changes a frozen number.
>
> **(5) `ℓ = dynamic`.** No enveloping analysis: `unbounded`'s observable has infinite
> image. This is a **witness at the rung**, not a universal over its inhabitants — a
> `dyn` whose function is constant costs what its body costs.

**Its ceiling, stated once.** The schema is about the free structure, hence about
`≈ᵖ`-classes. `level`, `size`, `askNodes`, `codes` and `costSummary` are not
`≈ᵖ`-invariant, and neither is the printed `RawProgram`; only `trace`, `billFresh`
and `billMemo` are. So the frame explains *why* every pinned number is well defined
and produces *none* of them. It also produces no counterexample (§1.1(d)), no
reachability result (`exists_min_bill` versus `minFold` is kernel open question 1),
and nothing about `billMemo`, which is not a monoid morphism by
`billMemo_not_monoid_hom` — *and that is the point the package makes about
memoization being a runtime policy.*

**What is therefore refused (P13, P16).** The full tower — `Strong`/`Choice`/`Closed`
profunctor classes, Tambara modules, the Pastro–Street adjunction, profunctor
composition, `Mon` in that monoidal category, four free constructions and an
equivalence to `Plan` on each fragment — is priced by C at 3,000–6,000 lines and
3–6 months for zero theorems, and every input is missing: Mathlib's
`Profunctor/Basic.lean` lists *"Define composition of profunctors"* under **Future
work** (verified in this checkout, line 25), `grep -rl Tambara Mathlib/` is empty
(verified), and Mathlib's coend in `Type` is `Quot (coendRel F)` — built from exactly
the material `Plan.case`'s `FinEnum` note (`Plan.lean:266–277`) exists to keep out of
`Plan`'s type. Making the tower bite would also require splitting `Plan` into four
indexed families, which is `attack-realizability-lean/D_graded_index_fails.lean`,
already compiled and already refuted ("Dependent elimination failed", quoted at
`Level.lean:14–21`). The final-tagless representation (P16) is refused for B's own
stated reason — `Rhs` must carry the printed `Raw` beside the term, `size` is read off
the skeleton, and a `forall p. C p => p x y` field would have to name its constraint
set in the record's type, defeating the inference that made it attractive — with the
addition that B's transport claim ("a claim proved in (b) transports to (a)") is
asserted and never argued.

### 2.2 What the Yoneda collapse deletes, by name

| deleted or unhypothesized | where | verified |
|---|---|---|
| `Plan.Denotes` as a hypothesis: 10 occurrences across 7 theorems | `Denote.lean:230`, `:496`×2; `Morphism.lean:255`, `:265`×2, `:276`, `:287`, `:463`×2 | counted in this checkout |
| four hand-written `Denotes` discharges in the 991-line, 75 s flagship module | `HardenPatch.lean:295`, `:304`, `:328`, `:350` | counted in this checkout |
| `Plan.Equiv.graft_congr`'s two inlined naturality premises | `Denote.lean:695` | C |
| `level_graft_le`/`level_graft_of_batch`'s `∀ Δ σ e` premise, replaced by a single bound discharged through `level_sub` | `Level.lean:230`, `:259` | A |
| the missing bifunctor square `sub_mapP`, which follows in one line and was stated nowhere | — | C, compiled |
| the missing repair `sub_graft_of_natural`, turning a documented wart into a matched pair | beside `Morphism.lean:324` | C, compiled |

One asymmetry the collapse also removes and that is worth recording in both
docstrings: Haskell's rank-2 `forall d.` gives naturality **for free by
parametricity**, Lean's `∀` does not. That is exactly why `Denotes` exists in Lean and
has no Haskell counterpart. After the collapse neither side needs the appeal.

### 2.3 The fold, and the instantiation table

`PlanAlg` is a five-field structure with `universe v`, so one record serves `Level`
(`Type 0`), `Env Γ → Dlg A` (`Type 0`) and `CostTree S` (`Type 1`) — the universe
polymorphism is what makes it work across the package's actual carriers, and it is
verified in C's probes.

| recursion | `PlanAlg` carrier | algebraic character | fits? |
|---|---|---|---|
| `denote` | `Env Γ → Dlg A` | the meaning | ✅ compiled |
| `level` | `fun _ _ => Level` | `Const` at the join-semilattice `(Level, max)` | ✅ compiled |
| `sub` | `∀ Δ, Sub Γ Δ → Plan Δ A` | fold at a function-space carrier | ✅ |
| `graft` | `Cont Γ A B → Plan Γ B` | fold with an accumulator; the `askC` clause is `Cont.reindex k Sub.wk`, which is a better explanation of "rebuild the continuation with one more weakening" than the current comment | ✅ |
| `under` | `Plan Γ A` | a signature morphism acting on the syntax | ✅ |
| `codes`, `shapes`, `asks` | `Option (List …)` | `Const` at a free monoid, partial above `pipeline` | ✅ |
| `size`, `askNodes` | `Nat` | `Const` at `(ℕ,+)` — positively ordered, **not** idempotent | ✅ |
| `explain` | `List String` | `Const` at `(List String, ++)`, and the one whose output is byte-pinned | ✅ |
| `costTree` | — | its signature absorbs the level bound (`(p : Plan Γ A) → level p ≤ branch → …`) and an algebra carrier may not mention `p` | ❌ — 11 of 12 |

`costTree`'s refusal is not a defect of the fold; it is the deliberate design decision
recorded at `Cost.lean:651–656` — "the analysis applies at this rung is the *type* of
the fold rather than a side condition" — and it is exactly what P11's move to a
`Multiset`-valued fold would dissolve.

The fusion law that comes with it is where the second prize is. Given `alg`, `alg'`
and a family commuting with the five operations, `h ∘ alg.fold = alg'.fold`; plus two
specialisations needing no `alg'` — an algebra ignoring its `Expr` arguments gives a
`sub`-invariant fold, and one ignoring `Expr`, `Q` and `Q.Shape` gives a fold
invariant under both `sub` and `under`. That buys:

* **`codes = Shape.code <$> shapes` and `shapes = Key.shape <$> asks`, both with no
  level hypothesis** — true at `branch` and `dynamic` too, where both sides are
  `none`. Two 8-line inductions with `absurd … decide` tails retire, and the level
  hypothesis is correctly relocated from *factorisation* to *totality*, which the
  package currently entangles. C's axiom print makes the point cleanly: both fusions
  are `[propext]`, where `codes_eq_of_le_pipeline` and
  `shapes_eq_trace_of_le_pipeline` are `[propext, Classical.choice, Quot.sound]`.
* **Four invariance lemmas the package does not have.** It has `level_sub` and
  `level_under`; it has no `size_sub`, `askNodes_sub`, `codes_sub`, `shapes_sub` — and
  `codes`/`shapes` being facts about the term alone is precisely what the conformance
  record depends on.
* **The two-move `absurd (le_of_case h).1 (by decide)` / `absurd h (…; decide)`
  boilerplate — 11 + 11 occurrences across 11 proofs — collapses into the `case` and
  `dyn` clauses of the relevant algebras.**

### 2.4 Panels

`Monoid (Dlg M)` with `mul` = `liftA2 (*)`, `runHom ω : Dlg M →* M`,
`traceHom ω : Dlg M →* FreeMonoid Event`, and `Plan.panel` (`Plan.lean:595`) as
`List.prod`. Then `run_panel` and `trace_panel` (`Denote.lean:365`, `:378`) are
`map_list_prod` instead of inductions, and `flatten_perm` (`:424`, eight lines of
`List.Perm` induction) is `List.Perm.prod_eq`. All compiled.

The test of whether an abstraction is the right one is that it must not quietly make
the false thing provable, and this one passes: the monoid on `Dlg M` is sequential in
the transcript by construction, so `trace_panel_not_perm_invariant`
(`Morphism.lean:425`) remains true and remains the honest statement.

Day convolution is the right name for *why the applicative structure exists at all* —
applicative = monoid in `[Set,Set]` under Day — and the wrong name for the panel fold,
which is ordinary `foldMap`. Mathlib does have `DayConvolution` and it is the wrong
tool here; the statement wanted is the elementary one that a lax monoidal functor
carries monoid objects to monoid objects.

A's premonoidal reading is the best prose in the dossier and it should be a docstring
rather than a refactor: `zipWith` chooses left-then-right sequentialization, so the
tensor is **premonoidal** (Power–Robinson) and the four scheduling-licence theorems
compute *how far its components are from central*. But D is right that they do not
merge: `approved_panel_perm` is a monoid morphism into `(Prop,∧)`, `trace_panel_perm`
is `List.Perm.flatten`, `trace_panel_perm_multiset` is a multiset, and
`billFresh_panel_perm` is a `CommMonoid`. Four theorems stay four theorems; what they
gain is a name for what they are all instances of.

### 2.5 The docstrings (P6)

Six sentences, no code, and they are the cheapest clarity available.

1. **Kernel open question 3, answered.** `askC` buys **nullary** generators, hence a
   whole-question label set, hence content-dependent pricing is a legitimate `Const M`
   interpretation there and nowhere above. This is the only clean explanation on offer
   for why `bill_exact_batch` carries no price hypothesis and `bill_exact_pipeline`
   carries `PricesByShape`, and both papers reach it independently from opposite sides.
2. **`PricesByShape` is object-blindness.** A `Const`-valued target has no argument
   position, so `onOpen`-shaped data can only price by shape. Belongs at
   `Cost.lean:142`.
3. **`Cost.asks` is the semantics at `ωDefault`, not a static analysis.**
   `asks_eq_default` (`Cost.lean:574`) is already the proof. An honesty gain at zero
   cost.
4. **The domination condition beside `level`** (§1.1(c)), which explains why `level`
   is total across `case` and an exact bill is not, and which currently exists
   nowhere.
5. **`Sub.lift = second'`, `Sub.wk = π₂`, `wk_lift` = the naturality square** — three
   `rfl`s, one name, and see §4.3's dissent for why the name is not free of content.
6. **The premonoidal centre** as what the four scheduling-licence theorems compute
   (§2.4), plus Atkey's condition and why `Sub`-as-a-function satisfies it (§1.1(b)).

### 2.6 The one Haskell simplification

P7, stated in full in §1.3: carry `(Text, Var g c)` in the handle; delete `SymEq`,
`LookupC`, `KnownVar`, `KnownVar'`; keep `Fresh`, `KnownScope` and the `Scope` index
on `Blk`/`Rhs`/`Body`. It removes ~55 lines of type-level machinery and three classes,
turns O(n²) instance resolution in a block into O(n), replaces `LookupC`'s custom
`TypeError` with GHC's own *"Variable not in scope"* at the right source span (which
`WF.hs:59` already documents as the goal), and collapses the `I`-suffixed twin split
that `Agentic.Gen` needs. Nothing at the wire changes, because the names move from the
type to the value rather than disappearing.

It needs no profunctor. `Var g c` with `varGet` *is* the projection; A §4.3(1) says so
correctly, and the `Strong` encoding (`type Handle e a = forall p. Strong p => p a a ->
p e e`) is a strictly more expensive spelling of the same function whose extra
generality — the `put` half — the language never uses.

---

## 3. What it costs

### 3.1 Lean

**Kernel reduction, not elaboration time, is the cliff.** C prices the loop
(`DslFlagship` at 249 s, `HardenPatch` at 75 s, `lakefile.toml` warning that two
concurrent elaborations have exhausted 48 GB) and not the thing that would actually
break. `level_upToTwice` is `by decide` (`Level.lean:332`);
`trace_upToTwice_stubborn` and `run_upToTwice_stubborn` are `by rfl`
(`Denote.lean:598`, `:604`); `bill_constBranch` is `rfl` (`Cost.lean:824`); the
flagship carries nine `decide +kernel` proofs. Routing `level`, `size` and
`askNodes` *through* `PlanAlg.fold` puts `Plan.brecOn` and a structure projection
between the kernel and every one of those. That is why P2 is additive and P12 is
gated: `PlanAlg` proves `level = levelAlg.fold` rather than replacing `level`.

**`simp` normal forms.** `level_ret`/`level_askC`/`level_ask`/`level_case`/`level_dyn`
are `@[simp]` and `rfl` (`Level.lean:129–142`, verified), and every
`simp only [level_ask]` in `Cost.lean` and `Level.lean` depends on the direct
definition. Replacing the definition means re-deriving and re-`@[simp]`-ing the
equation lemmas and auditing every `simpa`. C calls this "mechanical but wide"; the
adjective is right and the magnitude is understated.

**Axioms.** The new material's footprint is exactly what the modules it joins already
carry: `[Quot.sound]` (i.e. `funext`) and `[propext]`, with two of the seven strictly
*cleaner* than the theorems they subsume. `Classical.choice` is already in the
analyses via `Finset.sup`/`LinearOrder`. The invariant to state and check: the layer
is safe with respect to `Certify.lean`'s two `#guard_msgs` **iff** it does not change
the definitions of `Plan`, `denote`, `worldOf`, `lookup`, `Q` or `El` — and the guards
are build failures, not comments, so the discipline is self-enforcing.

**Two hazards the layer creates that did not exist before.** Do not make `case`'s tag
a `FintypeCat` object: `FintypeCat` bundles a `Fintype`, which holds a `Finset`, which
holds a `Multiset`, which is a `Quot`, and that would put `Quot.sound` into the *type*
`Plan` and break `certify_sound`'s zero-axiom guard immediately. And do not install a
global `Category Ctx` instance: `test/Pollution.lean` exists precisely to police what
this package imposes on other people's types, and `Agentic/Meaning.lean:2698–2704`
already records the "two instances on one type is not a category, it is an ambiguity"
trap. `scoped`, or not at all.

### 3.2 Conformance

Three surfaces are pinned, not one, and no working paper lists all three.

| surface | pinned by | contents |
|---|---|---|
| 128 frozen vectors | `test/corpus/*.json`, produced by `Observe.hs:88` | `level`, `size`, `askNodes`, `codes`, `costSummary{minFold,maxFold,paths}`, `blockAsks`, `fnAsks`, `worlds[{world,trace[Event],billFresh,billMemo}]`, **plus the printed `RawProgram` after `zeroPos`** |
| the CLI rendering | `test/CliSmoke.lean:181` | `Explain.planLines Dsl.flagshipPlan ++ Explain.revisionLines Dsl.flagshipRaw`, byte for byte, plus `costLines` and the three numbers `5`/`15`/`9` |
| the Lean `#guard_msgs` | `Certify.lean` | `certify_sound` axiom-freedom, unreachable from any of this |

**`shapes` and `asks` are pinned by nothing** (verified: zero hits across 128 files).
`Observe.hs:88`'s docstring says "the five static folds" and lists them; the record
specified in `connection.md` §3.1 includes `shapes` and `asks` and the implemented
record does not. That is a discrepancy between the specification and the freeze, it
should be recorded in the ledger, and its effect here is to *loosen* the constraint:
`shapes`/`asks` may be reorganised freely (which P3 does).

**`Explain.planLines` is pinned and no paper mentions it.** It prints, per node,
`askC` versus `ask` as distinct keywords, the shape line, `binds #{Γ.length}`, the
prompt evaluated at `Env.probe Γ`, and for a `case` the literal
`{ts.length} arms, in the enumeration order of the tag type the term carries`
(`Explain.lean:230–243`, verified). Three consequences:

* Any presentation identifying `askC` with `ask` changes the CLI output even where it
  preserves every corpus number.
* Closing the tag universe (P10) must reproduce `FinEnum.toList` order **and**
  `ts.length`. **A's "corpus impact: none" for this row is wrong; C flags it.**
* `binds #{Γ.length}` is a function of `Ctx` being a `List Code`. A `Type`-indexed
  `Flow` has no `Γ.length`. Harmless for Haskell, which has no `explain`; fatal for
  any attempt to carry B's re-indexing back to Lean.

Quiet observation changes, by proposal:

| proposal | moves | acknowledged in the papers? |
|---|---|---|
| P9 fuse `revising` + `case` | `size`, `costSummary.paths`, `planLines` | `size`/`paths` yes; `planLines` **no** |
| P10 close the tag universe | `planLines` (arm count and order) | A says "none"; **C flags it** |
| P11 `CostTree` → `Multiset` | `costSummary` triple (argued invariant, uncompiled) | flagged ⚠️ |
| P12 replacing fold bodies | nothing observationally — but `by decide` / `by rfl` / `decide +kernel` reduction cost | **no** |
| B step 1 with a leaky smart constructor | `size`, `askNodes`, `costSummary` on every entry | yes, §0.4 — and correctly named as unenforceable |

And one row B gets exactly right and deserves credit for: **"Dropping `PDyn` because
the builder cannot make one … Do not."** `Plan.hs:828` and `Cost.lean:871` are the two
ends of one witness, and deleting the Haskell end would leave
`no_finite_bill_set_at_dyn` with no counterpart.

### 3.3 GHC, if B's core were adopted (it is not — see §3.4)

Priced because the refusal should be made on the real number.

* **The smart-constructor discipline is unenforceable and unwritten.** `size` counts
  syntax nodes and is not invariant under the `Category` laws (`f >>> Ret id` has
  strictly larger `size`), so `Flow`'s `Category`, `Strong`, `Monoidal`, `Branching`
  and `Applying` instances must be skeleton-preserving smart constructors and can
  never be GADT formers. Nothing in Haskell's type system enforces that; a
  contributor adding a `Comp` former gets a lawful profunctor, a green typechecker and
  a silently different `size`, `askNodes` and `costSummary` on every corpus entry.
  B's mitigation — a property `size (f >>> Ret id) == size f` — catches unit-law leaks
  and not that failure mode. The only real enforcement is a module boundary hiding
  `Flow`'s constructors, which B does not propose and which would break `size` unless
  `size` lived inside the boundary too.
* **The headline line count is negated by that discipline.** `lmap`, `rmap`, `>>>`,
  `id`, `pureP`, `|*|`, `first'`, `second'`, `branching` and `applying` at `Flow` are
  ten operations, of which at least six must recurse over five constructors, and
  `first'` has no obvious linear definition that does not thread an accumulator — a
  naive `first' (AskC c q k) = AskC c q (lmap assoc (first' k))` re-traverses the
  subtree at every binder. The package has already been bitten once by exactly this
  class of mistake: `Plan.lean:54–80` records eager `Sub.lift` turning a `2n+2`-leaf
  tree into 122 s at `n = 24`. **A document that proposes to make `second'` the
  load-bearing operation and does not write it down has not priced itself.**
* **Rank-2 is moved, not deleted.** `Handler p`'s two fields are
  `forall (c :: Code). …`, so `RankNTypes` stays and `interp` cannot be partially
  applied and inferred.
* **`(>>>)`'s middle type is existential.** Today `graft :: Plan g a -> Cont g a b ->
  Plan g b` determines `a` from the first argument; after, GHC must determine `z` in
  `p x z -> p z y -> p x y` from context at every builder composition site.
* **Error quality.** B's own table concedes the environment prints as a nested tuple
  and is "worse to read". With `Flow` in the core that nesting appears in *term*
  errors, not only handle errors: a mis-scoped statement in a 20-binding block reports
  a 20-deep tuple mismatch.
* **What B's §0.3 claims as "the single biggest simplification" is already true.**
  The prompt-before-answer hazard is not merely detected but *unstateable* today:
  `PAsk c s e k` has `e :: Expr g Text` and `k :: Plan (c ': g) a` (`Plan.hs:505`), so
  evaluating the prompt under the extended environment does not typecheck, in all
  three folds. What the profunctor form actually moves is the **trace order**: today
  it is fixed three times by three explicit `Event : recurse` clauses; after, it is
  fixed once, inside the `Monoidal (Star m)` instance's choice of `<*>` argument
  order — where swapping two arguments typechecks, is lawful, and silently reverses
  event order at *every* target at once. The refactor concentrates the hazard into a
  place that looks like an algebra law.

### 3.4 The two-core hazard, and its resolution

**As the dossier stands, the proposal is two cores, and the papers do not notice that
they disagree with each other about which one.**

* A and C keep `Plan Γ A`, `Ctx = List Code`, `Env`, `Var`, `Sub`, `Cont`, and add a
  Yoneda collapse plus an algebra layer. `Cont` at a non-representable `A` —
  `finishCont : Cont Γ (Option (El c)) Unit` — is the residual obstruction, and A
  proposes a **spec regeneration** to remove it.
* B replaces the Haskell core with `Flow x y`, `Type`-indexed, environments as nested
  tuples. Under that encoding the obstruction **does not exist**: `finishCont` is
  `Flow (Maybe (El c), x) ()`, an ordinary arrow, no representability required. B's
  `revising` returns `K x (El c) (Maybe (El c))` without comment.

So A's most expensive proposal — the only one requiring a regenerated corpus — is
*unnecessary* under B's encoding, and B's encoding is *unavailable* in Lean without
abandoning `Ctx`-indexing, `Var`, `Env.probe` and `binds #{Γ.length}`. Neither
document cites the other on this point. Adopting both yields a Lean core indexed by
contexts and a Haskell core indexed by types, connected by 128 JSON files and a
generator that cannot reach `dyn`.

**The resolution is P15: refuse B step 1.** `connection.md` D1/D5 chose
reimplementation-plus-conformance knowingly, and the mitigation it relies on is
visible on every page of `Plan.hs`: the docstrings quote Lean line numbers constructor
for constructor — *"The five formers of Agentic/Core/Plan.lean:238"*, *"Lean's
`FinEnum.toList`, in Lean's order"*, *"`Plan.graft` (`Agentic/Core/Plan.lean:421`)"*,
*"that is the position where Lean has `absurd`"*. That **transliteration invariant** is
what a reviewer uses to check agreement *outside* the corpus's reach — and the corpus's
reach is bounded: the typed builder cannot construct a `PDyn` (`Plan.hs:502`;
`Check.lean:55` records that no clause emits `Plan.dyn`), cannot construct a
non-representable `Cont` other than `finishCont`, and emits exactly two tag types. **The
fragment where a Haskell `Flow` core and a Lean `Plan` core would first disagree —
`dyn`, arbitrary continuations, tags beyond `Bool`/`VTag` — is precisely the fragment
neither conformance tier reaches.** B's step 1 spends the invariant: after the rewrite
there is no `Env`, no `Var`, no `Sub`, no `Cont`, no `graft` on the Haskell side to line
up against. B lists what step 1 does not touch and never lists this.

The honest cost of the resolution, stated so it is not discovered later: **P9 stays
expensive.** The `Option (El c)` obstruction that B dissolves for free must, on the
Lean side, either be paid for with a spec regeneration or left in place. Leaving it in
place is the recommendation, and the consolation is that the Yoneda theorem *locates*
the obstruction precisely — the one place the language leaves the answer universe is
the one place representability fails — which is a better outcome than dissolving it in
a language that is not normative.

---

## 4. The recommendation

### 4.1 Adopt now — observation-preserving, additive (P1–P8)

Order matters, and it is C's: **do not begin with the Yoneda layer's ripple.**
P2–P5 are additive theorems about unchanged definitions and never re-elaborate
`DslFlagship` (249 s) or `HardenPatch` (75 s). P1's ripple through `Denote.lean`,
`Morphism.lean`, `Dsl.lean` and `HardenPatch.lean` is the real work and should be a
separate, reviewed change.

| # | Item | Evidence | Corpus |
|---|---|---|---|
| **P2** | `PlanAlg` + `fold` + `fold_unique`; `level = levelAlg.fold`, `denote = denoteAlg.fold` as theorems | compiled (C §6.2), `[Quot.sound]`, universe-polymorphic | none |
| **P3** | `codes_eq_map_shapes`, `shapes_eq_map_asks`; the `isSome` results as corollaries | compiled (C §6.3), `[propext]` only, hypothesis-free | none |
| **P4** | `Monoid (Dlg M)`, `runHom`, `traceHom`, `panel = List.prod`, `run_panel'`, `trace_panel'` | compiled (C §6.4) | none |
| **P5** | syntactic `mapP_id` (= `Morphism.graft_pure`), `mapP_comp` (= `graft_assoc` + `rfl`), `sub_mapP` | compiled (C §1.1, §6.1); strengthens the existing `≈ᵖ` versions at `Morphism.lean:587`, `:593` | none |
| **P1** | `Cont.Natural`, `ofPlan`/`toPlan`, both round trips, `sub_graft_of_natural`, `denotes_ofPlan`; **as theorems only** — `revising`'s definition is untouched | compiled (C §6.1, ~95 lines); D re-ran the probe file | none |
| **P6** | six docstrings (§2.5) | — | none |
| **P8** | record the three pinned surfaces and the `shapes`/`asks` specification-versus-freeze discrepancy in the ledger | verified here | none |
| **P7** | Haskell: value-carrying handles; delete `SymEq`/`LookupC`/`KnownVar`/`KnownVar'`; keep `Fresh`, `KnownScope`, the `Scope` index | B §3.2–3.3, D (i)#10 | none, provided names move type→value |

Net Lean cost, C's estimate with D's timing correction applied: ~250 new lines,
~120 retired, and the honest sale is not a shrink but a change in the number of
distinct obligations — twelve structural recursions become one fold plus twelve
algebra records, and 22 `absurd … decide` occurrences collapse into two algebra
clauses. Budget three to four focused days, of which P1 is two.

### 4.2 Gated — behind a spec regeneration or a measured diff (P9–P12)

Each is an owner decision, and each has a named gate rather than an argument.

**P9 — fuse `revising` with its consuming `case`, deleting `Option (El c)`.** Today
each loop exit is `ret (some a)`/`ret none` plus a grafted two-armed `caseB`; fused,
the arms sit at the exits. **Gate:** a `corpus-gen` diff *and* a `CliSmoke` run —
`size` and `costSummary.paths` move on every `revising` entry, and so does
`Explain.planLines`, which no paper noticed. **Prerequisite correction:** the fused
signature is `Plan (c :: Γ) Verdict → Plan (.verdict :: c :: Γ) (El c) → …`, per
`Check.lean:498` and `Builder.hs:1021`. C §7.1 has the de Bruijn order reversed, and
in a proposal whose whole content is a de Bruijn bookkeeping isomorphism that is not a
typo.

**P10 — close the `case` tag universe and `dyn`'s `B`, demoting `Plan` to `Type 0`.**
Real capability: `Type 0` residence, `deriving` becomes available, `Cont`'s `∀ Δ` stops
being large, and the Lean and Haskell signatures become literally the same (the
Haskell already has `data Tag t where TBool; TVTag`, `Plan.hs:468`). **Gate:** a
`CliSmoke` run — `planLines` prints `FinEnum.toList T` arm counts in enumeration order.
Also verify `Cost.unbounded` survives (`Cost.lean:871` needs `B = Nat`; `B = El .text`
works).

**P11 — replace `CostTree` with a `Multiset`-valued fold.** Deletes the analysis
layer's only `Quot`-bearing datatype (`CostTree.node` carries a `Fintype` inside a
`Type 1` inductive), moves the branch rung into the monoid semiring `Multiset S` —
which is the object `Agentic/Panel.lean` already calls `S⟨K⟩` — and makes `costTree`
the twelfth fold. **Gate:** a `corpus-gen` diff. It touches `costSummary`'s three
pinned numbers through `minFold`/`maxFold`/`card`; it is argued corpus-safe and was
**not compiled**, and it should be gated on the diff, not on the argument.

**P12 — replace the twelve recursion bodies with `PlanAlg.fold`.** C is internally
inconsistent here: §4.1's table says L3 "deletes 11 recursion bodies (~130)" while
§5.3 says `PlanAlg` proves `level = levelAlg.fold` *rather than replacing* `level`.
Only the additive version is P2. **Gate:** a timing diff on `DslFlagship`'s nine
`decide +kernel` proofs, `Level.lean:332`'s `by decide` and `Denote.lean:598`/`:604`'s
`by rfl` — kernel reduction is the un-priced risk (§3.1), not elaboration.

### 4.3 Refused, recorded as understanding (P13–P16)

**P13 — the tower.** §2.1's closing paragraph. Refused on five grounds, in order of
decisiveness: the rungs are a fold, not four types, and making the tower bite reopens
`D_graded_index_fails.lean`; the `⇒` direction stays a witness in any case; profunctor
composition is a coend and Mathlib's coend in `Type` is `Quot`, contradicting the
design's own `FinEnum`-over-`Fintype` discipline; Mathlib supplies none of the
inputs and says so in its own header; and `Type 1` plus `TypeCat.Hom` is a tax on
every statement.

**P14 — optics on `revising`, and open games.** §1.2. Refused because all three lens
laws fail and each failure is the combinator's purpose. **Reopen condition:** if
budgets become dynamic — spend as you go, return the residual — the backward flow
appears and the optic becomes load-bearing overnight. `PlanUpTo` (`Cost.lean:996`)
being a subtype of the term rather than a threaded resource is the recorded design
decision that keeps it inert, and it is the thing to watch.

**P15 — B step 1, the `Flow` re-indexing.** §3.4. Refused because it spends the
transliteration invariant in exactly the fragment the conformance tiers cannot reach.
**Reopen condition:** if the Haskell ever needs a term representation Lean does not
have — a staged or compiled form, say — or if the two implementations are ever
connected by something stronger than a sampled corpus plus docstring line references,
the calculation changes. Note that a regenerated corpus does *not* reopen it: the
hazard is about indexing, not about frozen numbers.

**P16 — final-tagless as a production surface.** §2.1. Refused for B's own reasons.
Recorded as a proof device; its transport claim would need arguing before anything is
proved in it.

### 4.4 Dissents recorded

**Dissent 1 (against D §6's "no profunctor content", partially).** D's summary — "its
best result is a Yoneda lemma and a fold; its profunctor framing is decoration on the
first and a licence to break the two-implementation invariant on the second" — is
mathematically correct and is adopted as this page's §0. But D adds that items (i)1–5
"would have been found by asking 'is `Cont` representable?' and 'is this a fold?'
without opening a single optics paper", and that is a claim about process, not
mathematics, and it is not supported: they were not found, over the package's whole
development, until the profunctor question was asked. Naming `Sub.lift = second'`
generated a checklist of Tambara/bifunctor coherence squares, and running that
checklist is what surfaced `sub_mapP` — the bifunctor square that is stated nowhere in
the package and follows in one line. **Vocabulary that generates a completeness
checklist is not decoration even when every entry it finds is a `rfl`.** The
proportion is still D's: one missing theorem is not four thousand lines of Tambara
modules. *Recorded, not acted on; no decision turns on it.*

**Dissent 2 (B, against P15).** B's re-indexing is not incorrect as a construction —
the tuple encoding really does make `Cont` rank-1, and it dissolves A's `Option (El c)`
obstruction for free. B's dissent is that a repository willing to regenerate its spec
for P9 is already accepting a core change, and should prefer the change that removes
the obstruction rather than the one that renumbers around it. **The reply, and the
reopen condition:** the two are not comparable costs. P9 spends a frozen corpus, which
is regenerable; P15 spends the transliteration invariant, which is not. Reopen per
P15's condition above.

**Dissent 3 (A, against P10's gate).** A rates the tag-universe closure "corpus
impact: none" and recommends it as nearly free. **The reply:** `Explain.planLines`
prints `FinEnum.toList` order and `ts.length`, and `CliSmoke.lean:181` pins the
rendering. C flags this and A does not. The gate stands; if the `CliSmoke` diff is
empty, P10 becomes a P1-tier item and should be promoted.

**Dissent 4 (C, against P2's additivity).** C's §4.1 table sells L3 on deleting
eleven recursion bodies, which requires replacing them. **The reply:** C's own §5.3
says the opposite, and the un-priced risk is kernel reduction through `Plan.brecOn`,
not lines. Additive now (P2); replacement gated on a timing diff (P12). If the diff
shows no regression, promote.

**One thing the papers got right that this page should not obscure.** All three
independently refute the seed's two headline claims — `revising` is not a lens, and
"`Const` is monoidal but not compositional, hence cost dies at `dyn`" is wrong — and
all three refute them from the sources rather than from taste. A and C additionally
converge, independently, on the `Cont`–Yoneda collapse as the highest-value item,
which is the strongest corroboration in the dossier. And **C is the paper that behaved
like an engineering document**: it compiled its claims, printed its axioms, read
Mathlib in the checkout instead of from memory, priced the version it recommends
*against*, and told the owner not to start with the expensive item. Its errors are all
in the prose around the compiled core. That is the right failure distribution.

---

## 5. Literature

Verified against the sources named. Where a detail could not be confirmed it is
marked, rather than guessed.

### 5.1 Corrections to the working papers' citations

1. **Pastro–Street.** Craig Pastro, Ross Street, *Doubles for monoidal categories*,
   **Theory and Applications of Categories 21(4):61–75, 2008** (arXiv:0711.1859).
   A cites issue 4, B cites issue 6; **A is right** and B's entry should be corrected.
   *Verified against the TAC volume listing.*
2. **Jacobs–Heunen–Hasuo.** Bart Jacobs, Chris Heunen, Ichiro Hasuo, ***Categorical
   semantics for arrows***, **Journal of Functional Programming 19(3–4):403–438,
   2009**, doi:10.1017/S0956796809007308. A's title is right; B writes "of arrows" and
   should be corrected. *Verified.* Its predecessors are Heunen–Jacobs, *Arrows, like
   monads, are monoids*, MFPS XXII, ENTCS 158:219–236, 2006, and Jacobs–Hasuo,
   *Freyd is Kleisli, for arrows*, MSFP 2006.
3. **Tambara.** Both papers guess and both flag the guess. The reference is
   **D. Tambara, *Distributors on a tensor category*, Hokkaido Mathematical Journal
   35:379–425, 2006** — not a *Journal of Algebra* paper, and not titled "Distributed
   modules over a monoidal category". It is the origin of "Tambara module" as the
   optics literature uses the term, introduced there as *distributors of tensor
   categories*. *Verified against secondary sources (Stroiński, PLMS 2024;
   Pastro–Street); I have not seen the printed paper.*
4. **Lindley–Wadler–Yallop's theorem.** A attributes to LWY the claim that "**static**
   arrows, those whose effect does not depend on the input, correspond to idioms", and
   D flags the gloss as possibly not the paper's definition. **D is right to flag it.**
   The paper's actual results are the two type isomorphisms — idioms are arrows with
   `A ⇝ B ≅ 1 ⇝ (A → B)`, monads are arrows with `A ⇝ B ≅ A → (1 ⇝ B)` — with
   oblivious/meticulous/promiscuous as the *intuition* for them. §1.1(a) states the
   isomorphism form, which is checkable here and is the better sentence for a
   docstring. *Verified against the paper's abstract and the ScienceDirect record.*
5. **Atkey's actual result.** A cites Atkey to justify stating `pipeline` as a Freyd
   category. Atkey's paper says the folklore arrows-are-Freyd-categories equivalence
   "is more subtle than that" and derives *enriched* and *indexed* Freyd categories
   instead, with a further condition for isomorphism to an ordinary Freyd category —
   the differentiating point being the structure available on a computation's inputs.
   agent-cat satisfies the condition maximally because `Sub` is a semantic function.
   §1.1(b). *Read from the abstract; not checked against the printed proof.*

### 5.2 The hierarchy

* **John Hughes**, *Generalising monads to arrows*, **Science of Computer Programming
  37(1–3):67–111, 2000**. `ArrowApply ⟺ Kleisli of a monad`: the identification of
  `dyn`, and why `bindP` is the only derived form that needs it.
* **Ross Paterson**, *A new notation for arrows*, **ICFP 2001, 229–240**. The
  `ArrowChoice` law list; the `proc`/`-<` notation whose de Bruijn analogue `Plan` is.
* **Sam Lindley, Philip Wadler, Jeremy Yallop**, *Idioms are oblivious, arrows are
  meticulous, monads are promiscuous*, MSFP 2008; **ENTCS 229(5):97–117, 2011**,
  doi:10.1016/j.entcs.2011.02.018. §1.1(a). *Verified.*
* **Sam Lindley, Philip Wadler, Jeremy Yallop**, *The arrow calculus*, **JFP
  20(1):51–69, 2010**. The normal form of the `pipeline` fragment is their calculus's.
* **Robert Atkey**, *What is a categorical model of arrows?*, MSFP 2008; **ENTCS
  229(5):19–37, 2011**, doi:10.1016/j.entcs.2011.02.014. §1.1(b). *Verified.*
* **John Power, Edmund Robinson**, *Premonoidal categories and notions of
  computation*, **MSCS 7(5):453–468, 1997**; **John Power, Hayo Thielecke**, *Closed
  Freyd- and κ-categories*, ICALP 1999, LNCS 1644:625–634; **Paul Blain Levy, John
  Power, Hayo Thielecke**, *Modelling environments in call-by-value programming
  languages*, **Information and Computation 185(2):182–210, 2003**. The premonoidal
  tensor and its centre: §2.4.
* **Andrey Mokhov, Georgy Lukyanov, Simon Marlow, Jeremie Dimino**, *Selective
  applicative functors*, ICFP 2019, **PACMPL 3(ICFP), article 90**. The
  over-/under-approximation discipline at `branch`, i.e. `bill_mem_leaves` versus
  `minFold_not_attained`. Not the right citation for `case`'s algebra, since
  `pipeline` already exceeds applicative.
* **Andrey Mokhov, Neil Mitchell, Simon Peyton Jones**, *Build systems à la carte*,
  ICFP 2018, **PACMPL 2(ICFP), article 79**; extended, **JFP 30, e11, 2020**. The same
  static/dynamic dependency grading as the level lattice, independently discovered.

### 5.3 The free constructions and the fold

* **Guillaume Allais, Robert Atkey, James Chapman, Conor McBride, James McKinna**,
  *A type- and scope-safe universe of syntaxes with binding: their semantics and
  proofs*, ICFP 2018; **JFP 31, e22, 2021**. **The direct prior art for P2 and P3** —
  N bespoke traversals become one generic semantics, formalised, in exactly this
  setting — and the reason to write `PlanAlg` rather than a profunctor tower. *It is
  not a profunctor paper, and that is the point.*
* **Thorsten Altenkirch, James Chapman, Tarmo Uustalu**, *Monads need not be
  endofunctors*, **LMCS 11(1:3), 2015** (earlier FoSSaCS 2010). `graft` as the Kleisli
  extension of a **relative monad** over `Expr` — the citation `Morphism.lean:218–226`
  is reaching for. §1.3.
* **Exequiel Rivas, Mauro Jaskelioff**, *Notions of computation as monoids*, **JFP 27,
  e21, 2017**. The uniform monoid-in-a-monoidal-category account. Cited for the
  reading; refused as an implementation (P13).
* **Paolo Capriotti, Ambrus Kaposi**, *Free applicative functors*, MSFP 2014, **EPTCS
  153**, doi:10.4204/EPTCS.153.2. The free-applicative normal form. *Venue and DOI
  verified; the page range commonly given as 2–30 was not confirmed.*
* **Marcelo Fiore, Gordon Plotkin, Daniele Turi**, *Abstract syntax and variable
  binding*, LICS 1999; **Thorsten Altenkirch, Bernhard Reus**, *Monadic presentations
  of lambda terms using generalized inductive types*, CSL 1999. The
  presheaf/substitution-algebra reading of §1.3 — and the reason it does *not* import
  cleanly: `E` here is the full image of `Env` in `Set`, not a syntactic site of
  contexts and renamings.
* **Brian Day**, *On closed categories of functors*, Reports of the Midwest Category
  Seminar IV, **LNM 137:1–38, 1970**. Why the applicative structure exists at all;
  not the name for the panel fold. *Page range unconfirmed.*

### 5.4 Strength, optics and Yoneda

* **Guillaume Boisseau, Jeremy Gibbons**, *What you needa know about Yoneda:
  profunctor optics and the Yoneda lemma*, ICFP 2018, **PACMPL 2(ICFP), article 84**.
  The methodological precedent for P1: a higher-rank type *is* a representability
  fact, and collapsing it is the intended move.
* **Saunders Mac Lane**, *Categories for the Working Mathematician*, Ch. X. Kan
  extensions; the identification of `Cont` as a right Kan extension and the
  fully-faithful collapse.
* **Matthew Pickering, Jeremy Gibbons, Nicolas Wu**, *Profunctor optics: modular data
  accessors*, **The Art, Science, and Engineering of Programming 1(2), article 7,
  2017**. The lens/`Strong` dictionary against which §1.2's refutation is checked.
* **Craig Pastro, Ross Street**, *Doubles for monoidal categories*, **TAC 21(4):61–75,
  2008**, over **D. Tambara**, *Distributors on a tensor category*, **Hokkaido Math.
  J. 35:379–425, 2006**. Tambara modules; the class `Sub.lift = second'` inhabits, and
  the archetypal one at that.
* **Bryce Clarke, Derek Elkins, Jeremy Gibbons, Fosco Loregian, Bartosz Milewski,
  Emily Pillmore, Mario Román**, *Profunctor optics, a categorical update*,
  **Compositionality**, arXiv:2001.07488. The general mixed-optic taxonomy, in which
  `revising` is not an optic of any kind — there is no residual flowing backward.
  *Journal volume and year not confirmed.*
* **Philip Wadler**, *Theorems for free!*, **FPCA 1989, 347–359**. Why Haskell's
  rank-2 `Cont` gets naturality for nothing and Lean's does not — the asymmetry P1
  removes.

### 5.5 The paths not taken

* **Jules Hedges**, *Towards compositional game theory*, PhD thesis, QMUL, 2016;
  **Neil Ghani, Jules Hedges, Viktor Winschel, Philipp Zahn**, *Compositional game
  theory*, **LICS 2018, 472–481**. Open games' lens structure exists because utilities
  flow backward. §1.2, P14's reopen condition.
* **André Joyal, Ross Street, Dominic Verity**, *Traced monoidal categories*, **Math.
  Proc. Cambridge Philos. Soc. 119(3):447–468, 1996**; **Masahito Hasegawa**,
  *Recursion from cyclic sharing*, TLCA 1997, LNCS 1210:196–213. What a loop *former*
  would be, hence what `Agentic/Star.lean`'s abandoned star was.
* **J. J. M. M. Rutten**, *Universal coalgebra: a theory of systems*, **TCS
  249(1):3–80, 2000**. Moore coalgebras — the reading A proposes for `revising` and
  that §1.2 downgrades, because both maps are effectful.
* **Oleg Kiselyov**, *Typed tagless final interpreters*, in Generic and Indexed
  Programming, **LNCS 7470:130–174, 2012**; **Jeremy Gibbons, Nicolas Wu**, *Folding
  domain-specific languages: deep and shallow embeddings*, **ICFP 2014, 339–347**. The
  deep/shallow duality behind P16.

### 5.6 Mathlib, read in this checkout

`Mathlib/CategoryTheory/Profunctor/Basic.lean` (Dagur Asgeirsson, Adam Topaz, Adrian
Marti) — `abbrev Profunctor := C ⥤ Dᵒᵖ ⥤ Type w`, with *"Define composition of
profunctors."* under **Future work** at line 25 (verified). `grep -rl Tambara
Mathlib/` returns nothing (verified). `Mathlib/CategoryTheory/Limits/Types/End.lean` —
coends as `Quot (coendRel F)`. `Mathlib/CategoryTheory/Types/Basic.lean` — `TypeCat.Hom`
is a one-field wrapper, so bare `A → B` is not the hom type.
`Mathlib/CategoryTheory/Monoidal/{Functor,Mon,DayConvolution}.lean` — present.
`Mathlib/Data/FinEnum.lean` — `card` + `equiv : α ≃ Fin card` + `[decEq]`,
quotient-free, which is the whole point of `Plan.case`'s choice. No Freyd categories,
no premonoidal categories, no free applicative/arrow/selective, no profunctor optics
classes.

---

## 6. Working papers

Kept in `doc/research/profunctor-design/`, unedited, as the evidence behind this page.

| file | what it is | how to read it |
|---|---|---|
| `a-categorical-frame.md` | the mathematics; the meta-theorem; the `Cont`-as-Kan-extension computation | §4 is correct and is P1's source. §5.1(4b) is the central error (§1.1(c)). Read §0's status column as "surjection", not "iso" (§1.1(b)). |
| `b-haskell-evaluator.md` | a concrete Haskell redesign around `Flow x y` | §1.3 (`PricesByShape` as object-blindness), §1.5–1.6 (`Forget` has no `Category`; `size` is not law-invariant), §3.2–3.3 (the handles, and what the corpus does and does not obstruct) are the durable parts. §0.3, §1.7, §2.2's lattice claim and §2.4 are withdrawn by §3.3–3.4 here. |
| `c-lean-side.md` + `c-lean-side-probes.lean` | the Lean side, with 30 compiled declarations and printed axiom footprints | the compiled core is the source of P1–P5. Its prose errors are the corpus record (§3.2 here), the de Bruijn order (§4.2), the "ignores its `Sub`" sentence (§1.3), and the additive/replacing inconsistency (§4.4 Dissent 4). |
| `d-attack.md` | the adversarial pass; re-ran C's probes; checked the corpus | the verdict tables are the backbone of §4 here. §6's "no profunctor content" is adopted as §0, with one recorded dissent (§4.4 Dissent 1). |

To re-run C's probes:

```
export PATH=/nix/store/…-lean4-4.30.0/bin:$PATH     # or: nix develop
cd /Users/johnw/src/agent-cat
lake env lean doc/research/profunctor-design/c-lean-side-probes.lean
```

Expect seven `#print axioms` lines and exit 0. (C's Appendix B says "Expect no
output"; it was written, not exercised. D corrected this.) The file sits in `doc/`,
which is in no `lean_lib` glob and no `srcDir`, so `lake build` cannot see it.
