# PORTING3 — the monadic surface

*The design of record for the authoring surface of the Haskell port. It
replaces `Agentic.Builder`'s type-application spelling **as the thing a human
writes**, and changes nothing below it: `Agentic.Builder` stays exactly as it
is, elaboration and printing are the single proven pairing, and everything
here compiles down to the `Blk` / `Body` / `Rhs` index-level forms already
pinned by tier1.*

---

## 0. Standing, and what is already proven

The Builder is correct and stays. What is rejected is its **surface**: the
flagship reads as

```haskell
bind @"guide" @'CodeText (one (askTool "cat" [lit "…"])) $
  bind @"draft" @'CodeText (one (askModelServed "author" "deep" [lit "…", lit spec, lit "…"])) $
    revisingCase @"draft" @"patch" @"verdict" @"patch" "result" 2 Nothing …
```

and it should read as `example/harden.wf` reads. The bar is that file; the
target reader is a Haskell aesthete; the result must be **pure** (no `IO` in
authoring) and must be **sugar** — every combinator below is an application of
an existing Builder entry point.

**This document is not a sketch.** The whole surface — the indexed monad, the
`QualifiedDo` modules, the `[wf|…|]` quoter, the flagship and `hello` rewritten
in it — was prototyped against stub `Raw` types and **compiles under the
project's GHC 9.10.3**, and its printed prompts were checked chunk-for-chunk
against `test/corpus/example-000-*.json` and `example-001-*.json`:

* prototype: `haskell/PORTING3-proto/{Surface,W,R,Quote,Harden,Main}.hs`
  (from `PORTING3-proto/`:
  `nix develop .. -c ghc -Wall -o proto-main Surface.hs W.hs R.hs Quote.hs Harden.hs Main.hs && ./proto-main`);
* refusal cases: `PORTING3-proto/{Bad,Bad2}.hs`, each error quoted verbatim in
  §5;
* all **eleven** prompts of `harden` and `hello` come out identical to the
  frozen chunks, including the deliberately un-fused adjacent literals.

Everything asserted below about what typechecks, what does not, and what the
quoter emits, was observed, not assumed.

---

## 1. What the corpus fixes — the constraints any surface must satisfy

### 1.1 Names are data

`zeroPos (progRawOut hardenProgram)` must stay value-equal to
`example-000`'s `request.program`. That program contains, as **strings**:

| string | where it appears in the frozen `Raw` |
|---|---|
| `guide` | `bind.x`, and `interp` in three prompts |
| `draft` | `bind.x`, and `revising.subject` |
| `patch` | `revising.carrier`, `caseResult.settledName`, and `interp` in six prompts |
| `verdict` | `revising.reviewName`, and `interp` in the amend prompt |
| `result` | `bind.x` of the revising bind **and** `caseResult.x` |
| `ok` | `bind.x`, and `ifFlag.x` |

So the surface **carries names**. The only question is where they come from
(§2.2 shows the one place they cannot come from).

### 1.2 Chunking is normative, and fusion is a bug

`Prompt.normalize` (`Agentic/Core/Dsl/Syntax.lean:152`) drops empty literals
and **deliberately does not fuse adjacent literals** — the comment there says
why (`Prompt.expr` is a left-associated `++`, and the flagship's transcript
agreements are computations, not appeals to `String.append_assoc`). A `define`
spliced into a prompt contributes **its own chunk**. Hence, from the frozen
entry:

```json
"prompt": [ {"lit": {"s": "Draft a patch satisfying:\n"}},
            {"lit": {"s": "harden the parser"}},
            {"lit": {"s": "\nReply with a unified diff only."}} ]
```

Three chunks, not one. Any surface that renders a prompt to a single `Text`
before printing is wrong on this entry.

### 1.3 A prompt is data over names, never a function of an answer

`Prompt.closed` decides `PAskC` from `PAsk`, i.e. `batch` from `pipeline` in
the `level` fold. A prompt is closed exactly when it holes nothing. Therefore
a surface in which a prompt is a Haskell function `a -> Prompt` of the artifact
flowing in — agent-functor's `brief`/`fixed` shape — **cannot print this
program at all**: every prompt would be closed and the flagship's rung would
change. This kills the literal transplant of `Agent.Flow`, and it is the
reason §2.3 keeps `[wf|…|]` even in the arrow-flavoured sketch.

### 1.4 The kind of a binding

`bindKind` (`Check.lean:265`) takes the annotation, else the first ground use,
else refuses. `usePrompt` (`Check.lean:207`) is explicit that **a hole reads
its name as `text`** — "a name whose only use is being spliced is a text
question" — while panels, review bindings and `case` arms ground `verdict`
*positionally*, and `if` grounds `flag`.

Haskell has no defaulting at kind `Code`, so this is reproduced structurally
(§3.4): a bare question in binding position **is** a text question; positions
that impose a kind impose it; `confirm` is the flag question; `answering`
states a kind that nothing else fixes. The printed `Raw` is unaffected either
way — `RawAsk` has no kind field — so this choice cannot change the corpus
program, only the `Plan`, which tier1's reply comparison pins.

### 1.5 The pending revision

`Check.lean:527`: a bounded revision's result is not a value — it is carried as
a `Pend Γ` that *the very next statement must consume*, and every other
statement is refused by name while it is pending. `revisingCase` fuses the two
in the Builder. The surface reproduces the *pairing* rather than the fusion,
with a two-constructor kind `Stage` (§3.2): `revising` moves the block from
`Open s` to `Pending c s`, and `caseResult` is the only statement that accepts
a `Pending` block.

---

## 2. Three surfaces for the same fragment

The fragment is `example/harden.wf` lines 10–68 — draft, revising, panel,
amend, `case result`. Here is the bar, verbatim:

```
  draft <- ask model "author" served by "deep" ```
      Draft a patch satisfying:
      {spec}
      Reply with a unified diff only.
  ```

  result <- revising draft as patch, at most 2 amendments {

    verdict <- panel, all must approve [
      ask model "reviewer-correct" ```
          {guide}
          Is this patch correct?
          {patch}
          {verdictSpec}
      ```,
      …
    ]

    amend patch {
      ask model "author" served by "deep" ```
          {guide}
          Revise this patch:
          {patch}
          {verdict}
          Reply with the revised diff only.
      ```
    }
  }

  case result {
    settled patch {
      ok <- ask person "owner" ```…```
      if ok { ask tool "apply" ```…``` } else { stop }
    }
    unsettled { stop }
  }
```

### 2.1 Sketch A — indexed CPS monad, `QualifiedDo`, `OverloadedLabels`, `[wf|…|]`

```haskell
  draft <- #draft =: ask (model "author" `servedBy` "deep") [wf|
      Draft a patch satisfying:
      {spec}
      Reply with a unified diff only.|]

  #result =: revising draft #patch (atMost 2) \patch -> R.do
    verdict <- #verdict =: panel
      [ ask (model "reviewer-correct") [wf|
          {guide}
          Is this patch correct?
          {patch}
          {verdictSpec}|],
        ask (model "reviewer-secure") [wf|
          {guide}
          Is this patch secure?
          {patch}
          {verdictSpec}|],
        ask (model "reviewer-simple") [wf|
          Could this patch be simpler?
          {patch}
          {verdictSpec}|]
      ]
    amend (ask (model "author" `servedBy` "deep") [wf|
      {guide}
      Revise this patch:
      {patch}
      {verdict}
      Reply with the revised diff only.|])

  caseResult #patch
    ( \patch -> W.do
        ok <- #ok =: confirm (person "owner") [wf|
            Apply this patch?
            {patch}
            {flagSpec}|]
        ifFlag ok
          ( W.do
              act (tool "apply") [wf|
                Apply:
                {patch}
                Write the patched file here, then reply DONE.|]
              stop )
          stop )
    stop
```

Binds are real Haskell binds; `patch` inside the loop is a real lambda binder
that exists only there; the prompts are prose; there is not one type
application in the whole flagship.

### 2.2 Sketch B — the same monad, with the names inferred instead of labelled

The label `#draft` is the only visible tax. Can the surface recover it? Two
routes, and both are worth writing down because the first is *impossible* and
the second is merely bad.

**B1: infer names from the quoter's holes.** Every name that a prompt holes is
already spelled in the source (`{guide}`, `{patch}`, `{verdict}`), so the
quoter could register it. This fails on the corpus, decisively:
`harden.wf`'s **`draft`, `result` and `ok` are never spliced into any prompt**
— `draft` is only a `revising` subject, `result` only a `case` scrutinee, `ok`
only an `if` scrutinee — and yet the frozen `Raw` prints all three
(`revising.subject = "draft"`, `caseResult.x = "result"`, `ifFlag.x = "ok"`).
There is nothing in any prompt for a quoter to read them off. B1 cannot print
`example-000`. It is not a matter of effort.

