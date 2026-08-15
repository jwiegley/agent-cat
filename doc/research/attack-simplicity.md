# Attack: Simplicity and Purity

*An adversarial reading of the four re-derivations under Elliott's four completion tests and ten
anti-patterns. The lens is simplicity and purity only: bespoke vocabulary where a standard class
exists, constructors that should be derived forms, meanings chosen for computability rather than
comprehension, complexity relocated into clients, grading machinery where a standard hierarchy
suffices, and anything retained because `agent-functor` has it.*

**Thesis.** The four proposals agree on the easy nine-tenths — one generator, standard classes,
labels deleted, `Frag` deleted — and disagree on the one decision that actually costs something:
*is the oracle a function or a kernel?* Three of them say function, and each then has to buy back
what a function forbids (a `draw` index, a namespace, a gensym, a mandated memoizing runtime, a
second cost fold). `rederive-decontaminate` says kernel, buys nothing, and recovers the other
three as its Dirac instance. It wins on the lens, and its residual impurities are seven, all
local. The most expensive thing wrong with the field as a whole is that **the domain's single most
common pattern — build a prompt out of an earlier answer, a fixed number of times — has no home in
three of the four proposals**, and the one proposal that gives it a home states a false theorem
about it.

---

## 0. What was run against each proposal

For each of `rederive-meaning-first` (**MF**), `rederive-algebra-first` (**AF**),
`rederive-decontaminate` (**DC**), and the constructive half of `contamination-ledger` (**CL**,
§4):

- **Completion test 1** — does every type have a one-line answer to "a `T` is a representation of
  what mathematical object?", and is that answer an *object* rather than a *syntax*?
- **Completion test 2** — is every operation's meaning forced by a morphism equation, and is any
  operation named that a standard class already supplies?
- **Completion test 3** — do the laws hold by morphism, or is there a per-type proof obligation
  hiding behind the word "then"?
- **Completion test 4** — would the specification run, if slowly; has any performance decision
  moved the denotation?
- **Anti-pattern scan** — all ten, with particular attention to 2 (representation becoming the
  concept), 3 (index arithmetic), 4 (a tape in the model), 6 (a machine fact in the meaning),
  8 (bespoke names), 9 (invariant by documentation), 10 (laws asserted rather than derived).
- **Where did the complexity go?** — the doctrine's review instruction. A trivially simple kernel
  surrounded by author obligations has relocated its complexity, which is worse than keeping it.

Load-bearing `agent-cat` citations used below were verified against the source:
`peak_not_le_grade` at `Agentic/Meaning.lean:1636`, `one_add_one_of_muS_respects_WEq` at
`:2814`, `acat-qtv` at `:47`, `acat-bmc` at `Agentic/Term.lean:80`. Line counts: `Term.lean` 535,
`Frag.lean` 285, `Meaning.lean` 2831.

---

## 1. The one question that separates them

Every other disagreement in the four documents is downstream of this:

> Two occurrences of `ask q` in one workflow. Same answer, or two draws?

| | answer | mechanism | what it costs |
|---|---|---|---|
| **MF** | same | world is a function `Q → El` | a `draw : Nat` field in the question; a *mandated* memoizing runtime (§11.3); a second fold (`trace`) so that cost can see what value cannot |
| **AF** | same | world is a function `(q:Q) → R q` | a `draw : Draw` field **and** a `ns : Namespace` field **and** a gensym for hygiene (§6.3); an idempotent cost carrier `Finset Q`; a non-homomorphic `bill` |
| **CL** | different | world indexed by `(History, Q)` | state threading in the meaning — see §5 |
| **DC** | different | oracle is a kernel `(q:Q) → V (Ans q)` | nothing: independence is the Kleisli tensor, sharing is `fmap Δ` |

