> ## SUPERSEDED — pre-attack draft, kept for the record
>
> **This is the round-18 draft as it stood *before* the adversarial pass.** Three
> attackers — theorems and architecture, parsing and grammar, types and
> normalization — returned **sixty findings** against it: **three fatal** and
> fifty-seven corrections.
>
> The three fatals were: (1) the north-star claim was false, because `RawRhs` has
> no constructor for a bare name or a literal, so `let id = \x -> x` followed by
> `x <- id draft` normalizes to something `Raw` cannot spell; (2) C2's phases
> contradicted each other — Phase A was declared strictly before Phase B and then
> hoisted inside Phase A, and the two readings give different question orders;
> (3) `maxNormSteps` bounded beta steps, which is not the resource, since one step
> copies its argument once per occurrence.
>
> **The design of record is `calculus-design.md` beside this file**, which applies
> every repair. Where the two disagree, that file is right. Nothing here should be
> implemented from; §0.2 of the successor names what changed and why.

---

# Round eighteen: the static function calculus over the do-notation core

*Design DRAFT for round eighteen, 2026-08-15. **Superseded by
`calculus-design.md`** — see the banner above.*

*Written against Written against
`expr-design.md` (the approved round-17 page, whose D1–D21 are inputs, not
questions), `GRAMMAR.md` (rounds 10–17), `fn-import-design.md` +
`fn-import-attack.md`, `block-syntax.md`, `example/{harden,library,
harden-imported,hello,ill-typed}.wf`, and the implementation in
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean` + `Agentic/Core/Dsl.lean` +
`Agentic/Core/Dsl/Explain.lean` + `test/{DslSmoke,CliSmoke}.lean`.*

*Per the owner's ruling — **one design, then one campaign** — this page covers
the round-17 core and the calculus together. Round 17 has not shipped; nothing
in it is legacy. Where this page and `expr-design.md` disagree, this page is the
proposal and `expr-design.md`'s decision is named explicitly as superseded, with
its cost saving recorded (§6, §10.6).*

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

The two things this page had to decide before it could be written, and did:
**there is only one arrow in this language and it is effectful** (§5.1), which is
why `.` and `<<<` can coexist without an effect system; and **`function` and
`let` are two strata, not two spellings** (§2.3), which is what keeps `FnEntry`
first-order and unchanged while still giving the owner higher-order functions.

### Decisions taken in this document

| # | Question | Decision |
|---|---|---|
| C1 | The architecture | **Two levels.** Runtime = today's `Plan`. Static = an STLC over the four kinds, eliminated by normalization in the front end. Function types never exist at run time. |
| C2 | Normalization strategy | **Beta by-value at the four kinds, by-name at function types; then post-order effect hoisting; eta only at the saturation check** (§1.2). |
| C3 | Termination | **Fuel** (`maxNormSteps := 4096`), refused with a count and a position, in the spirit of `maxRevisions`/`maxQuestions`. Strong normalization is argued, **not proved**; a two-line fuel-soundness statement is what the elaborator actually relies on (§1.3). |
| C4 | The north star | **Normalize in the front end into today's unchanged `Raw`.** No `Raw`, `Plan`, `Code`, `Ctx` or `FnEntry` change (§2.1). |
| C5 | The higher-order fork | **The stratum split.** `function` = runtime, first-order, one `FnEntry`, unchanged. `let` = static, any simple type, normalized away per site. A function-typed parameter is legal **only on a `let`**. Options (b) refuse and (c) generalize `FnEntry` recorded and refused (§2.3). |
| C6 | Where `let` stands | **A header, beside `define` and `function`; top level only; closed** (it may mention only headers above it). Statement-position `let` refused. `let` joins `stmtWords` (§7.2). |
| C7 | Application | **Left-associative juxtaposition, tightest.** Bounded above by the head's arity, below by the stopper set, with round 16's one-token `<-`/`:` probe promoted from refusal to decision (§3.3). |
| C8 | A function name in argument position | **Does not stand bare**: `(f)` or `\x -> f x`. Round 16's "a call is not an argument" survives as a determinism rule with two escapes named (§3.4). |
| C9 | Fixities | `.` **infixr 9**; `<<<` `>>>` **infixr 1**; `$` **infixr 0** — Haskell's own numbers (§3.5). |
| C10 | `.` versus `<<<`/`>>>` | `.` composes **arrows only**. `<<<`/`>>>` take an **arrow or a value** on the flowing side: `v >>> g` is `g v`, `g <<< v` is `g v`. The overload is coherent with the fixity (§5.2). |
| C11 | Sections | **Refused**, with the lambda named as the escape (§3.7). |
| C12 | Lambdas | `\x -> e`, `\x y -> e`, `\(x : t) -> e`. Legal at every expression position, refused at every runtime position. Binders obey rule 6 and `freshOfTables` (§3.6). |
| C13 | `->` | **Triple duty** — result kinds, lambda bodies, function types — and it parses, by position, with no lookahead (§3.8). |
| C14 | `ret` / `pure` / `return` | **Not added.** A body's final expression is its answer (round-17 D1). One recognized-mistake diagnosis at the word, permanently (§3.9). |
| C15 | Types | `type ::= kind \| type "->" type \| "(" type ")"`, right-associative. A bare parameter is `text` (D16 carries); a **function-typed parameter is always annotated** (§4.1). |
| C16 | Function-typed results | A `function`'s result stays a **kind**. A function that answers a function is a `let` (§4.2). |
| C17 | Partial application | **Legal statically, refused at every runtime position.** "Saturated" is defined; the round-16 objection ("a `Sub` that is not yet total") is answered rather than repeated (§4.3). |
| C18 | The typing discipline | **Synthesis up, checking down**, monomorphic, no unification, no Hindley–Milner, no polymorphism. Stated as a refusal so nobody adds one later (§4.4). |
| C19 | The bang `!(…)` | **Dropped before it ships.** Round-17 D3, D4, D5, D11 are superseded by the calculus; D6, D7, D8, D9, D15 survive restated over expressions (§6). |
| C20 | The dot, lexically | **Qualification iff the dot is immediately flanked by identifier characters**; every other dot is the composition token. Byte-compatible with every file that exists (§8.1). |
| C21 | `$`, lexically | **`$` immediately followed by an identifier character is a `$label`**; otherwise it is the application operator. Byte-compatible (§8.3). |
| C22 | `\` | A lexeme outside prompt text. **Prompts are unaffected**, with the line references (§8.4). |
| C23 | `>>>` / `<<<` | New tokens; the stray-`<` and stray-`>` diagnoses extended (§8.5). |
| C24 | Cost and trace | Priced on the **normal form**; `blockAsks`/`bodyAsks`/`rhsAsks` unchanged; post-order carries; **a question's position is where its words are written** (§5.4). |
| C25 | Substitution sharing | **A by-value argument used twice is one question**, unlike two written questions, which are two events. Divergence 3, stated as a language rule (§5.5). |
| C26 | Temporaries | Round-17 D10's already-qualified minting, `Dsl.isTemp` and `showName` **carry**, and now also serve static-binder renaming at inlining (§8.7). |
| C27 | Where the calculus lives | A new front-end module `Agentic/Core/Dsl/Norm.lean`. `Syntax`, `Check`, `Dsl`, `Explain`, `DslFlagship` untouched (§10.1). |
| C28 | The flagship | **`example/harden.wf` stays byte-identical**; the showcase is the pair (round-17 D21 carries) (§10.5). |
| C29 | The CLI | **No new subcommand.** `agent-cat plan` already names every question's rung and position; a normal-form dump is recorded as considered and refused (§5.6). |
| C30 | Round 17 | **D1, D6, D7, D8, D9, D10, D12, D13, D14, D15, D16, D17, D18, D19, D20, D21 all stand.** D2 stands in strengthened form. D3, D4, D5, D11 are superseded by C19 (§6.3). |

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
> position has a base kind and is a name, a literal, or a saturated source. That
> is exactly the grammar of today's `Raw`. **Function types never reach `Code`,
> so closures never reach `Plan`, so `Plan.dyn` stays quarantined and empty.**

The last sentence is the whole safety argument and it should be read twice. A
runtime closure in this system would have to be a value of function type sitting
in an `Env`, which would require an arrow constructor in `Code` and an arrow case
in `El`, which would make `Q c` — the question shape at kind `c` — meaningful for
functions, which is `Plan.dyn`. The owner's STATIC ruling is not a preference
about implementation strategy; it is the only reading under which the calculus
does not reopen the quarantine. §2.3 is where that bites hardest.

### 1.2 The normalization strategy (C2)

Three phases, in this order, with the ordering itself load-bearing.

**Phase A — beta and eta on the function layer.**

```
(\x -> e) a                 ⟶  e[x := a]
(f . g) a                   ⟶  f (g a)
f $ a                       ⟶  f a
v >>> g                     ⟶  g v          -- v at a base kind
f >>> g                     ⟶  \x -> g (f x)
g <<< v                     ⟶  g v
f <<< g                     ⟶  \x -> f (g x)
h  (a `let` or a lambda applied to its full arity)  ⟶  its body, substituted
```

> **The substitution rule (the one that decides what a question costs).**
> **Beta is by-value at the four kinds and by-name at function types.**
>
> A base-kind argument is *hoisted to a binder before substitution*, so it is
> asked once and its name is substituted — exactly the do-block a reader would
> have written. A function-typed argument asks nothing until it is applied, so
> substituting the term itself is free and duplicates no question.

This is not a performance choice. `(\x -> compare x x) (ask q)` under call-by-name
would write the question twice; under D12's sharing rule that is one answer but
**two events and `billFresh` 2**, which is a different transcript from the one the
author wrote. By-value at base kinds makes it one event, which is what `x <- ask q`
means. §5.5 states the consequence as a language rule, because it is the one place
where the calculus can change what a program *costs* without changing what it
*says*.

**Phase B — effect hoisting (ANF).** Post-order over the resulting first-order
term: every `ask`, `panel` or saturated `call` standing anywhere but a statement
position, a binder's right-hand side, or a body's final expression is lifted to a
fresh binder at the head of its enclosing statement, and replaced by that
binder's name.

This *is* round 17 §2.2's lifter, with `!(…)` deleted from its trigger and "every
nested source" put in its place. Its two rules carry verbatim:

* **Post-order** (round-17 D11): an expression's own sub-expressions are lifted
  before it, and siblings in source order. Round 17's defence is unchanged and
  is now stronger, because the post-order property is an *inference
  precondition*: the lifted temporary's only use sits in the next lifted bind's
  right-hand side, and `useKindB`'s `.bind` clause reaches it through
  `firstOf (useKindS sig x src) …` (`Check.lean:246–261`).
* **Lifting never crosses a `{`** (round-17 §2.2, §5.3 divergence 2): an
  expression inside an arm lifts to the head of the statement inside that arm,
  and its question is asked only on that path; an expression in an `if` subject
  lifts before the `if`. `blockAsks`'s per-branch tree keeps its shape
  (`Check.lean:877–890`).

**Phase C — the saturation check** (§4.3). Every runtime position is checked to
hold a base kind. Eta is applied here and only here: a name of arrow type
standing where an arrow is expected needs no expansion, and a name of arrow type
standing at a runtime position is a **refusal**, not an eta-expansion site. So
eta appears in the calculus as the *equation* `f ≡ \x -> f x` that licenses
`(\x -> g x) y ⟶ g y` (the owner's directive 3, which is really beta), and
nowhere as a rewrite the normalizer must search for.

**Why A before B.** Hoisting inside an unapplied lambda body would place a
question outside the block that will eventually contain it. Beta first, hoist
second, and every lifted binder lands in the block the author wrote.

**Why the by-value/by-name split does not need an effect system.** Phase A only
has to know whether an argument's *type* is a kind or an arrow, and types are
synthesized bottom-up with no inference (§4.4). No analysis of "does this ask a
question" is performed anywhere. That is what keeps the discipline "very
limited".

### 1.3 Termination, and the fuel (C3)

**The argument.** The static term algebra is simply typed (§4), has no fixpoint
former, and its table is stratified: a `let` or a `function` may mention only
headers declared above it (`Parse.lean:1187–1190` builds `fnAr` incrementally;
`resolveFn` at `:647–649` can only find what is already there). So inlining a
header strictly decreases the multiset of header ranks, and beta on the
remaining term is beta in the simply-typed lambda calculus, which is strongly
normalizing. **Every accepted program has a normal form, and it is unique.**

**The refusal.** That argument is a paragraph, not a Lean proof, and round 18
does not pay for the Lean proof. Instead, in the spirit of `maxRevisions`
(`Check.lean:502`) and `maxQuestions` (`Check.lean:857`):

```lean
/-- The largest number of normalization steps an expression may take. A
resource limit, like `maxRevisions`, refused with an ordinary diagnosis. -/
def maxNormSteps : Nat := 4096
```

counted over beta steps plus header inlinings, refused with the count and the
position:

```
normalizing this expression took more than 4096 steps; the language has no
recursion, so this is an expression that is merely very large — name a part
of it with a `let`, or bind a part of it above
```

**Never a hang.** This is the same posture the language already takes twice, and
the same posture the lexer takes (`lexAux`'s budget, `Parse.lean:338`).

**What the elaborator actually relies on** is not termination but the
postcondition, and that is two statements, both by induction on the fuel, both
cheap:

```lean
theorem normalize_ok_normal (fuel : Nat) (e e' : SExpr) :
    normalize fuel e = .ok e' → SExpr.isNormal e' = true

theorem normalize_ok_firstOrder (fuel : Nat) (e e' : SExpr) (c : Code) :
    normalizeAt fuel c e = .ok e' → SExpr.isBase e' = true
```

> **Fuel soundness, in one sentence: whatever comes back has no redex left and
> no arrow left, so the emitter never sees one.** Completeness — that no legal
> program hits the bound — is *not* claimed, exactly as it is not claimed for
> `maxQuestions`.

These are the only two new theorems round 18 proposes anywhere (§10.4).

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

Round 18 is a much larger parser change than round 17, and the argument does not
get weaker with size — it gets *more* valuable, because it is the only thing
standing between an expression grammar and a re-transcription of `flagshipRaw`.
The obligation it imposes is precise and is stated here as a rule:

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
`maxQuestions` (`:900`, `:943`), `overRevised` (`:915`) and every level lemma
see nothing but normal forms and cannot tell that a calculus exists.

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
| (b) | **Restrict.** Function-typed parameters refused in round 18; lambdas, `.`, `$`, `>>>`/`<<<` still work applied to first-order functions. | Directive 3's second half — "receiving functions as arguments, returning functions" — is refused. | Nothing new at all in the front end beyond the expression parser. |
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
  difference is elaboration time and which lemma covers the bound.

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

Against `expr-design.md` §6, which is against `GRAMMAR.md` §Grammar.

```
                                   -- DELETED -----------------------------
argument   ::= name | text | "$" label | bang        -- round 17's argument
bang       ::= "!" "(" source' ")"                   -- round 17's bang (C19)

                                   -- ADDED / REPLACED ---------------------
header     ::= import | define | function | let
let        ::= "let" name "=" expr                   -- static; closed (C6)

param      ::= name [ ":" type ]                     -- omitted means `text`
type       ::= kind                                  -- NEW
             | type "->" type                        --   right-associative
             | "(" type ")"

expr       ::= app
             | expr "$"   expr                       -- infixr 0
             | expr ">>>" expr                       -- infixr 1
             | expr "<<<" expr                       -- infixr 1
             | expr "."   expr                       -- infixr 9
             | lambda
lambda     ::= "\" binder { binder } "->" expr
binder     ::= name | "(" name ":" type ")"
app        ::= atom { atom }                         -- left-assoc; §3.3
atom       ::= name                                  -- not a function name: C8
             | text
             | "$" label
             | "(" expr ")"
             | "(" source' ")"                       -- a parenthesized question
source'    ::= ask | panel | call                    -- as round 17; no `revising`

-- runtime positions, all of which take an `expr` and impose a kind (§4.5)
step       ::= [ name [":" kind] "<-" ] expr
             | branching | assertion
bodyfinal  ::= expr
blockfinal ::= expr | branching | "stop" | assertion
subject    ::= expr                                  -- `if` and verdict-`case`
```

Unchanged: `program`, `library`, `import`, `define`, `function`'s header shape,
`labelledblock`, `ask`, `rule`, `loop`, `arms`, `kind`, `text`, `plainstring`,
`block`, `branching`, `assertion`, and every rule in "The rules the grammar does
not carry" except rules 2 and 3, which §7.3 and §5.1 restate.

**Tokens.** Four new: `.` (spaced), `\`, `>>>`, `<<<`. One repurposed by
context: `$`. One new keyword: `let`. `!` is **not** added (C19). `answer`
leaves `stmtWords` (round-17 D20).

### 3.2 The one-slide precedence table

| Level | Form | Associativity | Haskell |
|---|---|---|---|
| tightest | `f a b` — juxtaposition | left | same |
| 9 | `f . g` | right | `Prelude.(.)`, `infixr 9` |
| 1 | `f >>> g`, `f <<< g` | right | `Control.Category`, `infixr 1` |
| 0 | `f $ x` | right | `Prelude.($)`, `infixr 0` |

So `f . g $ x` is `(f . g) x`; `f . g >>> h` is `(f . g) >>> h`; `v >>> f . g`
is `v >>> (f . g)` = `f (g v)`; and `f $ g $ x` is `f (g x)`. These are Haskell's
numbers and they are taken unchanged so that a reader who knows Haskell never has
to check.

### 3.3 How far an application reads (C7)

This is the hardest question in the round, because **the language has no
statement terminator**: braces delimit, indentation means nothing, and
`notify "ready"` followed by `stop` was round 16's counterexample to
lookahead-only rules. Greedy Haskell juxtaposition would swallow the next
statement.

> **The three bounds.** An application reads atoms while all three hold:
> 1. **Arity from above.** The head's arity is not yet reached. For a `name`
>    resolving in the table, the arity is the table's (`resolveFn`,
>    `Parse.lean:647`); for a `let`, it is the arrow count of its type; for a
>    parenthesized or lambda head, it is unbounded and only (2) and (3) apply.
> 2. **The stopper set from below.** The next token begins an atom. It does not
>    when it is `)` `}` `]` `,` `<-` `:` `->` an operator, a number, a
>    `labelledblock`, a **statement word** (`stmtWords`, `Parse.lean:522`), a
>    **function or `let` name** (C8), or end of input.
> 3. **The next-statement probe.** The next token is not an ident immediately
>    followed by `<-` or `:`.

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

### 3.4 A function name does not stand bare in an argument position (C8)

```
  first <- library.drafted library.guide aim shape >>> library.reviewed library.guide
  library.applied patch
