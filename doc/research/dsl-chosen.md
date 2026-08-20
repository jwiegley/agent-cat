# The chosen grammar

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

*A surface for `Agentic/Core/Dsl`. One structural rule — **a scope is a pair of
braces, and a name is introduced by a word that says a name is being
introduced** — and one obligation: the elaborated plan does not move.*

Verified before it was written down: the chosen surface and the present one
parse to the same raw syntax modulo positions, checked by a line-for-line port
of `Agentic/Core/Dsl/Parse.lean` carrying both parsers.

```
$ python3 /tmp/wfcheck-C.py example/harden.wf /tmp/harden-C.wf example/hello.wf /tmp/hello-C.wf
harden: same AST modulo positions: True
hello : same AST modulo positions: True
hello : identical including every Pos: True
```

---

## 0. The judgment: what was taken from each proposal, and why

Both proposals were scored on the six criteria, in order. Neither wins outright,
and the disagreements are not stylistic: each proposal is right about a
different half of the construct the owner asked about.

| # | Criterion | A | B | Chosen |
|---|---|---|---|---|
| 1 | A stranger reads it correctly, no glossary | **4/5** — all four questions answered by the shape; the one soft spot is that `patch`, declared in the head, is silently *not* in scope in `never approved` | **2/5** — three questions answered well, but `let patch = revising … or give up { … }` reintroduces the owner's own complaint: nothing in the text says control does not resume after the give-up block (B admits this, §10.3) | **5/5** — every clause that is handed a name says `given`; there is no head binder, so there is no scope exception and no fall-through to explain |
| 2 | Every scope braced, every binder declared where it comes into being | **3/5** — braced throughout, but one declaration serves three sibling clauses and not the fourth, which is *not* where two of the three come into being | **5/5** — `given` at each clause; three binders, three declarations | **5/5** — B's `given`, applied to the accepted arm as well (`approved given patch`) |
| 3 | Reads like the Lean twin, line for line | **3/5** — the consent gate and the act are pushed inside `approved { … }`; `case ok { yes … no … }` where the twin writes `if … then … else` | **5/5** — six statements, flat, in the twin's order | **4/5** — B's `if ok { … } else { … }` taken; the tail still sits one level in, which is the one place the chosen grammar pays for its honesty |
| 4 | Identical plan, no semantic invention | **4/5** — plan preserved, but `RawBlock.revising` loses three fields and `revising (patch = draft)` asserts an equation that holds only at round zero | **4/5** — plan preserved; `let` is made to bind conditionally, which is a new meaning for the language's one binder | **5/5** — `RawBlock.revising` keeps all eleven fields unchanged; `Check.lean`'s `revising` clause does not move a character |
| 5 | Stays small | **3/5** — 40 lexemes (today 37) | **4/5** — 38 lexemes, but pays for it by deleting `ask … for ack`, which is the only non-terminal effect the language has | **4/5** — 38 lexemes: +5 words, −4 punctuation lexemes, nothing deleted from the language |
| 6 | Error messages it makes possible | **3/5** — the best message it proposes (`there is no patch in this clause`) needs new machinery, `RawBlock.mentions` | **4/5** — good, cheap messages | **5/5** — the same messages, and A's best one falls out of the ordinary unbound-name diagnosis for free, because no head binder ever declared `patch` where the artefact does not exist |

**The one substantive disagreement, decided.** B binds the loop's outcome with
`let` and hangs the failure on `or give up`, keeping the tail of the workflow
flat; A makes `revising` a tail whose two outcomes are blocks, costing one level
of indentation. B is more faithful to the Lean twin *as written*; A is more
faithful to the library, where the outcomes are the two arms of `finishCont` and
control does not rejoin. The owner's criticism is precisely that the present
surface implies a structure it does not have, so where the two goods conflict,
the one that cannot mislead wins. A's shape is taken.

