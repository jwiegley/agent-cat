# haskell/ — the Haskell implementation

The Haskell implementation of agent-cat's operational terms, living beside
the Lean formalization it implements (the repository root) — the raw syntax
of the agentic language, its JSON codec, the term-level guards, the ask counts
and the string layer, and above them the typed `Plan`, its meaning in a world
and the production surface that builds one, and above *that* the authoring
surface a human actually writes — kept honest by replaying a frozen corpus
produced by the Lean formalization.

Lean is normative. This directory does not ask to be believed on its own
authority: every claim it makes about the language is checked against 193
request/reply pairs the Lean oracle emitted (`../test/corpus`), and the check
is two programs you can run in one command each. That corpus is the frozen
conformance record: each request carries either a `RawProgram` — the same raw
term this library encodes and decodes — or a string operation, and each reply
is what the Lean oracle answered for it. (The request terms were emitted from
`.wf` sources back when the repository had a concrete syntax and a parser;
they are terms now, and they have not moved.) All commands below run from
`haskell/`.

```
nix develop -c cabal run tier0
nix develop -c cabal run tier1
```

```
tier0: kinds: 44 string, 9 guard, 45 other, 95 checked, 0 ping, 0 unclassified
tier0: 193 passed, 0 failed, 45 other-refusals (codec-only), of 193 files
tier1: 30 passed, 0 failed, of 30 cases
```

`tier0` replays every entry through the codec, the guards and the string layer.
`tier1` **rebuilds** twenty-seven of the checked entries, in thirty cases
— twenty-four in the production surface, three in the authoring surface above
it (the two walked examples and the yield vector), and three of the twenty-four
a second time in that authoring surface — and holds each rebuilt program against
the frozen one on both fronts: the program it prints, and the whole reply —
folds, counts, and one trace and two bills per world.

## Intent in the executable Plan representation

The Haskell mirror carries the same typed Plan annotation as Lean:

```haskell
data Request c = Request (Q c) (Intent c)
data Intent c where
  Consult :: Intent c
  Observe :: Intent c
  Effect  :: Intent CodeAck
```

Bare `Q` is semantic answer identity. `Request = Q × Intent` annotates one Plan
occurrence: ordinary value asks consult, value `running` observes, and statement
`act` effects. Denotation forgets annotation. Runtime interprets it: consult and
observe memoize by bare Q; effects neither read nor populate memo, reserve the
ordered lane, execute and bill per occurrence; ACP grants only `Effect`. Failover
preserves the authored
request and records its dispatched target separately. Tags state execution policy,
not physical success; `Observe` cannot prove an argv read-only.

The frozen legacy corpus remains version 2 bare-question semantics. Live `bisim`
uses version 3 for generated programs, comparing annotated events and
`semanticTrace`, and adds one version-4 result program whose typed value is
compared end to end. Passing these boundaries proves representation parity, not
intent as meaning.