DC's position is the only one that adds no vocabulary. Independence of two occurrences is the
monoidal structure of the Kleisli category of a commutative monad; sharing is the diagonal, which
is a *pure function*, pushed forward. `share ≠ dup` is then the standard fact that copying is not
natural (Fritz's Markov-category condition), not a design axiom needing a labelled key — which is
the same theorem `agent-cat` spends `Env.lean`, `Keys.lean` and a thousand lines of `Meaning.lean`
to be able to state.

And DC *contains* the other three. At a deterministic oracle `ω = δ ∘ o`, `Δ_* (δ a) = δ a ⊗ δ a`,
so `share x = dup x` extensionally and the two differ only in the cost fold — which is precisely
MF's headline slogan, "value is insensitive to repetition; cost is not" (§5 q1), obtained as an
instance rather than as a design decision. The world-as-a-function designs are the `S = Bool`,
`ω = δ ∘ o` fragment of DC. The converse does not hold: MF and AF cannot express a stochastic
oracle at all except by pushing a measure over worlds, which AF's own Randomization Lemma (§5.4)
shows requires `μ` to be a product measure — a side condition DC never incurs.

**AF's refutation of this position does not hold.** AF §9 Attempt A rejects a measure-valued
meaning because "`⟦ask q *> ask q⟧` is a product of two independent draws — which is right for
resampling and *wrong* for reuse, with no way to say which is meant." There *is* a way to say
which is meant, it is compositional, and it is not a label: reuse is `(fun a => (a,a)) <$> ask q`.
AF's second sentence ("adding a `share`/label mechanism then makes `⟦·⟧` non-compositional")
attacks a mechanism nobody needs. Attempt A was closed too early, and the whole `draw`/namespace
apparatus of §3.1 and §6.3 is the price of closing it.

---

## 2. `rederive-meaning-first` (MF) — audit

### What is genuinely strong

- **One meaning, and the observations are folds out of it.** `run`, `trace`, `cost` all come from
  `Dlg`, and `cost` factors through `trace`. This dissolves `acat-qtv` (`Meaning.lean:47`, "a
  matrix has no room to record a site") *by construction*: the object that decides equality is the
  object that records which questions were asked. That is the correct diagnosis of agent-cat's
  two-meaning split and the correct repair.
- **The Forcing Lemma** (§2.4) is the right kind of move: it converts "I picked a tree" into "the
  tree is the object of coherent world-indexed (result, transcript) pairs".
- **Memoization-is-adequacy** (§11.3) is a real result under MF's own assumptions.
- **Higher-order continuations delete the entire label/site/key/quotient apparatus** and make
  ill-scoped terms unwritable rather than merely discouraged. This is the doctrine's instruction in
  its strongest form and MF states it best of the four.

### Test 1 — the meaning is the syntax, rescued by a lemma

`[[W A]] = Dlg A` where `Dlg` is the free monad on the question signature. MF says so plainly
(§7 preamble): "Because the carrier was chosen to *be* the meaning, the doctrine's morphism
discipline moves one level out." That is `[[·]] = id`. There is then nothing for a morphism
equation to constrain, and the asymmetry the doctrine insists on — *meaning constrains
implementation, never the reverse* — has no content, because there is only one artifact.

The Forcing Lemma rescues this, but the presentation has it backwards. The honest meaning is

```
[[W A]] = { (r, t) : World → A × List Event | coherent }
```

and `Dlg A` is the *solved form* — the representation in which coherence is structural rather than
a side condition. Stated that way the discipline is intact and the lemma is the derivation. Stated
MF's way it is anti-pattern 2 (the representation becoming the concept) avoided by an appendix.
**The synthesis should lead with the observation pair and derive the tree.**

### Test 2 — one bespoke structure and one bespoke level

- **"Choice-semiring"** (§8.1) is invented: a carrier with sequencing `⊗`, independence `∥`, and
  alternation `⊕`. Three operations, one bespoke name, no library, no laws stated. Against DC's
  `cost_is_meaning` — cost is the *same* meaning evaluated at min-plus or max-plus, one fold, zero
  new structures — this is a straight loss. MF pays for a semiring anyway and gets a non-standard
  one.
- **`draw : Nat`** is index arithmetic in the question (anti-pattern 3), and MF has **no hygiene
  story**. Two call sites of `bestOf 3 q` produce the *same three questions*, hence the same three
  answers, silently. AF caught this and answered it with `under (fresh-name)`; MF's `Q` has
  `scope`, `prompt`, `draw` and no namespace, so the repair is not available without adding a
  field. This is a live defect, not a stylistic one.

### Test 3 — the tri-partite cost theorem is false as stated

MF §5 q4 defines the levels as *semantic predicates on traces*:

```
Pipeline p  :=  ∀ w w'. length (trace w p) = length (trace w' p)
```

and §8.2 Theorem (1) asserts: *"If `Batch p` or `Pipeline p`, then `cost` is an exact semiring
homomorphism and `∀w. costOf (trace w p) = cost p` — a single value, world-independent."*

Counterexample. Let `El c = Bool`, `μ q₁ ≠ μ q₂`, and

```
p = ask c >>= fun v => if v then ask q₁ else ask q₂
```

`trace w p` has length 2 in every world, so `Pipeline p` holds. But
`costOf (trace w p) ∈ { μc ⊗ μq₁ , μc ⊗ μq₂ }` depends on the world. The theorem is refuted, and
so is the table row "Pipeline: cost is a *value*". The semantic predicate and the syntactic witness
(free static arrow) do not coincide: `Pipeline` as defined admits selective and monadic terms that
the static-arrow fragment excludes. MF presents the correspondence as if it were established; it is
not stated, let alone proved.

The corrected theorem — which the synthesis needs — is a conjunction of two conditions MF keeps
apart:

> Exact static cost requires (i) the *question multiset* be world-independent, and (ii) the pricing
> `μ` factor through question *shape* rather than content.

MF admits (ii) in a caveat (§8.2) and then states the theorem without it. Under the corrected form,
`Batch` survives and `Pipeline` gives an exact *count*, not an exact bill.

Two further leaks in the same section:

- §7.4's lax bound `cost (p >>= k) ≤ cost p ⊗ (⊕ a. cost (k a))` ranges `⊕` over `El c`, which for
  free text is infinite — so it needs a complete semiring. MF §14.2(b) advertises "No star, no
  completeness, no leastness obligation" as a win over agent-cat. The completeness comes back in
  the one equation that matters.
- Everything in §§7–11 is stated and unproved (MF says so, §14.4). Against ~10k lines of proved
  Lean this is the honest accounting, but it means test 3 is a promise.

### Test 4 and the machine facts

`Code`, "a small universe of answer types … kept small so that `Dlg` lives in `Type` and worlds are
expressible" (§2.3). That is Lean's predicativity — a fact about the host's type theory — promoted
into the meaning. The doctrine's rule 2 says to suspect exactly this. AF and DC take
`Ans : Q → Type` and live in `Type 1` without complaint.

### What MF cannot express

No alternation. MF admits it (§14.4): "`run w` in my kernel is a *function*, so my language has no
nondeterminism operator". So fallback, beam search, weighted alternatives, and — critically — a
*gate that annihilates downstream cost* are all outside. Refusal-as-an-answer (§5 q8) reproduces
the outcome and not the cost collapse. This is the same hole AF records at §11.3.4 and the same one
DC closes for free with `Alternative` in a semimodule.

---

## 3. `rederive-algebra-first` (AF) — audit

### What is genuinely strong

- **The best justification discipline of the four.** AF is the only document that proves *why* a
  generator must be a generator, and the argument is exactly the doctrine's standard: a morphism
  equation that cannot otherwise close. `Const S` is Applicative and not Monad, so
  `⟦·⟧_{Const S}` exists on `W .ap` and cannot be obtained through `bind`; `Over S`/`Under S` are
  Selective and not Monads, so the finite-tree fold exists at `sel` and nowhere higher. *The tower
  is forced by which functors exist.* This is the single most valuable paragraph in the four
  documents and the synthesis must import it verbatim, because DC and CL assert the tower and AF
  derives it.
- **The failed-morphism ledger (§9, Attempts A–E)** is the method working as advertised, and
  Attempt E — failure as an `ExceptT` layer silently promotes every fallible applicative workflow
  to a grade at which exact costing is false — is a real result.
- **Adequacy as "a run exhibits a world"** (§7 q10) is the cleanest statement of the runtime
  theorem in the corpus after DC's.

### Test 1 — the meaning is stated and then abandoned

`⟦W g A⟧ = ∀ F ∈ Class(g), ((q:Q) → F (R q)) → F A`. Then §8.1: *"Take `W` as the inductive family
of §4 (initial), **not** the `∀F` type (final). Reasons: Lean has no parametricity theorem …"*

So the object named as the meaning is unusable in the host, and the object actually used is the
syntax, with equality defined as indistinguishability by every lawful `F`. That equality is a
quantification over a proper class of functors; AF then proposes `Quotient ≈` over it and calls the
congruence proofs "one line each". They are not, and the universe hygiene alone is a project. The
same critique lands on DC (§4 below) and is milder there only because DC quantifies over one class
rather than three.

More to the point for this lens: "a `W g A` is a natural transformation from oracles to answers,
uniformly in every lawful `F` of class `g`" is not a *simple mathematical object*. It is the
initial algebra with the words rearranged. Completion test 1 asks for comprehension; this answer
supplies a definition.

### Test 2 — two hygiene mechanisms, and a gensym in the client

`Q` carries **both** `ns : Namespace` and `draw : Draw`. Both exist for the same reason: to make two
things that would otherwise be the same question be different questions. And the hygiene story
(§6.3) is `under (fresh-name) w` — where the freshness comes from is never said. Either the author
supplies distinct names (anti-pattern 9: an invariant maintained by "callers must ensure…") or the
system supplies a gensym (state, at the surface, in a design whose entire premise is that the world
is stateless). The complexity went into the client, which is the doctrine's specific warning.

### Test 3 — the cost carrier is the design's weakest point

`S := Finset Q`, the free idempotent commutative monoid, with `bill price s = s.sum price` a
*derived function on the target, not a homomorphism out of it* (AF's own words, §5.2).

Three consequences AF does not price:

1. **There is no cost homomorphism into a number.** `bill (s ∪ t) ≠ bill s + bill t` unless `s` and
   `t` are disjoint. So the compositional reasoning an author actually wants — "this sub-workflow
   bills at most \$2, therefore the whole bills at most \$5" — is unavailable. AF's §5.4 convolution
   theorem states the disjointness hypothesis openly ("when `w₁` and `w₂` consult disjoint question
   sets"), which makes it anti-pattern 9: a side condition the type checker cannot enforce, guarding
   the headline theorem.
2. **Idempotence bakes a runtime policy into the meaning.** `w *> w` costs what `w` costs is true
   *only of a memoizing runtime*. AF calls this "the statement that a correct runtime consults each
   distinct question once" — i.e. the denotation has been chosen so that one implementation strategy
   is correct by fiat. That is step 9 violated ("never move the denotation"), and it is the same
   move MF makes more honestly by putting memoization into the adequacy hypothesis.
3. **`Finset Q` requires `DecidableEq Q`**, which MF §14.3 lists as one of the things its design
   *deletes*. The two "world is a function" derivations disagree about whether question equality
   must be decidable, and AF needs it.

### Test 4

`Grade` as a 3-element join-semilattice computed by the operations is the lightest grading in the
field and is not an impurity. AF's honest open points (§11.5) — the gate/annihilator question,
whether `Selective` survives dependent `R`, the width axis — are all real and are inherited by any
synthesis.

---

## 4. `rederive-decontaminate` (DC) — audit

### Test 1 — one meaning, one line

```
[[w]] : Oracle → V A,      [[w]] ω = the unique class morphism sending ask q ↦ ω q
Oracle = (q : Q) → V (Ans q)
```

Six types, six one-line meanings (§9). The meaning is uncomputable (an infinite sum in a complete
semiring) and says so. This is the only proposal whose stated meaning is the one actually used.

### Test 2 — one generator, eight class methods, zero invented operations

Nine morphism equations (Part 4). Eleven `agent-cat` constructors collapse to one generator plus
standard class methods, each with a one-line discharge. Three deletions are better than anyone
else's:

- **`gate` is the semimodule scalar action, and `failure` is the additive zero** — closing
  `acat-1xo` (the missing `zeroT`) and giving refusal an *annihilating* cost, which MF and AF both
  admit they cannot do.
- **`panel` is `traverse` then `foldMap`**, and the observation that `Panel.lean`'s 843 lines are
  the applicative instance of `VS S` written by hand — `conv_delta` is
  `liftA2 f (pure a) (pure b) = pure (f a b)`, `convFold_perm` is applicative commutativity — is
  the single most decisive anti-pattern-8 finding in the corpus.
- **`cost_is_meaning`**: `costOf w = [[w]] costOracle`. Cost is not a second artifact; it is the
  meaning at a different semiring. Best-case is min-plus, worst-case is max-plus, the interval is
  their product (the doctrine's own toolbox row, "an interval or bound ⇒ a product of tropical
  semirings"), and possibility is Bool. **One fold, four analyses, no bespoke carrier.** Against
  MF's invented choice-semiring and AF's non-homomorphic `bill`, this is not close.

Also derived rather than assumed: the arrow layer, `Static i o := WApp (i → o)`, with `Category`,
`Strong`, `Choice` free from `Applicative` — recovering the shape `agent-functor` wanted `arr`-
freedom for, *from the type*, rather than from a prohibition.

### Test 3 — adherence is one line, and this is the strongest structural argument in the field

> `ρ ∘ runW` and `[[·]]_ω` are both class morphisms `W → V`; `W` is free on `Sig`; they agree on
> generators; therefore they are equal by initiality.

The owner's requirement — "proofs that each operation commutes with the denotation" — is the eight
per-operation corollaries of one initiality argument. DC's observation that *"an eleven-constructor
GADT that is free over nothing requires a twelve-case induction for every such theorem, and every
new constructor invalidates every existing proof"* is the correct explanation of why `Meaning.lean`
is 2831 lines.

Equality is the kernel of the meaning, hence a congruence for every constructor with no proof —
which is exactly the diagnosis of agent-cat's four missing congruences (`retryT`, `fanT`, `bindT`,
`shareT` — the last impossible in kind), all of which are missing because `WEqR` is `∃σ. …` and not
the kernel of anything.

### Test 4

`[[·]]` is an uncomputable infinite sum; caching, scheduling, session reuse and content-addressing
are refinements. And DC is the only document that *refuses* to make caching semantic: where MF
concludes that the runtime must memoize for adequacy to have content, DC concludes that a
content-addressed cache is **sound for `w` iff `[[w]] = [[share-normal-form of w]]`** — a proof
obligation, not an identity. Given that MF's conclusion requires the world to be a function and DC's
does not, DC's is the more general statement and the one that keeps efficiency out of the meaning.

### Anti-pattern hits

Three, all local, all fixable — enumerated in §6 below.

---

## 5. `contamination-ledger` (CL) — audit

CL is the best *diagnostic* in the set. Its ranked list of ten load-bearing inherited verdicts,
each with `file:line` and each with the alternative stated, is the document a rebuild should be
planned against. Three of its findings are independently decisive:

- **`fanT n` truncates the meaning** so that "a workflow given eleven files when it declared eight
  silently reviews eight" — a scheduler cap promoted into the denotation, and the sole source of
  `Frag`'s entire numeric payload. Everything about `Frag.copies`, `scale`'s `max 1`, `peak`, and
  `peak_not_le_grade` is downstream of that one truncation.
- **`retryT`'s meaning was truncated in order to make an index true** — "the meaning is truncated in
  order to make an index true" is step 9 violated, stated precisely.
- **`Runner` displaced `Env`, and the design's central theorem went with it**: you cannot put a
  measure on a type of interpreters, so §3's promised projection π is not merely unproved but
  unstateable. This is the sharpest causal claim in the corpus.

### But the constructive half (§4) self-refutes its own thesis

CL's thesis is that agent-cat's error is *a world indexed by syntactic positions*. Its replacement:

```
World Q = (h : History) → ∀ {α}, Q α → α        -- §4.1
[[ask q]]_ext ω = ω h q                          -- "h the history at this point"
[[t >>= k]]_ext ω = [[k ([[t]]_ext ω)]]_ext (ω after t)
```

A history *is* a semantic position. Under this meaning the denotation of a subterm depends on the
prefix that precedes it, so `⟦·⟧` must thread state, an order has entered the model that the domain
does not have, applicative commutativity is lost, and the parallel-scheduling licence goes with it.
This is exactly AF's Attempt B, diagnosed there as *"a tape has entered the model"* (anti-patterns
4 and 6) and rejected. CL replaces a syntactic index with a dynamic one and keeps the cost.

Two further regressions in §4:

- **Two meanings are retained** (`[[·]]_S` into `Mat S Unit α`, and `[[·]]_ext` into `World ⇀ α`),
  with the projection π between them listed at §4.4 as a thing the rebuild "must prove". DC's
  Part 1 #2 names this as failure mode: *"Two meanings for one type. Elliott's rule is one meaning;
  two incomparable ones means neither is *the* meaning."* CL reproduces the structure it condemns.
- **Three fragment-specific meanings.** `[[t : Ap Q α]] = Σ (qs : List Q), (Answers qs → α)` is the
  free applicative's *normal form* offered as the meaning — anti-pattern 2 again — and it is a
  different meaning from the `Sel` and `Free` rows, so equality is not uniform across the tower.
- **`⊥` returns**: `[[empty]]_ext ω = ⊥`, partiality in the meaning, against DC's "partiality is
  missing mass" and MF's "no partiality at all".

CL should be read as the audit it is, and its §4 discarded.

---

## 6. Ranking

**1. `rederive-decontaminate`.** One meaning, one generator, eight standard class morphisms,
adherence by initiality in one line, equality as a kernel hence a free congruence, cost as the
meaning at another semiring, and the only design that keeps `agent-cat`'s genuinely forced
mathematics (complete semirings, the star, `LastOpt`, `pin`, the convolution collapse) as *derived*
objects instead of discarding it. It also contains the other three proposals as its deterministic
instance.

**2. `rederive-meaning-first`.** The best single insight in the field — the object that decides
equality must be the object that records what was asked, so cost cannot disagree with extension
about sharing — plus the strongest argument for higher-order continuations. Ranked below DC because
its meaning *is* its syntax with a lemma bolted on, its cost carrier is invented, its central cost
theorem is false as stated, and it cannot express alternation or an annihilating gate.

**3. `rederive-algebra-first`.** Contributes the one thing the winner is missing: a *proof* that
the App/Sel/Mon tower is forced, by exhibiting the functors that exist at each level and not above.
Ranked below MF because its stated meaning is abandoned at implementation time, its cost carrier
admits no homomorphism into a number, and it carries two overlapping hygiene mechanisms plus an
unspecified gensym.

**4. `contamination-ledger`.** Indispensable as a diagnostic, self-refuting as a proposal.

---

## 7. Residual impurities in the winner, which the synthesis must fix

Seven, ordered by how much they cost.

### I1 — The domain's most common pattern has no home, and this is the field-wide gap

The owner's own example is *"two reviewers sharing one reading of a style guide"*: read the guide,
then build two reviewer prompts **out of** that answer. In DC that is `bind`, so the workflow is
`WMon` and gets no static analysis at all — for the pattern that dominates real workflows. MF is
right that this level exists and is the free static arrow (`Category` + `Cartesian`, Hughes's
`Arrow` without `app`): shape fixed in advance, content flowing along wires. DC's derived
`Static i o := WApp (i → o)` is *not* this level — its leaves are fixed questions, so it is
batch-with-plumbing.

The synthesis must either admit the static-arrow level or state honestly that prompt-content
dependence is monadic and that only the *count* survives. It must not do what MF does, which is
admit the level and then claim exact billing for it. The corrected theorem:

> **Exact static cost** requires (i) the consulted question multiset be world-independent, **and**
> (ii) the pricing `μ` factor through question shape rather than content.
> `Batch` gives both. The static-arrow level gives (i) only, hence an exact *count* and a bounded
> *bill*. Per-call pricing and latency satisfy (ii); per-token pricing does not.

Note that this is the honest residue of `agent-cat`'s `bounded n` grade, which all four
re-derivations declared dead. Something real was being pointed at; the number was the wrong way to
point at it.

### I2 — `Weighting` is a bespoke class asserting its laws as axioms

DC defines `class Weighting extends Monad, Alternative` with `comm`, `distrib`, `zero_bind` as
*fields*. That is anti-pattern 10 verbatim: algebraic laws asserted as the specification, with
nothing to check them against. The object DC actually wants has a name and a denotation: the **free
`S`-semimodule monad** for a complete commutative semiring `S` — equivalently, a commutative monad
in Kock's sense whose Kleisli category is a Markov/CD category. Derive `comm`, `distrib` and
`zero_bind` as lemmas from `VS S A = A → S`, and require the class only where genericity over `V`
is actually used (`PMF`, `Giry`). Naming the standard structure also buys the copy-non-naturality
statement of `share_ne_dup` from the literature instead of by hand.

### I3 — The carrier is not yet a definite object

`VS S A = A → S` needs a complete semiring to sum over infinite answer types, and `pure = δ` needs
`DecidableEq A`. DC gestures at `PMF`/`Giry` "where measurability matters", but `PMF` has no
`Alternative`, so the alternation half of the design does not survive that substitution. The
meaning is currently a schema with an unfilled hole. Pick one: the free complete-semimodule monad
(and accept `DecidableEq` on answers, or move to `Finsupp`-style support), or a measure monad (and
lose `<|>` and the annihilating gate). This is the one place where DC fails completion test 1 in
substance rather than in presentation.

### I4 — The acting-leaves recommendation imports a tape into the specification

DC §q7 recommends, *as the specification*, `Oracle := (q:Q) → World → V (Ans q × World)`. That is a
state monad in the meaning, applied uniformly, which destroys applicative commutativity and the
reordering licence for *every* leaf, not only for acting ones — DC's own §q6 caveat asserts the
withdrawal is selective, but the type is not. It also reintroduces the ordering that AF's Attempt B
rejects and that CL's §4 falls into.

MF §12 prices this correctly and should be adopted instead: keep the passive kernel as the
specification, split the signature `Q = Consult ⊕ Act` if and when a domain requirement pays for
it, and print the ledger (memoization unsound on `Act`; `⊛` on two `Act`s no longer licenses
concurrency; the equational theory does not survive). *A workflow decides; it does not act.*

### I5 — Three carriers plus two inclusions relocates work into clients

`WApp` / `WSel` / `WMon` with `liftAS` and `liftSM` means every library function picks a level,
every composition inserts a coercion, and `do`-notation is unavailable at the two levels the whole
design exists to make attractive. DC's own strain note #5 admits it and calls the mitigation an
"applicative-do / selective-do elaboration". Unelaborated, this is the doctrine's "where did the
complexity go?" answered against the design.

AF's `Grade` — a three-element join-semilattice, *inferred* by the operations, with `⊔` and nothing
else — is the better presentation of the same content: one type family, no coercion noise, no
arithmetic, and grade-polymorphic combinators so library code does not force a level it does not
need. Take AF's index and DC's meanings.

### I6 — The tower is asserted, not derived

DC states `App ⊂ Sel ⊂ Mon` and gives the table of what each level makes visible. AF *proves* why:
`Const S` is Applicative and not a Monad, `Over S`/`Under S` are Selective and not Monads, and at
`bind` no `Const`-like functor can exist because the continuation must consume an answer. Import
that argument — it is what turns the level index from a convention into a theorem, and it is
precisely the content of owner directive (1). The accompanying obligation, which CL §4.4 names and
nobody proves: *the analysis homomorphism exists for `Ap` and `Sel` and provably does not for
`Free`.* That non-existence result is the honest replacement for `Frag`.

### I7 — Scope is done twice, and the transcript is missing

- **Scope twice.** DC puts scope in `Q` (correct — what determines the answer belongs in the
  question) *and* adds a Reader layer `Scoped G A := G → W A` at the surface for ambient overrides.
  MF's `under σ : Sig → W A → W A` — the unique monad morphism extending `ask ∘ σ`, hence a monoid
  action of `(Sig, ∘, id)` — is one mechanism, gives `under 1 = id` and `under σ ∘ under τ =
  under (σ ∘ τ)` for free, and costs no extra layer in any type. Take `under` as a derived fold and
  delete the Reader stratum. `LastOpt` survives either way and is a genuine Mathlib gap.
- **No transcript.** DC's only quantitative observable is a semiring fold; MF's `trace` is what an
  adequacy theorem matches against a live run and what a user debugs. This is cheap to recover
  inside DC's own frame — the transcript is `[[·]]` at a free-monoid-valued carrier — and doing so
  keeps "one meaning, many carriers" intact while regaining MF's best asset.

### Also carry forward, unchanged

`pin = Function.update` on the oracle (fork, resume, fixture-edit as three uses of one operation);
`LastOpt` and per-axis innermost-wins; `CompleteCSemiring`/`StarSemiring`/`Star.lean`'s
`retry_fixed`/`retry_least`; `Instances.lean`'s four carriers; and the one empirical axiom, stated
as a hypothesis of adherence rather than hidden in the meaning: *each invocation of `run q` has law
`ω q`, and distinct invocations are independent.* `agent-functor` buys the second by
fresh-session-per-leaf, which is correct engineering; the point is that it is a hypothesis of a
theorem, not a fact about the meaning.

---

## 8. What none of the four has

1. **A proof that the semantic level predicates and the syntactic fragments coincide.** MF defines
   levels on traces and witnesses them with free structures; AF and DC define levels as which type
   a term inhabits. Nobody proves the free static arrow is exactly the world-independent-length
   fragment, or that the free selective is exactly the finitely-branching one. Until that is
   proved, the tower classifies *terms* and the cost theorems must be stated about terms, not about
   meanings. (DC's strain note #3 says this and is the only document that does.)
2. **A free `Selective` in Lean.** All three constructive proposals write `FreeSelective Sig` as if
   it were available. It is not in Mathlib, its normal form is the load-bearing object for the
   entire branching cost story, and with dependent answer types `Ans : Q → Type` the `A ⊕ B` shape
   of `select` likely needs a Σ-variant whose `Over`/`Under` instances must be re-derived rather
   than imported (AF's open point 5). This is the largest unbudgeted item in any of the plans.
3. **An account of data-dependent width.** `fanT n` over a list whose length the answers decide is
   a real resource question, orthogonal to the sequencing tower. CL correctly kills the syntactic
   bound (it truncates the meaning); AF correctly notes the axis is orthogonal and suggests
   `Grade × Frag`; nobody has the theory. The honest interim answer is CL's: the cost of a traversal
   is a *function of the input*, and if an a-priori number is wanted, bound the input **type**, not
   the meaning.
4. **Anything that would make `agent-cat`'s `Meaning.lean` reusable.** Every proposal deletes the
   syntax stratum, so the ~1000 lines of site/key/relabelling machinery and the ~900 lines of
   `WEqR` go regardless of which wins. What survives is `Matrix`, `Semiring`, `Star`, `Gate`,
   `Instances`, `Keys`, `Context`, `Env.pin`, and `Scope.LastOpt` — the mathematics, none of the
   syntax. That is the same conclusion by four independent routes, and it is the one place where
   convergence is worth reporting.