**B2: recover the names from the Haskell binder, with Template Haskell over
the block.** This *is* possible — a splice over a quoted `do` block sees
`BindS (VarP n) rhs` and `nameBase n` is `"draft"`:

```haskell
hardenProgram :: Program
hardenProgram = $(workflow [| W.do
    guide  <- ask (tool "cat") [wf|Write out the house style guide, at most four short lines.|]
    draft  <- ask (model "author" `servedBy` "deep") [wf|…|]
    result <- revising draft `as` patch `atMost` 2 do
        verdict <- panel [ … ]
        amend (ask (model "author" `servedBy` "deep") [wf|…|])
    caseResult result (\patch -> do …) stop |])
```

and it is rejected:

* the surface stops being a library and becomes a macro — the `workflow`
  splice must *walk and rewrite* Haskell's AST, which is the one kind of parser
  a port that swore off parsers should least like to own;
* every type error is then reported against generated code, at the splice's
  position: the two errors that make this design safe (`this name is already in
  scope: guide`, `nothing follows a terminal`) become errors about `bindI`
  applications the author never wrote;
* `as`/`atMost`/`patch` in the quote are not identifiers of anything — they are
  syntax that the splice recognises, i.e. a second surface language living
  inside a bracket, which is exactly `D10`'s hazard wearing a Haskell hat;
* nested quasiquotes inside a bracket, `where`-bound defines, and imports all
  need the splice to be careful in ways that no test can enumerate.

Sketch A pays one `#label` per binding and buys back all of that. The label is
also *honest*: the name in the printed program is the author's name for the
question, and the Haskell variable is the Haskell variable. They are written
the same by convention (§5.5), and the surface is never in the business of
reading Haskell.

**This rejection has been overruled. See §2.2-REVISED.**

### 2.2-REVISED — the owner's ruling

The owner, twice, on the landed flagship:

> `guide <- #guide =: ask` is pretty bizarre, when it could just be `guide <-`

> i mean, `guide <- ask`

So B2 ships, as `Agentic.Notation` (`src/Agentic/Notation.hs`), and
`Example.Harden` is written in it. Sketch A is not withdrawn: it is what B2
*compiles to*, it stays exported in full, and an author who wants the labels
written out writes them and imports `Agentic.Workflow` directly. What changed
is which of the two a human is expected to write.

**Two of §2.2's four objections were void by the time the ruling landed.**

*Nesting.* "Nested quasiquotes inside a bracket … need the splice to be careful
in ways that no test can enumerate" was a guess, and it is wrong on this
compiler: a `[wf|…|]` inside a `[| … |]` compiles under GHC 9.10.3, and the
flagship is now the test — eleven quasiquotes inside two brackets, `where`-bound
`define`s and all, printing the frozen chunks.

What the bracket actually does is worth writing down, because it is the whole
implementation. A binder inside `[| … |]` is renamed to a unique before the
splice sees it (`BindS (VarP draft_a3GP) …`, and `nameBase` is `"draft"`), while
a hole the quoter expanded *in* that bracket stays dynamically bound — `mkName
"draft"`, resolved in the ordinary lexical scope at the splice site. The two
halves would never meet, so every rebuilt binder is an **as-pattern**,
`draft_a3GP@draft`: the unique half receives the uses the author wrote in the
bracket (`revising draft`), the `mkName` half receives the uses the quoter wrote
(`{draft}`), and they are one value. That is the only trick in the module, and
it is why no substitution pass over the author's expressions is needed.

*The label's own hazard.* The mutation test on the landed module showed that
`#drafted =:` beside a binder called `draft` compiles clean, and that **only the
frozen corpus catches it** — §5.5's "the failure mode is a program that prints a
name the reader did not expect" is real, and it is invisible without the corpus.
With every name taken from the binder, that whole class is unrepresentable:
there is no second spelling of a name anywhere in `Example.Harden`, and no
string in `example-000`'s program that is not a binder in the source.

**The remaining two objections are answered by the shape of the transformer,
not waved away.**

*"The surface stops being a library and becomes a macro."* It does not, because
the splice is a **name-injector** and its output is the landed surface,
verbatim. Here is what `$(workflow [| … |])` produced for a four-statement
program, as GHC printed it back in an error:

```haskell
bindW ((=:) #guide (ask (tool "cat") (concat [[lit (pack "g")]])))
  (\ guide_a3GO@guide ->
     bindW ((=:) #draft (ask (model "a") …))
       (\ draft_a3GP@draft ->
          bindW ((=:) #result (revising draft_a3GP #patch (atMost 2)
                                 (\ patch_a3GR@patch ->
                                    bindR ((=:) #verdict (panel [...]))
                                      (\ verdict_a3GS@verdict -> amend …))))
            (\ result_a3GQ@result ->
               (\ () -> caseResult #patch (\ patch_a3GT@patch -> …) stop)
                 result_a3GQ)))
```

Every name in it — `bindW`, `bindR`, `thenW`, `=:`, `#label`, `revising`,
`caseResult` — is an `Agentic.Workflow` export, applied exactly as declared.
Nothing was invented, nothing was elaborated, and the `Raw` this builds is the
`Raw` the builder builds.

*"`as`/`atMost`/`patch` in the quote are not identifiers of anything — a second
surface language living inside a bracket."* That was a fair objection to the
sketch, which invented `` `as` `` and infix `` `atMost` ``. The shipped notation
invents nothing: **every function inside the bracket is an ordinary
`Agentic.Workflow` export**, `revising` and `caseResult` included, and the
transformer knows only where their *lambdas* are. The recognised set is closed
at **three binding shapes**, and they are the three places the printed `Raw`
needs a name the author chose:

1. a statement bind `x <- e`, anywhere in the block including a nested one,
   which becomes `bindW (#x =: e) (\x -> …)`;
2. the carrier lambda of `revising` — `revising draft (atMost 2) \patch -> do …`
   — whose binder names the carrier and restores the `#patch` argument the
   surface declares;
3. the settled lambda of `caseResult` — `caseResult result (\patch -> do …) stop`
   — whose binder names the settled binding and likewise restores its `#patch`.

Everything else passes through verbatim. `do` is rewritten (the splice emits the
chain itself, so there is no `QualifiedDo` at the use site and no
`RebindableSyntax` anywhere), and the walk descends only through application and
parentheses — enough to find the `do`s that are block arms, and not enough to
look inside a prompt, a panel or a list. The transformer does not know what
`ask`, `panel`, `amend`, `ifFlag`, `act` or `stop` are.

**Where each printed name comes from now**, replacing §3.3's table for the
notation (the surface's own table stands unchanged, since it is still the
compilation target):

| printed field | value | taken from |
|---|---|---|
| `bind.x` | `guide`, `draft`, `ok`, `verdict`, `subject`, `greeting` | the statement's own binder (shape 1) |
| `bind.x` of the loop, and `caseResult.x` — one name, printed twice | `result` | the binder of the statement that revises (shape 1) |
| `revising.subject` | `draft` | the handle passed to `revising`, whose symbol is the `draft <-` binder |
| `revising.carrier` | `patch` | the carrier lambda's binder (shape 2) |
| `revising.reviewName` | `verdict` | the review's binder inside the revision block (shape 1) |
| `caseResult.settledName` | `patch` | the settled lambda's binder (shape 3) |
| `ifFlag.x` | `ok` | the handle passed to `ifFlag`, whose symbol is the `ok <-` binder |

`caseResult`'s **scrutinee prints nothing** — `revisingCaseI` is handed the
result name once, from the bind — so `caseResult result` could have been dropped
on the floor. It is not: a revision binds `()`, and the splice emits the arms
under a `\() -> …` applied to the author's scrutinee, which makes `result` a
real use (a typo is `Variable not in scope`) and a wrong name a type error.
Observed, for `caseResult guide (…) stop`:

```
• Couldn't match type ‘V "guide" CodeText’ with ‘()’
```

**The one objection that stands, and its measured size.** Errors that belong to
the *generated* half are now reported at the splice, with the generated
expression quoted. `stop` followed by a statement, which §3.2 observed at the
statement, is now:

```
Bad2.hs:14:4: error: [GHC-64725]
    • nothing follows a terminal: `stop`, `if` and `case` end a block
    • In the expression:
        thenW stop (thenW (act (tool "t") (concat [says guide])) stop)
```

— the rule still names itself, and the quoted expression is readable, but the
caret is on the splice and not on the offending line. Against that: the
notation's *own* refusals are splice-time failures that quote the source and
name the rule, which the surface could not do at all. A revision with two
reviews:

```
Bad3.hs:14:4: error: [GHC-39584]
    • a bounded revision reviews first — `verdict <- panel […]` — and then
      amends, and has no other statement.
    • In the untyped splice: $(workflow [| do draft <- ask (model "a") …
```