```

Without C8, `library.reviewed`'s second argument would be read as
`library.applied`, and `patch` would become junk. With C8 — *a name that
resolves to a function or a `let` is not an atom* — the application stops after
one argument, `library.reviewed library.guide` is the partial application the
pipeline wants, and `library.applied patch` is the next statement. **The rule
exists to make statement boundaries decidable without a terminator, and it is
round 16's own refusal in its useful form**, with two escapes named instead of
one:

```
`library.drafted` is a function; as an argument it is written `(library.drafted)`
or `\x -> library.drafted x`, because bare it would read as a call
```

Cost: passing a function by name to a higher-order `let` costs one pair of
parentheses. Benefit: the parser never needs a type to decide where a statement
ends. **Rejected alternative:** type-directed argument parsing — let `PEnv` carry
parameter *types* and admit a bare function name exactly where a function-typed
parameter expects it. It works, it is one line prettier at the call site, and it
makes the *parser* type-directed, which puts synthesis before parsing and makes
every diagnosis in `parseArgTokens` depend on the type checker. Refused on
layering.

### 3.5 The operators, typed (C9, C10)

Writing `M c` for "a computation answering kind `c`" — a metalanguage word with
**no surface spelling**, because Phase B erases it (§5.1):

```
Γ ⊢ f : b -> c    Γ ⊢ g : a -> b            Γ ⊢ f : a -> b    Γ ⊢ x : a
--------------------------------- (.)       ----------------------------- (app)
Γ ⊢ f . g : a -> c                          Γ ⊢ f x : b


