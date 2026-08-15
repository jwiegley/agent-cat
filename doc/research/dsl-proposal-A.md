# Proposal A — the block-structured reading

*A surface for `Agentic/Core/Dsl`. Same language, same elaborator, same plan; a
different set of words and one structural rule: **a scope is a pair of braces,
and a name comes into being in a head that looks like a binding.***

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

Proposed:

```
  revising (patch = draft) up to 2 revisions {

    check {
      panel [ … ]
    }

    revise (why) {
      ask text from model "author" using model "deep" "…"
    }

    approved {
      let ok = ask flag from person "owner" "…"
      case ok {
        yes { act by tool "apply" "…" }
        no  { }
      }
    }

    never approved { }
  }
```

Everything the owner asked, answered by the shape rather than by a footnote:

| The question | The answer in this surface |
| --- | --- |
| *Does `revising draft upto 2` scope the indented elements?* | Yes, and it now says so: the four clauses are inside the construct's braces. Indentation carries no meaning anywhere in the language. |
| *Where is `patch` declared?* | In the head, once: `revising (patch = draft)`. It is spelled with `=`, like `let`, because it is the same act — a name coming into being with a value. It means "the artefact under revision" in every clause that has one. |
| *Does `check` bring `patch` into being?* | No, and it no longer looks as if it might: `check { … }` has no parenthesised name. Nothing but a head declares a name. |
| *What does `exhausted` mean?* | The word is gone. The two outcomes are `approved { … }` and `never approved { … }` — which one you are in is the sentence itself. |
| *What does `done` mean?* | The word is gone. Doing nothing is written `{ }`. |

---

## 2. The three rules the grammar obeys

1. **A scope is braces.** Every region in which a name is visible, and every
   region that is a workflow of its own, is `{ … }`. Nothing is delimited by
   layout, and no construct ends at the next keyword.
2. **A name is born in a head, and a head reads like a binding.** `define x =`,
   `let x =`, `revising (x = e)` all use `=`. A clause that is *handed*
   something names it in parentheses immediately after its keyword, and exactly
   one clause is handed anything: `revise (why)`.
3. **Every word is a word.** `upto`, `done`, `exhausted`, `accepted`, `with`,
   `@` and `->` are removed. What is left — `ask … from`, `act by`, `using
   model`, `up to n revisions`, `approved` / `never approved` — is either
   English or a name the library already uses in the sense the reader will
   guess.

A corollary of (1) that pays for itself: **brackets are a list, braces are a
scope.** `panel [ … ]` keeps its brackets because a panel binds nothing; it is
the same list the Lean twin writes.

---

## 3. The complete grammar

```
program   ::= {define} "workflow" block
define    ::= "define" name "=" string

block     ::= "{" {binding} [tail] "}"
binding   ::= "let" name "=" rhs
tail      ::= act | case | revising

rhs       ::= ask | panel
ask       ::= "ask" code "from" target [scope] string
panel     ::= "panel" "[" ask {"," ask} "]"
act       ::= "act" "by" target string

code      ::= "text" | "verdict" | "flag" | "ack"
target    ::= ("model" | "tool" | "person") string ["draw" nat]
scope     ::= "using" "model" string

case      ::= "case" name "{" "yes" block "no" block "}"
            | "case" name "{" "approve" block "object" block "declined" block "}"

revising  ::= "revising" "(" name "=" name ")" "up" "to" nat ("revision"|"revisions") "{"
                "check"  "{" rhs "}"
                "revise" "(" name ")" "{" rhs "}"
                "approved" block
                "never" "approved" block
              "}"

string    ::= "…" with {name} interpolation and \n \t \r \\ \" \{ \} escapes
comment   ::= -- to end of line
```

Six notes on the grammar, each of which is a decision:

* **A block may end without a tail.** `{ let x = ask … }` asks and stops; `{ }`
  does nothing. This is what deletes `done`: a block is a list of things to do,
  and when the list runs out the workflow is over. It is also what makes "do
  nothing" *look* like doing nothing, which the owner asked for.