**But A's shape is taken with B's decomposition.** A puts all four clauses inside
the loop's braces, which is why A needs the scope exception: `check` and `revise`
are `Plan.revising`'s two continuations, while `approved` and `never approved`
are the graft's two outcomes, and they are not the same kind of thing. Braces
around exactly the two continuations, then the two outcomes as clauses of the
statement — the shape `if … { } else { }` already teaches — costs nothing and
removes the exception.

---

## 1. The two lines the owner read, before and after

Today:

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

Chosen:

```
  revising draft up to 2 revisions {
    check given patch {
      panel [ … ]
    }

    revise given patch, why {
      ask model "author" using model "deep" for text "…"
    }
  }

  approved given patch {
    let ok = ask person "owner" for flag "…"

    if ok {
      act tool "apply" "…"
    } else { }
  }

  never approved { }
```

| The owner's question | The answer in the text |
|---|---|
| *Does `revising draft upto 2` scope the indented elements?* | The braces say what is scoped: the loop's two clauses, and nothing else. Indentation means nothing anywhere in the language. |
| *Where is `patch` declared?* | Three times, each time by `given`, each time in the clause that is handed it: `check given patch`, `revise given patch, why`, `approved given patch`. These are three different binders in the library — de Bruijn `0` of three different contexts — and now three in the surface. |
| *Does `check` bring it into being?* | Yes, and it now says so. `given` is the word for "the name this clause is handed"; the author does not choose the value, the loop hands it over. |
| *What does `exhausted` mean?* | It meant "the budget ran out with objections outstanding", which is the same thing as "the artefact was never approved". The clause now says that: `never approved`. |
| *What does `done` mean?* | Nothing an empty block does not already say. The word is gone; doing nothing is `{ }`. |

---

## 2. The three rules

1. **A scope is a pair of braces.** Every region in which a name is visible is
   `{ … }`, every block is `{ … }`, and one function opens and closes all of
   them. Layout is whitespace.
2. **A name is introduced by a word.** `define x =` and `let x =` for a name you
   bind to an answer; `given x` for a name a clause is handed. There is no third
   way, and no construct introduces a name silently.
3. **A prompt is the last thing in its phrase, and it never sits beside another
   string.** `ask` puts the answer kind between the addressee's name and the
   words (`ask model "author" for text "…"`), so a reader never has to know an
   arity to see where a phrase ends. `act tool "apply" "…"` is the one place two
   strings meet, and it is unchanged from today.

---

## 3. The complete grammar

```
program    ::= { define } "workflow" block
define     ::= "define" ident "=" string

block      ::= "{" { binding } [ tail ] "}"
binding    ::= "let" ident "=" rhs
tail       ::= act | if | case | revising

rhs        ::= ask | panel
ask        ::= "ask" target [ scope ] "for" code string
panel      ::= "panel" "[" ask { "," ask } "]"
act        ::= "act" target string

target     ::= ( "model" | "tool" | "person" ) string [ "draw" nat ]
scope      ::= "using" "model" string
code       ::= "text" | "verdict" | "flag" | "ack"

if         ::= "if" ident block "else" block
case       ::= "case" ident "{" "approve" block "object" block "declined" block "}"

revising   ::= "revising" ident "up" "to" nat ( "revision" | "revisions" ) "{"
                 "check"  "given" ident               "{" rhs "}"
                 "revise" "given" ident "," ident     "{" rhs "}"
               "}"
               "approved" "given" ident block
               "never" "approved" block

ident      ::= (alpha | "_") (alpha | digit | "_")*
nat        ::= digit+
string     ::= '"' { char | escape | "{" ident "}" } '"'
escape     ::= \n | \t | \r | \\ | \" | \{ | \}
punct      ::= "{" | "}" | "[" | "]" | "," | "="
comment    ::= "--" … end of line
```

`(`, `)`, `@` and `->` leave the lexer. As today there are no reserved words: a
word is a keyword only where that word is expected, so the lexer stays a
function of characters alone.

