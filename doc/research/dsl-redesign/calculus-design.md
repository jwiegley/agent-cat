# Round eighteen: the static function calculus over the do-notation core

*Design of record CANDIDATE for round eighteen, 2026-08-15. Written against
`expr-design.md` (the approved round-17 page, whose D1–D21 are inputs, not
questions), `GRAMMAR.md` (rounds 10–17), `fn-import-design.md` +
`fn-import-attack.md`, `block-syntax.md`, `example/{harden,library,
harden-imported,hello,ill-typed}.wf`, and the implementation in
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean` + `Agentic/Core/Dsl.lean` +
`Agentic/Core/Explain.lean` + `Agentic/Core/DslFlagship.lean` +
`test/{DslSmoke,CliSmoke}.lean`.*

*This page supersedes `calculus-design-draft.md`, which was written before the
adversarial pass. Sixty findings from three attackers — theorems and
architecture, parsing and grammar, types and normalization — are applied here;
§0.2 names the three that were fatal and what each cost.*

*Per the owner's ruling — **one design, then one campaign** — this page covers
the round-17 core and the calculus together. Round 17 has not shipped; nothing
in it is legacy. Where this page and `expr-design.md` disagree, this page is the
proposal and `expr-design.md`'s decision is named explicitly as superseded, with
its cost saving recorded (§6, §10.6).*

*Two owner rulings of 2026-08-15 govern the page and are cited where they bite:
**ruling 8**, that `>>>` is bind-shaped Kleisli composition — `(f . g) x == f (g
x)`, `(f >>> g) x == f x >>= g == y <- f x; g y`, with effect-on-the-left as the
degenerate arrow and `.` over questions refused naming `>>>` (§5.1, §5.2, §3.5);
and **ruling 9**, that the Haskell Report is the default answer to every syntax
question, so the standard operator vocabulary is in by default and only genuine
collisions with this language's own commitments return to the owner (§0.3,
§5.1, §12).*

---

## 0. The claim, in one paragraph

The language already has two levels; it has simply never said so. Level one is
what runs: `Plan`, the four kinds, questions, sharing, cost — and round 18 does
not touch one byte of it. Level two is what the author writes: names,
applications, and now lambdas, composition and pipelines — a **simply-typed
lambda calculus over the four kinds, with no fixpoint, over a stratified table**,
which is therefore strongly normalizing, and which round 18 **eliminates
entirely at elaboration**. Function types never reach `Code`; closures never
reach `Plan`; the normal form of every accepted program is a term of today's
unchanged `Raw`, so the round-17 survival argument runs a third time and every
theorem, kernel proof and flagship pin stands. What the calculus buys is the
owner's four directives — Kleisli pipelines, function composition, lambdas,
"the whole deal" — and what it costs is a real expression parser: this is a
parser rewrite, and §10.6 prices it in days rather than pretending otherwise.

The three things this page had to decide before it could be written, and did:
**there is only one arrow in this language and it is effectful** (§5.1), which is
why `.` and `<<<` can coexist without an effect system; **`function` and `let`
are two strata, not two spellings** (§2.3), which is what keeps `FnEntry`
first-order and unchanged while still giving the owner higher-order functions;
and **not every well-typed normal form has a spelling in `Raw`** (§1.5), which
is the thing the attack found first and which the north star survives only
because the gap is closed by a refusal rather than by a new constructor.

### 0.1 Decisions taken in this document

| # | Question | Decision |
|---|---|---|
| C1 | The architecture | **Two levels.** Runtime = today's `Plan`. Static = an STLC over the four kinds, eliminated by normalization in the front end. Function types never exist at run time. |
| C2 | Normalization strategy | **One post-order traversal per statement.** Beta is the only rewrite and hoisting is part of it: a **source** argument is hoisted to a binder before substitution; every other argument is substituted as a term. Hoists are **positional**, not privileged. Then the boundary checks: C0 vacuity, then saturation (§1.2). |
| C3 | Termination | **A node budget** (`maxNormNodes := 65536`), charged per node the normalizer constructs, refused with a count and a position, in the spirit of `maxRevisions`/`maxQuestions`. Strong normalization is argued, **not proved** (§1.3). |
| C4 | The north star | **Normalize in the front end into today's unchanged `Raw`.** No `Raw`, `Plan`, `Code`, `Ctx` or `FnEntry` change (§2.1). |
| C5 | The higher-order fork | **The stratum split.** `function` = runtime, first-order, one `FnEntry`, unchanged. `let` = static, any simple type, normalized away per site. A function-typed parameter is legal **only on a `let`**. Options (b) refuse and (c) generalize `FnEntry` recorded and refused (§2.3). |
| C6 | Where `let` stands | **A header, beside `define` and `function`; top level only; closed** (it may mention only headers above it), and its body **stored fully qualified** at declaration. Statement-position `let` refused. `let` joins `stmtWords` (§7.2). |
| C7 | Application | **Left-associative juxtaposition, tightest.** Bounded above by the head's **syntactic** arity — which every head form has — below by the stopper set, with round 16's one-token `<-`/`:` probe promoted from refusal to decision, and a fourth bound: an expression continues while the next token is an operator (§3.3). |
| C8 | A function name in argument position | **A function or `let` name is an atom only in head position.** Elsewhere it is `(f)` or `\x -> f x`. As the **right operand** of an operator it reads zero arguments (§3.4). |
| C9 | Fixities | `.` **infixr 9**; `<<<` `>>>` **infixr 1**; `>>=` **infixl 1**; `=<<` **infixr 1**; `$` **infixr 0** — Haskell's own numbers (§3.5). |
| C10 | `.` versus `<<<`/`>>>` | `.` composes **arrows only**: `(f . g) x = f (g x)`. `<<<`/`>>>` are **Kleisli**: `(f >>> g) x = f x >>= g`. Each takes an **arrow or a value** on the flowing side. This is owner ruling 8, exactly (§5.2). |
| C11 | Sections | **Refused**, with the lambda named as the escape (§3.7). |
| C12 | Lambdas | `\x -> e`, `\x y -> e`, `\(x : t) -> e`. A lambda's body is **one expression**. Legal at every expression position, refused at every runtime position (§3.6). |
| C13 | `->` | **Triple duty** — result kinds, lambda bodies, function types — and it parses, by position, with no lookahead (§3.8). |
| C14 | `ret` / `pure` / `return` | **Not added.** A body's final expression is its answer (round-17 D1). One recognized-mistake diagnosis at the word, permanently (§3.9). |
| C15 | Types | `type ::= kind \| type "->" type \| "(" type ")"`, right-associative. A bare parameter is `text` (D16 carries); a **function-typed parameter is always annotated**; an arrow's **argument** may be only `text` or `verdict` (§4.1). |
| C16 | Function-typed results | A `function`'s result stays a **kind**. A function that answers a function is a `let` (§4.2). |
| C17 | Partial application | **Legal statically, refused at every runtime position.** "Saturated" is defined; the round-16 objection ("a `Sub` that is not yet total") is answered rather than repeated (§4.3). |
| C18 | The typing discipline | **Synthesis up, checking down**, monomorphic, no unification, no Hindley–Milner, no polymorphism. Stated as a refusal so nobody adds one later (§4.4). |
| C19 | The bang `!(…)` | **Dropped before it ships.** Round-17 D3, D4, D5, D11 are superseded by the calculus; D6, D7, D8, D9, D15 survive restated over expressions (§6). |
| C20 | The dot, lexically | **Qualification iff the dot is immediately flanked by identifier characters**; every other dot is the composition token. Implemented as a **dedicated lexer branch**, not a `punctChars` entry, so `a.b.c` stays refused (§8.1). |
| C21 | `$`, lexically | **`$` immediately followed by an identifier character is a `$label`**; otherwise it is the application operator. Byte-compatible (§8.3). |
| C22 | `\` | A lexeme outside prompt text. **Prompts are unaffected**, with the line references (§8.4). |
| C23 | `>>>` / `<<<` / `>>=` / `=<<` | New tokens; the stray-`<`, stray-`>` and stray-`-` diagnoses extended or reworded (§8.5). |
| C24 | Cost and trace | Priced on the **normal form**; `blockAsks`/`bodyAsks`/`rhsAsks` unchanged; post-order carries; **a question's position is its use site**, with the `let`'s body position carried as provenance (§5.4). |
| C25 | Substitution sharing | **Three lines**: two questions written are two events; one **source** argument substituted twice is one event; one **arrow** argument applied twice is two events. Divergence 3, stated as a language rule (§5.5). |
| C26 | Temporaries | Minting is keyed on the **inlining chain**. Round-17 D10's already-qualified minting, `Dsl.isTemp` and `showName` carry, and now also serve static-binder renaming (§8.8). |
| C27 | Where the calculus lives | A new front-end module `Agentic/Core/Dsl/Norm.lean`. `Syntax`, `Check`, `Dsl`, `Explain`, `DslFlagship` untouched but for round 17's seven `showName` sites (§10.1). |
| C28 | The flagship | **`example/harden.wf` stays byte-identical**; the showcase is the pair (round-17 D21 carries) (§10.5). |
| C29 | The CLI | **No new subcommand.** `agent-cat plan` already names every question's rung and position; a normal-form dump is recorded as considered and refused (§5.6). |
| C30 | Round 17 | **D1, D6, D7, D8, D9, D10, D12, D13, D14, D15, D16, D17, D18, D19, D20, D21 all stand**, four of them restated for the new trigger. D2 stands in strengthened form. D3, D4, D5, D11 are superseded by C19 (§6.3). |
| **C31** | **Vacuity** | **A normal form that asks nothing is refused where it was written.** A bind right-hand side or a statement position whose normal form is a bare name or a literal is refused at the source position, naming the cause. A body's final expression may normalize to a **name**; to a **literal** it is refused (§1.5). |
| **C32** | **Position discipline** | **Every `SExpr` node carries a `Pos`; substitution never overwrites one.** A refusal on a normalized term reports the node's own position, and names the inlining that brought it there (§1.4). |
| **C33** | **`>>=` and `=<<`** | **Added**, at Haskell's fixities, because ruling 8 defines `>>>` by `>>=` and ruling 9 makes Haskell's vocabulary the default. **`>=>` and `<=<` are not added: in a one-category language they *are* `>>>` and `<<<`.** The operator set is the one sanctioned multi-spelling region of the language (§5.1, §5.2). |
| **C34** | **The static table** | **`let`s live in their own table**, not in `fnAr`, with a synthesized type, a closed body and a pre-priced question count. `fnAr` widens to signatures. `freshOfTables` gains a fourth clause (§4.5). |
| **C35** | **Hoist emission** | **Every hoisted temporary is emitted annotated** with its synthesized kind, so kind inference is never consulted for one. A hoist with **zero** uses in the normal form is emitted as an **`.act`** (or `.callStmt`) — the language's existing spelling for "asked, answer discarded" (§1.2). |
| **C36** | **Static binders** | **Minted to temporaries at parse time**, by C26's mechanism. Rule 6 does not apply to them: shadowing is vacuous by construction, not enforced (§8.8). |

### 0.2 What the adversarial pass changed

Three findings were fatal — they said, correctly, that the draft as written could
not be implemented as described. Each is repaired in place, and the repair is
named here so a reviewer can check it rather than take it on faith.

| Fatal | What was wrong | The repair |
|---|---|---|
| **Normal forms with no `Raw` spelling** | `RawRhs ::= ask \| panel \| call` (`Syntax.lean:212–225`) has **no constructor for a bare name or a literal**. `let id = \x -> x` followed by `x <- id draft` normalizes to `x <- draft`, which cannot be emitted. The north-star claim "the normal form of every accepted program is a term of today's unchanged `Raw`" was therefore false as stated. | **C31, the vacuity refusal** (§1.5), run before saturation, at the position of the source expression, naming the cause. `Raw` is not reopened; the claim is narrowed to "every *accepted* program", and acceptance now has one more clause. |
| **The phases contradicted each other** | C2 declared Phase A (beta) strictly before Phase B (hoisting), and then said in its own substitution rule that a base-kind argument is "hoisted to a binder *before* substitution" — hoisting inside Phase A. The two readings give different question **orders**, and §5.4 stated only one of them. | **C2 restated as one traversal, one rule** (§1.2): hoisting *is* part of the beta rule, and a hoist takes its position in the statement's post-order rather than at the head of a pending list. |
| **The fuel bounded the wrong quantity** | `maxNormSteps` counted beta steps, but one step copies its argument once per occurrence, so a chain of static functions applied to static functions doubles the term at each step while the step count grows linearly. The bound was not the resource. | **A node budget** (§1.3): `maxNormNodes`, charged per node constructed, so substituting a term of size *s* into *n* occurrences costs *n·s*. The refusal is reworded to the real cause, because the draft's two escapes were both non-escapes. |

The other fifty-seven findings are applied throughout. The nine that changed a
decision rather than a wording are: signatures instead of arities in `PEnv`
(§4.5); `let`s out of `fnAr` and into their own table (§4.5); annotated hoist
emission (§1.2); minting keyed on the inlining chain (§8.8); the source
alternative restored at every runtime position and `app` split into head and
argument (§3.1); `$label` confined to the `call` production (§3.1); a dedicated
lexer branch for `.` (§8.1); the fence-close follower set widened to the operator
starts (§8.7); and the nine-spellings battery decided on **traces** rather than on
`Raw` (§5.3).

One finding is a compliment worth recording, because it moves where the page's
confidence should sit: the north star was verified mechanically rather than
taken on assertion — the fourteen level lemmas induct on `RawBlock`/`RawBodyStmt`
/`RawFn` constructors and discharge by `split at h` on `checkBlock`/`checkBody`
/`bindForm`/`rhsPlan` clauses, and none of them mentions the parser;
`Explain.lean`'s six front-end parity theorems `cases`/`split` on
`parseProgramWith`'s result and never look inside it. **Theorem survival is the
easy half of round 18 and the proofs confirm it.** The hard half is §§1, 3, 4 and
8, which is where fifty of the sixty findings landed, and this page's confidence
is redistributed accordingly.

### 0.3 The posture on syntax, per ruling 9

> **The Haskell Report is the default answer to every syntax question.** Where
> Haskell has a spelling, this language takes it — fixities, associativities,
> the operator vocabulary, the lambda, the `$`. Only a genuine collision with
> this language's own commitments — the dot rule, `$label`, fenced prompts,
> braces-not-layout — is even a candidate to come back to the owner. Four such
> collisions arose; §12 records that each was resolved in this page's own terms,
> so **none survives as an open question**.

That is why `>>=` and `=<<` are in this round (C33) and why `>=>`/`<=<` are not:
Haskell has them because it has more than one category, and this language has
exactly one, in which `>=>` **is** `>>>`. Adding both spellings would be the
two-spellings violation the noise audit exists to refuse — see §5.1, where the
one exemption the operator set enjoys is stated rather than assumed.

---

## 1. The two-level architecture, stated as the thesis

### 1.1 The thesis

> **Level one is what runs.** `Plan Γ A` with five formers, four writable; the
> four kinds `Code = text | verdict | flag | receipt`; `El .ack = Unit`;
> questions as term-level shapes; sharing by the question; `blockAsks` as the
> price. Round 18 changes nothing here — not `Code`, not `El`, not `Ctx`, not
> `Env`, not `Expr`, not `Sub`, not one former.
>
> **Level two is what the author writes.** A simply-typed lambda calculus whose
> base types are the four kinds and whose arrows are `τ → σ` over them. It has
> no fixpoint former, and its table is stratified — a header may mention only
> the headers above it, which is the same rule that already refuses recursion
> (`fn-import-design.md`: *"arity-directed parsing requires functions before
> uses, which is the same stratification that refuses recursion"*). It is
> therefore strongly normalizing, and round 18 **normalizes it away** during
> elaboration.
>
> **The join.** After normalization, every expression standing at a runtime
> position has a base kind, is a saturated source, and — by C31 — is not a bare
> name or a literal. That is exactly the grammar of today's `Raw`. **Function
> types never reach `Code`, so closures never reach `Plan`, so `Plan.dyn` stays
> quarantined and empty.**

The last sentence is the whole safety argument and it should be read twice. A
runtime closure in this system would have to be a value of function type sitting
in an `Env`, which would require an arrow constructor in `Code` and an arrow case
in `El`, which would make `Q c` — the question shape at kind `c` — meaningful for
functions, which is `Plan.dyn`. The owner's STATIC ruling is not a preference
about implementation strategy; it is the only reading under which the calculus
does not reopen the quarantine. §2.3 is where that bites hardest.

**The join's third clause is new, and it is the fatal finding's residue.** The
draft claimed only the first two clauses and was wrong: a base-kinded,
redex-free normal form can still be a bare name, which `RawRhs` cannot spell.
§1.5 is that clause, stated as a refusal.

### 1.2 The normalization strategy: one traversal, one rule (C2, C35)

The draft had three phases in a load-bearing order and the order was
self-contradictory. Round 18 has **one traversal**, and the rule that decides
what a question costs is part of the rewrite rather than a pass after it.

**The rewrites.**

```
(\x -> e) a                 ⟶  e[x := a]      (with the hoist rule below)
(f . g) a                   ⟶  f (g a)
f $ a                       ⟶  f a
f >>> g                     ⟶  \x -> g (f x)  -- Kleisli, ruling 8
v >>> g                     ⟶  g v            -- v at a base kind
m >>= g                     ⟶  g m            -- m at a base kind
g <<< f                     ⟶  \x -> g (f x)
g <<< v                     ⟶  g v
g =<< m                     ⟶  g m
h  (a `let` or a lambda applied to its full arity)  ⟶  its body, substituted
```

> **The substitution rule (the one that decides what a question costs), on the
> honest criterion.**
>
> **An argument that is a *source* — an `ask`, a `panel`, or a saturated `call` —
> is hoisted to a binder before substitution, and the binder's name is
> substituted. Every other argument — a name, a literal, a lambda, a partial
> application — is substituted as a term.**

This replaces the draft's "by-value at the four kinds, by-name at function
types", which was not implementable: a base-kind argument that is a **name** or a
**literal** *cannot* be hoisted, because there is no `RawRhs` for one
(`Syntax.lean:212–225`) — it must be substituted. The corrected criterion is
**syntactic**: it looks at the argument node's own head constructor, not at its
type and not at what it does. That is cheaper than the type test the draft
proposed, and it is what keeps the discipline "very limited".

`(\x -> compare x x) (ask q)` under substitution-of-the-term would write the
question twice; under D12's sharing rule that is one answer but **two events and
`billFresh` 2**, which is a different transcript from the one the author wrote.
Hoisting the source first makes it one event, which is what `x <- ask q` means.
§5.5 states the consequence as a language rule in three lines, because it is the
one place where the calculus can change what a program *costs* without changing
what it *says*.

> **The hoist rule, and it is positional.** A source standing anywhere but a
> statement position, a binder's right-hand side, or a body's final expression is
> lifted to a fresh binder at the head of its enclosing statement, and replaced
> by that binder's name. The traversal is **post-order over the reduced
> statement**, and a hoist is emitted **when the traversal reaches the first
> occurrence of its binder** — not at the head of a pending list, and not in
> reduction order.

That last clause is the repair for the phase contradiction. Worked, because it
is the case the two attackers disagreed about:

```
(\x -> g (ask q1) x) (ask q2)
```

`ask q2` is a source, so it is hoisted before substitution and its binder is
substituted for `x`. Under the draft's Phase-A-then-Phase-B reading, `q2`'s bind
is emitted first, because Phase A ran to completion before Phase B looked at
`q1`. Under the positional rule, the post-order walk of `g (ask q1) t` reaches
`ask q1` first and `t` second, so:

```
!L1:C1 <- ask q1
!L2:C2 <- ask q2
g !L1:C1 !L2:C2
```

— which is the order the words are written on the page, which is what §5.4's
order rule has always said, and which is what a reader would have written by
hand. **The by-value hoist is a sharing commitment, not an evaluation-order
commitment**; the order is the page's and the sharing is by-value, and saying so
in one sentence is what makes C2 and C24 agree.

**The one divergence this creates, named rather than buried.** When a static
function uses its arguments in a different order than they are written, the
questions are asked in **use** order, not in written order: `let swap = \a b ->
g b a` applied to two sources asks the second-written one first. It is the price
of "post-order of the normalized statement", it is visible in `agent-cat plan`,
and it goes in `GRAMMAR.md`'s hazards beside the other three (§5.4).

**Hoist emission (C35), which kills the inference fragility.**

> **Every hoisted temporary is emitted annotated.** The hoister already knows the
> source's kind — it is the callee's result kind, the `ask`'s kind, or `verdict`
> for a panel — so it emits `RawBlock.bind t (some c) …` at **every** lift site,
> not only where inference would otherwise fail.

The payoff is that hoisted binds are independent of kind inference entirely.
`bindKind`'s first-ground-use search (`Check.lean:265`) is never consulted for a
temporary; the round-8 ground-free refusal cannot fire on one; and the draft's
claim in §4.4 — that a hoisted temporary is "used exactly once, at a ground
site" — stops being a load-bearing invariant that by-value hoisting breaks and
becomes an observation that no longer has to be true.

> **A hoist with zero uses in the normal form is not emitted as a binder.** It is
> emitted as an **`.act`** when the source is an `ask` and a **`.callStmt` /
> `.callS`** when it is a call (`Syntax.lean:248–274`, `:285–292`) — the
> language's existing spelling for *asked, answer discarded*, which carries kind
> `receipt` by position and needs no binder at all.

`(\x -> "hello") (ask q)` and a `let` whose lambda drops a parameter therefore
ask their question, discard the answer, and read on the page exactly as a
statement-position ask does (GRAMMAR rule 11). **The one exception, checked
against the tree:** a discarded **panel** keeps its annotated binder, because
`RawBlock` has `.act` for an ask and `.callStmt` for a call and **nothing for a
panel**, and C4 forbids adding one. That is one sentence of honest residue and
it is preferable to a new constructor.

**Then the boundary checks, in this order.** They are checks, not rewrites, and
neither can produce a redex:

* **C0, vacuity** (§1.5) — a runtime position whose normal form asks nothing.
* **Saturation** (§4.3) — every runtime position holds a base kind. Eta is
  applied here and only here: a name of arrow type standing where an arrow is
  expected needs no expansion, and a name of arrow type standing at a runtime
  position is a **refusal**, not an eta-expansion site. So eta appears in the
  calculus as the *equation* `f ≡ \x -> f x` that licenses `(\x -> g x) y ⟶ g y`
  (the owner's directive 3, which is really beta), and nowhere as a rewrite the
  normalizer must search for.

**Why reduction precedes hoisting inside the traversal.** Hoisting inside an
unapplied lambda body would place a question outside the block that will
eventually contain it. Reduce at a node before you hoist from it, and every
lifted binder lands in the block the author wrote.

**Lifting never crosses a `{`** (round-17 §2.2, §5.3 divergence 2): an expression
inside an arm lifts to the head of the statement inside that arm, and its
question is asked only on that path; an expression in an `if` subject lifts
before the `if`. `blockAsks`'s per-branch tree keeps its shape
(`Check.lean:877–890`).

### 1.3 Termination, and the node budget (C3)

**The argument.** The static term algebra is simply typed (§4), has no fixpoint
former, and its table is stratified: a `let` or a `function` may mention only
headers declared above it (`Parse.lean:1189` builds the header tables
incrementally; `resolveFn` at `:647–649` can only find what is already there). So
inlining a header strictly decreases the multiset of header ranks, and beta on
the remaining term is beta in the simply-typed lambda calculus, which is strongly
normalizing. **Every accepted program has a normal form, and it is unique.**

**The bound, and why it is not a step count.** That argument is a paragraph, not
a Lean proof, and round 18 does not pay for the Lean proof. But the draft's
`maxNormSteps := 4096` bounded the wrong quantity, and the attack is worth
stating because it is a *legal, stratified* program:

```
let d = \(f : text -> text) -> \x -> g (f x) (f x)     -- g a runtime function
d (d (d (d h))) y
```

`d : (text -> text) -> text -> text`, every application is stratified, nothing
recurses. Each inlining substitutes an arrow term into **two** occurrences, so
the term doubles while the step count grows by one. `maxRevisions` and
`maxQuestions` bound quantities that are linear in the work done; a beta step is
not one, and calling the step counter "a resource limit, like `maxRevisions`"
concealed exactly that difference.

> **The budget is the size, not the steps.** A single `Nat` is decremented by the
> number of nodes the normalizer **constructs**: substituting a term of size *s*
> into *n* occurrences costs *n·s*, and each header inlining costs the size of
> the body it splices.

```lean
/-- The largest number of term nodes normalization may build. A resource
limit, like `maxRevisions`, refused with an ordinary diagnosis — and a bound
on the *output*, because a beta step's cost is its argument's size times its
argument's occurrence count, not one. -/
def maxNormNodes : Nat := 65536
```

Sixteen times `maxQuestions` (`Check.lean:857`), on the reasoning that a normal
form's node count is a small multiple of its question count for every program
anyone will write. **Completeness — that no legal program hits the bound — is
not claimed, exactly as it is not claimed for `maxQuestions`.**

**The refusal, worded against the real cause.** The draft's message named two
escapes and both were non-escapes: naming a part with a `let` cannot reduce the
size, because a `let` is inlined at every use and a part used twice makes it
worse; and `<-` binds a `RawRhs` (`Syntax.lean:212`), so there is nothing to bind
when the blow-up lives in the arrows. What is left is the one thing that is true:

```
this expression's normal form is larger than the elaborator will build
(65536 nodes): a static function applied to another static function copies its
argument once per use, and a chain of such applications doubles at each step —
apply the arrows to answers rather than to each other, or write the steps as
statements
```

**Never a hang.** This is the same posture the language already takes twice, and
the same posture the lexer takes (`lexAux`'s budget, `Parse.lean:338`).

### 1.4 Position discipline (C32)

Every refusal this page invents fires on a **normalized** term — the vacuity
refusals of §1.5, the saturation refusals of §4.3, the arrow-at-a-runtime-position
refusal, the `.`-operand refusal of §3.5, the kind mismatches of §4.4's table. A
mismatch discovered inside an inlined `let` body has two candidate positions and
the draft named neither. So:

> 1. **Every `SExpr` node carries a `Pos`**, assigned by the parser from the
>    token that produced it.
> 2. **Substitution never overwrites a position.** A substituted argument keeps
>    its call-site position; the parameter's declaration position is carried
>    beside it as *provenance*, not instead of it.
> 3. **A refusal on a normalized term reports the node's own position** and, when
>    that node came from an inlining, names the inlining in the message.

So a kind mismatch inside `library.checked`'s body, reached from a use in
`harden-imported.wf`, reads:

```
harden-imported.wf:52:31: `library.checked` wants a `text -> text` here and
`library.reviewed library.guide` answers `verdict` (in `library.checked`'s
body, library.wf:49:22)
```

Two positions, the actionable one first. This is the same shape `agent-cat plan`
uses for a `let`'s questions (§5.4) and the same shape C26's minting uses for
temporaries (§8.8): **the use site is where the reader can act, the declaration
site is why.**

### 1.5 The vacuity refusal (C31) — the fatal finding, closed

`RawRhs` is `ask | panel | call` (`Syntax.lean:212–225`) and `RawBlock.bind`
takes a `RawSource` whose `.rhs` is exactly that. There is **no constructor for a
bare name and none for a literal**. So this legal, well-typed, C6-closed program

```
let id = \x -> x
…
x <- id draft
```

normalizes to `x <- draft`, which has no spelling in `Raw` at all. The draft's
north-star sentence — *"the normal form of every accepted program is a term of
today's unchanged `Raw`"* — was false, and the two candidate repairs were to
reopen `Raw` (which is C4's whole refusal) or to refuse the program.

> **C31. A normal form that asks nothing is refused where it was written.** At a
> bind's right-hand side or at a statement position, a normal form that is a bare
> **name** or a **literal** is refused **at the position of the source
> expression**, naming the cause rather than the normal form.

```
this statement asks nothing: `id draft` normalizes to the name `draft`, and a
statement is a question — use `draft` where you meant it, or delete this line
```

```
this statement asks nothing: it normalizes to fixed words, and a statement is
a question — write the words where they are used
```

**The body-final case is different, and round 17 already decided it.**
`RawFn.answer : Option String` holds a **name** (`Syntax.lean:309`), and
round-17's `bodyfinal ::= name | source'` (`expr-design.md:1226–1227`) was
deliberate. So:

* a body whose final expression normalizes to a **name** is **legal** — that is
  round 17's final-name rule, unchanged, and it is what `function id (a) -> text
  { a }` has always meant;
* a body whose final expression normalizes to a **literal** is **refused**, with
  the escape named:

```
a body's answer is a question's answer or a name; to answer fixed words, bind
them — `x <- ask …` — or write the words at the call site
```

**Why a refusal rather than a constructor.** `RawRhs` gaining a `.pure` case
would put a `Plan.ret` where every theorem expects a question, would give
`blockAsks` a zero-cost statement, would give `agent-cat plan` a line with no
rung, and would re-baseline `flagshipRaw` — for a program that, by construction,
does nothing. The refusal costs two diagnoses and two battery cases and keeps C4
true.

**What this narrows.** §1.1's join clause now reads "every *accepted* program",
and acceptance has one more clause than it did. That is the honest statement, and
it is stated in §0 rather than buried here.

---

## 2. The architectural north star, tested honestly

### 2.1 Normalize in the front end into today's unchanged `Raw` (C4)

Round 17 §7.2 located the survival argument correctly and round 18 quotes it
rather than restating it:

> **(i) Survival.** `Raw` and every checker function named in a theorem are
> unchanged, and **no theorem in `Dsl.lean`, `Check.lean` or `Explain.lean`
> inspects the parser's output.** `parseAndCheckProgramWith_level_le`
> (`Dsl.lean:590`) is `unfold; split; exact checkProgram_level_le`;
> `parseAndCheckRawProgramWith_eq` (`Explain.lean:301`) `cases`/`split`s on
> `parseProgramWith`'s result and never looks inside it. That is the mechanical
> reason nothing restates, and **it is indifferent to *any* parser change,
> including this one.**

The adversarial pass verified this mechanically rather than accepting it, and it
holds (§0.2). What the pass also established is that **this is the easy half**:
the fourteen level lemmas induct on constructors that do not move, so their
survival is a consequence of C4 rather than a result to be defended. The page's
confidence belongs in §§1, 3, 4 and 8, where the calculus actually has to be
built. The obligation C4 imposes is precise and is stated here as a rule:

> **The emission obligation (round-17 §7.5, restated and widened).** Normalizing
> must not change what the block parser *emits* for a program that contains no
> calculus form. Same `.act` / `.callStmt` / `.bind` / `.empty` tree, same
> positions. Any tidier representation re-baselines `flagshipRaw`
> (`DslFlagship.lean:97`), re-runs `DslSmoke`'s parse pin (`:889`), and
> recomputes all nine `decide +kernel` results in a module that elaborates in
> ~107 s.

§10.5 checks `example/harden.wf` against that obligation clause by clause.

**Where the boundary sits.** `parseProgramWith` (`Parse.lean:1291`) returns a
`RawProgram`; normalization happens *inside* it, before it returns. So
`checkProgram` (`Check.lean:932`), `blockAsks` (`:877`), `bodyAsks` (`:869`),
`maxQuestions` (`:857`, `:900`, `:943`), `overRevised` (`:915`) and every level
lemma see nothing but normal forms and cannot tell that a calculus exists.

### 2.2 The hard fork, named

`FnEntry` (`Check.lean:292–302`) holds

```lean
  params : List (String × Code)
  result : Code
  plan   : Plan (paramCtx (params.map Prod.snd)) (El result)
```

— **one plan over a context of `Code`s**. A function with a function-typed
parameter cannot be checked once into that, and the reason is not an
implementation inconvenience: `paramCtx` builds a `Ctx`, `Ctx` is a list of
`Code`, and there is no `Code` for `text -> text`. The fork is real and it must
be chosen, not finessed.

**The three honest options.**

| | Option | What it costs | What it buys |
|---|---|---|---|
| (a) | **Templates.** Higher-order headers are elaborated per call site, after their function arguments are known. `FnEntry` unchanged; the table holds only first-order entries; higher-order headers live in a separate **static** table. | Per-site elaboration; a template has no rung of its own (its rung is the caller's, at every site); its questions are counted per site by `maxQuestions`. | Directive 3 in full — HOFs, currying, functions as values, functions returned — with `Code`, `Plan`, `Ctx` and `FnEntry` untouched. |
| (b) | **Restrict.** Function-typed parameters refused in round 18; lambdas, `.`, `$`, `>>>`/`<<<`/`>>=`/`=<<` still work applied to first-order functions. | Directive 3's second half — "receiving functions as arguments, returning functions" — is refused. | Nothing new at all in the front end beyond the expression parser. |
| (c) | **Generalize `FnEntry`.** | `Code` gains an arrow constructor ⇒ `El` gains an arrow case ⇒ `Env` holds functions ⇒ `Q c` becomes meaningful at arrow kinds ⇒ **the kernel moves, and `Plan.dyn`'s quarantine is reopened**. Every `decide +kernel` proof recomputes; `DecidableEq Code` changes; the permission model, which keys on the receipt kind, gains a kind it has no policy for. | Nothing the other two do not, at a price nobody should pay. |

### 2.3 The choice: the stratum split (C5)

**Option (a), made syntactic.** The weakness of (a) as usually written is that
"is this a template or a table entry?" becomes an invisible analysis of the
declaration. Round 18 makes it a **keyword**:

> **`function` declares a runtime function.** Its parameters are answers, so
> each has a **kind**; its result is an answer, so it has a **kind**. It is
> checked **once** into an `FnEntry` and called by `Plan.sub` — exactly today's
> function, byte for byte, with no change to `checkFn` (`Check.lean:819`),
> `callPlan` (`:403`), `checkArgs` (`:372`) or `FnEntry`.
>
> **`let` declares a static function.** It may have any simple type, including
> function-typed parameters and a function-typed result. It has **no plan of its
> own**, no `FnEntry`, no rung of its own and no entry in `agent-cat plan`; it is
> normalized away at every use.
>
> **A function-typed parameter is legal only on a `let`.** A `function` whose
> parameter list carries an arrow is refused at the arrow:
>
> ```
> a `function`'s parameters are answers, and an answer has a kind; a
> parameter that is itself a function makes this a static definition —
> write `let f = \(g : text -> text) -> …`
> ```

**Why this is the right cut, in four sentences.** The two things genuinely
differ in what the reader needs to know: a `function` has a cost, a rung and a
name in the plan; a `let` has none of those and its questions appear at its use
sites. The language's oldest promise is that the page says what it costs, so the
two must not look alike. `FnEntry` — the type on which fourteen level lemmas and
the whole calling convention rest — never learns that higher-order functions
exist. And the author, not an analysis, decides which they wrote.

**The price, paid in the open.** `fn-import-design.md` sold "a function has a
rung of its own" as a property of the design: *"`level_sub` says
`level (sub Pf σ) = level Pf`. The cost class of a call is the cost class of the
function, at every site, in every program."* **A `let` does not have that**, and
saying so is the honest half of this decision. What replaces it:

* a `let`'s questions land in the caller's `Raw`, so the caller's own bound
  applies — `checkBlock_level_le` (`Dsl.lean:265`) and `checkBody_level_le`
  (`:453`) cover them with no new lemma, and `parseAndCheck_level_le`
  (`:599`) still bounds the whole program at branch;
* a `let`'s questions cost the same as a `function`'s. This is not a
  concession, it is arithmetic: a call is `Plan.sub Pf σ`, which *substitutes
  through the term*, and `maxQuestions` already prices a call as "its callee's
  questions, at this site" (`fn-import-design.md`: *"a call inlines its
  function's questions per site"*, `Check.lean:860–890`). **Template-per-site
  and `FnEntry`-per-site cost exactly the same number of questions.** The only
  difference is elaboration time and which lemma covers the bound;
* **what a `let` does *not* get for free is the pre-pricing.** `checkFnsList`
  (`Check.lean:896–906`) prices a table entry with `bodyAsks acc f.body` over raw
  syntax *before* `checkFn` elaborates a node of it, and `fn-import-design.md`
  sells that as a property. A `let` has no `FnEntry` and no `asks` field, so
  §4.5 gives the static table the one number it needs and §7.2 spends it.

**The optimization not taken, recorded.** A `let` whose normal form is a
first-order lambda with a saturated base-kind body could be *promoted* to an
`FnEntry` — checked once, called by `Plan.sub`, one rung. It is a pure win in
elaboration time and it is decidable syntactically after normalization. It is
**deferred**, because by the paragraph above it changes no cost, no trace and no
bound, and because it is the kind of thing that should be added when a real
program is slow to elaborate rather than in the round that introduces the
feature.

**Option (b) is not taken**, but it is the fallback and it is one line of code
away: refuse an arrow in a `let`'s parameter annotation and the whole
higher-order path disappears while lambdas, composition, sections-free operators
and partial application all keep working. If the implementation campaign runs
long, **(b) is where to cut**, and cutting it does not invalidate any other
decision on this page. That is recorded here so the cut can be made without
reopening the design.

---

## 3. Expression grammar and precedence, Haskell's

### 3.1 The grammar

Against `expr-design.md` §6, which is against `GRAMMAR.md` §Grammar. Two of the
draft's productions were fatally wrong and are repaired here: `source` was
unreachable from every runtime position, and C8 was written into `atom` so that
no application could have a function head.

```
                                   -- DELETED -----------------------------
argument   ::= name | text | "$" label       -- round 17's argument
bang       ::= "!" "(" source' ")"           -- round 17's bang (C19)

                                   -- ADDED / REPLACED ---------------------
header     ::= import | define | function | let
let        ::= "let" name [ ":" type ] "=" expr      -- static; closed (C6)

param      ::= name [ ":" type ]                     -- omitted means `text`
type       ::= kind                                  -- NEW
             | type "->" type                        --   right-associative
             | "(" type ")"
             -- an arrow's ARGUMENT is never `flag` or `receipt`: refused at
             -- the annotation, by today's two messages (§4.1)

expr       ::= app
             | expr "$"   expr                       -- infixr 0
             | expr ">>>" expr                       -- infixr 1
             | expr "<<<" expr                       -- infixr 1
             | expr ">>=" expr                       -- infixl 1
             | expr "=<<" expr                       -- infixr 1
             | expr "."   expr                       -- infixr 9
             | lambda
lambda     ::= "\" binder { binder } "->" expr       -- the body is ONE expr
binder     ::= name | "(" name ":" type ")"

app        ::= head { arg }                          -- left-assoc; §3.3
head       ::= fname | letname | atom                -- C8 lives HERE
arg        ::= atom
atom       ::= name                    -- neither a function nor a `let` name
             | text
             | "(" expr ")"
             | "(" source' ")"                       -- a parenthesized question

call       ::= fname { arg } { labelledblock }       -- `$label` lives HERE, only
source     ::= ask | panel | call | loop             -- as today, unchanged
source'    ::= ask | panel | call                    -- no loop: a loop is a statement

-- runtime positions: the SOURCE alternative is tried first, then `expr` (§4.5)
step       ::= [ name [":" kind] "<-" ] ( source | expr )
             | branching | assertion
bodyfinal  ::= source' | expr
blockfinal ::= source | expr | branching | "stop" | assertion
subject    ::= source' | expr                        -- `if` and verdict-`case`
```

Unchanged: `program`, `library`, `import`, `define`, `function`'s header shape,
`labelledblock`, `ask`, `rule`, `loop`, `arms`, `kind`, `text`, `plainstring`,
`block`, `branching`, `assertion`, and every rule in "The rules the grammar does
not carry" except rules 2 and 3, which §7.3 and §5.1 restate.

**Three repairs the grammar block carries, each from a finding.**

1. **The source alternative is restored at every runtime position, and tried
   first.** In the draft, `source'` was reachable only through the parenthesized
   atom, so `guide : text <- ask tool "cat" "…"` (§9.1's own priming), `x <-
   panel, all must approve [ … ]` (`reviewed`'s body) and `result <- revising
   draft as patch, at most 2 amendments { … }` (§9.2) were all underivable — the
   grammar as written deleted three constructs the same page's examples use. The
   rule now is: **at a runtime position, a token that begins a source begins a
   source**; only a token that cannot enters the expression parser. That keeps
   every existing program on today's parse path byte for byte, which is the
   emission obligation's cheapest possible discharge, and it keeps a `revising`
   loop out of the operator layer entirely (§6.3, D15).

2. **`app` is split into head and argument, and C8 is a head-position rule.** In
   the draft, `atom ::= name -- not a function name` made a function head
   underivable, so `library.filed note`, `f a b` and every construct §3.3 bounds
   could not be parsed. C8 is about *argument* position and always was (§3.4).

3. **`$label` is deleted from `atom` and confined to the `call` production**,
   which is where it lives today. A `$label` has no type — it is not one of the
   four kinds — so §4.4's synthesis had no rule for it and §4.3's saturation
   check had nothing to say about `$rubric . g`. D9's widening (§6.3) is
   implemented instead as a **positive check after `collectLabelled`**
   (`Parse.lean:707–720`): if the call carried at least one `$label` and the
   parse is in an operand or argument position, refuse there, where the
   information exists.

**Tokens.** Six new: `.` (spaced), `\`, `>>>`, `<<<`, `>>=`, `=<<`. One
repurposed by context: `$`. One new keyword: `let`. `!` is **not** added (C19).
`answer` leaves `stmtWords` (round-17 D20).

### 3.2 The one-slide precedence table

| Level | Form | Associativity | Haskell |
|---|---|---|---|
| tightest | `f a b` — juxtaposition | left | same |
| 9 | `f . g` | right | `Prelude.(.)`, `infixr 9` |
| 1 | `f >>> g`, `f <<< g` | right | `Control.Category`, `infixr 1` |
| 1 | `m >>= g` | **left** | `Prelude.(>>=)`, `infixl 1` |
| 1 | `g =<< m` | right | `Prelude.(=<<)`, `infixr 1` |
| 0 | `f $ x` | right | `Prelude.($)`, `infixr 0` |

So `f . g $ x` is `(f . g) x`; `f . g >>> h` is `(f . g) >>> h`; `v >>> f . g`
is `v >>> (f . g)`; and `f $ g $ x` is `f (g x)`. These are Haskell's numbers and
they are taken unchanged so that a reader who knows Haskell never has to check —
ruling 9 in its simplest form.

**One consequence of taking the numbers whole**: `>>=` is `infixl 1` and `>>>`
is `infixr 1`, so `a >>= b >>> c` has no parse in Haskell either. §3.5 refuses a
mixed level-1 chain at the second operator rather than inventing a resolution,
which is Haskell's own behaviour with a better message.

### 3.3 How far an application reads (C7)

This is the hardest question in the round, because **the language has no
statement terminator**: braces delimit, indentation means nothing, and
`notify "ready"` followed by `stop` was round 16's counterexample to
lookahead-only rules. Greedy Haskell juxtaposition would swallow the next
statement.

> **The four bounds.** An application reads atoms while all four hold:
>
> 1. **Arity from above, and every head form has one, syntactically.**
>    * a `function` name — the table's arity (`resolveFn`, `Parse.lean:647–649`,
>      now over signatures: §4.5);
>    * a `let` name — the arrow count of the type synthesized at its own header
>      and stored in `env.lets` (§4.5), available before any use because a `let`
>      may mention only headers above it;
>    * a lambda head — its **written binder count**;
>    * a parenthesized non-lambda head, a runtime binding, a `function`
>      parameter, a lambda binder — **exactly zero**. A value is not applied to
>      anything, and §4.3's diagnosis says so at the first argument.
> 2. **The stopper set from below.** The next token begins an atom. It does not
>    when it is `)` `}` `]` `,` `<-` `:` `->` an operator, a number, a
>    `labelledblock`, a **statement word** (`stmtWords`, `Parse.lean:522`), a
>    **function or `let` name** (C8), or end of input.
> 3. **The next-statement probe.** The next token is not an ident immediately
>    followed by `<-` or `:`.
> 4. **The continuation rule.** An expression continues while the next token is
>    an **operator**, across line breaks. A statement therefore never begins with
>    an operator.

**Bound (1) had a hole and it is closed.** The draft said a parenthesized or
lambda head is "unbounded, and only (2) and (3) apply" — but (2) and (3) are
exactly what round 16 proved insufficient to separate statements, so bound (1),
the *primary* decider, was vacuous for every head that is not a table name. Two
of the four cases now have a written arity, and the third has zero, which is both
true (nothing in this language applies an answer) and decidable with no types.

**The continuation rule (4) is new as a written rule and old as behaviour.** It
is what makes a three-line `>>>` pipeline work (§9.2), and the draft used it
without stating it. Its hazard is a stray operator at a statement head, which is
now a refusal rather than a swallow:

```
a statement does not begin with `>>>`; it continues the statement above, so
join the lines, or bind the left-hand side with `<-`
```

The same clause serves `<<<`, `>>=`, `=<<`, `.` and `$`.

**Round 16's rule, promoted.** `fn-import-design.md` kept (3) as *"one token of
lookahead used only to improve a diagnosis, never to choose a production"*,
because on its own it cannot separate an argument from `stop`, from `ask …`, or
from another call statement. Round 18 keeps (1) as the primary decider, exactly
as round 16 did, and promotes (3) to a decision — which is sound precisely
because (1) already handles the three cases (3) cannot: they are all in the
stopper set of (2).

**Bounded lookahead, still.** At a statement head the current token plus the
tables decide (zero lookahead). At an argument position the atom is classified by
its own token, with (3) as one token of lookahead. Nothing in round 18 needs
more.

**The one ambiguity, recorded rather than hidden.** Inside a `-> text` body,

```
  f a b c d