Γ ⊢ f : a -> b   Γ ⊢ g : b -> c             Γ ⊢ e : b   Γ ⊢ g : b -> c
------------------------------- (>>>arr)    -------------------------- (>>>val)
Γ ⊢ f >>> g : a -> c                        Γ ⊢ e >>> g : c

  …and `<<<` is `>>>` with its operands exchanged; `$` is (app) at fixity 0.
```

Two rules for `>>>`, disjoint by the *shape of the left operand's synthesized
type* — an arrow or a base kind — and therefore decided with no inference at
all. §5.2 defends the overload and shows it is coherent with the fixity.

**`.` is arrows only**, on both sides. `f . x` with `x` at a base kind is
refused:

```
`.` composes two functions; to apply one, write `f $ x` or `f x`
```

### 3.6 Lambdas (C12)

```
\x -> e                 -- one binder, defaulting to `text`
\x y -> e               -- sugar for \x -> \y -> e
\(finding : verdict) -> e
\(draft : text -> text) -> e
```

**Where a lambda may stand:** any expression position — an argument, a `let`'s
body, either operand of `.`/`>>>`/`<<<`, the right of `$`. Its body extends as
far as the enclosing expression allows, which is Haskell's rule, and which is
why a lambda in an argument position is parenthesized in every real program.

**Where a lambda may not stand:** any runtime position — a statement, a binder's
right-hand side, a body's final expression, an `if`/`case` subject, a call
argument at a first-order parameter, a `{hole}`. Each is the saturation refusal
of §4.3.

**Binder discipline.** A lambda binder is a name being introduced, so it obeys
rule 6 (no shadowing) and `freshOfTables` (`Parse.lean:530`) exactly as a `<-`
binder does. The payoff is worth stating: **because every name in a program is
distinct, capture-avoiding substitution has nothing to avoid**, and the
normalizer's substitution is a plain traversal. The one exception is a header
inlined twice, where the same static binder would appear at two sites; C26
handles it by minting (§8.7).

### 3.7 Sections: refused (C11)

`(. g)`, `(f .)`, `($ x)`, `(>>> g)` — **refused.** Four reasons, ordered:

1. **They collide with the dot rule head-on.** `(f .)` and `(f.)` differ by one
   space and would mean a section and a lexical error; `(. g)` and `(.g)`
   likewise. The whitespace rule (C20) is already asking the reader to look at
   spaces once; asking twice, at the same character, in the same construct, is
   where a rule becomes a trap.
2. **They elide one binder, and cost a reading.** `(. g)` is `\f -> f . g` and
   `(f .)` is `\g -> f . g`; a reader who has to work out which is which has
   spent more than the four characters `\x ->` saved. The whole justification
   for sections in Haskell is arithmetic and operator sections over a large
   operator vocabulary, which this language does not have (reason 3).
3. **There are no infix value operators at all** in this language — no
   arithmetic, no comparison, rule 3 — so the only sections available would be
   over the four composition operators, which is the least valuable corner of
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
| `function f (…) -> kind {` | after the parameter list's `)` | `parseFn` (`Parse.lean:1110–1112`), which *expects* `->` |
| `\x y -> e` | after a non-empty binder list, inside `parseLambda` | terminates the binder list |
| `text -> text` | only after a `:` in a `param` or a lambda binder | `parseType`, right-associative, terminated by `,` `)` or `->`'s absence |

The third never occurs where the first two can, because a **type** is only ever
read after a `:`, and a `:` is only ever read in a parameter or a binder. The
first never occurs where the third can, because `parseParams` consumes the `)`
before `parseFn` looks for `->`. And a lambda's `->` cannot be mistaken for a
type's, because `parseType` is not on the stack when binders are being read.

The one shape that looks alarming and is not: `\(g : text -> text) -> e`. The
inner `->`s are inside the binder's parentheses and are consumed by `parseType`,
which stops at the `)`; the outer `->` is the lambda's. Pin it.

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

### 4.3 Partial application, and what saturation means (C17)

> **Partial application is legal statically and refused at every runtime
> position.** `library.reviewed library.guide` is a value of type
> `text -> verdict`; it may be an operand of `.`, `>>>`, `<<<`, `$`, an argument
> at a function-typed parameter, or a `let`'s body. It may **not** be bound by
> `<-`, stand as a statement, be a body's final expression, be an `if`/`case`
> subject, fill a first-order parameter, or appear in a hole.

Refusals, each naming what to do:

```
`library.reviewed` takes 2 arguments and 1 is written here; a question
cannot be asked of a function — apply it, or bind what it needs above
```
```
the last statement of `f` answers a function; `f` answers `text` — apply it
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