and likewise for a block that is not a `do`, a bind whose pattern is not a plain
variable, a lambda that does not name its carrier, and a qualified `do` inside
the bracket. Errors in the *author's* half — a mistyped hole, `served by` on a
tool, a flag spliced into a prompt, a name read where it is not live — are
unchanged, because those expressions are passed through untouched.

**One new cost, which §2.2 did not foresee.** An authoring module needs
`{-# OPTIONS_GHC -Wno-unused-matches #-}`. A binding whose only reader is a
`{hole}` — `guide`, `verdict`, both `patch`es, `subject`, `greeting` — is
invisible to the renamer that walks the bracket, because the hole resolves at
the splice; GHC reports fourteen `Defined but not used` warnings on the flagship
without it, half at the bracket's statements and half at the splice. The pragma
is one line, in the module header, next to the sentence that explains it.

**The final notation** — `example/Example/Harden.hs`, which is the deliverable
§4 now describes only as a compilation target (its prompt text remains the
byte-accurate reference):

```haskell
hardenProgram :: Program
hardenProgram = $(workflow [| do
    guide  <- ask (tool "cat") [wf|Write out the house style guide, at most four short lines.|]
    draft  <- ask (model "author" `servedBy` "deep") [wf|
        Draft a patch satisfying:
        {spec}
        Reply with a unified diff only.|]
    result <- revising draft (atMost 2) \patch -> do
        verdict <- panel [ ask (model "reviewer-correct") [wf|{guide}…{patch}…|], … ]
        amend (ask (model "author" `servedBy` "deep") [wf|{guide}…{patch}…{verdict}…|])
    caseResult result
      (\patch -> do
          ok <- confirm (person "owner") [wf|…{patch}…{flagSpec}|]
          ifFlag ok (do act (tool "apply") [wf|…{patch}…|]; stop) stop)
      stop |])
```

Four extensions at the use site — `BlockArguments`, `OverloadedStrings`,
`QuasiQuotes`, `TemplateHaskell` — and `DataKinds`, `OverloadedLabels` and
`QualifiedDo` are gone from the authoring module along with the three `do`
qualifiers and the imports that carried them: an authoring module now says
`import Agentic.Notation`, which re-exports the surface, and nothing else.
There is no `@`, no `#`, and no `=:` in the flagship.

Gates, at the ruling: `cabal build all` clean at `-Wall`, tier1 21/21 (both
example entries rebuilt through the notation, printed `Raw` value-equal under
`zeroPos` and whole reply equal), tier0 128/128, and
`agentic-run run harden --scripted` 7/7 questions, exit 0.

**This ruling has in turn been superseded: the splice is gone, and with it the
names. See §2.2-REVISED-2, at the end of this document.**

### 2.3 Sketch C — a Flow-flavoured indexed category

agent-functor's taste, transplanted as far as §1.3 permits (prompts stay data;
only the composition changes). No monad, no lambdas: an indexed category
`Flow s t` composed with `>>>`, names supplied by labels, holes resolved at the
type level because there is no Haskell binder to name.

```haskell
harden :: Flow '[] Done
harden =
       #guide  <-- ask (tool "cat") [wf|Write out the house style guide, at most four short lines.|]
  >>>  #draft  <-- ask (model "author" `servedBy` "deep") [wf|
           Draft a patch satisfying:
           {spec}
           Reply with a unified diff only.|]
  >>>  #result <-- revising #draft #patch (atMost 2)
           ( #verdict <-- panel
               [ ask (model "reviewer-correct") [wf|
                   {guide}
                   Is this patch correct?
                   {patch}
                   {verdictSpec}|]
               , … ]
           )
           ( amend (ask (model "author" `servedBy` "deep") [wf|
               {guide}
               Revise this patch:
               {patch}
               {verdict}
               Reply with the revised diff only.|]) )
  >>>  caseResult #patch
           (      #ok <-- confirm (person "owner") [wf|
                      Apply this patch?
                      {patch}
                      {flagSpec}|]
             >>>  ifFlag #ok
                    (act (tool "apply") [wf|…|] >>> stop)
                    stop )
           stop
```

It is pure, it is inspectable, and `>>>` is associative on the nose. But:

* **the binds are not binds.** `#guide <-- …` extends a type-level scope and
  binds no Haskell variable; `{patch}` resolves through `hole @"patch"`, so a
  reader must reconstruct the scope in their head to know where `patch` came
  from. The .wf reads better than this, which is disqualifying on its own.
* the flagship is three statements and then a `case`; `>>>` buys nothing for a
  three-element chain, and every branch arm becomes a **parenthesised
  argument** rather than a laid-out block, so the tail of the program is a
  nest of parentheses where the .wf has indentation.
* the amend clause reads `{verdict}` for a name introduced by *the review
  clause beside it*, which is the one place a reader most needs a binder.
* it does buy one thing: no `Res`/`Step` machinery (§5.1). That is a cost paid
  once by the implementer, not per program by the author.

The genuinely agent-functor version — `refineWith "review" (brief …) id`, where
the prompt is a function of the incoming artifact — is not on the table at all,
by §1.3.

### 2.4 Judgement

| | A — indexed `W.do` | B2 — TH over the block | C — `Flow` / `>>>` |
|---|---|---|---|
| reads like `harden.wf` | closest: statement per statement, prose prompts, real indentation | identical, minus `#labels` | pipeline, not a block; arms parenthesised |
| binds are real binds | **yes** — Haskell lambdas, Haskell shadowing | yes | **no** |
| purity | total, pure values | pure at runtime, compile-time metaprogram | total, pure values |
| unbound name in a prompt | *Haskell* scope error at the hole, then `LookupC`'s "unbound name" if it is out of the workflow's scope | error inside generated code | `LookupC` type error only |
| scope discipline | Haskell scope **and** `Fresh`/`LookupC` | same, via generated code | `Fresh`/`LookupC` only |
| terminality | `Term` uninhabited; observed error: `Couldn't match type ‘()’ with ‘Term’` | possible, in the splice | possible, in the index |
| implementation risk | medium, and **measured** (§5.1–§5.2): two type-system facts must hold, both verified | high, unbounded | low |
| corpus reachability | verified: 11/11 prompts | verified only in principle | verified in principle |

**Winner: A.** It is the only one of the three in which a bind is a bind, and
it is the closest to the file the owner points at.

*(And then B2, on the owner's ruling — §2.2-REVISED. A stays: it is what B2
compiles to, and the row above that reads "identical, minus `#labels`" is what
shipped.)*

---

## 3. The winner, specified

### 3.1 Modules, and what an author imports

```
Agentic.Builder            (unchanged)
Agentic.Prompt             Words, lit, hole, Says/says      -- re-exports Builder's Piece
Agentic.Prompt.Quote       the [wf|…|] QuasiQuoter          -- Template Haskell
Agentic.Workflow           the surface: labels, handles, questions, blocks, loops, functions
Agentic.Workflow.Do        (>>=), (>>)  for a workflow block
Agentic.Workflow.Revision  (>>=), (>>)  for the two clauses of a bounded revision
Agentic.Workflow.Body      (>>=), (>>)  for a function body
```

An authoring module says exactly:

```haskell
{-# LANGUAGE BlockArguments, DataKinds, OverloadedLabels,
             OverloadedStrings, QualifiedDo, QuasiQuotes #-}

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import qualified Agentic.Workflow.Revision as R   -- only if it revises
import qualified Agentic.Workflow.Body as B       -- only if it defines a function
```

Six extensions, none of them global in effect, and **no `TypeApplications`**.

Three `do`-qualifiers, because the language has three block grammars and each
refuses what its `Raw` cannot express: a workflow block branches and ends in a
terminal; a revision has exactly one review and one amendment; a function body
is a straight line of questions with no branch and no loop (`RawBodyStmt` has
no such constructors, and `B` has no such statements). Making one qualifier
serve all three means generalising `W` over its result family
(`Blk s` / `Body s r`) — mechanical, but unverified, and it would trade three
honest grammars for one that must then police itself.

`Agentic.Prompt.Quote` must be a module of its own: Template Haskell's stage
restriction forbids using a quasiquoter in the module that defines it. This
adds `template-haskell` to the library's `build-depends` and four modules to
`exposed-modules`; the `examples` library gains no new dependency beyond
`agentic`.

### 3.2 The block: an indexed CPS monad over a `Stage`

```haskell
-- Lean's `Pend Γ`, at the type level.
data Stage = Open Scope | Pending Code Scope

type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s)      = Blk s
  Res ('Pending c s) = Arms c s

-- The two arms a pending `case result` still owes. `ns` is existential,
-- exactly as `revisingCaseI` leaves it free.
data Arms (c :: Code) (s :: Scope) where
  Arms :: Text -> Blk ('(ns, c) ': s) -> Blk s -> Arms c s

newtype W (i :: Stage) (j :: Stage) a = W { unW :: (a -> Res j) -> Res i }

data Term                      -- uninhabited: a terminal has no value
absurdTerm :: Term -> a
absurdTerm t = case t of {}

runW :: W ('Open s) j Term -> Blk s
runW (W f) = f absurdTerm
```