```

with `f : … -> receipt` of arity 3 reads as `f a b c` (a statement call) followed
by `d` (the body's final expression, round-17 D1), because (1) fires before (2).
The alternative reading — `f` applied to four arguments — is refused by arity
anyway, so nothing legal is lost; but the diagnosis for a genuine over-application
is one statement later than the mistake. **Refusal wording**, keyed on a saturated
first-order application followed by an atom that cannot begin a statement:

```
`f` takes 3 arguments and 4 are written here; a value is not applied to
anything — parenthesize the nesting you meant, `f a b (g c)`
```

Two battery cases: the legal shape, and the refusal.

### 3.4 A function name in argument and operand position (C8)

```
  first <- library.drafted library.guide aim shape >>> library.reviewed library.guide
  library.applied patch
```

Without C8, `library.reviewed`'s second argument would be read as
`library.applied`, and `patch` would become junk. With C8 — *a function or `let`
name is an atom only in **head** position* — the application stops, and
`library.applied patch` is the next statement. **The rule exists to make
statement boundaries decidable without a terminator, and it is round 16's own
refusal in its useful form**, with two escapes named instead of one:

```
`library.drafted` is a function; as an argument it is written `(library.drafted)`
or `\x -> library.drafted x`, because bare it would read as a call
```

> **The extension the attack forced: an operator's right operand reads zero
> arguments.** A function or `let` name standing as the right operand of `.`,
> `>>>`, `<<<`, `>>=` or `=<<` is **the arrow itself** and reads no arguments. To
> apply it, parenthesize.

Without this, a statement that *ends* in a partially applied head — which is
precisely the shape `>>>` pipelines exist to write — has no decidable end. Take

```
  a >>> library.summarised patch
  draft
