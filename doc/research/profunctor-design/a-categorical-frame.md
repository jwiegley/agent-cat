# A categorical frame for agent-cat

*The mathematics, made exact. Every claim below is checked against
`Agentic/Core/{Plan,Denote,Level,Cost,Explain,Question,Dlg}.lean` and
`haskell/src/Agentic/{Plan,Builder,Workflow,Exec}.hs` as they stand. Where I
assert an equivalence I give the iso; where I only conjecture one I say so.
Where a citation may be off in volume or page I say that too.*

---

## 0. What this establishes, in one table

| Package object | Exact categorical identity | Status |
|---|---|---|
| `batch` fragment | free applicative (Capriotti–Kaposi normal form) over the container `(Σc. Q c) ◁ El`, at the reader `Expr Γ (−)` | iso given (§2.2) |
| `pipeline` fragment | hom-set of the **free Freyd category** over `Set` on the signature `{ask_{c,s} : String ⇝ El c}`; equivalently arrow-calculus normal forms | iso given (§2.3) |
| `askC` vs `ask` | generator **arity**: nullary vs unary. This is the whole content of kernel open question 3 | proved (§2.4) |
| `case` at `FinEnum T` | finite `ArrowChoice` = n-ary copair after the `Set` distributive law `X × T ≅ Σ_{t:T} X`; `FinEnum` is the *chosen* decomposition | proved (§2.5) |
| `dyn` | `ArrowApply`, hence Kleisli of a monad (Hughes); the `Type 1` residence is the price of the internal hom | proved (§2.6) |
| `Sub.lift` | `second'` — the Tambara/`Strong` structure map at `El c`; `wk_lift` is its naturality square | proved (§3.3) |
| `Cont Γ A B` | right Kan extension of the presheaf `Plan(−) B` along `E ↪ Set`, evaluated at `Env Γ × A`; **representable at `A = El c`** | iso given (§4) |
| `Plan.Denotes` | the Yoneda naturality condition; deletable | proved (§4.2) |
| `Q c ≅ Q.Shape c × String` | a constant-complement **lens**, laws = the three `rfl`s; `Sig` is its complement action | proved (§3.2) |
| `panel` | monoid object transported by a lax monoidal functor; `foldMap` in the induced monoid | proved (§3.4) |
| `zipWith` order + `trace_panel_perm` | **premonoidal** tensor + the exact failure of centrality (Power–Robinson) | proved (§3.4) |
| `shapes` | the *universal* `Const`-monoid interpretation of the free arrow | proved (§2.3, §5) |
| `PricesByShape` | not a hypothesis about terms: it is object-blindness of a `Const M` target | proved (§5) |
| `CostTree` | free **finite-family** (coproduct-with-multiplicity) completion of `Const M`; `bill_mem_leaves` is its unit; `minFold`/`maxFold` are tropical semiring homs | proved (§5) |
| `revising` | **Moore coalgebra `S → V × S` unrolled `n+1` times**, not a lens | refutation (§3.1) |

The one seed claim that is **wrong**: `revising` is not a lens (§3.1). The one
mechanism inside seed 1 that is **wrong and needs replacing**: "`Const`/`Forget`
is monoidal but not compositional, hence cost dies at `dyn`" — `Const M` is a
lawful `Arrow` *and* `ArrowChoice` *and* (vacuously) `ArrowApply`; what fails is
not structure but **ω-soundness**, and the exact condition is that `Const M`
survives `case` iff `M` is a join-semilattice (§5.1(c)). That is why `level`
lives at every rung and `billFresh` does not.

---

## 1. The categories, fixed

Nothing below is meaningful until three categories are pinned, because the
package's `Sub` is *semantic* and that changes which category we are in.

### 1.1 `E`, `Ctx`, `Sub`

`Env : Ctx → Type` (`Plan.lean:81`) is the product functor on a list of codes.
`Sub Γ Δ := Expr Δ (Env Γ) = Env Δ → Env Γ` (`Plan.lean:169`). So:

> **Definition.** Let `E ⊆ Type` be the full subcategory spanned by the objects
> `{Env Γ | Γ : Ctx}`. Then the package's category of contexts is `Ctx = E^op`,
> with `Hom_Ctx(Γ,Δ) = Hom_E(Env Δ, Env Γ) = Sub Γ Δ`, and `comp_assoc`,
> `id_comp`, `comp_id` (`Plan.lean:194–201`, all `rfl`) are its category laws.

Two consequences that the docstrings state informally and that matter later.

* **The base is cartesian and full.** Because `Sub` is *any* function on
  environments, weakening, exchange, contraction and genuine substitution are
  all inhabitants of one type (`Plan.lean:161–169`), and every pure map between
  environment types is available. This is exactly the precondition for a total
  `arr : (X → Y) → (X ⇝ Y)` in the arrow reading, and it is why `denote_sub` is
  one line: reading a plan in another context is *precomposing its meaning*.
* **`E` is not skeletal.** `Env [ack] ≅ Env [] ≅ Unit`, and `Env [ack,ack] ≅
  Unit`. So `Env` is not injective on objects and `Ctx` is not the free
  cartesian category on `Code`; the package deliberately works with the image in
  `Set`. Any claim of the form "`Plan` is the free X on `Code`" must therefore
  be stated relative to `E`, not to a syntactic context category. This is a
  real difference from the standard well-scoped-syntax presentation, and it is
  what buys the one-line substitution lemma.

`Γ ↦ Plan Γ A` is a functor `Ctx → Type 1` (equivalently a presheaf on `E`):
`sub_id` and `sub_comp` (`Plan.lean:319`, `:328`) *are* the two functor laws.
`A ↦ Plan Γ A` is also a functor, with `mapP` as the action; `mapP id = id`
holds definitionally in Lean by η (the `ret` clause becomes `.ret (fun δ => e δ)`
and the continuation of `graft` is unchanged under binders), but the package does
not state it. It should, because §4 needs it.

### 1.2 The signature Σ, and its two halves

Both `ask` formers are generators of one signature, but with different arities,
and that difference is the entire level lattice below `branch`:

```
Σ_batch = { g_{c,q} :  1      ⇝ El c   |  c : Code,  q : Q c        }   -- askC
Σ_pipe  = { g_{c,s} :  String ⇝ El c   |  c : Code,  s : Q.Shape c  }   -- ask
```

`Σ_pipe`'s label set is exactly `Cost.Shape = (c : Code) × Q.Shape c`
(`Cost.lean:101`), and `Σ_batch`'s is exactly `Cost.Key = (c : Code) × Q c`
(`Cost.lean:90`). The generating profunctor of `Σ_pipe` is

```
G(X,Y) = Σ (c : Code) (s : Q.Shape c). (X ≅ String) × (Y ≅ El c),
```

a profunctor *concentrated at the two objects* `String` and `El c`. That answers
the question in the brief — "is the prompt-only dependence a Tambara module over
a smaller category?" — as follows: the **module** is over the full cartesian base
`Set` (nothing is restricted there, because `Sub` is semantic), and the
**generator** is what is small: supported on a set of homs indexed by `Shape`.
The two are different restrictions and only the second is present.

`Q c ≅ Q.Shape c × String` (`Question.lean:301–321`, three `rfl`s) is the
factorization that makes the generator's *label* and *argument* separable. It is
a lens, and §3.2 argues it is the load-bearing optic in the design.

### 1.3 `Plan` as a profunctor: what is true, and what it costs

Seed 3's "`Plan Γ A` is a profunctor `Ctxᵒᵖ × Type → Type`" is true and is worth
exactly one sentence: `Plan` is a `Type`-enriched bimodule `Type ⇸ Ctx`,
contravariant in `Γ` via `sub`, covariant in `A` via `mapP`. It is *not* an
endoprofunctor on one category, so profunctor composition `⊙` is not immediately
available on it and none of the optics machinery applies to `Plan` directly.