`W i j a` is Atkey's indexed CPS: *given what follows, the whole block*. It is
the exact shape of every Builder block combinator, which all take "the rest of
the block" as their last argument — so the desugaring is a re-association and
nothing more.

**Statements.** A statement is either already a block (`act`, `knownHere`, a
terminal) or a `Named` pair awaiting interpretation. One class carries all of
them:

```haskell
class Step st (i :: Stage) (j :: Stage) a | st -> i j a where
  step :: st -> (a -> Res j) -> Res i

instance Step (W i j a) i j a                                            -- act, knownHere, terminals
instance (KnownSymbol n, Fresh n s)                                      -- x <- #x =: <ask>
      => Step (Named n (Ask s)) ('Open s) ('Open ('(n,'CodeText) ': s)) (V n 'CodeText)
instance (KnownSymbol n, Fresh n s, KnownCode c)                         -- x <- #x =: <panel|confirm|call|…>
      => Step (Named n (Rhs s c)) ('Open s) ('Open ('(n,c) ': s)) (V n c)
instance KnownSymbol n                                                   -- #result =: revising …
      => Step (Named n (Loop c s)) ('Open s) ('Pending c s) ()
```

each instance being one line of Builder: `bindI (nameText @n) (one a) rest`,
`bindI (nameText @n) rhs rest`, and `revisingCaseI …` respectively.

```haskell
-- Agentic.Workflow.Do
(>>=) :: forall st i j a k b. (Step st i j a, NoFollow a) => st -> (a -> W j k b) -> W i k b
m >>= f = W (\kk -> step @st @i @j @a m (\a -> unW (f a) kk))

(>>)  :: forall st i j a k b. (Step st i j a, NoFollow a) => st -> W j k b -> W i k b
m >> n = m >>= \_ -> n
```

`return`/`pure`/`fail` are deliberately absent: `QualifiedDo` never needs them
for blocks of this shape (no failable patterns, no trailing `return`), and
their absence is what makes "a block ends in a terminal" checkable.

**Terminality.** `workflow :: W ('Open '[]) ('Open '[]) Term -> Program`. The
last statement of the block is the block's value, so it must produce `Term`,
and only `stop`, `ifFlag`, `caseVerdict` and `caseResult` do. Observed:

```
Bad2.hs:18:3: error: [GHC-83865]
    • Couldn't match type ‘()’ with ‘Term’
      Expected: W (Open '[]) (Open '[]) Term
        Actual: W (Open '[]) (Open '[]) ()
    • In a stmt of a 'do' block:
        act (tool "t") …
```

**Nothing follows a terminal.** `Term` is uninhabited, so `stop; foo` would
silently *drop* `foo` (the continuation is never applied). A closed constraint
family refuses it instead:

```haskell
type family NoFollow a :: Constraint where
  NoFollow Term = TypeError ('Text "nothing follows a terminal: `stop`, `if` and `case` end a block")
  NoFollow a    = ()
```

Observed, at the `stop`:

```
Bad.hs:42:3: error: [GHC-64725]
    • nothing follows a terminal: `stop`, `if` and `case` end a block
```

**`QualifiedDo`, not `RebindableSyntax`.** `RebindableSyntax` rebinds `>>=`,
`>>`, `fail`, `ifThenElse`, `fromInteger`, `fromString` and more for the
*entire module*, so an authoring module could no longer use ordinary `do`,
`if`, or numeric literals for anything else — and `Example.Harden` has
`Data.Text` literals and a `where` clause. `QualifiedDo` is per-block, composes
with ordinary `do` in the same function, and lets **each block grammar have its
own `>>=`** — which §3.6 exploits to give the revision clauses a two-statement
grammar. It has been in GHC since 9.0; this project is on 9.10.3.

### 3.3 Names: labels, handles, and `=:`

```haskell
data Label (n :: Symbol) = Label
instance n ~ n' => IsLabel n (Label n') where fromLabel = Label

data V (n :: Symbol) (c :: Code) = V     -- a live binding: its printed name, its kind

data Named (n :: Symbol) src = Named src
(=:) :: Label n -> src -> Named n src
infix 1 =:
```

`V`'s constructor is **not exported**: a handle can only come from a bind, so
the only names in play are the ones the author introduced. Two mechanisms guard
a name, and they are complementary:

* **Haskell scope.** `guide` is a lambda binder; outside the block, or before
  its bind, it is not in scope and GHC says so at the hole.
* **`LookupC` / `Fresh`.** A handle that *is* in Haskell scope but whose name is
  no longer live — a carrier smuggled out of a revision — fails at
  `KnownVar n s`, i.e. `unbound name; nothing in scope answers to `patch``.
  Shadowing is refused by `Fresh`; observed:

```
Bad.hs:24:3: error: [GHC-64725]
    • this name is already in scope: guide
    • In a stmt of a 'do' block: _b <- #guide =: ask (tool "cat") …
```

**Where each printed name comes from** — this is the whole answer to "how does
`#result =: revising …` bind three names":

| printed field | value in `example-000` | supplied by |
|---|---|---|
| `bind.x` of the loop, and `caseResult.x` | `result` | the label `#result` in `#result =: revising …` — one label, printed twice, because `revisingCaseI` takes it once |
| `revising.subject` | `draft` | the **type-level symbol of the handle** passed to `revising` (`V "draft" c`), via `nameText @subj` — *not* the Haskell variable's name |
| `revising.carrier` | `patch` | the label `#patch` given to `revising`; the same call hands the lambda a `V "patch" c`, so the Haskell binder and the printed string cannot disagree |
| `revising.reviewName` | `verdict` | the label `#verdict` in `#verdict =: panel […]`, inside `R.do` |
| `caseResult.settledName` | `patch` | the label `#patch` given to `caseResult`; the same call hands *its* lambda a fresh `V "patch" c` |

The two `patch`es are two different binders in two different scopes — the
corpus's one use of that freedom — and here they are two different Haskell
lambda binders, in two different Haskell scopes, both spelled `patch`. The
type-level `Fresh` check is against the enclosing scope in each case, exactly
as `revisingCase` already does it.

### 3.4 Questions

```haskell
data PartyK = IsModel | IsTool | IsPerson
data Party (p :: PartyK)

model  :: Text -> Party 'IsModel
tool   :: Text -> Party 'IsTool
person :: Text -> Party 'IsPerson

servedBy :: Party 'IsModel -> Text -> Party 'IsModel   -- only a model is served by a model
drawing  :: Party p -> Integer -> Party p              -- `independent draw n`

ask :: Party p -> Words s -> Ask s                     -- kindless, exactly as RawAsk is kindless
```

`askGuard`'s refusal is unrepresentable rather than checked, as before, but
now by a party index rather than by four differently-named constructors.
Observed:

```
Bad.hs:37:19: error: [GHC-83865]
    • Couldn't match type ‘IsTool’ with ‘IsModel’
      In the first argument of ‘servedBy’, namely ‘tool "cat"’
```

An `Ask s` carries no kind, so it can stand wherever a position imposes one: a
panel member, an `act`, a review, an amendment. Where the *binder* imposes it
(§1.4), the surface says which:

```haskell
confirm  :: Party p -> Words s -> Rhs s 'CodeFlag      -- a yes/no question
panel    :: [Ask s] -> Rhs s 'CodeVerdict              -- `panel, all must approve […]`
answering :: Ask s -> Answer c -> Rhs s c              -- the kind, stated; prints nothing
annotated :: Ask s -> Answer c -> Ann s c              -- the kind, printed: `x : c <- …`

data Answer (c :: Code) where
  Text :: Answer 'CodeText;  Flag    :: Answer 'CodeFlag
  Verdict :: Answer 'CodeVerdict;  Receipt :: Answer 'CodeAck
```

and everything else is the `Step` instance for `Named n (Ask s)`, which reads
a bare question as a **text** question. So:

* `#guide =: ask …` → text, no annotation printed (`ann: null` ✓);
* `#ok =: confirm …` → flag, no annotation printed (`ann: null` ✓);
* `#verdict =: panel […]` → verdict, positionally;
* `#x =: ask … `answering` Verdict` → verdict, still `ann: null`;
* `#x =: ask … `annotated` Verdict` → verdict, and prints `x : verdict <- …`
  (a fourth `Step` instance, `Named n (Ann s c)`, which is `bindAsI` where the
  others are `bindI`; `battery-043` is what needs it).

The `Answer` constructors are capitalised on purpose: `verdict` is a name an
author binds (`#verdict =: …`), and a lower-case singleton would be shadowed by
it and warn under `-Wname-shadowing` — observed in the first prototype run.