Seven notes, each a decision:

* **A block may end without a tail.** `{ }` does nothing; `{ let x = ask … }`
  asks and stops. This is what deletes `done` — a block is a list of things to
  do, and a list that runs out is over — and it is what makes "do nothing" look
  like doing nothing.
* **A tail is terminal.** Nothing may follow `if`, `case` or `revising` in a
  block: each arm, and each outcome, *is* the rest of the workflow. That is the
  library's shape, not the surface's invention — `Plan.case` has no join — and
  "the last statement of a block" is how the surface says it.
* **`revising` is a tail with two outcome clauses, not a right-hand side.**
  `Plan.revising` produces `Option (El c)` and `Ctx = List Code`, so the outcome
  is not a context entry; it is consumed by `Plan.graft` into `finishCont`,
  which is a `caseB` with two complete arms. The surface writes those two arms.
* **The loop's braces hold exactly the loop.** `check` and `revise` are
  `Plan.revising`'s two continuations and they are inside; `approved` and
  `never approved` belong to the graft and are outside. Nothing is in scope
  across that brace, so nothing needs an exception.
* **`up to n revisions` names the unit of the numeral.** `Plan.revising`'s
  docstring records three independent readings getting `n` backwards. `up to 2
  revisions` is the true reading — three checks, at most two revisions — written
  where the numeral is. Both spellings of the noun are accepted so that `up to 1
  revision` is English; it is the only word in the language with two spellings.
* **The scope override is `using model "…"`, between the addressee and the
  kind.** `ask model "author"` says *who is asked*; `using model "deep"` says
  *which model serves it*. They are two different fields of `Q.Shape`
  (`addressee` and the first axis of `scope`), the two prepositions keep them
  apart, and naming the axis leaves `using mode "…"` available for `Scope`'s
  second component with no new syntax. It is postfix because a prefix looks like
  it governs the statement, and `Plan.under σ` really is a fold over a whole
  plan; what the checker emits is a shape rewrite, licensed at *one question* by
  `under_ask1`.
* **`ask … for ack` stays legal.** An act is terminal, so a question asked for
  its effect in the middle of a workflow has nowhere else to be written. It is
  also what keeps `codeOfName_codeName` a retraction over all four kinds.

Removed: `upto`, `done`, `exhausted`, `accepted`, `with`, `yes`, `no`, `@`,
`->`, `(`, `)`. Added: `for`, `using`, `up`, `to`, `revision(s)`, `given`,
`revise`, `approved`, `never`, `if`, `else`. Net: 37 lexemes today, 38 now —
five more words, four fewer punctuation marks, and nothing taken out of the
language.

---

## 4. The flagship, final form

`example/harden.wf`, verbatim. Same questions, same addressees, same prompts,
same order, byte for byte in every string; the file keeps its leading blank
line, so `flagshipSource`'s docstring stays true.

```

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {
  let guide = ask tool "cat" for text
    "Write out the house style guide, at most four short lines."

  let draft = ask model "author" using model "deep" for text
    "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  revising draft up to 2 revisions {
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
      ask model "author" using model "deep" for text
        "{guide}\nRevise this patch:\n{patch}\n{why}\nReply with the revised diff only."
    }
  }

  approved given patch {
    let ok = ask person "owner" for flag
      "Apply this patch?\n{patch}\n{flagSpec}"

    if ok {
      act tool "apply"
        "Apply:\n{patch}\nWrite the patched file here, then reply DONE."
    } else { }
  }

  never approved { }
}
```

Forty-two lines, as today. Read aloud, with no glossary: *let `guide` be what
you get when you ask the tool `cat` for text, saying this; let `draft` be what
you get when you ask the model `author`, using the model `deep`, for text,
saying this. Revising `draft`, up to two revisions: to check it, given a patch,
put this panel of three questions; to revise it, given a patch and why it was
rejected, ask the author again. Approved, given the patch: let `ok` be what you
get when you ask the person `owner` for a flag; if `ok`, act through the tool
`apply`; else do nothing. Never approved: do nothing.*