```

where `draft` is a runtime binding standing as a body's final expression. Bound
(1) says `library.summarised` has arity 2 and has read 1, so it keeps reading and
swallows `draft`. The stopper set cannot help: a bare binding is exactly what an
argument looks like. With the rule, `library.summarised` is the whole right
operand, `draft` is the next statement, and the arity mismatch is diagnosed at
the operator, where the fix is:

```
`library.summarised` takes 2 arguments and a pipeline supplies one; the right
of `>>>` reads no arguments, so a partial application is parenthesized —
`>>> (library.summarised patch)`
```

The left operand is unaffected: it is read as an ordinary application, bounded by
arity, and terminated by the operator token, which is in the stopper set. So
`library.judged patch library.rubric twice >>> …` needs no parentheses and
`… >>> (library.summarised patch)` does. §9.2 writes it that way.

Cost: passing a function by name to a higher-order `let`, or applying one in an
operator's right operand, costs one pair of parentheses.

**Rejected alternative, and its rationale corrected.** Type-directed argument
parsing — let `PEnv` carry parameter *types* and admit a bare function name
exactly where a function-typed parameter expects it — works and is one line
prettier at the call site. The draft refused it "on layering", and the attack
showed the layering argument is undermined by this page's own decisions: §4.5
already puts static types into `PEnv`, and bound (1) already reads a `let`'s
arity out of a synthesized type, so synthesis is already interleaved with
parsing, header by header. **So the refusal stands on its true ground instead:**
the parser must not need types it does not already have, and it does not have —
and must not have — the types of **runtime bindings**, which are inferred by the
checker from their uses (`bindKind`, `Check.lean:265`). A rule that admitted a
bare name "where a function is expected" would work for table names and fail for
bindings, which is a rule with an invisible exception. The paren is the price of
a boundary the reader can compute.

### 3.5 The operators, typed (C9, C10, C33)

Writing `M c` for "a computation answering kind `c`" — a metalanguage word with
**no surface spelling**, because hoisting erases it (§5.1):

```
Γ ⊢ f : b -> c    Γ ⊢ g : a -> b            Γ ⊢ f : a -> b    Γ ⊢ x : a
--------------------------------- (.)       ----------------------------- (app)
Γ ⊢ f . g : a -> c                          Γ ⊢ f x : b

Γ ⊢ f : a -> b   Γ ⊢ g : b -> c             Γ ⊢ e : b   Γ ⊢ g : b -> c
------------------------------- (>>>arr)    -------------------------- (>>>val)
Γ ⊢ f >>> g : a -> c                        Γ ⊢ e >>> g : c

Γ ⊢ m : b   Γ ⊢ g : b -> c
-------------------------- (>>=)      …and `<<<` is `>>>` with its operands
Γ ⊢ m >>= g : c                        exchanged, `=<<` is `>>=` likewise,
                                       and `$` is (app) at fixity 0.
```

Two rules for `>>>`, disjoint by the *shape of the left operand's synthesized
type* — an arrow or a base kind — and therefore decided with no inference at
all. §5.2 defends the overload and shows it is coherent with the fixity.

**`>>=` and `=<<` take a value on the flowing side only.** That is Haskell's own
restriction (`>>=` wants a monadic value on the left; the function instance is
the Reader monad, which this language does not have), and it gives `>>=` a job
`>>>` does not do: it says *"this one is a computation"* at the operator. An
arrow on the left of `>>=` is refused, naming the operator that composes:

```
`>>=` takes an answer on the left and a function on the right; to compose two
functions, write `f >>> g`
```

**`.` is arrows only**, on both sides, and the diagnosis splits on which side is
wrong. One arrow and one value:

```
`.` composes two functions; to apply one, write `f $ x` or `f x`
```

**Both values** — which is the case this round most needs to catch, because it is
what an author writes when they mean to sequence two questions:

```
both sides of `.` are questions, not functions; a question's answer flows with
`>>>` — `library.judged patch library.rubric twice >>> library.summarised patch`
— or write them as two statements
```

That second message is owner ruling 8's *"`.` over questions is refused,
diagnosis names `>>>`"*, implemented literally. Two battery cases, not one.

**A mixed level-1 chain is refused at the second operator.** `>>>` and `<<<` are
both `infixr 1`, so `a >>> f <<< g` is grammatical and parses as `a >>> (f <<<
g)` — a reading that is a coin flip for the reader and that, with the value
overload, sometimes type-checks. `>>=` at `infixl 1` beside `>>>` at `infixr 1`
is a fixity conflict Haskell itself rejects. So:

```
`>>>` and `<<<` do not mix in one chain; parenthesize the direction you meant
```

```
`>>=` and `>>>` do not mix in one chain; they associate opposite ways, so
parenthesize the grouping you meant
```

One token of state in the operator parser, nothing legal lost, and Haskell's
behaviour with a better message. Battery: `a >>> f <<< g` refused, `a >>> (f <<<
g)` accepted; `a >>= f >>> g` refused, `(a >>= f) >>> g` accepted.

### 3.6 Lambdas (C12)

```
\x -> e                 -- one binder, defaulting to `text`
\x y -> e               -- sugar for \x -> \y -> e
\(finding : verdict) -> e
\(draft : text -> text) -> e
```

**Where a lambda may stand:** any expression position — an argument, a `let`'s
body, either operand of `.`/`>>>`/`<<<`/`>>=`/`=<<`, the right of `$`. Its body
extends as far as the enclosing expression allows, which is Haskell's rule, and
which is why a lambda in an argument position is parenthesized in every real
program.

**Where a lambda may not stand:** any runtime position — a statement, a binder's
right-hand side, a body's final expression, an `if`/`case` subject, a call
argument at a first-order parameter, a `{hole}`. Each is the saturation refusal
of §4.3.

> **A lambda's body is one expression.** There is no `\x -> { … }` form. A
> function value that asks a *sequence* of questions is written as a `function`
> and passed by name as `(f)`.

That is a real limit on directive 3's "functions as values… the whole deal" and
it is recorded rather than discovered: the value being passed is limited to a
one-expression body, and the escape is the runtime function, which is the thing
the language already has for a sequence of questions. Keyed on a `{` following a
lambda's `->`:

```
a lambda's body is one expression; a sequence of questions is a `function`,
passed by name — `(f)`
```

**A prompt in a lambda body is legal, and it is the point.** `\x -> (ask model
"critic" "Rate this:\n{x}")` is inside the grammar, and it is the *only* way a
static function can build a prompt from its own parameter; without it a lambda
binder can do nothing but be handed to a runtime `function`, which would make the
higher-order half of directive 3 nearly ornamental. **It is taken**, and §8.8
carries the one clause it needs — minting rewrites `Chunk.interp` names inside
every prompt of a substituted term, and the `expand_*` theorems are untouched
because that rewrite is `Chunk.interp`-to-`Chunk.interp` and says nothing about
`expand`. Pinned in §9.3 and in the battery.

**Binder discipline: minted, not policed** (C36). The draft said a lambda binder
"obeys rule 6 (no shadowing) and `freshOfTables` (`Parse.lean:530`) exactly as a
`<-` binder does". That is not implementable and would be wrong if it were:
`freshOfTables` checks `stmtWords`, `env.defs`, `env.fnAr` and `env.mods`
(`:530–545`) and has **no view of runtime bindings at all** — no-shadowing
against live names is enforced by `freshName` over `Bindings` in the *checker*
(`Check.lean:111`), and a lambda binder is normalized away before the checker
runs. So the rule would either be unenforceable or would refuse
`let f = \patch -> library.judged patch …` in any program that also binds `patch
<- …`, which is a name collision between a name that runs and a name that never
does.

> **Every static binder is minted to a temporary at parse time**, at the binder's
> own position, by C26's mechanism (`!L:C`, already-qualified, routed around
> `PEnv.q`). No lambda binder ever spells a source name, so **shadowing is
> impossible by construction and rule 6 does not apply to static binders**;
> substitution is a plain traversal with nothing to avoid. §8.8 states the
> mechanism once and §7.3 states the rule.

This replaces the draft's `freshOfTables` claim outright. What *does* go through
`freshOfTables` is a **`let`'s own name**, which is a header name in the source
text — see §4.5's fourth clause.

### 3.7 Sections: refused (C11)

`(. g)`, `(f .)`, `($ x)`, `(>>> g)` — **refused.** Four reasons, ordered:

1. **They collide with the dot rule head-on** — and the claim has to be narrower
   than the draft made it, because C21 already asks the reader to look at a space
   once (`f $rubric` and `f $ rubric` differ by one space and mean unrelated
   things). The true statement: the trap is two whitespace-sensitive readings *of
   the same character in the same position*. `(f .)` and `(f.)` are exactly that —
   a section and a lexical error, differing by one space, at the same character,
   in the same construct. `$`/`$label` is not, because a `$label` is never in
   operator position: an operator's right operand cannot be a bare label.
2. **They elide one binder, and cost a reading.** `(. g)` is `\f -> f . g` and
   `(f .)` is `\g -> f . g`; a reader who has to work out which is which has
   spent more than the four characters `\x ->` saved. The whole justification
   for sections in Haskell is arithmetic and operator sections over a large
   operator vocabulary, which this language does not have (reason 3).
3. **There are no infix value operators at all** in this language — no
   arithmetic, no comparison, rule 3 — so the only sections available would be
   over the five composition operators, which is the least valuable corner of
   Haskell's section grammar.
4. **The noise audit's own criterion**: a construct earns its place if it
   removes a name the reader does not need. A section removes a *lambda binder*,
   which is one character.

Refusal, with the escape named:

```
a section is not written here; write the lambda: `\x -> f (g x)`
```

### 3.8 `->` does triple duty, and it parses (C13)

`->` is one token (`.resArrow`, produced at `Parse.lean:346`) and it appears in
three grammars. It parses with **no lookahead and no ambiguity**, because each
occurrence is reached from a different state:

| Occurrence | Reached from | Parsed by |
|---|---|---|
| `function f (…) -> kind {` | after the parameter list's `)` | `parseFn` (`Parse.lean:1104–1112`), which *expects* `->` |
| `\x y -> e` | after a non-empty binder list, inside `parseLambda` | terminates the binder list |
| `text -> text` | only after a `:` in a `param`, a `binder` or a `let` header | `parseType`, right-associative, terminated by `,` `)` `=` or `->`'s absence |

The third never occurs where the first two can, because a **type** is only ever
read after a `:`, and a `:` is only ever read in a parameter, a binder, or a
`let`'s optional annotation. The first never occurs where the third can, because
`parseParams` (`:1070`) consumes the `)` before `parseFn` looks for `->`. And a
lambda's `->` cannot be mistaken for a type's, because `parseType` is not on the
stack when binders are being read.

The one shape that looks alarming and is not: `\(g : text -> text) -> e`. The
inner `->`s are inside the binder's parentheses and are consumed by `parseType`,
which stops at the `)`; the outer `->` is the lambda's. Pin it. The `let` header's
annotation adds one more: `let f : text -> text = \x -> …`, where `parseType`
stops at the `=`. Pin that too.

### 3.9 `ret` — not added (C14)

The owner's directive 1 writes `y <- f x; z <- g y; ret z`. Round 17 already
answered this, in D1, for a word that was actually in the language:

> `answer` is **deleted**. The last statement of a body is its answer. `x <- m;
> pure x` is the monad's right identity, the elaborated term is *identical* by
> `rfl` (`Plan.askC1 c q` is *defined* as `.askC c q (.ret (Expr.var .here))`,
> `Agentic/Core/Plan.lean:469`), and every Haskell linter flags it.

**Adding `ret` would be re-adding `answer` under a Haskell name**, one round
after deleting it, and would cost a reserved word (`ret` could no longer be a
binder). The owner's own equivalence is the argument for the decision: the
directive says that chain *is* `f x >>> g`, and `f x >>> g` is what round 18
writes.

**But the mistake is worth catching, permanently.** `ret z` at a final position
is an ident followed by an ident — otherwise unparseable — so key a message
there, in the same spirit as round 17's bare-parenthesis message, and with the
same reasoning (it is a mistake the *language* invites, not a legacy one, so it
does not expire):

```
`ret` is not a word here: the last statement of a body is its answer —
write `z`
```

The same clause fires for `pure` and `return`. Three words, one clause, one
battery case each.

---

## 4. Types and annotations

### 4.1 The type grammar and the defaults (C15)

```
type ::= "text" | "verdict" | "flag" | "receipt"
       | type "->" type            -- right-associative
       | "(" type ")"