And the library **runs**: `agentic-run` plans, prices and executes the walked
examples, against a table of canned replies, against a live `agent-deck`
session, or against an ACP adapter it starts and speaks the protocol to. See
[Running a workflow](#running-a-workflow).

## Running it

The flake devShell is the only environment; nothing is installed globally.

```sh
nix develop -c cabal build all      # build the library, the examples and all four runners
nix develop -c cabal run tier0      # replay the frozen corpus
nix develop -c cabal run tier1      # rebuild the curated cases and compare
nix develop -c cabal run bisim      # draw programs and worlds against the live Lean oracle
nix develop -c cabal run agentic-run -- plan harden   # and see Running a workflow
```

(A flake in a git working tree is read *through git*, so `flake.nix` and
`flake.lock` are tracked; if you ever see `Path 'flake.nix' … is not tracked
by Git` after adding files, either track them or route around git with
`nix develop path:. -c …`.)

Both runners take an optional corpus directory and otherwise read
`../test/corpus` (the frozen corpus at the repository root):

```sh
nix develop -c cabal run tier0 -- /path/to/some/other/corpus
```

Each prints one line per failure — naming the file, what was compared, the
expected value and the actual one — then its summary line. Each exits `0` if
and only if nothing failed, so both are usable directly as CI gates.

## What is covered

| module | what it is |
| --- | --- |
| `Agentic.Raw` | the `Raw` AST and a codec byte-compatible with Lean's derived `ToJson`/`FromJson` |
| `Agentic.Guards` | the six term-level guards, in firing order, and the two ask counts |
| `Agentic.Text` | the string layer — `norm`, `words`, `decodeVerdict`, `decodeFlag`, `say`, and since wave three the four **deciders** (`lastNonEmptyLineIs`, `containsLine`, `anyLineStartsWith`, `anyPathMatches`) with the primitives they are composed from (`bare`, `fields`, `headerPaths`, `matchGlob`) and the **fence** a text panel folds into (`block`, `escapeClose`, `validLabel`) — ASCII-only throughout, as Lean core is |
| `Agentic.Plan` | `Q`, indexed `Intent`, `Request`, and the typed five-form `Plan`; de Bruijn expressions and static folds |
| `Agentic.World` | bare-question `WorldSpec` semantics and trace; annotated execution traces, operational memo bills, and v2/v3 JSON projections |
| `Agentic.Builder` | the production surface: typed combinators that both print a `RawProgram` and elaborate to the `Plan` the Lean checker elaborates the same construct to |
| `Agentic.Schema` (+ `.Json`, `.TH`) | format-independent `SchemaEl`, `HasSchema` conversion, strict JSON representation, and `deriveSchema`, which derives a record's schema, witness, and total nested-product conversion |
| `Agentic.WF` | the `[wf\|…\|]` prompt quoter — prose with `{name}` holes, laid out by the fence rule the frozen prompts were written under (blank edge lines dropped, common indentation stripped, no trailing newline) and chunked as the elaborator's left-associated `Prompt.expr` requires — adjacent literals never fused, empty literals dropped — and `Says`, which decides whether a hole is a binding or a `define`; and `[wft\|…\|]`, the same fence yielding a define's `Text` rather than a prompt's chunks, so that a define need not be written as a prompt and converted. One `parseFence` under both, so the two spellings of a block cannot differ by a byte |
| `Agentic.Workflow` (+ `.Do`) | the **authoring** surface: an indexed block, written in ordinary Haskell under `W.do`, in which a bind is a Haskell bind, a branch on a revision's result is a Haskell `case` and a branch on a flag is a Haskell `if` — `guide <- ask (tool "cat") [wf\|…\|]`, then `case result of Settled patch -> W.do …; Unsettled patch -> stop`, then `when ok $ W.do …`. The `case` is real pattern matching on the exported data type `Outcome`, which the revision's bind forks into; the `if` is Haskell's, reaching the exported `ifThenElse` because the **authoring module** enables `RebindableSyntax` — which costs that module its implicit `Prelude` (import it, and `Data.String (fromString)` beside it under `OverloadedStrings`) and costs a `W.do` block nothing, `QualifiedDo` and `RebindableSyntax` rebinding disjoint syntax. The library itself enables neither. There is no `#label`, no `=:` and no splice anywhere in the surface: `ifFlag` stays exported as the combinator the `if` compiles *to* — machinery, and a name in the printed `Raw`, not a statement anyone writes — and `when`/`unless` are that same `if` with only one arm to say — terminal, sealing the body with the implicit `stop` an arm block's end is, and printing the identical `ifFlag` node with an empty other arm; the `case` compiles to `Agentic.Builder`'s `revisingCase`, which `revising` applies; `caseVerdict` stays a combinator here, a verdict being a value that may be acted past. It carries no names at the type level — a library cannot read a Haskell binder — so it generates the name each binding prints from that binding's depth, `named` overrides one, and a `{hole}` prints the name its handle carries |
| `Agentic.Gen`, `Agentic.Observe`, `Agentic.Oracle` | the bisimulation surface: generators, the reply assembly both runners share, and the line-delimited JSON client for the Lean oracle subprocess |
| `Agentic.Exec` | IO realization of annotated Plan: bare-Q memo answers, per-node authored events, dispatched-source attribution, effect lanes, decode/re-ask and fail-over |
| `Agentic.Chains` | one traversal of a printed program into the chain table the runner walks — `primary -> alternates`, ill-definedness refused before the run starts |
| `Agentic.Shell` | executes a `toolExec` observation/effect argv without a shell; prompt on stdin, timeout and typed exit-status answer |
| `Agentic.AgentDeck` | one live `agent-deck` session as an answering service: the three CLI commands, poll loop, staleness guard, five named failures, and one plan-ordered turn lane |
| `Agentic.Acp` | an ACP adapter this process starts, as an answering service: handshake, session per question, permission policy, stop reason, six named failures, and one plan-ordered lane for its JSON-RPC pipe and request context |
| `Example.Harden` | the walked examples (`harden`, `hello`), written in `Agentic.Workflow` and shared by `tier1` and `agentic-run` |
| `Example.Structured` | a model-generated JSON object validated under a carried schema, decoded into `SchemaEl`, and consumed as an ordinary Haskell record |
| `tier0/`, `tier1/`, `bisim/`, `run/` | the four runners |

**Not** in scope, and deliberately absent: a parser, and the typing judgment.
There is no parser *anywhere* — not here and not in Lean. By the owner's
ruling the authoring surface is Haskell and nothing else, so there is no
concrete syntax left for anything to read; a program is a value, written in
`Agentic.Workflow` and elaborated by `Agentic.Builder`.
The builder gets well-formedness from Haskell's own types instead — an unbound
name, a kind mismatch, a duplicate function name, an empty panel and `served
by` on a tool are type errors or are unrepresentable — so the refusals those
rules produce are reachable only through `Agentic.Guards`, which is what tier0
already replays. Positions are oracle-only throughout, like `message` and
`excerpt`: the builder prints `0:0` and tier1 zeroes both sides.

## What tier0 compares

| entry | rule |
| --- | --- |
| `request.string` (44) | `stringOpOf` of the **whole request object** must equal the whole reply value — the object and not three fields, because `fence` takes a `name`, `matchGlob` a `pattern` and `decide` a `decider` and its `needles` |
| `request.program` (146) | decode, re-encode, and match the request's `program` value |
| refused with one of the six (9) | `guardCheck` must return that guard and its `n` |
| refused `other` (43) | the codec round-trip and nothing else — the typing judgment decided these, and it is not ported. **Read the count honestly:** these 43 entries are checked here as *bytes*, not as refusals. That each is refused at all, and the wording of every message, is held by Lean alone — including the traps the wave-three design named, the shadowing unsettled binder among them — and no Haskell code disagrees with Lean about them because none has an opinion. That is the documented boundary of the no-typing-judgment ruling (`doc/research/connection.md` D10/D11), not a gap this table is hiding |
| checked (94) | `guardCheck` must fire nothing, and `askCounts` must equal `(blockAsks, fnAsks)` |

## What tier1 compares

Twenty-seven checked entries in thirty cases, rebuilt from their surface
source — twenty-four in `Agentic.Builder`, three in `Agentic.Workflow` above it
(the two walked examples and the yield vector), and three of the twenty-four
(`module-000`, `battery-144`, `battery-147`) written a second time in
`Agentic.Workflow` too — and compared whole: no field skipped, a missing or
extra key a failure.

| front | rule |
| --- | --- |
| the printed program | `toJSON (progRawOut built)` against `request.program`, positions zeroed on both sides, and the print decoded back and re-encoded so a print no reader accepts fails here. Twenty-four cases match name for name; the other six — the two walked examples, the yield vector, and the three call vectors rewritten in the authoring surface — match **up to alpha**, both sides' binders canonically renamed first, because the authoring surface generates the names it prints (see below). Function and parameter names are a different namespace and are never renamed, so those six still match them exactly. The renaming is scope-aware — a canonical name is the *level* of the binder that introduced it — so which binding every hole, scrutinee and subject reads stays pinned exactly |
| the static folds | `level`, `size`, `askNodes`, `codes`, `costSummary` folded from the elaborated `Plan` |
| the ask counts | `Agentic.Guards.askCounts` on the *printed* program — week-one code, which is what makes this a cross-check of the builder rather than a second reading of the same term |
| each world | frozen v2 projection: world, event fields `code/addressee/scope/prompt/draw/answer`, legacy bills |

`bisim` strengthens this boundary live with version 3 for generated programs:
it compares intent-bearing Plan events, their bare-question `semanticTrace`
erasure, and operational memo billing. Its fixed P1R case uses version 4 and
also compares the closed program's result code and value.

The builder-written ones are chosen to reach every rung and every corner the
corpus fixes: all
three reachable levels (`batch`, `pipeline`, `branch`), the four built-in answer
codes plus the schema-indexed family, all three parties, draws 0–3, both scope states, `codes` as `null`, `[]` and a
list, bounded revisions at 0, 1, 2 and 3 amendments including two nested inside
a settled arm, and both of the only two entries where the memo bill falls below
the fresh one. The five guard vectors and the refused entries are
**unrepresentable** in the builder by design; tier0 covers them.

Two of the three written in the authoring surface are the **walked examples** —
`example-000`, the flagship, and
`example-001`, the smallest thing that is still a workflow. Those two frozen
entries are not conformance fixtures but *prose*: they are the programs the
documentation walks. They are written in `Example.Harden` rather than in
`tier1/Cases.hs`, and that module is now the text of record for both. They
live in their own
(internal) library because two components must see the same value: tier1 pins
it, and `agentic-run` runs it. Compiling the program twice would let the pinned
one and the executed one drift and still read as agreement.

They are also **what the authoring surface is for**. `tier1/Cases.hs` stays in
`Agentic.Builder`'s index-level spelling — those twenty-three are conformance
fixtures, not prose — but a program a human writes is written in
`Agentic.Workflow`, and this is that program, verbatim from
`example/Example/Harden.hs`, whole but for two of the three panel members:

```haskell
hardenProgram :: Program
hardenProgram = workflow W.do
    guide <- ask (tool "cat") [wf|Write out the house style guide, at most four short lines.|]

    draft <- ask (model "author" `servedBy` "deep") [wf|
        Draft a patch satisfying:
        {spec}
        Reply with a unified diff only.|]

    result <- revising draft (atMost 2) \patch -> W.do
        verdict <- panel
          [ ask (model "reviewer-correct") [wf|
              {guide}
              Is this patch correct?
              {patch}
              {verdictSpec}|]
          ]
        amend (ask (model "author" `servedBy` "deep") [wf|
            {guide}
            Revise this patch:
            {patch}
            {verdict}
            Reply with the revised diff only.|])

    case result of
      Settled patch -> W.do
        ok <- confirm (person "owner") [wf|
            Apply this patch?
            {patch}
            {flagSpec}|]

        when ok $ W.do
          act (tool "apply") [wf|
              Apply:
              {patch}
              Write the patched file here, then reply DONE.|]
      Unsettled _ -> stop
```

Ordinary Haskell: no splice, no bracket, no label, and no type application
anywhere in the program. Statement for statement with the frozen `example-000`
— a bind is a Haskell bind, a fenced prompt is a `[wf|…|]` whose `{name}` holes
and layout rule are the ones the frozen prompts were written under, a `define`
is a Haskell binding (`spec`, `verdictSpec`, `flagSpec` above), and `W.do` is
`QualifiedDo`, which rebinds nothing beyond the block it is written on.

**Both branches are Haskell's own, and they get there by different routes.**
`case result of` is a regular `case` on the regular data type `Outcome`, its
arms `W.do` blocks — there is no `caseResult` combinator to remember. **Both
constructors carry the candidate**: `Settled` the artefact a review approved and
`Unsettled` the one the loop ran out holding, each bound by its own pattern,
live in its own arm and in no other, so splicing one arm's binder in the other
is GHC's own `Variable not in scope`. (`hardenProgram` writes `Unsettled _`
because it has nothing to say about a patch nobody approved; a program that
means to *yield* what the capped trips produced now can, and one does — the
**yield vector**, `tier1/LoopVectors.hs`, the third case tier1 writes in this
surface, whose unsettled arm logs the candidate at a bound where that candidate
is the last *amendment* and no longer the first draft.) It can be a `case`
because a revision's bind *forks*: it runs the rest of the block twice, once
under `Settled` and once under `Unsettled`, and the two blocks that come back
are the arms it prints.