Against the standard, `example/HardenPatch.lean`:

| the twin | the surface |
|---|---|
| `let guide : String ← ask "…"` | `let guide = ask tool "cat" for text "…"` |
| `let patch ← revising 2 spec fun current => do` | `revising draft up to 2 revisions {` |
| `let patch ← model "deep" <| ask s!"…"` | `let draft = ask model "author" using model "deep" for text "…"`, hoisted above the loop, and `revise given patch, why { … }` inside it |
| `let verdict ← panel [ ask …, ask …, ask … ]` | `check given patch { panel [ ask …, ask …, ask … ] }` |
| `let ok : Bool ← askHuman s!"…"` | `let ok = ask person "owner" for flag "…"` |
| `if ok then ask s!"Apply:\n{patch}" else pure ()` | `if ok { act tool "apply" "…" } else { }` |
| — | `never approved { }` |

Six statements there, six here, in the same order. What the text language must
say and the twin need not: **who is asked**, because `ask` there means a model
and `askHuman` a person and this language has three addressees the shape
theorems quantify over; **what kind of answer**, because there is no `: String`
to infer from; **the check/revise split**, because `Plan.revising` takes two
continuations where `Agentic.revising` takes one step function; and **the
outcome in which nothing was approved**, because `Plan.revising` returns an
`Option` and `Agentic.revising` returns the last artefact reviewed. The last two
are differences between the two *libraries*, not between the two surfaces.

---

## 5. `hello.wf`, final form

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

Two words move (`text` from before the addressee to after it, twice). Because
`RawAsk.pos` is the position of the `ask` token and the addressee's kind swaps
places *after* it, **every `Pos` is unchanged**: the raw syntax of `hello.wf` is
byte-identical to today's, so the `pipeline` rung and the exact bill
`test/CliSmoke.lean` checks cannot have moved. Checked, not asserted — the third
line of the run at the head of this document.

---

## 6. What each construct elaborates to

Nothing in this column changes. Every row is a clause of
`Agentic/Core/Dsl/Check.lean` as it stands.

| surface | library object |
|---|---|
| `workflow B` | `check [] [] B : Except CheckError (Plan [] Unit)` — the owner's `W Unit` |
| `define x = "…"` | nothing; textual, expanded by `Parse.expand` before the checker sees a term |
| `{ }`, or a block with no tail | `Plan.ret (fun _ => ())` |
| `let x = ask A for c "w"`, `w` closed | `Plan.askC c (s.withPrompt w) k` — the **batch** rung |
| `let x = ask A for c "…{y}…"` | `Plan.ask c s e k`, `e : Expr Γ String` — the **pipeline** rung |
| `let x = panel [ … ]` | `Plan.graft (Plan.panel ps) (fun _ σ e => Plan.sub k (Env.cons (e δ) (σ δ)))` |
| an `ask` as a panel member or clause value | `Plan.askC1` / `Plan.ask1` (`checkAsk`) |
| `panel [a₁,…,aₙ]` | `Plan.panel [p₁,…,pₙ]`, folded in the monoid of `El .verdict`; refused at any other kind |
| `model/tool/person "id"` | `Q.Shape.addressee := Addressee.model/tool/person "id"` |
| `draw n` | `Q.Shape.draw := n` |
| `using model "m"` | `askShape (some m) c t = atModel m c s`, i.e. `s.scope := Scope.fst m * s.scope`; equal to `Plan.under (atModel m)` at one question by `under_ask1` / `under_askC1` |
| `"…{x}…"` | `Expr Γ String`: literals constant, `{x}` the de Bruijn variable `Bindings.find?` resolves, concatenated **left-associated** (`Prompt.expr`) |
| `let x = …` | `Bindings.push x c S`: `Expr.var .here` in `c :: Γ`, everything else along `Sub.wk` |
| `act A "w"` | `Plan.askC .ack (s.withPrompt w) (.ret fun _ => ())`, or `Plan.ask .ack s e (.ret …)` |
| `if x { T } else { F }` | `Plan.caseB e T F` — `Plan.case` at `Bool` |
| `case v { approve {A} object {O} declined {D} }` | `Plan.caseV e arms`, `arms : VTag → Plan Γ Unit` |
| `revising a up to n revisions { … } approved given p { … } never approved { … }` | `Plan.graft (Plan.revising (checkCont chk) (reviseCont rev) n Γ Sub.id b.val) (finishCont accP exhP)` |
| ‥ `check given p { R }` | `checkCont : Plan (c :: Γ) (El .verdict) → Cont Γ (El c) Verdict`; `p` is de Bruijn `0` |
| ‥ `revise given p, why { R }` | `reviseCont : Plan (.verdict :: c :: Γ) (El c) → Cont Γ (El c × Verdict) (El c)`; `why` is de Bruijn `0` under `Verdict.render`, `p` is de Bruijn `1` |
| ‥ `approved given p { A }` / `never approved { E }` | `finishCont A E = Plan.caseB (isSome ∘ final) (Plan.sub A …) (Plan.sub E σ)`; `p` is de Bruijn `0` of the accepted arm |