* **A tail is terminal because a branching does not rejoin.** Nothing may follow
  `case` or `revising` inside a block: each arm, and each outcome, *is* the rest
  of the workflow. That is not a restriction invented by the surface — the
  library has no join — and stating it as "the last statement of a block" is how
  the surface tells the reader.
* **The head binder is in scope in `check`, `revise` and `approved`, and not in
  `never approved`.** There is no artefact there; that is what the clause's name
  says. Mentioning it is an error, and the error says so (§9).
* **`up to n revisions` names the unit of the numeral.** `Plan.revising`'s
  docstring records three independent readings getting `n` backwards. `up to 2
  revisions` is the true reading — three checks, at most two revisions — written
  where the numeral is. Either spelling of the noun is accepted so that `up to 1
  revision` reads as English.
* **The scope override is postfix and names its axis.** `using model "deep"`
  sits between the addressee and the words, where it does not interrupt the
  phrase, and the axis word (`model`) is there because a question's scope has a
  second axis (mode) that a later version can add without moving anything.
  `from model "author"` says *who is asked*; `using model "deep"` says *which
  model serves it* — two different fields of `Q.Shape` (`addressee` and
  `scope.axis₁`), and the two prepositions keep them apart.
* **`act` takes no `using`.** `RawBlock.act` has no model field today and this
  proposal does not add one. It is the one asymmetry left; adding it is a
  one-field change that no existing program observes, and it is deliberately not
  bundled here.

Keywords removed: `upto`, `with`, `accepted`, `exhausted`, `done`, `@`, `->`.
Keywords added: `from`, `by`, `using`, `up`, `to`, `revision(s)`, `revise`,
`approved`, `never`. The lexer loses the `arrow` token and `@` from its
punctuation set; the language still has no reserved words.

---

## 4. The flagship, rewritten

`example/harden.wf`. Same questions, same addressees, same prompts, same order,
byte for byte in every string.

```
define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {
  let guide = ask text from tool "cat"
    "Write out the house style guide, at most four short lines."

  let draft = ask text from model "author" using model "deep"
    "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  revising (patch = draft) up to 2 revisions {

    check {
      panel [
        ask verdict from model "reviewer-correct"
          "{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}",
        ask verdict from model "reviewer-secure"
          "{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}",
        ask verdict from model "reviewer-simple"
          "Could this patch be simpler?\n{patch}\n{verdictSpec}"
      ]
    }

    revise (why) {
      ask text from model "author" using model "deep"
        "{guide}\nRevise this patch:\n{patch}\n{why}\nReply with the revised diff only."
    }

    approved {
      let ok = ask flag from person "owner"
        "Apply this patch?\n{patch}\n{flagSpec}"

      case ok {
        yes { act by tool "apply"
                "Apply:\n{patch}\nWrite the patched file here, then reply DONE." }
        no  { }
      }
    }

    never approved { }
  }
}
```

Read it against `example/HardenPatch.lean`, which is the standard:

```lean
let guide : String ← ask "Write out the house style guide."
let patch ← revising 2 spec fun current => do
  let patch ← model "deep" <| ask s!"Draft a patch satisfying:\n{current}"
  let verdict ← panel [ … ]
  pure (patch, verdict)
let ok : Bool ← askHuman s!"Apply this patch?\n{patch}"
if ok then ask s!"Apply:\n{patch}" else pure ()
```

Line for line the same story: a guide, a draft, a bounded revision that names
its artefact once in its head, a consent question, and an act that happens only
on the `yes` side. The DSL says four things the Lean surface leaves to the
elaborator — who is asked, what kind of answer, how the answer must be spelled,
and what happens when the loop gives up — and nothing else.

The file no longer begins with a blank line (the current one does, for no
reason); `flagshipRaw`'s positions below count from the first `define`.

---

## 5. `hello.wf`, rewritten