The useful reading is the other one, and it is a theorem rather than a
restatement:

> **`Plan` at the pipeline rung is a hom-set of a Freyd category, and `graft` is
> composition in it.** Composition there is `∫^A Plan Γ A × Cont Γ A B`, a coend
> over the *answer* type, with the context threading supplied by the Tambara
> strength (`Sub`, `sub`). Seed 3's "the Builder's graft/weaken machinery is its
> composition" is correct with that correction: the coend is over answers, and
> the weakening is the strength, not the composition.

---

## 2. Seed 1, made exact

### 2.1 The headline, corrected

Seed 1 says the lattice *is* the idiom/arrow/monad hierarchy. It is a chain in
that hierarchy, but a four-element one, and three of the four rungs are arrows:

```
batch      ≅  Applicative        =  static (oblivious) arrow      -- nullary generators
pipeline   ≅  Arrow              =  meticulous                    -- unary generators
branch     ≅  ArrowChoice        =  + finite coproducts
dynamic    ≅  ArrowApply ≅ Monad =  promiscuous                    -- Hughes 2000
```

Lindley–Wadler–Yallop's slogan (*Idioms are oblivious, arrows are meticulous,
monads are promiscuous*, MSFP 2008) is the right frame, and their own theorem —
that **static** arrows, those whose effect does not depend on the input,
correspond to idioms — is what identifies `batch`. `ArrowChoice` is inserted
between meticulous and promiscuous; that rung has no slogan in LWY, and
`Selective` (Mokhov et al., ICFP 2019) is the applicative-side analogue rather
than the same thing, because `pipeline` already needs strictly more than
applicative. The Lean docstring's "`Selective.branch`" (`Plan.lean:263`) is
therefore a good *intuition* and a bad *identification*: selective functors
build on `Applicative`, and `case`'s arms sit over a context that earlier `ask`
prompts have already read. What genuinely transfers from Mokhov et al. is their
over-/under-approximation discipline, which is exactly the
`bill_mem_leaves` / `minFold_not_attained` pair (§5.3).

### 2.2 `batch` = free applicative, with the iso

A `batch` term is, by `level`'s clauses (`Level.lean:120`; `level (askC c q k) =
level k`, no join), exactly

```
askC c₁ q₁ (askC c₂ q₂ (… (askC cₙ qₙ (ret e)) …)),   e : Expr (cₙ :: … :: c₁ :: Γ) A.
```

Let `F X = Σ (c : Code) (q : Q c). (El c → X)` — the polynomial functor of the
container `(Σc. Q c) ◁ El`. Capriotti–Kaposi's normal form for the free
applicative (MSFP 2014) is `FreeA F A ≅ Σ n. F X₁ × ⋯ × F Xₙ × (X₁ × ⋯ × Xₙ → A)`.
Then:

> **Proposition (batch).** `{p : Plan Γ A | level p = batch} ≅ FreeA F (Expr Γ A)`,
> an isomorphism of applicative functors in `A`, carrying `Plan.zipWith ↦ liftA2`
> and `Plan.ret ↦ pure`. The question list is the shape component; the final
> `Expr` is the pure combining function, uncurried through
> `Env (cₙ::…::c₁::Γ) ≅ El cₙ × ⋯ × El c₁ × Env Γ` (de Bruijn order reverses the
> asking order, which is the only bookkeeping in the proof).

Not currently stated in Lean; the induction is routine and `level_zipWith_le`
(`Level.lean:283`) already says the fragment is closed under `liftA2`.

What this buys immediately: `Const M` is applicative for any monoid `M`, so a
*unique* applicative morphism `FreeA F → Const M` exists for every function
`Σc. Q c → M`. That morphism is `billOfKeys price ∘ asks`, and
`bill_exact_batch` (`Cost.lean:425`) is its uniqueness. Note the hypothesis
count: **none on the price**, exactly as the theorem states — and §2.4 says why.

### 2.3 `pipeline` = the free Freyd category, with the iso

Add `ask c s e k`, with `s : Q.Shape c` term-level data and `e : Expr Γ String`
an expression. For a list `L = [(c₁,s₁),…,(cₙ,sₙ)] : List Shape`, write
`L_{<i}` for its first `i−1` entries and `Env_L` for the corresponding product.
Then a `pipeline` term is exactly

```
Σ (L : List Shape).  (∏_{i≤n} (Env_{L_{<i}} × Env Γ → String))  ×  (Env_L × Env Γ → A)
```

— a static list of generator labels, a prompt function per step reading
everything bound so far, and a final pure map. In arrow-calculus syntax
(Lindley–Wadler–Yallop, JFP 2010) that is precisely the normal form

```
let x₁ ⇐ ask_{s₁} • e₁ in  …  let xₙ ⇐ ask_{sₙ} • eₙ in  [e]
```

with every `e_i` a *pure* term over `Γ, x₁…x_{i−1}`. Hence:

> **Proposition (pipeline).** Let `Freyd(Σ_pipe)` be the free Freyd category over
> the cartesian base `E` on the signature `Σ_pipe`. Then
> `{p : Plan Γ A | level p ≤ pipeline} ≅ Hom_{Freyd(Σ_pipe)}(Env Γ, A)`,
> with `graft ↦ composition`, `sub p σ ↦ (arr σ) >>> p`, `zipWith ↦ the
> premonoidal product followed by `arr f`, and `ask c s e k ↦ arr ⟨id, e⟩ >>>
> second' g_{c,s} >>> k`.

Equivalently, in Rivas–Jaskelioff's vocabulary (*Notions of computation as
monoids*, JFP 2017 — I am confident of the journal, less so of the volume/e-number),
`pipeline` is the free monoid on `G` in the category of **Tambara modules**
(`Strong` profunctors) under profunctor composition. Both readings are correct
and they are the same object; the Freyd reading is the one to state, for the
reason Atkey gives (*What is a categorical model of arrows?*, MSFP 2008): the
naive "monoid in profunctors" characterization needs care about `arr` and
`first`, and the Freyd formulation carries the cartesian base explicitly — which
is the very thing `Sub`-as-a-function makes true here.

Three checks against the actual theorems.

1. **`shapes` is the universal `Const`-monoid interpretation.** `Const M` at a
   monoid `M` is a `Strong` profunctor monoid (`>>>` = `·`, `arr _` = `1`,
   `first' = id`). By initiality, an interpretation is determined by a function
   `Shape → M`. The *free* such `M` is `FreeMonoid Shape = List Shape`, and the
   induced homomorphism is literally `Cost.shapes` (`Cost.lean:321`). This is
   why `shapes_eq_trace_of_le_pipeline` (`:511`) **carries no hypothesis beyond
   the level bound**: it is initiality, and initiality never needs a
   factorization condition.
2. **`PricesByShape` is object-blindness.** A `Const M` target cannot see the
   `String` flowing through `g_{c,s}` — a constant profunctor has no argument
   position. So an interpretation into `Const M` *is* a function of the
   generator label, i.e. of the shape, i.e. `PricesByShape`
   (`Cost.lean:142`). `bill_exact_pipeline` (`:596`) is then the unique
   factorization `List Shape → M`, and the "one hypothesis that is left" the
   docstring names is not a residual assumption about terms at all — it is the
   statement that the target is a `Const`.
3. **`codes`, `length`, `askNodes` are monoid morphisms out of `shapes`.**
   `codes = Option.map (List.map Shape.code) ∘ shapes` (compare `Cost.lean:304`
   with `:321`); `length_trace_eq_of_le_pipeline` is `List.length`;
   `Plan.length_trace_eq_askNodes` (`Explain.lean:171`) is
   `askNodes = length ∘ shapes` at this rung; `Plan.size_eq_askNodes_succ` is
   that plus one. Each is currently proved by its own structural induction.