Two facts worth keeping in the guide, because they are why the language is worth
having: no clause emits `Plan.dyn`, so every program sits at or below the branch
rung (`Dsl.parseAndCheck_level_le`); and `check`'s type — `Except CheckError
(Plan Γ Unit)` — *is* the soundness statement, not a claim about it.

---

## 7. The vocabulary

Every word the language has, with what the checker means by it.

| word | means |
|---|---|
| `define` | name some words, at authoring time |
| `workflow` | the program |
| `let` | name the answer to a question |
| `ask` | put a question |
| `using model` | …served by this model (the scope override) |
| `for` | …and this is the kind of answer wanted |
| `draw` | …this independent sample of it |
| `panel` | ask all of these; combine the verdicts in their monoid |
| `act` | the workflow's effect on the world; ends the block |
| `revising` | check, and while not approved and budget remains, revise and check again |
| `up to n revisions` | how many revisions at most; there is one more check than that |
| `check` | how a candidate is judged |
| `revise` | how a rejected candidate is rewritten |
| `given` | the name this clause is handed |
| `approved` | the outcome in which the loop produced an approved artefact |
| `never approved` | the outcome in which it did not, so there is no artefact to hand over |
| `if` / `else` | branch on a flag; both arms written |
| `case` | branch on a verdict: `approve`, `object`, `declined`, all three written |
| `model` / `tool` / `person` | who is being asked |
| `text` / `verdict` / `flag` / `ack` | the four kinds of answer |

Punctuation: `{ } [ ] , =`. Braces are a scope; brackets are a list; the comma
separates list items and the two names of `revise given p, why`; `=` introduces
a value in the two places a name is bound to one.

---

## 8. The plan does not change

**The claim.** `check [] [] flagshipRaw` returns the same term as today, so
`flagshipPlan` is the same plan, so every protected theorem —
`level_flagshipPlan`, `level_flagshipPlan_le`, `card_leaves_flagship`,
`minFold_flagship`, `maxFold_flagship`, `trace_flagship_{refuse,apply,stubborn,echo}`,
`bill_flagship_{refuse,apply,stubborn,echo}`, `flagshipUpTo`,
`flagship_bill_le`, `minFold_flagship_le_bill`, and with them
`flagshipRaw_accepted`, `check_flagshipRaw` and `parseAndCheck_flagship` — keeps
its statement byte for byte and keeps its proof.

**(a) The elaborator does not change at all.** `RawBlock.revising` keeps all
eleven fields in their present order, so `checkBlock`'s `revising` clause,
`checkCont`, `reviseCont`, `finishCont`, `RawBlock.bounded` and
`checkBlock_bounded` are untouched but for two constructor spellings
(`.done → .empty`, `.caseFlag → .ifFlag`) and two message strings. The new
surface reads the same three artefact binders it always read — `cv` from `check
given p`, `av`/`wv` from `revise given p, why`, `pv` from `approved given p` —
and the flagship writes `patch` for all three, exactly as it does today, so name
resolution has identical inputs and produces identical de Bruijn indices.

**(b) No position reaches a plan.** Every occurrence of a `Pos` on a success
path is an argument to a `CheckError` constructor: `lookupBinding` (only in
`unbound`), `chunkExpr` (only in the two `.error`s), `Prompt.expr` /
`Prompt.exprFrom` (which thread `pos` and never store it), `checkAskAt`,
`checkRhsAt`, and the `maxRevisions` refusal. The success path is a function of
codes, shapes, prompts, structure and names alone, so a source that re-lays-out
the same program checks to the same plan. This is an ordinary structural
induction if it is ever worth proving; it is stated here as an inspection of six
clauses.

**(c) The two sources denote the same raw syntax.** Checked mechanically rather
than by eye. `/tmp/wfcheck-C.py` extends `/tmp/wfcheck.py`'s port of the lexer,
`define` expansion, `Prompt.normalize` and the current parser with a parser for
the grammar of §3, and compares the two trees with positions dropped: every
`Code`, every `Addressee`, every `draw`, every model override, every prompt as a
*chunk list* — so the three-literal split of the draft prompt survives unfused,
which is what keeps `Prompt.expr`'s left-associated `++`-chain equal to
`Harden.draftText` — the block structure, and every binder name.

**The new `flagshipRaw`**, emitted by that script from the source in §4, and the
only edit `DslFlagship.lean` needs:

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
            pos := { line := 26, col := 7 } })
        "patch"
        (RawBlock.bind "ok"
          (RawRhs.ask
            { model := none, code := Code.flag,
              target := { addressee := Addressee.person "owner", draw := 0 },
              prompt := [Chunk.lit "Apply this patch?\n", Chunk.interp "patch",
                Chunk.lit "\n", Chunk.lit "Reply with exactly yes or no."],
              pos := { line := 32, col := 14 } })
          (RawBlock.ifFlag "ok"
            (RawBlock.act { addressee := Addressee.tool "apply", draw := 0 }
              [Chunk.lit "Apply:\n", Chunk.interp "patch",
               Chunk.lit "\nWrite the patched file here, then reply DONE."]
              { line := 36, col := 7 })
            (RawBlock.empty { line := 38, col := 12 })
            { line := 35, col := 5 })
          { line := 32, col := 5 })
        (RawBlock.empty { line := 41, col := 18 })
        { line := 13, col := 3 })
      { line := 10, col := 3 })
    { line := 7, col := 3 }
```