```
-- The smallest program the language can write that is still a workflow: two
-- questions and an act. It exists so that `agent-cat` has a subject that is not
-- the flagship — cheap to run, `pipeline` rather than `branch`, and therefore
-- the one program whose bill the analysis knows exactly rather than bounds.
define brief = "Reply in one short line."

workflow {
  let subject = ask text from tool "cat"
    "Name one thing worth greeting.\n{brief}"

  let greeting = ask text from model "greeter"
    "Write a greeting for this, and nothing else:\n{subject}\n{brief}"

  act by tool "say"
    "Say it:\n{greeting}\nThen reply DONE."
}
```

Three words changed (`from`, `from`, `by`). It was already a good program; the
proposal must not make small programs longer, and it does not.

---

## 6. Line by line: what each decision answers

| # | Decision | Answers |
| --- | --- | --- |
| 1 | `revising (…) … { … }` — the four clauses live inside braces. | *"Does `revising draft upto 2` scope the indented elements? If so, why does it not use braces?"* Indentation now means nothing; the construct ends where its brace does. |
| 2 | `(patch = draft)` in the head. | *"Where is `patch` declared?"* Once, in the head, with `=`, exactly as `let x = …` and `define x = …` declare. |
| 3 | The same `patch` in `check`, `revise`, `approved`. | *"…that is used/referenced in the line `check (patch) {`"* — one declaration, one meaning: the artefact under revision. Three parenthesised binders that were always spelled the same word are now one word. |
| 4 | `check { … }` loses its binder. | *"Does that check statement also bring it into being? The use of scoping after check does not imply this."* Correct — and now nothing implies it, because only a head declares. |
| 5 | `revise (why)` keeps one binder. | The verdict *is* new here and nowhere else. A clause names in parentheses whatever it is handed beyond the artefact, and only this clause is handed anything. Matches the library: `reviseCont` is the one continuation of arity two. |
| 6 | `approved` / `never approved`. | *"What does `exhausted` mean?"* It meant "the revision budget ran out with objections outstanding", which is the same thing as "it was never approved", so the clause now says that. The pair is symmetric: both name the *verdict outcome*, not one the verdict and one the budget. |
| 7 | `{ }` for nothing, and `done` deleted. | *"What does `done` mean?"* Nothing that an empty block does not already say. An act is terminal, so a workflow that ends without one simply ends. |
| 8 | `up to 2 revisions`. | `upto` is not a word, and the bare numeral did not say what it counted. The Lean twin writes `revising 2 spec`, where the `2` is the argument of a function whose docstring has to explain it; the DSL has the room to say it in the phrase. |
| 9 | `ask text from tool "cat"`. | The owner's suggestion. It also removes a real ambiguity: `ask text tool "cat" "…"` is four juxtaposed atoms and a reader has to know the arity to parse it; `from` marks where the addressee starts. |
| 10 | `act by tool "apply"`. | Symmetry with `ask … from`: you get an answer *from* somebody and something is done *by* somebody. `act` is kept as its own word because an act is terminal and an `ask` is not; the library agrees (`Plan.ask .ack … (.ret ())` with nothing after it). |
| 11 | `using model "deep"` after the addressee. | *"putting the model override where it does not interrupt the phrase"* — `let draft = @model "deep" ask text model "author"` put a scope annotation between `=` and the verb. It also **misled**: a prefix looks like it governs the statement, and `Plan.under σ` really is a fold over a whole plan; the reason the checker may write it as a shape rewrite is `under_ask1`, which holds *at one question only*. Postfix says one question. |
| 12 | `yes { … } no { … }` — no `->`. | Braces already delimit the arm. The arrow was a second delimiter that said nothing, and it was the only two-character lexeme in the language. |
| 13 | `case` keeps every arm, and an empty arm is `{ }`. | The library demands totality (`Plan.case` over a `FinEnum`). An `if`/`else` with an elidable branch would hide exactly what the semantics insists on; the empty block makes "and otherwise, nothing" visible and one character long. |
| 14 | `panel [ … ]` keeps brackets and commas. | It is a list, not a scope, and it is the Lean twin's own notation. Braces are reserved for scopes so that "braces mean a scope" is a rule with no exceptions. |
| 15 | A block may end with no tail. | The Lean twin's `do` block ends when it ends. Requiring `done` was requiring a word to say that a list is over. |
| 16 | Blocks are parsed by one function that consumes its own braces. | Every `{` in the language is opened by the same code, so "every scope is braced" is a property of the grammar rather than a habit of eight call sites — the eight places (two `case` arms, three verdict arms, two `revising` outcomes, the `workflow` body) that each open and close a block by hand today. |