`panel` takes a plain list so the literal reads like the `.wf`'s bracket list.
Its emptiness refusal is a runtime `error` on a CAF (so it fires the first time
tier1 or `agentic-run` touches the program, i.e. immediately in CI), because
`NonEmpty` costs `a :| [b, c]` at every panel and the language's own refusal for
an empty panel is tier0's (`vector-004`), not this layer's.

### 3.5 The `[wf|…|]` quoter

**Grammar.** The only metacharacter is `{`.

* `{name}` — where `name` is a Haskell variable identifier
  (`[a-z_][A-Za-z0-9_']*`) — is a hole.
* `{{` is a literal `{`.
* `}` is always literal, and is never doubled — so a prompt full of JSON braces
  needs no escaping on the closing side.
* A `{` that is neither of the above is a **compile error** quoting the
  fragment, rather than silently-literal text: a mistyped hole is the one
  failure mode that changes a prompt without telling you, and prompts are what
  the corpus compares.

That is the whole grammar. Nothing else in the quoted text is interpreted —
no `served by`, no fences, no `ask`. This is `D10`-compliant by construction:
the quoter is ninety-nine lines including its haddock, and knows one
production.

**Layout** (agent-functor's `[__i|…|]` rule, which is the owner's existing
taste, and which happens to reproduce the `.wf` fence exactly):

1. `\r\n` becomes `\n`;
2. leading and trailing whitespace-only lines are dropped;
3. the longest common leading-whitespace prefix of the remaining non-blank
   lines is stripped from every line;
4. the lines are joined with `\n`, with **no trailing newline**;
5. line breaks are otherwise preserved verbatim.

Rule 4 is why `…only.|]` and `…only.\n  |]` produce the same prompt, and it is
the same trailing-newline decision the `.wf` fence makes. A prompt that must
end in a newline is spelled `[wf|…|] <> [lit "\n"]`; the `.wf` cannot write one
either.

**Splicing.** A hole becomes `says x` on the Haskell variable `x`:

```haskell
class Says a (s :: Scope) where says :: a -> Words s

instance (KnownSymbol n, KnownVar n s, Spliceable (LookupC n s), LookupC n s ~ c)
      => Says (V n c) s where says _ = [hole @n]     -- a live binding: one Interp chunk
instance Says Text s        where says t = [lit t]   -- a define: one Lit chunk, never fused
instance s ~ s' => Says [Piece s'] s where says = id -- a fenced define: its own chunks
```

This is what makes `{spec}` and `{patch}` look identical in the source and mean
different things — the type decides, exactly as the `.wf` parser decides by
whether the name is a `define` — and what keeps a define's expansion **its own
chunk** (§1.2). `Spliceable` is Builder's, so a flag hole is still refused;
observed:

```
Bad.hs:50:22: error: [GHC-64725]
    • a flag has no text of its own
    • In the expression: says ok
```