Beside it, `revisingOn` is the same loop reading its review's verdict **three**
ways rather than one predicate two ways — approval settles, an objection amends,
a refusal *abandons* — and its `case` is over `Ending`, whose three
constructors are `SettledOn`, `UnsettledOn` and `AbandonedOn`. (They take the
suffix their loop carries because Haskell has one constructor namespace per
module and `Outcome` already spells the first two; a reader who sees
`UnsettledOn` knows which loop it belongs to.) Its price is arithmetic and is
worth knowing before writing one: the exit is replicated `2n+1` times rather
than `n+1`, so a `revisingOn` with a long tail is a term-size cost a `revising`
is not, and the answer when it bites is to put the tail in a `function` and call
it once per arm. That is exact because Lean refuses every
statement between a revision's bind and its `case` (`Check.lean:653`), so the
two runs can differ only in the arms. Where this surface and Lean's checker do
differ they differ in the *accepting* direction: an author who writes a
statement there is not refused here, and it stands in **both** arms — the same
term an author reaches by writing that statement twice, one the checker accepts
and the oracle observes exactly as `Agentic.Observe` does (checked on an `act`,
a `known here`, a bind and a second revision).

`when ok $ W.do …` is the flag's branch with only one arm to say: it is
`ifThenElse` with both terminals supplied — the body sealed by the implicit
`stop` an arm block ends in, and the empty block for the other arm —
and it prints the very same `ifFlag` node the two-armed spelling prints, `else
{ }` and all. **It is terminal**, and deliberately not `Control.Monad`'s
continuing `when`: every branching in this language is terminal, each arm being
the rest of the workflow, so a continuing `when` would have to duplicate the
statements after it into both printed arms. Nothing follows a `when`, and a
statement that tries is the same `nothing follows a terminal` error a statement
after `stop` is. `unless` is the same with the arms exchanged — the flag is not
negated, because neither the `Raw` nor the `Plan` has a negation to reach for.

A block that ends by asking somebody to do something, and reads no answer, says
so in one statement: `ask_ (tool "say") [wf|…|]` is `act` and then `stop`, and
it is *the same term* — both sides are `B.act (ask …) B.stop`, so the printed
program, the plan, the bills and the generated names are untouched by writing
one instead of the other. `hello` ends that way, as do three arms across
`Example.Isaac` (two more did until `review-lite`'s pair became a `call_` and a
`stop`); nothing needed refreezing and tier1 stayed byte-identical.
The `act` inside a `when` body stays an `act`, because a body is an arm block
*minus* its terminal and `when` supplies that — an `ask_` there is a type
error, which is the right refusal. Since `act` became a statement *value* (so
that one word stands both in a workflow block and in a function body), `when`
and `unless` take a statement rather than a block — a one-statement `W.do` is
that statement, and a `W` is a statement too, so both spellings still reach
them.

With two arms to say, an author writes `if ok then … else …`, a regular `if`,
which reaches `ifThenElse` because the
authoring module enables `RebindableSyntax` — hence its explicit `import
Prelude` and the `Data.String (fromString)` beside it that `OverloadedStrings`
then needs by name. A flag forks at the `if` and **not** at its bind, because a
flag may be bound, acted past, and only then branched on: `battery-043` in the
frozen corpus binds a flag, binds again, `act`s, and branches on the next line.
`caseVerdict` stays a combinator for the same reason, plus one more — its three
arms are Lean's three tags in Lean's order, not the constructors of any Haskell
type.

**The names this program prints are not the names above.** A library cannot
read a Haskell binder's spelling — only Template Haskell can, and the surface
uses none — so each binding prints a name generated from its depth: `b0` is
`guide`, `b1` is `draft`, `b2` is the carrier and the settled binder, `b3` is
the review and the owner's flag, `r2` is the revision's result. A `{hole}`
prints the name its *handle* carries, so a binder and the holes that read it
cannot disagree, and tier1 compares this program against `example-000` up to
alpha. An author who wants the printed program to read as this source does
writes `named "guide" (ask …)`; the flagship deliberately does not. What
`named` will not accept is a name of the shape the surface generates for itself
— `b0`, `b1`, … for a binding and `r0`, `r1`, … for a bounded revision's result
— because those are fresh by construction only while no author claims one, and
a hand-written `b2` sitting anywhere but depth 2 would print the same name as
the binding at that depth: two different bindings reading alike in the printed
program.

That is the whole price of the ruling, stated plainly: a printed program says
`b0` where the frozen entry says `guide` unless someone writes `named`, and five of
twenty-four tier1 cases compare their printed program loosely in exactly one
respect — the spelling of binders. Nothing else is loosened. The nineteen
builder-written cases still match name for name, every non-program comparand
(the folds, the ask counts, the worlds, the traces, the bills) is exact for all
twenty-four, and because the canonicalizer renames by binder level rather than
by position, pointing a hole at the wrong binding of the right kind still
fails: splicing `{guide}` where the flagship splices `{patch}` is caught as
`prompt[2].interp.name: expected "c3", actual "c0"`.

**The three call vectors are written twice, on purpose.** `module-000`,
`battery-144` and `battery-147` are the corpus's function-and-call entries, and
`tier1/Cases.hs` rebuilds all three in `Agentic.Builder`. `tier1/CallVectors.hs`
rebuilds the same three in `Agentic.Workflow` — `function`, `takes`, `call`,
`call_` and `defining` — because those combinators arrived with nothing frozen
behind them: `Example.Harden` exercises the block, and no pinned case exercised
a *call* written in the authoring surface at all. What the second writing pins
that an alpha-compared example cannot is the half of a program whose names are
**not** generated: `lib.drafted`, `goal`, `applied`, `patch` and the argument
each call passes are matched name for name, because a function's namespace is
not a binder's. They live in tier1 and not in the `examples` internal library —
they are conformance fixtures, and a module `agentic-run` cannot see is a module
its example registry cannot grow a row for.

Comparison is on `Data.Aeson.Value`, never on bytes, so object key order and
number formatting are free. `refused.pos`, `.excerpt` and `.message` are
oracle-only and are never compared: they are functions of written characters and
of the checker's wording, neither of which this side has.

Values in failure messages are printed with every non-ASCII and non-printing
character escaped. The corpus turns on differences that are invisible in a
terminal — U+00A0 against a space, `İ` against `i`, a stripped `\r` — and a
diagnostic that hides them would be worse than none.

## Functions, calls, and a program's inputs

Two things a workflow could not say until wave 2, both of which the production
surface (`Agentic.Builder`) and the Lean checker have always had.

**A function is a name, a parameter list, and a body that is a straight line.**
It is declared in the program's table, called by value (`call`, which binds) or
as a statement (`call_`, which does not), and it costs exactly what writing its
statements out at the call site costs — a call is priced at the callee's own
ask count with the arguments ignored, and `graft` splices the callee's nodes at
the call site rather than adding one. `Example.Isaac`'s `review-lite` is the
worked case: its closing report used to be written out once per arm of the
Haskell router, and is now one function both arms call.

