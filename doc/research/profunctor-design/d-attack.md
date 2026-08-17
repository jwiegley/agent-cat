# D — The attack

*An adversarial pass over `a-categorical-frame.md`, `b-haskell-evaluator.md` and
`c-lean-side.md`, checked against the sources rather than against the seed brief.
Every claim below that says a document is wrong names the file and line that makes
it wrong. Where I could not check something I say so.*

---

## 0. Method, and what was actually re-run

Read in full: `Agentic/Core/{Plan,Level,Cost,Denote,Morphism,Explain,Question}.lean`
(the relevant sections), `Agentic/Core/Dsl/Check.lean:485–530`,
`haskell/src/Agentic/{Plan,World,Exec,Builder,Workflow,Observe}.hs`,
`doc/research/dsl-redesign/connection.md` §0–§3.1, `test/CliSmoke.lean`, and the
128 frozen vectors in `test/corpus/`.

**Re-run, not taken on trust.** Document C's probe file compiles. I ran it:

```
$ export PATH=/nix/store/0fir0wp7vh4r7g6qmwgzznxl5qna6i7a-lean4-4.30.0/bin:$PATH
$ lake env lean doc/research/profunctor-design/c-lean-side-probes.lean
'Agentic.Core.Cont.toPlan_ofPlan' depends on axioms: [propext, Quot.sound]
'Agentic.Core.Cont.ofPlan_toPlan' depends on axioms: [Quot.sound]
'Agentic.Core.sub_graft_of_natural' depends on axioms: [Quot.sound]
'Agentic.Core.codes_eq_map_shapes' depends on axioms: [propext]
'Agentic.Core.shapes_eq_map_asks' depends on axioms: [propext]
'Agentic.Core.PlanAlg.fold_unique' depends on axioms: [Quot.sound]
'Agentic.Core.run_panel'' depends on axioms: [propext, Quot.sound]
```

Exit 0, 421 lines, no errors, no warnings, and the seven axiom footprints are
**exactly** the ones §5.1 of document C prints. That is the single most credible
thing in the dossier and it should be weighted accordingly: document C's ✅ marks
are real, and everything it marks ⚠️ should be read as untested.

(One nit: Appendix B says *"Expect no output."* Seven `#print axioms` commands
produce seven lines. The appendix was written, not exercised.)

**Not checked by me:** the Haskell does not rebuild in this shell (no GHC on
`PATH`); I did not run `corpus-gen`; I did not verify the wall-clock numbers in
document C §4.1 or the `DslFlagship` 249 s figure; and I did not chase the LWY
"static arrows ≅ idioms" theorem to the printed page (see §3).

---

## 1. Verdicts

### (i) Adopt now