**Staging.** The quoter emits `varE (mkName nm)` — an *unqualified* `mkName`,
which resolves in the ordinary lexical scope at the splice site, including
lambda binders and `where` bindings. That is deliberate: it is what makes a
typo a plain `Variable not in scope: guiide` rather than a type-level puzzle,
and it is what lets `{brief}` in `helloProgram` see a `where`-bound define
(verified: the prototype's `hello` compiles and prints the right chunks).

**Desugaring of one real prompt.** Source:

```haskell
[wf|
    {guide}
    Is this patch correct?
    {patch}
    {verdictSpec}|]
```

After layout: `"{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}"`.
After the hole scan: `["", guide, "\nIs this patch correct?\n", patch, "\n",
verdictSpec, ""]`. After `normalize` (both empty literals dropped, nothing
fused), the emitted expression is

```haskell
concat
  [ says guide
  , [lit (Data.Text.pack "\nIs this patch correct?\n")]
  , says patch
  , [lit (Data.Text.pack "\n")]
  , says verdictSpec
  ]
```

which, with `guide :: V "guide" 'CodeText`, `patch :: V "patch" 'CodeText` and
`verdictSpec :: Text`, is

```haskell
[ hole @"guide", lit "\nIs this patch correct?\n", hole @"patch", lit "\n", lit verdictSpec ]
```

— the current `Example.Harden`'s hand-written list, letter for letter.

### 3.6 Verification against the frozen prompts

The prototype prints the chunks of every prompt it builds. Three of them,
frozen JSON on the left, prototype output on the right:

**`draft`** (`main.bind.rest.bind.src.rhs.r.ask.a.prompt`)

```json
[ {"lit": {"s": "Draft a patch satisfying:\n"}},
  {"lit": {"s": "harden the parser"}},
  {"lit": {"s": "\nReply with a unified diff only."}} ]
```
```
=== "model:author"
   Lit "Draft a patch satisfying:\n"
   Lit "harden the parser"
   Lit "\nReply with a unified diff only."
```

**`reviewer-correct`** (`…revising.review.panel.members[0].prompt`)

```json
[ {"interp": {"name": "guide"}},
  {"lit": {"s": "\nIs this patch correct?\n"}},
  {"interp": {"name": "patch"}},
  {"lit": {"s": "\n"}},
  {"lit": {"s": "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."}} ]
```
```
=== "model:reviewer-correct"
   Interp "guide"
   Lit "\nIs this patch correct?\n"
   Interp "patch"
   Lit "\n"
   Lit "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
```

**the amendment** (`…revising.amend.ask.a.prompt`)

```json
[ {"interp": {"name": "guide"}},
  {"lit": {"s": "\nRevise this patch:\n"}},
  {"interp": {"name": "patch"}},
  {"lit": {"s": "\n"}},
  {"interp": {"name": "verdict"}},
  {"lit": {"s": "\nReply with the revised diff only."}} ]
```
```
=== "model:author"
   Interp "guide"
   Lit "\nRevise this patch:\n"
   Interp "patch"
   Lit "\n"
   Interp "verdict"
   Lit "\nReply with the revised diff only."
```

The remaining eight (`guide`, `reviewer-secure`, `reviewer-simple`, `ok`,
`apply`, and `hello`'s three) match likewise; the full run is reproducible with
`./proto-main` from `PORTING3-proto/`. Note in particular:

* the `"\n"` between `{patch}` and `{verdictSpec}` is its own chunk — it is the
  contiguous literal run between two holes;
* the define's expansion is a separate chunk beside it, unfused;
* the empty literal before `{guide}` and after `{verdictSpec}` are dropped by
  `normalize` and never reach the term;
* `hello`'s `"Name one thing worth greeting.\n"` + `"Reply in one short line."`
  are likewise two adjacent literals.

### 3.7 The bounded revision, and the pending `case`

```haskell
newtype Bound = Bound Integer
atMost :: Integer -> Bound

revising ::
  ( KnownSymbol subj, KnownSymbol carrier, KnownVar subj s
  , c ~ LookupC subj s, KnownCode c, Fresh carrier s ) =>
  V subj c -> Label carrier -> Bound -> (V carrier c -> Clauses carrier c s) -> Loop c s

caseResult ::
  (KnownSymbol sname, Fresh sname s) =>
  Label sname ->
  (V sname c -> W ('Open ('(sname,c) ': s)) j Term) ->   -- settled p { … }
  W ('Open s) j Term ->                                  -- unsettled { … }
  W ('Pending c s) j Term
```

`revising` builds a `Loop c s = Text -> Arms c s -> Blk s` — the loop awaiting
its result name (from the label, via the `Step` instance) and its two arms
(from the continuation, whose `Res` at a `Pending` stage *is* `Arms c s`). So
the whole `revisingCaseI` call is assembled by the `>>=` that joins the two
statements, and neither statement can stand without the other:

* a block still `Pending` cannot end — `workflow` wants `Open '[]`;
* no statement but `caseResult` has a `Step`/`W` at a `Pending` input stage;
* `caseResult` alone is ill-typed, since nothing produces its `Pending` input.

That is Lean's `Pend Γ` discipline, as types.

**The clauses are their own grammar.** A revision has exactly one review and
exactly one amendment — `SrcRevising` has no other shape — so
`Agentic.Workflow.Revision` gives them a bespoke `>>=` and *no* `>>`:

```haskell
-- Agentic.Workflow.Revision
(>>=) :: (KnownSymbol nr, Fresh nr ('(nc,c) ': s), ReviewSrc src ('(nc,c) ': s)) =>
         Named nr src -> (V nr 'CodeVerdict -> Amendment nc nr c s) -> Clauses nc c s

class ARevisionReviewsThenAmends a          -- no honest instance
instance TypeError ('Text "a bounded revision reviews first — `verdict <- #verdict =: …` — \
                          \and then amends, and has no other statement")
      => ARevisionReviewsThenAmends a
(>>) :: ARevisionReviewsThenAmends a => a -> b -> c
```

`R.do` therefore accepts exactly `verdict <- #verdict =: <review>` followed by
`amend <ask>`, and nothing else — a second bind, a missing review, or a
statement between them is a type error naming the rule. `ReviewSrc` accepts a
bare `Ask` (elaborated at `verdict` by position, as `checkMembers` does), a
`Rhs s 'CodeVerdict` (a panel or a call), and an `Ann s 'CodeVerdict` (which
sets `reviewAnn = Just verdict`).

The `Clauses` GADT hides the review binding's symbol existentially, which is
precisely the freedom `revisingCaseI` already leaves in its `nr` parameter, so
the surface hands it straight through.

### 3.8 The rest of the block

| surface | Builder | note |
|---|---|---|
| `stop` | `stop` | terminal |
| `act party words` | `act` | statement; scope unchanged, plan weakened |
| `knownHere` | `knownHere` | statement; **no node**; names computed from `KnownScope s` |
| `ifFlag h yes no` | `ifFlag` | terminal; `h :: V n 'CodeFlag`, so the flag's kind comes from the handle and `LookupC n s ~ 'CodeFlag` is checked |
| `caseVerdict h approved objected noAnswer` | `caseVerdict` | terminal; arms positional, in Lean's order |
| `caseResult #p settled unsettled` | (half of) `revisingCase` | terminal, only at a `Pending` stage |
| `#x =: …` | `bindI` | §3.3 |
| `#result =: revising …` | (half of) `revisingCase` | §3.7 |

### 3.9 Functions, and calling one

A function body is the third grammar: `RawBodyStmt` has binds, acts and
statement-calls and **no branching**, so `Agentic.Workflow.Body` gives it its
own `>>=` — the same CPS shape as `W`'s, over `Body s r` instead of `Blk s`
and indexed by a bare `Scope` rather than by a `Stage`, since a body can be
neither pending nor branching:

```haskell
newtype B (r :: Code) (s :: Scope) (t :: Scope) a = B { unB :: (a -> Body t r) -> Body s r }
```

Parameters are introduced in HOAS, so a parameter is a handle exactly like a
bind is, and no arity or order can disagree between the printed parameter list
and the body's names:

```haskell
critique :: Fn '[ 'CodeText ] 'CodeText
critique =
  function "critique" $
    arg #goal Text \goal ->
      body B.do
        notes <- #notes =: ask (model "critic") [wf|
            Critique this goal in three lines, worst problem first:
            {goal}|]
        answer notes
```

* `arg :: (KnownSymbol n, KnownCode c, Fresh n acc) => Label n -> Answer c -> (V n c -> Params cs ('(n,c) ': acc) r) -> Params (c ': cs) acc r`
* `body :: B r acc t Term -> Params '[] acc r`
* `answer :: (KnownSymbol n, KnownVar n s, c ~ LookupC n s) => V n c -> B c s t Term`
  — terminal; the declared result *is* the answered name's kind, which is
  `checkFn`'s `b.at? f.result` made structural. `done :: B 'CodeAck s t Term`
  ends a `-> receipt` body.
* `function :: KnownCode r => Text -> Params ps '[] r -> Fn ps r` walks the
  HOAS chain once, building Builder's `Params ps '[] s` and its `Body s r`
  together and handing both to `Builder.function`.

Calling it, at a value position and at a statement position:

```haskell
  notes <- #notes =: call critique (draft :> nil)
  callStmt announce (notes :> [wf|to the team|] :> nil)
```

`(:>)`/`nil` are Builder's `Args`, with a `ToArg` class so an argument is
either a handle (passed at *its* kind, no silent rendering) or `[wf|…|]` words
(a `text` parameter, elaborated in the caller's bindings). The stratified table
— no recursion, a call names only an earlier function — remains Haskell's
`let`: a `Fn` value must exist before it can be applied.

`program [SomeFn critique] W.do …` builds a `Program` with a function table;
`workflow = program []`.

### 3.10 What a `define` becomes

A Haskell binding, and nothing else — a `define` is not a binding, reaches no
scope, and is expanded by the import walk:

```haskell
spec :: Text
spec = "harden the parser"
```

`{spec}` in a prompt is `says spec = [lit spec]`: one literal chunk, in the
place the `.wf` puts it, unfused with its neighbours (§1.2). A `define` written
as a fence, or one that holes an earlier define (`battery-027`, `battery-028`),
is a `Words s` value — `[wf|…|]` at a type annotation — and splices its chunks
through the third `Says` instance. `define` is Haskell's `let`, as promised:
top-level, or in the `where` of the program that uses it (`hello` does the
latter, and the quoter finds it).

---

## 4. The target text: `example/Example/Harden.hs`

This *was* the deliverable, and it compiles unchanged with tier1 at 21/21. It is
now the **compilation target**: since §2.2-REVISED the module a human reads has
bare binds and no labels, and this text is what `$(workflow [| … |])` emits. Its
prompts are still the byte-accurate reference — the chunk-for-chunk agreement
with `example-000` and `example-001` is pinned here.

```haskell
-- |
-- Module      : Example.Harden
-- Description : The walked examples, written in the monadic surface.
--
-- @agent-cat@ ships two programs under @example\/@ that are not corpus
-- fixtures but /prose/: the flagship @harden.wf@, which the language guide
-- walks line by line, and @hello.wf@, the smallest thing that is still a
-- workflow. Both are frozen in the corpus (@example-000@ and @example-001@),
-- and both are written here in "Agentic.Workflow" — the sugar layer over
-- "Agentic.Builder", whose combinators these statements are.
--
-- Two callers share these programs:
--
--   * @tier1@ pins them against the frozen entries — printed 'Raw' and whole
--     reply, positions zeroed on both sides;
--   * @agentic-run@ plans, prices and /runs/ them.
--
-- The first caller is what makes the second trustworthy: the program the CLI
-- executes is the same value the conformance runner has already held against
-- the oracle.
--
-- == How to read this against @harden.wf@
--
-- Statement for statement. @x <- ask …@ is @guide <- #guide =: ask …@: the
-- label is the name the /program/ prints, the Haskell binder is the name /this
-- module/ reads, and they are written the same on purpose. A @```fence```@ is
-- a @[wf|…|]@, with the same @{name}@ holes and the same layout rule —
-- surrounding blank lines dropped, common indentation stripped, line breaks
-- kept, no trailing newline. A @define@ is a Haskell binding.
--
-- == What the transcription still pins
--
--   * __A @define@ contributes its own chunk.__ @{spec}@ splices @spec@'s one
--     literal beside the surrounding text without fusing with it, so the
--     drafting prompt is three chunks and not one. Writing the prompt as a
--     single string would render the same text and print a different program.
--
--   * __The carrier and the settled binder share the name @patch@.__ They are
--     different binders in different scopes — here, two different lambda
--     binders — and both are fresh against @[draft, guide]@. It is the one
--     place in the whole corpus that leans on that.
--
--   * __The review is a panel__, which no other rebuilt case does, and its
--     three members fold right in the noncommutative verdict monoid.
--
--   * __@guide@ is read from inside the loop.__ Every round of the unroll
--     re-reads it through the accumulated substitutions and never re-asks
--     @cat@: 19 ask nodes, one @cat@ question.
--
--   * __@served by \"deep\"@ appears twice__, on the draft and on the
--     amendment.
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}

module Example.Harden
  ( -- * The programs
    hardenProgram,
    helloProgram,

    -- * The registry
    examples,
    lookupExample,
    exampleNames,
  )
where

import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import qualified Agentic.Workflow.Revision as R
import Data.Text (Text)

-- ---------------------------------------------------------------------------
-- The defines, once
-- ---------------------------------------------------------------------------

-- | @define spec = "harden the parser"@.
spec :: Text
spec = "harden the parser"

-- | @define verdictSpec = …@ — the format line every reviewer's prompt ends
-- with.
verdictSpec :: Text
verdictSpec =
  "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."

-- | @define flagSpec = "Reply with exactly yes or no."@ — the owner's.
flagSpec :: Text
flagSpec = "Reply with exactly yes or no."

-- ---------------------------------------------------------------------------
-- The flagship
-- ---------------------------------------------------------------------------

-- | @example\/harden.wf@: read the house style, draft a patch, review it by a
-- three-model panel under a bounded revision, and — if the owner says so —
-- apply it.
--
-- Level @branch@, size 36, 19 ask nodes, 9 paths folding between 5 and 15.
-- @codes@ is @null@: a program that branches has no single sequence of answer
-- kinds, which is exactly what separates the flagship from 'helloProgram'.
hardenProgram :: Program
hardenProgram = workflow W.do
  guide <- #guide =: ask (tool "cat")
    [wf|Write out the house style guide, at most four short lines.|]

  draft <- #draft =: ask (model "author" `servedBy` "deep") [wf|
      Draft a patch satisfying:
      {spec}
      Reply with a unified diff only.|]

  #result =: revising draft #patch (atMost 2) \patch -> R.do
    verdict <- #verdict =: panel
      [ ask (model "reviewer-correct") [wf|
          {guide}
          Is this patch correct?
          {patch}
          {verdictSpec}|],
        ask (model "reviewer-secure") [wf|
          {guide}
          Is this patch secure?
          {patch}
          {verdictSpec}|],
        ask (model "reviewer-simple") [wf|
          Could this patch be simpler?
          {patch}
          {verdictSpec}|]
      ]
    amend (ask (model "author" `servedBy` "deep") [wf|
        {guide}
        Revise this patch:
        {patch}
        {verdict}
        Reply with the revised diff only.|])

  caseResult #patch
    -- settled patch { … }
    ( \patch -> W.do
        ok <- #ok =: confirm (person "owner") [wf|
            Apply this patch?
            {patch}
            {flagSpec}|]

        ifFlag ok
          ( W.do
              act (tool "apply") [wf|
                  Apply:
                  {patch}
                  Write the patched file here, then reply DONE.|]
              stop )
          stop )
    -- unsettled { stop }
    stop

