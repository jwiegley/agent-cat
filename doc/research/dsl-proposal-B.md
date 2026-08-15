# Proposal B — the do-notation reading

A design review and revision of the workflow surface in `Agentic/Core/Dsl/`,
answering the owner's criticism of `example/harden.wf`.

The standard this is written against is `example/HardenPatch.lean`: twelve lines
of `do`-notation that a reader with no glossary reads correctly on the first
pass. The claim of this proposal is that the same program can be written in a
first-order text language that reads the same way, with **fewer** words than the
present surface, and that the plan it elaborates to is unchanged to the byte.

Three laws are imposed and never bent:

1. **Every scope is delimited by braces.** Indentation is whitespace and means
   nothing.
2. **Every binder is visibly introduced where it comes into being, by a word
   that says a name is being introduced** — `let` for a name you bind to an
   answer you asked for, `given` for a name the construct hands you. There is no
   third way to bring a name into being, and no construct brings one into being
   silently.
3. **Every keyword says what it means, or does not exist.** Removed by this
   rule: `done`, `exhausted`, `accepted`, `upto`, `with` as the name of a clause,
   `->`, `@`, and the parenthesised pseudo-arguments `(patch)` and
   `(patch, why)`. (`with` survives only inside the English phrase
   `with at most 2 revisions`, where it is a preposition and not a construct.)

---

## 1. The flagship, before and after

### Before — `example/harden.wf` today

```
  revising draft upto 2

    check (patch) {
      panel [ … ]
    }

    with (patch, why) {
      @model "deep" ask text model "author" "…"
    }

    accepted (patch) {
      let ok = ask flag person "owner" "…"
      case ok {
        yes -> { act tool "apply" "…" }
        no  -> { done }
      }
    }

    exhausted { done }
```

### After — proposal B

```

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {
  let guide = ask tool "cat" for text
    "Write out the house style guide, at most four short lines."

  let draft = ask model "author" for text using model "deep"
    "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  let patch = revising draft with at most 2 revisions {
    check given patch {
      panel [
        ask model "reviewer-correct" for verdict
          "{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}",
        ask model "reviewer-secure" for verdict
          "{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}",
        ask model "reviewer-simple" for verdict
          "Could this patch be simpler?\n{patch}\n{verdictSpec}"
      ]
    }
    revise given patch, why {
      ask model "author" for text using model "deep"
        "{guide}\nRevise this patch:\n{patch}\n{why}\nReply with the revised diff only."
    }
  } or give up {
    -- Three reviews, two revisions, and the panel still objects. No patch
    -- survived, so the owner is never troubled and nothing is applied.
  }

  let ok = ask person "owner" for flag
    "Apply this patch?\n{patch}\n{flagSpec}"

  if ok {
    act tool "apply"
      "Apply:\n{patch}\nWrite the patched file here, then reply DONE."
  } else {
    -- The owner said no. The patch is not applied.
  }
}
```

Read aloud, without a glossary: *Let `guide` be what you get when you ask the
tool `cat` for text, saying this. Let `draft` be what you get when you ask the
model `author` for text, using the model `deep`, saying this. Let `patch` be
what you get by revising `draft`, with at most two revisions, where to check it
— given a patch — you put this panel of three questions, and to revise it —
given a patch and why it was rejected — you ask the author for text again; or
give up, in which case do nothing. Let `ok` be what you get when you ask the
person `owner` for a flag, saying this. If `ok`, act through the tool `apply`,
saying this; else do nothing.*

Every noun in that reading is written in the program. Nothing is inferred from
indentation, and no name appears that was not introduced by `let` or `given`.

The file is the same length: 42 lines then, 42 lines now; 1315 characters then,
1502 now, of which 199 are the two explanatory comments in the arms that do
nothing — the program text is 1303 characters, twelve fewer than today, and the
`for` and `using model` connectives are paid for by the four keywords and the
whole `accepted (patch) { … }` scope that disappear. The **token inventory**
shrinks outright: the punctuation of the language goes from
`{ } [ ] ( ) , = @ ->` to `{ } [ ] , =`.

---

## 2. The grammar, complete

### 2.1 Lexical