Diff against the present `flagshipRaw`: twelve of the sixteen `Pos` literals
move (the guide's two, the draft's `let` and the `revising` keep theirs), and two
constructor names change. The eleven fields of `RawBlock.revising` are in the
same order with the same values; every `Chunk` list is character-identical; every
`RawTarget`, `Code` and `model := some "deep"` is identical.

**What still has to be run, and in what order.** Never two at once.

```
direnv exec . lake build Agentic.Core.DslFlagship   # the nine kernel proofs
direnv exec . lake exe dsl_smoke                    # parse flagshipSource = flagshipRaw
direnv exec . lake exe cli_smoke                    # the file on disk is the constant
```

Cheaper and worth doing first, in a scratch module: `example : flagshipPlanNew =
flagshipPlanOld := rfl`. If positions are the only difference, that `rfl` is
immediate, and it settles §8 before five minutes of kernel time are spent.
Nothing above is a substitute for the build; the argument is from the code of
`checkBlock` and from a port of the parser, not from the Lean elaborator.

---

## 9. Diagnoses the shape makes possible

| situation | message |
|---|---|
| `patch` mentioned in `never approved` | the ordinary `unbound name; nothing in scope answers to it` — correct, and free: no clause ever declared a name there, so there is no head binder to explain away |
| a `let` whose right-hand side is `revising` | ``a bounded revision has two outcomes and is not an answer to bind: write its `approved given …` and `never approved` clauses after its braces`` |
| the `approved` clause missing | ``expected `approved given <name> { … }`: a bounded revision writes both of its outcomes`` |
| a question in tail position | ``a question here has nowhere to put its answer: write `let x = ask …`, or `act` if the point is the doing`` (replaces a message naming `done`, which no longer exists) |
| an unfinished block | ``expected a statement (`let`), a tail (`act`, `if`, `case`, `revising`), or `}` `` |
| `if` on a non-flag | ``an `if` branches on a flag, but `x` answers `text` `` |
| the bound refused | unchanged wording, new excerpt: `` at `up to 65 revisions` `` |