-- ---------------------------------------------------------------------------
-- The small one
-- ---------------------------------------------------------------------------

-- | @example\/hello.wf@: two questions and an act.
--
-- Level @pipeline@, size 4, one path, @codes [text, text, receipt]@ and both
-- bills 3. It exists so that the CLI has a subject that is not the flagship:
-- no branch, no loop, and a bill the analysis knows exactly rather than
-- bounds.
--
-- @brief@ is a @define@ — here a @where@ binding, which the @[wf|…|]@ holes
-- find in the ordinary lexical scope — so it contributes a chunk of its own to
-- each of the first two prompts, unfused with the literal beside it.
helloProgram :: Program
helloProgram = workflow W.do
  subject <- #subject =: ask (tool "cat") [wf|
      Name one thing worth greeting.
      {brief}|]

  greeting <- #greeting =: ask (model "greeter") [wf|
      Write a greeting for this, and nothing else:
      {subject}
      {brief}|]

  act (tool "say") [wf|
      Say it:
      {greeting}|]
  stop
  where
    -- @define brief = "Reply in one short line."@
    brief :: Text
    brief = "Reply in one short line."

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The named programs, in the order the CLI lists them.
examples :: [(Text, Program)]
examples =
  [ ("harden", hardenProgram),
    ("hello", helloProgram)
  ]

-- | The keys of 'examples', for a usage message or an error.
exampleNames :: [Text]
exampleNames = map fst examples

-- | 'examples' as a lookup.
lookupExample :: Text -> Maybe Program
lookupExample n = lookup n examples
```

Against the current module: the two programs go from 119 non-blank lines of
combinator application to 63, every prompt is prose instead of a chunk list,
and every type application (`@"guide" @'CodeText`,
`@"draft" @"patch" @"verdict" @"patch"`) is gone — the flagship contains no
`@` at all.

---

## 5. Hazards, reality-checked

### 5.1 `Res` must be an injective type family — first thing that bites

`W`'s field is `(a -> Res j) -> Res i`. With `Res` an ordinary (non-injective)
family, unwrapping a `W` cannot recover `i` and `j`, and `>>=` does not
typecheck at all:

```
Surface.hs:297:23: error: [GHC-05617]
    • Could not deduce ‘Res i0 ~ Res i’
      NB: ‘Res’ is a non-injective type family
      The type variable ‘i0’ is ambiguous
```

The fix is one annotation, and it is legitimate — `Blk s` and `Arms c s` are
distinct type constructors, so the family really is injective:

```haskell
type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s)      = Blk s
  Res ('Pending c s) = Arms c s
```

(`TypeFamilyDependencies`.)

### 5.2 `Step` must carry the fundep `st -> i j a` — second thing that bites

Without it, the flagship fails inside the settled arm with two ambiguity errors
that name nothing useful:

```
Harden.hs:66:9: • Couldn't match type ‘LookupC n0 s8’ with ‘CodeFlag’
                  The type variables ‘n0’, ‘s8’ are ambiguous
Harden.hs:68:38: • Couldn't match type: LookupC "patch" s11 with: LookupC "patch" s10
                   NB: ‘LookupC’ is a non-injective type family
```

The cause is ordering: `caseResult`'s `c` and `s` are only determined once the
*previous* statement's `Step` instance is solved, so inside its lambda the
scope is still a metavariable and the constraints from `says patch` float
apart. The functional dependency makes the improvement eager — as soon as the
statement's type is known, its two stages and its bound value are known — and
the whole module then compiles clean. All four instance heads satisfy the
coverage condition (everything on the right of the arrow appears in `st`).

**These two are the riskiest details in the whole design**, in the sense that
an implementer who omits either will conclude the surface does not work. Both
are settled: `PORTING3-proto/Surface.hs` has them, and the flagship compiles.

### 5.3 Template Haskell staging and `mkName`

* The quoter cannot live in the module that uses it → `Agentic.Prompt.Quote`
  is its own module, and `Agentic.Workflow` re-exports `wf`.
* It emits `varE (mkName nm)`: *dynamically* scoped, so it captures the
  author's lambda, `where` and top-level bindings at the splice site, which is
  what makes `{patch}` mean the carrier inside the loop and the settled binder
  inside the arm — two different `V`s, same spelling, correct in both places.
  A missing name is `Variable not in scope: patch`.
* It emits `lit` and `says` as *statically* resolved names (through
  `TemplateHaskellQuotes` brackets), so an author who shadows `lit` locally
  cannot break a prompt.
* Only `QuasiQuotes` is needed at the use site; `template-haskell` is a library
  dependency, and there is no cross-stage or cross-compilation concern in this
  build.

### 5.4 `OverloadedLabels` at kind `Symbol`

`data Label (n :: Symbol) = Label` with
`instance n ~ n' => IsLabel n (Label n')` — the equality-in-the-context form,
so that `#guide` unifies with an expected `Label n` rather than requiring one.
GHC ≥ 9.6 accepts the full identifier syntax used here. The phantom is the
whole value: `#guide` carries no runtime content, and `nameText @n` at the
`Step` instance is the only place it becomes a `Text`.

### 5.5 The two names, and the convention

The printed name comes from the label; the reference comes from Haskell scope.
`g <- #guide =: ask …` would print `guide` and be read as `g`. The convention
is that they are spelled the same, and it is not enforced — enforcing it needs
§2.2's rejected metaprogram. This is worth one line in the module header
(there is one, above) and nothing more: the failure mode is a program that
prints a name the Haskell reader did not expect, not a program that means
something else.

### 5.6 Small ones

* `-Wname-shadowing` fires if the kind singletons are lower-case (`verdict` is
  a name authors bind) → the `Answer` constructors are `Text`/`Flag`/
  `Verdict`/`Receipt`. `Text` as a *data* constructor does not clash with
  `Data.Text.Text`, a *type*.
* `R.>>`'s `TypeError` must live in an instance context, not in the signature:
  in the signature GHC reports it at the *definition*. The
  `ARevisionReviewsThenAmends` class also needs
  `-Wno-simplifiable-class-constraints` in that module — an accepted, local
  cost for a good message.
* `AllowAmbiguousTypes` is needed in the two `do`-modules (the `a` of `>>` is
  determined only by the `Step` fundep at the use site); `bindW`/`thenW` are
  applied with explicit type applications inside those modules.
* `GADTs` implies `MonoLocalBinds`, which is what keeps the block's local
  inference stable; do not turn it off.
* `panel`'s emptiness is a CAF-time `error` (§3.4).

### 5.7 What does *not* change

`Agentic.Builder`, `Agentic.Plan`, `Agentic.Raw`, `Agentic.World`,
`Agentic.Exec`, `Agentic.Gen`, `tier0`, `bisim`, and `tier1/Cases.hs` — the 19
rebuilt battery cases stay in the Builder's index-level spelling, which is
where they belong: they are conformance fixtures, not prose. The surface is
additive, and if it were deleted the port would still pass everything except
the two example entries.

---

## 6. Acceptance

1. `nix develop -c cabal build` clean at `-Wall`.
2. `ci/tier1.sh` → 21/21, with `example-000` and `example-001` rebuilt through
   the new surface: printed `Raw` value-equal under `zeroPos`, and whole reply
   equal.
3. A unit test that is cheaper than tier1 and fails earlier: assert the eleven
   prompts of `hardenProgram` and `helloProgram` chunk-for-chunk against the
   frozen entries (this is what `PORTING3-proto/Main.hs` does by hand, and it
   is the test that catches a quoter-layout regression at the point of the
   change rather than three modules later).
4. The refusal cases of `PORTING3-proto/{Bad,Bad2}.hs` promoted to a
   `should-not-compile` note in the surface module's haddock — GHC has no
   negative-test harness here, and the messages are the design.