```haskell
reviewReport ::
  Fn '[ 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText] 'CodeAck
reviewReport =
  function
    "review-lite.report"
    ( takes @"correctness" Text
        . takes @"haskell" Text
        . takes @"claims" Text
        . takes @"failures" Text
        . takes @"braids" Text
        . takes @"cuts" Text
        $ noParams
    )
    \correctness haskell claims failures braids cuts -> W.do
      act (tool "write-report") [wf|
          {reviewReportBrief}
          {correctness}
          {haskell}
          {claims}
          {failures}
          {braids}
          {cuts}|]
      done

reviewLite :: Parameterized
reviewLite = taking (input "subject" :> noInputs) \subject ->
  defining [SomeFn reviewReport] W.do
    correctness <- ask (model "correctness" `servedBy` "fable") [wf|
        {correctnessLens}
        {subject}|]
    -- … four more reviewers, then the router …
    if touchesHaskell
      then W.do
        haskell <- ask (model "haskell" `servedBy` "fable") [wf|
            {haskellHouseLens}
            {subject}|]

        call_
          reviewReport
          ( arg correctness :> arg haskell :> arg claims
              :> arg failures :> arg braids :> arg cuts :> noArgs
          )
        stop
      else W.do
        call_
          reviewReport
          ( arg correctness :> arg noHaskellEdits :> arg claims
              :> arg failures :> arg braids :> arg cuts :> noArgs
          )
        stop
```

A parameter is the one place this surface asks for a name at the type level,
and it asks because a parameter's name is *printed* — in the function's
signature, and again in every hole of its body — where a binding's is
generated. `takes @"goal" Text` is that name and its kind; two parameters of
one name is `Fresh`'s own refusal, and a name the surface generates for itself
(`b0`, `r0`, …) is refused outright, which is what keeps "fresh by
construction" exact now that an author can spell one.

An argument is either a binding (`arg correctness`, printed as a *name* and
passed by reference, which is why `arg` is not `Says`) or a define (`arg
noHaskellEdits`, printed as literal words). Its kind must be the parameter's
exactly. `defining` is `workflow` with a table, and it checks on a CAF the two
things the type level cannot see: no name twice, and every call naming an entry
declared before it — because an unknown callee is priced at zero and would
print a program Lean refuses.

**A closed program may return an existing answer code.** `Program` and
`Parameterized` remain receipt-valued aliases, so every existing `stop` program
and every explicit `'Open s` signature is source-compatible. `ProgramOf c` and
`ParameterizedOf c` carry the result witness, and `answer` closes the whole
program just as it closes a function body:

```haskell
translated :: ParameterizedOf 'CodeText
translated = taking (input "language" :> noInputs) \language -> workflow W.do
  source <- ask (model "greeter") [wf|Hello, world!|]
  result <- ask (model "translator") [wf|Translate into {language}: {source}|]
  answer result
```

The stage index distinguishes a function return from a program return. Both
branches of an `if`, verdict case or bounded-revision exit must produce the same
result code in Haskell, and Lean's `checkProgramResult` imposes the same code on
every `RawBlock.answer`. The terminal elaborates to `ret`, so it changes no
static fold or bill. `RawProgram` remains the frozen `{fns, main}` record; only
the additive `answer` terminal is new, and conformance version 4 carries the
expected code beside that unchanged object.

**An input is a define supplied at run time.** `taking (input "subject" :>
noInputs) \subject -> …` makes the program a Haskell function of its inputs,
and `{subject}` splices as literal chunks wherever it is written. Input source
metadata changes only how a caller obtains that text:

```haskell
taking
  ( argsInput                 -- command tail, name "args"
      :> stdinInput           -- standard input, name "input"
      :> input "tone"         -- ordinary named/prompted input
      :> noInputs
  )

-- Custom-name alternatives: argsInputAs "scope", stdinInputAs "document".
```

A declaration has unique names, at most one command-tail source, and at most
one stdin source. `run.*` facts remain runner-owned and cannot use either
operator source. These declarations remain outside `main`'s parameter list:
`RawProgram` is still only `fns` and `main`, and source metadata never enters
workflow denotation.
Because an input reaches the term only as literal chunks inside prompts, and no
static fold reads a prompt, **every fold is the same for every input** — which
is why `plan` and `cost` answer without one and say so:

```sh
nix develop -c cabal run agentic-run -- plan review-lite
nix develop -c cabal run agentic-run -- plan review-lite --input ./commit.diff
printf 'diff --git …\n' | \
  nix develop -c cabal run agentic-run -- run review-lite --scripted
nix develop -c cabal run agentic-run -- run review-lite --scripted \
    --input-arg subject='diff --git …'
```

```
review-lite, as elaborated:

  inputs    subject (text) = 4.1 kB from ./commit.diff
  level     branch
  size      12
  askNodes  9
```

The `inputs` line names each input, its source, and byte size, never its value.
`run` requires every input. A declared stdin input not supplied by an explicit
input flag is read strictly as UTF-8 to EOF; empty stdin is valid, while a
terminal refuses with piping guidance instead of hanging. Explicit flags take
precedence. Stdin and command-tail sources preserve decoded text exactly; the
legacy ordinary-file source alone strips one final LF. `plan` and `cost` never
auto-read stdin: they bind missing values to `""`, say so, and accept explicit
input flags when an actual-input plan is wanted.

**Four input names are the runner's and not the command line's.** An input
under the `run.` prefix is a *run fact* — `run.backends`, `run.engine`,
`run.routes`, `run.sentinel` (`Agentic.Workflow.runFacts`) — and `run` binds
every one of them from the run it is making: how many answerers this run reaches
and which, whether each question gets a session of its own or they all share
one, which pin reaches which answerer, and a line generated for this run and put
in no other place than the prompts that hole it. So `run` still requires every
input, but two parties supply them, and the one that supplies these four is not
you: `--input-arg run.engine=acp` is refused, naming who binds it rather than
sending you looking for a typo, because a command line cannot say what a run
did. Nothing else changes — a run fact arrives at `Given` by the same door as
any other input, prints on the same `inputs` line, and is spliced as the same
literal chunks — so every count and every list an operator is shown names only
their own inputs, and a program declaring `subject` and `run.engine` takes *one*
input as far as `--input FILE` is concerned. Declaring a `run.` name that is not
one of the four is the author's mistake and is refused on a CAF, since the
runner would have no such fact to bind. `plan` and `cost` make no run, so they
leave all four unbound at `""` like any other absent input.

`run.routes` is the roster's counterpart and neither derives the other:
`run.backends` is deduplicated and nameless, so no arithmetic over it says
*which pin reaches which*, and `run.engine` says whether going somewhere means
sharing a conversation but never where anything went. One line per answerer,
the default first under the label `(default)`, each right-hand side in the
grammar's own spelling, and empty exactly when there is no table at all:

```
(default) = deck:0f3a91c2-codex
partner = deck:7b2e40aa-claude
```

The default line is there on every live run, `--route` or no `--route`, and that
is deliberate: it is the one line that tells a run whose every question falls to
one session apart from a run where one pin was routed away. A program reads the
fact with `Agentic.Workflow.routedBackend`, which is the header's own spelling
read back — three readers, one sentence, exactly as `run.engine` and
`sharesOneSession` are.

## Running a workflow

A program in this language is a value. The human surface lists registered programs, then reads, prices, or runs them. A separate machine surface emits protocol records only and adds immutable lineage operations.

```sh
nix develop -c cabal build all              # library, examples, all four executables
nix develop -c cabal run agentic-run -- list
nix develop -c cabal run agentic-run -- plan harden
nix develop -c cabal run agentic-run -- cost harden
nix develop -c cabal run agentic-run -- run  harden --scripted
nix develop -c cabal run agentic-run -- run  harden --session my-session
nix develop -c cabal run agentic-run -- run  harden --engine acp --adapter stub
```

Execution is dependency-driven. Every ask node is scheduled as soon as the
de Bruijn support of its prompt expression is available, so siblings that read
the same earlier answers overlap even when they share a serving-model pin.
Branches schedule only the selected arm; equal consultation/observation requests
racing share one memo reservation; effects never do and execute once per
occurrence. Returned traces stay in plan order. Stateful ACP/deck lanes and the
intent-selected effect lane reserve FIFO positions during traversal, so a later
ready effect cannot overtake an earlier blocked effect.

### Symbolic routing profiles

A workflow may name an execution capability rather than a provider model:

```haskell
ask (model "reviewer" `servedBy` "deep-thinker") [wf|Review this change.|]
```

The name `deep-thinker` is part of the authored question. Its physical
realization is execution policy, loaded from two optional YAML files in
increasing precedence order:

1. `$XDG_CONFIG_HOME/agent-cat/routing.yaml`, or
   `~/.config/agent-cat/routing.yaml` when `XDG_CONFIG_HOME` is unset;
2. the nearest `.agent-cat/routing.yaml` between the working directory and the
   repository root; and
3. existing `--route NAME=BACKEND` arguments, which override backend selection
   for the named primary profile while retaining its declared constraints.

A higher YAML layer replaces a same-named router or profile whole. It does not
merge fields. Missing files preserve the former command-line behavior.
Scripted and static commands do not read live routing configuration.

Version 1 uses lists so duplicate names can be refused rather than silently
collapsed by an object decoder:

```yaml
version: 1
routers:
  - name: anthropic-acp
    backend: acp:claude
    provider: anthropic
  - name: review-pane
    backend: deck:reviewer
    provider: anthropic
profiles:
  - name: deep-thinker
    chain:
      - router: anthropic-acp
        model: claude-fable-5
        thinking: max
        max-output: 65536
        options:
          mode: plan
      - router: review-pane
        model: claude-opus-5
        thinking: high
        max-output: 32768
```

A router names one physical backend and its provider. A profile owns a nonempty,
ordered chain of realizations. `model`, `thinking`, and `max-output` are required
policy; `max-output` is either a positive integer bound or `unconstrained`. Only
`options` is optional. Option values retain YAML string, number, or boolean
types; arrays, objects, and null are refused. The
runner applies or verifies
every required value before a prompt and refuses the run when the backend cannot
prove it. There is no silent delegation to a backend default. Valid
thinking values are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and
`max`; `max-output` is a positive integer or `unconstrained`. Unknown fields, empty names or
chains, unresolved routers, duplicate declarations, unsupported values, and
credential-bearing option keys are errors, including token, password,
credential, auth, cookie, bearer, and `*-key` forms. Credentials do not belong
in this file.

For ACP, eager preflight opens a throwaway session for every used rung, validates
its advertised catalogue, and applies every requested setting through
`session/set_config_option`. Only after every setter succeeds does the scheduler
begin. Each dispatched question opens and configures its own session again before
`session/prompt`. Thus an unsupported or setter-refusing late fallback cannot
spend tokens on earlier rungs. For
agent-deck, the runner sends nothing until `agent-deck list --json` identifies
one existing session whose provider, model, thinking level, and any declared
output limit match every constraint. Provider metadata must be explicit: a tool
name such as `claude` is a harness and is not evidence of Anthropic rather
than Bedrock or Vertex. Agent-deck exposes no generic metadata for
backend-specific `options`, so a deck realization carrying them is refused.
The runner neither creates nor mutates deck sessions.

A profile chain and a Haskell `fallingBackTo` chain cannot both own one pin.
That ambiguity is refused before startup. YAML fallbacks acquire stable runtime
axes (`deep-thinker#2`, `deep-thinker#3`, and so on), preserving memo identity
while the header and machine manifest retain their parent profile, concrete
backend, provider, model, declared rung, and settings. The machine event journal
records the generated axis that actually answered. Failover remains sequential and
uses the existing recoverable-gap policy.

The run header names each loaded file and effective realization. Machine runs
persist the same data under `policy.routingSources` and
`policy.realizations`. These records are the audit surface for the mapping; a
symbolic pin by itself makes no claim about a provider model. Because Haskell
may branch while building a program from `run.routes`, live commands hold the
run sentinel fixed and rebuild until the program's pins and its target policy
agree. A cycle or more than sixteen builds is a usage refusal; no backend has
started at that point.

#### Migrating a concrete Haskell ladder

A concrete helper such as:

```haskell
broad party =
  party `servedBy` "fable"
    `fallingBackTo` "gemini-3.1-pro-preview"
    `fallingBackTo` "opus"

greeting <- ask (broad (model "hello-world-greeter")) prompt
```

becomes one symbolic pin in the workflow:

```haskell
greeting <-
  ask (model "hello-world-greeter" `servedBy` "deep-thinker") prompt
```

Define `deep-thinker` under `profiles` in routing.yaml, placing the former
`fable`, Gemini, and Opus particulars in its ordered `chain`, with a router,
model, thinking level, and explicit output policy on every rung. Use a positive
`max-output` bound where enforced and `max-output: unconstrained` otherwise.
Remove the Haskell
`fallingBackTo` calls. Keeping both spellings is refused as ambiguous; this
prevents two sources from claiming authority over fallback order. The
`Workflows.HelloWorld` example in the sibling `agent-workflows` repository is
the runnable migration.

#### Diagnostics and pre-spend refusals

Routing failures are divided by the boundary at which they are known:

* YAML syntax, unknown fields or versions, duplicate names, missing required
  `thinking` or `max-output`, unresolved routers, invalid limits, suspicious
  option keys, ambiguous Haskell/YAML chains, and run-fact fixed-point cycles
  exit `1` before a backend starts. The diagnostic begins `routing
  configuration:` or `refusing to start:` and names the file, profile, or
  generated axis responsible.
* ACP catalogue or setter mismatches exit `2` with `cannot realize the requested
  routing profile` or the adapter's `session/set_config_option` refusal. Every
  used rung is applied on a throwaway session before the scheduler starts; no
  `session/prompt` is sent when any setter fails.
* Agent-deck metadata mismatches exit `2` with the same realization phrase.
  The message distinguishes an absent session, ambiguous id/title, missing
  provider or generation metadata, and a mismatched value. No `session send`
  occurs.
* On success, the `routing configuration:` header lists each loaded file and
  effective rung, including backend options as `key=value` rather than names
  alone. Failover narration names the selected generated axis; machine
  manifests retain the declared chain, and each `occurrence.completed.source`
  in the event journal identifies the rung that actually answered.

Threaded executions in this repository use `+RTS -N8 -RTS`. Open-ended `-N` is
not used, because its capability count follows the host and can saturate
machines with very large core counts.

`plan` and `run` both take `--require-pinned`, which refuses the program —
before it is planned, before an adapter is started, before anything is spent —
if any question put to a *model* does not say `served by` which model serves it
(`Agentic.Guards.guardUnpinnedAsk`, exit `1`). It is this language's answer to
`agent-functor`'s `stackPin`: there a pin wraps a subtree and everything under
it inherits, here who answers is a property of the question, so the guarantee
over questions *not yet written* is taken by refusing a program rather than by
wrapping a scope. Opt-in and off by default: no existing program is affected.

All three verbs also take the input flags — `--input FILE`, `--input-file
NAME=FILE`, `--input-arg NAME=VALUE` — for a program that takes inputs, because
`plan --raw` prints prompts and an operator pricing a run wants to price the
run they will make. A program that takes none refuses them by name, and so does
a flag naming one of the four run facts — those are `run`'s to bind, and the
refusal says so.

The two walked programs are `harden` and `hello`, written in
`Agentic.Workflow` as `Example.Harden`. **They are the same values `tier1` pins
against the frozen corpus** — nothing is rebuilt, adapted or trimmed for
execution — which is what makes a run evidence about the language rather than
about this executable. `Example.Structured` is registered beside them as the
worked representation-boundary example, with `structured-result` showing the
same schema-valued answer returned from the closed program; `Example.Isaac`'s
five follow, with `review-lite` as a program of its subject. Registry entries
remain `Fixed` or `Needs` regardless of result code.

### Machine protocol, controls, and durable lineage

`machine RUN_ID NAME <run options>` executes the same built `Program` through
`runPlanPersisted`/`WorldIO`, but stdout is strict version-1 NDJSON. Events distinguish
chronological sequence from `trace.ordered`, and name runs, occurrences, physical
attempts, output chunks, memo reuse, recovery, redirect, controls, failures, and
terminal bills. Transport/setup diagnostics remain on stderr, but machine mode does not duplicate
input-expanded human narration there. Encoded frames are checked against the 1 MiB limit; large
attempt output is split losslessly, while oversized non-output events fail before writing. ACP input
lines are bounded before JSON decoding. Counters are decimal strings, timestamps are canonical UTC,
and duplicate, conflicting, gapped, or torn journals fail closed.