```
comment     ::= "--" … end-of-line                     -- discarded
ident       ::= (alpha | "_") (alpha | digit | "_")*
nat         ::= digit+
string      ::= '"' (char | escape | interpolation)* '"'
escape      ::= "\n" | "\t" | "\r" | "\\" | "\"" | "\{" | "\}"
interpolation ::= "{" ident "}"
punct       ::= "{" | "}" | "[" | "]" | "," | "="
```

Unchanged from today except that `(`, `)`, `@` and `->` are no longer lexemes.
As today, there are no reserved words: a word is a keyword only at a position
where that word is expected, so `let` may still name an addressee inside a
string, and the lexer stays a function of characters alone.

### 2.2 Syntactic

```
program     ::= { define } "workflow" block

define      ::= "define" ident "=" string

block       ::= "{" { binding } [ ending ] "}"

binding     ::= "let" ident "=" rhs
              | "let" ident "=" revision "or" "give" "up" block

ending      ::= act
              | "if" ident block "else" block
              | "case" ident "{" "approve" block "object" block "declined" block "}"

rhs         ::= ask | panel

ask         ::= "ask" addressee "for" kind [ "using" "model" string ]
                                           [ "draw" nat ] string

panel       ::= "panel" "[" ask { "," ask } "]"

revision    ::= "revising" ident "with" "at" "most" nat "revisions" "{"
                  "check"  "given" ident            block-of-rhs
                  "revise" "given" ident "," ident  block-of-rhs
                "}"

block-of-rhs ::= "{" rhs "}"

act         ::= "act" addressee string

addressee   ::= ("model" | "tool" | "person") string

kind        ::= "text" | "verdict" | "flag"
```

Six facts the grammar states rather than leaves to a reader's inference:

* **A block is a list of bindings, optionally ended.** The ending is an act or a
  branching; both are terminal, because each arm of a branching is a whole
  workflow and the library's `Plan.case` has no join. A block with no ending
  does nothing further, and `{ }` is how "do nothing" is written.
* **A binding is the only thing that introduces a name into the rest of a
  block**, and it always begins with `let`.
* **`given` is the only other binder**, it appears only in the two clauses of a
  revision, and it is written immediately before the brace of the scope its
  names cover.
* **`revising` appears only as the right-hand side of a `let`**, and that `let`
  always carries an `or give up` block. Neither half is optional.
* **A branching writes all of its arms.** `if` requires `else`; `case` requires
  all three verdict tags; `let … = revising …` requires `or give up`. One rule,
  three constructs, no defaults. This is not pedantry: the not-taken arm is a
  leaf of the cost tree (`card_leaves_flagship = 9` counts it), so an author who
  cannot see it cannot read the bill.
* **`ack` is not a writable kind.** An acknowledgement is what `act` asks for,
  and an act is terminal, so there is exactly one way to write one.

### 2.3 The whole vocabulary

Eighteen entries — every word the language has is in this table or in the two
lines beneath it. A reader is expected to know what each means from the word
itself; the gloss is what the checker means by it, not what the reader needs to
be told.

| word | means |
|---|---|
| `define` | name some words, at authoring time |
| `workflow` | the program |
| `let` | name the answer to a question |
| `ask` | put a question |
| `for` | …and this is the kind of answer wanted |
| `using model` | …served by this model (the scope override) |
| `draw` | …this independent sample of it |
| `panel` | ask all of these; combine the verdicts |
| `revising` | check, and if not approved, revise and check again |
| `with at most … revisions` | how many revisions, at most |
| `check` | how a candidate is judged |
| `revise` | how a rejected candidate is rewritten |
| `given` | the name this clause is handed |
| `or give up` | …and if nothing survived review, do this instead |
| `if` / `else` | branch on a flag |
| `case` | branch on a verdict (`approve`, `object`, `declined`) |
| `act` | the workflow's effect on the world; ends the block |
| `model` / `tool` / `person` | who is being asked |

Kinds: `text`, `verdict`, `flag`. Verdict tags: `approve`, `object`,
`declined`. Punctuation: `{ } [ ] , =`.

---

## 3. What each construct elaborates to

Every row is the existing clause of `Agentic/Core/Dsl/Check.lean`; the surface
moved, the elaboration did not.