| # | Proposal | One-line reason |
|---|---|---|
| 1 | **C-L5 / A-§4: `Cont.Natural` + `Cont.ofPlan`/`toPlan` + `sub_graft_of_natural` + `sub_mapP` + `denotes_ofPlan`, as an additive theorem layer** | Compiles, I ran it; kills the ten `Plan.Denotes` hypothesis occurrences and `HardenPatch`'s four hand discharges; repairs `Morphism.sub_graft_not_natural` into a matched pair; zero corpus impact. |
| 2 | **C-§6.3: `codes_eq_map_shapes`, `shapes_eq_map_asks`** | Compiles; hypothesis-free (true at `branch`/`dynamic` too, where both sides are `none`); retires two inductions and correctly separates *factorisation* from *totality*. |
| 3 | **C-§6.4: `Monoid (Dlg M)`, `runHom`/`traceHom`, `panel = List.prod`** | Compiles; `run_panel`/`trace_panel` become `map_list_prod`, `flatten_perm` becomes `List.Perm.prod_eq`, and `trace_panel_not_perm_invariant` stays true — the abstraction does not make the false thing provable. |
| 4 | **C-§1.1: syntactic `mapP_id`/`mapP_comp`** | `Plan.mapP id p = p` is literally `Morphism.graft_pure`; the package currently proves the strictly weaker `≈ᵖ` versions (`Morphism.lean:587`, `:593`). Two lines. |
| 5 | **C-§6.2: `PlanAlg` + `fold` + `fold_unique`, *additively*, with `X = XAlg.fold` as theorems** | Compiles, universe-polymorphic, `[Quot.sound]` only. Additive only — see verdict (ii)#4 for the replacement version. |
| 6 | **A-§2.4: answer kernel open question 3 in a docstring — `askC` buys *nullary* generators, hence a whole-question label set, hence content-dependent pricing** | Correct, and it is the only clean explanation on offer for why `bill_exact_batch` (`Cost.lean:425`) carries no price hypothesis and `bill_exact_pipeline` (`:596`) carries `PricesByShape`. Costs one docstring. |
| 7 | **B-§1.3: record that `PricesByShape` is "the analysis's `onOpen` cannot see the prompt"** | Same fact as #6 from the other side; true, cheap, and it is the tightest prose in document B. Adopt the *sentence*, not the refactor. |
| 8 | **B-§1.5 / A-§2.3: reclassify `Cost.asks` as "the semantics at `ωDefault`", not a static analysis** | `asks_eq_default` (`Cost.lean:574`) is already the proof. An honesty gain at zero cost. |
| 9 | **B-§1.6: the seed's "`Const`/`Forget` is monoidal but not compositional" separates *batch from pipeline*, not branch from dynamic** | `Forget r x y = x → r` has no `Category` instance; `Tally s` does. Correct refutation of the brief, and both A and C independently agree. |
| 10 | **B-§3.2's *value-carrying handle*, stripped of the lens encoding: carry `(Text, Var g c)` in `V n c g` and delete `SymEq`/`LookupC`/`KnownVar`/`KnownVar'`** | This needs no profunctor and no `Flow`: `Var g c` with `varGet` *is* the projection (A-§4.3(1) says so correctly). It is exactly what the existing `I`-suffixed entry points already do (`Builder.hs:1248` ff.), and it answers the O(n²) instance-resolution complaint of B-§3.3 on its own. |

### (ii) Adopt only behind a spec regeneration (owner decision)

| # | Proposal | One-line reason |
|---|---|---|
| 1 | **A-§4.2 / C-§7.1: fuse `revising` with its consuming `case`, deleting `Option (El c)`** | Correctly flagged by A: each loop exit today is `ret (some a)`/`ret none` plus a grafted two-armed `caseB`; fused, `Plan.size` and `costSummary.paths` both move on every `revising` entry. Also moves `Plan.explain` output, hence `test/CliSmoke.lean:181` — which no document mentions. |
| 2 | **A-§2.6 / C-§5.2(2): close the `case` tag universe (and `dyn`'s `B`), demote `Plan` to `Type 0`** | Real capability, but **A's "corpus impact: none" is wrong**: `Plan.explain` prints `FinEnum.toList T` arm counts in enumeration order (`Explain.lean:230–243`) and `CliSmoke` pins the rendering byte-for-byte. C flags this; A does not. Also verify `Cost.unbounded` survives (`Cost.lean:871` needs `B = Nat`; `B = El .text` works). |
| 3 | **C-§7.2(3): replace `CostTree` with a `Multiset`-valued fold** | Argued corpus-safe, **not compiled** (C's own ⚠️). It touches `costSummary`'s three pinned numbers through `minFold`/`maxFold`/`card`; gate on a `corpus-gen` diff, not on the argument. |
| 4 | **C-L3 as a *replacement* of the twelve recursion bodies** | C is internally inconsistent here: §4.1's table says L3 "deletes 11 recursion bodies (~130)" while §5.3 says "`PlanAlg` proves `level = levelAlg.fold` rather than replacing `level`", i.e. additive. Replacing them routes `level`, `size`, `askNodes` through `brecOn`, and the package has `level_upToTwice := by decide` (`Level.lean:332`), `trace_upToTwice_stubborn := by rfl` (`Denote.lean:598`) and nineteen `decide +kernel` proofs in a 249 s module. Kernel-reduction cost is un-priced and is the actual risk. |

### (iii) Beautiful, not load-bearing

| # | Claim | One-line reason |
|---|---|---|
| 1 | **`Sub.lift = second'`, `Sub.wk = π₂`, `wk_lift` = a Tambara coherence square** (A-§3.3, B-§1.1) | True and worth a docstring, but at `(->)` `second'` *is* `id × −`; the "Tambara module" is the archetypal one. This names three `rfl`s; it proves nothing new and unlocks nothing. |
| 2 | **`Q c ≅ Q.Shape c × String` "is a constant-complement lens"** (A-§3.2) | It is a product projection (`Question.lean:301`, `:304`, three `rfl`s at `:310`, `:315`, `:321`). Every product projection is a constant-complement lens. The content is `exists_relabel_not_onQ` (`:386`) — that `Sig` acts on the first factor only — and that theorem is already there and already explained without optics. A also mislabels the three `rfl`s ("GetPut, PutGet and the iso condition"): a lens has two laws, the third is `withPrompt_shape`, which is the *iso*, and once you have the iso the lens vocabulary is redundant. |
| 3 | **The premonoidal-centre reading of the four scheduling-licence theorems** (A-§3.4) | The best prose in document A and genuinely under-named in the package. But it re-describes `approved_panel_perm` / `trace_panel_perm` / `trace_panel_perm_multiset` / `billFresh_panel_perm`; it does not merge them, because each is invariance of a *different* observable under a *different* argument (monoid morphism into `(Prop,∧)`; `List.Perm.flatten`; multiset; `CommMonoid`). Four theorems stay four theorems. |
| 4 | **`revising` is a Moore coalgebra `S → V × S`** (A-§3.1, A-§0 table) | Both maps are *effectful* — `check : Cont Γ (El c) Verdict` asks a question (`Denote.lean:564`) — so the coalgebra is `S → Dlg (V × S)` at best, i.e. a coalgebra in a Kleisli category. C says this in one clause and then correctly drops it. Once said properly, "Moore machine" adds nothing to "`Nat.rec` writes the unrolling", which is what `Plan.lean:621` already says. |
| 5 | **Open games / bidirectional optics** (A-§3.5, B-§5, C-§2.2) | All three agree it is inert, and all three are right: `denote : Plan Γ A → Env Γ → Dlg A` is covariant end to end and `PlanUpTo` (`Cost.lean:996`) is a subtype of the term, not a threaded resource. A's "revisit if budgets become dynamic" is the correct standing note. |
| 6 | **B-§2.2's final-tagless representation** | B itself explains why it cannot be the production representation (`Rhs` must carry the printed `Raw` beside the term, `size` is read off the skeleton). It is a proof device, and the *transport* claim ("a claim proved in (b) transports to (a)") is asserted and not argued. |

### (iv) Wrong

| # | Claim | Why |
|---|---|---|
| 1 | **A-§5.1(4b): "a sound over-approximating `Const M` analysis exists *iff* `M` is a join-semilattice and `case` is interpreted by the join"** — billed as "the load-bearing sentence of the whole document" | Refuted by two folds in the package. `Plan.askNodes` (`Explain.lean:155`) interprets `>>>` as `+` and `case` as `Σ` in `(ℕ,+)`, which is not idempotent, and it *is* a sound over-approximation of trace length at `≤ branch` (a run walks one path; every ask node on that path is a node of the term). `Plan.size` (`:140`) is a second instance. The correct condition is order-theoretic, not idempotence: the ordered monoid must be **positively ordered and monotone** (`1 ≤ m`, `·` monotone), so that `⟦arm t⟧ ≤ ⟦case⟧`. `sup` is one way; `·` in a positive monoid is another. A's own §5.1 preamble concedes "`Const M` … satisfies Paterson's stated `ArrowChoice` laws with `left' = id`", which is precisely the non-idempotent interpretation it then declares impossible. |
| 2 | **A-§2.3, "Proposition (pipeline)", tabled in §0 as "iso given"** | `{p : Plan Γ A ∣ level p ≤ pipeline}` contains every `askC` chain, and `askC` is not a generator of `Σ_pipe` (A's own §1.2). Adding `Σ_batch` does not repair it: `askC_coherent` (`Denote.lean:151`) says `askC c q k` and `ask c q.shape (const q.prompt) k` have the *same meaning* and are *different terms*, so the free-Freyd hom-set is a quotient of the fragment, not a bijection with it. A's §5.3(7) already states that a presentation modulo `≈ᵖ` "can never replace the term" because `size`/`askNodes`/`explain`/`paths` are not `≈ᵖ`-invariant. §2.3 and §5.3(7) cannot both stand; §5.3(7) is the true one. Same objection, weaker, applies to §2.2's "isomorphism of applicative functors". |
| 3 | **A-§3.1's first refutation argument: "the pair is not of lens type: the second component consumes the very `a` the first produced, not an independent `b`"** | A type-level claim that is false. `revise : Cont Γ (El c × Verdict) (El c)` has exactly the shape `s × b → t` with `b = Verdict`; nothing in the *type* forces the verdict fed to `put` to be the one `get` produced — that is a fact about the loop's use site. The correct refutation is the one B and C give (all three laws fail, and each failure is the combinator's purpose). A reaches the right conclusion by a bad argument in the one place it claims a "refutation" in its §0 table. |
| 4 | **A-§4.2: "removes the last non-representable `Cont`, and lets `Cont` be deleted outright"** | `zipWith`'s continuation uses `σ` essentially — `graft p (fun _ σ e => graft (sub q σ) …)` (`Plan.lean:442`) is how `q` is moved under `p`'s binders — so it is not "constant in `σ` up to `sub`". Deleting `Cont` means deleting `graft`, and `graft` is what `mapP`, `zipWith`, `seq`, `bindP`, `panel` and `revising` are all derived from (`Plan.lean:429–463`, `:595`, `:621`). The proposal would re-add six bespoke recursions to remove one type. `bindAt` as a *derived* primitive beside `graft` is fine and is verdict (i)#1; deleting `Cont` is not. |
| 5 | **A-§5.4 and C-§5.3: the frozen corpus pins `shapes` and `asks`** | It does not. `grep '"shapes"' test/corpus/*.json` returns nothing across all 128 vectors, and so does `"asks"`. The reply record is exactly `Observe.hs:88`'s eight keys: `level, size, askNodes, codes, costSummary{minFold,maxFold,paths}, blockAsks, fnAsks, worlds[]`. C is the worse offender because §5.3 says "Read one (`battery-007-…json`)" and then lists fields that file does not contain — it copied `connection.md` §3.1's *specified* record instead of the *frozen* one. B-§4.1 gets this right. |
| 6 | **C-§7.1: "`Plan.revising … ` becomes `Plan (c :: Γ) Verdict → Plan (c :: .verdict :: Γ) (El c) → …`"** | Context order reversed. `Check.lean:498` is `reviseCont (rev : Plan (.verdict :: c :: Γ) (El c))` and `Builder.hs:1021` is `Plan ('CodeVerdict ': c ': g) (El c)`. A-§4.1 has it right. In a proposal whose whole content is a de Bruijn bookkeeping iso, getting the de Bruijn order backwards is not a typo. |
| 7 | **C-§6.1: "Every author-written `Cont` in the repository ignores its `Sub` argument."** | False for the three that matter. `checkCont`, `reviseCont`, `finishCont` (`Check.lean:491`, `:498`, `:505`; `Builder.hs:1016`, `:1021`, `:1029`) all use `σ`, via `Plan.sub … (Env.cons … (σ δ))`. The true statement is *"every author-written `Cont` is `ofPlan` of a plan"*, which is stronger and is what the Yoneda argument needs. `Acceptance.check` (`Denote.lean:564`) drops `σ` only because its plan reads nothing from `Γ`. |
| 8 | **B-§0.3: "The hazard is not merely detected, it is **unstateable**" — billed as "the single biggest simplification"** | It is already unstateable. `PAsk c s e k` has `e :: Expr g Text` and `k :: Plan (c ': g) a` (`Plan.hs:505`), so evaluating the prompt under the extended environment does not typecheck *today*, in all three folds. What the profunctor form actually moves is the **trace order**: today it is fixed three times by three explicit `Event : recurse` clauses (`World.hs:347`, `Exec.hs:271`); after, it is fixed once, inside the `Monoidal (Star m)` instance's choice of `<*>` argument order — where swapping two arguments typechecks, is lawful, and silently reverses event order at *every* target at once. The refactor concentrates the hazard into a place that looks like an algebra law. That is a smaller and more dangerous change than advertised. |
| 9 | **B-§2.4: "delete the `Applying (Tally CostTree)` instance and a dynamic program fails to typecheck at that target. That is `no_cost_tree_at_dyn` as a type error rather than a theorem."** | A category error. `no_cost_tree_at_dyn` (`Cost.lean:926`) says *no finite-leaf tree exists* containing the bills of `unbounded` — a cardinality theorem about a semantic image. A missing instance says only that the author did not write one; B supplies it three paragraphs earlier (`applying = Tally (CostNode [])`, §1.4), and `Plan.hs:828` records the same choice as deliberate. Deleting an instance is not evidence it cannot be written soundly. B's own §2.5 half-admits this ("the *statement* becomes schematic while the *witness* stays a hand-built counterexample"); §2.4 should be withdrawn to match. |
| 10 | **B-§1.7's accounting ("≈ 92 added", "net −70") and B-§1.7's headline "adding a former costs three class methods instead of `5 × 9` clauses"** | The table omits the largest new item entirely: `Flow`'s own `Profunctor`, `Category`, `Strong`, `Monoidal`, `Branching` and `Applying` instances. Under B's own §0.4/§4.2 discipline these **must** be skeleton-preserving smart constructors, i.e. five-clause recursions over the GADT — `lmap` is today's `subP`, `>>>` is today's `graft`, and `first'`/`|*|` need an accumulator each or they are quadratic (a naive `first' (AskC c q k) = AskC c q (lmap assoc (first' k))` re-traverses the subtree at every binder). That is six to eight recursive folds where today there are two. So adding a former costs one clause in each of ~8 instances plus `interp` plus `size` ≈ 10 sites — the same nine it costs today. **§0.4 logically negates §1.7, and B never connects them.** |
| 11 | **B-§2.2: "the level lattice is the lattice of inferred contexts, ordered by entailment"** | Contradicted by B-§2.1 one page earlier, which correctly says batch→pipeline is a *handler* boundary and not a class boundary — so the bottom rung is not in the constraint lattice at all. And `Branching` does not have `Opens` as a superclass, so a term with a `case` and no `ask` infers the antichain `(Branching p, Puts p)`, which is not a point of a four-element chain. There is a collapsing map from inferred contexts to `Level`; there is no lattice isomorphism. |
| 12 | **B step 1 as a whole: re-index the Haskell core to `Flow x y`** | Not incorrect as a construction — the tuple encoding really does make `Cont` rank-1, and it even dissolves A's `Option (El c)` obstruction for free (`K x (El c) (Maybe (El c))` is an ordinary `Flow`, no representability needed). It is wrong as a *proposal*, for three compounding reasons: (a) its headline benefit is negated by its own constraint (#10); (b) its headline simplification is already true (#8); (c) it moves the Haskell term language off the Lean term language's indexing, which is verdict-level and is §6 below. |
| 13 | **The "full version" — monoids in `Prof`, Tambara modules, four free constructions, one meta-theorem** (A-§5, C-§4.2) | C already refutes it and I concur, with one addition C could have made: I confirmed in this checkout that `Mathlib/CategoryTheory/Profunctor/Basic.lean` lists *"Define composition of profunctors"* under **Future work** at line 25, `grep -rl Tambara Mathlib/` is empty, and `Limits/Types/End.lean` builds coends as `Quot`. The tower would have to be written from scratch, out of the exact material `Plan.case`'s `FinEnum` note (`Plan.lean:266–277`) exists to keep out of `Plan`'s type. |

---

## 2. The correspondence audit, in detail

Only the ones that need more than a table row.

### 2.1 The `Const`-crosses-`case` mechanism (A-§5.1(4b)) — the central error

A stakes the document on this sentence:

> **`level` survives `case` because `max` is idempotent and commutative; `billFresh`
> does not because `Multiplicative ℕ`'s product is neither.**

The second clause is true and the first is a non-explanation. `billFresh` does not
"survive `case`" because it is not an analysis of the *term* at all — it is a fold
of the *transcript* (`Cost.lean:166`), and a transcript belongs to a run. The
statement that has content is about a *static* analysis, and there the package
contains two counterexamples to A's "iff":

* `Plan.askNodes` (`Explain.lean:155`): `case` ↦ `Σ` arms, in `(ℕ,+)`, sound as an
  upper bound on `List.length (Plan.trace ω p γ)` at `level p ≤ branch`.
* `Plan.size` (`Explain.lean:140`): the same with a `1 +`.

Neither monoid is idempotent. What actually makes them sound is that the monoid is
**positively ordered** — `1 ≤ m` for every `m`, so `⟦arm t⟧ ≤ ∏_t ⟦arm t⟧` — and
monotone in each argument. A join-semilattice is the special case where the bound is
tight arm-by-arm. Stated correctly, the schema is:

> A `Const M` interpretation with `M` an ordered monoid over-approximates soundly
> across `case` iff the interpretation of the copair dominates each arm. `sup` and
> `∏`-in-a-positive-monoid both qualify; `∏` in a monoid with inverses does not.

That repair keeps everything A wants (`level` at `(Level, max)`, `shapes` exact at
`branch`-free fragments, `billFresh` failing) and stops asserting something the
repository refutes twice.

### 2.2 `Cont` as a right Kan extension (A-§4) — the one result that survives intact

A's §4.1 computation is correct and C's §6.1 compiles it. Three notes.

* The two documents agree on the shape and disagree on the de Bruijn order
  (verdict (iv)#6). `Check.lean:498` settles it: `.verdict :: c :: Γ`.
* A's framing — "`Plan (c :: Γ) B ↪ Cont Γ (El c) B` is a split mono whose image is
  the natural families" — is exactly `toPlan_ofPlan` (unconditional) plus
  `ofPlan_toPlan` (conditional on `Cont.Natural`), both compiled. Good.
* The *interesting* corollary neither document states: `Morphism.wobbly`
  (`Morphism.lean:310`) — the compiled non-natural `Cont` — is now classified rather
  than merely exhibited. `wobbly Δ _ _ = ticks Δ.length` reads the *length of the
  context it lands in*, which is precisely the data a natural family may not see.
  `sub_graft_not_natural` (`:324`) becomes "the presheaf `Δ ↦ Sub Γ Δ × Expr Δ A` has
  non-natural sections", which is worth one sentence in `Morphism.lean`'s docstring.

This is a Yoneda/representability result about context extension. It uses no
profunctor, no Tambara module, and no optic. That is not a criticism of the result;
it is the whole of §6.

### 2.3 The Haskell `interp` — where it is right, and where it is unwritten

I checked B's five `interp` clauses against every fold they replace.

* `level` at `Tally Level`: correct clause by clause against `Plan.hs:738`, including
  `AskC` contributing `⊥` and `Dyn` discarding its body. ✔
* `askNodes` at `Tally (Sum Integer)`: correct against `:767`. ✔
* `costTree` at `Tally CostTree`: correct against `:822`, and the `graft` monoid B
  gives (`CostLeaf n <> u = bumpBy n u`, `CostNode ts <> u = CostNode (map (<> u) ts)`,
  `mempty = CostLeaf 0`) is genuinely lawful — I checked associativity and both units
  by hand, including the `bumpBy n t <> u = bumpBy n (t <> u)` lemma the associativity
  case needs. ✔ `bump` really does become `CostLeaf 1 <> ·`. That is the nicest
  observation in document B.
* `codes` at `Partial (Tally [Code])`: correct, including `Nothing` at both `Case` and
  `Dyn` and left-to-right code order. ✔
* `revising` at twelve lines: I type-checked the four tuple shuffles (`settle`,
  `reassoc`, `forget`, `keep`) by hand and they are consistent. ✔ And `keep f = f |*| id`
  really is skeleton-preserving: `zipWithP f p (PRet id)` grafts a `PRet` into a `PRet`,
  adding no node.

What is **not** written anywhere in document B is the part the whole plan rests on:
the `Flow` instances themselves. §4.2 gives five illustrative clauses in a block quote
and calls them "line for line, today's `graft` and `subP`". They are not: `subP` and
`graft` are two functions; `lmap`, `rmap`, `>>>`, `id`, `pureP`, `|*|`, `first'`,
`second'`, `branching` and `applying` at `Flow` are ten, of which at least six must
recurse over five constructors. `first'` in particular has no obvious linear
definition that does not thread an accumulator — and the package has already been
bitten once by exactly this class of mistake (`Plan.lean:54–80`: eager `Sub.lift`
turned a `2n+2`-leaf tree into 122 s at `n = 24`). A document that proposes to make
`second'` the load-bearing operation and does not write it down has not priced itself.

### 2.4 The `Handler` / `PricesByShape` correspondence — right, and orthogonal

B-§1.3's observation is correct and is the best thing in the document:
`onOpen :: SCode c -> Shape c -> p Text (El c)` at `p = Tally s` has hom `s`, so the
`Text` is unreachable, so a `Tally`-valued handler prices by shape. That *is*
`PricesByShape` (`Cost.lean:142`).

But note what it buys: nothing, on the Lean side, without the whole `Flow` refactor —
because Lean has no `Tally` and no interpreter, and `PricesByShape` is a hypothesis on
a `Price S`, which is a function, not a target. The correct Lean-side statement is
C-§6.3's: the level hypothesis belongs to *totality*, not to *factorisation*. B's
insight is a good docstring for `Cost.lean:142` and is not an argument for `Flow`.

### 2.5 The `≈ᵖ` boundary, which A states and then crosses

A-§5.3(7) is the sharpest paragraph in the dossier:

> The meta-theorem is stated modulo `≈ᵖ`, but `Plan.size`, `Plan.askNodes`,
> `Plan.explain` and `paths` are **not** `≈ᵖ`-invariant. So the free-structure
> presentation can never replace the *term*.

Every "iso given" in A's §0 table crosses that line. `batch ≅ FreeA` reassociates the
final `Expr`; `pipeline ≅ Hom_Freyd` collapses `askC` into `ask` (`askC_coherent`);
`branch ≅ free distributive Freyd` would quotient by any `case` identity you care to
name. A knows this — §5.3(6) says "presenting `branch` with an idempotent choice …
changes a frozen number" and cites `battery-042` (`paths 2`, `minFold = maxFold = 3`;
I confirmed the file: `level branch`, `size 8`, `askNodes 5`). The document should
demote its §0 status column from "iso given" to "bijection modulo `≈ᵖ`" in three rows
and stop calling them isomorphisms.

---

## 3. Citation audit

Checked against what I know; where I am unsure I say so rather than guess.

**Materially wrong or inconsistent:**

1. **Pastro–Street, "Doubles for monoidal categories", TAC 21.** A cites `21(4):61–75`;
   B cites `21(6):61–75`. Same page range, different issue number — one of them is
   wrong and both flag "unsure of the issue". My recollection is **No. 4**, i.e. A is
   right, but I would check the TAC volume index before quoting either.
2. **Jacobs–Heunen–Hasuo title.** A writes *"Categorical semantics for arrows"*;
   B writes *"Categorical semantics of arrows"*. The published JFP title is
   *"Categorical semantics for arrows"* — B's is the slip. Trivial, but it is the
   citation both documents lean on for "arrows are monoids in profunctors".
3. **A-§2.1's attribution to LWY.** A asserts LWY's "own theorem — that **static**
   arrows, those whose effect does not depend on the input, correspond to idioms".
   The idiom↔static-arrow correspondence is indeed LWY's, but "static" in that paper
   is a technical condition on the arrow, not the informal "effect does not depend on
   the input" gloss, and I am **not confident** the gloss is the paper's definition.
   Since this is the sentence that identifies `batch`, it should be checked against the
   printed proceedings before it goes into a docstring.
4. **Tambara.** Both documents flag the reference as uncertain, correctly. I cannot
   confirm the title *"Distributed modules over a monoidal category"* or the year; the
   optics literature's standard pointer is via Pastro–Street. Cite Pastro–Street and
   say "the notion is named for Tambara" without a bibliographic entry, or check it.
5. **C's Mathlib attributions.** I verified these in this checkout:
   `Mathlib/CategoryTheory/Profunctor/Basic.lean` has authors *Dagur Asgeirsson, Adam
   Topaz, Adrian Marti*, `abbrev Profunctor := C ⥤ Dᵒᵖ ⥤ Type w` at line 54, and
   *"Define composition of profunctors."* under **Future work** at line 25.
   `TypeCat.Hom` is a one-field structure at `Types/Basic.lean:88` with
   `ofHom` at `:134`. `grep -rl Tambara` is empty; `Monoidal/DayConvolution.lean`
   exists. **All of C's §3 claims that I could check are accurate.** This is the only
   part of the dossier whose empirical claims I found uniformly correct.

**Checked and fine:** Hughes SCP 37(1–3):67–111 (2000); Paterson ICFP 2001 229–240;
Capriotti–Kaposi MSFP 2014 / EPTCS 153:2–30; Rivas–Jaskelioff JFP 27 e21 (2017);
Heunen–Jacobs MFPS 2006 / ENTCS 158:219–236; Atkey ENTCS 229(5):19–37;
Power–Robinson MSCS 7(5):453–468 (1997); Power–Thielecke ICALP 1999 LNCS 1644:625–634;
Day LNM 137:1–38 (1970); Mac Lane CWM Ch. X (Kan extensions); Wadler FPCA 1989 347–359;
Rutten TCS 249(1):3–80 (2000); Joyal–Street–Verity MPCPS 119(3):447–468 (1996);
Hasegawa TLCA 1997 LNCS 1210:196–213; Mokhov et al. PACMPL 3(ICFP):90 (2019);
Mokhov–Mitchell–Peyton Jones PACMPL 2(ICFP):79 (2018) + JFP 30 e11 (2020);
Altenkirch–Chapman–Uustalu LMCS 11(1:3) (2015); Fiore–Plotkin–Turi LICS 1999;
Levy–Power–Thielecke Inf. Comput. 185(2):182–210 (2003); Pickering–Gibbons–Wu
Programming 1(2):7 (2017); Boisseau–Gibbons PACMPL 2(ICFP):84 (2018);
Kiselyov LNCS 7470:130–174 (2012); Gibbons–Wu ICFP 2014 339–347;
Allais et al. ICFP 2018 / JFP 31 e22 (2021).

**Best citation in the dossier, and it is C's:** Allais, Atkey, Chapman, McBride,
McKinna, *A type- and scope-safe universe of syntaxes with binding* — "N bespoke
traversals become one generic semantics", formalised, in exactly this setting. That
is the actual prior art for the only structural proposal that survives, and it is not
a profunctor paper.

---

## 4. The conformance audit

### 4.1 What is actually pinned

Three surfaces, not one, and no document lists all three.

| surface | pinned by | contents |
|---|---|---|
| the 128 frozen vectors | `test/corpus/*.json`, produced by `Observe.hs:88` | `level`, `size`, `askNodes`, `codes`, `costSummary{minFold,maxFold,paths}`, `blockAsks`, `fnAsks`, `worlds[{world,trace[Event],billFresh,billMemo}]`, **plus the printed `RawProgram` after `zeroPos`** |
| the CLI rendering | `test/CliSmoke.lean:181` | `Explain.planLines Dsl.flagshipPlan ++ Explain.revisionLines Dsl.flagshipRaw`, byte for byte |
| the Lean `#guard_msgs` | `Certify.lean` (per C-§5.1) | `certify_sound` axiom-freedom, unreachable from any of this |

**`shapes` and `asks` are not pinned by anything.** A-§5.4 and C-§5.3 both say they
are; `grep` says otherwise (verdict (iv)#5). This *loosens* the constraint — it means
`shapes`/`asks` may be reorganised freely — but it also means the two documents that
claim to have checked the corpus did not open it.

**`Explain.planLines` is pinned and no document mentions it.** It prints, per node:
`askC` vs `ask` as *distinct* keywords, the shape line, `binds #{Γ.length}`, the
prompt evaluated at `Env.probe Γ`, and for a `case` the literal
`{ts.length} arms, in the enumeration order of the tag type the term carries`
(`Explain.lean:230–243`, `:402`). Consequences:

* Any presentation that identifies `askC` with `ask` (A-§2.3's Freyd collapse) changes
  the CLI output even where it preserves every corpus number.
* Closing the `case` tag universe (A-§2.6, "corpus impact: none") must reproduce
  `FinEnum.toList` order *and* `ts.length`, or `CliSmoke` fails.
* `binds #{Γ.length}` is a function of `Ctx` being a `List Code`. A `Type`-indexed
  `Flow` has no `Γ.length`. This is harmless for B (Haskell has no `explain`) and
  fatal for any attempt to carry B's reindexing back to Lean.

### 4.2 Quiet observation changes, by proposal

| proposal | moves | acknowledged? |
|---|---|---|
| A-§4.2 / C-§7.1 fuse `revising` + `case` | `size`, `costSummary.paths`, `planLines` | `size`/`paths` yes; `planLines` **no** |
| A-§2.6 / C-§5.2(2) close the tag universe | `planLines` (arm count + order) | A says "none"; **C flags it** |
| C-§7.2(3) `CostTree` → `Multiset` | `costSummary` triple (argued invariant, uncompiled) | flagged ⚠️ |
| C-L3 replacing (not adding) fold bodies | nothing observationally — but `by decide` / `by rfl` / `decide +kernel` reduction cost | **no** |
| B step 1 with a leaky smart constructor | `size`, `askNodes`, `costSummary` on every entry | yes, §0.4 — and correctly named as unenforceable |
| B-§4.3's five listed non-proposals | as tabulated | yes, and the table is good |
| B-§3.2 lens handles | nothing at the wire, provided names move type→value | yes, §3.3 last paragraph, and it is the right answer |

One row B gets exactly right and deserves credit for: **"Dropping `PDyn` because the
builder cannot make one … Do not."** `Plan.hs:828` and `Cost.lean:871` are the two
ends of the same witness, and deleting the Haskell end would leave
`no_finite_bill_set_at_dyn` with no counterpart.

### 4.3 The corpus cannot police what these proposals move

`connection.md` D6 gives two tiers: 128 frozen vectors, and live differential
generation. Both drive the **typed builder**. The builder cannot construct a `PDyn`
(`Plan.hs` docstring at `:502`; `Check.lean:55` records that no clause emits
`Plan.dyn`), cannot construct a non-representable `Cont` other than `finishCont`, and
emits exactly two tag types. So the fragment where a Haskell `Flow` core and a Lean
`Plan` core would first disagree — `dyn`, arbitrary `Cont`s, tags beyond `Bool`/`VTag`
— is precisely the fragment neither tier reaches. That is not a defect of the harness;
it is what makes the *transliteration invariant* load-bearing, and §6 is about spending
it.

---

## 5. Costs the documents undersold

### 5.1 GHC

* **The smart-constructor discipline is unenforceable and unwritten** (verdict
  (iv)#10). B's mitigation — a property test `size (f >>> Ret id) == size f` — catches
  unit-law leaks and *not* the failure mode that matters, which is a contributor adding
  a `Comp` former. The only real enforcement is a module boundary that hides `Flow`'s
  constructors, which B does not propose and which would break `size` (a fold over the
  constructors) unless `size` lives inside that boundary too.
* **Rank-2 is not deleted, it is moved.** `Handler p`'s two fields are
  `forall (c :: Code). …`, so `RankNTypes` stays, `Handler` values need signatures, and
  `interp`'s `Handler p -> Flow x y -> p x y` cannot be partially applied and inferred.
  The claim "rank-2 quantification **deleted**" (§1.1 dictionary) is true only of `Cont`.
* **`Envs` non-injectivity, carried one step further than B carries it.** B correctly
  spots the `Res` injectivity trap (§3.1) and correctly prescribes keeping the `Scope`
  index. It does not notice that `(>>>)`'s middle type is existential
  (`p x z -> p z y -> p x y`), so at every builder composition site GHC must determine
  `z` from context; today `graft :: Plan g a -> Cont g a b -> Plan g b` determines `a`
  from the first argument's type. Every `>>>` in `Builder.hs` will need either an
  annotation or a helper with a monomorphic middle.
* **Error quality.** B's own §3.3 table concedes the environment prints as a nested
  tuple and is "worse to read". With `Flow` in the core that nesting appears in *term*
  errors too, not only in handle errors — a mis-scoped statement in a 20-binding block
  reports a 20-deep tuple mismatch.
* **`Control.Category.id` vs `Prelude.id`.** Pervasive `NoImplicitPrelude`-style import
  hygiene across `Plan.hs`, `Builder.hs`, `Exec.hs`, `World.hs`. Small, real, unpriced.

### 5.2 Lean

* **Kernel reduction, not elaboration time, is the cliff.** C prices the loop
  (`DslFlagship` 249 s) and not the thing that would actually break: `level_upToTwice`
  is `by decide` (`Level.lean:332`), `trace_upToTwice_stubborn` and
  `run_upToTwice_stubborn` are `by rfl` (`Denote.lean:598`, `:604`),
  `bill_constBranch` is `rfl` (`Cost.lean:824`), `one_mem_leaves_constBranch` is
  `by decide`, and the flagship carries nineteen `decide +kernel` proofs. Routing
  `level`/`size`/`askNodes` through `PlanAlg.fold` puts `Plan.brecOn` and a structure
  projection between the kernel and every one of those. Adopt L2/L3 **additively**
  (verdict (i)#5) and treat replacement as verdict (ii)#4 gated on a timing diff.
* **`simp` normal forms.** `level_ret`/`level_askC`/`level_ask`/`level_case`/`level_dyn`
  are `@[simp]` and `rfl` (`Level.lean:129–142`); every `simp only [level_ask]` in
  `Cost.lean` and `Level.lean` depends on the direct definition. Replacing the
  definition means re-deriving and re-`@[simp]`-ing the equation lemmas and auditing
  every `simpa`. C's "mechanical but wide" for L3 is the right adjective and the wrong
  magnitude.
* **`test/Pollution.lean`.** C gets this right (`scoped`, or not at all) and it is worth
  restating: a `Category Ctx` instance is a claim about `List Code` imposed on every
  transitive importer, and `Agentic/Meaning.lean` already records the two-instances-is-an-ambiguity
  trap.
* **What C does *not* undersell:** the axiom footprint (I re-ran it), the Mathlib
  inventory (I re-checked it), and the `FintypeCat` hazard. Those three sections are
  the model for how the rest of the dossier should have been written.

### 5.3 Two cores

**Is the proposal one core or two?** As it stands: **two, and the documents do not
notice that they disagree with each other about which one.**

* A and C keep `Plan Γ A`, `Ctx = List Code`, `Env`, `Var`, `Sub`, `Cont`, and add a
  Yoneda collapse plus an algebra layer. `Cont` at a non-representable `A` —
  `finishCont : Cont Γ (Option (El c)) Unit` — is the residual obstruction, and A
  proposes a **spec regeneration** to remove it.
* B replaces the Haskell core with `Flow x y`, `Type`-indexed, environments as nested
  tuples. Under that encoding the `Option (El c)` obstruction **does not exist**:
  `finishCont` is `Flow (Maybe (El c), x) ()`, an ordinary arrow, no representability
  required. B's `revising` returns `K x (El c) (Maybe (El c))` without comment.

So A's most expensive proposal — the only one that requires regenerating the frozen
corpus — is *unnecessary* under B's encoding, and B's encoding is *unavailable* in
Lean without abandoning `Ctx`-indexing, `Var`, `Env.probe`, and `binds #{Γ.length}`.
Neither document cites the other on this point. Whoever adopts both gets a Lean core
indexed by contexts and a Haskell core indexed by types, connected by 128 JSON files
and a generator that cannot reach `dyn`.

`connection.md` D1/D5 chose reimplementation-plus-conformance knowingly, and the
mitigation it relies on is visible on every page of `Plan.hs`: the docstrings quote
Lean line numbers constructor for constructor (`"The five formers of
Agentic/Core/Plan.lean:238"`, `"Lean's @FinEnum.toList@, in Lean's order"`,
`"@Plan.graft@ (@Agentic/Core/Plan.lean:421@)"`, `"that is the position where Lean has
@absurd@"`). That transliteration invariant is what a reviewer uses to check agreement
**outside** the corpus's reach. B's step 1 spends it: after the rewrite there is no
`Env`, no `Var`, no `Sub`, no `Cont`, no `graft` on the Haskell side to line up
against, and nine folds become nine instances of a recursion Lean does not have.
B lists what step 1 does *not* touch and never lists this.

---

## 6. The single strongest objection

**There is no profunctor content in the surviving program.**

Take the three documents, delete everything refuted above, and delete everything that
is a new name for an old `rfl`. What is left that is both true and load-bearing is
three things:

1. `Cont Γ (El c) B ≅ Plan (c :: Γ) B` on natural families — a **Yoneda /
   representability** fact about context extension, which I watched compile from
   `Env.cons_head_tail` and `sub_id` and nothing else;
2. `Plan` has an initial-algebra fold and the twelve structural recursions are its
   instances — **Allais et al.**, and C says so;
3. the analyses are interpretations into ordered monoids, and the rung boundary is an
   order-theoretic condition on the target — **§2.1 above**, once A's idempotence claim
   is corrected.

None of the three is a profunctor theorem. Meanwhile every genuinely
profunctor-specific object proposed is disposed of by the dossier itself: Tambara
modules and profunctor composition are priced at 3,000–6,000 Lean lines for zero
theorems and are absent from Mathlib (I confirmed the header, the empty `Tambara`
grep, and the `Quot`-based coend); optics on `revising` fail all three laws in all
three documents; `Sub.lift = second'` is `id × −` at `(->)`; handles-as-lenses reduces
to "carry the name in the value", which the `I`-suffixed API already does without a
`Strong` constraint anywhere.

That leaves exactly one place where a *profunctor representation* would earn
something real: document B's `Flow x y`, where the rank-2 `Cont` genuinely becomes
rank-1 and A's `Option (El c)` obstruction genuinely evaporates. And that payment is
made in the wrong currency. It re-indexes the Haskell core off the Lean core, in a
repository whose entire correctness architecture is "Lean is normative, Haskell is a
transliteration, the corpus catches the rest" — where the corpus provably cannot reach
`dyn`, cannot reach arbitrary continuations, and cannot reach tags beyond `Bool` and
`VTag`, which is the exact list of places two cores diverge first. B's own §0.4 then
concedes that the discipline required to keep the corpus green forces every class
method back into a five-clause recursion, which is the modularity the refactor was
for.

So the honest summary of the whole program is: **its best result is a Yoneda lemma and
a fold; its profunctor framing is decoration on the first and a licence to break the
two-implementation invariant on the second.** Adopt items (i)1–5 — they are compiled,
additive, and would have been found by asking "is `Cont` representable?" and "is this
a fold?" without opening a single optics paper. Everything that needed the profunctor
vocabulary to be *stated* also needs a spec regeneration to be *adopted*, and nothing
in the dossier argues that the resulting theorems are worth the regenerated corpus.

---

## 7. Two things the documents got right that this attack should not obscure

1. **All three independently refute the seed's two headline claims** — `revising` is
   not a lens, and "`Const` is monoidal but not compositional, hence cost dies at
   `dyn`" is wrong — and all three refute them from the sources rather than from
   taste. A and C additionally converge, independently, on the `Cont`–Yoneda collapse
   as the highest-value item, which is the strongest corroboration in the dossier.
2. **Document C is the one that behaved like an engineering document.** It compiled
   its claims, printed its axioms, read Mathlib in the checkout instead of from memory,
   priced the version it recommends *against*, and told the owner not to start with the
   expensive item. Its errors (the corpus record, the de Bruijn order, the "ignores its
   `Sub`" sentence, the additive/replacing inconsistency) are all in the prose around
   the compiled core, not in the core. That is the right failure distribution.