```

* **A bare parameter is `text`** — round-17 D16, carried unchanged, with its
  reasoning (*"since argument types are almost always text, in this case the
  `: text` can be omitted"*) and its quirk (`function f (verdict)` declares one
  **text** parameter *named* `verdict`).
* **A function-typed parameter is always annotated.** There is no default arrow
  type and there will not be one: a default that could be an arrow would make
  `\x -> …` mean something different depending on the body, which is inference,
  which is §4.4's refusal. So: **a bare binder is `text`, never a function.**
* `flag` and `receipt` parameters stay refused, with today's two diagnoses
  unchanged (`Parse.lean:1090–1096`). Both refusals extend to `let` binders for
  the same reasons: nothing consumes a flag inside an expression (`if` is a
  statement), and a receipt carries no information.
* **And both refusals now extend to an arrow's *argument*, at the annotation.**
  The type grammar admits `receipt -> text`, but no value of that type can ever
  exist — a `receipt` parameter is refused everywhere, so nothing can fill the
  argument. Rather than let `\(g : receipt -> text) -> …` be a well-formed
  annotation for a parameter nothing can ever supply, and fail at some later
  mismatch, refuse it **where it is written**, with the same two messages. The
  inhabited argument kinds are `text` and `verdict`; an arrow may of course be an
  argument (`(text -> text) -> text` is what `library.checked` is).
* `: text` stays legal. This is an elision, not a prohibition.

### 4.2 Function-typed results (C16)

**A `function`'s result stays a kind.** A function that answers a function is
written as a `let`:

```
function f (a) -> (text -> text) { … }      -- refused
let f = \a -> \b -> …                       -- written
```

Refusal:

```
a `function`'s result is an answer, and an answer has a kind; a function
that answers a function is a static definition — write `let f = \a -> …`
```

**Why this is not a restriction on expressiveness.** Currying is available where
it matters — at *use*, through partial application (§4.3) — and the declaration
form lists parameters, so "returning a function" and "taking one more parameter"
are the same declaration. Haskell says yes to function-typed results because
Haskell has no separate declaration form; this language does, and the two strata
(C5) are the place where the distinction is already being drawn.

### 4.3 Partial application, saturation, and the boundaries (C17)

> **Partial application is legal statically and refused at every runtime
> position.** `library.reviewed library.guide` is a value of type
> `text -> verdict`; it may be an operand of `.`, `>>>`, `<<<`, `>>=`, `=<<`,
> `$`, an argument at a function-typed parameter, or a `let`'s body. It may
> **not** be bound by `<-`, stand as a statement, be a body's final expression,
> be an `if`/`case` subject, fill a first-order parameter, or appear in a hole.

Refusals, each naming what to do:

```
`library.reviewed` takes 2 arguments and 1 is written here; a question
cannot be asked of a function — apply it, or bind what it needs above
```
```
the last statement of `f` answers a function; `f` answers `text` — apply it
```

**The most likely first mistake in "a simplified Haskell", and it now has a
diagnosis.** `let apply = \f x -> f x` — the shape directive 3 invites — defaults
`f` to `text` (C15), so `f x` is an application whose head synthesizes a *base
kind*. §4.4's rule (no inference of an arrow from a body) is correct and says
nothing to the author. Keyed on an application whose head synthesizes a base
kind:

```
`f` is an answer, and an answer is not applied to anything; a parameter that
is a function says so — write `\(f : text -> text) -> …`
```

The mirror fires for the `let`-header form. Two battery cases: the bare binder
used as a function, and the annotated binder accepted.

**Two binder classes, two opposite kind policies, stated rather than left
implicit.** A `<-` binder's kind is *inferred* from its uses (first-ground-use,
with the round-8 ground-free refusal, `GRAMMAR.md` rule 4); a **lambda binder's**
kind is *defaulted* to `text`, with an explicit refusal to infer anything from
the body (C18). So `\finding -> library.summarised patch finding` is a type error
where the same name written `finding <- …` would have been inferred `verdict`.
The message is issued by the normalizer, not the checker — a lambda binder is
gone before `checkProgram` runs — and it has the wanted kind from `PEnv.fnSigs`,
which is `fnSigsOf`'s shape by construction (§4.5), so it can name it:

```
a lambda binder's kind is `text` unless it says otherwise, and this one is
used where a `verdict` is wanted — write `\(finding : verdict) -> …`
```

**A receipt on the flowing side of a pipeline.** `library.applied patch >>> g`
puts a `receipt` into `g`'s argument, and no `g` can take one. Keyed on a
receipt-kinded left operand:

```
a receipt carries no information, so nothing flows out of `library.applied`;
order is the sequence of statements — write the two calls on two lines
```

**The round-16 objection, answered rather than repeated.** `expr-design.md`
§3.9 recorded: *"a curried signature would prepare for partial application —
which this language does not have and should not get (a function is an open plan
over its parameter context; partial application would need a `Sub` that is not
yet total)."* That objection is exactly right **about runtime**, and round 18
does not contradict it: by the time `callPlan` (`Check.lean:403`) runs, every
call is saturated, so every `Sub Γf Δ` it builds is total, and `checkArgs`
(`:372`) folds a complete argument list exactly as today. Partial application
lives entirely above that line and is gone before it.

**A syntactic consequence worth stating:** because an application is bounded
above by arity (§3.3) and an operator's right operand reads zero arguments
(§3.4), **a partial application is always parenthesized or a left operand**. You
cannot write one bare at a statement head, which is exactly where it would be
refused anyway.

### 4.4 The typing discipline, stated as a refusal (C18)

> **Types are synthesized bottom-up and checked top-down at runtime positions.
> There is no unification, no Hindley–Milner, no let-polymorphism, no type
> variables, and no inference of an arrow type from a body.**

* **Synthesis.** A name synthesizes from the tables (`function` via `fnSigs`,
  `let` via `lets`, `define` via `defs`) or from the binding
  (`Bindings`/`Binding.code`); a literal synthesizes `text`; an application
  synthesizes its head's result; `.`/`>>>`/`<<<`/`>>=`/`=<<`/`$` synthesize by
  the rules of §3.5; a lambda synthesizes `τ → σ` from its annotated (or
  defaulted) binder and its body.
* **Checking.** Every runtime position *imposes* a kind, and round-17 §4.1's
  imposed-kind table is unchanged and now carries four more rows:

| Position | Kind | Source |
|---|---|---|
| call argument (first-order parameter) | the parameter's kind | `argExpr` / `checkArgs` |
| call argument (function-typed parameter of a `let`) | the parameter's **type** | the static table |
| final **ask** of a body | the declared result | `bodyBindKind`'s `answer` clause |
| final **call or panel** of a body | the source's kind, then checked | `Check.lean:775–789`, `:826–834` |
| final statement of a `Unit` block | `receipt` | `El .ack = Unit` |
| binder-elided statement | `receipt` | `bindForm fns .ack` |
| panel member | `verdict` | `checkMembers` |
| `if` subject | `flag` | `bnd.at? .flag` |
| verdict `case` subject | `verdict` | `bnd.at? .verdict` |
| `{x}` hole | `text`, or `verdict` by its one canonical rendering | `chunkExpr` |
| unannotated **parameter** or **lambda binder** | `text` | D16 / C15 |
| **operand of `.`** | an arrow | C10 |
| **left of `>>>` / right of `<<<`** | an arrow **or** a base kind | C10 |
| **left of `>>=` / right of `=<<`** | a base kind **only** | C33 |
| **a hoisted temporary's binder** | its source's synthesized kind, **written** | C35 |

* **Monomorphic, and that is fine.** A `let` is not generalized: `let apply =
  \(f : text -> text) -> \x -> f x` works at `text` and nowhere else, and a
  second instantiation is a second `let`. In a language with four base types, no
  data structures, no lists and no recursion, polymorphism buys almost nothing
  and costs a unification algorithm, a generalization rule, and an error-message
  vocabulary (`cannot match `a` with `text``) that the rest of the language does
  not have.
* **Kind inference is untouched, and the calculus now needs less of it, not
  more.** Named `<-` bindings keep first-ground-use inference and the round-8
  honest side condition (an annotation is *required* for any constraint component
  that never touches a ground site). The draft argued that hoisted temporaries
  strengthen this because each is "anonymous, used exactly once, at a ground
  site" — an invariant that by-value hoisting breaks in both directions (zero
  uses, and two). **C35 removes the argument's need**: every hoisted temporary is
  emitted *annotated*, so inference is never asked about one at all. That is a
  stronger statement than the draft's and it does not depend on a use count.

### 4.5 What `PEnv` must now carry (C34)

Round 17 §2.3 recorded two conditions under which D2 would need revisiting, of
which the second was *"any move away from arity-directed parsing"*, and noted
that `PEnv` carries `fnAr : List (String × Nat)` — arities, not kinds
(`Parse.lean:496–509`). Round 18 does not move away from arity-directed parsing
(§3.3 keeps arity as the primary bound). It needs **more than arities**, and the
draft's "and `fnAr` stays exactly as it is" was wrong on both tables.

**Change one: `fnAr` widens to signatures.** Every typing rule in §3.5 runs
*inside* `parseProgramWith`: `.` must check that `g`'s result kind equals `f`'s
argument kind; `>>>`'s two rules are disjoint by the left operand's synthesized
type; §4.3's diagnoses name the wanted kind. `fnAr` carries names and arities
only (`Parse.lean:500`), and the parameter and result **kinds** live in
`Fns`/`FnEntry`, which `checkFnsList` builds *after* parsing. So:

```lean
  /-- Function signatures, under full names, in stratified order — exactly
  `fnSigsOf`'s shape (`Check.lean:312`), so the parser's table and the
  checker's agree by construction. Arity is the parameter list's length. -/
  fnSigs : List (String × List (String × Code) × Code) := []
```

replacing `fnAr`. Four sites move, all mechanical: the declaration
(`Parse.lean:500`), the build in `parseModuleSrc`'s `function` header case
(`:1189`, `fn.params` instead of `fn.params.length`), and the two readers —
`freshOfTables` (`:537`) and `resolveFn` (`:649`, whose arity becomes
`.length`). Nothing else in the parser reads it.

**Change two: `let`s get their own table, and are kept out of `fnAr`.** The draft
put a `let` "in the function namespace" so that `freshOfTables`'s function clause
covers it and `resolveFn` finds it. Those two sentences break call emission:
`resolveFn` (`:647–649`) is the **head resolution used by the call parser**, and
anything it resolves is read as a runtime call and emitted as `RawRhs.call` /
`RawBlock.callStmt` / `RawBodyStmt.callS`. Those reach `callPlan`
(`Check.lean:403`), which does `fns.find? f` against `Fns` — a table a `let` is
never in, by C5's whole point. Every use of a `let` would elaborate to "no such
function", from the checker, at a position the parser had already accepted.

```lean
/-- One static header: a `let`, as the normalizer will splice it. -/
structure LetEntry where
  /-- The full name, qualified at declaration. -/
  name : String
  /-- Synthesized at the header, from the right-hand side; checked against
  the written annotation when there is one. -/
  type : SType
  /-- The normalized body, stored CLOSED: every head, define and `let`
  reference already fully qualified, so inlining is a pure substitution. -/
  body : SExpr
  /-- The question count of `body`'s normal form, priced once — the static
  table's answer to `FnEntry.asks`. -/
  asks : Nat