**Consequence for `checkArgs_too_few`.** The parser no longer emits an
under-applied call into `Raw`; the saturation check refuses it first. So
`checkArgs_too_few` (`Check.lean:388`) and `checkArgs_too_many` (`:395`) survive
**verbatim, statement and `rfl` proof**, and become *unreachable from source
text* — the same documented category as `check_panel_nil` (`:717`), tested
against hand-built `Raw` in the same way (`DslSmoke.lean`'s exception 2). No
theorem restates; one battery note moves.

**A syntactic consequence worth stating:** because an application is bounded
above by arity (§3.3), **a partial application is always parenthesized or an
operand**. You cannot write one bare at a statement head, which is exactly where
it would be refused anyway.

### 4.4 The typing discipline, stated as a refusal (C18)

> **Types are synthesized bottom-up and checked top-down at runtime positions.
> There is no unification, no Hindley–Milner, no let-polymorphism, no type
> variables, and no inference of an arrow type from a body.**

* **Synthesis.** A name synthesizes from the table (`function`, `let`, `define`)
  or from the binding (`Bindings`/`Binding.code`); a literal synthesizes `text`;
  an application synthesizes its head's result; `.`/`>>>`/`<<<`/`$` synthesize
  by the rules of §3.5; a lambda synthesizes `τ → σ` from its annotated (or
  defaulted) binder and its body.
* **Checking.** Every runtime position *imposes* a kind, and round-17 §4.1's
  imposed-kind table is unchanged and now carries three more rows:

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

* **Monomorphic, and that is fine.** A `let` is not generalized: `let apply =
  \(f : text -> text) -> \x -> f x` works at `text` and nowhere else, and a
  second instantiation is a second `let`. In a language with four base types, no
  data structures, no lists and no recursion, polymorphism buys almost nothing
  and costs a unification algorithm, a generalization rule, and an error-message
  vocabulary (`cannot match `a` with `text``) that the rest of the language does
  not have.
* **Kind inference is untouched.** Named `<-` bindings keep first-ground-use
  inference and the round-8 honest side condition (an annotation is *required*
  for any constraint component that never touches a ground site). Round 17 §4.2's
  three strengthenings carry: a hoisted temporary is anonymous, used exactly
  once, at the position it was lifted from, which is always a ground site. **The
  calculus makes that *more* true, not less** — every nested source now becomes
  such a temporary, so the fraction of bindings in the fragile multi-use case
  falls again.

### 4.5 What `PEnv` must now carry — a prediction that came true

Round 17 §2.3 recorded two conditions under which D2 would need revisiting, of
which the second was *"any move away from arity-directed parsing"*, and noted
that `PEnv` carries `fnAr : List (String × Nat)` — arities, not kinds
(`Parse.lean:496–509`). Round 18 does not move away from arity-directed parsing
(§3.3 keeps arity as the primary bound), but it does need arities for `let`s and
types for the static table, so `PEnv` gains:

```lean
  /-- Static headers: a `let`'s name and its type. -/
  lets : List (String × SType) := []
```

and `fnAr` stays exactly as it is. That is the honest scope of the change: the
first-order path is untouched; the static path is new data beside it.

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
only in fixity — which is exactly Haskell's own situation.** In
`Control.Category`, `(<<<) = (.)`, and Haskell nonetheless ships both, at
`infixr 9` and `infixr 1`, because they serve different idioms: `.` for a tight
composition inside a larger expression, `<<<`/`>>>` for a left-to-right or
right-to-left pipeline read as a sentence. Round 18 inherits the fact and the
reason. **This is not a divergence from Haskell; it is Haskell's design,
specialized to a category that happens to be the only one this language has.**

**The monad is invisible in the type language.** There is no `M` in the surface
type grammar (§4.1) because Phase B erases it: an expression of "type `M c`"
becomes a binder of kind `c` plus a statement above. That erasure is what makes
"a simplified Haskell with a very limited typing discipline" honest rather than
aspirational.

### 5.2 `>>>` and `<<<`: the pipeline rule, and its coherence (C10)

The owner's directive 1 writes `f x >>> g` — a **value** on the left, not an
arrow. That is Haskell's `>>=` (or `&`), not Haskell's `>>>`. Round 18 takes the
owner's spelling and states the overload:

> **The flow rule.** `>>>` and `<<<` mean "flow left into right" and "flow right
> into left". Each accepts an **arrow** on the flowing side, in which case it
> composes; or a **value**, in which case it applies:
>
> ```
> f >>> g   =  \x -> g (f x)          f, g arrows
> v >>> g   =  g v                    v a value
> g <<< f   =  \x -> g (f x)          f, g arrows
> g <<< v   =  g v                    v a value
> ```

**Why the overload is safe.** The two rules are disjoint by the *synthesized
type* of the operand, which is known before the operator is elaborated, with no
inference and no backtracking. There is no expression whose type is both an
arrow and a kind.

**Coherence with the fixity, which is the part worth checking.** `>>>` is
`infixr 1`, so `a >>> f >>> g` parses as `a >>> (f >>> g)`. Normalizing:

```
a >>> (f >>> g)   ⟶   (f >>> g) a   ⟶   (\x -> g (f x)) a   ⟶   g (f a)
(a >>> f) >>> g   ⟶   (f a) >>> g   ⟶   g (f a)
```

**Both associations reach the same normal form**, so the reader never has to know
the fixity to know the meaning. The same holds for `<<<`. Add it to the battery
as a normal-form equality case.

### 5.3 What the owner's five spellings elaborate to

Given `f : text -> text` and `g : text -> verdict` (both `function`s) and a
binding `x : text`:

| Spelling | Rule | Normal form |
|---|---|---|
| `y <- f x`  `g y` | round-17 do-notation | `!L:C <- f x` ; `g !L:C` |
| `f x >>> g` | (>>>val) | *the same* |
| `g <<< f x` | (<<<val) | *the same* |
| `(g . f) x` | (.) then (app) | *the same* |
| `g . f $ x` | fixity 9 then 0 | *the same* |
| `g (f x)` | (app) then Phase B | *the same* |

**Six spellings, one normal form**, and the identification is by normalization
rather than by a table of special cases. That is the whole content of directives
1 and 2, and it is a `decide`-able battery case: parse each, normalize, and
compare the resulting `Raw` for equality — `Raw` derives `DecidableEq`
(`Syntax.lean`), so this is one `decide` per pair and no `native_decide`.

### 5.4 Cost and trace through normal forms (C24)

> **`blockAsks`, `bodyAsks` and `rhsAsks` are unchanged** (`Check.lean:860–890`)
> **because they run over `Raw`, and `Raw` is the normal form.** So is
> `maxQuestions` (`:857`, guards at `:900` and `:943`), so is `overRevised`
> (`:915`), so is every bill and every trace.

Stated exactly: normalization happens inside `parseProgramWith`
(`Parse.lean:1291`); `checkProgram` (`Check.lean:932`) receives a `RawProgram`
that has already been normalized; **`blockAsks` never sees a lambda, a `.`, a
`$`, a `>>>`, a `let`, or a partial application.**

The derived recurrence, for a reader of the *surface*:

```
asks(stmt)         = Σᵢ asks(sᵢ) + asks(head)     -- sᵢ the hoisted sources, post-order
asks(f . g)        = asks(g) + asks(f)            -- g's questions first
asks(v >>> g)      = asks(v) + asks(g)
asks(a `let` use)  = asks(its normal form), per site
asks(if b … …)     = asks(b's hoists) + asks(yes) + asks(no)
asks(arm)          = a hoist inside an arm counts inside that arm only
asks(revising)     = unchanged — C19/D15 means a loop clause hoists nothing
```

**The order rule** (round-17 §5.1, widened): the questions a statement asks are
put in the order its sub-expressions are hoisted — post-order — followed by the
statement's own question, and that is the order of the events in the trace. For
composition this reads: **`f . g` asks `g`'s questions before `f`'s, because the
data flows that way.** For `>>>` it reads left to right. Both are "the direction
the value moves", stated once.

**Positions.** A question's `Pos` is **where its words are written**. For a
question inside a `function` body that is already true today (the body is
checked once, with its own positions). Round 18 makes the same choice for a
`let`: a `let` used twice produces two questions at one position, and
`agent-cat plan` prints that position twice. This is uniform with `function`,
and it is the argument for keeping `let` bodies short — which the guide should
say.

**The honest new hazard, named.** Before round 18 you could count a program's
questions by counting `ask`s, panels and calls on the page. After round 18 you
cannot, because a `let` used *k* times costs *k* times its body. The mitigation
is not a new rule; it is that `agent-cat cost` and `agent-cat plan` run on the
elaborated plan and have always been the answer to that question — which is the
twelfth of the survey's differentiators and the reason those commands exist.
Record it in `GRAMMAR.md`'s "Hazards, named".

### 5.5 Divergence 3: substitution sharing (C25)

Round 17 stated two divergences from Idris. Round 18 adds a third, and this one
is a divergence from a *naive* reading of the calculus rather than from another
language:

> **Two questions *written* are two events; one question *substituted* twice is
> one event.**
>
> ```
> compare (ask model "critic" "Rate:\n{p}") (ask model "critic" "Rate:\n{p}")
> ```
> — two events, one answer, `billFresh` 2, `billMemo` 1, `blockAsks` 2 (round-17
> D12, unchanged).
>
> ```
> (\x -> compare x x) (ask model "critic" "Rate:\n{p}")
> ```
> — **one** event, one answer, `billFresh` 1, `blockAsks` 1, because beta is
> by-value at base kinds (C2) and the argument is hoisted to one binder before
> substitution.

The second is what `x <- ask …` then `compare x x` means, and it is what a reader
expects a lambda to do. Getting there required the by-value rule, which is why C2
is a decision and not an implementation note. Both lines go in the battery, with
their bills.

### 5.6 The CLI (C29)

**No new subcommand.** A `agent-cat norm` that printed the normal form was
considered — it would be genuinely useful while the parser is being written —
and is refused as scope: `agent-cat plan` already enumerates every question with
its rung and its position, which is the user-facing question ("what will this
ask, and where did it come from"), and a normal-form dump is a *compiler*
question. If the campaign wants one, it belongs behind a debug flag in the
implementation obr, not in the language design.

---

## 6. The bang's fate: dropped (C19)

### 6.1 The criteria, then the answer

Round 17's noise audit asked three questions of every construct. Asked of
`!(…)`, now that parentheses, lambdas, `$` and `>>>` exist:

| Criterion | Answer |
|---|---|
| Does it distinguish two readings that would otherwise collide? | **No.** `judged (drafted g a) r` and `judged !(drafted g a) r` have one reading each, and it is the same one. Round 17 said so itself: *"the parentheses remove the ambiguity, which is precisely why the feature is safe now and was not before"* (§6.1). |
| Does it warn the reader of a cost they could not otherwise see? | **No more than the callee's name does.** `drafted` is a question either way; the `!` adds a glyph, not a fact. And `agent-cat cost` is the actual answer (§5.4). |
| Is it in the language the owner asked us to follow? | **No.** Haskell has no bang; Idris's means "run this action", which §5.3 of round 17 had to spend two divergences correcting. |

> **Decision: `!` is dropped, and `punctChars` does not gain it.** Round-17 D3,
> D4, D5 and D11's *trigger* are superseded; D11's *traversal* (post-order)
> survives as C2's Phase B, applied to every nested source rather than to marked
> ones.

**The counter-argument, recorded fairly.** The bang made "this argument costs
questions" visible at a glance, and dropping it means a reader of
`judged (drafted g a) r` must know that `drafted` is a function rather than a
binding. That is a real loss. It is accepted because the language already
requires that distinction everywhere else — a statement `f x` is a call exactly
when `f` is a function, and has been since round 16 — and because C8 (*a
function name does not stand bare in an argument position*) means a bare name in
an argument position is **never** a call, which localizes the reader's question
to "is there a paren here".

### 6.2 The timing, which is a saving

**Round 17 has not shipped.** Under the owner's "one design, then one campaign"
ruling, the bang's parser plumbing — `parseBang`, the D4/D5/D9 refusals, the
`!`-in-`punctChars` change, six accepted battery cases and twelve refusal cases —
is **never written**. §10.6 credits it: roughly a day of implementation and a
half-day of battery that round 17 had budgeted and round 18 does not spend.

### 6.3 What of round 17 survives (C30)

| Round-17 decision | Fate in round 18 |
|---|---|
| D1 `answer` deleted | **Stands.** The last statement of a body is its answer; §3.9 refuses `ret` for the same reason. |
| D2 desugar at parser level, into today's `Raw` | **Stands, strengthened** — it is now C4, the north star, and it is carrying much more weight. |
| D3 where `!` may stand | **Superseded** (C19). Its content becomes: an expression may stand wherever a value may stand. |
| D4 `!x` refused | **Superseded** — there is no `!`. The *content* survives as C25's note that a name is already an answer. |
| D5 `!(…)` as a whole statement | **Superseded** — `(ask q)` as a whole statement is now just `ask q` with redundant parens, which is accepted and harmless. |
| D6 no `!` / no expressions inside prompt text or a `{hole}` | **Stands, and is now load-bearing for four operators.** Prompts stay byte-literal; `$`, `.`, `\` and `>` inside prompt text are prose (§8.6). Its proof-side reason survives: `expand_lit`, `expand_interp_hit`, `expand_append` (`Parse.lean:574, 577, 583`) are unchanged *because* a `Chunk` never contains a source. |
| D7 no question as a panel member | **Stands**, restated: a panel's members are `ask`s, not expressions. A panel of *k* members costs *k* questions in every world, and the monoid, the trace and the cost model are stated over questions. |
| D8 no expression as a `revising` subject | **Stands**, on the same taste-plus-technical grounds (`revising draft as patch` is a sentence whose subject is a noun; and the subject is the one name position whose grounding runs through `useKindS`'s carrier clause). |
| D9 no `$label` inside a nested call | **Stands, and widens**: a call carrying `$label`s may not be an operand of any operator and may not be an argument, because its labelled fences are collected *after its arguments* (`collectLabelled`, `Parse.lean:707–720`) and there is nowhere to put them. |
| D10 temporaries minted already-qualified | **Stands** (C26), and now also renames static binders at inlining. |
| D11 post-order | **Stands** as C2's Phase B traversal. |
| D12 sharing: two identical questions are one answer | **Stands**; C25 adds the substitution case beside it. |
| D13 no change to the function header | **Stands** for `function`; `let` is a *new* header, not a change to that one (§7). |
| D14 `amend`, `as`, `stop`, `known here` all kept | **Stands.** |
| D15 no lifting site inside a `revising` clause | **Stands, and matters more.** A clause is a single `RawRhs` slot (`Syntax.lean:239–241`), so there is nowhere to hoist; hoisting out of the loop would ask once instead of once per round and would break `blockAsks`'s `(n+1)·review + n·amend` recurrence. Diagnosis unchanged. |
| D16 parameter annotations default to `text` | **Stands** (C15), extended to lambda binders. |
| D17 `-> receipt` bodies do not lift | **Stands.** The clause is keyed on `result : Code`, which `parseFnBody` already has (`Parse.lean:1025`). |
| D18 trailing bindings refused in blocks, arms and bodies, not in a priming | **Stands.** |
| D19 the fence-close drift | **Stands, and is still required.** `fenceCloses` (`Parse.lean:210–219`) must accept `)` and a trailing comment, because a parenthesized question ending in a fence puts a `)` there — the *majority* case now that every nested question is parenthesized. |
| D20 `answer` deleted cold, one migration clause | **Stands.** |
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
> let name = expr
> ```
>
> A **header**, in the header stratum with `define` and `function`, before the
> `workflow` block or the priming. Its right-hand side is a static expression of
> any simple type. It is **closed**: it may mention `define`s, `function`s and
> `let`s **declared above it**, and nothing else — never a runtime binding.