| surface | library object |
|---|---|
| `workflow B` | `Dsl.check [] [] B : Except CheckError (Plan [] Unit)` — the owner's `W Unit` |
| `{ }` (block with no ending) | `Plan.ret (fun _ => ())` |
| `let x = ask A for c "w"`, `w` closed | `Plan.askC c (s.withPrompt w) k` — the **batch** rung |
| `let x = ask A for c "…{y}…"` | `Plan.ask c s e k`, `e : Expr Γ String` — the **pipeline** rung |
| `A` = `model "m"` / `tool "t"` / `person "p"` | `s.addressee := Addressee.model "m"` etc. |
| `using model "d"` | `askShape (some "d") c t = atModel "d" c s`, i.e. `scope := Scope.fst "d" * 1` |
| `draw n` | `s.draw := n` |
| `{x}` in a prompt | `chunkExpr`: the `Expr Γ String` that `x` resolves to; only `.text` names resolve |
| `let x = …` (scope of `x`) | `Bindings.push x c S`: `Expr.var .here` in `c :: Γ`, everything else along `Sub.wk` |
| `panel [a₁, …, aₙ]` | `Plan.panel [p₁,…,pₙ] = foldr (zipWith (·*·)) (.ret fun _ => 1)`, members `Plan.ask1`/`askC1` |
| `let x = panel […]` | `Plan.graft (Plan.panel ps) (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ)))` |
| `revising a with at most n revisions {…}` | `Plan.revising (checkCont chk) (reviseCont rev) n Γ Sub.id a` |
| `check given p { R }` | `checkCont`: `fun _ σ a => Plan.sub chk (fun δ => Env.cons (a δ) (σ δ))`, `chk` checked in `c :: Γ` with `p ↦ 0` |
| `revise given p, w { R }` | `reviseCont`: `w ↦ Verdict.render (Env.head δ)`, `p ↦ index 1`, `rev` checked in `.verdict :: c :: Γ` |
| `let x = revising … or give up { E }` + rest `K` | `Plan.graft (Plan.revising …) (finishCont K E)` where `finishCont` is `Plan.caseB (fun δ => (final δ).isSome) (sub K …) (sub E σ)` |
| `if x { T } else { F }` | `Plan.caseB e T F`, i.e. `Plan.case` at `Bool` |
| `case v { approve {A} object {O} declined {D} }` | `Plan.caseV e (fun t => …)`, i.e. `Plan.case` at `VTag` |
| `act A "w"` | `Plan.askC .ack (s.withPrompt w) (.ret fun _ => ())`, or `Plan.ask` if the words are computed |
| `define x = "…"` | textual, expanded by the parser before the checker sees anything |

No clause emits `Plan.dyn`; `parseAndCheck_level_le` is untouched.

---

## 4. The obstacle, stated and solved

`Plan.revising` produces `Option (El c)`. `Ctx = List Code`, so "an artefact or
nothing" is **not** a context entry, and the loop's outcome therefore cannot be
bound by a plain `let` the way `let patch ← revising 2 spec …` appears to in
`example/HardenPatch.lean`. In the library the outcome is consumed by
`Plan.graft` into `finishCont`, which is a `caseB` on `isSome` with two complete
arms; the Lean twin hides this because Lean's `revising` is a different
combinator with a different type from `Plan.revising`.

Three ways out were weighed.

**(a) A binding whose failure outcome is an arm written immediately below it —
chosen.**

```
let patch = revising draft with at most 2 revisions { … } or give up { … }
<the rest of the block is the accepted arm, with `patch` in scope>
```

The `let` is a real binding: `patch` is in scope for everything after it, at
kind `text`, exactly as `let guide = ask …` is. The `or give up` block is the
other arm. This is Rust's `let … else` and Swift's `guard let … else`, and it is
the only option that keeps the do-notation reading: the workflow after the loop
stays at the top level of the block, at the same indentation as the statements
before it, instead of being pushed one scope to the right.

*The honest cost.* Control does **not** resume after `or give up { … }`. A
reader who thinks it does will misread a program with a non-empty give-up block.
Three things are done about that, and none of them is a comment in the manual:

* the words `give up` say that the workflow gives up, and they are the library's
  own words for this outcome (`Plan.revising`: "if the last check still objects,
  give up with `none`");
* the give-up block is a **block**, i.e. a complete workflow, so it may itself
  end in an `act` — which is exactly what a reader who thinks control resumes
  would not expect to be legal, and finding it legal is the correction;
* the clause is mandatory, so every reader meets it on the first `revising` they
  ever read, rather than meeting it once in ten programs.

**(b) A `case` over the outcome.** This is essentially today's design with
better words:

```
case revising draft with at most 2 revisions { … } {
  accepted patch { <the whole rest of the workflow> }
  gave up       { }
}
```

It is unambiguous and it has no fall-through hazard, and it was rejected for two
reasons. It indents the entire remainder of the workflow — in the flagship, the
consent gate and the act — inside an arm, which is the shape the owner is
already reading as unclear; and it makes the loop a scrutinee rather than a
right-hand side, so the one construct with a result is the one construct whose
result is not bound by `let`. Under brief B ("the do-notation reading") this is
the wrong trade.

**(c) A restriction making the common shape one line.** `let patch = revising …
or give up` with no block at all, meaning "give up silently". It reads well
(`… or give up` full stop) and it costs the ability to say anything on the way
out — no log, no notification, no fallback act — and it introduces a second
spelling of the same node the moment anyone wants one. Rejected as a special
case; but note that under (a) the flagship's give-up block is empty anyway, so
(c) would save exactly two braces on the one program that exists.

**The two inner binders.** `check` and `revise` are continuations —
`Plan.Cont Γ (El c) Verdict` and `Plan.Cont Γ (El c × Verdict) (El c)` — i.e.
functions of the artefact. A function's parameter is a binder, so law 2 applies:
`check given patch { … }`. `given` is the right word because it is not a `let` —
the author does not choose the value, the loop hands it over — and because it
reads as English at exactly the point the name comes into being. The present
`check (patch) {` is the construct the owner asked about, and the answer to
"where is `patch` declared" is now written on the line: it is declared there, by
`given`.

The second clause's two names are positional: `revise given patch, why` hands
over the artefact and the panel's objections rendered as text (`Verdict.render`,
which `DslFlagship.render_eq_harden_render` proves is `Harden.render`). The
order is the same as `check`'s first name, which is the inference a reader makes
and it is correct.

---

## 5. The ask phrase

Chosen:

```
ask ADDRESSEE for KIND [using model "…"] [draw n] "…"
```

*ask the model `author` for text, using model `deep`: «…»*

