> **Superseded.** This is the pre-attack draft, kept for the record. Two of its
> claims are fatal (the §6 grammar does not derive the pinned flagship; the §3.2
> worked example does not lex) and forty more were corrected by the adversarial
> pass. Read `expr-design.md` beside this file instead.

# Round seventeen: the do-notation reading, bang lifting, and the noise audit

*Draft of record for round seventeen, 2026-08-15. Written against
`GRAMMAR.md` (the design of record, rounds 10–16), `doc/dsl-guide.html`,
`example/{library,harden-imported,harden,hello}.wf`, and the implementation in
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean` + `Agentic/Core/Dsl.lean`. Where
this file and `GRAMMAR.md` disagree, `GRAMMAR.md` is still the record until
this one is approved.*

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
an argument" (parentheses are what make it safe).

The whole of round 17 is implementable as a **lifting pass inside the
parser**. `Raw` does not change, `Check` changes in two small places, and
**not one level lemma or kernel proof restates**. That is the headline
argument, and §7 defends it clause by clause.

### Decisions taken in this document

| # | Question | Decision |
|---|---|---|
| D1 | `answer` | **Deleted.** The last statement is the result. |
| D2 | Desugar level | **Parser-level**, into today's `Raw`; the two leaks are named and closed in §2.4. |
| D3 | Where `!` may stand | **Exactly where a name may stand, outside prompt text**: call arguments (any depth), `if` subject, verdict-`case` subject. |
| D4 | `!x` on a bare name | **Refused** — a name is already a value; `!` would read as "ask again", which is `independent draw`. |
| D5 | `!(…)` as a whole statement / whole right-hand side / whole final expression | **Refused** — the bang must be a proper subterm; there is one spelling for one thing. |
| D6 | `!` inside prompt text or a `{hole}` | **Refused.** `!` is prose inside a prompt, and prompts are byte-literal. §2.6 presents the alternative honestly. |
| D7 | `!` as a panel member | **Refused** — a panel's members are questions; the monoid and the cost model are stated over questions. |
| D8 | `!` as a `revising` subject | **Refused** on taste (the loop is *about* a value the reader can name), with a technical bonus: it is the one name position whose grounding could fail. |
| D9 | `$label` fences inside a bang | **Refused** — a labelled block follows a call written as a statement; lift short calls, bind long ones. |
| D10 | Temporary names | `!` + the bang's own `line:col`, module-qualified in a library. No counter, no state, unspellable, and the position is recoverable for diagnoses. |
| D11 | Evaluation order | Left to right, **innermost first**, lifted to the head of the nearest enclosing statement, **never across a `{`**. |
| D12 | Sharing | Two identical bangs are two binders and **one answer**. Named loudly as a divergence from Idris (§5.3). |
| D13 | Function declaration syntax | **No change.** Recommended against, not churned (§3.9). |
| D14 | `amend <carrier>`, `as <carrier>`, `stop`, `known here` | **All kept**, each for a reason tied to the owner's own history (§3). |

---

## 1. The do-notation reading, made official

### 1.1 The rule

> **A block is a do-block over `Plan`.** Its statements are steps; the last
> step is the block's result; a step written without `x <-` binds nothing and
> its answer is discarded; and a step's kind is fixed by its position.

Three spellings, one construct:

```
x <- source        -- a step whose answer is named
source             -- a step whose binder is elided (today's "act")
source             -- …and in final position, the block's result
```

That the same text means "discard" in the middle and "result" at the end is
not an ambiguity to be resolved by a keyword. It is this language's oldest
stated principle — *there are no reserved words: positions decide* — applied
to the one place it had not yet been applied. Haskell and Idris both settle it
exactly this way, and neither needs a word for it.

### 1.2 Value function bodies

`answer` is deleted. A value function's body is steps followed by a **final
expression at the declared result kind**:

```
function drafted (guide : text, goal : text, shape : text) -> text {
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

A **final binding is refused**, with the fix in the diagnosis:

```
the last statement of a body is its answer, and a binding is not one:
drop the `x <-`
```

The refusal is total (nothing downstream can ever use a name introduced by the
last statement), so "drop the binder" is always the correct fix, and the
diagnosis can say so without hedging.

Kinds: the final expression is elaborated at the **declared result**, imposed,
never inferred. `-> flag` bodies therefore work without an annotation, which
today they only get via the `answer`-grounding clause of `bodyBindKind`
(`Check.lean:754`).

### 1.3 `-> receipt` bodies: why the old ambiguity dissolves

Today the parser carries two ad-hoc rules that exist only to decide whether a
body's last act is a step or an answer: *"a value function ends with
`answer <name>`"* (`Parse.lean:1034`) and *"a `-> receipt` function's body just
ends: the end of the block is the answer, and there is nothing to name"*
(`Parse.lean:1038`). Both are consequences of an unstated do-rule, and both go
away when it is stated.

At `receipt`, "the last step's answer is discarded and the block returns `()`"
and "the last step **is** the result" are the same term:

* discarded: `bindForm .ack … (Plan.sub (Plan.ret (fun _ => ())) Sub.wk)`
  = `.askC .ack q (.ret (fun _ => ()))`;
* result: `askPlan .ack …` = `Plan.askC1 .ack q`
  = `.askC .ack q (.ret (Expr.var .here))`.

`El .ack = Unit`, and Lean's definitional eta for structures gives
`Env.head δ ≡ ()`. The two continuations are **definitionally equal**. There is
nothing to decide, so the language stops deciding it, and the two refusals
above are deleted rather than reworded.

`example/library.wf`'s `applied` is unchanged by round 17 for exactly this
reason: its last statement is an act, an act at `receipt` is the receipt, and
that was already true.

### 1.4 The workflow block

`workflow { … }` is a do-block at `Plan [] Unit`. **Nothing changes
observably**, and the reason is §1.3's equation: every statement form's
discarded result is `Unit`, the block's result is `Unit`, and a trailing act
already elaborates to the term that "the act is the result" would produce. The
pinned flagship (`example/harden.wf` → `flagshipRaw` → nine `decide +kernel`
proofs) is untouched, byte for byte.

One behavior does change: a **trailing binding in a workflow block** is now
refused, with the same message as §1.2. Today such a binding is accepted when
annotated (`x : text <- ask …` as the last statement), binds a name nothing
can consume, and asks a question whose answer is thrown away silently. That is
precisely the shape the language refuses everywhere else — the round-11 note
already records the sibling case ("a *bound* ask may still be annotated
`: receipt`, which binds a name nothing can consume — a refusal to add"). Round
17 adds both refusals, because the do-reading gives them one wording.

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

One nit, cheap to fix now: **assertions are transparent** to the rule. A
`known here:` is not a step, so it cannot be a block's result; a block whose
last step is an assertion must still end with `stop`. (Today `known here: x }`
is quietly accepted as a block that does nothing without saying so — a small
hole in "a path that does nothing says so".)

---

## 2. Bang notation, exactly

### 2.1 The rule

```
bang ::= "!" "(" source ")"        source ::= ask | panel | call
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
| `case x { settled … }` subject | a pending loop result | no — a bang cannot produce one |

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

A bang **outside any statement** is unreachable by construction: every block
and body is a list of statements, so every expression sits inside one. The
parser still needs the refusal for the header positions where an expression
cannot appear at all (`define name = !(…)`, a parameter list, an `import`);
there it falls out of the existing "expected …" diagnoses and needs no new
wording.

### 2.2 Desugaring

For a statement `S` containing bangs `b₁ … bₖ` enumerated **left to right,
innermost first**:

```
⟦S⟧  =  t₁ <- s₁
        t₂ <- s₂
        …
        tₖ <- sₖ
        S[bᵢ := tᵢ]
```

where `sᵢ` is `bᵢ`'s parenthesized source and `tᵢ` is a fresh binder. Nested
example, from the owner's directive:

```
verdict <- judged !(drafted g a) r
```
```
!17:19 <- drafted g a
verdict <- judged !17:19 r
```

and doubly nested, `!(judged !(drafted g a) r)` in an argument position of
`h`:

```
!17:24 <- drafted g a
!17:15 <- judged !17:24 r
h !17:15
```

Innermost first is forced: the outer call cannot be built until its argument
has a name. Left to right is the reading order, and §5.1 makes it the trace
order.

**Lifting never crosses a `{`.** "The nearest enclosing do-statement" is a
statement *of the same block*, so a bang inside an arm lifts to the head of the
statement inside that arm, and its question is asked only on that path. The
per-branch cost tree keeps its shape; `blockAsks`'s branching clauses
(`Check.lean:888`) need no change. A bang in an `if` subject, by contrast,
lifts *before* the `if` and is asked once on every path — which is the right
reading of `if !(ask person "owner" "…")`.

### 2.3 The desugar level: parser, and why

**Decision: parser-level, emitting today's `Raw`.** The argument, in the order
it convinced me:

1. **`Raw` does not change, so no theorem restates.** `desugar : Surface → Raw`
   lands in the *image of what is already writable*: every `.bind` it emits is
   a `.bind` a hand-written program could have written, differing only in the
   binder's spelling. Therefore every property proved of `Raw` today —
   `checkBlock_level_le`, `checkBody_level_le`, `bindForm_level_le`,
   `checkProgram_level_le`, `parseAndCheck_level_le`, `overRevised_sound`,
   `checkBlock_caseVerdict_arms`, `blockAsks`'s recurrence, the nine
   `decide +kernel` flagship results — holds of desugared programs *with no new
   lemma and no re-elaboration*. This is not a saving of effort; it is a
   saving of risk, on a module that costs ~107 s to elaborate and whose proofs
   are kernel computations.
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
   says it is a total one. (If a future bang position were ever *not* a ground
   site, `PEnv` would have to gain parameter kinds. Recorded as the condition
   under which this decision would need revisiting.)

The alternative — **checker-level, graft-based**, like today's panel and call
binds — was seriously considered, and it does buy one real thing: `Bindings`
never carries a name no source can write, because the argument's expression
could be handed to `argExpr` directly as `Expr.var .here` instead of being
looked up by name. Its costs:

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
* Level lemmas: `bindForm_level_le` already covers each lifted bind, so the
  proof burden is not large — but it *is* new proof about new clauses, where
  parser-level has zero.

Weighing: the checker-level route pays a change to the load-bearing type and
the calling convention to avoid two named, one-clause leaks. Parser-level, and
close the leaks.

### 2.4 The two leaks, and how each is closed

**Leak 1: unspellable temporaries must not reach `known here`.**
`checkBlock`'s `knownHere` clause (`Check.lean:534`) compares the asserted list
against `S.map (·.name)`. A temporary lifted before an earlier statement is
still in `S`, so `known here: library.guide` would be refused against a live
list containing `!12:20`.

*Close it:* the live list is the list of names **the author can write**.

```lean
let live := (S.map (·.name)).filter (fun n => !(n.any (· == '!')))
```

One line, one clause, no level lemma touched (the `knownHere` clause only
recurses). And it is the honest statement of what the assertion asserts: a
temporary is not a name, it is a position.

**Leak 2: diagnoses must not quote `!12:20`.** A kind clash on a lifted
argument would today read ``…`judged`'s parameter `patch` takes `text`, and
`!12:20` answers `verdict` ``.

*Close it:* one helper in `Check.lean`, used by the five diagnoses that quote a
bound name (`argExpr` ×2, `chunkExpr`, `ifFlag`, `caseVerdict`):

```lean
def showName (x : String) : String :=
  if x.any (· == '!') then "the lifted `!(…)`" else s!"`{x}`"
```

The position in the `CheckError` is already the bang's own position (the parser
writes the bang's `Pos` into the emitted `RawArg.name`), so the reader is
pointed at the `!` and told which parameter rejected it. Five message sites,
five battery cases.

**Not a leak, worth recording:** temporaries cannot reach `agent-cat plan`,
because `Plan` has no names at all — it is de Bruijn. They cannot reach a
prompt (D6). They cannot collide with a user name (`!` is not an identifier
character, so no source can spell one). They cannot collide with each other:
two bangs cannot begin at the same line and column, and in a library they are
qualified by the module exactly as binders are (`PEnv.q`, `qualRefs`), which is
what keeps a priming's temporaries distinct from an importer's after the splice.

### 2.5 What this costs the parser

`Token`: `'!'` joins `punctChars` (`Parse.lean:102`). That is the entire lexer
change, and it is safe precisely because prompt text is scanned as a single
token — see §2.6.

`stmtWords` (`Parse.lean:522`) **loses `answer`**: it no longer begins
anything, so a binder may be called `answer` again. Small, real, and exactly
the kind of thing the audit exists to find.

### 2.6 Bangs in prompts: refused, and the alternative stated fairly

**Refused.** Three reasons, in increasing order of decisiveness:

1. *Consumption stays consumption.* The language's rule 3 says there are two
   consumption sites and no third; a prompt that also *produces* questions
   would make "who can see what" require reading inside prompts, which is the
   scan the design sells.
2. *The rung stays decidable from the preamble.* `Prompt.closed` decides
   `askC` (batch) versus `ask` (pipeline) from the hole structure alone
   (`Syntax.lean:140`). A question nested inside another question's words does
   not break that computation, but it does break the *reader's* version of it:
   a closed question's words would contain an open question's answer.
3. **`!` is prose.** Prompts are byte-literal by round-8 decree — inside a
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
                                    -- BEFORE                          AFTER
function drafted (…) -> text {      d <- ask model "author" …          ask model "author" served by "deep" ```…```
                                    answer d                           (nothing)
}
function reviewed (…) -> verdict {  v <- panel, all must approve […]   panel, all must approve [ … ]
                                    answer v                           (nothing)
}
function judged (…) -> verdict {    v <- ask model "judge" ```…```     ask model "judge" ```…```
                                    answer v                           (nothing)
}
```

Six lines and three binder names deleted from a seventy-line file; the term is
unchanged. Full rewritten file in §8.1.

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
stops being a name whose kind is inferred from a use two lines later.

**`why` — keep the name.** It is consumed by `{why}` in the amend prompt, and
prompts refuse bangs (D6). This is the rule of thumb doing its work: `why` is
*spoken*, so it is named.

Score for the flagship-imported file: one of four one-use binders lifts. That
is the honest yield, and it is the right one — the language should make the
elision available, not mandatory.

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

The review binding (`why <- …`) cannot be elided either, per §3.2 — it is
spoken in the amend prompt. Recorded honestly: the loop is the one construct
where round 17 removes nothing.

### 3.5 `known here:` — **KEEP, optional**

Haskell has no analogue; the nearest is a type signature written for the
reader. It is opt-in, it is checked, it cannot rot, and §2.4 makes it immune to
temporaries. Nothing to change but that one filter.

### 3.6 `stop` — **KEEP the word**

`stop` is `pure ()`. Haskell writes `pure ()`, Idris the same. Keeping the word
costs one token and buys the round-9 rule *"a path that does nothing says
so"* — `{ }` stays unwritable. Under the new reading `stop` is simply the
final expression of a block at `Unit`, so it is no longer a special block
shape; it is a step like any other, which is a simplification of the *story*
even though the syntax is unchanged.

### 3.7 Statement asks — **KEEP the syntax, DELETE the concept**

The act is no longer a construct: it is a do-step with its binder elided, at
the kind its position imposes (`receipt`). The guide's story gets strictly
shorter — §Four of `doc/dsl-guide.html` currently spends a paragraph
introducing "the act" as a thing; it becomes a sentence in the do-notation
section plus the two honest limits (discard is not consequence; a receipt
verifies nothing), which are *about the receipt kind*, not about a construct.
The permission layer is unaffected: it keys on the receipt kind, and the kind
is still what statement position imposes.

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

**Recommendation: do not change.** Listed here because the directive asked for
every construct to be weighed, not because anything is wrong with it.

### 3.10 `independent draw n` — **KEEP, and promote it**

It is the *only* way to get a second opinion, and round 17 makes that more
visible rather than less: two identical bangs share one answer (§5.3), so
`independent draw` is what the author reaches for when they meant two. The
guide should place it immediately beside the bang rule, not three sections
away.

### 3.11 The `<-` arrow — **KEEP**

It is do-notation's own arrow, in Haskell, Idris, and here. Deleting it would
mean either `let`-style `=` (which would make binding look pure, and every
binding here is a question) or juxtaposition (which would collide with calls).
The lexer's stray-`<` diagnosis stays as it is.

### 3.12 Summary table

| Construct | Verdict | One-line justification |
|---|---|---|
| `answer x` | **delete** | right identity; identical term; do-blocks don't write it |
| one-use binder, passed/branched | **elide** via `!(…)` | Idris's bang, at the positions where a name already stands |
| one-use binder, spoken/read twice | **keep** | prompts refuse bangs; a value read twice needs a word |
| `amend <carrier>` | keep | checked redundancy; the back-edge was filed as fatal once already |
| `as <carrier>` | keep | forced by no-shadowing: the carrier is a different value |
| `at most n amendments` | keep | the bound is the unrolling, the limit and the price |
| `known here:` | keep | opt-in, checked, cannot rot; now filters temporaries |
| `stop` | keep the word | `{ }` stays unwritable; a path that does nothing says so |
| statement `ask` | keep syntax, drop the concept | a do-step with its binder elided |
| function header | **no change** | round-16 decision; `name : kind` stays where the reader looks |
| `panel, rule [ … ]` | keep | the rule belongs on the page; members are questions |
| `independent draw n` | keep, promote | the only fresh opinion; now load-bearing beside sharing |
| `<-` | keep | do-notation's arrow |
| trailing bind in any block | **refuse** | its answer has nowhere to go; the do-rule gives the wording |
| `answer` in `stmtWords` | **delete** | it no longer begins anything |

No re-skin is proposed: no new sigils beyond the single `!`, and every
construct still reads as a sentence.

---

## 4. Kind discipline under the sugar

### 4.1 The imposed-kind table

| Position | Kind | Source |
|---|---|---|
| call argument | the parameter's kind | `argExpr` / `checkArgs` |
| final expression of a body | the declared result | `checkFn`'s terminal |
| final statement of a `Unit` block | `receipt` | `El .ack = Unit` |
| discarded statement | `receipt` | `bindForm fns .ack` |
| panel member | `verdict` | `checkMembers` |
| review binding of a loop | `verdict` | `rhsPlan … .verdict` |
| loop carrier / `settled` binder | the subject's kind | `Pend.code` |
| `if` subject | `flag` | `bnd.at? .flag` |
| verdict `case` subject | `verdict` | `bnd.at? .verdict` |
| `{x}` hole | `text`, or `verdict` by its one canonical rendering | `chunkExpr` |

Named ask-binds keep first-ground-use inference and the round-8 honest side
condition (an annotation is required for any constraint component that never
touches a ground site).

### 4.2 Why anonymity makes inference strictly simpler

A bang's binder is **anonymous, used exactly once, at the position it was
lifted from, which is always a ground site**. Three consequences, all
strengthenings:

1. **The ground-free refusal can never fire on a temporary.** Inference for a
   temporary is total by construction, so the one refusal that authors find
   hard to act on (`nothing fixes what kind of answer x names`) is unreachable
   for the construct that most often replaces a binding.
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
   case is different.

Net: the sugar moves work *out* of inference. Round 17 does not make the kind
system cleverer; it shrinks the domain on which cleverness is needed.

---

## 5. Trace and cost

### 5.1 Evaluation order is lifting order, and that is the trace order

> **Rule.** The questions a statement asks are put in the order the statement's
> `!`s are lifted — innermost first, then left to right — followed by the
> statement's own question. That order is the order of the events in the trace,
> and it is decided entirely by the source text.

Nothing here is new machinery: after desugaring, the lifted binds *are* the
preceding statements, and the trace order of a sequence of statements is
already the order they are written. The rule is worth stating because it is
what a reader needs in order to predict a transcript without desugaring by
hand.

### 5.2 The recurrences

`blockAsks` / `bodyAsks` / `rhsAsks` (`Check.lean:860–890`) are **unchanged**,
because they run over `Raw`, and `Raw` is what the parser emits after lifting.
`maxQuestions` is unchanged. For readers of the *surface*, the derived
recurrence is:

```
asks(stmt)      = Σᵢ asks(sᵢ)  +  asks(head)        -- sᵢ the lifted sources, in order
asks(if b … …)  = asks(b's bangs) + asks(yes) + asks(no)
asks(arm)       = as before; a bang inside an arm counts inside that arm only
```

The second and third lines are the content of "lifting never crosses a `{`"
(§2.2): a bang in a subject is priced once, before the branch; a bang in an arm
is priced in that arm alone. So the per-branch cost enumeration — the twelfth
of the survey's differentiators, and the reason `agent-cat cost` exists — keeps
its shape exactly.

### 5.3 Sharing: the divergence from Idris, stated as a language rule

> **The shared-answer rule.** The world is a function of the question. Two
> questions with the same shape and the same words are **one answer** in every
> world. A bang binds; it does not resample. `f !(ask q) !(ask q)` lifts two
> binders that receive the *same* answer. **In Idris the two bangs could
> differ; here they cannot.** A fresh opinion is a different question, and the
> way to write one is `independent draw n`.

Worked example. Given `compare (a : text, b : text) -> receipt`:

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

This rule is not a consequence of the bang; it is the language's existing
semantics (*"sharing is by binding: asking twice is one answer"*) meeting a
notation borrowed from a language whose bang means something else. It must be
stated at the point of borrowing, in the guide, in the grammar, and in the
diagnosis for `!x` (D4) — which is why that refusal names `independent draw`.

---

## 6. Grammar: the EBNF delta

Against `GRAMMAR.md` §Grammar. **Deleted** productions struck, **added** marked.

```
                                   -- DELETED ------------------------------
body       ::= { bodystmt } "answer" name
             | { bodystmt }
bodystmt   ::= name [ ":" kind ] "<-" ( ask | panel | call )
             | ask
             | call
argument   ::= name | text | "$" label       -- "a call is not an argument: bind it"

                                   -- ADDED / REPLACED ---------------------
body       ::= { step } final                -- a do-block; the final step is the result

block      ::= "{" { step } final "}"
             | "{" "stop" "}"

step       ::= [ name [ ":" kind ] "<-" ] source     -- bind, or bind-and-discard
             | "if" subject block "else" block
             | "case" subject "{" arms "}"
             | "known" "here" ":" ( "nothing" | name { "," name } )   -- an assertion, not a step

final      ::= expr                          -- at the block's kind; `stop` at Unit

expr       ::= name | source                 -- a bang is refused as a whole expr (D5)
subject    ::= name | bang                   -- `if` and verdict-`case` heads
argument   ::= name | text | "$" label | bang            -- CHANGED
bang       ::= "!" "(" source' ")"                        -- NEW
source'    ::= ask | panel | call            -- no `revising`, no `$label` inside (D9)

source     ::= ask | panel | call | loop     -- `loop` only right of `<-`, as before
primer     ::= name ":" kind "<-" source' | source'       -- bangs legal; §4.2
```

Unchanged: `program`, `library`, `import`, `define`, `function`, `param`,
`call`, `labelledblock`, `ask`, `rule`, `loop`, `arms`, `kind`, `text`,
`plainstring`, and every rule in "The rules the grammar does not carry" except
rule 11 (the act is now derived — same behavior, shorter statement) and rule 1
(`stop` is now a final expression, not a special block shape).

**Tokens.** One new: `!`, added to `punctChars`. No new keyword. `answer`
leaves `stmtWords`.

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
* **The reversed diagnosis.** `Parse.lean:685` becomes:
  ``a call is not an argument as written: bind it above — `y <- judged …` — or
  lift it here: `!(judged …)` ``. Same site, same trigger, two fixes named.
* **`$label` fences** are collected after the call's arguments, as today. A
  `$label` inside a bang is refused at the `$` with: *"a labelled block follows
  a call written as a statement; bind this call and pass its name"* (D9).
* **Trailing blocks** are unaffected: a fenced block is one token, so
  `!(library.drafted g aim ```…```)` reads as head, two names, one block,
  close paren.
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
binding by the parser; `none` for a `-> receipt` body". (An optional tidy:
rename the field to `resultOf`. Free — no `flagshipRaw` mentions it, the
flagship has no functions.)

### 7.2 `Parse.lean` — where the work is

| Clause | Change |
|---|---|
| `punctChars` | `'!'` added |
| `stmtWords` | `"answer"` removed |
| new `parseBang` | `!` `(` `parseRhs` `)`; refuses `revising`, refuses a bare name, refuses `$label` inside |
| `parseArgTokens` | accepts a bang as an argument; returns it as a *pending lift* alongside `PArg` |
| new `liftStmt` | given the pending lifts of a statement and the statement, emits `.bind tⱼ none (.rhs sⱼ) …` in order, innermost-first, then the statement |
| `parseBlockFrom` | `if` / `case` heads accept a `subject` (name or bang); the final-statement refusal for a trailing `x <- …`; every statement routed through `liftStmt` |
| `parseFnBody` | `answer` clause **deleted**; the last statement is parsed as the body's result — a name becomes `answer := some x` directly, a source is lifted to `!L:C <- source` with `answer := some "!L:C"`; a trailing binding refused |
| `parsePrimer` | statements routed through `liftStmt`; the annotation requirement applies to *named* bindings only (§4.2) |
| `resolveFn` diagnosis | reversed message (§6.1) |

Estimated size: **+120 / −40 lines**, all mechanical, all in one file.

The lifting function is worth writing down as the module's central claim:

```
desugar : Surface → Raw          -- total, and its image ⊆ {Raw writable today}
```

Every `.bind` it introduces is a `.bind` a hand-written program could have
written. **That is the whole theorem-survival argument**, and everything below
is a corollary.

### 7.3 `Check.lean` — two clauses and five messages

1. `knownHere`: filter unwritable names from `live` (§2.4, leak 1). The clause
   recurses and builds no plan node; no lemma mentions it.
2. `showName` helper, used at five diagnosis sites (§2.4, leak 2). Diagnoses
   are `String`s inside `CheckError`; no theorem is stated about their content
   except the battery's fixtures.
3. The two body refusals in `parseFnBody` disappear; their `Check`-side
   counterpart (`checkFn`'s *"a value function ends with `answer <name>`"*,
   `Check.lean:845`) stays as the hand-built-`Raw` guard, exactly as
   `check_panel_nil` does for empty panels. **It becomes unreachable from
   source text**, which is a documented category the battery already has (see
   `DslSmoke.lean`'s exception 2), and it is tested against a hand-built `Raw`
   the same way.

Nothing else. In particular `checkBody`'s terminal does **not** become an
imposed-kind source: in `Raw` it is still `answer <name>`, where the name is
the temporary the parser lifted, and `bodyBindKind`'s existing `answer`-clause
grounds that temporary at the declared result. The imposed kind is real — it is
just imposed one node earlier than the hypothesis in the brief supposed, and
the node it is imposed at is one that already exists.

### 7.4 `Dsl.lean` — no change

`askPlan_level_le`, `checkMembers_level_le`, `FnLevel`, `callPlan_level_le`,
`rhsPlan_level_le`, `bindForm_level_le`, `PendLevel`, `checkBlock_level_le`,
`checkBody_level_le`, `checkFn_level_le`, `checkFnsList_fnLevel`,
`checkProgram_level_le`, `parseAndCheckProgramWith_level_le`,
**`parseAndCheck_level_le`** — every one restates verbatim, because each is a
statement about `Raw`/`Fns`/`Plan` and none of those move. In particular the
brief's expectation that "bang elaboration reuses `bindForm`/`graft` so
`bindForm_level_le` covers it" is right, and stronger than expected: bang
elaboration reuses `bindForm` *because it reuses the `.bind` constructor*, so
`bindForm_level_le` covers it without being invoked in a new place.

`overRevised_sound`, `checkProgram_overRevised`, `checkProgram_oversized`,
`checkProgram_of_within`, `checkBlock_caseVerdict_arms`, `askShape_draw`:
unchanged.

### 7.5 `DslFlagship.lean` — no change, and this is the pin

`flagshipSource := include_str "../../example/harden.wf"`.
**`example/harden.wf` is not rewritten** (§8.3). It contains no `answer` — it
is a single-file program with no functions — and it is not rewritten to use
bangs. Therefore:

* `flagshipRaw` is unchanged, character for character;
* `parse flagshipSource = .ok flagshipRaw` re-verifies with no re-baseline;
* `flagshipPlan`, `check_flagshipRaw`, `flagshipRaw_accepted`,
  `level_flagshipPlan` (= `branch`), `card_leaves_flagship` (9),
  `minFold_flagship` (5), `maxFold_flagship` (15), the four `trace_flagship_*`
  and four `bill_flagship_*` results, `flagship_bill_le`,
  `minFold_flagship_le_bill` — **all nine `decide +kernel` proofs recompute at
  unchanged cost, or rather are not recomputed at all**, since neither the term
  nor the type moved.

This is the single largest argument for D2 (parser-level), and it is why the
temptation to show off the bang in the flagship should be refused: the flagship
is a pin first and a showcase second.

### 7.6 Kernel and axiom policy

Untouched. No `native_decide`. The lexer still never runs in the kernel — the
lifting pass is part of parsing, so it inherits that. `parse` pins stay
runtime, as `DslFlagship`'s note requires. No new `Decidable` instances, no new
`deriving`.

---

## 8. Migration

### 8.1 `example/library.wf` (rewritten)

```
-- A library: standing context, shared words, and reusable questions. It has
-- no `workflow` block, so it is imported, not run; its top-level statements
-- are the priming, and they are the first questions of every program that
-- imports it. Its top-level bindings are annotated, because a library's
-- questions must not depend on who imports it.

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

function drafted (guide : text, goal : text, shape : text) -> text {
  ask model "author" served by "deep" ```
      {guide}
      Draft a patch satisfying:
      {goal}
      {shape}
      Reply with a unified diff only.
  ```
}

function reviewed (guide : text, patch : text) -> verdict {
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
    ```
  ]
}

function judged (patch : text, rubric : text, context : text) -> verdict {
  ask model "judge" ```
      {context}
      Judge this patch against the rubric.
      {patch}
      {rubric}
      {verdictSpec}
  ```
}

-- A procedure: a reusable act sequence. It answers `receipt`, so it is called
-- as a statement and binds nothing. Its last act is its receipt.
function applied (patch : text) -> receipt {
  ask tool "apply" ```
      Apply:
      {patch}
      Write the patched file here, then reply DONE.
  ```
  ask tool "test" "Run the test suite, then reply with its last line."
}

-- The priming. Asked once, before anything an importer writes.
guide : text <- ask tool "cat" "Write out the house style guide, at most four short lines."

ask model "author" ```
    {guide}
    You are drafting patches for this codebase. Hold this style guide.
```
```

Six lines and three binder names gone; the elaborated table is identical.

### 8.2 `example/harden-imported.wf` (rewritten)

Only the `ok` binding changes (§3.2); `draft`, `why` and `second` stay named,
each for a reason the language enforces.

```
  ...
      case second {
        approved {
          if !(ask person "owner" ```
              Apply this patch?
              {patch}
              {library.flagSpec}
          ```) { library.applied patch } else { stop }
        }
        objected { stop }
        no answer { stop }
      }
  ...
```

### 8.3 `example/harden.wf`, `example/hello.wf`, `example/ill-typed.wf`

**`harden.wf`: not touched** (§7.5). It has no `answer`; its `ok` binding
*could* become a bang, and must not, because it is the kernel pin.

`hello.wf`: not touched (no `answer`, its trailing act is already the result).

`ill-typed.wf`: not touched by round 17 — it is refused at 11:18 by a kind
conflict, and no round-17 clause is involved. (The separate obligation from the
round-8 audit, to rebuild it around a genuine conflict, stands where it was.)

### 8.4 Battery churn (`test/DslSmoke.lean`, 201 cases)

Estimated, by category:

| Category | Count | Note |
|---|---|---|
| cases whose source spells `answer` in a body | ~12 | mechanical deletion of one line each |
| `fnsPre` (the shared eleven-line preamble) | 1 fixture | **keep it eleven lines** — replace each `answer x` line with a comment line, and every position in every dependent expectation is unmoved. Without this trick, ~35 expected diagnoses shift by 1–3 lines each |
| refusals deleted | 2 | "a value function with no answer"; "a procedure with an answer" — replaced by the new final-statement refusals, tested at the same sites |
| the two cases quoting `stmtWords` verbatim | 2 | `answer` leaves the list |
| the reversed "a call is not an argument" message | 1 | new wording, same trigger |
| **new**: bang accepted — argument, nested argument, `if` subject, `case` subject, in a priming, in an arm | 6 | |
| **new**: bang refused — `!x`, whole statement, whole rhs, final position, in a prompt, panel member, `revising` subject, `$label` inside, `!(revising …)` | 9 | one per refusal site, whole-diagnosis match as the battery requires |
| **new**: trailing bind refused — workflow block, arm, value body | 3 | |
| **new**: `known here` with live temporaries; a temporary named in a kind clash (`showName`) | 2 | the two leaks, pinned |
| **new** semantic section: two identical bangs — one answer, two events, `billFresh` 2 / `billMemo` 1 | 1 | the sharing rule, executed |
| unchanged | ~165 | |

Net: roughly **−2 / +21 cases**, ~15 edited, and no position churn if the
`fnsPre` line-count trick is used. `batteryCasesM` (the 32 module cases) is
affected only through `library.wf`'s rewrite, which changes no diagnosis.

### 8.5 Pins and other tests

* `DslFlagship`: nothing (§7.5).
* `DslSmoke`'s file-reading section: still reads `example/library.wf` and
  `example/harden-imported.wf` and expects `"ok"` — unchanged outcome.
* `CliSmoke`: `plan` of the imported flagship still prints "house style guide";
  `run` still exits 0; `expectedApply = 7` and `expectedRefuse` are about
  `harden.wf`, untouched. **No CLI expectation changes.**
* `McpSmoke`, `AcpSmoke`, `ExecSmoke`, `Pollution`: no DSL surface in their
  fixtures beyond what is listed.

### 8.6 Docs

* `GRAMMAR.md`: a round-17 note in the style of rounds 12/13/16; the grammar
  block replaced by §6; rule 11 rewritten (the act is derived); rule 1 restated
  (`stop` is a final expression); a new rule — **the shared-answer rule and the
  Idris divergence** — which is the one piece of round 17 a reader must not
  discover by experiment.
* `doc/dsl-guide.html`: §Three (bindings) gains the do-notation paragraph and
  the bang, with the rule of thumb from §2.6; §Four loses the act's own
  paragraph and keeps its two honest limits; §Seven (functions) loses `answer`;
  the refusal table gains four rows and loses two; §Nine (what is guaranteed)
  gains the sharing sentence.
* `ROUNDS.md`: one paragraph, round 17.

### 8.7 Honest estimates

| Piece | Estimate |
|---|---|
| `Parse.lean` lifting pass + refusals | ~1 day |
| `Check.lean` two clauses + `showName` | ~1 hour |
| battery: edits, new cases, whole-diagnosis matching | ~half a day |
| examples + docs | ~half a day |
| re-elaboration risk | **near zero** — `Dsl.lean` and `DslFlagship.lean` are not edited; the ~107 s module and the nine kernel proofs are not recompiled for content |

**Total: two to three focused days**, with the risk concentrated entirely in
one file. That concentration is the point of D2, and if it turns out to be
false — if `Raw` has to move after all — the honest response is to reopen D2
before writing the parser, not to patch around it.

---

## 9. What round 17 does not do

* It does not give the language expressions. `!(…)` produces no operator, no
  comparison, no arithmetic; rule 3 (two consumption sites, now three name
  positions) is intact, and "who can see what" is still answered by searching
  the page — the bang's own text is the question, right there.
* It does not touch `dyn`, the four kinds, the panel menu, the loop, or the
  permission model.
* It does not make anything shorter that was not already redundant. The audit
  found four elidable things (`answer`, the one-use passed binder, the trailing
  binder, `answer` in `stmtWords`) and refused to invent a fifth.
* It does not raise the rung. Every lifted bind is a bind; `level ≤ branch`
  holds by the same proof, for the same reason, with the same lemma.