**Why `let` earns its place now, when round 17's audit killed it.** Round 17
refused `let` on the ground that there was no pure computation to name: every
right-hand side was a question, and questions are bound with `<-`. Round 18
creates exactly the missing thing — a composed arrow, a partial application, a
lambda — none of which is a question and none of which can be bound with `<-`
(they are not answers). `let review = judged . normalize` names a *step of the
program's vocabulary*, not a step of its execution.

**Why top-level only, and why closed.** Rule 2 of `GRAMMAR.md` says: *"A name is
introduced only left of `<-`, as a `settled` arm's binder, or at a loop head's
`as`. Nothing is bound by a keyword's position."* A statement-position `let`
would break that flat, and would introduce a **second class of name inside a
block** — one that `known here` must not list, that `agent-cat plan` shows
nothing for, and that a reader would have to classify before knowing whether it
cost anything. A *header* does not break rule 2, because a header is not a
statement — exactly as `define` is not. Closedness is what makes the rule
checkable in one line and what removes every capture question at inlining time.

Refusal for the statement position:

```
a `let` names a static function and belongs with the other headers; inside a
block, `<-` binds an answer
```

**The keyword cost, paid in the open.** `let` joins `stmtWords`
(`Parse.lean:522`), so `let` stops being a legal binder, parameter or function
name. That is one word out of the namespace, on the same list as `define` and
`function`, and it is the whole price.

**Namespace.** A `let` lives in the **function** namespace: `freshOfTables`'s
function clause (`Parse.lean:537`) covers it, so a binder may not spell a `let`,
a `let` may not spell a define, and `resolveFn` finds it. That is one line in
each of three places, and it preserves "every name in a program means exactly
one thing".