The one pipeline-level analysis that is **not** in this picture is
`Cost.asks` (`:336`): it evaluates prompts at `default`, so it is not an
interpretation of the free structure but a *semantic probe* — and
`asks_eq_default` (`:574`) says exactly that (`asks p γ = trace ωDefault`).
Reclassifying `asks` as "the semantics at a chosen world" rather than "a static
analysis" is a small honesty gain.

### 2.4 The `askC`/`ask` split: generator arity — and kernel open question 3

The brief asks which structure the shape/prompt split corresponds to. Answer:
**generator arity, and hence the size of the label set a `Const` target may
read.**

* `askC`'s generators are nullary: `1 ⇝ El c`, labelled by the whole question
  `q : Q c`. A `Const M` interpretation may therefore be *any* function of the
  full question, prompt text included.
* `ask`'s generators are unary: `String ⇝ El c`, labelled by `s : Q.Shape c`
  only. A `Const M` interpretation cannot read the argument, so it is a function
  of the shape.

That is the complete answer to the kernel's open question 3, which
`Cost.lean:424` poses as "the only guarantee `batch` has over `pipeline`":

> **The guarantee `batch` has over `pipeline` is that its generators are
> constants, so content-dependent pricing is a legitimate `Const M`
> interpretation there and nowhere above.**

And `askC_coherent` (`Denote.lean:151`) is precisely the inclusion of the
nullary generators into the unary ones by constant application,
`g_{c,q} = g_{c,q.shape} ∘ arr (const q.prompt)` — which is why the redundancy
is *deliberate* (the meaning coincides; the label set does not). LWY's
"oblivious/meticulous" distinction is this and nothing else.

### 2.5 `branch` = finite distributive choice; and what `FinEnum` really is