```

with `lets : List LetEntry := []` beside `fnSigs`, and three consequences:

1. **`freshOfTables` gains a fourth clause**, with its own message, so a binder,
   parameter or function may not spell a `let` and a `let` may not spell any of
   them:
   ```
   a binder may not spell a static definition; one of the two must be renamed
   ```
2. **Head dispatch consults `lets` before `resolveFn`.** A name that resolves in
   `lets` is a static head: it is handed to the normalizer with its arity read
   off `type`, and never enters `parseArgTokens` (`:659`) or the call emission
   path at all.
3. **A `let`'s body is stored qualified at declaration.** In §9.1's own showcase,
   `let checked = \(draft : text -> text) -> \goal -> judged (draft goal) rubric
   spec` is written inside `library.wf` with `judged`, `rubric` and `spec`
   **unqualified**, and it is used, dotted, from `harden-imported.wf`. Today's
   machinery for that is `qualifyBody`, which rewrites `RawFn`s; a `let`'s body
   is an `SExpr` and no pass would reach it. So the body is resolved and
   qualified **at declaration**, inside `parseModuleSrc`, through that module's
   own `env.q` (`Parse.lean:513–517`), exactly as a function body's heads already
   are — and inlining is then a pure substitution with no environment. That is
   what "closed" means operationally, and it is why C6's closedness rule is worth
   its restriction.

**Change three: the type is synthesized at the header and stored.** Bound (1) of
§3.3 reads a `let`'s arity off its type, and a `let` has no *required*
annotation, so the type must be synthesized from the right-hand side before any
later statement is parsed. That is exactly what stratification already licenses:
a `let` may mention only headers above it, so its type is computable the moment
its `=` is read.

> **Point-free `let`s stay.** `let review = judged . normalize` and `let step = f
> >>> g` are the showcase for the whole round, and the alternative repair —
> requiring every `let`'s right-hand side to be a lambda — would delete them to
> save a table field. The cost is that the parser synthesizes a type per header,
> header by header; §3.4 already had to admit that synthesis is interleaved with
> parsing, so this adds no layer, only a field.
>
> **The annotation is optional and is checked, not trusted:** `let f : text ->
> text = \x -> …` synthesizes the type from the body and refuses a mismatch at
> the annotation. It exists because a point-free header's type can be non-obvious
> to a reader, and a reader is who the annotation is for.

**A `let` whose synthesized type is a base kind is refused, at the `=`.** C6 as
drafted admitted `let q = ask model "critic" "Rate:\n{p}"` — a legal `let` of
type `text`, inlined per site, so *k* uses cost *k* events, while `q <- ask model
"critic" "Rate:\n{p}"` used *k* times costs one. Two spellings one character
apart, the same words on the page, and bills that differ by a factor of *k*. That
is the two-spellings violation in its purest form:

```
a `let` names a function; `q` names an answer, and an answer is bound where
it is asked — write `q <- ask …` in the block that uses it
```

One test on the synthesized type. It makes §7.2's justification for `let` true
rather than aspirational — *a `let` names a step of the program's vocabulary, not
a step of its execution* — and it removes the worst cost surprise the round could
have shipped.

**Pre-pricing, which is what `asks` is for.** `checkFnsList` refuses a *function*
whose inlining would exceed `maxQuestions` **before elaborating a node of it**
(`Check.lean:899–902`), and `fn-import-design.md` sells that as a property. A
`let` would lose it. So the normalizer prices `uses × letAsks` before it inlines,
and refuses **at the use site** — which, unlike `checkProgram`'s bound, has a
position:

```
this use of `library.logged` writes 2 questions and the program is already at
4095 of 4096; a static function is inlined at every use — bind its parts above,
or make it a `function`
```

**And the honest half, recorded rather than repaired.** `checkProgram`'s own
oversized refusal is `⟨⟨0,0⟩, "this program elaborates to N questions …", ""⟩`
(`Check.lean:943–945`) — no line, no excerpt — and it is theorem-quoted by
`checkProgram_oversized` (`Dsl.lean:706`). **It cannot gain a position without
restating that theorem, and round 18 does not restate it.** The normalizer's
pre-check is what puts a position on the common case; the `⟨0,0⟩` refusal stays
as the backstop it has always been. This is stated in §5.4 too, because that is
where a reader looking for it will be.

---

## 5. Kleisli versus pure composition, precisely

### 5.1 There is one arrow, and it is effectful

This is the decision the rest of §5 rests on, and it deserves to be derived
rather than asserted.

Ask what a *pure* function would be here. The language has **no expression
language over values**: rule 3 says there is no test, comparison, arithmetic or
transformation, and round 17 kept it. So the only things a function can do with
an argument are: splice it into a prompt, pass it on, or branch on it (and
branching is not writable in a body). It follows that:

* every `function` has the shape `c₁ → … → cₙ → M cₖ` — it takes answers and
  produces a *question-asking computation*;
* a `function` that asks nothing is writable (`function id (a) -> text { a }`
  elaborates to `Plan.ret`), so "pure" is a *property of a particular body*, not
  a *type*;
* to make `.` mean pure composition and `<<<` mean Kleisli composition, the type
  system would have to separate those two, which is an **effect system** — and
  the owner's directive 4 asks for "a very limited typing discipline".

> **Ruling: there is one arrow, `a -> b`, and it means "given `a`, ask some
> questions, answer `b`." It is the Kleisli arrow of the plan monad. There is no
> pure arrow to distinguish it from.**

**And so `.` and `<<<` denote the same operation, at the same type, differing
only in fixity and direction.** The draft justified this by citing
`Control.Category`, and the citation was false in a way that mattered:
`Control.Category.(.)` and `Prelude.(.)` are *different operators* that cannot
both be in scope unqualified; `(<<<) = Control.Category.(.)`, which at the
Kleisli category is `(<=<)`, **not** `Prelude.(.)`. `Prelude.(.)` at `infixr 9`
is pure composition and is not Kleisli composition of anything. So the honest
statement, which keeps the decision and drops the false claim:

> **This language has one category, so `.` and `<<<` cannot be distinguished.**
> Haskell keeps them distinct because it has both `(->)` and Kleisli categories,
> and it inherits two fixities from that distinction. Round 18 keeps **Haskell's
> numbers** — `infixr 9` and `infixr 1` — so that the parse never surprises a
> reader who knows them, and states plainly that here the two operators denote
> the same composition. **We take the numbers, honestly; we do not claim to have
> taken the operators.**

**The one exemption from the two-spellings rule, stated rather than assumed.**
The house rule — *two spellings for one thing is a violation* — is applied
ruthlessly on this page: C14 refuses `ret` because it would be `answer` again;
§3.7 refuses sections on the noise audit's own criterion; §9.4 refuses three of
five calculus sites as noise. It is **not** applied to the operator set, where
this page cheerfully advertises nine spellings of one normal form (§5.3). That
is a deliberate exemption and it needs to be visible:

> **The composition operators are the one place where this language admits
> several spellings of one meaning. They are Haskell's, taken whole, because a
> reader who knows Haskell should not have to check which subset survived.
> Everywhere else, one spelling.**

That exemption is exactly what owner ruling 9 licenses, and it is also what
bounds it. `>>=` and `=<<` are in (C33) because ruling 8 *defines* `>>>` by
`>>=` and Haskell has them. **`>=>` and `<=<` are out**, and the reason is the
same rule read the other way: Haskell has `>=>` because it has more than one
category and needs a Kleisli-specific spelling. Here there is one category, so
`>=>` **is** `>>>` and `<=<` **is** `<<<` — the same operator at the same type
with the same fixity. Adding both spellings would be two names for one arrow,
which is the violation the exemption does not cover.

**The monad is invisible in the type language.** There is no `M` in the surface
type grammar (§4.1) because hoisting erases it: an expression of "type `M c`"
becomes a binder of kind `c` plus a statement above. That erasure is what makes
"a simplified Haskell with a very limited typing discipline" honest rather than
aspirational.

### 5.2 The flow operators, and their coherence (C10, C33)

Owner ruling 8 fixes the meanings, and C10 realizes it exactly:

> ```
> (f . g) x     ==  f (g x)                      -- pure composition
> (f >>> g) x   ==  f x >>= g  ==  y <- f x; g y -- Kleisli (Haskell's >=>)
> f x >>> g     ==  y <- f x; g y                -- effect on the left: the
>                                                --   degenerate arrow from Unit
> ```
> `<<<` flips both. `.` over questions is refused, and the diagnosis names `>>>`
> (§3.5). **Both normalize to bind chains — the static story holds.**

Which is to say the rewrite table of §1.2 *is* the ruling, transcribed:

```
f >>> g   =  \x -> g (f x)          f, g arrows      -- Kleisli composition
v >>> g   =  g v                    v a value        -- effect on the left
m >>= g   =  g m                    m a value        -- the same bind
g <<< f   =  \x -> g (f x)          f, g arrows
g <<< v   =  g v                    v a value
g =<< m   =  g m                    m a value
f . g     =  \x -> f (g x)          f, g arrows      -- the mirror of >>>
```

and every right-hand side then hoists to `y <- f x; g y`, which is the ruling's
own do-block. **`v >>> g`, `m >>= g` and `y <- v; g y` are one normal form**, and
that is C33's whole justification: `>>=` is not a new operation, it is the
spelling Haskell uses for the case where the flowing side is a computation.

**Why the arrow/value overload on `>>>` is safe.** The two rules are disjoint by
the *synthesized type* of the operand, which is known before the operator is
elaborated, with no inference and no backtracking. There is no expression whose
type is both an arrow and a kind.

**Coherence with the fixity, which is the part worth checking.** `>>>` is
`infixr 1`, so `a >>> f >>> g` parses as `a >>> (f >>> g)`. Normalizing:

```
a >>> (f >>> g)   ⟶   (f >>> g) a   ⟶   (\x -> g (f x)) a   ⟶   g (f a)
(a >>> f) >>> g   ⟶   (f a) >>> g   ⟶   g (f a)
```

**Both associations reach the same normal form**, so the reader never has to know
the fixity to know the meaning. The same holds for `<<<`, and for `>>=` at its
own associativity: `a >>= f >>= g` is `(a >>= f) >>= g` by `infixl 1`, which is
`g (f a)` — the same term. Add all three to the battery as normal-form
equalities. Mixed chains are refused (§3.5), so no case where the fixities
*disagree* is reachable.

### 5.3 What the owner's spellings elaborate to

Given `f : text -> text` and `g : text -> verdict` (both `function`s) and a
binding `x : text`:

| Spelling | Rule | Normal form |
|---|---|---|
| `y <- f x`  `g y` | round-17 do-notation | `!L:C <- f x` ; `g !L:C` |
| `f x >>> g` | (>>>val) | *the same* |
| `f x >>= g` | (>>=) | *the same* |
| `g <<< f x` | (<<<val) | *the same* |
| `g =<< f x` | (=<<) | *the same* |
| `(g . f) x` | (.) then (app) | *the same* |
| `g . f $ x` | fixity 9 then 0 | *the same* |
| `g (f x)` | (app) then hoisting | *the same* |
| `(f >>> g) x` | (>>>arr) then (app) | *the same* |

**Nine spellings, one normal form**, and the identification is by normalization
rather than by a table of special cases. That is the whole content of directives
1 and 2, and of owner ruling 8.

**How it is pinned, which the draft got wrong.** The draft proposed `decide` on
`Raw` equality — *"`Raw` derives `DecidableEq`, so this is one `decide` per
pair"*. It does, and the pins would all fail: `Raw` carries a `Pos` on
essentially every node (`RawAsk.pos`, `RawArg.name x pos`, `RawRhs`, every
`RawBlock` constructor, `RawFn.pos`/`answerPos`, `Syntax.lean:190–334`), and C26
mints hoisted binder **names** from line and column. Nine differently-spelled
programs occupy different columns, so their `Raw`s differ in both positions and
binder names. The pin as written proves nothing, or rather proves nine
inequalities.

> **The nine-spellings battery is decided on TRACES, not on `Raw`.** `Plan.trace`
> over a fixed `Ω` yields a list of events, and **an event carries no position
> and no binder name** — it carries the question shape, the addressee, the draw
> index and the answer. Two spellings of one program are the same program exactly
> when they ask the same questions in the same order and bill the same, which is
> what a trace says and what a reader means. `DslSmoke` already decides trace
> equality this way (`:1014`, the block-versus-string prompt pin), so the
> instrument exists and needs no new `DecidableEq`.

**The alternative, recorded.** A position-and-temp-erasing view — `Raw.shape :
Raw → Shape`, dropping every `Pos` and rewriting temporaries to de Bruijn indices
in binding order, with `DecidableEq Shape` derived — would pin *syntactic*
identity rather than observational identity, which is strictly stronger. It is
**not taken**, for two reasons: it is a new type and a new derived instance in a
round whose whole claim is that it adds neither, and it would pin a property
nobody has asked for (that two spellings produce the same *tree*) in place of the
property everyone means (that they produce the same *run*). If a later round
wants the stronger pin, `Raw.shape` is where to put it.

### 5.4 Cost and trace through normal forms (C24)

> **`blockAsks`, `bodyAsks` and `rhsAsks` are unchanged** (`Check.lean:860–890`)
> **because they run over `Raw`, and `Raw` is the normal form.** So is
> `maxQuestions` (`:857`, guards at `:900` and `:943`), so is `overRevised`
> (`:915`), so is every bill and every trace.

Stated exactly: normalization happens inside `parseProgramWith`
(`Parse.lean:1291`); `checkProgram` (`Check.lean:932`) receives a `RawProgram`
that has already been normalized; **`blockAsks` never sees a lambda, a `.`, a
`$`, a `>>>`, a `>>=`, a `let`, or a partial application.**

The derived recurrence, for a reader of the *surface*:

```
asks(stmt)         = Σᵢ asks(sᵢ) + asks(head)     -- sᵢ the hoisted sources, post-order
asks(f . g)        = asks(g) + asks(f)            -- g's questions first
asks(v >>> g)      = asks(v) + asks(g)
asks(m >>= g)      = asks(m) + asks(g)
asks(a `let` use)  = asks(its normal form), per site
asks(if b … …)     = asks(b's hoists) + asks(yes) + asks(no)
asks(arm)          = a hoist inside an arm counts inside that arm only
asks(revising)     = unchanged — C19/D15 means a loop clause hoists nothing
```

**The order rule** (round-17 §5.1, widened): the questions a statement asks are
put in the order its sub-expressions are hoisted — post-order over the
**normalized** statement, at first occurrence (§1.2) — followed by the
statement's own question, and that is the order of the events in the trace. For
composition this reads: **`f . g` asks `g`'s questions before `f`'s, because the
data flows that way.** For `>>>` and `>>=` it reads left to right. Both are "the
direction the value moves", stated once.

**Positions, decided.** A question's `Pos` is **where its words are written**,
and for a question that came from an inlined `let` that is the **use site** — the
outermost position in its minting chain (§8.8). A `let` has no rung, no plan
entry and no line in `agent-cat plan`, so the use site is the only place a reader
can act. The `let`'s own body position is carried as **provenance** and printed
as a second column:

```
harden-imported.wf:62:19   ask model "scribe"   (via library.logged, library.wf:41:22)
```

This is C32's discipline applied to cost reporting, and it settles the draft's
one internal contradiction: §5.4 said the position is the `let`'s body and §9.3
printed use sites. **The use site wins, and §9.3 is correct as printed.**

**The honest new hazards, all four named.** Before round 18 you could count a
program's questions by counting `ask`s, panels and calls on the page. After round
18 you cannot:

1. **A `let` used *k* times costs *k* times its body.** Its mitigation is
   `agent-cat cost` and `agent-cat plan`, which run on the elaborated plan and
   have always been the answer to that question.
2. **An arrow *argument* applied twice asks twice.** `let twice = \(f : text ->
   text) -> \x -> library.judged (f x) (f x) library.spec` asks `f`'s question
   *twice* from one written argument — the exact inverse of hazard 1 and of
   C25's second line. See §5.5.
3. **A question inside a function value is asked once per application, and not at
   all if the value is never applied.** `library.checked (\z -> ask model
   "critic" "Rate:\n{z}")`, where `checked`'s body drops its parameter,
   normalizes the lambda away and never asks. Words on the page that cost
   nothing, which is hazard 1 read backwards.
4. **A static function that uses its arguments out of written order asks them in
   use order** (§1.2).

All four go in `GRAMMAR.md`'s "Hazards, named", and all four have the same
mitigation, which is the twelfth of the survey's differentiators and the reason
those commands exist: **`agent-cat plan` is the page's answer to "what will this
ask, and where did it come from".**

**And the refusal's position, stated plainly.** When hazard 1 fires hard enough
to cross `maxQuestions`, `checkProgram`'s refusal lands at `⟨0,0⟩` with no line
and no excerpt (`Check.lean:943–945`), because it is theorem-quoted by
`checkProgram_oversized` (`Dsl.lean:706`) and round 18 does not restate that
theorem. **That is accepted.** §4.5's per-`let` pre-pricing is what puts a
position on the case a real author will hit.

### 5.5 Divergence 3: substitution sharing, in three lines (C25)

Round 17 stated two divergences from Idris. Round 18 adds a third, and this one
is a divergence from a *naive* reading of the calculus rather than from another
language. The draft stated two of its three lines; the third is the one that
costs money.

> **1. Two questions *written* are two events.**
> ```
> compare (ask model "critic" "Rate:\n{p}") (ask model "critic" "Rate:\n{p}")
> ```
> — two events, one answer, `billFresh` 2, `billMemo` 1, `blockAsks` 2 (round-17
> D12, unchanged).
>
> **2. One *source* argument substituted twice is one event.**
> ```
> (\x -> compare x x) (ask model "critic" "Rate:\n{p}")
> ```
> — **one** event, one answer, `billFresh` 1, `blockAsks` 1, because a source
> argument is hoisted to one binder before substitution (C2).
>
> **3. One *arrow* argument applied twice is two events.**
> ```
> let twice = \(f : text -> text) -> \x -> compare (f x) (f x)
> twice (library.revised) draft
> ```
> — **two** events, one answer by D12's sharing, `billFresh` 2, `blockAsks` 2,
> because an arrow is substituted as a *term* and each occurrence is then applied
> in its own right.

Line 2 is what `x <- ask …` then `compare x x` means, and it is what a reader
expects a lambda to do. Line 3 is what a reader expects a *function* to do, and
it is the reason line 2 could not simply be generalized to "arguments are
shared". Getting all three required the source-versus-term criterion, which is
why C2 is a decision and not an implementation note. All three go in the battery
with their bills.

**The same divergence one level up, pinned beside them.** A `let` of arrow type
applied twice is line 3 with no lambda in sight:

```
let q = \x -> ask model "critic" "Rate:\n{x}"
compare (q p) (q p)        -- TWO events, one answer  (arrow, applied twice)
(\y -> compare y y) (q p)  -- ONE event,  one answer  (source, substituted twice)
```

Two spellings, one character of difference in shape, and a factor of two in
`billFresh`. Both lines go in the battery, and one line goes in the guide: **a
static function applied twice asks twice; an answer bound once and used twice
asks once.**

**And the eta pin.** `library.checked (library.revised) shape` and
`library.checked (\x -> library.revised x) shape` must reach the same trace —
that is the eta equation of §1.2 doing its one job — and it is one `decide` on
traces.

### 5.6 The CLI (C29)

**No new subcommand.** An `agent-cat norm` that printed the normal form was
considered — it would be genuinely useful while the parser is being written —
and is refused as scope: `agent-cat plan` already enumerates every question with
its rung and its position, and now with its provenance (§5.4), which is the
user-facing question ("what will this ask, and where did it come from"), and a
normal-form dump is a *compiler* question. If the campaign wants one, it belongs
behind a debug flag in the implementation obr, not in the language design.

---

## 6. The bang's fate: dropped (C19)

### 6.1 The criteria, then the answer

Round 17's noise audit asked three questions of every construct. Asked of
`!(…)`, now that parentheses, lambdas, `$` and `>>>` exist:

| Criterion | Answer |
|---|---|
| Does it distinguish two readings that would otherwise collide? | **No.** `judged (drafted g a) r` and `judged !(drafted g a) r` have one reading each, and it is the same one. Round 17 said so itself: *"the parentheses remove the ambiguity, which is precisely why the feature is safe now and was not before"* (§6.1). |
| Does it warn the reader of a cost they could not otherwise see? | **No more than the callee's name does.** `drafted` is a question either way; the `!` adds a glyph, not a fact. And `agent-cat cost` is the actual answer (§5.4). |
| Is it in the language the owner asked us to follow? | **No.** Haskell has no bang, and ruling 9 makes Haskell the default; Idris's means "run this action", which §5.3 of round 17 had to spend two divergences correcting. |

> **Decision: `!` is dropped, and `punctChars` does not gain it.** Round-17 D3,
> D4, D5 and D11's *trigger* are superseded; D11's *traversal* (post-order)
> survives inside C2's one traversal, applied to every nested source rather than
> to marked ones.

**The counter-argument, recorded fairly.** The bang made "this argument costs
questions" visible at a glance, and dropping it means a reader of
`judged (drafted g a) r` must know that `drafted` is a function rather than a
binding. That is a real loss. It is accepted because the language already
requires that distinction everywhere else — a statement `f x` is a call exactly
when `f` is a function, and has been since round 16 — and because C8 (*a
function or `let` name is an atom only in head position*) means a bare name in an
argument position is **never** a call, which localizes the reader's question to
"is there a paren here".

### 6.2 The timing, which is a saving

**Round 17 has not shipped.** Under the owner's "one design, then one campaign"
ruling, the bang's parser plumbing — `parseBang`, the D4/D5/D9 refusals, the
`!`-in-`punctChars` change, six accepted battery cases and twelve refusal cases —
is **never written**. §10.6 credits it: roughly a day of implementation and a
half-day of battery that round 17 had budgeted and round 18 does not spend.

### 6.3 What of round 17 survives (C30)

| Round-17 decision | Fate in round 18 |
|---|---|
| D1 `answer` deleted | **Stands.** The last statement of a body is its answer; §3.9 refuses `ret` for the same reason; C31 keeps the final-**name** case legal and refuses only the final-**literal** case. |
| D2 desugar at parser level, into today's `Raw` | **Stands, strengthened** — it is now C4, the north star, and it is carrying much more weight. |
| D3 where `!` may stand | **Superseded** (C19). Its content becomes: an expression may stand wherever a value may stand. |
| D4 `!x` refused | **Superseded** — there is no `!`. The *content* survives as C25's note that a name is already an answer, and as C31's vacuity refusal, which is the same observation with teeth. |
| D5 `!(…)` as a whole statement | **Superseded** — `(ask q)` as a whole statement is now just `ask q` with redundant parens, which is accepted and harmless. |
| D6 no `!` / no expressions inside prompt text or a `{hole}` | **Stands, and is now load-bearing for six operators.** Prompts stay byte-literal; `$`, `.`, `\`, `<` and `>` inside prompt text are prose (§8.6). Its proof-side reason survives: `expand_lit`, `expand_interp_hit`, `expand_append` (`Parse.lean:574, 577, 583`) are unchanged *because* a `Chunk` never contains a source — and C26's prompt rewriting (§8.8) does not disturb them, because it maps `Chunk.interp` to `Chunk.interp` and says nothing about `expand`. |
| D7 no question as a panel member | **Stands**, restated: a panel's members are `ask`s, not expressions. A panel of *k* members costs *k* questions in every world, and the monoid, the trace and the cost model are stated over questions. |
| D8 no expression as a `revising` subject | **Stands**, on the same taste-plus-technical grounds (`revising draft as patch` is a sentence whose subject is a noun; and the subject is the one name position whose grounding runs through `useKindS`'s carrier clause, `Check.lean:235–245`). |
| D9 no `$label` inside a nested call | **Stands, and widens — implemented where the information is.** `$label` is not an `atom` (§3.1); it belongs to the `call` production. The widening is a check **after `collectLabelled` returns** (`Parse.lean:707–720`): a call that carried at least one `$label` may not be an operand of any operator and may not be an argument, because its labelled fences are collected *after its arguments* and there is nowhere to put them. Refusal: `` a call carrying `$rubric` collects its fences after its arguments, so it is a statement, not an operand — bind it above and use the name ``. |
| D10 temporaries minted already-qualified | **Stands** (C26), with the mint key widened from a position to an **inlining chain** (§8.8), and now also serving static-binder renaming and parse-time lambda-binder minting. |
| D11 post-order | **Stands** as C2's traversal, and is now *one* traversal rather than a phase after beta. |
| D12 sharing: two identical questions are one answer | **Stands**; C25 adds two lines beside it. |
| D13 no change to the function header | **Stands** for `function`; `let` is a *new* header, not a change to that one (§7). |
| D14 `amend`, `as`, `stop`, `known here` all kept | **Stands.** |
| D15 no lifting site inside a `revising` clause | **Stands, and matters more, and the calculus creates two refusals it did not name.** A clause is a single `RawRhs` slot (`Syntax.lean:239–241`), so there is nowhere to hoist; hoisting out of the loop would ask once instead of once per round and would break `blockAsks`'s `(n+1)·review + n·amend` recurrence. **New (a):** a `let` whose normal form is more than one statement cannot stand in a review or amend clause — `` a revising clause is one question per round, and `library.logged` writes two; bind its parts above the loop, or call a `function` ``. **New (b):** `revising` is not in `source'` (§3.1), so a loop cannot be an operand at all — `` a `revising` loop is a statement, not an expression; bind it — `r <- revising …` — and case on the result ``. Two diagnoses, two battery cases. |
| D16 parameter annotations default to `text` | **Stands** (C15), extended to lambda binders — and §4.3 now states the divergence from rule 4's inference for `<-` binders, with its diagnosis, instead of leaving two opposite policies implicit. |
| D17 `-> receipt` bodies do not lift | **Stands, restated for the new trigger.** In round 17 the trigger was the bang and the rule meant "the terminal stays `.act`/`.callS` with `answer := none`". In round 18 the trigger is *every nested source*, and a receipt body can now contain one. So: **a `-> receipt` body's *final statement* is not lifted into a binder — it stays `.act`/`.callS` with `answer := none`; sources *nested inside* any of its statements, final included, hoist exactly as elsewhere.** The clause is still keyed on `result : Code`, which `parseFnBody` already has (`Parse.lean:1025`). Worked in §9.3. |
| D18 trailing bindings refused in blocks, arms and bodies, not in a priming | **Stands.** |
| D19 the fence-close drift | **Stands, is still required, and is widened by round 18 rather than merely carried.** `fenceCloses` (`Parse.lean:210–219`) must accept `)` and a trailing comment, because a parenthesized question ending in a fence puts a `)` there. Round 18 makes a fenced block an *operand*, so the follower set must also admit the operator starts — §8.7 states it as a round-18 lexer change, which is what it is. |
| D20 `answer` deleted cold, one migration clause | **Stands**, and `let` takes the vacated slot in `stmtWords` (§7.2), which edits the same two pinned strings (§10.6). |
| D21 the showcase is the pair, not the flagship | **Stands** (C28). |

---

## 7. Declaration syntax

### 7.1 `function`: no change (C-carry of D13)

```
function name (params) -> kind { do-block }
```

**Kept**, and the round-17 reasoning is unchanged and is now reinforced: the
braces *are* the do-block; the parameter names stay in the signature where a
reader looks for them; the result kind stays beside the brace that opens the
body; and `parseFnBody env fname result` dispatches on the result (D17). The
Idris-style separated signature (`drafted : text -> text -> text -> text` on one
line, `drafted guide goal shape = …` on the next) is refused for the same three
reasons round 17 gave — and now for a fourth: with `let` in the language, the
point-free/curried style has a home, and giving `function` two spellings would
blur the stratum split (C5) that the whole higher-order story rests on.

### 7.2 `let`: taken, at the top level only (C6)

> ```
> let name [ : type ] = expr
> ```
>
> A **header**, in the header stratum with `define` and `function`, before the
> `workflow` block or the priming. Its right-hand side is a static expression of
> **arrow type** — a `let` whose synthesized type is a base kind is refused
> (§4.5). It is **closed**: it may mention `define`s, `function`s and `let`s
> **declared above it**, and nothing else — never a runtime binding — and its
> body is stored **fully qualified** at declaration, which is what makes
> inlining a pure substitution (§4.5).

**Why `let` earns its place now, when round 17's audit killed it.** Round 17
refused `let` on the ground that there was no pure computation to name: every
right-hand side was a question, and questions are bound with `<-`. Round 18
creates exactly the missing thing — a composed arrow, a partial application, a
lambda — none of which is a question and none of which can be bound with `<-`
(they are not answers). `let review = judged . normalize` names a *step of the
program's vocabulary*, not a step of its execution. **The base-kind refusal of
§4.5 is what makes that sentence true rather than aspirational**: without it,
`let q = ask …` would be a `let` naming a step of *execution*, one character away
from `q <- ask …` and costing *k* times as much.

**Why top-level only, and why closed.** Rule 2 of `GRAMMAR.md` says: *"A name is
introduced only left of `<-`, as a `settled` arm's binder, or at a loop head's
`as`. Nothing is bound by a keyword's position."* A statement-position `let`
would break that flat, and would introduce a **second class of name inside a
block** — one that `known here` must not list, that `agent-cat plan` shows
nothing for, and that a reader would have to classify before knowing whether it
cost anything. A *header* does not break rule 2, because a header is not a
statement — exactly as `define` is not. Closedness is what makes the rule
checkable in one line and what lets the body be qualified once, at declaration.

Refusal for the statement position:

```
a `let` names a static function and belongs with the other headers; inside a
block, `<-` binds an answer
```

**The keyword cost, paid in the open.** `let` joins `stmtWords`
(`Parse.lean:522`), so `let` stops being a legal binder, parameter or function
name. That is one word out of the namespace, on the same list as `define` and
`function`, and it is the whole price — with one consequence the draft did not
name: `freshOfTables` interpolates `stmtWords` **verbatim** into its refusal
(`:531–534`), and that full list appears byte-for-byte in two `DslSmoke` cases
(`:510`, `:573`). Adding `let` and removing `answer` (D20) edits both messages
and both pins. §10.6's churn table names them.

**Namespace, corrected.** The draft put a `let` "in the function namespace", so
that `freshOfTables`'s function clause covers it and `resolveFn` finds it. The
second half of that sentence breaks call emission and is replaced by §4.5's
three changes: `let`s live in **their own table**, `freshOfTables` gains a
**fourth clause** with its own message, and head dispatch consults `lets`
**before** `resolveFn`. What survives is the guarantee: a binder may not spell a
`let`, a `let` may not spell a define or a function, and every name in a program
still means exactly one thing.

### 7.3 What rule 2 and rule 3 become

`GRAMMAR.md`'s rule 2 gains one clause and rule 3 needs one honest rewrite:

> **Rule 2 (revised).** A *runtime* name is introduced only left of `<-`, as a
> `settled` arm's binder, or at a loop head's `as`. A *static* name is
> introduced by a `let` header, a `let`'s lambda binder, or a lambda binder at
> an expression position — and every static name is gone before the program
> runs. **No shadowing (rule 6) is a rule about runtime names.** A static binder
> is minted to a temporary at parse time (C36), so it cannot collide with a
> runtime name by construction; a static **header** name is checked against the
> tables by `freshOfTables`, which is a different rule and is unchanged.

> **Rule 3 (revised).** There are two consumption sites for an *answer* —
> `{x}` in a prompt, and `if x` / `case x` — and no third. There is now an
> expression language over **functions**, and it has no operations on
> answers at all: no test, no comparison, no arithmetic, no transformation.
> Every value a program computes is still the answer to a question that is
> written on the page, and "who can see what" is still answered by reading one
> statement — because every expression hoists into the statement it sits in.

The second is the sentence a reviewer will attack, and it should be attacked. It
is defensible exactly because §5.1's ruling is true: the calculus can move
answers around and can name the moving, but it cannot *inspect* one. The five
operators are all composition; none of them is a function of a `text`.

---

## 8. Collisions, enumerated and resolved

### 8.1 The dot (C20)

**Today**, a dot is *only* legal glued between two identifiers. `lexAux`'s ident
branch (`Parse.lean:385–399`) matches `'.' :: d :: _` and glues **only when
`isIdentStart d`**; every other dot falls to `punctChars.contains c`
(`:399–400`), which does not contain `.`, and then to `.error ⟨p, "unexpected
character", …⟩` (`:402`). So:

> **A spaced dot is a lex error in every program that exists today, which makes
> the composition operator byte-compatible by construction.**

**The rule.**

> A `.` is **qualification** iff it is immediately preceded by an identifier
> character and immediately followed by an identifier start, with **no
> whitespace on either side**. Every other `.` is the **composition operator**.

| Written | Lexes as | Means |
|---|---|---|
| `lib.f` | one `.ident "lib.f"` | qualification — **unchanged, today's path** |
| `f . g` | `.ident "f"`, `.punct '.'`, `.ident "g"` | composition |
| `f .g` | same three | composition |
| `f. g` | same three | composition |
| `a.b.c` | `.ident "a.b"`, then a **refusal in the ident branch** | refused — *"modules do not nest"* |
| `3.5` | a refusal in the dot branch | refused — a number-adjacent dot |

**The implementation is a dedicated lexer branch, not a `punctChars` entry**, and
this is the correction the attack forced twice. The draft said *"the
implementation is two lines: add `'.'` to `punctChars`"*, and stated in the same
table that `a.b.c` stays refused. **Both cannot be true.** Today `a.b.c` lexes as
`.ident "a.b"` and then the trailing `.c` falls to "unexpected character"; after
`.` joins `punctChars`, the same input lexes as `.ident "a.b"`, `.punct '.'`,
`.ident "c"` — a perfectly legal **composition** of `a.b` with `c`. The rule (C20)
says the second dot *is* qualification, because it is flanked by identifier
characters, and so the line must stay refused; the proposed implementation
deleted the refusal without anyone deciding to.

So the rule is implemented on **both** sides, where each side's information is:

1. **In the ident branch** (`:385–399`), which already tests the glue: after
   gluing one dot, if `rest0` again begins `'.' :: d` with `isIdentStart d`,
   refuse *at that dot*:
   ```
   modules do not nest: `a.b.c` names `c` in module `a.b`, and a module has no
   submodules; composition is written with spaces, `a.b . c`
   ```
   One added test in the branch that already does the test, before any
   fallthrough can see it.
2. **In a new `.` branch**, placed beside the `-`, `<` and `$` branches rather
   than in `punctChars`, so that it can look at what precedes it. A `.`
   immediately preceded by a **digit** is refused with its own message:
   ```
   a number is written without a decimal point in this language; a spaced `.`
   composes two functions
   ```
   Every other `.` is `.punct '.'`, the composition token.

Note that `f. g` and `f .g` both composing follows from the *existing* code, not
from a new rule: the glue requires `isIdentStart d` where `d` is the character
after the dot, and a space fails it.

**The one new mistake the rule creates, and its diagnosis.** An author who means
composition and forgets the spaces writes `f.g`, which lexes as a qualified name
and reaches `resolveFn` (`Parse.lean:647–649`) as `"f.g"`. Key the message on a
dotted name whose prefix is not an imported module:

```
`f.g` names `g` in module `f`, and no module `f` is imported; composition is
written with spaces: `f . g`
```

And the mirror, when the prefix *is* a module: `library . spec` (spaced) is
composition applied to a module name, refused with

```
`library` is a module, not a function; a module's member is written without
spaces: `library.spec`
```

Four battery cases: the two above, `a.b.c`, and the number-adjacent dot.

**Holes are unaffected.** `scanHole` has its own dotted-name rule
(`Parse.lean:120–142`) and runs inside `scanString`/`scanBlockChunks`, never
through `lexAux`. `{library.spec}` is byte-identical, and `{f . g}` is refused
by `scanHole`'s existing *"a hole is `{name}`"* diagnosis, which is the right
answer under D6.

### 8.2 Dotted names as function heads and as arguments

`library.judged patch rubric context` — the head is one `.ident` token,
`resolveFn` resolves it (`Parse.lean:647–649`), arity-directed reading proceeds.
Unchanged.

`library.filed . (library.summarised patch)` — three tokens, then a
parenthesized partial application: `.ident "library.filed"`, `.punct '.'`, `(`,
`.ident "library.summarised"`, `.ident "patch"`, `)`. Composition of a qualified
name with a partial application of another. The whitespace rule does all of the
lexical work and no new resolution rule is needed; the parentheses are C8's
right-operand rule (§3.4), not the lexer's business.

### 8.3 `$` versus `$label` (C21)

**Today**, `$` is legal *only* when immediately followed by an identifier start
(`Parse.lean:372–384`); a `$` followed by a space, a `(`, or end of input is
refused with *"a `$name` names a labelled block argument; a name follows the
dollar"*. So a spaced `$` is a lex error today, and the operator is again
byte-compatible.

> **The rule, stated on the right-hand side only, which is where today's code
> already looks.** `$` immediately followed by an identifier character is a
> `$label` token. `$` followed by anything else — whitespace, `(`, `\`, a
> string — is the **application operator**.

| Written | Lexes as | Means |
|---|---|---|
| `f $rubric` | ident, label | a labelled-block argument — **unchanged** |
| `f $ x` | ident, op, ident | application |
| `f $(g x)` | ident, op, … | application (the `(` is not an identifier start) |
| `f$ x` | ident, op, ident | application |
| `f$x` | ident, label | a labelled-block argument (attachment wins) |

The last row is the only surprise, and it is the *existing* behaviour: `$x`
attached is a label today and stays one. Haskell's `$` is conventionally spaced,
`$label` is by construction attached, and the two never meet. Pin all five rows.

**And the language does now ask the reader to look at a space in two places** —
here and at the dot (§8.1) — which §3.7 uses as a reason to refuse sections. The
two are not the same ask, and the difference is why one is safe and the other is
not: `$` and `$label` are never in the **same position**, because an operator's
right operand cannot be a bare label, so no single site has two readings. A
section would put two readings of `.` at one site. One space to check per
character, never two per position, is the rule the language holds itself to.

**But the diagnosis is extended**, because round 18 is the round that *creates*
the mistake. `f$x` with no fence following produces today's *"``$x`` names no
labelled block: write ```` ```x ```` after the call's arguments"*, which says
nothing about the far likelier reading. One clause is added when the label is
immediately attached and resolves to a live name or a table entry:

```
…or, if you meant application, `$` needs a space: `f $ x`
```

Pinned as a sixth battery case beside the five rows.

### 8.4 `\` (C22)

`\` is not in `punctChars` and has no branch in `lexAux`, so today it reaches
*"unexpected character"* (`Parse.lean:402`). Adding a lambda branch is purely
additive.

**Prompts are unaffected, with the lines.**

* **Fenced blocks:** `scanBlockChunks` (`Parse.lean:283–301`) treats `\{` and
  `\}` as literal braces and **every other backslash as a literal character** —
  the docstring at `:280–283` says so: *"every other character — quotes, lone
  backslashes, short backtick runs — is literal, so pasted Markdown survives
  verbatim except for `{`."* A prompt containing `\n`, a Windows path or a LaTeX
  macro is unchanged.
* **Quoted strings:** `scanString` (`Parse.lean:154–171`) already owns `\` as
  the escape character with a closed list (`\n \t \r \\ \" \{ \}`) and refuses
  the rest. Unchanged.
* Neither scanner is reached from `lexAux`'s dispatch except through `"` and
  `` ` `` (`:354–367`), so **a lambda's backslash and a prompt's backslash never
  meet.**

### 8.5 `>>>`, `<<<`, `>>=`, `=<<` (C23)

* `<` today: `.arrow` on `<-`, else *"stray `<`; `<-` binds an answer, and
  nothing else in the language begins with one"* (`Parse.lean:349–353`). Extend:
  `<<<` before the arrow test; the stray message gains `<<<`.
* `>` today: no branch at all — `-` handles `->` at `:346`, so a bare `>` is
  *"unexpected character"*. Add a branch: `>>>`, `>>=`, else a stray-`>` message
  in the same voice: *"stray `>`; `>>>` is a pipeline and `>>=` a bind, and
  nothing else in the language begins with one"*.
* `=` today: `.punct '='`, used by `define`, `let` and nothing else. Extend: `=<<`
  before the punct emission; a lone `=` is unchanged.
* `>>` and `<<` are **not** tokens and are refused by the same messages.
  Haskell's `>>` (sequence) has no place here: statements sequence by being
  written, and D1 already made that the language's whole position on sequencing.
* **The stray-`-` message is reworded**, which the draft did not name and which
  is a pinned string. Today it reads *"`--` begins a comment and `->` a
  function's result, and nothing else in the language begins with one"*
  (`:347–348`) — and after C13, `->` has three jobs. New wording, in the same
  voice as the `<` and `>` ones:
  ```
  stray `-`; `--` begins a comment and `->` a result, a lambda's body or a
  function type, and nothing else in the language begins with one
  ```

All of `>>>`, `<<<`, `>>=`, `=<<`, `>>` and `<<` are lex errors today, so no
existing file changes meaning.

### 8.6 Operator tokens inside prompt text stay literal

`$`, `.`, `\`, `>`, `<`, `=`, `!` and every other operator character inside a
prompt — in either spelling — is literal, because a prompt is lexed by
`scanString` or `scanBlockChunks` as **one token** and neither scanner consults
`punctChars`. The only characters with meaning inside a prompt are `{`, `}` and
`\` before a brace. This is round-8's byte-literal decree, round-17's D6, and the
reason the guide can say *"a prompt is what you wrote"* without a caveat list.

Battery: one prompt containing `f . g`, `$x`, `\`, `>>>`, `>>=` and `!`, checked
byte for byte against the string spelling — the existing two-spellings `decide`
pin (`DslSmoke:1014`) is exactly the right instrument.

### 8.7 The fence-close follower set, widened (D19, extended)

`fenceCloses` (`Parse.lean:210–219`) accepts a closing run followed only by
whitespace, `,`, `]` or `}`; D19 adds `)` and a trailing `--` comment. **Round 18
makes a fenced block an `atom` (§3.1), and therefore a legal operand of every new
operator**, so this does not close:

```
  x <- ask model "m" ```
      rate this
  ``` >>> library.summarised patch
```

`restWs` begins with `>`, `fenceCloses` returns `none`, and the fence silently
becomes unterminated. That is a round-18 lexer change, not a D19 carry, and the
page says so:

> **The follower set becomes `,` `]` `}` `)` `.` `$` `<` `>` `-`** — the existing
> three, D19's `)`, and the five operator starts. `=` is deliberately **not**
> added: no legal shape puts a fenced block immediately before a `=`, and adding
> it would let a missing newline before a `define` swallow the next header.

Six battery pins, one per new follower, byte for byte, plus one **negative**: a
```` ```haskell ```` line inside a three-backtick block is still content, which is
the property `fenceCloses`'s length test exists to protect and the one a widened
follower set could plausibly break.