---

## 7. What each construct elaborates to

Nothing in this column changes. This is the current elaborator, and it is the
argument of §8.

| Surface | Library object (`Agentic/Core/Dsl/Check.lean`) |
| --- | --- |
| `workflow { … }` | `check [] [] : Raw → Except CheckError (Plan [] Unit)` |
| `define x = "…"` | Nothing. Textual expansion into `Prompt` chunks in `Parse.expand`; no term mentions it. |
| `let x = ask c from t "…"`, prompt closed | `Plan.askC c (s.withPrompt words) k` — the batch rung (`Prompt.closed = some`) |
| `let x = ask c from t "…"`, prompt mentioning a name | `Plan.ask c s e k`, `e : Expr Γ String` — the pipeline rung |
| `let x = panel [ … ]` | `Plan.graft (Plan.panel ps) (fun _ σ e => Plan.sub k (Env.cons (e δ) (σ δ)))` |
| `ask …` as a panel member or clause value | `Plan.askC1` / `Plan.ask1` (`checkAsk`) |
| `panel [a₁, …, aₙ]` | `Plan.panel [p₁, …, pₙ]`, folded in the monoid of `El .verdict`; rejected at any other code |
| `from model/tool/person "id"` | `Q.Shape.addressee := Addressee.model/tool/person "id"` |
| `draw n` | `Q.Shape.draw := n` |
| `using model "m"` | `atModel m c s`, i.e. `s.scope := Scope.fst m * s.scope`; equal to `Plan.under (atModel m)` at one question by `under_ask1` / `under_askC1` |
| `"…{x}…"` | `Expr Γ String`: literals are constants, `{x}` is the de Bruijn variable `Bindings.find?` resolves, concatenated **left-associated** (`Prompt.expr`) |
| `act by t "…"` | `Plan.askC .ack (s.withPrompt words) (.ret fun _ => ())`, or `Plan.ask .ack s e (.ret …)` |
| `{ }` / a block with no tail | `Plan.ret (fun _ => ())` |
| `case x { yes {…} no {…} }` | `Plan.caseB e y n` |
| `case x { approve {…} object {…} declined {…} }` | `Plan.caseV e arms`, `arms : VTag → Plan Γ Unit` |
| `revising (p = a) up to n revisions { … }` | `Plan.graft (Plan.revising (checkCont chk) (reviseCont rev) n Γ Sub.id b.val) (finishCont accP exhP)` |
| ‥ `check { … }` | `checkCont : Plan (c :: Γ) (El .verdict) → Plan.Cont Γ (El c) Verdict`; `p` is de Bruijn 0 |
| ‥ `revise (why) { … }` | `reviseCont : Plan (.verdict :: c :: Γ) (El c) → Plan.Cont Γ (El c × Verdict) (El c)`; `why` is de Bruijn 0 bound through `Verdict.render`, `p` is de Bruijn 1 |
| ‥ `approved { … }` / `never approved { … }` | `finishCont acc exh = Plan.caseB (isSome ∘ final) (Plan.sub acc …) (Plan.sub exh σ)` |