### 7.3 What rule 2 and rule 3 become

`GRAMMAR.md`'s rule 2 gains one clause and rule 3 needs one honest rewrite:

> **Rule 2 (revised).** A *runtime* name is introduced only left of `<-`, as a
> `settled` arm's binder, or at a loop head's `as`. A *static* name is
> introduced by a `let` header, a `let`'s lambda binder, or a lambda binder at
> an expression position — and every static name is gone before the program
> runs.

> **Rule 3 (revised).** There are two consumption sites for an *answer* —
> `{x}` in a prompt, and `if x` / `case x` — and no third. There is now an
> expression language over **functions**, and it has no operations on
> answers at all: no test, no comparison, no arithmetic, no transformation.
> Every value a program computes is still the answer to a question that is
> written on the page, and "who can see what" is still answered by reading one
> statement — because every expression hoists into the statement it sits in.

The second is the sentence a reviewer will attack, and it should be attacked. It
is defensible exactly because §5.1's ruling is true: the calculus can move
answers around and can name the moving, but it cannot *inspect* one. The four
operators are all composition; none of them is a function of a `text`.

---

## 8. Collisions, enumerated and resolved

### 8.1 The dot (C20)

**Today**, a dot is *only* legal glued between two identifiers. `lexAux`'s ident
branch (`Parse.lean:385–398`) matches `'.' :: d :: _` and glues **only when
`isIdentStart d`**; every other dot falls to `punctChars.contains c`, which does
not contain `.`, and then to `.error ⟨p, "unexpected character", …⟩`
(`Parse.lean:399–402`). So:

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
| `a.b.c` | `.ident "a.b"` then a stray `.` | refused — *"modules do not nest"* (unchanged) |

The implementation is two lines: add `'.'` to `punctChars` (`Parse.lean:102`).
The glue at `:389–397` already tests both sides, so nothing else moves. Note
`f. g` and `f .g` both composing follows from the *existing* code, not from a new
rule: the glue requires `isIdentStart d` where `d` is the character after the
dot, and a space fails it.

**The one new mistake the rule creates, and its diagnosis.** An author who means
composition and forgets the spaces writes `f.g`, which lexes as a qualified name
and reaches `resolveFn` (`Parse.lean:647`) as `"f.g"`. Key the message on a
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

Two battery cases, one each.

**Holes are unaffected.** `scanHole` has its own dotted-name rule
(`Parse.lean:120–142`) and runs inside `scanString`/`scanBlockChunks`, never
through `lexAux`. `{library.spec}` is byte-identical, and `{f . g}` is refused
by `scanHole`'s existing *"a hole is `{name}`"* diagnosis, which is the right
answer under D6.

### 8.2 Dotted names as function heads and as arguments

`library.judged patch rubric context` — the head is one `.ident` token,
`resolveFn` resolves it (`Parse.lean:647–649`), arity-directed reading proceeds.
Unchanged.

`library.filed . library.summarised patch` — three tokens: `.ident
"library.filed"`, `.punct '.'`, `.ident "library.summarised"`, then `patch`.
Composition of a qualified name with a partial application of another. The
whitespace rule does all of the work and no new resolution rule is needed.

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

### 8.5 `>>>` and `<<<` (C23)

* `<` today: `.arrow` on `<-`, else *"stray `<`; `<-` binds an answer, and
  nothing else in the language begins with one"* (`Parse.lean:349–353`). Extend:
  `<<<` before the arrow test; the stray message gains `<<<`.
* `>` today: no branch at all — `-` handles `->` at `:346`, so a bare `>` is
  *"unexpected character"*. Add a branch: `>>>`, else a stray-`>` message in the
  same voice: *"stray `>`; `->` is a function's result and `>>>` a pipeline, and
  nothing else in the language begins with one"*.
* `>>` and `<<` are **not** tokens and are refused by the same two messages.
  Haskell's `>>` (sequence) has no place here: statements sequence by being
  written.

All four spellings are lex errors today, so no existing file changes meaning.

### 8.6 Operator tokens inside prompt text stay literal

`$`, `.`, `\`, `>`, `<`, `!` and every other operator character inside a prompt —
in either spelling — is literal, because a prompt is lexed by `scanString` or
`scanBlockChunks` as **one token** and neither scanner consults `punctChars`.
The only characters with meaning inside a prompt are `{`, `}` and `\` before a
brace. This is round-8's byte-literal decree, round-17's D6, and the reason the
guide can say *"a prompt is what you wrote"* without a caveat list.

Battery: one prompt containing `f . g`, `$x`, `\`, `>>>` and `!`, checked byte
for byte against the string spelling — the existing two-spellings `decide` pin
(`DslSmoke:1016`) is exactly the right instrument.

### 8.7 Temporaries and static binders (C26)

Round-17 D10 and §2.4 carry **verbatim** and are cited rather than restated:

* the temporary is minted **already-qualified, once, at the lifter**, routed
  around `PEnv.q`/`qualRefs`;
* `Dsl.isTemp x := x.any (· == '!')` is total and cannot misfire, because
  `isIdentStart`/`isIdentCont` (`Parse.lean:98–100`) exclude `!` — and note that
  C19 dropping the bang makes this **stronger**, not weaker: `!` is now not a
  token at all, so a temporary's spelling is unwritable by any means;
* **Leak 1**, `known here`: `live` filters temporaries
  (`checkBlock`'s `knownHere` clause, `Check.lean:534`), which is the identity
  on every program that exists today and keeps all eight `known here` battery
  cases byte-unchanged;
* **Leak 2**, seven quoting sites get `showName`, and the five theorem-quoted
  messages (`check_panel_nil` `:717`, `checkArgs_too_few` `:388`,
  `checkArgs_too_many` `:395`, `checkProgram_overRevised` `Dsl.lean:694`,
  `checkProgram_oversized` `:706`) stay off-limits.

**New in round 18:** the same minting renames **static binders at inlining**. A
`let` inlined at two sites would otherwise introduce its lambda binder twice,
which rule 6 forbids; minting `x` to `!L:C` at each site — where `L:C` is the
*use* site — makes the two copies distinct without an alpha-renaming pass and
without a gensym counter. One mechanism, two jobs, and `showName` already keeps
both out of the diagnoses.

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
-- The lambda earns its place here, and composition cannot replace it: `.`
-- composes at arity one, and `summarised` takes two arguments. Haskell would
-- write `(filed .) . summarised`; that is exactly the noise this audit exists
-- to refuse.
let logged = \patch finding -> filed (summarised patch finding)

-- A static HIGHER-ORDER function: its parameter is a function, so it is a
-- `let` and not a `function` — a runtime function's parameters are answers,
-- and an answer has a kind.
let checked = \(draft : text -> text) -> \goal ->
      judged (draft goal) rubric spec

-- The priming. Asked once, before anything an importer writes. A priming is a
-- prefix, not a block: it has no final position, so the trailing-binding
-- refusal does not reach it.
guide : text <- ask tool "cat" "Write out the house style guide, at most four short lines."

ask model "author" ```
    {guide}
    You are drafting patches for this codebase. Hold this style guide.
```
```

**The refusal this file demonstrates by not containing it.** `let primed =
reviewed guide` would be refused — `guide` is a runtime binding and a `let` is
closed (C6):

```
a `let` is a static definition and may name only the headers above it;
`guide` is an answer, bound when the program runs — pass it at the use site
```

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
      -- to make the `text -> text` that `checked` asks for.
      second <- library.checked (library.revised . library.drafted library.guide aim) shape

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
            -- intermediates, no names, read left to right.
            library.judged patch library.rubric twice
              >>> library.summarised patch
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

### 9.3 The three normalizations, shown

**The composition in an argument.** Source:

```
second <- library.checked (library.revised . library.drafted library.guide aim) shape
```

Phase A inlines `checked` (a `let`), substitutes the arrow **by name** (it asks
nothing until applied) and `shape` **by value** (it is a literal, so its hoist is
trivial), and beta-reduces:

```
second <- library.judged ((library.revised . library.drafted library.guide aim) shape)
                         library.rubric library.spec
        ⟶ library.judged (library.revised (library.drafted library.guide aim shape))
                         library.rubric library.spec
```

Phase B hoists post-order — innermost first, siblings in source order:

```
!45:34 <- library.drafted library.guide aim shape
!45:18 <- library.revised !45:34
second <- library.judged !45:18 <rubric's words> <spec's words>
```

