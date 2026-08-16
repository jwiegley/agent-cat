# Round seventeen: the do-notation reading, bang lifting, and the noise audit

*Design of record CANDIDATE for round seventeen, 2026-08-15. Written against
`GRAMMAR.md` (the design of record, rounds 10–16), `doc/dsl-guide.html`,
`example/{library,harden-imported,harden,hello,ill-typed}.wf`, and the
implementation in `Agentic/Core/Dsl/{Syntax,Parse,Check}.lean` +
`Agentic/Core/Dsl.lean`. This file supersedes `expr-design-draft.md`, which was
written before the adversarial pass; every finding of that pass is applied here.
Where this file and `GRAMMAR.md` disagree, `GRAMMAR.md` is still the record
until this one is approved.*

---

## 0. The claim, in one paragraph

The blocks this language already writes **are** do-blocks over `Plan`. Once
that is said out loud, three pieces of syntax stop being constructs and become
consequences: `answer x` is the right identity of the monad and is deleted; a
statement-position `ask` is a do-step whose binder was elided, so the "act" is
derived rather than special; and the last statement of a block is its result,
which at `receipt` (= `Unit`) makes the act-versus-answer question disappear
definitionally rather than by rule. On top of that reading, one new piece of
syntax — Idris's bang, `!(source)`, written **only where a name may be
written** — removes the one-use binder, and reverses round 16's "a call is not
an argument" (parentheses are what make it safe). Round 17 also takes the
owner's parameter-annotation elision: a parameter is `text` unless it says
otherwise.

The whole of round 17 is implementable as a **lifting pass inside the
parser**. `Raw` does not change, `Check` changes in two clauses and seven
messages, and **not one level lemma or kernel proof restates**. That is the
headline argument, and §7 defends it clause by clause against the proof
scripts rather than against the docstrings.

Two things the draft got wrong and this page fixes before anything else: the
grammar as drafted did not derive the pinned flagship (§6), and the one worked
example of the whole feature did not lex (§2.5). Both are repaired here, and
each repair carries its own battery pin.

### Decisions taken in this document

| # | Question | Decision |
|---|---|---|
| D1 | `answer` | **Deleted.** The last statement of a body is its answer. One migration diagnosis ships for a release (D20). |
| D2 | Desugar level | **Parser-level**, into today's `Raw`; the leaks are named and closed in §2.4. |
| D3 | Where `!` may stand | **Exactly where a name may stand, outside prompt text**: call arguments (any depth), `if` subject, verdict-`case` subject. |
| D4 | `!x` on a bare name | **Refused** — a name is already a value; `!` would read as "ask again", which is `independent draw`. |
| D5 | `!(…)` as a whole statement / whole right-hand side / whole final expression | **Refused** — the bang must be a proper subterm; there is one spelling for one thing. |
| D6 | `!` inside prompt text or a `{hole}` | **Refused.** `!` is prose inside a prompt, and prompts are byte-literal. §2.6 presents the alternative honestly. |
| D7 | `!` as a panel member | **Refused** — a panel's members are questions; the monoid and the cost model are stated over questions. Diagnosis written in §2.1. |
| D8 | `!` as a `revising` subject | **Refused** on taste (the loop is *about* a value the reader can name), with a technical bonus: it is the one name position whose grounding could fail. |
| D9 | `$label` fences inside a bang | **Refused** — a labelled block follows a call written as a statement; lift short calls, bind long ones. |
| D10 | Temporary names | `!` + the bang's own `line:col`, **minted already-qualified, once, at the lifter**, and routed around `PEnv.q`/`qualRefs`. `Dsl.isTemp` is defined beside the minting code. |
| D11 | Evaluation order | **Post-order**: a bang's own bangs are lifted before it, and siblings in source order. Never across a `{`. |
| D12 | Sharing | Two identical bangs are two binders and **one answer**. One of the two divergences from Idris (§5.3). |
| D13 | Function declaration syntax | **No change.** Recommended against, not churned (§3.9). |
| D14 | `amend <carrier>`, `as <carrier>`, `stop`, `known here` | **All kept**, each for a reason tied to the owner's own history (§3). |
| D15 | `!` inside a `revising` clause (the review source, the `amend` source, or any argument of a call standing in either) | **Refused.** A clause is one question asked once per round, not a do-block: there is no lifting site, and lifting out of the loop would change what is asked (§2.1). |
| D16 | Parameter annotations | **`param ::= name [":" kind]`, defaulting to `text`.** Only a `verdict` parameter annotates; `flag` and `receipt` parameters stay refused. The result arrow stays explicit (§3.13). |
| D17 | `-> receipt` bodies | **Do not lift.** The terminal stays `.act`/`.callS` with `answer := none`: same plan, same `Raw`, byte-identical (§1.3). |
| D18 | A trailing **binding** | **Refused** in a workflow block, in an arm, and in a body — and **not** in a library's priming, which has no final position (§1.4). The block/arm half is an owner question (§9, Q1). |
| D19 | The fence-close drift | **Fixed as part of round 17**: a closing fence may be followed by `)` and by a `--` comment, as `block-syntax.md` rule 2 already specifies. A second lexer change, with its own pin (§2.5). |
| D20 | The `answer` migration | `parseFnBody` keeps one clause at the word: *"`answer` is deleted: the last statement of a body is its answer — drop this line."* Staged for one release (§9, Q3 asks how long). |
| D21 | The every-feature showcase | **`library.wf` + `harden-imported.wf`.** `example/harden.wf` stays byte-identical, because it is the kernel pin (§8.2). |

---

## 1. The do-notation reading, made official

### 1.1 The rule

> **A block is a do-block over `Plan`.** Its statements are steps; the last
> step is the block's result; a step written without `x <-` is asked at the
> kind its position imposes; and a step's kind is fixed by its position.

Three spellings, one construct:

```
x <- source        -- a step whose answer is named
source             -- a step whose binder is elided (today's "act")
source             -- …and in final position, the block's result
```

That the same text means "elided binder" in the middle and "result" at the end
is not an ambiguity to be resolved by a keyword. It is this language's oldest
stated principle — *there are no reserved words: positions decide* — applied to
the one place it had not yet been applied. Haskell and Idris both settle it
exactly this way, and neither needs a word for it.

**The elided binder is not a discard, and the difference is a refusal.** The
draft said "a step written without `x <-` binds nothing and its answer is
discarded", and the implementation says something stronger, which round 17
keeps and now defends on the page:

> A step written without `x <-` is asked at `receipt`, the kind its position
> imposes (`bindForm fns Code.ack`, `Check.lean:564–566`). A step that can only
> answer something else — a call to a value function — is **refused**:
> ``…`{f}` answers `text`, and its answer has nowhere to go: bind it,
> `x <- {f} …` `` (`Check.lean:566`, and the body-side twin at
> `Check.lean:816`). Haskell warns on a discarded non-unit; here it is a
> refusal, because an answer that cost a question is not something this
> language will let you throw away silently.

So the do-reading does *not* import Haskell's `-Wunused-do-bind` culture. It
imports the notation and keeps the stricter rule, and the guide should say why
in one sentence rather than leaving a reader to discover it at the diagnosis.

**A priming is not a block.** A library's top-level statements are a *prefix*,
not a block: `parsePrimer` recurses to `[]` (`Parse.lean:978–1020`), there is
no terminator, and a priming's last statement is followed by the importer's
first. So:

> A priming has no final position. The do-rule is a rule about blocks and
> bodies, and a library's last binding is the importer's first name.

This is not a nicety. `example/library.wf` and the `libOk` fixture behind all
eleven module cases (`test/DslSmoke.lean:88–91`) both end in `guide : text <-
ask tool "cat" …`; applying D18 literally to a priming would delete the one
construct round 16 landed libraries for.

### 1.2 Value function bodies

`answer` is deleted. A value function's body is steps followed by a **final
expression**:

```
function drafted (guide, goal, shape) -> text {
  ask model "author" served by "deep" ```
      {guide}
      Draft a patch satisfying:
      {goal}
      {shape}
      Reply with a unified diff only.
  ```
}
```

The elaborated term is **literally the same term** as today's
`d <- ask …  answer d`, and that is not a claim about a normal form, it is a
claim about the constructor: today the pair elaborates to
`bindForm .text S (.ask a)` applied to `Plan.ret (Expr.var .here)`, which
unfolds to `Plan.askC .text q (.ret (Expr.var .here))`; and
`Plan.askC1 c q` is *defined* as `.askC c q (.ret (Expr.var .here))`
(`Agentic/Core/Plan.lean:469`). One is the other, by `rfl`. The owner's round-17
point 1 is therefore not an aesthetic preference; it is an equation the code
already satisfies.

A **final binding is refused** (D18), with the fix in the diagnosis:

```
the last statement of a body is its answer, and a binding is not one:
drop the `x <-`
```

The refusal is total (nothing downstream can ever use a name introduced by the
last statement), so "drop the binder" is always the correct fix, and the
diagnosis can say so without hedging.

**Kinds: what the final expression is checked against.** The draft said
"imposed, never inferred", and that is only half true, so it is corrected here.
`checkBody`'s `.bind` clause routes a `.call` rhs to `ann.getD fe.result` and a
`.panel` rhs to `ann.getD Code.verdict` (`Check.lean:775–789`); only a `.ask`
reaches `bodyBindKind`. So:

* a final **ask** takes the declared result, imposed, through
  `bodyBindKind`'s `answer` clause (`Check.lean:754–757`);
* a final **call** or **panel** takes the *source's* kind and is then
  **checked against** the declared result at `checkFn`'s terminal
  (`Check.lean:826–834`).

`-> flag` bodies therefore work without an annotation — and they work for the
same reason they work today: the lift names the final expression, and
`bodyBindKind`'s `answer` clause grounds that name at the declared result.
Round 17 changes what the author writes, not what grounds it.
`test/DslSmoke.lean:553–554`'s `-> flag` fixture is grounded identically before
and after.

**The parser cannot know the callee's result kind, and does not need to.**
`PEnv` carries `fnAr : List (String × Nat)` — arities, not result kinds
(`Parse.lean:496`). So for

```
function f (a) -> text { applied a }        -- applied : … -> receipt
```

the parser lifts unconditionally (it knows only the *declared* result of the
function it is parsing, which is enough for D17), and the checker produces the
diagnosis. `checkFn`'s terminal is therefore reworded do-style, without the
deleted keyword and without quoting a temporary:

```
the last statement of `f` answers `receipt`, but `f` answers `text`
```