---

## 10. What has to change in the tree

Surface only; no theorem statement moves.

| file | change |
|---|---|
| `Agentic/Core/Dsl/Syntax.lean` | `RawBlock.done → .empty`, `.caseFlag → .ifFlag`; docstrings for both and for `revising`. **No constructor gains or loses a field.** |
| `Agentic/Core/Dsl/Parse.lean` | the grammar of §3: `parseBlock` consumes its own braces and takes an optional tail; `parseAsk` reads target, then `using model`, then `for`, then the kind; `if`/`else`; `case` loses `->`; `revising`'s clause words; `Token.arrow`, `@`, `(` and `)` leave the lexer; the messages of §9. Net: shorter. |
| `Agentic/Core/Dsl/Check.lean` | two constructor names, and two message strings (``the `with` clause`` → ``the `revise` clause``; the `if` kind error). The `revising` clause itself is unchanged. |
| `Agentic/Core/Explain.lean` | two constructor names in `RawBlock.revisionBounds` and its induction; `revisionLines` prints `up to n revisions → n+1 checks` so that it quotes the source. |
| `Agentic/Core/DslFlagship.lean` | `flagshipRaw` as in §8; the nine kernel proofs re-run unchanged. |
| `example/harden.wf`, `example/hello.wf`, `example/ill-typed.wf` | §4, §5, and in the third the two ask phrases reordered and the trailing `done` deleted; it is refused for the same reason at a new position. |
| `test/DslSmoke.lean` | eleven embedded sources and the expected diagnoses (positions and wording). |
| `test/CliSmoke.lean`, `test/McpSmoke.lean` | the hostile `upto 1000000000` source; `splitOn "upto 2"` → `"up to 2 revisions"`. |
| `doc/mcp.md`, `doc/dsl-guide.html` | the worked example, the bullets, the reference card. |

Off limits and untouched: `Agentic/Surface.lean`, `example/HardenPatch.lean`,
`Agentic/Core/HardenPatch.lean`, `doc/PLAN.org`, `Agentic/Core/{Acp,Exec,Artifact}.lean`,
`cli/AgentCat.lean` (the CLI reaches the language only through `parseAndCheck`
and `Explain`, so it needs no edit).

---

## 11. The losing options, one line each

**Whole shapes**

* **B's `let patch = revising … or give up { … }`** — keeps the twin's flat
  reading, and cannot say that control does not resume after the give-up block;
  the owner's complaint was exactly a construct implying a structure it lacks.
* **B's `let` binding conditionally** — makes the language's one binder mean two
  things, one of which is "or else jump elsewhere".
* **A's four clauses inside one brace pair** — mixes `Plan.revising`'s two
  continuations with the graft's two outcomes, which is why A must except
  `never approved` from the scope of its head binder.