Three statements of today's `Raw`, three calls, in the order the data flows.
(`rubric` and `spec` are defines, so they are already literal `RawArg.lit`
chunks by the time the normalizer runs — `expand` at `Parse.lean:553`; `aim` and
`shape` likewise.) `blockAsks` prices this at 1 + 1 + 1 = 3 questions, being one
per callee body, and `checkProgram`'s `maxQuestions` guard (`Check.lean:943`)
sees exactly that.

**The Kleisli chain.** Source:

```
library.judged patch library.rubric twice >>> library.summarised patch >>> library.filed
```

`>>>` is `infixr 1`, so this is `v >>> (f >>> g)`; §5.2's coherence says the
normal form is the same either way:

```
!58:15 <- library.judged patch <rubric's words> <twice's words>
!59:19 <- library.summarised patch !58:15
library.filed !59:19
```

The last line is a statement call at `receipt`, which is exactly what an arm's
final statement must be (D18, D17), and exactly what the three-binder version
elaborated to. (Two temporaries, two positions: no two hoisted expressions begin
at one line and column, which is round-17 D10's collision argument, unchanged.)

**The `let` with a lambda.** `library.logged patch second` inlines to
`library.filed (library.summarised patch second)` and hoists to

```
!62:19 <- library.summarised patch second
library.filed !62:19
```

Two questions, both at the `let`'s body positions per C24 — which is the
position rule's honest cost, visible here.

### 9.4 Where the calculus was refused, and why

| Site | Calculus form considered | Kept as | Reason |
|---|---|---|---|
| `draft <- library.drafted …` | `>>>` into the loop | a binder | The loop's subject must be a name (D8), and `draft` is read twice. |
| `why <- library.reviewed …` | any expression | a binder | D15: a clause is one question per round; there is no hoisting site. |
| `objected { library.logged patch second }` | `library.filed . library.summarised patch $ second` | the plain call | One step. The composition is the same length and asks the reader to compute a normal form. |
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
| **`let`, higher-order** | `library.checked` |
| **a lambda** | `logged`'s body |
| **an annotated function-typed binder** | `\(draft : text -> text) -> …` |
| **partial application** | `library.drafted library.guide aim`; `library.summarised patch` |
| **`.` composition** | `library.revised . library.drafted library.guide aim` |
| **`>>>` pipeline, two steps** | the approved arm |
| **`$`** | in the battery only — the showcase never needed it, and that is worth recording |

Not covered, deliberately: `at least n must approve` (acat-f10), `<<<` (the
mirror of `>>>`, covered in the battery), sections and function-typed results
(both refused), and every construct round 18 refuses.

**Two lexer facts this pair depends on**, both from D19: the `if` subject's fence
closes with ```` ```) ```` and nested parenthesized questions close with
```` ```)) ````. Neither lexes without the `fenceCloses` repair, and round 18
needs it *more* than round 17 did, because every nested question is now
parenthesized.

---

## 10. Theorem survival and pricing

### 10.1 What moves, file by file (C27)

| File | Round-18 change |
|---|---|
| `Agentic/Core/Plan.lean`, `Cost.lean`, and the kernel | **none** |
| `Agentic/Core/Dsl/Syntax.lean` | **none.** `Raw`, `RawBlock`, `RawBodyStmt`, `RawRhs`, `RawSource`, `RawArg`, `RawFn`, `RawProgram` all unchanged. `RawFn.answer`'s docstring is rewritten, as round 17 already planned. |
| **`Agentic/Core/Dsl/Norm.lean`** | **NEW.** `SType`, `SExpr`, type synthesis, `normalize`, the hoister, `maxNormSteps`, and the two fuel-soundness theorems. ~600 lines. |
| `Agentic/Core/Dsl/Parse.lean` | the expression parser; five lexer changes; `let` in the headers; `parseType`; `PEnv.lets`; the round-17 refusals that survive. ~+450 / −120 lines. |
| `Agentic/Core/Dsl/Check.lean` | **two clauses and seven messages** — the `knownHere` `live` filter and `showName`, exactly as round 17 priced them. Nothing else. |
| `Agentic/Core/Dsl.lean` | **none** |
| `Agentic/Core/Dsl/Explain.lean` | **none** |
| `test/DslFlagship.lean` | **none** (§10.5) |

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
changes, the match's *patterns* do not, so the reduction is unaffected.

**`parseAndCheck_level_le` still bounds every accepted program at branch**, and
the calculus cannot raise the rung, because every hoisted step is a `.bind`
covered by `bindForm_level_le` and every inlined `let` produces statements the
caller's own induction already covers. **A `let` is not a new rung; it is not a
rung at all.**

**The six guards survive verbatim**: `overRevised_sound` (`:615`),
`checkProgram_overRevised` (`:694`), `checkProgram_oversized` (`:706`),
`checkProgram_of_within` (`:720`), `checkBlock_caseVerdict_arms` (`:733`),
`askShape_draw` (`:762`). `overRevised_sound`'s induction steps through
`.bind _ _ (.rhs _) rest` (`:638–640`), which is the shape every hoisted bind
has, so hoisted binds are transparent to it, and
`Explain.RawBlock.revisionBounds` (`Explain.lean:378`) skips them the same way.

### 10.3 `Check.lean`'s own theorems, and `Explain.lean`'s seven

**All survive verbatim.** `check_panel_nil` (`Check.lean:717`),
`parseAndCheck_ok_iff` (`:972`), `under_ask1`/`under_askC1` (`:179`/`:184`) are
`rfl`s or unfoldings about functions round 18 does not touch.

`checkArgs_too_few` (`:388`) and `checkArgs_too_many` (`:395`) survive verbatim
**and become unreachable from source text** (§4.3), which is a documented
category the battery already has. This is the one place round 18 changes the
*status* of a theorem without changing its text, and it is recorded rather than
buried.

`Explain.lean`'s seven — `parseAndCheckRaw_eq_with_nil` (`:292`),
`parseAndCheckRawProgramWith_eq` (`:301`), `_level_le` (`:318`),
`parseAndCheckRawWith_level_le` (`:329`), `parseAndCheckRaw_eq` (`:336`),
`parseAndCheckRaw_level_le` (`:343`), `bindForm_ask_head_draw` (`:356`) —
**survive verbatim.** The six front-end parity theorems `cases`/`split` on
`parseProgramWith`'s result and never inspect it, which is C4 in concrete form.
`bindForm_ask_head_draw` is ∀-quantified over `bindForm fns c S (.ask a)`, so it
now *additionally* guarantees that a **hoisted** ask puts the source-written draw
index on the first event of its run — a free strengthening, and the proved half
of the sharing rule (§5.5).

`Parse.lean`'s three — `expand_lit` (`:574`), `expand_interp_hit` (`:577`),
`expand_append` (`:583`) — **survive verbatim, and D6 is why**: an expression
legal in a prompt would put an `SExpr` inside a `Chunk`, and `expand_append`'s
homomorphism statement would no longer type-check.

### 10.4 What is genuinely new, proof-side

**Nothing that any existing theorem needs.** Normalization is front-end, and no
theorem inspects the parser's output.

**Two statements the normalizer itself wants**, both by induction on the fuel,
both in `Norm.lean` (§1.3): `normalize_ok_normal` and `normalize_ok_firstOrder`.
Their content is the licence the emitter runs on — *the emitter never sees a
redex and never sees an arrow* — and their cost is an afternoon.

**Deliberately not proved:** strong normalization of the calculus (§1.3's
argument is a paragraph, and the fuel is the shipped answer, exactly as it is for
`maxRevisions` and `maxQuestions`); confluence (the normalizer is
deterministic — it does not search, so uniqueness of *its* normal form is
definitional); and any theorem relating surface cost to normal-form cost (there
is nothing to relate: cost is *defined* on the normal form, §5.4).

**Kernel and axiom policy: untouched.** No `native_decide`. The lexer still never
runs in the kernel — normalization is part of parsing, so it inherits that. No
new `Decidable` instances and no new `deriving` on any type a kernel proof
mentions: `SType`/`SExpr` derive `Repr`/`DecidableEq` for the battery's benefit
only, and no `decide +kernel` result mentions them.

### 10.5 The flagship, re-answered (C28)

`flagshipSource := include_str "../../example/harden.wf"`, and
**`example/harden.wf` is not rewritten.** The premise was checked, clause by
clause, against the actual file rather than assumed:

| Round-18 clause | `harden.wf` |
|---|---|
| C20 the dot | contains no `.` outside prompt text (its prompts are `scanString`/`scanBlockChunks` tokens) |
| C21 `$` | contains no `$` |
| C22 `\` | contains no `\` |
| C23 `>>>`/`<<<` | contains none |
| C6 `let` | declares none; contains no binder, parameter or function named `let` |
| C7/C8 application | contains **no calls at all** — no `function`, no `import` |
| round-17 D1 `answer` | no functions, so no `answer` |
| round-17 D18 trailing bind | its workflow block ends in `case result { … }` |
| round-17 D17 receipt bodies | no bodies |
| D19 `fenceCloses` | every fence is closed by whitespace only |
| C4 emission obligation | the block parser's tree and positions are unchanged for a file containing no calculus form |

Therefore `flagshipRaw` (`DslFlagship.lean:97`), `flagshipProgram` (`:255`),
`flagshipPlan` (`:206`), `flagshipRaw_accepted` (`:224`), `check_flagshipRaw`
(`:229`), `checkProgram_flagship` (`:260`), `parseAndCheck_flagship` (`:269`),
`level_flagshipPlan` (`:282`), `card_leaves_flagship` (`:293`),
`minFold_flagship` (`:301`), `maxFold_flagship` (`:308`), the four
`trace_flagship_*`, the four `bill_flagship_*`, `flagshipUpTo`,
`flagship_bill_le`, `minFold_flagship_le_bill` and `render_eq_harden_render`
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
round 18 removes its bang cases and adds its own.

| Category | Δ | Note |
|---|---|---|
| round-17 cases that stand | ~+30 | D1/D16/D17/D18/D19/D20 accepted-and-refused cases, the fixture edits, the seven `showName` sites, the `known here` filter |
| round-17 bang cases **never written** | **−18** | 6 accepted + 12 refused (C19, §6.2) |
| **new**: the six spellings of one normal form (§5.3), by `decide` on `Raw` | 6 | one per pair, plus `>>>` associativity |
| **new**: `.` accepted — two arrows, a partial application, a dotted name | 4 | |
| **new**: `.` refused — a value operand; `f.g` unqualified; `library . spec` | 3 | §8.1 |
| **new**: `$` — all five rows of §8.3's table | 5 | the `$label` rows are byte-unchanged behaviour, pinned for the first time |
| **new**: `>>>`/`<<<` — value-left, arrow-left, mixed with `.`, associativity | 5 | |
| **new**: lambdas — one binder, two binders, annotated, function-typed binder, refused at four runtime positions | 8 | |
| **new**: `let` — first-order, higher-order, refused in a statement, refused mentioning a runtime binding, refused as a duplicate name, in a library (dotted) | 6 | |
| **new**: partial application — accepted as an operand and as an argument; refused at a binder, a statement, a body final, a subject, a hole | 7 | |
| **new**: saturation and over-application (§3.3's ambiguity and its refusal) | 3 | |
| **new**: types — defaulted binder, annotated arrow, function-typed `function` parameter refused, function-typed result refused, `flag`/`receipt` still refused | 6 | |
| **new**: `ret`/`pure`/`return` diagnoses | 3 | §3.9 |
| **new**: sections refused (three spellings) | 3 | §3.7 |
| **new**: the fuel — a program that exceeds `maxNormSteps`, refused with its count | 1 | |
| **new**: substitution sharing (§5.5) — the two bills, executed | 2 | |
| **new**: prompt literality — one prompt containing `. $ \ >>> !`, against the string spelling | 1 | `decide`, at `DslSmoke:1016`'s instrument |
| **new**: `\` and `>>>` inside a fenced block, byte for byte | 2 | |
| **new**: trace order through a composition (`(f . g) x` gives g then f) | 1 | via `codesOf`/`promptAt`, as at section 9g |
| unchanged | ~163 | including all eight `known here` cases, byte for byte |

Net: roughly **−18 / +96 cases** against today, ~23 edited, and no position churn
given round 17's in-place fixture edit (`answer x` → `x`, same line, same
column).

**Pins outside the battery:** `DslSmoke`'s file-reading section (`:1236–1250`)
still expects `"ok"` from both files of the pair; `CliSmoke:229` still prints
"house style guide" (the priming's words are unchanged); `CliSmoke:113`'s
`expectedApply = 7` and `:123`'s `expectedRefuse = 6` are about `harden.wf` and
are untouched; `CliSmoke:254`'s `example/ill-typed.wf:11:18:` holds **only**
because of round-17 §8.3's appended act, which carries.

**The estimate. This is a parser rewrite, and the number should be read as one.**

| Piece | Estimate |
|---|---|
| `Norm.lean`: `SType`/`SExpr`, synthesis, `normalize` with fuel, the hoister, two soundness lemmas | **3 days** |
| `Parse.lean`: the expression parser (atoms, application with the three bounds, four operators with fixity), `parseType`, `parseLambda`, the `let` header, `PEnv.lets`, five lexer changes, D19's `fenceCloses` repair | **2½ days** |
| `Check.lean`: the `knownHere` filter, `isTemp`/`showName` at seven sites, three rewordings | **2 hours** |
| battery: ~96 new cases, in-place fixture edits, whole-diagnosis matching | **2 days** |
| examples (the pair, `ill-typed.wf`) and docs (`GRAMMAR.md` round-18 note and grammar block, `doc/dsl-guide.html`, `ROUNDS.md`, `block-syntax.md`'s one line) | **1 day** |
| re-elaboration risk | **near zero** — `Dsl.lean`, `Explain.lean` and `DslFlagship.lean` are not edited; the ~107 s module and the nine kernel proofs are not recompiled for content |
| **credit**: round 17's bang, never written | **−1½ days** |

**Total: eight to nine focused days**, against round 17's three for the core
alone. The risk is concentrated in two files, one of them new, and the new one
is where every genuinely novel algorithm lives — which is the shape you want,
because `Norm.lean` can be tested against `Raw` equality with `decide` before a
single diagnosis is written.

**The reopening condition, stated in advance.** If `Raw` has to move — if some
normal form turns out not to be expressible in today's syntax — the honest
response is to **reopen C4 before writing the parser**, not to patch around it.
The one candidate is a `let` whose normal form is a first-order lambda that would
benefit from `FnEntry` promotion (§2.3), and that is an optimization, not an
expressiveness gap. If a second candidate appears, this page is wrong and should
be said to be wrong.

---

## 11. What round 18 does not do

* **It does not give the language an expression language over answers.** The
  four operators are all composition; none is a function of a `text`. Rule 3's
  revised form (§7.3) is the claim, and it is the claim a reviewer should attack
  first.
* **It does not create runtime closures.** Function types never reach `Code`, so
  they never reach `Env`, so `Plan.dyn` stays quarantined and no surface syntax
  reaches it. §1.1 and §2.2(c) are the two places that could have gone wrong and
  did not.
* **It does not add recursion.** Stratification refuses it, and stratification is
  also what makes normalization terminate — one rule, two jobs, as round 16
  already noted for arity-directed parsing.
* **It does not raise the rung.** Every hoisted step is a `.bind`; every inlined
  `let` is statements the caller's own lemma covers; `parseAndCheck_level_le`
  bounds every accepted program at branch by the same proof.
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

## 12. Questions for the owner

**Q1 — the `>>>` overload (C10).** The owner's directive 1 writes `f x >>> g`, a
value on the left; Haskell's `>>>` composes arrows and its value-left cousin is
`>>=` or `&`. Round 18 gives `>>>`/`<<<` both rules, disjoint by the operand's
type, and shows the two associations agree (§5.2). *Recommendation: take it* —
it makes the owner's own example legal, it is coherent, and one spelling for
"flow" is less to learn than two. *The alternative*, recorded: arrows-only, with
`f x >>> g` refused in favour of `g $ f x` — Haskell-exact, and it refuses a
sentence the owner wrote.

**Q2 — the stratum split (C5).** `function` runtime and first-order; `let` static
and higher-order. The alternative that keeps one keyword is to let `function`
take function-typed parameters and become a template silently, which makes "does
this have a rung?" an invisible property of its signature. *Recommendation: take
the split.* But it is two declaration forms in a language with a tight keyword
budget, so it should be chosen rather than derived.

**Q3 — higher-order functions at all, this round (C5 versus option (b)).** If the
campaign must be cut, option (b) — refuse function-typed parameters, keep
lambdas, composition, pipelines and partial application — removes about two days
and invalidates no other decision on this page. *Recommendation: keep them*, on
the strength of directive 3's "the whole deal"; *but* the cut is clean and the
owner should know it exists before the campaign starts rather than after.