---

## 2.2-REVISED-2 — the second ruling: no Template Haskell, and no names

*(Appended after the landing of §2.2-REVISED. It supersedes §2.2-REVISED,
§3.3, §5.2, §5.4 and §5.5, and the module list of §3.1; everything else in this
document stands.)*

### The ruling

The owner, on the landed notation:

> I do NOT like using `$(workflow [| do`. This should not rely on Template
> Haskell in this way, but just be regular Haskell.

So `Agentic.Notation` is **deleted** — module, cabal entry, README mentions —
and with it the last program-level splice. What survives from the two earlier
landings is exactly what the owner has praised or accepted: bare binds
(§2.2-REVISED), `QualifiedDo`'s `W.do`, which is a plain extension, and the
`[wf|…|]` quoter, whose interpolation is the part of agent-functor the owner
asked for. **The objection is to program-level Template Haskell, not to
quasiquotation**: a prompt is data, and a quoter that produces data is not a
second surface language.

### The forced trade

A Haskell binder's spelling is not readable by a library. Only Template
Haskell can read it. So dropping the splice drops the names, and the surface
has to be honest about which of the three it gives up:

| | keeps binder names | no second spelling | no Template Haskell |
|---|---|---|---|
| §2.1 Sketch A — `#guide =: …` | ✓ | ✗ | ✓ |
| §2.2-REVISED — `$(workflow [| … |])` | ✓ | ✓ | ✗ |
| **this landing** | **✗** | ✓ | ✓ |

The third column is the ruling and the second is the previous ruling, so the
first is what goes.

### What went

`Agentic.Workflow` no longer carries names at the type level **at all**. The
`Symbol`-keyed `Scope`, `SymEq`, `LookupC`, `Fresh`, `KnownVar`,
`KnownScope`, `OverloadedLabels`, `Label`, `Named` and `(=:)` are gone from
this layer; so are `Agentic.Notation` and `Agentic.Workflow.Revision` (see
"two adjustments" below). `Agentic.Builder` keeps every one of them, untouched:
the nineteen Builder-written tier1 cases, `Agentic.Gen` and the corpus pins all
depend on the named API, and this landing does not touch a line of it.

The block's index is the list of live **codes** and nothing else. It is still
spelled as the Builder's `Scope`, with every entry carrying the empty symbol
(`type An c = '("", c)`), because `Codes` is not injective and it is the
Builder's types — `Blk s`, `Rhs s c`, `Words s` — that have to line up. That is
a spelling, not a second meaning: nothing in this layer ever reads the symbol.

### What replaced it

**A handle is a position, not a name.** `V h c` records the scope it was bound
into, itself at index 0; a use at scope `s` walks `h` down to `s`, one `VThere`
per binding made since, dispatched on `ScopeEq` exactly as the Builder's
`KnownVar` dispatches on `SymEq`. A scope grows by one entry per binding, so
two live bindings never share a scope and scope equality *is* identity of
bindings. Reading a handle whose binding is no longer live is the same refusal
it always was, and still a type error:
`this binding is not live here; nothing in scope answers to it`.

**The printed name is generated from the depth.** A binding made with `d`
bindings live prints `b<d>`; so does a revision's carrier (bound at the
enclosing depth) and the settled binder of its `case` (same depth, disjoint
scope); the review binding is one deeper; and the revision's *result* — printed
twice, never in scope — prints `r<d>`, which no binding can collide with. Every
name is therefore a function of the program's shape alone, reproducible across
machines and builds, and fresh by construction: at depth `d` the live names are
exactly `b0 … b(d-1)`.

**A block carries its live names.** The scope index says how many bindings are
live and at which kinds; it cannot say what they are *called*, and one
construct needs to know — `known here`, which prints them. So `W` is
`Live -> (a -> Res j) -> Res i`: each binding conses the name it printed onto
the list and `knownHere` prints the list, rather than recomputing names from
the depth, which would print `b0` for a binding the author named `guide`. That
was a real bug in the first cut of this landing, caught by exercising the
surface the two examples do not reach (`knownHere`, `named`, `annotated`,
`drawing`, a single-question review, `caseVerdict`).

**`named` overrides one**, for an author who wants a printed program that reads
well:

```haskell
guide <- named "guide" (ask (tool "cat") [wf|…|])
```

It is never required and the flagship does not use it.

**A hole prints the handle's name.** `{guide}` resolves to the Haskell *value*
`guide` — `mkName`, in the ordinary lexical scope at the splice, as before —
and the chunk it writes carries `vName` of that value, which is the very `Text`
its binder printed. Binder and hole agree **by construction**; the labelled
surface could only ask for it by convention. Two consequences worth naming:
the class of bug §2.2's table worried about (`#drafted` beside a binder called
`draft`) has no spelling at all, and `-Wno-unused-matches` is gone from
`Example.Harden` — a binding read only by a hole is now genuinely read, because
there is no bracket for the renamer to lose it in.

### Two adjustments the target text needed

The flagship was specified verbatim and compiles as specified but for these,
each recorded here because each is a design consequence and not a typo:

1. **`ok <- confirm (person "owner") …`, not `ok <- ask …`.** A bare `ask` in
   binding position is a *text* question — Lean's "a name whose only use is
   being spliced is a text question" (`Check.lean:207`) made structural. Making
   it kind-polymorphic instead would leave `guide`'s and `draft`'s kind
   determined by nothing at all (a hole constrains `Spliceable`, which both
   `text` and `verdict` satisfy), so every prompt-only binding in the language
   becomes an ambiguous type. `confirm` is the surface's existing way to say
   "a yes/no question", and `ifFlag` accepts nothing else.

2. **The revision's clauses are written in `W.do`, not `R.do`.** The target
   text asked for `W.do`, and it works, because the *stage* index already tells
   the two grammars apart: at `Review c s` only a review may stand, and after
   it only `amend` — a second statement there is the same refusal as before,
   `a bounded revision reviews first … and then amends, and has no other
   statement`, now an instance of `Step` rather than of a second `>>`. So
   `Agentic.Workflow.Revision` has nothing left to do and is deleted. One `do`
   qualifier, one grammar to explain.

### The alpha pin, and its exact scope

Generated names are not the frozen corpus's names, so **two** of tier1's
twenty-one cases — `example-000` and `example-001`, listed in
`Cases.alphaNamed` — compare **one field**, `request.program`, up to alpha.
Nothing else moves anywhere:

* the other nineteen cases keep their exact, name-for-name program comparison;
* every non-program comparand stays exact for all twenty-one — `level`, `size`,
  `askNodes`, `codes`, `costSummary`, `blockAsks`, `fnAsks`, and per world the
  world's re-serialization, its trace event by event and both bills. A trace
  never carries a binder's name;
* the printed program's round-trip through the codec stays exact, because it
  compares the print with itself.

`canonProgram` (`tier1/Main.hs`) is a total structural rename over
`RawProgram`, applied to **both** sides, scope-aware rather than a flat
substitution: a canonical name is the *level* of the binder that introduced it,
so binders in disjoint scopes may share one (the flagship's carrier and settled
binder do, on both sides) and a free name is left exactly as written. The
traversal order, which is the order levels are handed out and therefore the
whole definition:

1. the function table, each function alone: parameters take levels `0…n-1` in
   declaration order, then body statements in order — a `bind` takes the next
   level, its right-hand side read *before* that name is live — then `answer`;
2. the main block from level 0, down the `rest` spine: a `bind` takes the
   current level, its source is read in the scope before it, the rest continues
   one level deeper;
3. inside a `revising`: the subject is read in the enclosing scope, the carrier
   takes the level after the result's, the review binding the one after that,
   and the review and amendment are read in those scopes;
4. a `caseResult`'s settled binder takes the current level and is live in the
   settled arm only; the arms of an `if` and of a `case` are read in the same
   scope, in constructor order;
5. within a question, its prompt left to right, an `interp` chunk being a read
   like any other.

What survives the weakening is everything a name is not — including **which
binding every hole, scrutinee and subject reads**. That is not a claim on
paper: swapping `{guide}` for `{draft}` in the flagship's first review, a
program that still compiles and still holes a live text binding, fails tier1 at
`$.main.bind.rest.bind.rest.bind.src.revising.review.panel.members[0].prompt[0].interp.name:
expected "c0", actual "c1"` (and, separately, in the trace).

### Gates, at this landing

`cabal build all` from a clean build directory, every target, zero warnings at
`-Wall`; tier0 128/128; tier1 21/21 (nineteen exact, two alpha);
`agentic-run plan harden` → `branch`, size 36, 19 ask nodes, 9 paths folding
between 5 and 15 — the folds are name-independent and did not move;
`agentic-run run harden --scripted` → 7 events, `billFresh 7`, `billMemo 7`,
exit 0.