* **A's `revising (patch = draft)`** — spells an equation that is true only at
  round zero; the artefact under review is `draft` once and something else
  twice.
* **A's `check { … }` with no binder** — answers "does `check` bring `patch`
  into being?" with "no", when the truthful answer is "yes, and here is the
  word".
* **B's option (b), `case revising … { accepted patch { … } gave up { } }`** —
  unambiguous, and it indents the whole remainder of every revising workflow
  inside an arm of a scrutinee.
* **B's option (c), `… or give up` with no block** — a second spelling of one
  node, bought for two braces on the one program that exists.

**Clauses**

* **`case ok { yes { } no { } }` (A)** — `Plan.caseB` is `Bool`, the twin writes
  `if`, and `if … else` with a mandatory `else` is exactly as total.
* **`if` with an elidable `else`** — the not-taken arm is a priced leaf of the
  cost tree (`card_leaves_flagship = 9` counts it); an author who cannot see it
  cannot read the bill.
* **`ask text from tool "cat"` (A)** — leaves the addressee's name beside the
  prompt, so two strings still meet and a reader still needs the arity.
* **`act by tool "apply"` (A)** — a preposition bought for symmetry with a
  preposition that is not being bought.
* **`with at most 2 revisions` (B)** — three filler words where `up to` is two
  and equally exact.
* **Refusing `ask … for ack` (B)** — an act is terminal, so this is the only
  non-terminal effect the language has; deleting it shrinks the language, not
  the surface.
* **`accepted` / `exhausted` (today)** — one names the verdict, the other names
  a counter; they are the same outcome seen from two places.
* **`unapproved`, `otherwise`, `gave up`** — the first is not a word anyone
  says, the second names no outcome, the third is a sentence about the loop
  where the clause is about the artefact.
* **`@model "deep"` before the verb** — a prefix reads as governing the
  statement, and `Plan.under` really would; `under_ask1` holds at one question
  only.
* **Braces for a panel** — would make `{ … }` mean two things.
* **Renaming `flag` or `ack`** — `flag` is answered by `if`, and renaming `ack`
  would break `codeOfName_codeName`.
* **A `then`/`or` connective before the outcome clauses** — two more words to
  say what two participles already say.

---

## 12. Honest residue

1. **Not built.** This is a design. The Lean edits of §10 are specified, not
   applied, and the nine kernel proofs have not been re-run. The evidence
   for §8 is a faithful port of the lexer and both parsers, not the elaborator.
2. **The tail sits one level in.** `approved given patch { … }` indents the
   consent gate and the act, which is the one place this surface reads less like
   the twin than B's does. It is the price of never implying a join the library
   does not have.
3. **Position-independence of the plan is argued, not proved.** Six clauses of
   inspection; a dozen lines of structural induction would close it.
4. **`check` and `revise` take one question or one panel, not a block.** Their
   library type admits any plan, but the language has no value-returning block.
   The brace form is chosen so this can be relaxed later — `{ let x = ask …
   panel [ … ] }` — without moving a character of what exists.
5. **Branchings are terminal.** The library can express a sequel
   (`Plan.graft` of a `Cont Γ Unit Unit`); the surface does not, because the
   alternative is duplicating the sequel into every arm or making the emitted
   term depend on whether anything follows.
6. **`revise given p, why` is positional.** The artefact then the objections;
   the order is `check`'s order, which is the inference a reader makes and it is
   correct.
7. **`revision` and `revisions` are both accepted.** The only word in the
   language with two spellings, so that `up to 1 revision` is English.
8. **`act` cannot carry `using model`.** `RawBlock.act` has no model field
   today; adding one is a one-field change no existing program observes, and it
   is deliberately not bundled here.
9. **Two-word clause heads.** `up to`, `never approved` and `using model` are
   parsed as consecutive keywords. The language has no reserved words, so this
   costs nothing but the parser saying `expectKw` twice.