`case e arms` has `e : Expr Γ T`, `arms : T → Plan Γ A`, and **both arms see the
same `Γ`** — the payload rides in the environment, not in a coproduct
(`Plan.lean:494`, `VTag`'s docstring). With `T` finite the `Set` distributive
law gives `Env Γ × T ≅ Σ_{t:T} Env Γ`, so

```
case e arms  =  arr ⟨id, e⟩ >>> dist >>> (⊔_{t : T} arms t)
```

i.e. an n-ary `|||`. So `branch` is the free **distributive** Freyd category —
finite coproducts in the base, `Choice`/cocartesian structure on the arrow. Seed
1's "branch adds Choice/cocartesian structure" is correct; the refinement is that
cartesianness of the base is what supplies the distributive law that turns
"scrutinee plus shared environment" into a genuine coproduct.

Two things follow that the axiom-hygiene argument for `FinEnum` over `Fintype`
(`Plan.lean:266–277`) does not mention, and that are worth recording:

* `FinEnum T` is a **chosen** iso `T ≅ Fin n`, i.e. a chosen finite coproduct
  decomposition. `Fintype` would give the coproduct without the choice.
* That choice is *observable*: `Explain.finEnum_toList_bool`,
  `finEnum_toList_vtag` (`Explain.lean:96`, `:100`) pin arm order for the
  renderer, and `CostTree.leaves` is a `Multiset` — so `paths` counts leaves
  **with multiplicity** (`Explain.costSummary`, `Explain.lean:445`; the Haskell
  note at `Plan.hs:850` records `battery-042` with `paths 2` and
  `minFold = maxFold = 3`). Any categorical presentation that quotients by
  idempotence — e.g. "the free semilattice" — changes a byte-pinned number. The
  correct universal object is the free **finite-family** completion, multiplicity
  and all (§5).

### 2.6 `dynamic` = `ArrowApply`, and the universe bump

`dyn e f : Expr Γ B → (B → Plan Γ A) → Plan Γ A` with `B : Type` arbitrary
(`Plan.lean:285`). This is `app` at every `B`: `bindP` is exactly
`graft p (fun _ σ e => dyn e (fun a => sub (k a) σ))` (`Plan.lean:462`), and by
Hughes's theorem (*Generalising monads to arrows*, SCP 2000) an arrow with `app`
is the Kleisli category of a monad. So `dyn` = `ArrowApply` = `Monad`, and the
package's "the only derived form that needs `dyn` is `bindP`" is the arrow-side
statement of that theorem.

A consequence the package pays for and does not name: **`Plan : Ctx → Type →
Type 1` because the internal hom of an `ArrowApply` is a large object.** The
docstring attributes the universe to `case` and `dyn` quantifying over `Type`
(`Plan.lean:237`), which is the same fact seen syntactically. Note that the
Haskell port has already restricted the coproduct decomposition to a closed
universe — `data Tag t where TBool :: Tag Bool; TVTag :: Tag VTag`
(`Plan.hs:468`) — precisely because the elaborator emits only those two
(`Check.lean`'s three `case` sites). Restricting Lean's `case` tag to a `Code`-like
inductive and `dyn`'s `B` likewise would put `Plan`, `Cont` and `CostTree` in
`Type 0` and make the two signatures literally the same. That is a real
capability (`Type 0` residence, `deriving` becomes available, `Cont`'s `∀ Δ`
stops being large) at the cost of the fifth former's generality — which the
package already documents as reachable only from `bindP`.

### 2.7 What `level` is

`level` (`Level.lean:120`) is the interpretation of the free structure in
`Const Level`, where `Level` is the four-element **join-semilattice**
(idempotent commutative monoid under `max`), with generators sent to their rung
and `case`'s arms merged by `Finset.sup`. Everything about it follows:

* `level_sub`, `level_under` (`:190`, `:207`) — a pure precomposition and a
  signature relabelling both act on the free structure by initiality, so a
  `Const`-valued interpretation is invariant. Two inductions, one reason.
* `level_graft_le`, `level_graft_of_batch`, `level_mapP`, `level_zipWith_le`,
  `level_seq_le`, `level_panel_le` (`:230`–`:299`) — the homomorphism property of
  the interpretation at composition and at the premonoidal product. The `≤` in
  `level_graft_le` and the empty-`case` slack the docstring names is exactly the
  failure of the *nullary* copair to see its continuation.
* `level (dyn …) = ⊤` is **forced**, not conventional: any ω-sound
  over-approximation into a linear order must be `⊤` at the witness `unbounded`,
  because `no_finite_bill_set_at_dyn` (`Cost.lean:908`) makes the observable's
  image infinite.

And the reason `level` survives `case` while `billFresh` does not is §5.1(c):
`max` is idempotent and commutative, `Multiplicative ℕ`'s product is neither.

---

## 3. Seed 2, made exact — and the half of it that is wrong

### 3.1 `revising` is a Moore coalgebra, not a lens (refutation)

The types, with §4's Yoneda iso already applied:

```
check  : Plan (c :: Γ) Verdict                     -- "get":  C ⇝ V
revise : Plan (verdict :: c :: Γ) (El c)           -- "put":  C × V ⇝ C
```

A lens is `Lens s t a b = (get : s → a, put : s × b → t)`. Here the second
component consumes **the very `a` the first produced**, not an independent `b`.
So the pair is not of lens type: it is `(S → V, S × V → S)`, which uncurries to

```
γ : S ⇝ V × S,     γ s = (check s, revise (s, check s))
```

— a coalgebra for `F X = V × X`, i.e. a **Moore machine** with state `S = El c`
and output alphabet `V = Verdict` (Rutten, *Universal coalgebra*, TCS 2000).
`Plan.revising` (`Plan.lean:621`) is the `n+1`-st approximant of the unfold of
`γ` with the halting predicate `Verdict.approvedB`, and `reviseLoop`
(`Denote.lean:477`) is the same recursion at the meaning;
`denotes_revising` (`:493`) is the statement that the two agree.

Three separate reasons the lens reading cannot be repaired:

1. **No `put`-`get` law is even statable.** `PutGet` would say: after amending
   with verdict `v`, reviewing the amended artefact returns `v`. That is the
   negation of the design's purpose — the loop exists because the second review
   may differ — and `trace_upToTwice_stubborn` (`Denote.lean:598`) is a machine-
   checked instance of it failing (three reviews, all objecting, all distinct
   events).
2. **`PutPut` is what the bound replaces.** The lens law that would license
   collapsing repeated amendments is exactly what `Nat.rec` unrolling refuses to
   assume: the meaning of "revise up to `n` times" is its unrolling, not a
   fixpoint.
3. **There is no backward flow anywhere in the meaning.** `denote : Plan Γ A →
   Env Γ → Dlg A` is covariant end to end; `Dlg` has no contravariant component.
   Optics exist to describe a forward-and-backward pair; there is no backward
   pair here to describe.

What *is* load-bearing in the seed's second sentence is the **strength**: the
artefact must survive across the review's effect, which is `dup >>> second'
review`, and the `Sub.comp σ τ` / `subCons` chains in `revising` and in
`Builder.hs`'s `checkCont`/`reviseCont` (`Builder.hs:1016`, `:1021`) are exactly
that. So: seed 2's Tambara clause is right, its lens clause is wrong, and the
right clause is already provided by `pipeline` — **`revising` needs nothing
beyond strength, finite choice, and metalanguage recursion.** That is the
positive content: the bounded loop adds no categorical structure at all, which
is precisely why `level_upToTwice = branch` (`Level.lean:332`).

### 3.2 The lens that *is* there: `Q c ≅ Q.Shape c × String`

`Q.shape` (get) and `Q.Shape.withPrompt` (put) with `shape_withPrompt`,
`prompt_withPrompt`, `withPrompt_shape` (`Question.lean:310`, `:315`, `:321`) —
three `rfl`s that are GetPut, PutGet and the iso condition. This is a
constant-complement lens, the strictest kind, and it is doing three jobs:

* it is the **generator/argument separation** of §1.2, hence the reason
  `Σ_pipe`'s label set is `Shape` and `shapes` is a fold of the syntax alone;
* `Sig.onQ σ c q = (σ c q.shape).withPrompt q.prompt` (`Question.lean:361`) is
  the **complement action**: `Sig` acts on the "view" and leaves the complement
  alone. The docstring calls it "the unique extension of `σ` along the
  isomorphism", which is exactly the lens's induced action;
* `exists_relabel_not_onQ` (`Question.lean:386`) is the theorem that the action
  is *exactly* the complement action: a relabelling that read the words to choose
  the addressee is not of the form `σ.onQ`. In the frame: **signature morphisms
  act on generator labels, not on generator arguments**, and this theorem is that
  statement made concrete.

So the optic the design has is in the *question*, not in the loop; and it earns
its keep because the pipeline analyses are the complement action's fixed data.

### 3.3 The other iso: `Env (c :: Γ) ≅ El c × Env Γ` is the strength

`Env.cons` against `(head, tail)`, with `head_cons`, `tail_cons`,
`cons_head_tail` (`Plan.lean:103`–`:117`) as the round trips. Then

```
Sub.lift σ  =  id_{El c} × σ  =  second' σ,
```

and `Sub.wk = π₂`, and `wk_lift : comp wk (lift σ) = comp σ wk`
(`Plan.lean:214`) is the naturality square of the projection — i.e. one of the
Tambara/`Strong` coherence conditions. `Sub.lift_id` and `Sub.lift_comp` are the
other two. Seed 2's "the carrier plumbing is Tambara/`Strong` `first'`" is
therefore exactly right, and it is `Sub.lift`, in the kernel, already proved.

Worth noting for the performance docstring on `Env` (`Plan.lean:54–80`): the
`2ⁿ` blow-up is the cost of *evaluating* `second'` eagerly. `consBy` makes
`second'` lazy in its second component. That is a statement about the
representation of the strength, not about the semantics, which is why
`consBy_eq_cons` is `rfl`.

### 3.4 Panels: monoid objects, Day, and the premonoidal centre

`panel ps = ps.foldr (zipWith (·*·)) (.ret (fun _ => 1))` (`Plan.lean:595`).
The frame:

> **Where the monoid lives.** `Verdict = WithZero (FreeMonoid Objection)` is a
> monoid *object in `Set`* (`Question.lean:101`). `A ↦ Plan Γ A` is a lax
> monoidal (applicative) functor — that is `zipWith` existing without `dyn`
> plus `level_zipWith_le`. A lax monoidal functor sends monoid objects to monoid
> objects; `panel` is `foldMap id` in the induced monoid on
> `Plan Γ (El .verdict)`.

Day convolution (Day, *On closed categories of functors*, LNM 137, 1970) is the
right name for *why the applicative structure exists at all* — applicative =
monoid in `[Set,Set]` under Day, per Rivas–Jaskelioff — and not for the panel
fold, which is ordinary `foldMap`. Seed 2's Day clause is correct with that
relocation. Then:

* `run_panel`, `trace_panel` (`Denote.lean:365`, `:378`) are the statements that
  `Dlg.run ω : Dlg ⇒ Id` and `⟨run,trace⟩ : Dlg ⇒ Writer Trace` are applicative
  morphisms, hence monoid morphisms on the induced monoids.
* `approved_panel_perm` (`:413`) is: `Verdict.Approved` is a monoid morphism into
  the **commutative** monoid `(Prop, ∧)` (`Question.lean:186`), and permutation
  invariance is a property of the *target*. The aggregate verdict has no such
  licence because its monoid is not commutative.

And one correspondence the package states operationally but does not name:

> **The tensor is premonoidal, and `trace_panel_perm` measures exactly how far
> from central its components are.** In a premonoidal category (Power–Robinson,
> MSCS 1997) `⊗` is not a bifunctor; only *central* morphisms may be interchanged.
> `zipWith` chooses left-then-right sequentialization
> (`denote_zipWith`, `Denote.lean:277`); `Morphism.trace_panel_not_perm_invariant`
> says panel members are not central; `trace_panel_perm` /
> `trace_panel_perm_multiset` / `billFresh_panel_perm` / `approved_panel_perm`
> say precisely which observations *are* invariant. The scheduling licence is the
> centrality analysis, done four times at four observables.

This is the single most under-named piece of category theory in the package: the
whole "parallelism is a fact about a runtime" discussion is the distinction
between a premonoidal tensor and its centre.

### 3.5 Open games / bidirectional optics: decorative here, and why

Hedges-style open games (Ghani–Hedges–Winschel–Zahn, LICS 2018) have lens
structure because a game has a genuine backward flow: `play` forward, `coplay`
utilities backward. agent-cat has no backward flow — see §3.1(3). The only place
one could appear is a *budget that returns a residual*, and the package has
deliberately made budgets static instead: `PlanUpTo` (`Cost.lean:996`) is a
**subtype of the term**, defined by `maxFold ∘ costTree`, not a resource threaded
through a run. So: the optics/open-games reading is decorative here, and it is
decorative *because of a design decision that is recorded and defensible*. If a
future requirement made budgets dynamic (spend as you go, return what is left),
the lens reading would become load-bearing overnight — that is the honest
statement of when to revisit it.

### 3.6 The trace/star operator: a deliberate absence, with the receipt

A loop former would be a **trace** on the premonoidal category
(Joyal–Street–Verity, *Traced monoidal categories*, 1996; Hasegawa, TLCA 1997,
for trace = fixpoint). The package has one recorded attempt at it and abandoned
it: `Agentic/Star.lean` is "retry as a star: the loop solved, not unrolled", and
`retry_cost_ambiguous` there is the reason it lost — under a bare
`StarSemiring` the same loop equation is answered by `fin 3`, `fin 5` and `inf`,
each by `rfl`, so the cost read-out is not determined. `revising`-by-unrolling is
what replaced it. In the frame: **the design deliberately has no traced structure,
and `level_upToTwice = branch` is the payoff** — a trace operator would either
raise the rung or require a fixpoint semantics with `⊥`, which `Dlg`'s
least-fixed-point construction forbids (`Dlg.lean:42–49`).

---

## 4. Seed 3's real content: `Cont` is a Kan extension, and Yoneda collapses it

This is the strongest *actionable* result in the document.

### 4.1 The computation

`Cont Γ A B := ∀ Δ : Ctx, Sub Γ Δ → Expr Δ A → Plan Δ B` (`Plan.lean:410`).
Writing `X = Env Γ`, `Y = Env Δ`, and using
`(Y → X) × (Y → A) ≅ (Y → X × A)`:

```
Cont Γ A B  ≅  ∀ Y ∈ E.  Hom_Set(Y, X × A) → Plan(Y) B
            =  Nat_E( Hom_Set(−, X × A)|_E ,  Plan(−) B )
            =  (Ran_{j^op} Plan(−)B)(X × A),        j : E ↪ Set
```

— the **right Kan extension of the presheaf `Plan(−) B` along the inclusion of
environment types into types**, evaluated at `Env Γ × A` (Mac Lane, CWM Ch. X).
Because `j` is fully faithful, `Ran_j P ∘ j ≅ P`; so whenever `Env Γ × A` is
*itself* an environment type, the extension collapses:

> **Theorem (Yoneda for `Cont`).** For any code `c`, the maps
> ```
> Φ : Cont Γ (El c) B → Plan (c :: Γ) B,   Φ k = k (c::Γ) Sub.wk (Expr.var .here)
> Ψ : Plan (c :: Γ) B → Cont Γ (El c) B,   Ψ q = fun Δ σ e => sub q (fun δ => Env.cons (e δ) (σ δ))
> ```
> satisfy `Φ ∘ Ψ = id` **unconditionally** (it is `cons_head_tail` followed by
> `sub_id`), and `Ψ ∘ Φ = id` on exactly the *natural* families, i.e. those `k`
> with `k Δ σ e = sub (Φ k) (subCons e σ)`. Hence
> `Plan (c :: Γ) B ↪ Cont Γ (El c) B` is a split mono whose image is the natural
> families, and `Plan.Denotes k K` (`Denote.lean:212`) is precisely the semantic
> shadow of that naturality condition.

More generally `Cont Γ (El c₁ × ⋯ × El cₖ) B ≅ Plan (cₖ :: … :: c₁ :: Γ) B`, and
`Ψ` at `k = 2` is exactly `Builder.hs`'s `reviseCont`
(`Plan ('CodeVerdict ': c ': g) (El c) -> Cont g (El c, Verdict) (El c)`,
`Builder.hs:1021`).

### 4.2 What the collapse deletes

**The implementation has already found this iso and uses only its image.** Every
`Cont` the elaborator builds is `Ψ` of a plan:

| site | is | Lean counterpart |
|---|---|---|
| `Builder.graftForm v k = graft v (Cont (\σ e -> subP k (subCons e σ)))` | `Ψ` at one code | `Check.lean`'s bind form |
| `Builder.checkCont`, `reviseCont` | `Ψ` at one / two codes | `Check.lean:491`, `:498` |
| `Builder.callStmt`'s `Cont (\σ _ -> subP rest σ)` | `Ψ` composed with discard = `seqP` | `Check.lean:580` |

So the proposal is not speculative: **make the representable form primitive.**

```lean
def bindAt {Γ : Ctx} {c : Code} {B : Type}
    (p : Plan Γ (El c)) (q : Plan (c :: Γ) B) : Plan Γ B := graft p (Ψ q)
```

with the master lemma stated **without a hypothesis**:

```lean
theorem denote_bindAt (p : Plan Γ (El c)) (q : Plan (c :: Γ) B) (γ : Env Γ) :
    denote (bindAt p q) γ = Dlg.bind (denote p γ) (fun x => denote q (Env.cons x γ))
```

What that deletes or simplifies, by name:

* `Plan.Denotes` (`Denote.lean:212`) — gone for every representable use.
* `denote_graft`'s hypothesis (`Denote.lean:229`) — gone at `bindAt`.
* `Plan.Equiv.graft_congr`'s two naturality premises (`Denote.lean:695`) — gone.
* `level_graft_le` / `level_graft_of_batch` (`Level.lean:230`, `:259`) — the
  premise `∀ Δ σ e, level (k Δ σ e) ≤ ℓ₀` becomes the single bound
  `level q ≤ ℓ₀`, discharged through the already-proved `level_sub`.
* `denotes_revising` (`Denote.lean:493`) — its two `Denotes` hypotheses are
  discharged by construction.
* In Haskell: the rank-2 `newtype Cont` (`Plan.hs:540`, whose docstring already
  complains that Haskell "needs a `newtype` for it") disappears, and with it
  `runCont`. Note the asymmetry the collapse also removes: Haskell's rank-2
  `forall d.` *does* give naturality by parametricity (Wadler, *Theorems for
  free!*, FPCA 1989), Lean's `∀` does not — which is exactly why `Denotes`
  exists in Lean and has no Haskell counterpart. After the collapse neither side
  needs the appeal.

**The one obstruction, and it is a spec decision.** The general `graft` at a
non-representable `A` is still used in three places: `mapP`, `zipWith`, `seq` (all
harmless — their continuations are constant in `σ` up to `sub`, so they can be
given directly), and `Check.lean:505`'s `finishCont`, whose `A = Option (El c)`
is not an environment type. That `Option` exists only because `revising` returns
a value the context cannot hold — which the surface *already* refuses to let
happen: `Pend Γ` (`Check.lean:527`) forbids every statement until the consuming
`case` arrives, and `Builder.revisingCase` / `Workflow`'s `Stage = Pending c s`
bundle the loop with its two arms into one combinator. Fusing them —

```lean
def revising' (check) (revise) (n) (settled : Plan (c :: Γ) A) (unsettled : Plan Γ A) : Plan Γ A
```

— removes `Option (El c)` from the term language, removes the last
non-representable `Cont`, and lets `Cont` be deleted outright. It also **changes
the elaborated term**: today each loop exit is a `ret (some a)` / `ret none` leaf
that `finishCont` replaces with a two-armed `caseB (isJust …)`; fused, the arms sit
at the exits directly. `askNodes` is unchanged (a `case` contributes no asks), but
`Plan.size` and `costSummary`'s `paths` **change**, and both are pinned by the
frozen corpus. So this half is a proposal to regenerate the spec, and that is the
owner's call, not the refactor's.

### 4.3 Handles as profunctor lenses: refuted, with a salvage

Seed 3 proposes replacing the Builder's nominal `Scope`/`LookupC`/`KnownVar`
machinery (`Builder.hs:190–252`) with profunctor lenses into a structural
environment. Three objections, in increasing severity:

1. **A lens is over-powered.** `Env` is append-only; nothing in the language
   updates a binding. Only the `get` half is ever used, and the `get` half *is*
   `Var Γ c` with `Var.get` — membership as data, already the projection.
2. **The nominal layer is not plumbing, it is diagnosis.** `LookupC`'s
   `TypeError` reproduces `Check.lean:99`'s `unbound` and `Fresh`'s reproduces
   `freshName`'s refusal verbatim. Those messages are the product.
3. **Names are observable.** The printed `RawProgram` carries the author's name
   (`nameText @n`), and that `Raw` is what the conformance oracle checks
   (connection.md §3.1, D5). A structural encoding that erased the `Symbol`
   would change the wire object, i.e. the frozen corpus.

The salvage is worth stating anyway: the *weakening* half of the machinery is
already structural and should be named as such. `subLift = second'`,
`subWk = π₂`, and `subCons e σ` is the counit of the Yoneda iso of §4.1 — so the
Builder's "no weakening is ever written by hand" is the statement that the
Tambara action is derived, not authored. That is the correct half of seed 3.

---

## 5. The meta-theorem

### 5.1 Statement

Fix the signatures of §1.2 and, for a rung `ℓ`, let `𝔽_ℓ` be the free
`ℓ`-structure over the corresponding signature:

| `ℓ` | `𝔽_ℓ` | free in |
|---|---|---|
| `batch` | free applicative on `Σ_batch` | monoids in `([Set,Set], Day)` — Rivas–Jaskelioff |
| `pipeline` | free Freyd category over `E` on `Σ_pipe` | monoids in `(Tambara(Set,Set), ⊙)` — Rivas–Jaskelioff; Atkey |
| `branch` | `𝔽_pipeline` + finite distributive coproducts | free `ArrowChoice` at `FinEnum` tags |
| `dynamic` | Kleisli of the free monad on `Σ_pipe` | free `ArrowApply` — Hughes |

An **observable** is a monoid morphism `φ : Trace → M` out of the free monoid on
`Event` (`billFresh price`, `List.length`, `List.map Event.shape`, …); for a plan
`p` and environment `γ` it induces the world-indexed family
`O_p : Ω → M`, `O_p ω = φ (Plan.trace ω p γ)`. An **analysis into `T`** is an
`ℓ`-structure homomorphism `⟦−⟧_T : 𝔽_ℓ → T`. Call it *exact* if `T = Const M`
and `⟦p⟧ = O_p ω` for all `ω`; *sound over-approximating* if `T = Const M` with
`M` ordered and `O_p ω ≤ ⟦p⟧` for all `ω`; *enveloping* if `T` is a
finite-family completion and `O_p ω ∈ leaves ⟦p⟧` for all `ω`.

> **Meta-theorem (rung ⇒ analysis).**
>
> **(0) Presentation.** For each rung, the fragment `{p | level p ≤ ℓ}` modulo
> `≈ᵖ` is `𝔽_ℓ`, with `Plan Γ A = 𝔽_ℓ(Env Γ, A)`; `level` is the syntactic
> membership test, sound and (kernel open question 1) not complete.
>
> **(1) Existence and uniqueness.** For any target `T` carrying the
> `ℓ`-structure, an interpretation of the generators extends uniquely to an
> `ℓ`-homomorphism `⟦−⟧_T : 𝔽_ℓ → T`.
>
> **(2) `ℓ ≤ batch`.** `Const M` is applicative for every monoid `M`, and the
> generators are nullary, so *every* function `Key → M` — content-dependent
> pricing included — induces an **exact** analysis. No hypothesis on the price.
>
> **(3) `ℓ ≤ pipeline`.** A `Const M` target is object-blind, so an
> interpretation is exactly a function `Shape → M`; equivalently a
> `PricesByShape` price. The universal such target is
> `Const (FreeMonoid Shape)`, whose interpretation is `shapes`; every exact
> `Const M` analysis factors through it by a unique monoid morphism.
>
> **(4) `ℓ ≤ branch`.**
>   (a) No exact `Const M` analysis exists in general: two reachable arms with
>       different observables force two values.
>   (b) A **sound over-approximating** `Const M` analysis exists iff `M` is a
>       join-semilattice and `case` is interpreted by the join. (The interchange
>       needed to merge arms and then post-compose is `m·n = n·m` and `m·m = m`.)
>   (c) The universal **enveloping** target is the free finite-family completion
>       of `Const M` — finite trees of `M`-leaves with multiplicity — i.e.
>       `CostTree M`. `bill_mem_leaves` is the unit of that adjunction, and
>       `minFold`/`maxFold` are the two semiring homomorphisms into the min-plus
>       and max-plus tropical semirings.
>
> **(5) `ℓ = dynamic`.** No enveloping analysis into a finite-family completion
> exists: the witness `unbounded` has `O_p` with infinite image. Consequently
> any sound over-approximation into a linear order is `⊤` at that witness. This
> is a **witness at the rung**, not a universal over its inhabitants.

Part (4b) is the repair of seed 1's mechanism, and it is the load-bearing
sentence of the whole document: **`level` survives `case` because `max` is
idempotent and commutative; `billFresh` does not because `Multiplicative ℕ`'s
product is neither.** "Const is monoidal but not compositional" is false —
`Const M` is a lawful `Arrow` and satisfies Paterson's stated `ArrowChoice` laws
with `left' = id`, and it even admits an `app`. What it cannot do is be
*ω-sound* past a reachable branch unless the monoid is a semilattice.

### 5.2 What it subsumes, by name

Currently ~12 independent structural inductions over `Plan`; the meta-theorem
leaves ~4 (one presentation/initiality theorem per rung) and makes the rest
corollaries.

Kept as the initiality theorems (one induction each):

* `Cost.asks_eq_of_le_batch` (`:397`) — batch.
* `Cost.shapes_eq_trace_of_le_pipeline` (`:511`) — pipeline, universal target.
* `Cost.bill_mem_leaves` (`:691`) — branch, enveloping.
* `Denote.denote_graft` / `denote_bindAt` — composition (after §4).

Become corollaries by monoid or semiring homomorphism:

* `Cost.codes_eq_of_le_pipeline` (`:441`) — `List.map Shape.code`. Currently a
  separate induction.
* `Cost.length_trace_eq_of_le_pipeline` (`:458`), `Cost.shapes_eq_of_le_pipeline`
  (`:529`), `Cost.bill_indep_of_le_pipeline` (`:566`),
  `Cost.bill_exact_pipeline` (`:596`), `Cost.bill_exact_batch` (`:425`) —
  already corollaries; the frame explains *why* they are.
* `Explain.Plan.length_trace_eq_askNodes` (`:171`) and
  `Plan.size_eq_askNodes_succ` (`:190`) — `List.length` and `+1`. Currently two
  separate inductions.
* `Cost.asks_isSome_of_le_pipeline`, `codes_isSome_of_le_pipeline`,
  `shapes_isSome_of_le_pipeline` (`:358`, `:368`, `:379`) — three inductions,
  one fact: the initial map is total on the fragment.
* `Level.level_sub`, `level_under` (`:190`, `:207`) — invariance of a `Const`
  interpretation under pure precomposition and signature relabelling.
* `Level.level_graft_le`, `level_graft_of_batch`, `level_mapP`,
  `level_zipWith_le`, `level_seq_le`, `level_panel_le` (`:230`–`:299`) — the
  homomorphism property at composition and at the premonoidal product.
* `Cost.CostTree.minFold_le_of_mem`, `le_maxFold_of_mem`, `minFold_le_bill`,
  `bill_le_maxFold` (`:735`–`:766`) — tropical semiring homomorphisms out of the
  universal enveloping object.
* `Denote.run_panel`, `trace_panel`, `approved_panel_cons` (`:365`, `:378`,
  `:459`) — applicative-morphism + induced-monoid, per §3.4.
* `Plan.under_idSig`, `under_under`, `under_atModel_atModel`, `Dlg.under_*`
  (`Plan.lean:354`–`:386`, `Dlg.lean:234`–`:262`) — a signature morphism induces
  a homomorphism of free structures, functorially in the morphism.

### 5.3 Where it is strictly weaker than a bespoke theorem

This list is the honest limit of the exercise, and it is not short.

1. **Every byte-pinned number.** `Acceptance.bill_sharedGuide = ofAdd 3`
   (`Cost.lean:1025`), `trace_sharedGuide` as an explicit three-event list
   (`Denote.lean:661`), `trace_upToTwice_stubborn =
   [.verdict,.text,.verdict,.text,.verdict]` (`:598`, by `rfl`),
   `run_upToTwice_stubborn = none`, `level_upToTwice = branch` (`Level.lean:332`,
   `by decide`), and the whole frozen conformance corpus's `size`, `askNodes`,
   `costSummary`, `paths`. **An initiality theorem gives existence and
   uniqueness of the number; it never gives the number.** These stay, they stay
   proved by computation, and the frame's only contribution is to explain why
   they are well defined.
2. **The witnesses.** `no_finite_bill_set_at_dyn` (`:908`),
   `no_cost_tree_at_dyn` (`:926`), `no_static_bill_at_branch` (`:974`),
   `minFold_not_attained` (`:839`), `billMemo_not_monoid_hom` (`:276`),
   `exists_relabel_not_onQ` (`Question.lean:386`), `Dlg.not_forcing`
   (`Dlg.lean:450`). A structure-existence schema produces no counterexamples; it
   is the wrong shape of statement.
3. **Reachability.** `exists_min_bill` / `exists_max_bill` (`:776`, `:792`) are
   about the image of `Ω → M`, not about the tree. The gap between them and
   `minFold`/`maxFold` is kernel open question 1 and the meta-theorem is silent
   on it. In Mokhov et al.'s vocabulary this is the difference between the
   over-approximation and the achievable set, and their paper documents the same
   gap for selective computations.
4. **`billMemo` is not an interpretation at all.** It is not a monoid morphism
   (`billMemo_not_monoid_hom`), so it is not an `ℓ`-homomorphism into any
   `Const M`, so nothing in the meta-theorem reaches it.
   `billMemo_dvd_billFresh` (`:211`) and `billMemo_le_billFresh` (`:219`) stay
   bespoke, and *that is the point the package makes about memoization being a
   runtime policy*.
5. **`Cost.asks`.** A semantic probe at `ωDefault`, not a static analysis (§2.3).
   `asks_eq_default` and `asks_eq_of_le_batch` cannot both be corollaries of the
   same initiality statement.
6. **Multiplicity.** The universal enveloping object must be the free
   finite-**family** completion, not the free semilattice: `paths =
   Multiset.card leaves` counts duplicate leaves, and `battery-042` pins
   `paths 2` at equal prices. Presenting `branch` with an idempotent choice —
   which is the most natural categorical presentation — changes a frozen number.
7. **The quotient.** The meta-theorem is stated modulo `≈ᵖ`, but `Plan.size`,
   `Plan.askNodes`, `Plan.explain` and `paths` are **not** `≈ᵖ`-invariant. So the
   free-structure presentation can never replace the *term*; `Plan` must remain
   a first-order syntax and the theorems about the analyses must remain theorems
   about that syntax. This is the hard boundary of the frame and it agrees with
   the package's own reason for classifying terms rather than meanings
   (`Level.lean:26–32`).

### 5.4 The conformance constraint, applied

connection.md §3.1 (D5) pins the printed `RawProgram` and the full observation
record — `level`, `size`, `askNodes`, `codes`, `shapes`, `asks`, `costSummary`
(`minFold`, `maxFold`, `paths`), `blockAsks`, `fnAsks`, and per-world
`trace`/`billFresh`/`billMemo`. Sorting the proposals against that:

| proposal | corpus impact |
|---|---|
| §4.2 `bindAt` + delete `Denotes` for representable uses | **none** — same nodes, same folds; a proof refactor |
| Name `Sub.lift = second'`, `Q ≅ Shape × String` as a lens, the premonoidal centre | **none** — documentation |
| §5.2 collapse the pipeline theorems to homomorphisms out of `shapes` | **none** — proof refactor |
| §2.6 close the `case` tag universe / restrict `dyn`'s `B`, demote to `Type 0` | **none** *if* the two tag types are kept (the elaborator emits only those two, and the Haskell port already does this) |
| §4.2 fuse `revising` with its consuming `case`, delete `Option (El c)` and `Cont` | **breaks** `size` and `paths`; requires regenerating the spec — **owner decision** |
| present `branch` with an idempotent choice | **breaks** `paths`; do not |

---

## 6. Ranked proposals

1. **Yoneda-collapse `Cont` at representable answer types** (§4). Deletes
   `Plan.Denotes`, unhypothesizes the master lemma, simplifies four `level`
   lemmas, deletes the rank-2 `newtype` in Haskell, and removes the
   Lean-vs-Haskell parametricity asymmetry. Zero corpus impact. Do this first.
2. **State the pipeline analyses as one initiality theorem plus homomorphisms**
   (§2.3, §5.2). Turns ~8 inductions into 1 + 7 corollaries. Zero corpus impact.
3. **Name the three structures that are already there**: `Sub.lift = second'`
   (Tambara), `Q ≅ Shape × String` as the lens whose complement `Sig` acts on,
   and the premonoidal centre as what the four scheduling-licence theorems
   compute. Documentation only, and it is the cheapest clarity in the package.
4. **Answer kernel open question 3 in the source** (§2.4): `askC` buys nullary
   generators, hence a whole-question label set, hence content-dependent pricing.
   One docstring.
5. **Record the (4b) mechanism next to `level`** (§5.1): a `Const M` analysis
   crosses `case` iff `M` is a join-semilattice. This is the sentence that
   explains why `level` is total and `billFresh` is not, and it currently exists
   nowhere.
6. **Consider closing the tag universe** to demote `Plan` to `Type 0` (§2.6).
   Free if the two tag types suffice, which `Check.lean` says they do.
7. **Consider fusing `revising` with its `case`** (§4.2) — the only proposal that
   requires regenerating the frozen spec, and therefore the only one that is not
   a refactor.

Explicitly **not** proposed: a `Monad`/`Applicative`/`Arrow` *instance* on
`Plan`. The package's refusal (`Plan.lean:28–35`) is the right call in this
frame: instances would make `bindP` look as free as `zipWith` when the whole
content of the level lattice is that it is not. The frame's contribution is to
say *which* class each rung would satisfy, not to install any of them.

---

## 7. Literature map — one line each on what it contributes *here*

*Where I am unsure a citation is exact I mark it. Volume/page numbers for the
ENTCS proceedings volumes in particular are from memory and should be checked
before this document is quoted.*

**The hierarchy.**

* **J. Hughes, "Generalising monads to arrows", Science of Computer Programming
  37(1–3):67–111, 2000.** The `ArrowApply ⟺ Kleisli-of-a-monad` theorem: this is
  §2.6's identification of `dyn`, and the reason `bindP` is the only derived form
  that needs it.
* **R. Paterson, "A new notation for arrows", ICFP 2001, 229–240.** The `ArrowChoice`
  law list checked in §5.1 against `Const M`; also the `proc`/`-<` notation whose
  de Bruijn analogue `Plan` is.
* **S. Lindley, P. Wadler, J. Yallop, "Idioms are oblivious, arrows are
  meticulous, monads are promiscuous", MSFP 2008; ENTCS 229(5):97–117, 2011
  (volume/pages uncertain).** The frame of §2.1, and the *static arrows ≅ idioms*
  theorem that identifies `batch` — i.e. that `askC`/`ask`/`dyn` is exactly
  oblivious/meticulous/promiscuous.
* **S. Lindley, P. Wadler, J. Yallop, "The arrow calculus", JFP 20(1):51–69,
  2010 (pages uncertain).** The normal form of §2.3 *is* their calculus's; and
  their two-context judgment `Γ; Δ ⊢ P ! A` is what `Plan Γ A` with
  `Expr Γ A = Env Γ → A` degenerates to when the base is cartesian.
* **A. Mokhov, G. Lukyanov, S. Marlow, J. Dimino, "Selective applicative
  functors", PACMPL 3(ICFP):90, 2019.** The right citation for the *analysis*
  discipline at `branch` — over-approximating statically visible effects — and
  therefore for `bill_mem_leaves` vs `minFold_not_attained`. Not the right
  citation for `case`'s algebra, since `pipeline` already exceeds applicative.

**The free constructions.**

* **E. Rivas, M. Jaskelioff, "Notions of computation as monoids", JFP 27, 2017
  (volume/e-number uncertain; an earlier MPC/arXiv version exists).** The
  uniform "monoid in a monoidal category of functors/profunctors" account:
  applicative = Day, monad = composition, arrow = profunctor composition on
  strong profunctors. This is the sentence that makes §5.1's four rows one row.
* **P. Capriotti, A. Kaposi, "Free applicative functors", MSFP 2014, EPTCS
  153:2–30.** The normal form used verbatim in §2.2's iso.
* **B. Jacobs, C. Heunen, I. Hasuo, "Categorical semantics for arrows", JFP
  19(3–4):403–438, 2009**, and **C. Heunen, B. Jacobs, "Arrows, like monads, are
  monoids", MFPS 2006, ENTCS 158:219–236.** The arrows-as-monoids-in-profunctors
  result being invoked in §2.3.
* **R. Atkey, "What is a categorical model of arrows?", MSFP 2008; ENTCS
  229(5):19–37, 2011 (pages uncertain).** Why I state §2.3 as a *Freyd category*
  rather than a bare profunctor monoid: `arr` and `first` need the base handled
  explicitly, which is exactly what `Sub`-as-a-function supplies here.
* **J. Power, E. Robinson, "Premonoidal categories and notions of computation",
  MSCS 7(5):453–468, 1997**, and **J. Power, H. Thielecke, "Closed Freyd- and
  κ-categories", ICALP 1999, LNCS 1644:625–634.** Freyd categories, and the
  premonoidal tensor + centre of §3.4 — the frame for the four
  scheduling-licence theorems.
* **B. Day, "On closed categories of functors", Reports of the Midwest Category
  Seminar IV, LNM 137:1–38, 1970.** Day convolution: why the applicative
  structure exists, per §3.4, and hence why `panel` is `foldMap`.

**Strength and optics.**

* **C. Pastro, R. Street, "Doubles for monoidal categories", Theory and
  Applications of Categories 21(4):61–75, 2008.** Tambara modules for
  profunctors: the class that `Sub.lift = second'` inhabits (§3.3). *The notion
  is named for D. Tambara's work on distributive laws for module categories; I do
  not have his exact reference to hand and would check it before citing him
  directly.*
* **M. Pickering, J. Gibbons, N. Wu, "Profunctor optics: modular data
  accessors", The Art, Science, and Engineering of Programming 1(2):7, 2017.**
  The concrete lens/`Strong` dictionary against which §3.1's refutation is
  checked and §3.2's lens is identified.
* **G. Boisseau, J. Gibbons, "What you needa know about Yoneda: profunctor
  optics and the Yoneda lemma", PACMPL 2(ICFP):84, 2018.** The methodological
  precedent for §4: the higher-rank type *is* a Yoneda/representability fact, and
  collapsing it is the intended move rather than a trick.
* **B. Clarke, D. Elkins, J. Gibbons, F. Loregian, B. Milewski, E. Pillmore,
  M. Román, "Profunctor optics, a categorical update", Compositionality, 2024
  (arXiv:2001.07488; year uncertain).** The general (mixed-optic) account; the
  reason I can say with confidence that `revising` is *not* an optic of any kind
  in their taxonomy — there is no residual/complement flowing backward.
* **S. Mac Lane, "Categories for the Working Mathematician", Ch. X.** Kan
  extensions; §4.1's identification of `Cont` and the fully-faithful collapse.
* **P. Wadler, "Theorems for free!", FPCA 1989, 347–359.** Why Haskell's rank-2
  `Cont` gets naturality for nothing and Lean's does not — the asymmetry §4.2
  removes.

**Bidirectionality, iteration, and the paths not taken.**

* **A. Alimarine, S. Smetsers, A. van Weelden, M. van Eekelen, R. Plasmeijer,
  "There and back again: arrows for invertible programming", Haskell Workshop
  2005, 86–97 (pages uncertain).** The arrow-side analogue of the lens reading:
  bidirectional arrows exist and require an inverse in the *arrow*. `revising`
  has none — the amended artefact is not an inverse image of the verdict — which
  is the arrow-side confirmation of §3.1.
* **J. Hedges, "Towards compositional game theory", PhD thesis, QMUL, 2016**, and
  **N. Ghani, J. Hedges, V. Winschel, P. Zahn, "Compositional game theory", LICS
  2018, 472–481.** Open games' lens structure exists because utilities flow
  backward; §3.5 uses this to say precisely what would have to change in
  agent-cat (dynamic budgets) before the optic became load-bearing.
* **J. J. M. M. Rutten, "Universal coalgebra: a theory of systems", TCS
  249(1):3–80, 2000.** Moore/Mealy coalgebras: the correct identification of
  `(check, revise)` as `γ : S → V × S` in §3.1, and of `revising … n` as its
  `n+1`-st approximant.
* **A. Joyal, R. Street, D. Verity, "Traced monoidal categories", Math. Proc.
  Cambridge Philos. Soc. 119(3):447–468, 1996**, and **M. Hasegawa, "Recursion
  from cyclic sharing", TLCA 1997, LNCS 1210:196–213.** What a loop *former*
  would be, and hence what `Agentic/Star.lean`'s abandoned star was; §3.6.
* **S. Bloom, Z. Ésik, "Iteration Theories", Springer EATCS Monographs, 1993**;
  **J. Adámek, S. Milius, J. Velebil, "Elgot theories", MSCS 21(2):417–480, 2011
  (volume/pages uncertain)**; **S. Goncharov, L. Schröder, C. Rauch, M. Piróg,
  "Unifying guarded and unguarded iteration", FoSSaCS 2017, LNCS 10203:517–533
  (uncertain).** The theory of the iteration operator agent-cat deliberately does
  *not* have; cited to make the absence a decision rather than an omission.

---

## 8. Two questions this frame raises and does not settle

1. **Completeness of `level` (kernel open question 1), restated.** Part (0) of
   the meta-theorem says `level p ≤ ℓ` is a *sound* membership test for `𝔽_ℓ`.
   Completeness would say: if `p ≈ᵖ q` for some `q` with `level q ≤ ℓ`, then the
   ℓ-analyses are valid for `p`. In the frame this is exactly the question of
   whether the fragment inclusions `𝔽_batch ↪ 𝔽_pipeline ↪ 𝔽_branch ↪ 𝔽_dyn` are
   *full* on the image of `denote` — i.e. whether the free-structure inclusions
   reflect semantic equality. `Dlg.not_forcing` (`Dlg.lean:450`) says `denote`'s
   codomain over-represents observations, so the honest form of the question is
   about `Obs`, not about `=`, and the repeat-free (`Fresh`) fragment is where an
   answer would live. That is a well-posed question the frame makes askable.
2. **Is `Plan` at `branch` free over a *distributive* Freyd category, or only
   over one with finite coproducts?** `case` uses the `Set` distributive law
   `X × T ≅ Σ_t X`. If the base were only cartesian-with-coproducts and not
   distributive, `case` would not be expressible as a copair, and `costTree`'s
   independent pricing of arms would lose its justification. Since the base here
   *is* `Set`, the question is only whether the presentation should record
   distributivity as a hypothesis — which matters the moment anyone tries to
   reinterpret `Plan` in a non-distributive base (a probability monad's Kleisli
   category, say, which is a plausible next target for a cost model).