With `AGENT_CAT_CONTROL_FD=N` (where `N >= 3`), that inherited descriptor
accepts correlated JSON controls while fd 0 remains literal workflow input.
The control reader starts before stdin and route-dependent program construction,
so cancellation also interrupts a blocked input read. Pi uses fd 3. Control
NDJSON still covers whole-run cancel, capability-advertised steering,
runner-offered retry/failover/abandon, and bounded pre-dispatch redirect.
`AGENT_CAT_CONTROL_STDIN=1` remains a legacy compatibility path only when the
stdin-designated workflow value was supplied explicitly; selecting both control
modes is refused. Steering provenance and replay rules are unchanged.

Set `AGENT_CAT_RUN_STORE` to a new private directory to persist the immutable manifest,
private `program.json`, event journal, typed reusable answers keyed by complete bare questions,
started/completed effect journal, and atomic checkpoint. `manifest.json` stores only a fixed
reference to the mode-0600 program file, so source input text is absent from manifests while
remaining available for exact lineage validation. `AGENT_CAT_RUN_OWNER` adds controller metadata.
Unknown versions, corruption, target/program/policy mismatch, and any parent effect record fail closed.

```sh
agentic-run machine         RUN_ID NAME <run options>
agentic-run machine-restart RUN_ID PARENT_STORE NAME <run options>
agentic-run machine-resume  RUN_ID PARENT_STORE NAME <run options>
agentic-run machine-fork    RUN_ID PARENT_STORE NAME [--drop-answer OCCURRENCE] \
  [--set-answer OCCURRENCE=JSON_FILE] <run options>
agentic-run lineage-check   restart|resume|fork PARENT_STORE NAME [fork edits] <run options>
```

Restart inherits no answers and does not require a checkpoint. Resume requires a compatible checkpoint and the exact launch fingerprint. Fork may proceed without a checkpoint,
change input/route state, and explicitly drop or replace persisted answers; only complete bare-question keys that still match can otherwise be reused. Replacement files contain one JSON value and are checked against the persisted code/schema. `lineage-check` validates compatibility, answer/effect/checkpoint counts, and fork edits without creating a child store. All three create a new run with an immutable parent link; none mutates the parent.
A started or completed parent effect refuses resume/fork, because effect completion cannot
be safely inferred or silently replayed. `ci/policies.sh` runs the crash/lineage fixture.

### Structured JSON answers

`structured` asks a model for a closed object with `title`, `priority`, and
`steps`. One splice derives the carried schema, witness, and both conversions
from the record declaration; no type-level schema or nested tuple appears in
the example:

```haskell
data ReleasePlan = ReleasePlan { title :: Text, priority :: Integer, steps :: [Text] }
$(deriveSchema ''ReleasePlan)

consumeModelJson :: Text -> Maybe ReleasePlan
consumeModelJson = decodeAs @ReleasePlan
```

The derived schema is both runtime validator and type index.
`summarizeReleasePlan` consumes every decoded field.

```sh
agentic-run run structured --scripted
# <- {"priority":1,"steps":["decode JSON","consume typed fields"],"title":"Ship structured answers"}

agentic-run run structured-result --scripted
# result structured
#   {"priority":1,"steps":["decode JSON","consume typed fields"],"title":"Ship structured answers"}
```

### `plan` — what the program is, before anyone is asked anything

```
$ agentic-run plan harden
harden, as elaborated:

  level     branch
  size      36
  askNodes  19
  codes     (none — the program branches, so no one sequence of answer kinds)
  cost      minFold 5, maxFold 15, over 9 paths
  (--raw prints the program itself)
```

Every line is a static fold of the elaborated `Plan`, and every one of them is
in the frozen corpus entry for `harden`. `--raw` additionally prints the program
as the builder prints it.

### `cost` — what it can cost to run

```
$ agentic-run cost harden
harden, priced:

  costSummary   minFold 5, maxFold 15, over 9 paths

  no path through this program consults fewer than 5 addressees,
  and none consults more than 15.

  the fold, path by path (9 in all):
    5, 6, 7, 9, 10, 11, 13, 14, 15
```

Nine paths, nine prices, decided before the first question goes out. A run whose
`billFresh` is not one of these nine numbers is a run of a different program.

### `run --scripted` — execute against a table, and ask nobody

```
$ agentic-run run harden --scripted
running harden against the scripted table (8 canned replies)

  consult text -> tool cat: Write out the house style guide, at most four short lines.
    <- House style: two-space indent, no tabs, every public name documented, …
  consult text -> model author: Draft a patch satisfying: harden the parser …
    <- --- a/src/parse.c +++ b/src/parse.c @@ …
  consult verdict -> model reviewer-correct: … Is this patch correct? …
    <- approve
  consult verdict -> model reviewer-secure: … Is this patch secure? …
    <- approve
  consult verdict -> model reviewer-simple: Could this patch be simpler? …
    <- approve
  consult flag -> person owner: Apply this patch? …
    <- yes
  effect ack -> tool apply: Apply: … Write the patched file here, then reply DONE.
    <- done

  the run is over.
    answer      () — a workflow's value is the unit; what it did is the trace
    billFresh   7 (request occurrences reached)
    billMemo    7 (reusable requests deduplicated; every effect occurrence kept)
```

The canned replies are `agent-cat/test/stub_adapter.py`'s, keyed **by prefix**
rather than by substring: a substring key can match a prompt through an answer
that was spliced into it, and a patch that happened to contain the words
`correct?` would otherwise answer the reviewers' question. They are *bytes*, not
answers — `"yes"` goes through `Agentic.Text.decodeFlag` like any live reply, so
the scripted world has no private channel to the answer type.

### `run --session` — execute against a live agent-deck session

```sh
agentic-run run harden --session <id|title> \
    [--binary PATH] [--poll MS] [--timeout MS] [--verbose]
```