Two facts about this table worth keeping in the guide, because they are the
whole reason the language is worth having: no clause emits `Plan.dyn`, and every
program therefore sits at or below the branch rung
(`Dsl.parseAndCheck_level_le`); and `check`'s type — `Except CheckError (Plan Γ
Unit)` — is the soundness statement, not a claim about it.

---

## 8. The plan does not change

The claim: `check [] [] flagshipRaw` returns the **same term** before and after,
so `flagshipPlan` is the same plan, so every theorem in
`Agentic/Core/DslFlagship.lean` about it — `level_flagshipPlan`,
`card_leaves_flagship`, `minFold_flagship`, `maxFold_flagship`, the four
`trace_flagship_*`, the four `bill_flagship_*`, `flagshipUpTo`,
`flagship_bill_le`, `minFold_flagship_le_bill` — keeps its statement byte for
byte and keeps its proof (`decide +kernel` on the same numbers, or a `rw`
through one of them).

The argument has three steps.

**(a) The elaborator is untouched except in the names it reads.** The only
change in `Agentic/Core/Dsl/Check.lean` is that the `revising` clause reads one
artefact name where it read three:

```lean
  | Γ, S, .revising art subj n chk why rev acc exh pos =>
    …
    let Swith : Bindings (Code.verdict :: b.code :: Γ) :=
      ⟨art, b.code, fun δ => Env.head (Env.tail δ)⟩ ::
      ⟨why, Code.text, fun δ => Verdict.render (Env.head δ)⟩ ::
      Bindings.rename Sub.wk (Bindings.rename Sub.wk S)
    match checkRhsAt Code.verdict (Bindings.push art b.code S) chk … with
    …
    match checkBlock (b.code :: Γ) (Bindings.push art b.code S) acc with
    …
    .ok (Plan.graft (Plan.revising (checkCont chkP) (reviseCont revP) n Γ Sub.id b.val)
                    (finishCont accP exhP))
```

`cv`, `av`, `pv` become `art`; `wv` becomes `why`. Nothing else moves. Since
the flagship already wrote `patch` for all three of `cv`, `av`, `pv`, and `why`
for `wv`, the *inputs* to name resolution are identical, so the de Bruijn
indices are identical, so the emitted term is identical.

**(b) Positions never reach a plan.** Every occurrence of a `Pos` in
`checkBlock`, `checkBinder`, `checkAsk`, `chunkExpr`, `Prompt.expr` and
`lookupBinding` is an argument to a `CheckError` constructor, i.e. lives under
`.error`. The success path is a function of codes, shapes, prompts, structure
and names alone. So a source that re-lays-out the same program checks to the
same plan.

**(c) The two sources denote the same raw syntax, modulo (a) and (b).** Checked
mechanically rather than by eye: `/tmp/wfcheck.py` is a line-for-line port of
`Parse.lean`'s lexer (`scanString`, escapes, interpolation, comments, positions)
together with **both** parsers — the current grammar and this one — and it
compares the two ASTs with positions dropped and the `revising` node normalised.

```
$ python3 /tmp/wfcheck.py example/harden.wf /tmp/harden-A.wf example/hello.wf /tmp/hello-A.wf
harden: same AST modulo positions: True
hello : same AST modulo positions: True
```

The comparison is on the fields the elaborator reads: every `Code`, every
`Addressee`, every `draw`, every model override, every prompt as a *chunk list*
after `define` expansion and `Prompt.normalize` (so the three-literal
`"Draft a patch satisfying:\n" / "harden the parser" / "\nReply with a unified
diff only."` split survives unfused, which is what keeps `Prompt.expr`'s
left-associated `++`-chain equal to `Harden.draftText`), the block structure,
and every binder name.

**The new `flagshipRaw`**, emitted by the same script from the source in §4, and
the only edit `DslFlagship.lean` needs:

```lean
def flagshipRaw : Raw :=
  RawBlock.bind "guide"
    (RawRhs.ask
      { model := none, code := Code.text,
        target := { addressee := Addressee.tool "cat", draw := 0 },
        prompt := [Chunk.lit "Write out the house style guide, at most four short lines."],
        pos := { line := 6, col := 15 } })
    (RawBlock.bind "draft"
      (RawRhs.ask
        { model := some "deep", code := Code.text,
          target := { addressee := Addressee.model "author", draw := 0 },
          prompt := [Chunk.lit "Draft a patch satisfying:\n", Chunk.lit "harden the parser",
            Chunk.lit "\nReply with a unified diff only."],
          pos := { line := 9, col := 15 } })
      (RawBlock.revising "patch" "draft" 2
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
        "why"
        (RawRhs.ask
          { model := some "deep", code := Code.text,
            target := { addressee := Addressee.model "author", draw := 0 },
            prompt := [Chunk.interp "guide", Chunk.lit "\nRevise this patch:\n",
              Chunk.interp "patch", Chunk.lit "\n", Chunk.interp "why",
              Chunk.lit "\nReply with the revised diff only."],
            pos := { line := 26, col := 7 } })
        (RawBlock.bind "ok"
          (RawRhs.ask
            { model := none, code := Code.flag,
              target := { addressee := Addressee.person "owner", draw := 0 },
              prompt := [Chunk.lit "Apply this patch?\n", Chunk.interp "patch",
                Chunk.lit "\n", Chunk.lit "Reply with exactly yes or no."],
              pos := { line := 31, col := 16 } })
          (RawBlock.caseFlag "ok"
            (RawBlock.act { addressee := Addressee.tool "apply", draw := 0 }
              [Chunk.lit "Apply:\n", Chunk.interp "patch",
               Chunk.lit "\nWrite the patched file here, then reply DONE."]
              { line := 35, col := 15 })
            (RawBlock.empty { line := 37, col := 13 })
            { line := 34, col := 7 })
          { line := 31, col := 7 })
        (RawBlock.empty { line := 41, col := 20 })
        { line := 12, col := 3 })
      { line := 9, col := 3 })
    { line := 6, col := 3 }
```

Compare it with the one in the tree: the codes, addressees, prompts and block
structure are character-identical; `RawBlock.revising "draft" 2 "patch" … "patch"
"why" … "patch" …` has become `RawBlock.revising "patch" "draft" 2 … "why" …`;
`RawBlock.done` has become `RawBlock.empty`; and the positions have moved — the
first four nodes up a line, since the file lost its leading blank line, and the
columns by the width of the new words. Nothing else.

**What still has to be *run*, and where.** `flagshipRaw_accepted`,
`level_flagshipPlan`, the three cost-tree numbers and the four transcript
equalities are `decide +kernel` on the new `flagshipRaw`; they must be
re-elaborated, and they must still say 9, 5, 15, 6, 7, 13, 15. Nothing in the
argument above is a substitute for that build. The cost is the same as today's
(the term the kernel reduces is the same size, and `flagshipRaw` is written out
precisely so that the *lexer* never runs in the kernel).

**One statement in the tree becomes slightly stale and should be corrected, not
weakened**: `DslFlagship`'s docstring sentence "The file begins with a newline
because this literal did, and `flagshipRaw`'s positions count lines from it."
The file no longer does; the sentence should go.

---

## 9. Diagnoses that come with the shape

Three messages the new grammar makes possible; each replaces a message that was
correct but less useful, and each is a one-line change.

| Situation | Message |
| --- | --- |
| A name mentioned in `never approved` that only the head declares | ``there is no `patch` in this clause: `never approved` is the outcome in which the revision produced none`` (needs a `RawBlock.mentions : String → RawBlock → Bool`, first-order like `RawBlock.bounded`; separable from the rest of the proposal) |
| A question in tail position | ``a question here has nowhere to put its answer: write `let x = ask …`, or `act by …` if the point is the doing`` (replaces "a block ends in `done` or `act`", which now names two words that no longer exist) |
| An unfinished block | ``expected a statement (`let`), a tail (`act`, `case`, `revising`), or `}` `` |

The bound refusal keeps its wording and changes its excerpt: `` at `up to 65
revisions` ``.

---

## 10. What has to change in the tree

Surface only; no theorem statement moves.