The addressee leads because "ask X for Y" is the most idiomatic English form
there is, and because the addressee is the field a reader scans for — it is what
`Q.shape` records and what every shape theorem in `Agentic/Core/HardenPatch.lean`
quantifies over ("the guide was read once", "at most three drafts were asked
for" are statements about addressees).

The runner-up was kind-first, `ask for verdict from model "reviewer-correct"`,
which matches the order in the owner's sentence and costs one more preposition
and the scanning position of the addressee. Either is a one-line change to
`parseAsk`; if the owner prefers it, nothing else in this proposal moves.

**Why the override is `using model "deep"` and not `@model "deep"`:**

* `@` said nothing. `using` says the question is served by that model.
* It is **subordinate and postfix**, so the sentence still begins with the verb
  and the addressee, and the long prompt still comes last. Today's prefix form
  `@model "deep" ask text model "author"` puts the least important word first.
* The word `model` appearing twice is not an accident to be hidden: the
  addressee `model "author"` is *who answers*, and `using model "deep"` is
  *which engine serves them*. These are different fields of `Q` — `addressee`
  and the first axis of `scope` — and `Agentic/Core/Acp.lean` treats them
  differently ("a scope names a model the author chose"). Naming the axis is
  what makes the second one legible, and it leaves room for the sibling axis:
  `using mode "…"` is the obvious future spelling of `Scope`'s second component,
  and it needs no new syntax.
* `atModel` prepends on the left of the scope monoid so the innermost wins;
  `askShape` already implements exactly this, and `Dsl.Check.under_ask1` is the
  `rfl` that licenses rewriting a shape rather than wrapping a term. Unchanged.

---

## 6. Line-by-line, against the owner's complaints

> **"Does `revising draft upto 2` scope the indented elements? If so, why does
> it not use braces?"**

It did, and it did not say so. Now it does: `revising draft with at most 2
revisions { check … revise … }`. The braces enclose exactly the two clauses that
belong to the loop, and the two clauses have their own braces. The `or give up`
block is outside the loop's brace because it is not part of the loop — it is
what happens after the loop fails — and it is inside the same statement because
it is the other outcome of the same binding. Indentation now carries no meaning
anywhere in the language.

> **"Where is `patch` declared that is used in `check (patch) {`? Does that
> check statement also bring it into being?"**

Yes, it did, invisibly, which is the defect. `check given patch { … }` declares
it in the one place it comes into being, with a word that says a name is being
introduced. The same fix applies to `with (patch, why)` → `revise given patch,
why`, and to `accepted (patch)` → the `let patch =` that heads the whole
statement.

> **"What does `exhausted` mean?"**

It is gone. The outcome it named is now `or give up`, which is the phrase
`Plan.revising`'s own docstring uses for it, and which says what the workflow
does rather than what happened to a counter.

> **"What does `done` mean?"**

It is gone, and nothing replaces it. A block that does nothing further is `{ }`.
There is no keyword left to explain, which is the strongest form of the answer.

> **"The original Lean code was very succinct and clear, but this DSL has lost
> much of that clarity."**

Against the twin, statement by statement:

| `example/HardenPatch.lean` | proposal B |
|---|---|
| `let guide : String ← ask "…"` | `let guide = ask tool "cat" for text "…"` |
| `let patch ← revising 2 spec fun current => do` | `let patch = revising draft with at most 2 revisions {` |
| `let patch ← model "deep" <| ask s!"…"` | `revise given patch, why { ask model "author" for text using model "deep" "…" }` |
| `let verdict ← panel [ ask …, ask …, ask … ]` | `check given patch { panel [ ask …, ask …, ask … ] }` |
| `let ok : Bool ← askHuman s!"…"` | `let ok = ask person "owner" for flag "…"` |
| `if ok then ask s!"Apply:\n{patch}" else pure ()` | `if ok { act tool "apply" "…" } else { }` |

Six statements in the twin, six statements here, in the same order, each one a
`let` or an `if`. What the text language must say and the twin need not:

* **the addressee**, because the twin's `ask` means "a model" and `askHuman`
  means "a person", and a language with seven distinct addressees cannot leave
  them implicit — and must not, since the shape theorems are about them;
* **the kind of answer**, because there is no `: String` / `: Bool` ascription
  and no elaborator to infer one;
* **the check/revise split**, because `Plan.revising` takes two continuations
  and the twin's `revising` is a different combinator that fuses drafting into
  the loop body. This is a difference between the two *libraries*, not between
  the two surfaces, and `Agentic/Core/HardenPatch.lean`'s `review`/`redraft` pair
  is the shape being written;
* **both arms of the consent gate**, because the arm the run does not take is a
  priced leaf of the cost tree.

Nothing else. Every remaining word of the surface corresponds to something the
twin also writes.

---

## 7. The other programs

### `example/hello.wf`

```
-- The smallest program the language can write that is still a workflow: two
-- questions and an act. It exists so that `agent-cat` has a subject that is not
-- the flagship — cheap to run, `pipeline` rather than `branch`, and therefore
-- the one program whose bill the analysis knows exactly rather than bounds.
define brief = "Reply in one short line."

workflow {
  let subject = ask tool "cat" for text
    "Name one thing worth greeting.\n{brief}"

  let greeting = ask model "greeter" for text
    "Write a greeting for this, and nothing else:\n{subject}\n{brief}"

  act tool "say"
    "Say it:\n{greeting}\nThen reply DONE."
}
```

Only the two ask phrases move (`ask text tool "cat"` → `ask tool "cat" for
text`), and because the kind and the addressee merely swap places after `ask`,
the `ask` tokens stay in columns 17 and 18 and every `Pos` is unchanged too: the
raw syntax of `hello.wf` is **byte-identical** to today's, so the `pipeline`
rung and the exact bill `test/CliSmoke.lean` checks cannot have moved.

### `example/ill-typed.wf`

```
-- … (comment unchanged) …
workflow {
  let review = ask model "reviewer" for verdict
    "Is the parser correct?"

  let note = ask tool "cat" for text
    "Write this up: {review}"
}
```

`done` is deleted; the block simply ends. The refusal is the same refusal —
interpolating a verdict — with a new position in the diagnosis.

### `test/DslSmoke.lean`'s refusal corpus

Every source is one mechanical rewrite; the messages that change are listed in
§9. For example:

```lean
def srcRevising (n : Nat) : String :=
  "workflow { let d = ask model \"a\" for text \"draft\"\n" ++
  s!"           let p = revising d with at most {n} revisions " ++
  "{ check given c { ask model \"r\" for verdict \"review {c}\" }\n" ++
  "             revise given c, why { ask model \"a\" for text \"fix {c} {why}\" } }\n" ++
  "           or give up { }\n" ++
  "           act tool \"t\" \"apply {p}\" }"
```

---

## 8. The plan is unchanged

### 8.1 What determines the plan

`Dsl.checkBlock` reads exactly five things out of a `Raw`: the constructor
sequence, the `Code`s, the `RawTarget`s and `model` overrides, the `Prompt`
chunk lists, and — only through `Bindings.find?` — the *identity* of the name an
interpolation mentions. It reads `Pos` **only** to build a `CheckError`, i.e.
only on branches that return `.error`. On a source that checks, no position
reaches the result.

### 8.2 What the rewrite changes in `flagshipRaw`

* Every `Pos`. (Lines and columns of the new file.)
* Two constructor spellings: `RawBlock.done` → `RawBlock.empty`,
  `RawBlock.caseFlag` → `RawBlock.ifFlag`. Their clauses in `checkBlock` and
  their lines in `RawBlock.bounded` / `checkBlock_bounded` are unchanged; this
  is α-renaming of the syntax tree, not a change of function.

Nothing else. In particular, all of the following are **byte-identical** between
the old and the new `flagshipRaw`:

* the field order and nesting of `RawBlock.revising` — the new surface parses
  into the *same node*, with `pv = "patch"` and `accepted` = the remainder of
  the enclosing block, exactly as `accepted (patch) { … }` did;
* the five binder names `guide`, `draft`, `patch`, `why`, `ok`;
* every `Chunk` list, because every string literal and every `define` body is
  copied character for character, including the un-fused `Chunk.lit "\n"`
  before each `{verdictSpec}` and `{flagSpec}` that `Prompt.normalize`
  deliberately leaves alone and that keeps `Prompt.expr`'s left-associated
  `++`-chain equal to `Harden.correctText`'s on the nose;
* every `RawTarget`, every `Code`, and both `model := some "deep"` overrides.

Therefore `check [] [] flagshipRaw` reduces to the same `Plan [] Unit`, and
`flagshipPlan` is the same term.

(If the owner prefers the round's candidate to have its own name — `check given
candidate { … }` — that is also plan-preserving, because a name reaches the plan
only through the `Expr` it resolves to, and both spellings resolve to
`Expr.var .here`. It would change the `Chunk.interp` spellings in `flagshipRaw`
and nothing downstream of it. The version above keeps the names because a
by-position diff of `flagshipRaw` is the cheapest possible review.)

### 8.3 The new `flagshipRaw`

Positions computed from the file in §1 (the file keeps its leading blank line,
so the `define` preamble is lines 2–4 as today).

```lean
def flagshipRaw : Raw :=
  RawBlock.bind "guide"
    (RawRhs.ask
      { model := none, code := Code.text,
        target := { addressee := Addressee.tool "cat", draw := 0 },
        prompt := [Chunk.lit "Write out the house style guide, at most four short lines."],
        pos := { line := 7, col := 15 } })
    (RawBlock.bind "draft"
      (RawRhs.ask
        { model := some "deep", code := Code.text,
          target := { addressee := Addressee.model "author", draw := 0 },
          prompt := [Chunk.lit "Draft a patch satisfying:\n", Chunk.lit "harden the parser",
            Chunk.lit "\nReply with a unified diff only."],
          pos := { line := 10, col := 15 } })
      (RawBlock.revising "draft" 2 "patch"
        (RawRhs.panel
          [{ model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-correct", draw := 0 },
             prompt := [Chunk.interp "guide", Chunk.lit "\nIs this patch correct?\n",
               Chunk.interp "patch", Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 16, col := 9 } },
           { model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-secure", draw := 0 },
             prompt := [Chunk.interp "guide", Chunk.lit "\nIs this patch secure?\n",
               Chunk.interp "patch", Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 18, col := 9 } },
           { model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-simple", draw := 0 },
             prompt := [Chunk.lit "Could this patch be simpler?\n", Chunk.interp "patch",
               Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 20, col := 9 } }]
          { line := 15, col := 7 })
        "patch" "why"
        (RawRhs.ask
          { model := some "deep", code := Code.text,
            target := { addressee := Addressee.model "author", draw := 0 },
            prompt := [Chunk.interp "guide", Chunk.lit "\nRevise this patch:\n",
              Chunk.interp "patch", Chunk.lit "\n", Chunk.interp "why",
              Chunk.lit "\nReply with the revised diff only."],
            pos := { line := 25, col := 7 } })
        "patch"
        (RawBlock.bind "ok"
          (RawRhs.ask
            { model := none, code := Code.flag,
              target := { addressee := Addressee.person "owner", draw := 0 },
              prompt := [Chunk.lit "Apply this patch?\n", Chunk.interp "patch",
                Chunk.lit "\n", Chunk.lit "Reply with exactly yes or no."],
              pos := { line := 33, col := 12 } })
          (RawBlock.ifFlag "ok"
            (RawBlock.act { addressee := Addressee.tool "apply", draw := 0 }
              [Chunk.lit "Apply:\n", Chunk.interp "patch",
               Chunk.lit "\nWrite the patched file here, then reply DONE."]
              { line := 37, col := 5 })
            (RawBlock.empty { line := 41, col := 3 })
            { line := 36, col := 3 })
          { line := 33, col := 3 })
        (RawBlock.empty { line := 31, col := 3 })
        { line := 13, col := 15 })
      { line := 10, col := 3 })
    { line := 7, col := 3 }
```

Diff against the present `flagshipRaw`: thirteen of the sixteen `Pos` literals
(the guide's two and the draft's `let` do not move) and two constructor names.
Nothing else.

### 8.4 The theorems

None of the protected statements mentions `flagshipRaw`, the source text, or any
surface construct. They mention `flagshipPlan`, `flagshipUpTo`, `Harden.demo`
and the four worlds:

* `level_flagshipPlan`, `level_flagshipPlan_le`
* `card_leaves_flagship`, `minFold_flagship`, `maxFold_flagship`
* `trace_flagship_{refuse,apply,stubborn,echo}`
* `bill_flagship_{refuse,apply,stubborn,echo}`
* `flagshipUpTo`, `flagship_bill_le`, `minFold_flagship_le_bill`

Each is byte-identical after the rewrite, and each closes the same way, because
`flagshipPlan` reduces to the same term: the `decide +kernel` proofs perform the
same reductions at the same cost, and the four `Plan.trace … = Plan.trace …
Harden.demo` equations compare the same two plans they compare today.
`flagshipRaw_accepted` and `check_flagshipRaw` likewise. `parseAndCheck_flagship`
keeps its hypothesis `parse flagshipSource = .ok flagshipRaw`, discharged as
today at run time by `test/DslSmoke.lean`.

**Verification status, stated honestly.** This is a proposal; no build was run
for it, and the paragraph above is an argument from the code of `checkBlock`,
not a machine check. The two commands that settle it, in this order and never
concurrently:

```
direnv exec . lake build Agentic.Core.DslFlagship     # ~5 min, several GB
direnv exec . lake exe dsl_smoke                      # parse flagshipSource = flagshipRaw
```

A third, cheaper check is available while implementing and is worth doing first:
`#guard (Dsl.check [] [] flagshipRaw_new) matches .ok _` plus a
`decide +kernel`-free `example : flagshipPlan_new = flagshipPlan_old := rfl` in a
scratch module — if positions are the only difference, that `rfl` is immediate.

---

## 9. Implementation impact

| file | change |
|---|---|
| `Agentic/Core/Dsl/Syntax.lean` | rename `RawBlock.done` → `.empty`, `.caseFlag` → `.ifFlag`; docstrings for the new spellings. **No field changes to any constructor.** `codeName`/`codeOfName` keep all four kinds — the retraction `codeOfName_codeName` is stated for every `Code`, and `.ack` is still needed to *name* a kind in a diagnosis; `ack` is refused at the `ask` position by `parseAsk`, with "an acknowledgement is what `act` asks for", which is a rejection of a parsed kind and not a hole in the table |
| `Agentic/Core/Dsl/Parse.lean` | the grammar of §2: `parseAsk` reorders and takes `for`/`using model`; `parseBlock`'s `let` case grows the `revising … or give up` alternative and calls itself for the accepted remainder; `case` loses `->`; `if` added; `done` deleted; `(`, `)`, `@`, `->` leave `punctChars` and `Token` |
| `Agentic/Core/Dsl/Check.lean` | **no elaboration change**; message wording only (see below) |
| `example/harden.wf`, `hello.wf`, `ill-typed.wf` | rewritten as above |
| `Agentic/Core/DslFlagship.lean` | `flagshipRaw` positions and two constructor names |
| `test/DslSmoke.lean` | refusal corpus rewritten; the expected diagnoses listed below reworded |
| `test/CliSmoke.lean`, `test/McpSmoke.lean` | source-text comparisons only |
| `doc/PLAN.org` | out of scope here; a grammar section will need the new EBNF |

Diagnoses that must change wording, old → new:

* the parser's fallback: "expected a statement (`let`) or a tail (`done`, `act`,
  `case`, `revising`)" → "expected `let`, `if`, `case`, `act`, or `}`"
* a bare question: "a block ends in `done` or `act`; this one ends with an
  answer, and a closed workflow has nowhere to return one" → "every question
  binds its answer: write `let x = ask …`, or `act` if this is the workflow's
  effect on the world"
* the flag branching kind error: "the arms `yes` and `no` branch on a `flag`,
  but `x` answers `text`" → "`if` branches on a flag, but `x` answers `text`"
* the revision bound: the excerpt "upto 65" becomes "at most 65 revisions"; the
  message itself — "a bounded revision is unrolled into the term it writes, so
  its bound may name at most 64 revisions" — is unchanged and still true
* the revise clause: "the `with` clause of a bounded revision" → "the `revise`
  clause of a bounded revision"
* new: "an acknowledgement is what `act` asks for; write `act` instead" at an
  `ask … for ack`

`maxRevisions`, `checkBlock_bounded`, `check_bounded`,
`parseAndCheck_level_le` and every theorem in `Agentic/Core/Dsl.lean` are
untouched.

---

## 10. What this proposal does not fix

Stated rather than hidden, in the house style.

1. **`check` and `revise` take one question or one panel, not a block.** Their
   library type is a `Plan.Cont … Verdict` / `… (El c)`, which can be an
   arbitrary plan, but the language has no value-returning block, so a check
   that wanted to read a file first cannot be written. The brace form
   `check given patch { … }` is chosen partly so that this can be relaxed later
   — `{ let x = ask …  panel [ … ] }`, a block whose ending is a value — without
   moving a single character of the surface that exists today.
2. **Branchings are terminal.** Statements may not follow an `if` or a `case`.
   The library can express the sequel (`Plan.graft` of a `Cont Γ Unit Unit`), so
   this is a surface restriction, taken because the alternative is either
   duplicating the sequel into every arm or making the emitted term depend on
   whether anything follows. The flagship does not need it.
3. **`or give up` does not fall through**, and no syntax can make that as loud as
   an indentation-free reader might want. §4 argues the words carry it; if the
   owner disagrees, option (b) is the fallback and costs one level of
   indentation for the whole tail of every workflow that revises.
4. **The second `given` name is positional.** `revise given patch, why` binds the
   artefact and then the objections; nothing in the surface says which is which
   beyond the order and the names the author chose.
5. **`define` and `let` are both written with `=`.** They are different — one
   names words at authoring time, the other names an answer heard at run time —
   and only the leading keyword distinguishes them. This is deliberate: the
   alternative, `let x ← ask …`, imports the arrow from `do`-notation to mark an
   effect, and in this language *every* `let` is an effect, so the arrow would
   mark nothing.