That is the same site as today's ``` `answer v`: `v` answers `text`, but `f`
answers `verdict` ``` (`Check.lean:845` is the sibling refusal; the terminal
message is at `Check.lean:832`), so `test/DslSmoke.lean:679–681`'s pinned
position `3:3` is preserved by the fixture rewrite in §8.5 and only the message
text changes.

### 1.3 `-> receipt` bodies: the equation, and why the parser still does nothing

Today the parser carries two ad-hoc rules that exist only to decide whether a
body's last act is a step or an answer: *"a value function ends with
`answer <name>`"* (`Parse.lean:1034`) and *"a `-> receipt` function's body just
ends: the end of the block is the answer, and there is nothing to name"*
(`Parse.lean:1038`). Both are consequences of an unstated do-rule, and both go
away when it is stated.

The equation, split in two, because the draft presented one equation for two
jobs and made the stronger of them look decorative.

**At a `Unit` block the equation is idle, and that is the argument for not
touching the parser.** Nothing produces the second term: the parser emits
`.act a (.empty opos)`, `checkBlock` builds
`bindForm .ack … (Plan.sub (Plan.ret (fun _ => ())) Sub.wk)`, and `askPlan .ack`
is never reached from a block. `El .ack = Unit` and Lean's definitional eta for
structures give `Env.head δ ≡ ()`, so the two continuations *would* be
definitionally equal if both were built — but only one ever is. The honest
statement is therefore: **at `Unit`, the do-reading is a change to the story and
to two refusals, and to nothing else.** That is what protects the flagship
(§7.5).

**At a value body the equation is load-bearing, and it is what makes `answer`
deletable.** The lifted `!L:C <- ask …` plus the terminal
`Plan.ret (b.at? result)` reduces to `Plan.askC c q (Plan.ret (Expr.var .here))`,
which *is* `Plan.askC1 c q` (`Plan.lean:469`). That `rfl` is D1's licence.

**D17: a `-> receipt` body does not lift.** For `result = .ack` the parser
emits the last statement as a statement — `.act` / `.callS` / a binding —
with `answer := none`, exactly as today. Two reasons, and the second is the
decisive one:

1. **It keeps the `Raw` byte-identical.** Under an unconditional lift,
   `library.wf`'s `applied` would end `.bind t none (.ask a)` with
   `answer := some "!L:C"` instead of `.act`. The *plans* are definitionally
   equal and `bodyAsks` is unaffected (a `.bind` with an ask rhs prices
   `rhsAsks = 1`, exactly as `.act` prices 1) — so nothing observable changes,
   but "the elaborated table is identical" would be false of the
   representation. Not lifting makes §1.3's "there is nothing to decide" true
   of the representation as well as of the term.
2. **An unconditional lift breaks a receipt body whose last statement is a
   call.** `… library.applied patch` would be lifted to `.bind t none (.call …)`,
   and `checkBody` routes that through `ann.getD fe.result` = `.ack`, binding a
   name nothing can consume — for no gain whatever, since `answer := none` was
   already the right answer.

The cost of D17 is one clause in `parseFnBody`, keyed on a fact the parser
already has in hand (`result : Code` is its own argument). Add one battery case:
a `-> receipt` body ending in a statement call.

`example/library.wf`'s `applied` is therefore unchanged by round 17 in every
sense — surface, `Raw`, and plan.

### 1.4 The workflow block

`workflow { … }` is a do-block at `Plan [] Unit`. **Nothing changes
observably**, and §1.3's first half is the reason: every statement form's
elided-binder result is `Unit`, the block's result is `Unit`, and a trailing
act already elaborates to the term that "the act is the result" would produce.
The pinned flagship (`example/harden.wf` → `flagshipRaw` → nine `decide +kernel`
proofs) is untouched, byte for byte, subject to the emission obligation in
§7.5.

One behavior does change: a **trailing binding in a workflow block** is refused
(D18), with the same message as §1.2. Today such a binding is accepted when
annotated (`x : text <- ask …` as the last statement), binds a name nothing can
consume, and asks a question whose answer is thrown away silently.

**Scope, exactly.** The refusal fires in `parseBlockFrom` (workflow blocks and
arms) and in `parseFnBody`. It does **not** fire in `parsePrimer` — see §1.1.
Pin it with a battery case: a library whose priming ends with an annotated
binding still parses, still checks, and the importer can still name the binding.

**This one is put to the owner rather than derived** (§9, Q1). The draft
justified it by citing `GRAMMAR.md:26–28`'s round-11 note ("a *bound* ask may
still be annotated `: receipt`, which binds a name nothing can consume — a
refusal to add"), and that line is about the *sibling* case, not this one. The
do-rule gives the two refusals one wording; that is a reason to spell them
alike, not by itself a reason to add one. For bodies the refusal is settled
(nothing downstream exists at all). For blocks and arms it removes an accepted
shape.

### 1.5 `if` / `case` arms

Arms become last-statement-is-result too. **Today that changes nothing**: arms
are blocks at `Unit`, since `Plan.case` demands one type across arms and arms
export no bindings (rule 7). So an arm's last statement is an act, a call, a
nested branching, or `stop`, exactly as now, and `stop` is `pure ()` in final
position rather than a special empty block.

What it means *before branch-values exist* is worth stating, because it is why
the reading was chosen: when the day comes that a branching may carry a value,
the rule needs **no new syntax and no new keyword**. It reads "each arm's last
statement is its value; all arms at one kind", the checker imposes that kind on
each arm's terminal exactly as §4 imposes kinds everywhere else, and `Plan.case`
already has the type. The sugar is forward-compatible with the one extension
the surface is most likely to want.

**The assertion nit, demoted to a question.** The draft proposed that
assertions be transparent to the rule, so a block whose last step is a
`known here:` would have to end with `stop`. That is a behavior change, not a
nit: `parseBlockFrom`'s `knownHere` clause recurses with `first := false`
(`Parse.lean:880–889`), so `known here: x }` is accepted today and elaborates to
`ret`, and `test/DslSmoke.lean:511–513` pins exactly that shape as `"ok"`. It is
put to the owner as Q2 (§9) with its churn priced, not taken here. If it is
taken, the diagnosis is *"a `known here` asserts and does nothing; a block that
does nothing says `stop`"*, and the fixture becomes
`if ok { known here: ok  stop } else { stop }` with a new refusal case beside
it.

---

## 2. Bang notation, exactly

### 2.1 The rule

```
bang ::= "!" "(" source' ")"        source' ::= ask | panel | call
```

> **`!(…)` stands wherever a name may stand, outside prompt text.**

That is the whole rule, and it is why the notation costs the reader nothing:
the three name positions the language already has (round 16 added the third)
are the three bang positions.

| Position | Name today | Bang legal? |
|---|---|---|
| call argument, any depth | `f x` | **yes** |
| `if` subject | `if x` | **yes** |
| verdict `case` subject | `case x { approved … }` | **yes** |
| `{x}` in prompt text | `{x}` | no (D6, §2.6) |
| panel member | — (members are `ask`s) | no (D7) |
| `revising` subject | `revising x as c` | no (D8) |
| a `revising` **clause** (review source, `amend` source, or an argument of a call in either) | `v <- …`, `amend c { … }` | no (**D15**) |
| `case x { settled … }` subject | a pending loop result | no — a bang cannot produce one |

**D15, the refusal the draft did not have.** A bang inside a `revising` clause
is neither permitted nor refused by the draft, and it *cannot* be permitted at
parser level. `RawSource.revising subj carrier n rname rann review amend pos`
carries the review and the amend as single `RawRhs` slots
(`Syntax.lean:239–241`, `Parse.lean:834,844`), and `RawRhs` is `ask | panel |
call` with no bind: there is no statement list inside a loop, so there is
nowhere to put a lifted binder. The only enclosing statement is the
`x <- revising …` binding itself, and lifting there is not merely ugly, it is
**wrong** — the question would be asked once, before the loop, instead of once
per round, and `blockAsks`'s `(n+1)·review + n·amend` recurrence would price a
question that is no longer inside the loop it prices. The diagnosis says so:

```
a bounded revision's clauses are asked once per round; a question written
here would have to be lifted out of the loop, where it would be asked once
and could not see the carrier — write it as the clause itself, or bind it
above the loop
```

Implement it by threading a "no lifting site here" flag into the clause
parsers; two battery refusal cases, one for the review source and one for the
`amend` source.

And two "the bang is doing nothing" refusals, which are one rule:
**a bang must be a proper subterm of its statement.**

* `!x` on a bare name — refused: *"a name is already an answer; drop the `!`
  (a fresh opinion is `independent draw n`)"*. This refusal is load-bearing,
  not tidiness: in Idris `!` marks an action, so `!x` reads as "run it again",
  and running it again is exactly what this language will not do silently
  (§5.3).
* `x <- !(ask q)`, `!(ask q)` as a whole statement, `!(ask q)` as a final
  expression — refused: *"the statement is already the question; drop the
  `!`"*. One spelling for one thing.

**Three diagnoses the draft left to fall out of existing "expected …"
messages, written out here.** The draft's line — "there it falls out of the
existing diagnoses and needs no new wording" — is fine for a parameter list. It
is not fine for the two positions an author will actually try, nor for the
mistake the feature itself creates.

* **A bang as a panel member** reaches `parseAsk`'s `expectKw "ask"`
  (`Parse.lean:604`) and would say only *"expected `ask` at `!`"*. Write it:
  *"a panel's members are questions, and a panel of k members costs k questions
  in every world; bind the answer above and pass its name."*
* **A bang in a define** reaches `expectStr` in the define header
  (`Parse.lean:1177`) and would say only *"expected a string literal or a text
  block at `!`"*. Write it: *"a define is literal text, expanded at parse time —
  there is nothing here to ask; `!` inside the words is prose."* Note in the
  same place that `define x = "… !(ask q) …"` is *literal*, by D6, and that this
  is the right behavior rather than an oversight.
* **`f (ask q)`** — a bare parenthesis where the author meant a bang — is the
  mistake round 17 creates, and today it hits `parseArgTokens`'s catch-all,
  *"this is not an argument (a name, words, or a `$label`)"* (`Parse.lean:701`),
  a sentence that has just stopped being true. Key a message on a leading `(`
  in argument position: *"a question in an argument is written `!(ask …)`; a
  bare parenthesis is not a group."* One clause, one battery case, and the
  round's most likely new mistake becomes its clearest refusal.

A bang **outside any statement** is unreachable by construction: every block
and body is a list of statements, so every expression sits inside one. In the
header positions where an expression cannot appear at all (a parameter list, an
`import`), the existing "expected …" diagnoses are adequate and need no new
wording.

### 2.2 Desugaring

For a statement `S` containing bangs `b₁ … bₖ` enumerated in **post-order**:

```
⟦S⟧  =  t₁ <- s₁
        t₂ <- s₂
        …
        tₖ <- sₖ
        S[bᵢ := tᵢ]
```

where `sᵢ` is `bᵢ`'s parenthesized source and `tᵢ` is a fresh binder.

> **The traversal (D11).** A bang's own bangs are lifted before it; siblings
> are lifted in source order.

The draft said "left to right, innermost first", which is two sort keys, not
one order, and §5.1 makes the ambiguity observable in a transcript. The example
that fixes it — neither of the draft's two examples disambiguates, because both
are single-branch:

```
f !(judged !(A) r) !(B)
```

* **Post-order** (the decision): `A`, `judged`, `B`.
* Depth-first-by-depth ("all innermost, then left to right"): `A`, `B`,
  `judged`.

Two different traces and two different prompts if `B` mentions nothing and
`judged` does. Post-order, stated once as a traversal, decides it. Add this
example to the battery as a trace-order case; the machinery exists —
`DslSmoke`'s `codesOf`/`promptAt` at section 9g already pin event order.

Worked, from the owner's directive:

```
verdict <- judged !(drafted g a) r
```
```
!17:19 <- drafted g a
verdict <- judged !17:19 r
```

and doubly nested, `!(judged !(drafted g a) r)` in an argument position of `h`:

```
!17:24 <- drafted g a
!17:15 <- judged !17:24 r
h !17:15
```

**Post-order is more than a convention: it is an inference precondition.** In
the doubly-nested lift, the inner temporary's only use sits in the *next lifted
bind's* rhs, and `useKindB`'s `.bind` clause reaches it through
`firstOf (useKindS sig x src) …` (`Check.lean:246–261`). Reversing the order
would put the use before the binding, and the ground-free refusal would fire on
a name the author never wrote. That is the sharpest one-line defence of D11
available, and it is why "innermost first is forced" understates the case.

**Lifting never crosses a `{`.** "The nearest enclosing do-statement" is a
statement *of the same block*, so a bang inside an arm lifts to the head of the
statement inside that arm, and its question is asked only on that path. The
per-branch cost tree keeps its shape; `blockAsks`'s branching clauses
(`Check.lean:888`) need no change. A bang in an `if` subject, by contrast,
lifts *before* the `if` and is asked once on every path — which is the right
reading of `if !(ask person "owner" "…")`. This is also the second divergence
from Idris (§5.3).

### 2.3 The desugar level: parser, and why

**Decision: parser-level, emitting today's `Raw`.** The argument, in the order
it convinced me:

1. **`Raw` does not change, and no theorem mentions the parser.** See §7.2 for
   the corrected form of this argument: survival follows from the fact that no
   theorem in `Dsl.lean`, `Check.lean` or `Explain.lean` *inspects* the
   parser's output, not from an image claim about a `desugar` function that
   does not exist in Lean. On a module that costs ~107 s to elaborate and whose
   flagship results are kernel computations, that is a saving of risk, not of
   effort.
2. **The temporary's kind is already inferred, correctly, by the machinery
   that exists.** A lifted binder is emitted with `ann = none`. Its *only* use
   is the position it was lifted from, which is the immediately following
   statement, and every legal bang position is a **ground site** for
   `useKindB`: a call argument grounds at the parameter's kind (`useArgs`, via
   `fnSigsOf`), an `if` subject grounds at `flag`, a `case` subject at
   `verdict`. So `bindKind` (`Check.lean:265`) resolves every temporary, always,
   on its first and only use. Nothing new is computed.
3. **The parser cannot annotate even if it wanted to.** `PEnv` carries function
   *arities*, not parameter kinds (`Parse.lean:496`). Relying on inference is
   not a shortcut around a missing annotation; it is the only route, and (2)
   says it is a total one.

Two recorded conditions under which D2 would need revisiting, both of which
would force `PEnv` to carry parameter kinds: **(i)** a bang position that is not
a ground site, and **(ii)** any move away from arity-directed parsing. See §4.2
for why (ii) is load-bearing.

The alternative — **checker-level, graft-based**, like today's panel and call
binds — was seriously considered, and it does buy one real thing: `Bindings`
never carries a name no source can write, because the argument's expression
could be handed to `argExpr` directly as `Expr.var .here` instead of being
looked up by name. Its costs, priced properly:

* `RawArg` gains a `.bang (r : RawRhs)` constructor and `RawBlock`/`RawBodyStmt`
  gain bang-carrying shapes ⇒ **`Raw` changes** ⇒ derived `DecidableEq`/`Repr`
  change ⇒ all nine kernel proofs recompute (they would still pass; the point
  is that they must be re-run and re-timed, and the flagship pin re-baselined,
  for a feature the flagship does not use).
* `checkArgs`/`argExpr` become effect-collecting: arguments can no longer be
  elaborated into a `Sub` in one left fold, because each may prepend a `graft`.
  The calling convention (`Sub Γf Δ` *is* the argument list — the sentence the
  round-16 design rests on) stops being a fold and becomes a fold plus a
  continuation stack.
* **The death list, which the draft omitted.** Seven level lemmas whose
  inductions step through `RawArg`/`checkArgs` restate, and two `rfl` theorems
  die outright: `checkArgs_too_few` (`Check.lean:388`) and `checkArgs_too_many`
  (`Check.lean:395`) are `rfl`s about a function that would no longer have that
  shape. `bindForm_level_le` still covers each lifted bind, so the *new* proof
  burden is modest — but the restatement burden is not, and it is paid on the
  load-bearing type.

Weighing: the checker-level route pays a change to the load-bearing type, the
calling convention, and nine kernel recomputations, to avoid leaks that §2.4
closes in one clause and one helper. Parser-level, and close the leaks.

### 2.4 Temporaries: minting, spelling, and the seven quoting sites

**D10, corrected: mint the temporary already-qualified, once, at the lifter.**
The draft said "module-qualified in a library" and left the qualification to the
existing paths, and those paths disagree. In a priming `qualRefs` is true:
`parsePrimer` binds `env.q w` (`Parse.lean:1017`) while `parseArgTokens` emits
`.name (if env.qualRefs then full else x)` (`Parse.lean:693`). A lifted
temporary is written twice — once at the bind, once at the use — and if only
one of the two passes through `PEnv.q` the two strings differ and the name does
not resolve. So:

> A name written by the lifter is final: it is minted already-qualified and
> routed around `PEnv.q`/`qualRefs` entirely, at both the bind and the use.

Battery case: a library priming containing a bang, imported and run, whose
trace equals the hand-bound spelling's.

**`Dsl.isTemp`, defined beside the minting code:**

```lean
def isTemp (x : String) : Bool := x.any (· == '!')
```

It is total and it cannot misfire: identifier characters are
`isIdentStart = isAlpha || '_'` and `isIdentCont = isAlpha || isDigit || '_'`
(`Parse.lean:98–100`), plus at most one dot from qualification, so no source
name contains `!`.

**Leak 1: unspellable temporaries must not reach `known here`.**
`checkBlock`'s `knownHere` clause (`Check.lean:534`) compares the asserted list
against `S.map (·.name)`. A temporary lifted before an earlier statement is
still in `S`, so `known here: library.guide` would be refused against a live
list containing `!12:20`.

*Close it:* the live list is the list of names **the author can write**.

```lean
let live := (S.map (·.name)).filter (fun n => !Dsl.isTemp n)
```

One line, one clause, no level lemma touched (the `knownHere` clause only
recurses; see §7.4 for the check against `checkBlock_level_le`'s proof script).
And it is the honest statement of what the assertion asserts: a temporary is not
a name, it is a position.

**It is the identity on every program that exists today.** On bang-free source
the filter removes nothing, so all eight `known here` battery cases
(`DslSmoke:395, 416, 419, 422, 425, 428, 494, 497`) are byte-unchanged,
including the failure message that prints `live`. That is the cheapest possible
evidence the clause is safe, and it is what lets §8.6 keep those eight cases in
the "unchanged" column honestly. The filter is also correct at the arm and
splice boundaries: temporaries lifted inside an arm are live only within that
arm, and a library's temporaries are module-qualified yet still contain `!`, so
they filter after the splice too.

**Leak 2: diagnoses must not quote `!12:20`.** A kind clash on a lifted
argument would today read ``…`judged`'s parameter `patch` takes `text`, and
`!12:20` answers `verdict` ``.

*Close it:* one helper in `Check.lean`, used at **seven** sites — the draft said
five, and enumerating them is the point, since a string convention applied at
two of seven is not a mitigation:

```lean
def showName (x : String) : String :=
  if Dsl.isTemp x then "the lifted `!(…)`" else s!"`{x}`"
```

| # | Site | File:line | Note |
|---|---|---|---|
| 1 | `argExpr`, kind clash | `Check.lean:360` | the common case |
| 2 | `argExpr`, unknown name | `Check.lean` (same clause family) | |
| 3 | `chunkExpr`, non-text hole | `Check.lean:141` | unreachable for temporaries by D6, kept for uniformity |
| 4 | `ifFlag` | `Check.lean` | subject at `flag` |
| 5 | `caseVerdict` | `Check.lean` | subject at `verdict` |
| 6 | `checkFn`'s terminal | `Check.lean:832` | **the most likely site of all** — under D2 the terminal name is routinely the lifted temporary. Reworded per §1.2, without `answer` and without quoting the temporary. |
| 7 | `bodyBindKind`'s ground-free refusal | `Check.lean:760` | prints the name *and* names "the `answer`"; the hint becomes "(a hole, an argument, the final expression)" |

Two further sites are *checked and deliberately excluded*: `freshName`'s
collision message (`Check.lean:114`) and `parseFnBody`'s catch-all
(`Parse.lean:1065`) cannot see a temporary — the first because the lifter never
mints a colliding name (two bangs cannot begin at one line and column), the
second because it fires before any lift. Record them as checked rather than
leaving a reader to wonder.

**`showName` must not be applied at the five message sites a theorem quotes**:
`check_panel_nil` (`Check.lean:717`), `checkArgs_too_few` (`Check.lean:388`),
`checkArgs_too_many` (`Check.lean:395`), `checkProgram_overRevised`
(`Dsl.lean:694`), `checkProgram_oversized` (`Dsl.lean:706`). Those quote
function names and numerals, never binders, so the exclusion costs nothing —
but it is a rule, because rewording any of them requires a theorem
restatement.

The position in the `CheckError` is already the bang's own position (the parser
writes the bang's `Pos` into the emitted `RawArg.name`), so the reader is
pointed at the `!` and told which parameter rejected it. Seven message sites,
seven battery cases — the draft budgeted two.

**Not a leak, worth recording, each with the line that proves it:**

* Temporaries cannot reach `agent-cat plan`: `Plan` has no names at all — it is
  de Bruijn.
* They cannot reach a prompt: `!` is not an identifier character
  (`Parse.lean:98–100`), and the same two predicates guard hole scanning
  (`Parse.lean:124–135`), so `{!12:20}` is unscannable as a hole.
* They cannot collide with a user name: `!` never was an identifier character,
  so adding it to `punctChars` cannot split an existing name, and today it
  falls through to "unexpected character" (`Parse.lean:403`) — no existing
  source text changes meaning.
* They cannot collide with each other: two bangs cannot begin at the same line
  and column, and in a library they are minted qualified (D10).

### 2.5 What this costs the lexer: two changes, not one

**Change 1.** `'!'` joins `punctChars` (`Parse.lean:102`). Safe for the reason
just given, and safe inside prompts because prompt text is scanned as a single
token — see §2.6.

**Change 2 (D19), which the draft missed and on which every fenced bang example
depends.** `fenceCloses` (`Parse.lean:210–219`) closes a fence only when the
backtick run is followed by whitespace and, optionally, one of `,` `]` `}`.
Every bang whose inner source ends in a fenced block puts a `)` there:

```
if !(ask person "owner" ```
    Apply this patch?
    {patch}
    {library.flagSpec}
```) { library.applied patch } else { stop }
```

The line ```` ```) ```` is **not** a close under today's implementation, so the
rest of the file is swallowed as content and the diagnosis is "this fence of 3
backticks is never closed" at the opening fence — i.e. the one worked win of the
whole feature does not lex.