| File | Change |
| --- | --- |
| `Agentic/Core/Dsl/Syntax.lean` | `RawBlock.revising` loses three fields and gains none (`art subj n chk why rev acc exh pos`); `RawBlock.done` renamed `RawBlock.empty`; docstrings for both. |
| `Agentic/Core/Dsl/Parse.lean` | `parseBlock` consumes its own braces and takes an optional tail; new keywords; `Token.arrow` and `'@'` removed from the lexer; three messages from §9. Net: shorter. |
| `Agentic/Core/Dsl/Check.lean` | `cv/av/pv → art`, `wv → why`, `.done → .empty` in `checkBlock`, `RawBlock.bounded` and the `checkBlock_bounded` induction (case names only). |
| `Agentic/Core/Explain.lean` | `.done → .empty` in `RawBlock.revisionBounds` and its induction; `revisionLines` prints `up to n revisions` so that it quotes the source. |
| `Agentic/Core/DslFlagship.lean` | `flagshipRaw` as in §8; one docstring sentence; the nineteen kernel proofs re-run unchanged. |
| `example/harden.wf`, `example/hello.wf` | §4, §5. |
| `test/DslSmoke.lean` | Eleven embedded sources and ten expected diagnoses (positions and wording). |
| `test/McpSmoke.lean`, `test/CliSmoke.lean` | The hostile `upto 1000000000` source; `splitOn "upto 2"` → `"up to 2 revisions"`. |
| `doc/mcp.md`, `doc/dsl-guide.html` | The worked example, the bullets and the reference card. |

Off limits and untouched by this proposal: `Agentic/Surface.lean`,
`example/HardenPatch.lean`, `Agentic/Core/HardenPatch.lean`, `doc/PLAN.org`,
`Agentic/Core/{Acp,Exec,Artifact}.lean`, `cli/AgentCat.lean` (the CLI reads only
`parseAndCheck` and `Explain`, so it needs no edit).

---

## 11. Alternatives considered and rejected

* **`if ok { … } else { … }` for a flag.** More familiar than `case`, and it
  invites an elided `else` — precisely the elision `Plan.case`'s `FinEnum`
  forbids. `case … { yes { … } no { } }` keeps totality visible at a cost of one
  brace pair.
* **Reusing the subject's name (`revising draft up to 2 revisions { … }`) so
  that no second name appears.** It rebinds `draft` invisibly to a different
  slot inside the block: shadowing with no binder in sight, which is the thing
  the head binder exists to prevent.
* **Allowing a question in the head (`revising (patch = ask text from … "…") …`).**
  It reads well and it desugars to the same plan, but it puts a five-line prompt
  inside the head of a construct whose head should be readable in one glance.
  `let draft = …` is that same line, one line earlier.
* **`accepted` / `unapproved`, or `approved` / `otherwise`.** `unapproved` is
  not a word anyone says; `otherwise` names no outcome and would have earned the
  owner's question a second time. `never approved` is a sentence.
* **Braces for a panel.** They would make `{ … }` mean two things.
* **Keeping `@model` where the Lean twin puts the scope (before the verb).** The
  Lean twin's `model "deep" <| …` genuinely scopes a whole `W`; the DSL's does
  not and must not (`under_ask1` holds at one question). Writing it in the same
  place would import the wrong reading.
* **Renaming the codes (`flag` → `yesno`, `ack` → …).** `flag` is answered by
  the arms `yes`/`no` two lines later, and renaming `ack` would break the
  retraction `codeOfName_codeName`. Left alone.

---

## 12. Honest residue

* **Not built.** This document is a design; the Lean edits in §10 are specified,
  not applied, and the nineteen kernel proofs have not been re-run. The evidence
  for §8 is a faithful port of the lexer and both parsers (`/tmp/wfcheck.py`),
  not the Lean elaborator.
* **Position-independence of the plan is argued by inspection, not proved.**
  It could be proved — "`checkBlock` is invariant under any relabelling of the
  `Pos` fields" is an ordinary structural induction — and it would be worth a
  dozen lines if positions ever change again.
* **The head binder does not scope the whole block.** `never approved` is
  outside it, necessarily and for a good reason, and the surface communicates
  that by the clause's name plus a diagnosis. It is the one place where the rule
  "the head declares, the braces scope" has a stated exception.
* **`act` cannot carry `using model`.** Pre-existing; noted in §3.
* **The parser accepts `revision` and `revisions` alike.** A deliberate second
  spelling — the only one in the language — so that `up to 1 revision` reads as
  English.