### 8.8 Temporaries, static binders, and the minting chain (C26, C36)

Round-17 D10 and §2.4 carry, with one widening the attack forced from two
directions at once. (Note that `Dsl.isTemp` and `showName` are round-17
*proposals*: round 17 has not shipped, so they are written for the first time in
this campaign, exactly as D10 specified them.)

* the temporary is minted **already-qualified, once, at the lifter**, routed
  around `PEnv.q`/`qualRefs`;
* `Dsl.isTemp x := x.any (· == '!')` is total and cannot misfire, because
  `isIdentStart`/`isIdentCont` (`Parse.lean:98–100`) admit only letters, digits
  and `_` — so `!`, `:` and `/` are all unwritable in a source name — and note
  that C19 dropping the bang makes this **stronger**, not weaker: `!` is now not
  a token at all, so a temporary's spelling is unwritable by any means;
* **Leak 1**, `known here`: `live` filters temporaries
  (`checkBlock`'s `knownHere` clause, `Check.lean:534–536`), which is the identity
  on every program that exists today and keeps all eight `known here` battery
  cases byte-unchanged;
* **Leak 2**, seven quoting sites get `showName`, and the five theorem-quoted
  messages (`check_panel_nil` `Check.lean:717`, `checkArgs_too_few` `:388`,
  `checkArgs_too_many` `:395`, `checkProgram_overRevised` `Dsl.lean:694`,
  `checkProgram_oversized` `:706`) stay off-limits.

**The widening: the mint key is the inlining chain, not a position.** The draft
minted `x` to `!L:C` where `L:C` is the use site, and two attackers found the
same two holes from opposite ends:

* **Two temporaries, one name, inside one use.** `let dup = \(h : text -> text)
  -> \y -> h (h y)` applied to `\w -> library.revised w` puts **two** copies of
  that lambda, both bearing binder `w`, into one statement at one use site — both
  minting to `!L:C`.
* **Two uses, one body position.** A `let` whose body holds a hoistable
  sub-expression, used twice in one straight-line block, mints that
  sub-expression's temporary from the *body's* position at both sites — the same
  name twice, and the program is rejected for a name the author never wrote.

One rule closes both:

> **Every static name is a temporary, and inlining prepends.** A temporary's name
> is `!` followed by the positions of the inlinings traversed to reach it,
> outermost first, joined by `/`, and ending with the position of its own words:
> `!45:34`, and one level in, `!45:18/62:19`.
>
> * A **lambda binder** is minted at **parse time**, at the binder's own
>   position (C36).
> * A **hoisted source's** temporary is minted at the hoist, at the source's own
>   position (C35).
> * **When a term is substituted at a use site, every temporary inside the
>   substituted copy gains that use site at the front of its chain.**

Consequences, each of which was a separate finding:

1. **Two copies of one body carry disjoint names by construction, at every
   depth**, because they differ at the front of the chain. No alpha-renaming
   pass, no gensym counter.
2. **A program with no `let` mints exactly what round 17 minted.** The chain has
   length one and the name is `!L:C`, byte for byte. The `known here` `live`
   filter, `showName` and every existing battery case are unaffected.
3. **Rule 6 does not apply to static binders** (§3.6, §7.3): a minted binder
   cannot spell a source name, so shadowing is vacuous rather than enforced. This
   replaces the draft's claim that a lambda binder goes through `freshOfTables`,
   which was not implementable — `freshOfTables` has no view of runtime bindings
   (`Parse.lean:530–545`) and a lambda binder never reaches `freshName`
   (`Check.lean:111`).
4. **The chain is bounded by the node budget** (§1.3), so a name cannot grow
   without a refusal firing first.
5. **`showName` suppresses the whole family** — the `!` test is a prefix test and
   does not care how long the chain is.

**And the clause that makes holes in lambda prompts work.**

> **Minting rewrites `Chunk.interp` names inside every prompt of the substituted
> term.** When `\x -> (ask model "critic" "Rate this:\n{x}")` is substituted, the
> hole naming `x` becomes a hole naming `x`'s minted temporary, in the same pass
> that renames the binder.

`\x -> (ask model "critic" "Rate this:\n{x}")` is the **only** way a static
function can build a prompt from its own parameter, and without it the
higher-order half of directive 3 would be nearly ornamental (§3.6). It is taken.

**The `expand_*` theorems are untouched, and here is exactly why.** `expand_lit`,
`expand_interp_hit` and `expand_append` (`Parse.lean:574, 577, 583`) are
statements about `expand`, whose job is to replace holes naming *defines* with
literal chunks. The minting rewrite is a **different** pass: it runs after
`expand`, it maps `Chunk.interp nm` to `Chunk.interp nm'`, and it produces an
`interp` from an `interp`. `expand_append`'s homomorphism statement quantifies
over prompts and is indifferent to which names the `interp`s carry; `expand_lit`
and `expand_interp_hit` are about `expand`'s two clauses and mention no rewrite
at all. **D6 is what keeps them true** — a `Chunk` never contains an `SExpr` —
and C26 does not put one there. The worked case is pinned in §9.3 and in the
battery.

---

## 9. Worked examples

The discipline is round 17's: **use the calculus where it genuinely improves the
program, and leave the program alone where it does not.**

### 9.1 `example/library.wf`

```
-- A library: standing context, shared words, and reusable questions. It has
-- no `workflow` block, so it is imported, not run; its top-level statements
-- are the priming, and they are the first questions of every program that
-- imports it.
--
-- With `example/harden-imported.wf`, this file is the every-feature showcase:
-- `example/harden.wf` is the kernel pin and does not move.

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."
define rubric      = "A patch passes when it is minimal, tested, and reversible. Nothing else counts."

-- Three parameters, all text, so none of them says so. The body is one
-- question and no `answer`: the last statement of a body is its answer.
function drafted (guide, goal, shape) -> text {
  ask model "author" served by "deep" ```
      {guide}
      Draft a patch satisfying:
      {goal}
      {shape}
      Reply with a unified diff only.
  ```
}

-- A polish pass, so that a composition below has two arrows to compose.
function revised (patch) -> text {
  ask model "author" ```
      Tighten this patch without changing what it does.
      {patch}
      Reply with a unified diff only.
  ```
}

-- A panel: three members, one rule, three questions in every world. The third
-- is the correctness reviewer read a second, independent time.
function reviewed (guide, patch) -> verdict {
  panel, all must approve [
    ask model "reviewer-correct" ```
        {guide}
        Is this patch correct?
        {patch}
        {verdictSpec}
    ```,
    ask model "reviewer-secure" ```
        {guide}
        Is this patch secure?
        {patch}
        {verdictSpec}
    ```,
    ask model "reviewer-correct" independent draw 1 ```
        {guide}
        Is this patch correct?
        {patch}
        {verdictSpec}
    ```
  ]
}

function judged (patch, rubric, context) -> verdict {
  ask model "judge" ```
      {context}
      Judge this patch against the rubric.
      {patch}
      {rubric}
      {verdictSpec}
  ```
}

-- The one parameter in this file that is not text says so. A verdict splices
-- into a prompt as its objections, which is its one canonical text.
function summarised (patch, finding : verdict) -> text {
  ask model "scribe" ```
      Write one line for the run log: what this patch does, and what the last
      reading of it said.
      {patch}
      {finding}
  ```
}

function applied (patch) -> receipt {
  ask tool "apply" ```
      Apply:
      {patch}
      Write the patched file here, then reply DONE.
  ```
  ask tool "test" "Run the test suite, then reply with its last line."
}

function filed (note) -> receipt {
  ask tool "append" ```
      Append this line to the run log:
      {note}
  ```
}

-- A static function. `let` is a header, not a statement: it has no questions
-- of its own and it does not appear in `agent-cat plan`; its two questions
-- appear at every site that uses it.
--
-- `finding` is annotated because a lambda binder defaults to `text` and
-- `summarised` wants a `verdict` there. A `<-` binder would have had its kind
-- inferred; a static binder says what it is (§4.3).
--
-- The lambda earns its place here, and composition cannot replace it: `.`
-- composes at arity one, and `summarised` takes two arguments. Haskell would
-- write `(filed .) . summarised`; that is exactly the noise this audit exists
-- to refuse.
let logged = \patch (finding : verdict) -> filed (summarised patch finding)

-- A static HIGHER-ORDER function: its parameter is a function, so it is a
-- `let` and not a `function` — a runtime function's parameters are answers,
-- and an answer has a kind. The optional annotation is written here because
-- a reader of a higher-order header should not have to synthesize its type.
let checked : (text -> text) -> text -> verdict =
      \(draft : text -> text) -> \goal -> judged (draft goal) rubric spec

-- The priming. Asked once, before anything an importer writes. A priming is a
-- prefix, not a block: it has no final position, so the trailing-binding
-- refusal does not reach it.
guide : text <- ask tool "cat" "Write out the house style guide, at most four short lines."

ask model "author" ```
    {guide}
    You are drafting patches for this codebase. Hold this style guide.
```
```

**Three refusals this file demonstrates by not containing them.**

`let primed = reviewed guide` — `guide` is a runtime binding and a `let` is
closed (C6):

```
a `let` is a static definition and may name only the headers above it;
`guide` is an answer, bound when the program runs — pass it at the use site
```

`let opinion = judged patch rubric spec` — the synthesized type is a base kind
(§4.5):

```
a `let` names a function; `opinion` names an answer, and an answer is bound
where it is asked — write `opinion <- judged …` in the block that uses it
```

`let logged = \patch finding -> filed (summarised patch finding)` — the binder
defaults to `text` where a `verdict` is wanted (§4.3):

```
a lambda binder's kind is `text` unless it says otherwise, and this one is
used where a `verdict` is wanted — write `\(finding : verdict) -> …`
```

**And one the file's own bodies rely on**: `judged`, `rubric` and `spec` are
written **unqualified** inside `checked` and are used, dotted, from
`harden-imported.wf`. That works because a `let`'s body is resolved and stored
**fully qualified at declaration**, through this module's own `env.q` (§4.5) —
so what the importer inlines is already `library.judged`, `library.rubric`,
`library.spec`, and inlining needs no environment at all.

### 9.2 `example/harden-imported.wf`

```
-- The flagship, written against `library.wf`. This pair is the every-feature
-- showcase. `example/harden.wf` is the kernel pin: it is not modernized, and
-- round eighteen does not touch one byte of it.

import library

define aim   = "Harden the parser against malformed input, minimally."
define shape = "Keep the diff under forty lines."
define twice = "You have already reviewed this patch once; this is the second reading."

workflow {

  known here: library.guide

  -- THE DO-BLOCK REMAINS RIGHT. `draft` is revised by the loop below, so the
  -- loop's subject must be a name a reader can find (D8). Nothing here wants
  -- a pipeline.
  draft <- library.drafted library.guide aim shape

  result <- revising draft as patch, at most 2 amendments {

    -- `why` is spoken, so `why` is named: a prompt refuses an expression
    -- (D6), and so does a revision's clause — its questions are asked once
    -- per round, and there is no hoisting site inside one (D15).
    why <- library.reviewed library.guide patch

    amend patch {
      ask model "author" served by "deep" ```
          {library.guide}
          Revise this patch:
          {patch}
          {why}
          Reply with the revised diff only.
      ```
    }
  }

  case result {

    settled patch {

      -- A COMPOSITION IN AN ARGUMENT, passed to a higher-order `let`.
      -- `library.drafted library.guide aim` is a partial application of a
      -- three-parameter runtime function; `.` composes it with `library.revised`
      -- to make the `text -> text` that `checked` asks for. The inner
      -- parentheses are C8's rule: the right of an operator reads no
      -- arguments, so a partial application there says so.
      second <- library.checked
                  (library.revised . (library.drafted library.guide aim)) shape

      case second {
        approved {

          -- An expression in an `if` subject: the question is written where
          -- the decision is, and it is asked once, before the branch.
          if (ask person "owner" ```
              Apply this patch?
              {patch}
              {library.flagSpec}
          ```) {
            library.applied patch

            -- A KLEISLI CHAIN replacing a three-binder chain: judge the
            -- landed patch, write one line about it, file the line. Two
            -- intermediates, no names, read left to right. `>>>` is bind-
            -- shaped: `f x >>> g` is `y <- f x; g y`.
            library.judged patch library.rubric twice
              >>> (library.summarised patch)
              >>> library.filed
          } else { stop }
        }

        -- One step, so the plain call reads better than a pipeline would.
        -- `library.logged` is a `let`: two questions, at this position.
        objected { library.logged patch second }

        no answer { stop }
      }
    }

    unsettled { stop }
  }
}
```

**Two things in this file that the rules of §3 are visible in.** The three-line
pipeline works because of the continuation rule (§3.3 bound 4): an expression
continues while the next token is an operator, so lines two and three are the
same statement. And `(library.summarised patch)` is parenthesized while
`library.filed` is not, because the right of an operator reads zero arguments
(§3.4) — the first is a partial application and says so, the second is the arrow
itself.

### 9.3 The normalizations, shown

**The composition in an argument.** Source (`harden-imported.wf:45`):

```
second <- library.checked
            (library.revised . (library.drafted library.guide aim)) shape
```

`library.checked` is a `let`, so the head dispatches to the normalizer, not to
`resolveFn` (§4.5). Its arrow parameter `draft` takes the composition
**substituted as a term** (an arrow is not a source), and `goal` takes `shape`
**substituted as a term** (a literal is not a source). Beta:

```
second <- library.judged ((library.revised . (library.drafted library.guide aim)) shape)
                         library.rubric library.spec
        ⟶ library.judged (library.revised (library.drafted library.guide aim shape))
                         library.rubric library.spec
```

The traversal hoists post-order — innermost first, siblings in source order:

```
!45:34 <- library.drafted library.guide aim shape
!45:19 <- library.revised !45:34
second <- library.judged !45:19 <rubric's words> <spec's words>
```

Three statements of today's `Raw`, three calls, in the order the data flows.
Both temporaries were **written at the use site**, so their chains have length
one and their names are round-17's exactly (§8.8). Both binds are emitted
**annotated** at `text` (C35), so kind inference is never consulted for either.
(`rubric` and `spec` are defines, so they are already literal `RawArg.lit`
chunks by the time the normalizer runs — `expand` at `Parse.lean:553`; `aim` and
`shape` likewise.) `blockAsks` prices this at 1 + 1 + 1 = 3 questions, being one
per callee body, and `checkProgram`'s `maxQuestions` guard (`Check.lean:943`)
sees exactly that.

**The Kleisli chain.** Source (`harden-imported.wf:58–60`):

```
library.judged patch library.rubric twice
  >>> (library.summarised patch)
  >>> library.filed
```

`>>>` is `infixr 1`, so this is `v >>> (f >>> g)`; §5.2's coherence says the
normal form is the same either way, and owner ruling 8 says what it means:
`f x >>> g` is `y <- f x; g y`.

```
!58:15 <- library.judged patch <rubric's words> <twice's words>
!59:20 <- library.summarised patch !58:15
library.filed !59:20
```

The last line is a statement call at `receipt`, which is exactly what an arm's
final statement must be (D18, D17), and exactly what the three-binder version
elaborated to. Two temporaries, two positions, both annotated — the first at
`verdict` (it is `library.judged`'s result kind), the second at `text`.

**The `let` with a lambda, and the minting chain.** `library.logged patch second`
at `harden-imported.wf:62:19` inlines `logged`'s body, whose
`library.summarised patch finding` call is written at `library.wf:41:22`:

```
!62:19/41:22 <- library.summarised patch second
library.filed !62:19/41:22
```

Two questions. The temporary's name carries **both** positions, outermost first,
which is what makes a second use of `library.logged` in the same block mint a
different name (`!71:9/41:22`) rather than colliding — the failure the draft's
one-axis key would have produced. `showName` suppresses the whole name from every
diagnosis, and `agent-cat plan` prints the **use site** with the body position as
provenance (§5.4):

```
harden-imported.wf:62:19   ask model "scribe"   (via library.logged, library.wf:41:22)
```

**D17, worked, because the trigger changed.** A `-> receipt` body can now contain
a nested source, which round 17's trigger could not produce:

```
function log (p, f : verdict) -> receipt { filed (summarised p f) }
```

The body's **final statement** is not lifted into a binder — it stays `.callS`
with `answer := none` — while the source **nested inside it** hoists exactly as
anywhere else:

```
!7:24 <- summarised p f          -- nested: hoisted, annotated `text`
filed !7:24                      -- final: NOT lifted, `.callS`, answer := none
```

That is D17's rule restated for round 18's trigger, and it is one line of
`Raw` different from what round 17 would have emitted for the same body — which
is to say, nothing is different, which is the point.

**A hole in a lambda's prompt, pinned.** This is the shape that lets a static
function build a prompt from its own parameter, and it is what §8.8's rewrite
clause exists for. Declared in a library at line 30:

```
let rated = \x -> (ask model "critic" "Rate:\n{x}")
```

A hole is `{name}`, never `{expression}` (D6), so the binder is the only thing
the prompt can name — which is exactly why the binder's minting has to reach
inside the prompt. **At parse time** the binder `x` is minted to `!30:18` and the
prompt's hole is rewritten in the same pass, so the stored body is

```
\!30:18 -> (ask model "critic" "Rate:\n{!30:18}")
```

**At the use site** `second <- rated draft`, written at line 44, the chain gains
the use position, so binder and hole both become `!44:12/30:18`. Then `draft` is
a **name**, so it is substituted as a term rather than hoisted (C2), and beta
replaces both occurrences at once:

```
second <- ask model "critic" "Rate:\n{draft}"
```

One statement, one question, with the hole naming the runtime binding the caller
passed — which is the program the author would have written by hand. Used at a
second site the chain differs at the front, so the two copies never collide.

That is the whole mechanism in one example, and it is also why the `expand_*`
theorems do not move: the rewrite maps `Chunk.interp "!30:18"` to
`Chunk.interp "!44:12/30:18"`, an `interp` to an `interp`, after `expand` has run
and outside anything `expand_lit`, `expand_interp_hit` or `expand_append`
(`Parse.lean:574, 577, 583`) quantifies over (§8.8).

### 9.4 Where the calculus was refused, and why

| Site | Calculus form considered | Kept as | Reason |
|---|---|---|---|
| `draft <- library.drafted …` | `>>>` into the loop | a binder | The loop's subject must be a name (D8), and `draft` is read twice. |
| `why <- library.reviewed …` | any expression | a binder | D15: a clause is one question per round; there is no hoisting site. |
| `objected { library.logged patch second }` | `library.filed . (library.summarised patch) $ second` | the plain call | One step. The composition is longer than the call and asks the reader to compute a normal form. |
| `second <- library.judged patch $rubric $context` (round 17) | a pipeline | rewritten to use `checked` | D9: a call carrying `$label`s cannot be an operand — its fences follow its arguments. |
| the panel members | expressions | `ask`s | D7: a panel of *k* members costs *k* questions in every world. |

That last column is the noise audit doing its job: **five sites considered, two
taken.**

### 9.5 Every-feature coverage (extending round 17's §8.2 table)

| Feature | Where |
|---|---|
| do-notation result (`answer` gone) | every function in `library.wf` |
| default-text parameters | all seven functions |
| a `verdict` parameter, annotated | `summarised (patch, finding : verdict)` |
| functions, value and `-> receipt` | `drafted`/`revised`/`reviewed`/`judged`/`summarised`; `applied`/`filed` |
| imports and dotted names | `import library`; `library.guide`, `library.drafted`, … |
| `$labels` and trailing blocks | (round 17's `judged patch $rubric $context` — see §9.4; retained in the battery, not in the showcase) |
| `revising` with `as` and `at most n amendments` | the loop |
| `panel, all must approve` | `reviewed` |
| `independent draw` | third panel member of `reviewed` |
| `if` / verdict `case` / `settled`-`unsettled` case | all three |
| `known here` | first statement of the workflow |
| defines, local and imported | `aim`, `shape`, `twice`; `library.spec`, `library.rubric`, `library.flagSpec` |
| the `served by` model override | `drafted`, and the amend clause |
| `stop` | three arms |
| **a parenthesized question in an argument or subject** | `if (ask person "owner" …)` |
| **`let`, static** | `library.logged` |
| **`let`, higher-order, with its optional annotation** | `library.checked` |
| **a lambda, with an annotated binder** | `logged`'s body |
| **an annotated function-typed binder** | `\(draft : text -> text) -> …` |
| **partial application** | `library.drafted library.guide aim`; `library.summarised patch` |
| **`.` composition** | `library.revised . (library.drafted library.guide aim)` |
| **`>>>` pipeline, two steps, across three lines** | the approved arm |
| **an operator's parenthesized right operand** | `>>> (library.summarised patch)` |
| **`$`, `>>=`, `=<<`, `<<<`** | in the battery only — the showcase never needed them, and that is worth recording |

Not covered, deliberately: `at least n must approve` (acat-f10), sections and
function-typed results (both refused), and every construct round 18 refuses.

**Two lexer facts this pair depends on**, and they are now three: the `if`
subject's fence closes with ```` ```) ```` and nested parenthesized questions
close with ```` ```)) ````, both from D19; and a fenced block standing as an
operand closes with an operator start, which is §8.7's widening. None of the
three lexes without the `fenceCloses` repair, and round 18 needs it *more* than
round 17 did, because every nested question is now parenthesized and a fenced
prompt is now an operand.

---

## 10. Theorem survival and pricing

### 10.1 What moves, file by file (C27)

Two of the draft's eight rows named files that do not exist — `Explain.lean` is
at `Agentic/Core/Explain.lean`, not under `Dsl/`, and `DslFlagship.lean` is at
`Agentic/Core/DslFlagship.lean`, not under `test/`. This is the one table an
implementer works from, so both paths are corrected here and everywhere else on
the page.

| File | Round-18 change |
|---|---|
| `Agentic/Core/Plan.lean`, `Cost.lean`, and the kernel | **none** |
| `Agentic/Core/Dsl/Syntax.lean` | **none.** `Raw`, `RawBlock`, `RawBodyStmt`, `RawRhs`, `RawSource`, `RawArg`, `RawFn`, `RawProgram` all unchanged. `RawFn.answer`'s docstring is rewritten, as round 17 already planned. |
| **`Agentic/Core/Dsl/Norm.lean`** | **NEW.** `SType`, `SExpr` (with positions, C32), type synthesis, `normalize` with the node budget, the hoister, `LetEntry`, the emitter, `maxNormNodes`, and the two theorems of §10.4. ~750 lines. |
| `Agentic/Core/Dsl/Parse.lean` | the expression parser; six lexer changes plus the `fenceCloses` widening; `let` in the headers; `parseType`; `parseLambda`; `PEnv.fnSigs` and `PEnv.lets`; the round-17 refusals that survive. ~+550 / −120 lines. |
| `Agentic/Core/Dsl/Check.lean` | **two clauses, seven `showName` sites and three rewordings** — the `knownHere` `live` filter (`:534–536`) and `showName`, exactly as round 17 priced them. Nothing else. |
| `Agentic/Core/Dsl.lean` | **none** |
| `Agentic/Core/Explain.lean` | **none** for content; `agent-cat plan`'s provenance column (§5.4) is a rendering change in `planLines` (`:398`) and touches no theorem. |
| `Agentic/Core/DslFlagship.lean` | **none** (§10.5) |

**Worth recording in this table, because it is the actual reason "no recompile"
is true:** `DslFlagship.lean` imports `Agentic.Core.Dsl` and
`Agentic.Core.HardenPatch` and is imported by the three smoke tests and the
aggregate; **the three executables never reach it.** So a parser change
recompiles it only if `Dsl.lean` changes its interface, which C4 guarantees it
does not.

### 10.2 The fourteen level lemmas, and the guards

**All fourteen survive verbatim, statement and proof**: `askPlan_level_le`
(`Dsl.lean:126`), `checkMembers_level_le` (`:137`), `FnLevel` (`:160`),
`callPlan_level_le` (`:164`), `rhsPlan_level_le` (`:182`), `bindForm_level_le`
(`:218`), `PendLevel` (`:255`), `checkBlock_level_le` (`:265`),
`checkBody_level_le` (`:453`), `checkFn_level_le` (`:514`),
`checkFnsList_fnLevel` (`:547`), `checkProgram_level_le` (`:575`),
`parseAndCheckProgramWith_level_le` (`:590`), `parseAndCheck_level_le` (`:599`).

The reason is C4 and it is mechanical: each is an induction over a
`RawBlock`/`RawBodyStmt`/`RawFn`/`Fns` whose constructors do not move,
discharged by `split at h` on `checkBlock`/`checkBody`/`bindForm`/`rhsPlan`
clauses round 18 does not touch. The only `Check.lean` edit inside the chain's
reach is the `knownHere` `live` filter (`Check.lean:534–536`), and round 17
already checked it against `checkBlock_level_le`'s script: the clause's *body*
changes, the match's *patterns* do not, so the reduction is unaffected. The
adversarial pass re-verified this mechanically rather than by assertion.

**`parseAndCheck_level_le` still bounds every accepted program at branch**, and
the calculus cannot raise the rung, because every hoisted step is a `.bind` or an
`.act` covered by `bindForm_level_le` and every inlined `let` produces statements
the caller's own induction already covers. **A `let` is not a new rung; it is not
a rung at all.**

**The six guards survive verbatim**: `overRevised_sound` (`:615`),
`checkProgram_overRevised` (`:694`), `checkProgram_oversized` (`:706`),
`checkProgram_of_within` (`:720`), `checkBlock_caseVerdict_arms` (`:733`),
`askShape_draw` (`:762`). `overRevised_sound`'s induction steps through
`.bind _ _ (.rhs _) rest` (`:638–640`), which is the shape every hoisted bind
has, so hoisted binds are transparent to it, and
`Explain.RawBlock.revisionBounds` (`Explain.lean:378`) skips them the same way.
`checkProgram_oversized` is also the reason §4.5's positioned pre-check exists
rather than a repositioned refusal.

### 10.3 `Check.lean`'s own theorems, and `Explain.lean`'s seven

**All survive verbatim.** `check_panel_nil` (`Check.lean:717`),
`parseAndCheck_ok_iff` (`:972`), `under_ask1`/`under_askC1` (`:179`/`:184`) are
`rfl`s or unfoldings about functions round 18 does not touch.

`checkArgs_too_few` (`:388`) and `checkArgs_too_many` (`:395`) survive verbatim,
and the draft's claim about them is **deleted**. It said round 18 makes them
"unreachable from source text" and called that "the one place round 18 changes
the *status* of a theorem". They are **already** unreachable from source text,
today, before round 18: `parseArgTokens` is documented as *"Exactly `arity`
single-token arguments"* (`Parse.lean:656–659`) and is driven by `resolveFn`'s
arity, so a call reaching `callPlan` always has exactly `fe.params.length`
arguments, and a short count is refused in the parser, by count, with a parser
diagnosis. The accurate statement is a **survival**, not a status change:
arity-directed parsing already made both unreachable from source, round 18
preserves that property through the saturation check, and the theorems continue
to guard the hand-built `Raw` entry point exactly as `check_panel_nil` does
(`DslSmoke`'s exception 2). No theorem restates and no battery note moves.

`Explain.lean`'s seven — `parseAndCheckRaw_eq_with_nil` (`:292`),
`parseAndCheckRawProgramWith_eq` (`:301`), `parseAndCheckRawProgramWith_level_le`
(`:318`), `parseAndCheckRawWith_level_le` (`:329`), `parseAndCheckRaw_eq`
(`:336`), `parseAndCheckRaw_level_le` (`:343`), `bindForm_ask_head_draw` (`:356`)
— **survive verbatim.** The six front-end parity theorems `cases`/`split` on
`parseProgramWith`'s result and never inspect it, which is C4 in concrete form.
`bindForm_ask_head_draw` is ∀-quantified over `bindForm fns c S (.ask a)`, so it
now *additionally* guarantees that a **hoisted** ask puts the source-written draw
index on the first event of its run — a free strengthening, and the proved half
of the sharing rule (§5.5).

`Parse.lean`'s three — `expand_lit` (`:574`), `expand_interp_hit` (`:577`),
`expand_append` (`:583`) — **survive verbatim, and D6 is why**: an expression
legal in a prompt would put an `SExpr` inside a `Chunk`, and `expand_append`'s
homomorphism statement would no longer type-check. C26's prompt rewriting does
not disturb them, for the reason spelled out in §8.8: it is an
`interp`-to-`interp` map that runs after `expand` and that none of the three
statements quantifies over.

### 10.4 What is genuinely new, proof-side

**Nothing that any existing theorem needs.** Normalization is front-end, and no
theorem inspects the parser's output.

The draft proposed two statements and both were the wrong ones. `normalize_ok_normal
: normalize fuel e = .ok e' → isNormal e' = true` is very likely **vacuous**: if
`normalize` is written the obvious way (`if isNormal e then .ok e else normalize
fuel' (step e)`, `.error` at fuel 0), the guard discharges it and it proves
nothing about `step`'s completeness — a tautology dressed as a postcondition. And
`normalize_ok_firstOrder`'s postcondition `isBase e' = true` is strictly weaker
than the licence §1.3 claimed for it: a term can be base-kinded and still not be
emittable — `library.judged (library.revised x) rubric spec` is base-kinded with
an un-hoisted nested source, and by §1.5 a bare name is base-kinded and has no
`RawRhs` at all.

**The two statements round 18 actually proposes:**

```lean
/-- The non-vacuous half: `step` has no move exactly when the term is normal.
This forces `isNormal` to be defined independently of `step`, which is what
makes it a specification rather than a restatement. -/
theorem step_none_iff_normal (e : SExpr) : step e = none ↔ SExpr.isNormal e
```

and **emit-totality, obtained by construction rather than by proof**: the
normalizer's result type is an inductive whose constructors **mirror the
emittable grammar** — `RawRhs`, `RawArg`, `RawBlock` — so `emit` is total by
typing and "the emitter never sees a redex, never sees an arrow, and never sees
a bare name at a bind right-hand side" is *definitional*. That is strictly better
than a lemma, it is the standard way to discharge this obligation, and it is what
makes §1.5's vacuity refusal a **type error the normalizer cannot produce**
rather than an invariant a proof has to maintain.

The fuel statement is then a **corollary**, not a theorem in its own right:

> **Node-budget soundness, in one sentence: whatever comes back is emittable,
> because it could not have been built otherwise.** Completeness — that no legal
> program hits the bound — is *not* claimed, exactly as it is not claimed for
> `maxQuestions`.

**Deliberately not proved:** strong normalization of the calculus (§1.3's
argument is a paragraph, and the node budget is the shipped answer, exactly as
the fuel is for `maxRevisions` and `maxQuestions`); confluence (the normalizer is
deterministic — it does not search, so uniqueness of *its* normal form is
definitional); and any theorem relating surface cost to normal-form cost (there
is nothing to relate: cost is *defined* on the normal form, §5.4).

**Kernel and axiom policy: untouched.** No `native_decide`. The lexer still never
runs in the kernel — normalization is part of parsing, so it inherits that. No
new `Decidable` instances and no new `deriving` on any type a kernel proof
mentions: `SType`/`SExpr` derive `Repr`/`DecidableEq` for the battery's benefit
only, and no `decide +kernel` result mentions them. **And no `Raw.shape`** — the
nine-spellings pins are decided on traces (§5.3), which needs no new type at all.

### 10.5 The flagship, re-answered (C28)

`flagshipSource := include_str "../../example/harden.wf"`, and
**`example/harden.wf` is not rewritten.** The premise was checked, clause by
clause, against the actual file — and one row of the draft's table was **false**,
which is worth showing rather than quietly fixing, because the row claimed to
have been checked against the file:

| Round-18 clause | `harden.wf` |
|---|---|
| C20 the dot | contains no `.` outside prompt text (its prompts are `scanString`/`scanBlockChunks` tokens) |
| C21 `$` | contains no `$` |
| C22 `\` | contains no `\` |
| C23 `>>>`/`<<<`/`>>=`/`=<<` | contains none. Note that line 2 carries `<one line>` **inside a quoted string** (`define verdictSpec = "… OBJECTION: <one line> if not."`), which is why the stray-`<` extension cannot reach it — the string is one token and the lexer never sees the `<`. That is the fact that makes the row true, and it is worth writing down. |
| C6 `let` | declares none; contains no binder, parameter or function named `let` |
| C7/C8 application | contains **no calls at all** — no `function`, no `import` |
| round-17 D1 `answer` | no functions, so no `answer` |
| round-17 D18 trailing bind | its workflow block ends in `case result { … }` |
| round-17 D17 receipt bodies | no bodies |
| **D19 + §8.7 `fenceCloses`** | **Corrected.** The draft said "every fence is closed by whitespace only". False: **lines 24 and 30 close their fences with `` ```, `` — a comma**, which `fenceCloses` (`Parse.lean:210–219`) accepts today. The true row: *every fence in this file closes with whitespace or a `,`, both already accepted; the `)`, the operator starts and the trailing comment are unreached by this file.* The conclusion survives — the widening is purely additive — but it survives on the correct premise. |
| C4 emission obligation | the block parser's tree and positions are unchanged for a file containing no calculus form |

Therefore `flagshipRaw` (`DslFlagship.lean:97`), `flagshipProgram` (`:255`),
`flagshipPlan` (`:206`), `flagshipRaw_accepted` (`:224`), `check_flagshipRaw`
(`:229`), `checkProgram_flagship` (`:260`), `parseAndCheck_flagship` (`:269`),
`level_flagshipPlan` (`:282`), `card_leaves_flagship` (`:293`),
`minFold_flagship` (`:301`), `maxFold_flagship` (`:308`), the four
`trace_flagship_*` (`:333`, `:339`, `:346`, `:353`), the four `bill_flagship_*`
(`:360`, `:366`, `:372`, `:379`), `flagshipUpTo` (`:388`), `flagship_bill_le`
(`:392`), `minFold_flagship_le_bill` (`:398`) and `render_eq_harden_render`
(`:59`) **all survive verbatim, and the nine `decide +kernel` results are not
recomputed for content** in a module that elaborates in ~107 s.

**The byte-identity question, answered the same way round 17 answered it and for
the same reason:** the pin is *syntactic* — a hand-transcribed `Raw` compared by
`decide (prog = flagshipProgram)` (`DslSmoke:889`) — so definitional equalities
buy it nothing. What saves it is the emission obligation, and the obligation is
checkable by a reviewer against the table above.

**The contingency, priced in one line:** if the pin ever churns, `flagshipRaw`
is re-transcribed with new positions and the nine kernel results re-run — the
round-8 block work performed exactly that operation, and `GRAMMAR.md`'s
"Elaboration and theorem survival" records what it cost. **The temptation to put
the calculus in the flagship is refused: the flagship is a pin first and a
showcase second.**

### 10.6 Battery churn and the honest estimate

**Battery**, over `test/DslSmoke.lean`'s 201 cases. Round 17's table is the base;
round 18 removes its bang cases and adds its own. The rows in **bold** are ones
the adversarial pass added or corrected.

| Category | Δ | Note |
|---|---|---|
| round-17 cases that stand | ~+30 | D1/D16/D17/D18/D19/D20 accepted-and-refused cases, the fixture edits, the seven `showName` sites, the `known here` filter |
| round-17 bang cases **never written** | **−18** | 6 accepted + 12 refused (C19, §6.2) |
| **the nine spellings of one normal form (§5.3), by `decide` on TRACES** | **11** | eight comparisons against the do-block baseline, plus `>>>`, `<<<` and `>>=` associativity; the instrument is `DslSmoke:1014`'s |
| `.` accepted — two arrows, a partial application, a dotted name | 4 | |
| **`.` refused — one value operand; TWO value operands; `f.g` unqualified; `library . spec`; `a.b.c`; a number-adjacent dot** | **6** | §3.5, §8.1 |
| `$` — all five rows of §8.3's table, plus the `f$x` application clause | 6 | the `$label` rows are byte-unchanged behaviour, pinned for the first time |
| **`>>>`/`<<<`/`>>=`/`=<<` — value-left, arrow-left, mixed with `.`, associativity, arrow-left-of-`>>=` refused, mixed chains refused (two)** | **10** | §3.5 |
| lambdas — one binder, two binders, annotated, function-typed binder, refused at four runtime positions | 8 | |
| **a lambda body with a `{hole}` naming its own binder, at one and two use sites** | **2** | §8.8, §9.3 |
| **a `{` after a lambda's `->`, refused** | **1** | §3.6 |
| `let` — first-order, higher-order, refused in a statement, refused mentioning a runtime binding, refused as a duplicate name, in a library (dotted) | 6 | |
| **`let` — point-free (`judged . normalize`); annotated header; annotation mismatch refused; base-kind type refused; over-budget use refused at its use site** | **5** | §4.5 |
| **a `let` in a `revising` clause, refused; `revising` as an operand, refused** | **2** | D15, §6.3 |
| partial application — accepted as an operand and as an argument; refused at a binder, a statement, a body final, a subject, a hole | 7 | |
| **an operator's right operand: bare arrow accepted, applied-unparenthesized refused** | **2** | §3.4 |
| saturation and over-application (§3.3's ambiguity and its refusal) | 3 | |
| **a bare binder applied (`\f x -> f x`), refused; the annotated form accepted** | **2** | §4.3 |
| **a lambda binder used where a `verdict` is wanted, refused** | **1** | §4.3 |
| **a receipt on the flowing side of a pipeline, refused** | **1** | §4.3 |
| types — defaulted binder, annotated arrow, function-typed `function` parameter refused, function-typed result refused, `flag`/`receipt` still refused | 6 | |
| **`flag`/`receipt` as an arrow's argument, refused at the annotation** | **2** | §4.1 |
| **C31 vacuity — a name at a bind rhs; a literal at a bind rhs; a literal body final refused; a NAME body final accepted** | **4** | §1.5 |
| `ret`/`pure`/`return` diagnoses | 3 | §3.9 |
| sections refused (four spellings) | 4 | §3.7 |
| **a statement beginning with an operator, refused; a three-line pipeline accepted** | **2** | §3.3 bound 4 |
| **the node budget — a program that exceeds `maxNormNodes`, refused with its count** | **1** | §1.3 |
| **substitution sharing (§5.5) — all three lines, executed with their bills; the `let`-arrow duplication pair; the eta pin** | **6** | |
| **hoist emission — a zero-use hoist emitted as an `.act`; a zero-use call as a `.callStmt`; a zero-use panel keeping its annotated binder; a hoisted bind's annotation, pinned** | **4** | C35 |
| **hoist order — `(\x -> g (ask q1) x) (ask q2)` gives q1 then q2** | **1** | §1.2, the positional rule |
| prompt literality — one prompt containing `. $ \ >>> >>= !`, against the string spelling | 1 | `decide`, at `DslSmoke:1014`'s instrument |
| `\`, `>>>` and `>>=` inside a fenced block, byte for byte | 2 | |
| **`fenceCloses` — one pin per new follower (`)` `.` `$` `<` `>` `-`), plus the `` ```haskell `` negative** | **7** | §8.7 |
| trace order through a composition (`(f . g) x` gives g then f) | 1 | via `codesOf`/`promptAt` |
| **`stmtWords` pins — whole-string, two cases** | **edit 2** | `DslSmoke:510` and `:573`; `let` in, `answer` out |
| **the stray-`-` message, reworded** | **edit 1** | §8.5 |
| unchanged | ~163 | including all eight `known here` cases, byte for byte |

Net: roughly **−18 / +151 cases** against today, ~26 edited, and no position churn
given round 17's in-place fixture edit (`answer x` → `x`, same line, same
column). Round 17 has not shipped, so its ~30 surviving cases are additions
against today too; the column sums to +151 with them and +121 without.

**Pins outside the battery:** `DslSmoke`'s file-reading section (`:1236–1250`)
still expects `"ok"` from both files of the pair; `CliSmoke:229` still prints
"house style guide" (the priming's words are unchanged); `CliSmoke:113`'s
`expectedApply = 7` and `:123`'s `expectedRefuse = 6` are about `harden.wf` and
are untouched; `CliSmoke:254`'s `example/ill-typed.wf:11:18:` holds **only**
because of round-17 §8.3's appended act, which carries.

**The estimate. This is a parser rewrite, and the number should be read as one.**

| Piece | Estimate |
|---|---|
| `Norm.lean`: `SType`/`SExpr` with positions, synthesis, `normalize` with the node budget, the positional hoister with annotated emission, `LetEntry` and pre-pricing, the emittable result type, `step_none_iff_normal` | **4 days** |
| `Parse.lean`: the expression parser (atoms, head/arg split, application with the four bounds, six operators with fixity and the mixed-chain refusal), `parseType`, `parseLambda`, the `let` header with its optional annotation, `PEnv.fnSigs` + `PEnv.lets`, six lexer changes including the dedicated `.` branch, the `fenceCloses` widening, parse-time binder minting | **3½ days** |
| `Check.lean`: the `knownHere` filter, `isTemp`/`showName` at seven sites, three rewordings | **2 hours** |
| battery: ~151 new cases, in-place fixture edits, whole-diagnosis matching | **3 days** |
| examples (the pair, `ill-typed.wf`) and docs (`GRAMMAR.md` round-18 note, grammar block, revised rules 2 and 3, the **continuation rule** as a new numbered rule, and the four hazards of §5.4; `doc/dsl-guide.html`; `ROUNDS.md`; `block-syntax.md`'s one line) | **1 day** |
| re-elaboration risk | **near zero** — `Dsl.lean`, `Explain.lean` and `DslFlagship.lean` are not edited for content; the ~107 s module and the nine kernel proofs are not recompiled for content |
| **credit**: round 17's bang, never written | **−1½ days** |

**Total: ten to eleven focused days**, against the draft's eight to nine and
round 17's three for the core alone. **The delta is the attack**: the node
budget, positions on `SExpr`, the `lets` table with its type synthesis and
pre-pricing, `fnSigs`, annotated hoist emission, the minting chain, the dedicated
dot branch, the fence widening, two more operators, and thirty more battery
cases. Every day of it buys a defect the draft would have shipped, and three of
those defects were fatal.

The risk is concentrated in two files, one of them new, and the new one is where
every genuinely novel algorithm lives — which is the shape you want, because
`Norm.lean` can be tested against trace equality with `decide` before a single
diagnosis is written.

**The reopening condition, stated in advance.** If `Raw` has to move — if some
normal form turns out not to be expressible in today's syntax — the honest
response is to **reopen C4 before writing the parser**, not to patch around it.
The attack found exactly one such normal form and C31 closed it with a refusal
rather than a constructor; a discarded **panel** is a second, and §1.2 closes it
by keeping the annotated binder. **If a third appears, this page is wrong and
should be said to be wrong.**

---

## 11. What round 18 does not do

* **It does not give the language an expression language over answers.** The
  five operators are all composition; none is a function of a `text`. Rule 3's
  revised form (§7.3) is the claim, and it is the claim a reviewer should attack
  first.
* **It does not create runtime closures.** Function types never reach `Code`, so
  they never reach `Env`, so `Plan.dyn` stays quarantined and no surface syntax
  reaches it. §1.1 and §2.2(c) are the two places that could have gone wrong and
  did not.
* **It does not add recursion.** Stratification refuses it, and stratification is
  also what makes normalization terminate — one rule, two jobs, as round 16
  already noted for arity-directed parsing.
* **It does not raise the rung.** Every hoisted step is a `.bind` or an `.act`;
  every inlined `let` is statements the caller's own lemma covers;
  `parseAndCheck_level_le` bounds every accepted program at branch by the same
  proof.
* **It does not let a function value ask a sequence.** A lambda's body is one
  expression (C12); a function value that asks more than one question is a
  `function`, passed by name as `(f)`. That is a real limit on directive 3 and it
  is recorded rather than discovered.
* **It does not make every well-typed term a program.** C31 refuses a normal form
  that asks nothing, because `Raw` has no spelling for one. That is the one place
  the two levels do not line up, and it is a refusal rather than a constructor.
* **It does not move the flagship.** `example/harden.wf` is byte-identical,
  `flagshipRaw` is not re-transcribed, and the nine `decide +kernel` results are
  not recomputed — which is, for the second round running, the strongest single
  thing this design has to say for itself.
* **It does not make the surface shorter than it was.** Nine of the twelve
  statements in the showcase are unchanged; two calculus forms were taken and
  three were considered and refused (§9.4). The calculus is there for the
  programs that want it, and the noise audit is still the rule for the ones that
  do not.

---

## 12. Questions for the owner: none

The draft carried three. Under owner ruling 9 — *the Haskell Report is the
default answer to every syntax question; only genuine collisions with this
language's own commitments come back* — and owner ruling 8, all three are
answered, and this page records the answers rather than re-asking them:

* **The `>>>` overload** was the draft's Q1. **Ruling 8 decides it**: `>>>` is
  bind-shaped, `f x >>> g` is `y <- f x; g y`, and effect-on-the-left is the
  degenerate arrow. C10 is that ruling transcribed (§5.2), and C33 adds `>>=` and
  `=<<` because ruling 8 *defines* `>>>` in terms of `>>=` and ruling 9 makes
  Haskell's vocabulary the default. `>=>` and `<=<` are not added, because in a
  one-category language they are `>>>` and `<<<` — which is a decision the two
  rulings make between them, not a question.
* **The stratum split** was Q2. It is not a syntax question and it is not a
  collision; it is the only reading under which `FnEntry` and the `Plan.dyn`
  quarantine survive (§2.2, §2.3), and the alternative that keeps one keyword
  makes "does this have a rung?" an invisible property of a signature, which the
  language's oldest promise forbids. **Taken, with option (b) recorded as the
  clean cut if the campaign runs long.**
* **Higher-order functions at all** was Q3. Directive 3's "the whole deal" is the
  answer; §2.3 records exactly where and how to cut if the campaign runs long,
  and cutting it invalidates no other decision on this page.

**The genuine collisions did come back, and they were resolved in this page's own
terms rather than by asking**: the dot rule against qualification (§8.1, resolved
by whitespace and a dedicated lexer branch); `$` against `$label` (§8.3, resolved
on the right-hand side, where today's code already looks); fenced prompts against
operands (§8.7, resolved by widening the follower set); and braces-not-layout
against multi-line pipelines (§3.3 bound 4, resolved by the continuation rule and
its statement-head refusal). Each is a place where Haskell's answer and this
language's commitments met, and in each the commitment won and Haskell's spelling
survived around it.

**What the owner is being asked for is approval of the page, not adjudication of
a question.**