| option | what it is | default |
| --- | --- | --- |
| `--session` | the session id or title every question is put to | — |
| `--binary` | the `agent-deck` executable | `agent-deck`, found on `PATH` |
| `--poll` | milliseconds between two checks of the session's status | `1000` |
| `--timeout` | milliseconds one turn may take before it is abandoned | `600000` (= `agent-deck session send`'s own `-timeout` default) |
| `--verbose` | narrate the transport — every command, every poll — on stderr | off |

One question is one turn, and a turn is three commands:

1. `agent-deck session output <id> --json` — *before* sending, to learn the
   timestamp of the reply already there. Without this the window between
   "submitted" and "the agent has begun" reads as idle, and the **previous**
   turn's text is recorded as this question's answer.
2. `agent-deck session send <id> --message-file <private-file>` — the rendered
   question through a mode-0600 temporary file, never argv or command diagnostics.
3. `agent-deck session show <id> --json`, every `--poll` milliseconds, until
   `status` is no longer `running`; then `session output <id> --json` again,
   accepted only once its `timestamp` differs from the one taken in step 1.

The whole turn is bounded by `--timeout`, re-asks included (a second attempt is
a second turn, and charging it what the first one spent would make a slow answer
unaskable twice). Exit `0` is a completed run, `1` a usage error, `2` a
transport failure, `3` a run abandoned because an answer could not be read.

#### Everything goes to the one session

The language has three kinds of addressee — `model "reviewer-secure"`,
`tool "apply"`, `person "owner"` — and **this adapter sends all three to the
same `--session`.** That is a ruling about this transport, not about the
semantics: a world is a function of bare questions. The annotated transport
happens to send every authored request to one session.

The addressee is not lost. It is the first thing the rendered question says, so
the agent knows whose part it is being asked to play:

```
[question for model author
intent: consult
model: deep
answer (text): Reply with the text itself and nothing else.]

Draft a patch satisfying:
harden the parser
Reply with a unified diff only.
```

#### The format line, and why it is adapter behaviour

The header's last line is `Agentic.Exec.answerSpec` — for a `flag`, `Reply with
exactly yes or no.`; for a `verdict`, `Reply with exactly APPROVE if acceptable,
or OBJECTION: <one line> if not.` It is there because the trusted base is narrow
on purpose and a live model cannot be expected to guess it.

**This is adapter behaviour and not language semantics.** Nothing in
`Agentic/Core/Question.lean` says a question carries its own answer format; what
the language says is that a `flag`'s answer set is `Bool`. A different transport
may say it differently — or select it over a protocol, which is what
`Exec.renderQ`'s `Selected` argument is for and what the `agent-deck` CLI has no
call for — and the program means the same thing. The wording is imported from
`Agentic.Exec` and never re-phrased locally, because an addressee told two
different formats in one prompt obeys neither.

If a reply still cannot be read, `Agentic.Exec` re-asks **once**, appending a
nudge that quotes the unreadable words back, and then abandons the run rather
than recording an answer nobody gave — a defaulted table cell is
indistinguishable from a real one, and no check further down could recover the
difference.

That policy is now written down as data rather than as a branch in a loop:
`Agentic.Exec.ExecSettings` carries a re-ask budget per `TurnGap`
(`GapUndecodable` 1, `GapTransportRefusal` 0, `GapEmptyOrProtocol` 0 — the
taxonomy is `agent-functor`'s, the numbers are today's behaviour), the
`RetryHere | FailOver | Abandon` fork as a pure `Recover` function, an
`esLoudArm` under which an unreadable *flag* takes an operator-configured arm
with a warning instead of abandoning, and an `esStandingAnswer` a person
question falls back on in an unattended run instead of waiting on somebody who
is not there. `FailOver` is declared and refuses by name: a fallback list on
`served by` changes the printed program, so the mechanism is a later wave's and
only the vocabulary is here. **Every field defaults to what this section
already describes**, so nothing above changes unless an operator asks.

### `run --engine acp` — execute against an adapter this run starts

```sh
agentic-run run harden --engine acp [--adapter stub|claude|codex|droid|PATH] \
    [--adapter-arg ARG]... [--scratch DIR] [--timeout MS] [--verbose]
```

| option | what it is | default |
| --- | --- | --- |
| `--engine acp` | start an ACP adapter and speak line-delimited JSON-RPC 2.0 to it over a pipe this process owns | — |
| `--adapter` | the answering program: `stub` (`agent-cat/test/stub_adapter.py`, under `python3`); `claude` and `codex` (looked for on `PATH`, then at their machine-local nix-store pins); `droid` (`droid exec --output-format acp` from `PATH`); or a path | `stub`, announced when it was not typed |
| `--adapter-arg` | one argument appended to the adapter's `argv`; repeatable — `--adapter-arg --refuse` is how the stub is told to answer *no* to the owner | — |
| `--scratch` | the adapter's working directory, and the only place an act is authorized to write | a fresh temporary directory, printed |
| `--timeout` | milliseconds one request may take before the child is killed and the question named | `900000` |
| `--verbose` | narrate the transport on stderr | off |

`droid` uses Factory Droid's native ACP mode; it does not add a Python SDK
dependency or a second transport. Install and authenticate the Droid CLI first,
or provide `FACTORY_API_KEY` in the environment that starts `agentic-run`. Never
put the key in `--adapter-arg`, routing YAML, or a wrapper script.

```sh
agentic-run run structured --engine acp --adapter droid
agentic-run run harden --engine acp --adapter stub --route deep=acp:droid
```

A plain Droid backend uses Droid's configured session default. To select a model
and reasoning level, define a routing profile whose router is `acp:droid` and set
`max-output: unconstrained`; agent-cat validates and applies both settings through
the existing `session/set_config_option` path before any prompt. Declaring an
unsupported setting still refuses preflight. Do not append `--model`: ACP session
settings do not come from Droid's ordinary command-line model flag.

One adapter process may retain subscriptions for sessions opened earlier in the
run. Agent-cat accepts answer chunks only for the current `sessionId`. Permission
requests must also match the session and dynamic extent of an active prompt; stale
or delayed out-of-turn requests are cancelled.

The honest paragraph. **This transport can promise one thing the `agent-deck`
one cannot.** `session/prompt` answers with a `stopReason`, and exactly one of
ACP's five words — `end_turn` — means the agent finished; so when
`Agentic.Exec.requiresCompletedTurn` says an answer needs a completed turn (an
semantic `effect`, or anything addressed to a person), this adapter checks it:
a cancelled effect abandons the run with exit `3` rather than recording a receipt
that did not happen. `Agentic.AgentDeck` says in as many words that it cannot
make that check, because the CLI it drives reports no stop reason. Everything
else is the same runtime: the question is rendered by the same `renderQ` with
the same `Agentic.Exec.answerSpec` line, decoded by the same trusted base,
re-asked once by the same loop, and abandoned in the same words. What is
*not* here is Lean's `--session`/`--fork-session` handoff,
`session/set_mode`, or its second clock. An unconfigured symbolic axis travels
in the prompt header; a routing profile's concrete model and generation settings
are instead validated and applied through `session/set_config_option`. One
`--timeout` bounds a whole request, and a wedged pipe is a wedged request.

Two policies are worth reading before pointing this at a directory you care
about. Each request gets a **new session** because a semantic world is a function
of the bare question while a session remembers predecessors — an approximation,
not a theorem. Tool permission is granted only when `permissionByIntent` sees
`Effect`; consultations and observations are declined. Thus answer code no longer
stands in for authority, and every decision is printed. The grant remains an
assumption about the adapter, directory and requested tool call.

### Testing the transport without a live session

`ci/acp.sh` drives the ACP stub directly and through a fake `droid` on `PATH`.
The Droid scenario validates `droid exec --output-format acp`, appended arguments,
default and routed turns, current-session answer and permission correlation, and
a dead-process failure without Factory credentials or network access.

The separately authorized live record—including diagnostic history and the one
post-fix acceptance smoke—is inspectable at
[`../doc/droid-live-verification.md`](../doc/droid-live-verification.md).

`ci/deck.sh` runs `agentic-run` against `test/stub-deck.sh`, a fake `agent-deck`
implementing exactly the three commands the adapter uses and refusing every
other one loudly. No Lean, no network, no session:

```sh
./ci/deck.sh
```

```
ci/deck: happy: settled in 7 turns, exit 0
ci/deck: objects: 13 ask nodes, 6 questions put, exit 0
ci/deck: undecodable: re-asked once, then abandoned, exit 3
ci/deck: stopped: named as a transport failure, exit 2
ci/deck: hang: bounded by the turn budget, exit 2
ci/deck: stale: the previous turn's text was refused on the second question, exit 2
ci/deck: missing: named as a transport failure, exit 2
ci/deck: two-panes: one run, two sessions, the pin in its own pane, 6+1 of 7, exit 0
ci/deck: 8 scenarios passed, 0 failed
```

The second scenario is the one worth naming. Every reviewer objects and every
revision answers with the *same* patch, so the second and third review rounds
put questions that were already answered: the run walks **13** ask nodes and the
session is sent **6** messages. That gap is the memo table, observed from
outside the process — a memoized reusable request is a message never received —
and 13/6 matches the pure `Agentic.World` fold for this effect-free repetition.

The eighth is the two-pane one, and it is what makes `run.routes` worth
carrying. One `run harden --session pane-a --route 'deep=deck:pane-b'` against
**two** instances of the stub — a four-line shim installed as `agent-deck`
derives each pane's state directory from the session id, so the stub itself is
unedited — and the assertion is a *partition*: the pinned question is in
`pane-b`'s transcript and in no other, everything with no axis to route by is in
`pane-a`'s, and the two send counts are 1 and 6 against the run's own bill of 7.
The two negative greps are the gate; everything else could be true of a run that
sent both questions to both panes.

## The CI shape

Two lanes, per the one-build rule (connection.md §3.9 — one Lean build at a
time, machine-wide, so Lean builds must be rare, not merely serialized):

```sh
./ci/tier0.sh      # every commit: tier0 + tier1 against the frozen corpus — no Lean at all
./ci/deck.sh       # every commit: the deck transport, against test/stub-deck.sh — no Lean, no session
./ci/acp.sh        # every commit: the ACP transport, against agent-cat/test/stub_adapter.py
./ci/examples.sh   # every commit: every registered example's numbers, against a pinned table — no Lean
./ci/citations.sh  # every commit: every `X.lean:N` cited in a docstring still resolves — no Lean
./ci/policies.sh   # every commit: the Exec policies probed against an unreadable flag — no Lean
./ci/tier1.sh      # nightly / semantic-core changes: bisim against the PREBUILT oracle
```

`ci/citations.sh` checks that every `X.lean:N` written in a docstring under
`haskell/` names a file that exists and a line within it — including the bare
`@:N@` continuation form, resolved against the file named above it — because a
citation is how this package claims to be a port rather than a rewrite, and a
stale one is worse than none: when the Lean transport was retired, 57 of the
220 citations here named a vanished file or a line past the end, and
an old citation to line 925 of `Exec.lean` went on resolving to an unrelated retry loop.

`ci/acp.sh` is twelve scenarios against the deterministic stub adapter,
`agent-cat/test/stub_adapter.py` — real ACP over real pipes, and never a real
agent. Five
of them are the transport's named failures; the two that matter most are
`cancelled-act`, where an act's turn is interrupted and the run is abandoned
rather than credited, and `write-on-ask`, where the adapter asks to edit the
workspace during a draft turn, is denied, and the run's directory is checked
afterwards to prove nothing was written.

`ci/policies.sh` is 43 executable checks plus two command-line refusals. Six
of those checks pin the concurrent executor directly: dependency-independent
prompts at one model overlap while the trace stays in plan order; prompts
sharing an earlier answer remain blocked until it arrives and then overlap;
equal reusable requests racing for memo ownership execute once but occupy both
trace nodes; equal effects instead execute and bill twice;
dependency waits; and one prompt's failure cancels a blocked sibling and runs
its cleanup. The gate also pins **fail-over**
as well as the loud arm, standing answers, retry budgets, routing, the authoring
surface's refusals, and the executing world. Its fail-over acceptance criterion
is that a question pinned `deep or broad` settles on `broad`, attributes that
answer in the trace, narrates the transition, and still abandons in the old
words when no chain is declared. Its executing-world rows assert that `true`
and `false` command exits become typed answers, two commands at one tool id are
two questions, and an unspawnable command is a named gap rather than an answer.

`ci/examples.sh` is the third no-Lean lane, and the one that watches the
programs the corpus does not. It reads the registry out of the binary — an
unknown name is refused with the list of them — and for each of the seven runs
`plan`, `cost` and `run --scripted`, holding `level`, `size`, `askNodes`,
`costSummary` and the `billFresh`/`billMemo` pair against a table pinned in the
script itself, with each row citing where the same number is also published.
`harden` and `hello` are pinned three times over by the frozen corpus and are
here anyway, so that the gate is a statement about the *registry*: a program
cannot be registered without being priced, and a row naming no program fails
too. The five Isaac programs are the reason it exists — they are deliberately
unfrozen (isaac-workflows §6, D10), so their numbers live in haddocks and one
document and nothing else would notice them going stale. A mismatch prints the
program, the field, the expected value and the actual one, and exits 1. A
program that takes inputs is given them here too — `review-lite` gets the
subject that its deleted script entry used to answer with — and the gate ends
by checking D8's own claim: at two different subjects the five fold lines are
identical and the printed programs are not.

`ci/tier1.sh` takes the oracle path from `$ORACLE` (defaulting to agent-cat's
`.lake/build/bin/conformance-oracle`), the iteration count from `$N` and an
optional `$SEED`; it **fails loudly** when the binary is missing rather than
degrading to Tier 0. It never runs `lake build`: the oracle is a build
artifact of the *Lean side*, produced when Lean changes, not when the Haskell
changes. Divergences found live land as ordinary reviewed corpus commits on
the Lean side, not as bot pushes.

## Layout

```
flake.nix          the devShell: one GHC with aeson and QuickCheck, plus cabal-install
agentic.cabal      library (src) + internal library examples (example) + executables
src/Agentic/Raw.hs      the Raw AST and its JSON codec
src/Agentic/Guards.hs   guardCheck, askCounts
src/Agentic/Text.hs     stringOp, Verdict — the trusted string base
src/Agentic/Schema.hs   the format-independent SchemaEl algebra and code singletons
src/Agentic/Schema/Json.hs       user-facing Aeson codec + JSON Schema
src/Agentic/Schema/Conformance.hs exact semantic-value wire codec for tests
src/Agentic/Schema.hs   the format-independent SchemaEl algebra and HasSchema conversion
src/Agentic/Schema/Json.hs strict JSON codecs and record-level decodeAs/renderAs helpers
src/Agentic/Schema/TH.hs Template Haskell derivation from record declarations
src/Agentic/World.hs    WorldSpec, toWorld, trace, the bills, the event JSON
src/Agentic/Builder.hs  the production surface and its elaboration
src/Agentic/WF.hs       the [wf|…|] and [wft|…|] prompt quoters, and what a {hole} may name
src/Agentic/Workflow.hs the authoring surface: handles, questions, the indexed block
src/Agentic/Workflow/Do.hs        W.do — the one block grammar, workflow and revision
src/Agentic/Gen.hs      the generators the bisimulation draws from
src/Agentic/Observe.hs  the reply assembly both runners share
src/Agentic/Oracle.hs   the line-delimited JSON client for the Lean oracle
src/Agentic/Exec.hs     the IO interpreter: STM dependency scheduling, memoization and decode
src/Agentic/AgentDeck.hs  one agent-deck session as an answering service
src/Agentic/Acp.hs      an ACP adapter this process starts, as an answering service
src/Agentic/Cli.hs      the runner as a function of its registry: the five verbs,
                        the flags, the refusals, the usage message
example/Example/Harden.hs the walked examples and the examples registry
example/Example/Structured.hs model JSON decoded into typed Haskell fields
test/SchemaProbe.hs     schema algebra, codec and decode/re-ask regression probe
tier0/Main.hs           the corpus runner
tier1/Cases.hs          the rebuilt cases, each quoting its surface source
tier1/Main.hs           the rebuilt-case runner; it owns every comparison
bisim/Main.hs           the live differential against the Lean oracle
run/Main.hs             agentic-run: Agentic.Cli's cliMain at the examples
                        registry, and the argument for the two-registry split
test/stub-deck.sh       a fake agent-deck, for testing the deck transport
test/acp-misbehave.sh   an ACP adapter that babbles or wedges, for the two failures
                        a conforming stub cannot produce
ci/tier0.sh             the PR gate: tier0 + tier1
ci/deck.sh              the PR gate: the deck transport, eight scenarios
ci/acp.sh               the PR gate: the ACP transport, sixteen scenarios
ci/citations.sh         the PR gate: every cited Lean line still resolves
ci/tier1.sh             the nightly gate: bisim against the prebuilt oracle
```

## Sources of record

* **The design** — why there is a Haskell implementation at all, and why it is
  connected to Lean by reimplementation-plus-conformance rather than by
  extraction, FFI or a subprocess oracle —
  `doc/research/connection.md`. That
  page is the design of record for this repository.
* **The port** — the modules themselves. Every rule each one obeys is stated in
  its own header: the codec in `Agentic.Raw`, the guard order and the contract
  it is held to in `Agentic.Guards`, the folds in `Agentic.Plan`, the trace and
  the bills in `Agentic.World`, the elaboration in `Agentic.Builder`, and the
  comparison rules in `tier0/Main.hs` and `tier1/Main.hs`. For the **authoring**
  surface the text of record is the live
  [`example/Example/Harden.hs`](example/Example/Harden.hs), quoted above.
* **The wire format** —
  `doc/conformance-schema.md`.
* **The arbiter** — `test/corpus/*.json`. Where a module here and the corpus
  disagree, the corpus wins; where the corpus and the Lean source disagree,
  Lean wins.

Nothing outside `haskell/` is ever edited from here. The Lean side is read,
and it is obeyed.