This is not a new requirement invented by round 17. It is **drift**:
`block-syntax.md` rule 2 (lines 14–20) already specifies "exactly N backticks
followed by nothing but whitespace and, optionally, one of `,` `]` `}` `)` and a
comment — lexing resumes at that punctuation." The implementation dropped `)`
and the comment. The repair restores the spec:

```lean
match restWs with
| [] => some rest
| c :: _ =>
  if c == ',' || c == ']' || c == '}' || c == ')' then some rest
  else if isCommentStart restWs then some rest
  else none
```

Nested closes work without further care: `fenceCloses` returns the characters
*at* the punctuation and lexing resumes there, so ```` ```)) ```` closes the
fence and then lexes two parens — which the nested-bang example in §8.4 needs.

**It is currently unpinned, and that is why it drifted.** `DslSmoke:1016`'s
`decide` pin is `traceOf srcBlockSpelling = traceOf srcStringSpelling` — the
two-spellings identity — which says nothing about what may follow a closing
fence. Add two pins: a program whose fence is closed by `)` (inside a bang) and
one whose closing fence carries a trailing `--` comment.

**`stmtWords` (`Parse.lean:522`) loses `answer`**: it no longer begins anything,
so a binder may be called `answer` again. Small, real, and exactly the kind of
thing the audit exists to find. Two battery cases quote `stmtWords` verbatim and
must be edited (see §8.6). Note the interaction with D20: `answer` leaving
`stmtWords` is what makes the migration clause necessary, since without it
`answer d` reaches `parseFnBody`'s `.ident w` branch, `freshOfTables` now passes,
and the author is told **"expected `<-`" at `d`** — one token past the actual
word, with no mention of `answer`, of the deletion, or of the fix.

### 2.6 Bangs in prompts: refused, and the alternative stated fairly

**Refused.** Four reasons, in increasing order of decisiveness:

1. *Consumption stays consumption.* The language's rule 3 says there are two
   consumption sites and no third; a prompt that also *produces* questions
   would make "who can see what" require reading inside prompts, which is the
   scan the design sells.
2. *The rung stays decidable from the preamble.* `Prompt.closed` decides
   `askC` (batch) versus `ask` (pipeline) from the hole structure alone
   (`Syntax.lean:140`). A question nested inside another question's words does
   not break that computation, but it does break the *reader's* version of it:
   a closed question's words would contain an open question's answer.
3. **The `expand` theorems depend on it.** `expand_lit` (`Parse.lean:574`),
   `expand_interp_hit` (`Parse.lean:577`) and `expand_append` (`Parse.lean:583`)
   are the only theorems in the file round 17 rewrites, and they survive
   verbatim *because* of D6: a bang legal in a prompt would put a `RawRhs`
   inside a `Chunk`, and `expand_append`'s homomorphism statement would no
   longer type-check. This is a proof-side reason the draft's prose reasons did
   not include.
4. **`!` is prose.** Prompts are byte-literal by round-8 decree — inside a
   fenced block everything but `{name}` and `\{` is literal, and the block
   scanner is pinned by a `decide` test. Making `!` significant would require
   `\!` escaping in every prompt that ends a sentence with an exclamation mark,
   in a language whose prompts are English addressed to people and models. That
   alone settles it.

*The alternative, honestly:* allow `{!(ask …)}` — "lift, then splice" — and
restrict it to quoted strings, where `!` is already inside a lexed token and
could be given meaning without touching the block scanner. It would read
compactly for one-use text answers, which is a real pattern (`why` in
`harden-imported.wf`, §3.2). It is refused anyway, because the round-8 block
work explicitly established that the two text spellings behave identically;
a hole that works in `"…"` and not in ` ``` ` would be the first divergence,
and it would land in the construct authors reach for most.

Consequence, stated as a rule of thumb for the guide:

> **Name what is spoken; lift what is passed.** A value that goes into a
> prompt needs a name. A value that is passed to a function or branched on
> does not.

---

## 3. The noise audit

Every construct of `GRAMMAR.md`, asked the same three questions: what would
Haskell or Idris write; is anything here encoding something elidable; keep,
elide, or change.

### 3.1 `answer` — **ELIDE (delete)**

Haskell/Idris write nothing: the last expression of a `do` block is its value,
and `x <- m; pure x` is the monad's right identity, which every linter flags.
Here the elaborated term is *identical*, by `rfl` (§1.2). Before and after, all
three value functions of `example/library.wf`:

```
                                 -- BEFORE                     AFTER
function drafted (…) -> text {   d <- ask model "author" …     ask model "author" served by "deep" ```…```
                                 answer d                      (nothing)
}
function reviewed (…) -> verdict { v <- panel, all must approve […]   panel, all must approve [ … ]
                                 answer v                      (nothing)
}
function judged (…) -> verdict { v <- ask model "judge" ```…```  ask model "judge" ```…```
                                 answer v                      (nothing)
}
```

Six lines and three binder names deleted; the term is unchanged. `applied`
(`-> receipt`) is untouched in surface, `Raw` and plan alike (D17). Full
rewritten file in §8.4.

### 3.2 One-use binders — **ELIDE where the value is passed or branched on; KEEP where it is spoken or read twice**

Haskell would write `f =<< m` or `do { x <- m; f x }`; Idris writes `f !m`.
This is the owner's directive 4, and the boundary matters more than the
feature. `example/harden-imported.wf`, construct by construct:

**`draft` — keep the name.**

```
  -- attempted
  result <- revising !(library.drafted library.guide aim ```…```) as patch, at most 2 amendments { … }
```

Refused by D8, and it should be: `revising draft as patch` is a sentence whose
subject is a noun, and the reader who wants to know what is being revised must
be able to find the word. (The technical bonus recorded in D8: the `revising`
subject is the one name position whose kind grounding runs through
`useKindS`'s carrier clause rather than directly, so refusing it also removes
the one path on which a temporary's inference could fail.)

**`why` — keep the name, twice over.** It is consumed by `{why}` in the amend
prompt, and prompts refuse bangs (D6); and it sits inside a `revising` clause,
where D15 refuses bangs outright. This is the rule of thumb doing its work:
`why` is *spoken*, so it is named.

**`second` — keep the name, and the language forces it.**

```
  -- attempted
  case !(library.judged patch $rubric $context) { approved { … } objected { … } no answer { … } }
  ```rubric  … ```      -- where would these go?
```

Refused by D9: a `$label` is answered by a fence written *after the call's
arguments*, and there is no readable place to put fences that belong to a call
nested inside a `case` head. So a call with labelled blocks is bound, never
lifted. This is the right refusal on taste as well: `second` heads a
three-armed `case` twenty lines long, and a reader scanning the arms needs a
word for what is being cased.

**`ok` — lift it.** The clean win:

```
  -- BEFORE
  ok <- ask person "owner" ```
      Apply this patch?
      {patch}
      {library.flagSpec}
  ```
  if ok { library.applied patch } else { stop }

  -- AFTER
  if !(ask person "owner" ```
      Apply this patch?
      {patch}
      {library.flagSpec}
  ```) { library.applied patch } else { stop }
```

One name and one line gone, the question is where the decision is, and `ok`
stops being a name whose kind is inferred from a use two lines later. **This
example is the whole reason D19 exists**: without the fence-close fix it does
not lex (§2.5).

Score for the flagship-imported file as it stands today: one of four one-use
binders lifts. That is the honest yield, and it is the right one — the language
should make the elision available, not mandatory. §8.4's showcase adds a second
(a nested bang) deliberately, to exercise the feature rather than because the
program demanded it, and says so in a comment.

### 3.3 The `amend <carrier>` head — **KEEP**

Is it derivable? Yes, entirely: the parser refuses any head that is not the
`as` name (`Parse.lean:839`), so it carries no information. It is nevertheless
kept, because round 8's cold reader filed the loop's invisible back-edge as
*fatal* and round 10 fixed it by putting the target of the rewrite on the page.
This is redundancy chosen for readability, and — the part that makes it
legitimate — **the redundancy is checked, so it cannot rot**. A comment could
lie; this cannot. Keep, and say why in the guide, so it does not get audited
away next round.

### 3.4 `revising d as c, at most n amendments` — **KEEP all three parts**

* `as c`: not elidable **given rule 6 (no shadowing)**. The carrier is a
  *different value* from the subject — the moving candidate — and reusing
  `draft` for it would be a live name meaning two things, which is the one
  thing the language refuses outright. The alternative (elide `as` and let the
  subject's name be rebound in the body) buys one clause and sells the rule
  that makes "search the page" work.
* `at most n amendments`: load-bearing three times over — `Nat.rec` unrolls
  `n`, `maxRevisions` bounds it, `blockAsks` prices `(n+1)·review + n·amend`.
  Not elidable in any language.
* the unit agreeing with the numeral (`1 amendment`): kept; it is a
  proofreading aid that costs one parser clause.

The review binding (`why <- …`) cannot be elided either, per §3.2. Recorded
honestly: **the loop is the one construct where round 17 removes nothing, and
D15 adds a refusal to it.**

### 3.5 `known here:` — **KEEP, optional**

Haskell has no analogue; the nearest is a type signature written for the
reader. It is opt-in, it is checked, it cannot rot, and §2.4 makes it immune to
temporaries — with the filter being the identity on every program that exists
today. Nothing to change but that one line. Whether a block may *end* with one
is Q2.

### 3.6 `stop` — **KEEP the word**

`stop` is `pure ()`. Haskell writes `pure ()`, Idris the same. Keeping the word
costs one token and buys the round-9 rule *"a path that does nothing says
so"* — `{ }` stays unwritable. Under the new reading `stop` is one of the forms
a block's final may take (§6), so it is no longer a special *block shape*; it is
a step like any other, which is a simplification of the *story* even though the
syntax is unchanged.

### 3.7 Statement asks — **KEEP the syntax, DELETE the concept**

The act is no longer a construct: it is a do-step with its binder elided, at
the kind its position imposes (`receipt`). The guide's story gets strictly
shorter — §Four of `doc/dsl-guide.html` currently spends a paragraph
introducing "the act" as a thing; it becomes a sentence in the do-notation
section plus the two honest limits (discard is not consequence; a receipt
verifies nothing), which are *about the receipt kind*, not about a construct.
The permission layer is unaffected: it keys on the receipt kind, and the kind
is still what statement position imposes. §1.1's refusal — a value call in
statement position — is part of this story and must be told with it.

### 3.8 `panel, all must approve [ … ]` — **KEEP**

Haskell would write `mconcat <$> traverse ask [...]`, which is exactly what it
elaborates to (`Plan.panel` is a `foldr` of the verdict monoid) and exactly
what the owner refused to make the surface say. The rule stays on the page
(round 10). The bracket-and-comma list is Haskell's own list syntax. Members
stay `ask`s (D7): the monoid, the trace and the cost model are all stated over
questions, and `k` members must cost `k` questions in every world.

### 3.9 Function declaration syntax — **NO CHANGE (recommended, not churned)**

An Idris-style separated signature would read:

```
drafted : text -> text -> text -> text
drafted guide goal shape = { … }
```

Against it: the parameter *names* leave the signature, so `name : kind` — the
one place a reader looks to learn what a parameter is — is split across two
lines; the result kind moves away from the brace that opens the body; two
lines replace one; and it is a round-16 decision the owner approved, with the
brace-delimited consistency of every other header (`function`, `workflow`,
`define`) resting on it. For it: arity-directed parsing would still work (the
arity is still known before first use), and a curried signature would prepare
for partial application — which this language does not have and should not get
(a function is an open plan over its parameter context; partial application
would need a `Sub` that is not yet total).

**Recommendation: do not change.** D16 (§3.13) is the change the owner did ask
for, and it is strictly smaller.

### 3.10 `independent draw n` — **KEEP, and promote it**

It is the *only* way to get a second opinion, and round 17 makes that more
visible rather than less: two identical bangs share one answer (§5.3), so
`independent draw` is what the author reaches for when they meant two. The
guide should place it immediately beside the bang rule, not three sections
away. §8.4's showcase uses it inside a panel, which is the honest place: two
independent readings by one reviewer.

### 3.11 The `<-` arrow — **KEEP**

It is do-notation's own arrow, in Haskell, Idris, and here. Deleting it would
mean either `let`-style `=` (which would make binding look pure, and every
binding here is a question) or juxtaposition (which would collide with calls).
The lexer's stray-`<` diagnosis stays as it is.

### 3.12 The result arrow `-> kind` — **KEEP explicit**

Elidable in principle: a body's shape decides its kind, since a `-> receipt`
body ends in a statement and a value body ends in an expression. Kept, for two
reasons. First, the arrow is the function's **contract**, read at the call site
by every author who never opens the body; inferring it would put the caller's
obligation inside the callee's last line. Second, the parser dispatches on it —
`parseFnBody env fname result` takes `result : Code` and D17 keys the no-lift
clause on it — so eliding it would turn a decision the parser makes into one it
must guess. The owner's input 6 asked for the *parameter* annotations, and
explicitly left the arrow alone.

### 3.13 Parameter annotations — **ELIDE, defaulting to `text` (D16)**

The owner, after the round-17 brief was written: *"since argument types are
almost always text, in this case the `: text` can be omitted."* Taken.

```
param  ::= name [ ":" kind ]        -- omitted means `text`
```

* Only a **`verdict`** parameter ever annotates, because `verdict` is the only
  other kind a parameter may have: `flag` and `receipt` parameters stay refused,
  with today's two diagnoses unchanged (`Parse.lean:1088–1095`) — a flag
  parameter because nothing in a body can consume one, a receipt parameter
  because a receipt carries no information.
* `: text` stays **legal** where an author wants it. This is an elision, not a
  prohibition.
* `parseParams` needs no lookahead: after the identifier the next token is `:`,
  `,` or `)`, and the three are distinguished by one token.
* **The quirk, for the guide.** `function f (verdict)` declares *one text
  parameter named `verdict`*, not a verdict parameter. This is not a new
  hazard — kind names have always been legal binder names, pinned as `"ok"` at
  `test/DslSmoke.lean:505–507` — but round 17 is the first time the two
  readings sit one token apart, so the guide says it out loud rather than
  letting a reader find it.

Yield across the examples: eight annotations deleted from `library.wf` alone,
and every signature in this document is updated accordingly —
`function judged (patch, rubric, context) -> verdict`.

### 3.14 Summary table

| Construct | Verdict | One-line justification |
|---|---|---|
| `answer x` | **delete** | right identity; identical term; do-blocks don't write it |
| one-use binder, passed/branched | **elide** via `!(…)` | Idris's bang, at the positions where a name already stands |
| one-use binder, spoken/read twice/in a loop clause | **keep** | prompts refuse bangs (D6); loop clauses refuse them (D15) |
| `: text` on a parameter | **elide** | almost always text; only `verdict` annotates (D16) |
| `-> kind` on a function | keep | the contract is read at the call site; the parser dispatches on it |
| `amend <carrier>` | keep | checked redundancy; the back-edge was filed as fatal once already |
| `as <carrier>` | keep | forced by no-shadowing: the carrier is a different value |
| `at most n amendments` | keep | the bound is the unrolling, the limit and the price |
| `known here:` | keep | opt-in, checked, cannot rot; now filters temporaries |
| `stop` | keep the word | `{ }` stays unwritable; a path that does nothing says so |
| statement `ask` | keep syntax, drop the concept | a do-step at the kind its position imposes |
| statement `call` at a value kind | **stays refused** | an answer that cost a question is not thrown away silently |
| function header | **no change** | round-16 decision; `name` stays where the reader looks |
| `panel, rule [ … ]` | keep | the rule belongs on the page; members are questions |
| `independent draw n` | keep, promote | the only fresh opinion; now load-bearing beside sharing |
| `<-` | keep | do-notation's arrow |
| trailing bind in a block, arm or body | **refuse** (D18) | its answer has nowhere to go — but see Q1 for blocks and arms |
| trailing bind in a **priming** | **keep** | a priming is a prefix; it has no final position |
| `answer` in `stmtWords` | **delete** | it no longer begins anything |

No re-skin is proposed: no new sigils beyond the single `!`, and every
construct still reads as a sentence.

---

## 4. Kind discipline under the sugar

### 4.1 The imposed-kind table

| Position | Kind | Source |
|---|---|---|
| call argument | the parameter's kind | `argExpr` / `checkArgs` |
| final **ask** of a body | the declared result, imposed | `bodyBindKind`'s `answer` clause |
| final **call or panel** of a body | the source's kind, then **checked against** the declared result | `checkBody`'s rhs dispatch (`Check.lean:775–789`), then `checkFn`'s terminal (`Check.lean:826–834`) |
| final statement of a `Unit` block | `receipt` | `El .ack = Unit` |
| binder-elided statement | `receipt` | `bindForm fns .ack` |
| panel member | `verdict` | `checkMembers` |
| review binding of a loop | `verdict` | `rhsPlan … .verdict` |
| loop carrier / `settled` binder | the subject's kind | `Pend.code` |
| `if` subject | `flag` | `bnd.at? .flag` |
| verdict `case` subject | `verdict` | `bnd.at? .verdict` |
| `{x}` hole | `text`, or `verdict` by its one canonical rendering | `chunkExpr` |
| an unannotated **parameter** | `text` | D16 |

The second row is the correction the draft needed: "imposed, never inferred"
holds for a final `ask` and not for a final call or panel. Both routes end in a
refusal when they disagree with the declared result; only the *wording* differs,
and §1.2 gives it.

Named ask-binds keep first-ground-use inference and the round-8 honest side
condition (an annotation is required for any constraint component that never
touches a ground site).

### 4.2 Why anonymity makes inference strictly simpler

A bang's binder is **anonymous, used exactly once, at the position it was
lifted from, which is always a ground site**. Three consequences, all
strengthenings:

1. **The ground-free refusal can never fire on a temporary** — and the reason
   is narrower than the draft implied, so it is written down. `useArgs`
   (`Check.lean:220–227`) grounds an argument by `(args.zip ps)`, and `zip`
   *truncates*: an arity mismatch would leave a lifted temporary ungrounded and
   `bindKind` would refuse with "nothing fixes what kind of answer `!12:20`
   names" — an eighth quoting site. It is unreachable **only because parsing is
   arity-directed** (`parseArgTokens`, `Parse.lean:656–697`, reads exactly the
   arity and errors before the checker sees a mismatched call). So the totality
   is real, and it rests on arity-directed parsing — recorded in §2.3 as
   revisiting condition (ii), beside the `PEnv`-lacks-parameter-kinds note.
2. **The rule-4 hazard does not apply.** `GRAMMAR.md` records, as a
   consequence to state in the reference, that *"adding or removing a
   downstream use can change which question is asked"*. That hazard is
   entirely about multi-use inference. A temporary has one use, and it is in
   the same statement, so no edit anywhere else can move it. Every binder an
   author converts to a bang is a binder removed from the fragile case.
3. **Inference for a temporary is local.** It never scans past the next
   statement — which is why a bang is legal in a **library priming** even
   though a priming's *named* bindings must be annotated. That annotation rule
   exists because "forward", after the splice, is the importer's file
   (`Parse.lean:1008`); a temporary's grounding site is above the splice point,
   in the library's own text, always. So the rule does not bite, and the
   refusal does not need an exception — it needs a sentence explaining why the
   case is different, and D10's already-qualified minting is what makes the
   spelling survive the splice.

Net: the sugar moves work *out* of inference. Round 17 does not make the kind
system cleverer; it shrinks the domain on which cleverness is needed.

---

## 5. Trace and cost

### 5.1 Evaluation order is lifting order, and that is the trace order

> **Rule.** The questions a statement asks are put in the order the statement's
> `!`s are lifted — post-order: a bang's own bangs first, then siblings in
> source order — followed by the statement's own question. That order is the
> order of the events in the trace, and it is decided entirely by the source
> text.

Nothing here is new machinery: after desugaring, the lifted binds *are* the
preceding statements, and the trace order of a sequence of statements is
already the order they are written. The rule is worth stating because it is
what a reader needs in order to predict a transcript without desugaring by
hand — and, per §2.2, because the draft's two-key phrasing left
`f !(judged !(A) r) !(B)` genuinely ambiguous.

### 5.2 The recurrences

`blockAsks` / `bodyAsks` / `rhsAsks` (`Check.lean:860–890`) are **unchanged**,
because they run over `Raw`, and `Raw` is what the parser emits after lifting.
`maxQuestions` is unchanged. For readers of the *surface*, the derived
recurrence is:

```
asks(stmt)      = Σᵢ asks(sᵢ)  +  asks(head)        -- sᵢ the lifted sources, in post-order
asks(if b … …)  = asks(b's bangs) + asks(yes) + asks(no)
asks(arm)       = as before; a bang inside an arm counts inside that arm only
asks(revising)  = unchanged — D15 means a loop clause contains no bang at all
```

The second and third lines are the content of "lifting never crosses a `{`"
(§2.2): a bang in a subject is priced once, before the branch; a bang in an arm
is priced in that arm alone. So the per-branch cost enumeration — the twelfth
of the survey's differentiators, and the reason `agent-cat cost` exists — keeps
its shape exactly. The fourth line is why D15 is a cost decision as much as a
syntax one.

### 5.3 The two divergences from Idris, stated as language rules

The draft named one. Idris's *other* bang behavior is its most notorious, and
this language diverges from it too — favorably — so both belong under one
heading, in the guide, beside the bang rule.

**Divergence 1 — sharing.**

> **The shared-answer rule.** The world is a function of the question. Two
> questions with the same shape and the same words are **one answer** in every
> world. A bang binds; it does not resample. `f !(ask q) !(ask q)` lifts two
> binders that receive the *same* answer. **In Idris the two bangs could
> differ; here they cannot.** A fresh opinion is a different question, and the
> way to write one is `independent draw n`.

Worked example. Given `compare (a, b) -> receipt`:

```
compare !(ask model "critic" "Rate this patch:\n{patch}")
        !(ask model "critic" "Rate this patch:\n{patch}")
```

* **Answers:** one. Both binders receive it.
* **Trace:** two events — the transcript records what was *put*, and two
  questions were put.
* **`billFresh`:** 2 (it sums over all events).
* **`billMemo`:** 1 (it sums over distinct questions —
  `Agentic/Core/Cost.lean:176`), so a memoizing runtime pays once.
* **`blockAsks`:** 2 — the cost tree prices questions *asked*, matching
  `billFresh`, which is the conservative side. Unchanged from today, where two
  identical bindings price the same way.

To get two opinions:

```
compare !(ask model "critic" "Rate this patch:\n{patch}")
        !(ask model "critic" independent draw 1 "Rate this patch:\n{patch}")
```

Now the shapes differ in their draw index, so they are two questions: two
answers, two events, `billFresh` 2, `billMemo` 2.

**Half of this rule is already proved, and the draft defended it only by
`billMemo`'s definition.** `bindForm_ask_head_draw` (`Explain.lean:356`) is
∀-quantified over `bindForm fns c S (.ask a)`, so it now additionally
guarantees that a *bang-lifted* ask puts the source-written draw index on the
first event of the run. Cite it here: the "two shapes differ in their draw
index" half is a theorem, not a convention.

**Divergence 2 — scope.**

> **The arm rule.** A bang written inside an `if` or `case` arm stays in that
> arm: it is lifted to the head of the statement it sits in, inside the arm,
> and its question is asked **only on that path**. In Idris a bang inside a
> branch is hoisted *out of* the branch — branches are not do-blocks — so the
> action runs unconditionally. That is the gotcha every Idris programmer has
> been bitten by, and this language does not have it.

Here the better rule is also the cheaper one: it is what keeps `blockAsks`'s
per-branch tree intact (§5.2) and what makes `agent-cat cost`'s per-path
enumeration continue to mean what it says.

Neither divergence is a consequence of the bang; both are the language's
existing semantics meeting a notation borrowed from a language whose bang means
something else. They must be stated at the point of borrowing — in the guide, in
the grammar, and (for divergence 1) in the diagnosis for `!x` (D4), which is why
that refusal names `independent draw`.

---

## 6. Grammar: the EBNF delta

Against `GRAMMAR.md` §Grammar. **Deleted** productions struck, **added** marked.

The draft's version of this block **did not derive the pinned flagship**, and
that was the first fatal finding. `block ::= "{" { step } final "}"` with
`final ::= expr` and `expr ::= name | source` makes a block that *ends in a
branching* underivable — yet every block of `example/harden.wf` ends exactly
that way (the workflow block ends in `case result { … }`, the `settled patch`
arm ends in `if ok { … } else { … }`), and so does `harden-imported.wf`'s
`approved` arm. It also admitted a bare name as a block's final, which is
meaningless: `workflow { x <- ask model "m" "?"  x }` has no reading, since a
block answers a receipt and a name is never one.

The repair splits the two finals, and it makes the honest point visible: **for
blocks, the grammar does not change at all.** A block's final is exactly a
statement that may stand alone; the do-reading is a change to the story and to
one refusal. Only *bodies* gain a final expression.

```
                                   -- DELETED ------------------------------
body       ::= { bodystmt } "answer" name
             | { bodystmt }
bodystmt   ::= name [ ":" kind ] "<-" ( ask | panel | call )
             | ask
             | call
param      ::= name ":" ( "text" | "verdict" )
argument   ::= name | text | "$" label       -- "a call is not an argument: bind it"

                                   -- ADDED / REPLACED ---------------------
param      ::= name [ ":" kind ]             -- omitted means `text`; flag/receipt still refused (D16)

body       ::= { step } bodyfinal            -- a do-block; the final step is the result
bodyfinal  ::= name | source'                -- at the declared result (§4.1)
             | ask | call                    -- …and for `-> receipt`, a statement, unlifted (D17)

block      ::= "{" { step } blockfinal "}"
blockfinal ::= ask | call | branching | "stop"
             | assertion                     -- accepted today; see Q2

step       ::= [ name [ ":" kind ] "<-" ] source
             | branching
             | assertion
branching  ::= "if" subject block "else" block
             | "case" subject "{" arms "}"
assertion  ::= "known" "here" ":" ( "nothing" | name { "," name } )

subject    ::= name | bang                   -- `if` and verdict-`case` heads
argument   ::= name | text | "$" label | bang            -- CHANGED
bang       ::= "!" "(" source' ")"                        -- NEW
source'    ::= ask | panel | call            -- no `revising`, no `$label` inside (D9)

source     ::= ask | panel | call | loop     -- `loop` only right of `<-`, as before
primer     ::= name ":" kind "<-" source' | source'       -- bangs legal (§4.2); no final position (§1.1)
```

Three notes the productions do not carry:

* **A branching is both a step and a final**, and that is forced, not chosen: a
  branching's *arms* carry the finals, so at `Unit` the branching itself is the
  block's result. Round 11's "branchings are terminal in their block" already
  says this from the other side.
* **`"{" "stop" "}"` is now the degenerate case** of `{ } blockfinal { }` with
  zero steps, not a separate production. `{ }` stays unwritable because
  `blockfinal` is mandatory.
* **A bare name is refused as a `blockfinal`**, with the reason in the
  diagnosis: *"a name is an answer, and a block answers a receipt: write the act
  it came from, or `stop`"*.

Unchanged: `program`, `library`, `import`, `define`, `function`,
`call`, `labelledblock`, `ask`, `rule`, `loop`, `arms`, `kind`, `text`,
`plainstring`, and every rule in "The rules the grammar does not carry" except
rule 11 (the act is now derived — same behavior, shorter statement) and rule 1
(`stop` is now one form of a block's final, not a special block shape).

**Tokens.** One new: `!`, added to `punctChars`. No new keyword. `answer`
leaves `stmtWords` (D20 keeps one migration clause at the word for a release).

### 6.1 Parsing notes

* **Juxtaposition survives, because the bang is parenthesized.** The parser is
  arity-directed: at a call head it knows the arity and reads exactly that many
  single-token arguments (`parseArgTokens`). A bang is a *bracketed* argument
  whose end is marked by its own `)`, so it is still exactly one argument, read
  without lookahead, and a nested call inside it is read by its own arity and
  closed by its own paren. Round 16's refusal existed because *unparenthesized*
  juxtaposition is genuinely ambiguous (`f g x` — is `g` an argument or a call
  of arity 1?); the parentheses remove the ambiguity, which is precisely why
  the feature is safe now and was not before.
* **The new body final costs one token of lookahead, on `}` only.** Deciding
  whether a trailing identifier is a nullary call, a binder, or the body's final
  name requires seeing the next token. It is one token, it is consumed at a
  brace, and it never occurs inside a call's arguments — so arity-directed
  parsing is untouched.
* **The reversed diagnosis.** `Parse.lean:685` becomes:
  ``a call is not an argument as written: bind it above — `y <- judged …` — or
  lift it here: `!(judged …)` ``. Same site, same trigger, two fixes named. Its
  neighbour at `Parse.lean:701` gains the bare-parenthesis message (§2.1).
* **`$label` fences** are collected after the call's arguments, as today. A
  `$label` inside a bang is refused at the `$` with: *"a labelled block follows
  a call written as a statement; bind this call and pass its name"* (D9).
* **Trailing blocks** are unaffected as *tokens*: a fenced block is one token,
  so `!(library.drafted g aim ```…```)` reads as head, two names, one block,
  close paren — **provided D19 lands**, because otherwise the fence does not
  close (§2.5). This is the single most important cross-reference in the
  document.
* **Dotted names** are unaffected: `!(library.judged …)` resolves through
  `resolveFn` exactly as a statement call does.
* **Fuel** discipline is unchanged: every new recursion (the bang's inner
  source) is seeded from the remaining token list's length and consumes at
  least the `!` and the `(`.

---

## 7. Elaboration and theorem survival

### 7.1 `Syntax.lean` — no change

`Raw`, `RawBlock`, `RawBodyStmt`, `RawRhs`, `RawSource`, `RawArg`, `RawFn`,
`RawProgram`: **all unchanged**. `RawFn.answer : Option String` survives as
what it always was operationally — *which binding is the body's result* — and
its docstring is rewritten to say so: "the body's final expression, lifted to a
binding by the parser; `none` for a `-> receipt` body, which does not lift."

**The field must survive as data.** D2's whole survival argument depends on that
node continuing to exist; a *removal* would restate `checkBody_level_le` and
`checkFn`, a *rename* is free. If the rename to `resultOf` is taken, take it in
the same commit as the message rewrites (they touch the same lines), and price
the two caveats: no theorem *statement* mentions the field
(`checkBody_level_le`'s `answer` is a plain binder name, `Dsl.lean:455`) and
`flagshipProgram`'s `fns` is `[]` so the derived `DecidableEq`/`Repr` change
cannot move the parse pin — but `test/DslSmoke.lean:1266` constructs `hbFn` with
`answer := some "p"` by field name, and `Repr RawFn` output changes if any
fixture prints one.

### 7.2 `Parse.lean` — where the work is

| Clause | Change |
|---|---|
| `punctChars` (`:102`) | `'!'` added |
| `fenceCloses` (`:210–219`) | **D19**: `)` accepted, and a trailing `--` comment — the spec's own rule 2 |
| `stmtWords` (`:522`) | `"answer"` removed |
| `parseParams` (`:1069–1099`) | **D16**: the `:` is optional, defaulting to `text`; the flag/receipt refusals unchanged |
| new `parseBang` | `!` `(` `parseRhs` `)`; refuses `revising`, refuses a bare name, refuses `$label` inside |
| `parseArgTokens` (`:656–701`) | accepts a bang as an argument, returning it as a *pending lift* alongside `PArg`; gains the bare-`(` message |
| new `liftStmt` | given a statement's pending lifts, emits `.bind tⱼ none (.rhs sⱼ) …` in **post-order**, then the statement; mints each `tⱼ` already-qualified (D10) |
| `parseBlockFrom` | `if` / `case` heads accept a `subject` (name or bang); the trailing-binding refusal (D18); the bare-name-as-final refusal; every statement routed through `liftStmt` |
| the `revising` clause parsers (`:834, :844`) | **D15**: a "no lifting site here" flag; a bang in either clause is refused with the once-per-round diagnosis |
| `parseFnBody` (`:1030–1066`) | the `answer` clause replaced by **D20**'s migration diagnosis; the last statement is the body's result — **for a value result** a name becomes `answer := some x` directly and a source is lifted to `!L:C <- source` with `answer := some "!L:C"`; **for `-> receipt` (D17) nothing lifts**: the last statement is emitted as a statement with `answer := none`, exactly as today; a trailing binding refused |
| `parsePrimer` (`:978–1020`) | statements routed through `liftStmt`; the annotation requirement applies to *named* bindings only (§4.2); **no trailing-bind refusal here** (§1.1) |
| `resolveFn` diagnosis (`:685`) | reversed message (§6.1) |
| `expectStr` in the define header (`:1177`) | the bang-in-a-define message (§2.1) |
| `parseAsk`'s `expectKw "ask"` (`:604`) | the bang-as-panel-member message (§2.1) |
| `expand_lit`, `expand_interp_hit`, `expand_append` (`:574, :577, :583`) | **unchanged, and D6 is why** — a bang legal in a prompt would put a `RawRhs` inside a `Chunk` and `expand_append`'s homomorphism would not type-check |

Estimated size: **+140 / −40 lines**, all mechanical, all in one file.

**The survival argument, correctly located.** The draft wrote
`desugar : Surface → Raw — total, and its image ⊆ {Raw writable today}` and
called that "the whole theorem-survival argument". That over-claims and
mislocates it: no such function exists in the design (the lifting is fused into
the parser), it is not a Lean theorem, and no theorem needs it. Two separate
claims, each checkable:

> **(i) Survival.** `Raw` and every checker function named in a theorem are
> unchanged, and **no theorem in `Dsl.lean`, `Check.lean` or `Explain.lean`
> inspects the parser's output.** `parseAndCheckProgramWith_level_le`
> (`Dsl.lean:590`) is `unfold; split; exact checkProgram_level_le`;
> `parseAndCheckRawProgramWith_eq` (`Explain.lean:301`) `cases`/`split`s on
> `parseProgramWith`'s result and never looks inside it. That is the mechanical
> reason nothing restates, and it is indifferent to *any* parser change,
> including this one.
>
> **(ii) Hygiene.** Every `.bind` the lifter introduces is a `.bind` a
> hand-written program could have written, differing only in the binder's
> spelling. That is what confines the exposure to the leaks named in §2.4 — and
> it carries nothing else.

Do not let (ii) carry (i). They are different claims with different evidence.

### 7.3 `Check.lean` — two clauses and seven messages

1. `knownHere`: filter unwritable names from `live` (§2.4, leak 1). The clause
   recurses and builds no plan node; no lemma mentions it, and §7.4 records the
   check against `checkBlock_level_le`'s script.
2. `showName` (with `Dsl.isTemp`), used at the **seven** sites enumerated in
   §2.4 — including `checkFn`'s terminal, which is the *most likely* site of
   all and which is also reworded to drop the deleted keyword (§1.2), and
   `bodyBindKind`'s hint, which becomes "(a hole, an argument, the final
   expression)". Diagnoses are `String`s inside `CheckError`; no theorem is
   stated about their content **except the five listed in §2.4**, which are
   off-limits.
3. The two body refusals in `parseFnBody` disappear; their `Check`-side
   counterpart (`checkFn`'s *"a value function ends with `answer <name>`"*,
   `Check.lean:845`) stays as the hand-built-`Raw` guard, exactly as
   `check_panel_nil` does for empty panels. **It becomes unreachable from
   source text**, which is a documented category the battery already has (see
   `DslSmoke.lean`'s exception 2), and it is tested against a hand-built `Raw`
   the same way. Its wording drops `answer` too.

Nothing else. In particular `checkBody`'s terminal does **not** become a new
imposed-kind source: in `Raw` it is still `answer <name>`, where the name is
the temporary the parser lifted, and `bodyBindKind`'s existing `answer` clause
grounds that temporary at the declared result. The imposed kind is real — it is
just imposed one node earlier than the round-17 brief supposed, and the node it
is imposed at is one that already exists.

**Why D2-vs-checker-level is not load-bearing for `checkBody_level_le`.** Under
D2 there is no terminal rewrite at all: `checkFn` still ends at `answer <name>`,
so `fin` is still `lookupBinding … ▸ Plan.ret e` and `checkFn_level_le`
discharges `hfin` with `level_ret` + `bot_le` exactly as at `Dsl.lean:531` and
`:543`. The theorem is robust because it already quantifies over `fin` with the
hypothesis `∀ Δ SΔ q, fin Δ SΔ = .ok q → level q ≤ pipeline` — any terminal
producing a `ret` satisfies it. The D2 choice is load-bearing for `checkArgs`,
and only there.

### 7.4 `Dsl.lean` — no change, checked against the proof scripts

`askPlan_level_le` (`:126`), `checkMembers_level_le` (`:137`), `FnLevel`
(`:160`), `callPlan_level_le` (`:164`), `rhsPlan_level_le` (`:182`),
`bindForm_level_le` (`:218`), `PendLevel` (`:255`), `checkBlock_level_le`
(`:265`), `checkBody_level_le` (`:453`), `checkFn_level_le` (`:514`),
`checkFnsList_fnLevel` (`:547`), `checkProgram_level_le` (`:575`),
`parseAndCheckProgramWith_level_le` (`:590`), `parseAndCheck_level_le` (`:599`)
— **all fourteen survive verbatim, statement and proof.**

This was verified against the proofs, not the docstrings. Each is an induction
over a `RawBlock`/`RawBodyStmt`/`RawFn`/`Fns` whose constructors do not move,
discharged by `split at h` on `checkBlock`/`checkBody`/`bindForm`/`rhsPlan`
clauses that round 17 does not touch. **The one `Check.lean` edit inside this
chain's reach is the `knownHere` `live` filter (`Check.lean:534–536`)**, and it
was checked for interference: `checkBlock_level_le`'s `knownHere` case is
`simp only [checkBlock] at h` followed by the recursive call, and the filter
changes the clause's *body* without changing the match's patterns, so the
reduction is unaffected. A reviewer does not have to re-derive that.

`overRevised_sound` (`:615`), `checkProgram_overRevised` (`:694`),
`checkProgram_oversized` (`:706`), `checkProgram_of_within` (`:720`),
`checkBlock_caseVerdict_arms` (`:733`), `askShape_draw` (`:762`) — **all six
survive verbatim.** `overRevised_sound`'s induction steps through
`.bind _ _ (.rhs _) rest` (`Dsl.lean:638–640`), which is precisely the shape
every lifted bind has, so lifted binds are transparent to it;
`Explain.RawBlock.revisionBounds` (`Explain.lean:378`) skips them the same way.
`checkBlock_caseVerdict_arms` is ∀-quantified in `x`, so it now *also*
constrains a `case` whose subject is a lifted temporary — a free strengthening.

`Check.lean`'s own theorems — `check_panel_nil` (`:717`), `checkArgs_too_few`
(`:388`), `checkArgs_too_many` (`:395`), `parseAndCheck_ok_iff` (`:972`),
`under_ask1`/`under_askC1` (`:179`/`:184`) — **all survive verbatim.** The first
is `unfold check checkBlock freshName; rw [hx]; rfl`: it unfolds the *whole* of
`checkBlock` and reduces into the `.bind` clause, and the `knownHere` edit
changes a sibling clause's body but not the match's patterns. The rest are
`rfl`s about functions round 17 does not touch. The only cost is
re-elaboration.

`Explain.lean`'s seven — `parseAndCheckRaw_eq_with_nil` (`:292`),
`parseAndCheckRawProgramWith_eq` (`:301`), `_level_le` (`:318`),
`parseAndCheckRawWith_level_le` (`:329`), `parseAndCheckRaw_eq` (`:336`),
`parseAndCheckRaw_level_le` (`:343`), `bindForm_ask_head_draw` (`:356`) —
**all seven survive verbatim.** The six front-end parity/bound theorems
`cases`/`split` on `parseProgramWith`'s result and never inspect it, which is
§7.2's claim (i) in concrete form. `bindForm_ask_head_draw` is cited in §5.3 as
the proved half of the sharing rule.

### 7.5 `DslFlagship.lean` — no change, and this is the pin

`flagshipSource := include_str "../../example/harden.wf"`.
**`example/harden.wf` is not rewritten** (D21, §8.2), and the premise was
checked rather than assumed: the file has no functions and therefore no
`answer`; its workflow block's last statement is `case result { … }`, not a
binding, so D18 does not fire; it contains no `known here`, so Q2 cannot reach
it; and it writes no bang. Its `ok <- ask person …` binding *could* be lifted
and must not.

Therefore `flagshipRaw` (`:97`), `flagshipProgram` (`:255`), `flagshipPlan`
(`:206`), `flagshipRaw_accepted` (`:224`), `check_flagshipRaw` (`:229`),
`checkProgram_flagship` (`:260`), `parseAndCheck_flagship` (`:269`),
`level_flagshipPlan` (`:282`), `card_leaves_flagship` (`:293`),
`minFold_flagship` (`:301`), `maxFold_flagship` (`:308`), the four
`trace_flagship_*`, the four `bill_flagship_*`, `flagshipUpTo`,
`flagship_bill_le`, `minFold_flagship_le_bill` and `render_eq_harden_render`
(`:59`) all survive verbatim, and are not recompiled for content.

**The argument is narrower than the draft's, and it must be, because the draft's
does not reach.** `flagshipRaw` is a hand-transcribed `Raw` literal compared
*syntactically* — by the parse pin and by `decide (prog = flagshipProgram)`
(`DslSmoke:889`). The definitional equalities of §1.2 and §1.3 are Plan-level
and buy the pin nothing. What actually saves it is this:

> **Parser-emission obligation, stated as a rule.** Implementing
> last-statement-is-result must not change what the block parser *emits*. At
> `Unit` the do-reading is a change to the story and to two refusals, and to
> nothing else — the same `.act`/`.callStmt`/`.bind`/`.empty` tree, with the
> same positions. Any tidier representation — dropping the `.empty` tail,
> adding a terminal constructor, moving a `Pos` — re-baselines `flagshipRaw`,
> re-runs the `DslSmoke` parse pin, and recomputes all nine `decide +kernel`
> results.

The contingency, priced in one line so nobody has to wonder: if the pin ever
churns, `flagshipRaw` is re-transcribed with new positions and the nine kernel
results re-run — the round-8 block work performed exactly that operation, and
`GRAMMAR.md`'s "Elaboration and theorem survival" section records what it cost.

This is the single largest argument for D2, and it is why the temptation to
show off the bang in the flagship is refused: **the flagship is a pin first and
a showcase second**, which is precisely the reason D21 puts the showcase in the
other pair.

### 7.6 Kernel and axiom policy

Untouched. No `native_decide`. The lexer still never runs in the kernel — the
lifting pass is part of parsing, so it inherits that, and so does D19's
`fenceCloses` repair. `parse` pins stay runtime, as `DslFlagship`'s note
requires. No new `Decidable` instances, no new `deriving`.

---

## 8. Migration

### 8.1 What moves, at a glance

| File | Round-17 change |
|---|---|
| `example/harden.wf` | **none, byte for byte** (D21, §7.5) |
| `example/hello.wf` | none — no `answer`, its trailing act is already the result, no `known here`, no trailing binding |
| `example/ill-typed.wf` | **one line appended** (§8.3) — the draft said "not touched", and that was wrong |
| `example/library.wf` | rewritten: `answer` deleted, annotations elided, two functions added for the showcase (§8.4) |
| `example/harden-imported.wf` | rewritten: one lift, one nested lift, and the showcase's remaining features (§8.4) |

### 8.2 The every-feature showcase: the pair, not the flagship (D21)

The owner asked that the harden example use every feature after round 17. That
collides with the fact that `example/harden.wf` is the kernel pin. Two routes,
both priced.

**Recommended: `library.wf` + `harden-imported.wf` become the every-feature
pair; `harden.wf` stays byte-identical.**

* Cost: **zero pins.** The pair's only pinned facts are
  `DslSmoke:1245` ("`example/harden-imported.wf` checks against
  `example/library.wf`" → `"ok"`), `DslSmoke:1250` ("`example/library.wf` runs
  alone: its priming, then nothing" → `"ok"`), and `CliSmoke:229` (`plan` of the
  imported flagship prints a line containing "house style guide"). All three are
  outcome pins, not transcriptions; the rewrite below preserves all three by
  construction — the priming's closed question keeps its exact words — and they
  are re-run, not assumed.
* Benefit: the pair *already* carries imports, dotted names, `$labels`, trailing
  blocks and functions, which the single-file flagship structurally cannot. It
  is where a feature tour belongs.

**The alternative: modernize `harden.wf` itself.** Priced honestly, because the
owner should be able to choose it deliberately:

* re-transcribe `flagshipRaw` by hand (`DslFlagship.lean:97`, a `Raw` literal
  with every position written out);
* re-run and re-time the nine `decide +kernel` proofs, in a module that
  elaborates in ~107 s;
* re-baseline `DslSmoke`'s parse pin `decide (prog = flagshipProgram)`
  (`:889`);
* re-pin the bills if any question count moves: `CliSmoke`'s
  `expectedApply = 7` (`:113`) and `expectedRefuse = 6` (`:123`), each of which
  restates a kernel theorem (`Dsl.bill_flagship_apply`,
  `Dsl.bill_flagship_refuse`), plus the aliased-run repeat at `CliSmoke:347`;
* re-check `Harden.demo`'s trace agreements and `render_eq_harden_render`.

That is a day of careful transcription and re-verification, spent to put
features into a file whose job is to *not move*. Recommended against; recorded
so the choice is the owner's.

### 8.3 `example/ill-typed.wf` — one line appended (the draft was wrong here)

The draft said this file is "not touched by round 17 — no round-17 clause is
involved", and §8.5 said "no CLI expectation changes". Both are false, and the
consequence is three broken pins. The file's **last statement is a trailing
binding**:

```
  note : text <- ask model "scribe"
    "Write this up: {ok}"
```

which is exactly the shape D18 refuses. Under round 17 as drafted, the file
would be refused at the *parser*, at the binding's position 11:3, with the new
wording — instead of by the *checker* at 11:18 with the interpolation
diagnosis. `test/CliSmoke.lean:254` pins `example/ill-typed.wf:11:18:` and
requires all three of `plan`, `cost` and `run` to produce it byte for byte.

*Repair:* append one act, so the trailing statement is no longer a binding:

```
workflow {
  ok : flag <- ask person "owner"
    "Shall we?"

  note : text <- ask model "scribe"
    "Write this up: {ok}"

  ask tool "log" "filed."
}
```

The `{ok}` conflict still fires first, at exactly 11:18 (`Prompt.expr S a.pos`
puts the error at the `ask` keyword, and line 11 column 18 is where `ask`
stands), so every `CliSmoke` pin holds byte for byte and the file keeps its
purpose. The separate obligation from the round-8 audit — to rebuild this file
around a genuine conflict once inference deletes the current one — stands where
it was, untouched by this repair.

### 8.4 The rewritten pair, in full

**`example/library.wf`** — `answer` deleted (D1), annotations elided (D16), and
two functions added so the pair covers `verdict` parameters and a second
receipt procedure. `applied` is byte-identical below the header line, by D17.

```
-- A library: standing context, shared words, and reusable questions. It has
-- no `workflow` block, so it is imported, not run; its top-level statements
-- are the priming, and they are the first questions of every program that
-- imports it. Its top-level bindings are annotated, because a library's
-- questions must not depend on who imports it.
--
-- With `example/harden-imported.wf`, this file is the every-feature showcase:
-- `example/harden.wf` is the kernel pin and does not move.

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

-- Three parameters, all text, so none of them says so. `served by "deep"`
-- overrides the model this addressee is served by. The body is one question
-- and no `answer`: the last statement of a body is its answer.
function drafted (guide, goal, shape) -> text {
  ask model "author" served by "deep" ```
      {guide}
      Draft a patch satisfying:
      {goal}
      {shape}
      Reply with a unified diff only.
  ```
}

-- A panel: three members, one rule, three questions in every world. The third
-- is the correctness reviewer read a second, independent time — `independent
-- draw` is the only way to get a fresh opinion, because two questions of one
-- shape are one answer.
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

-- A procedure: a reusable act sequence. It answers `receipt`, so it is called
-- as a statement and binds nothing. Its last act is its receipt — and a
-- `-> receipt` body is the one body shape round seventeen does not rewrite at
-- all: same surface, same raw syntax, same plan.
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

-- The priming. Asked once, before anything an importer writes. The first is a
-- closed question, so it is the same question in every program that imports
-- this file, and a memoizing runtime pays for it once. A priming is a prefix,
-- not a block: it has no final position, so the trailing-binding refusal does
-- not reach it.
guide : text <- ask tool "cat" "Write out the house style guide, at most four short lines."

ask model "author" ```
    {guide}
    You are drafting patches for this codebase. Hold this style guide.
```
```

**`example/harden-imported.wf`** — one lifted `if` subject, one nested bang, and
every remaining feature.

```
-- The flagship, written against `library.wf`: the priming runs first, the
-- drafting and reviewing are the library's functions, and every imported name
-- says where it came from. `agent-cat run example/harden-imported.wf` reads
-- `library.wf` from beside this file.
--
-- This pair is the every-feature showcase. `example/harden.wf` is the kernel
-- pin: it is not modernized, and round seventeen does not touch one byte of it.

import library

define aim = "Harden the parser against malformed input, minimally."

workflow {

  known here: library.guide

  -- A dotted function call: two short arguments — a dotted binding, a local
  -- define — and one trailing block for the last parameter. Bound, not
  -- lifted: the loop below is about this value, and the reader must be able
  -- to find the word.
  draft <- library.drafted library.guide aim ```
      Keep the diff under forty lines. The standing objective is:
      {library.spec}
  ```

  result <- revising draft as patch, at most 2 amendments {

    why <- library.reviewed library.guide patch

    -- `why` is spoken, so `why` is named: a prompt refuses a bang, and so
    -- does a revision's clause — its questions are asked once per round.
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

      -- A call with two $labels, each satisfied by a labelled block below.
      -- Bound, never lifted: a bang has nowhere to put the fences.
      second <- library.judged patch $rubric $context
      ```rubric
          A patch passes when it is minimal, tested, and reversible.
          Nothing else counts.
      ```
      ```context
          {library.guide}
          You have already reviewed this patch once; this is the second reading.
      ```

      case second {
        approved {

          -- A bang in an `if` subject: the question is written where the
          -- decision is, and it is asked once, before the branch.
          if !(ask person "owner" ```
              Apply this patch?
              {patch}
              {library.flagSpec}
          ```) {
            library.applied patch

            -- A nested bang. The inner question is lifted first (a bang's own
            -- bangs come before it), and its answer is `summarised`'s
            -- `verdict` parameter; the outer answer is `filed`'s text. Both
            -- lifts stay inside this arm, so both are asked only on this path.
            library.filed !(library.summarised patch !(ask model "judge" ```
                Did this patch land cleanly?
                {library.verdictSpec}
            ```))
          } else { stop }
        }
        objected { library.filed !(library.summarised patch second) }
        no answer { stop }
      }
    }

    unsettled { stop }
  }
}
```

**Feature coverage, checked item by item against the owner's list:**

| Feature | Where |
|---|---|
| do-notation result (`answer` gone) | every function in `library.wf` |
| bang lifting | `if !(ask person "owner" …)` |
| nested bang | `library.filed !(library.summarised patch !(ask model "judge" …))` |
| default-text parameters | all six functions |
| a `verdict` parameter, annotated | `summarised (patch, finding : verdict)` |
| functions, value and `-> receipt` | `drafted`/`reviewed`/`judged`/`summarised`; `applied`/`filed` |
| imports and dotted names | `import library`; `library.guide`, `library.drafted`, … |
| `$labels` | `library.judged patch $rubric $context` |
| trailing blocks | `library.drafted library.guide aim ```…``` ` |
| `revising` with `as` and `at most n amendments` | the loop |
| `panel, all must approve` | `reviewed` |
| `if` / verdict `case` / `settled`-`unsettled` case | all three present |
| `known here` | first statement of the workflow |
| `independent draw` | third panel member of `reviewed` |
| defines, local and imported | `aim`; `library.spec`, `library.verdictSpec`, `library.flagSpec` |
| the `served by` model override | `drafted`, and the amend clause |
| `stop` | three arms |

Not covered, and deliberately: `at least n must approve` (the panel menu ships
entry one only — acat-f10), and every construct round 17 refuses.

**Two lexer facts this pair depends on**, both worth naming because they are the
difference between a showcase and a bug report: the `if` subject's fence closes
with ```` ```) ```` and the nested bang's with ```` ```)) ````. Neither lexes
without D19 (§2.5); the second also confirms that `fenceCloses` returning the
characters *at* the punctuation is what makes nested closes work without further
care.

### 8.5 Fixture migration: drop the binder in place

The draft proposed keeping `fnsPre` at eleven lines by "replacing each
`answer x` line with a comment line". That does not work, on three counts, and
the corrected trick is simpler than the broken one.

*Why the comment trick fails:* it preserves line counts but not columns
(`  answer d` becoming a comment while `d <- ask …` becomes `ask …` shifts every
column on that line), it does not preserve `answerPos`, and it leaves the
fixture's body ending in a *binding* — the shape this very round refuses.

**The trick, restated: replace `answer x` by `x`, in place.** Same line, same
indentation. `answerPos` moves from the `answer` keyword at column 3 to the bare
name at column 3 — identical. Every dependent position is unmoved, and only
message *text* changes.

Three shared fixtures, not one — the draft listed only the first:

| Fixture | `test/DslSmoke.lean` | Constraint | Edit |
|---|---|---|---|
| `fnsPre` | `:74–82` | **eleven lines**, so an appended workflow always begins at line 12 | three `answer x` lines → `x` |
| `libOk` | `:86–91` | **six lines**, and it *ends with an annotated priming binding* — the fixture that pins §1.1's priming exemption | one `answer d` line → `d` |
| `chain n` | `:95–101` | `f1` four lines, each later link five, so `f n`'s header sits at line `5n − 5` for `n ≥ 2`; `:1256` pins `"65:1: `f14` elaborates to 8192 questions"` | one generated `answer x` line per link → `x` |

Add one battery case pinning `chain`'s geometry directly — a one-link chain
whose header position is asserted — so the next round that touches a fixture is
told immediately rather than through a distant expectation.

The ~30 inline body fixtures take the same in-place edit.

### 8.6 Battery churn (`test/DslSmoke.lean`, 201 cases)

Two corrections to the draft's arithmetic before the table: `batteryCasesM` is
**11** module cases, not 32 (`:686`, counted), and the §1.5 assertion nit
**flips an accepted case** that the draft's table did not list.

| Category | Count | Note |
|---|---|---|
| cases whose source spells `answer` in a body | ~12 | in-place edit per §8.5 |
| `fnsPre`, `libOk`, `chain` | 3 fixtures | in-place edit; **every position preserved**, including `:681`'s `3:3` and `:1256`'s `65:1` |
| refusals deleted | 2 | "a value function with no answer"; "a procedure with an answer" — replaced by the new final-statement refusals, tested at the same sites |
| refusals reworded (position preserved, text changes) | 3 | `checkFn`'s terminal (`:679–681`); `bodyBindKind`'s hint; the hand-built `answer` guard |
| the two cases quoting `stmtWords` verbatim | 2 | `answer` leaves the list |
| the reversed "a call is not an argument" message | 1 | new wording, same trigger |
| **flip, accepted → refused** | 1 | `:511–513` "a known here is a whole block body" — **only if Q2 is taken**; rewrite to `if ok { known here: ok  stop } else { stop }` and add the refusal as a new case |
| **new**: `answer` migration diagnosis (D20) | 1 | pinned at the word, so the release that deletes it is told |
| **new**: bang accepted — argument, nested argument (post-order), `if` subject, `case` subject, in a priming, in an arm | 6 | |
| **new**: trace order — `f !(judged !(A) r) !(B)` gives A, judged, B | 1 | via `codesOf`/`promptAt`, as at section 9g |
| **new**: bang refused — `!x`, whole statement, whole rhs, final position, in a prompt, panel member, `revising` subject, **review clause (D15)**, **amend clause (D15)**, `$label` inside, in a `define`, bare `f (ask q)` | 12 | whole-diagnosis match, as the battery requires |
| **new**: trailing bind refused — workflow block, arm, value body | 3 | and one *accepted*: a priming ending in an annotated binding (§1.1) |
| **new**: bare name as a block's final, refused | 1 | the §6 grammar repair |
| **new**: `-> receipt` body ending in a statement call (D17) | 1 | the no-lift clause |
| **new**: D16 — a defaulted parameter, an annotated `verdict` parameter, `(verdict)` as a text parameter named verdict, `flag`/`receipt` still refused | 4 | |
| **new**: D19 — a fence closed by `)` inside a bang; a fence closed with a trailing `--` comment | 2 | the drift, pinned for the first time |
| **new**: `known here` with live temporaries; `isTemp` at each of the seven quoting sites | 8 | §2.4; the draft budgeted two |
| **new**: D10 — a library priming containing a bang, imported and run, trace equals the hand-bound spelling | 1 | the qualification bug, pinned |
| **new** semantic section: two identical bangs — one answer, two events, `billFresh` 2 / `billMemo` 1 | 1 | the sharing rule, executed |
| **new**: `chain` geometry pinned directly | 1 | §8.5 |
| unchanged | ~163 | including all eight `known here` cases, byte for byte (§2.4) |

Net: roughly **−2 / +42 cases**, ~23 edited, one flipped (Q2-dependent), and no
position churn given the in-place fixture edit. The eleven module cases are
affected only through `library.wf`'s rewrite, which changes no diagnosis.

### 8.7 Pins and other tests

* `DslFlagship`: nothing (§7.5).
* `DslSmoke`'s file-reading section (`:1236–1250`): still reads
  `example/library.wf` and `example/harden-imported.wf` and expects `"ok"` from
  both — unchanged outcome under the §8.4 rewrite, re-run rather than assumed.
* `CliSmoke`: `plan` of the imported flagship still prints "house style guide"
  (`:229`) — the priming's words are unchanged; `run` still exits 0 (`:230`);
  `expectedApply = 7` (`:113`) and `expectedRefuse = 6` (`:123`) are about
  `harden.wf`, untouched. `example/ill-typed.wf:11:18:` (`:254`) holds because
  of §8.3, **and only because of it**. No CLI expectation changes.
* `McpSmoke`, `AcpSmoke`, `ExecSmoke`, `Pollution`: no DSL surface in their
  fixtures beyond what is listed.

### 8.8 Docs

* `GRAMMAR.md`: a round-17 note in the style of rounds 12/13/16; the grammar
  block replaced by §6; rule 11 rewritten (the act is derived, at the kind its
  position imposes, and a value call in statement position is refused); rule 1
  restated (`stop` is one form of a block's final); a new rule — **the two
  divergences from Idris, sharing and scope** — which is the one piece of round
  17 a reader must not discover by experiment.
* `doc/dsl-guide.html`: §Three (bindings) gains the do-notation paragraph and
  the bang, with the rule of thumb from §2.6; §Four loses the act's own
  paragraph and keeps its two honest limits; §Seven (functions) loses `answer`
  and gains D16, including the `(verdict)` quirk; the refusal table gains rows
  for D15, D18, the bang refusals and the bare-parenthesis message, and loses
  two; §Nine (what is guaranteed) gains both divergences, with `independent
  draw` promoted to sit beside them (§3.10).
* `block-syntax.md`: no change — D19 makes the implementation match what this
  file already says. Add a line recording that rule 2's `)` and comment clauses
  were unimplemented from the start and were pinned in round 17.
* `ROUNDS.md`: one paragraph, round 17.

### 8.9 Honest estimates

| Piece | Estimate |
|---|---|
| `Parse.lean` lifting pass, D15/D17/D18 refusals, D16, D19, D20 | ~1½ days |
| `Check.lean` two clauses + `isTemp`/`showName` at seven sites + three rewordings | ~2 hours |
| battery: in-place fixture edits, ~42 new cases, whole-diagnosis matching | ~1 day |
| examples (the pair, `ill-typed.wf`) + docs | ~half a day |
| re-elaboration risk | **near zero** — `Dsl.lean` and `DslFlagship.lean` are not edited; the ~107 s module and the nine kernel proofs are not recompiled for content |

**Total: three focused days**, up from the draft's two-to-three, with the extra
half-day accounted for by D15, D19, D16 and the seven-site sweep the attack pass
found. The risk stays concentrated in one file. That concentration is the point
of D2, and if it turns out to be false — if `Raw` has to move after all — the
honest response is to reopen D2 before writing the parser, not to patch around
it.

---

## 9. Questions for the owner

Three decisions in this document are not the author's to make. Each is stated in
two sentences, with a recommendation.

**Q1 — the trailing-binding refusal in workflow blocks and arms (D18).** For
function bodies the refusal is settled: nothing downstream exists at all, so
`drop the x <-` is always the fix. For workflow blocks and arms it *removes an
accepted program shape* — `x : text <- ask …` as a block's last statement is
legal today — and the derivation offered for it ("the do-rule gives them one
wording") is a reason to spell the two refusals alike, not by itself a reason to
add the second.
*Recommendation: take it.* It flips no existing example (`harden.wf` ends in a
`case`; `hello.wf` ends in an act; `ill-typed.wf` is repaired anyway in §8.3),
and a binding whose name nothing can consume is the shape this language refuses
everywhere else. But it is a deliberate narrowing, so it should be chosen rather
than derived.

**Q2 — assertion transparency (§1.5).** Today a block may end with
`known here: x }`, which checks and elaborates to `ret`; making assertions
transparent to the do-rule would require such a block to end with `stop`, on the
grounds that a path that does nothing should say so. One battery case flips from
accepted to refused (`test/DslSmoke.lean:511–513`), and no example file is
affected.
*Recommendation: take it, in the same round.* It closes a real hole in "a path
that does nothing says so", the diagnosis writes itself (*"a `known here`
asserts and does nothing; a block that does nothing says `stop`"*), and the cost
is one fixture and one new case. If it is deferred, defer it explicitly — it is
the kind of nit that becomes unfixable once someone's program depends on it.

**Q3 — how long the `answer` migration diagnosis lives (D20).** Deleting the
`answer` clause and removing `answer` from `stmtWords` in one step gives every
existing program in the wild the worst diagnosis in the language ("expected
`<-`" at the token *after* `answer`, naming neither the word nor the fix), so one
clause is kept at the word: *"`answer` is deleted: the last statement of a body
is its answer — drop this line."* The question is whether it comes out one
release later or stays permanently.
*Recommendation: one release, with the battery case pinned so the release that
deletes it is told.* The word is short and the mistake is a legacy one, not a
recurring authoring error — unlike, say, the bare-parenthesis message (§2.1),
which is a *new* mistake the feature creates and which should stay forever.

---

## 10. What round 17 does not do

* It does not give the language expressions. The defence is not "there are no
  operators" — `f !(g !(h x))` is an expression tree by any reading a reviewer
  will apply, and pointing at the absence of arithmetic invites the objection
  rather than answering it. The defence is §2.1's rule: **a bang stands only
  where a name may stand**, so every value still flows through a binder or a
  bang whose own text is right there. "Who can see what" is still answered by
  reading one statement, which is the property rule 3 exists to protect.
* It does not touch `dyn`, the four kinds, the panel menu, the loop's
  semantics, or the permission model. D15 *narrows* the loop's syntax; it adds
  nothing to it.
* It does not make anything shorter that was not already redundant. The audit
  found five elidable things (`answer`, the one-use passed binder, the trailing
  binder, `answer` in `stmtWords`, and the `: text` parameter annotation) and
  refused to invent a sixth.
* It does not raise the rung. Every lifted bind is a bind; `level ≤ branch`
  holds by the same proof, for the same reason, with the same lemma.
* It does not move the flagship. `example/harden.wf` is byte-identical, its
  `flagshipRaw` is not re-transcribed, and the nine `decide +kernel` results are
  not recomputed — which is the strongest single thing this design has to say
  for itself.
