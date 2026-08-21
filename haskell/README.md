# haskell/ — the Haskell implementation

The Haskell implementation of agent-cat's operational terms, living beside
the Lean formalization it implements (the repository root) — the raw syntax
of the agentic language, its JSON codec, the term-level guards, the ask counts
and the string layer, and above them the typed `Plan`, its meaning in a world
and the production surface that builds one, and above *that* the authoring
surface a human actually writes — kept honest by replaying a frozen corpus
produced by the Lean formalization.

Lean is normative. This directory does not ask to be believed on its own
authority: every claim it makes about the language is checked against 189
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
tier0: kinds: 44 string, 9 guard, 43 other, 93 checked, 0 ping, 0 unclassified
tier0: 189 passed, 0 failed, 43 other-refusals (codec-only), of 189 files
tier1: 29 passed, 0 failed, of 29 cases
```

`tier0` replays every entry through the codec, the guards and the string layer.
`tier1` **rebuilds** twenty-six of the checked entries, in twenty-nine cases
— twenty-three in the production surface, three in the authoring surface above
it (the two walked examples and the yield vector), and three of the twenty-three
a second time in that authoring surface — and holds each rebuilt program against
the frozen one on both fronts: the program it prints, and the whole reply —
folds, counts, and one trace and two bills per world.

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
| `Agentic.Plan` | the typed `Plan` — five formers, `DataKinds` codes, de Bruijn `Expr` — and its static folds `level`, `size`, `askNodes`, `codes`, `costSummary` |
| `Agentic.World` | `WorldSpec` and `toWorld`, the `trace` of a plan through a world, the fresh and memo bills, and the oracle's event JSON |
| `Agentic.Builder` | the production surface: typed combinators that both print a `RawProgram` and elaborate to the `Plan` the Lean checker elaborates the same construct to |
| `Agentic.WF` | the `[wf\|…\|]` prompt quoter — prose with `{name}` holes, laid out by the fence rule the frozen prompts were written under (blank edge lines dropped, common indentation stripped, no trailing newline) and chunked as the elaborator's left-associated `Prompt.expr` requires — adjacent literals never fused, empty literals dropped — and `Says`, which decides whether a hole is a binding or a `define`; and `[wft\|…\|]`, the same fence yielding a define's `Text` rather than a prompt's chunks, so that a define need not be written as a prompt and converted. One `parseFence` under both, so the two spellings of a block cannot differ by a byte |
| `Agentic.Workflow` (+ `.Do`) | the **authoring** surface: an indexed block, written in ordinary Haskell under `W.do`, in which a bind is a Haskell bind, a branch on a revision's result is a Haskell `case` and a branch on a flag is a Haskell `if` — `guide <- ask (tool "cat") [wf\|…\|]`, then `case result of Settled patch -> W.do …; Unsettled patch -> stop`, then `when ok $ W.do …`. The `case` is real pattern matching on the exported data type `Outcome`, which the revision's bind forks into; the `if` is Haskell's, reaching the exported `ifThenElse` because the **authoring module** enables `RebindableSyntax` — which costs that module its implicit `Prelude` (import it, and `Data.String (fromString)` beside it under `OverloadedStrings`) and costs a `W.do` block nothing, `QualifiedDo` and `RebindableSyntax` rebinding disjoint syntax. The library itself enables neither. There is no `#label`, no `=:` and no splice anywhere in the surface: `ifFlag` stays exported as the combinator the `if` compiles *to* — machinery, and a name in the printed `Raw`, not a statement anyone writes — and `when`/`unless` are that same `if` with only one arm to say — terminal, sealing the body with the implicit `stop` an arm block's end is, and printing the identical `ifFlag` node with an empty other arm; the `case` compiles to `Agentic.Builder`'s `revisingCase`, which `revising` applies; `caseVerdict` stays a combinator here, a verdict being a value that may be acted past. It carries no names at the type level — a library cannot read a Haskell binder — so it generates the name each binding prints from that binding's depth, `named` overrides one, and a `{hole}` prints the name its handle carries |
| `Agentic.Gen`, `Agentic.Observe`, `Agentic.Oracle` | the bisimulation surface: generators, the reply assembly both runners share, and the line-delimited JSON client for the Lean oracle subprocess |
| `Agentic.Exec` | the interpreter in `IO` — the memoizing fold of `Exec.lean`'s `Dlg.execM`, its decode/re-ask loop, the failure vocabulary and its budgets, and the **fail-over walk**: a pinned question is put to the models its chain names, in order, and the trace records the one that actually answered |
| `Agentic.Chains` | one traversal of a printed program into the chain table the runner walks — `primary -> alternates`, ill-definedness refused before the run starts |
| `Agentic.Shell` | the world that answers a `toolExec` question by **running its command**: no shell, the prompt on the child's stdin, a per-command timeout, and one answer per code — an exit code where the answer type can express failure, an abandoned run where it cannot |
| `Agentic.AgentDeck` | one live `agent-deck` session as an answering service: the three CLI commands, the poll loop, the staleness guard and five named transport failures |
| `Agentic.Acp` | an ACP adapter this process starts, as an answering service: the handshake, a session per question, the permission policy per question, the stop reason — which is what lets this transport refuse a receipt from a turn that did not finish — and six named transport failures |
| `Example.Harden` | the walked examples (`harden`, `hello`), written in `Agentic.Workflow` and shared by `tier1` and `agentic-run` |
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
| `request.program` (145) | decode, re-encode, and match the request's `program` value |
| refused with one of the six (9) | `guardCheck` must return that guard and its `n` |
| refused `other` (43) | the codec round-trip and nothing else — the typing judgment decided these, and it is not ported. **Read the count honestly:** these 43 entries are checked here as *bytes*, not as refusals. That each is refused at all, and the wording of every message, is held by Lean alone — including the traps the wave-three design named, the shadowing unsettled binder among them — and no Haskell code disagrees with Lean about them because none has an opinion. That is the documented boundary of the no-typing-judgment ruling (`doc/research/connection.md` D10/D11), not a gap this table is hiding |
| checked (93) | `guardCheck` must fire nothing, and `askCounts` must equal `(blockAsks, fnAsks)` |

## What tier1 compares

Twenty-six checked entries in twenty-nine cases, rebuilt from their surface
source — twenty-three in `Agentic.Builder`, three in `Agentic.Workflow` above it
(the two walked examples and the yield vector), and three of the twenty-three
(`module-000`, `battery-144`, `battery-147`) written a second time in
`Agentic.Workflow` too — and compared whole: no field skipped, a missing or
extra key a failure.

| front | rule |
| --- | --- |
| the printed program | `toJSON (progRawOut built)` against `request.program`, positions zeroed on both sides, and the print decoded back and re-encoded so a print no reader accepts fails here. Twenty-three cases match name for name; the other six — the two walked examples, the yield vector, and the three call vectors rewritten in the authoring surface — match **up to alpha**, both sides' binders canonically renamed first, because the authoring surface generates the names it prints (see below). Function and parameter names are a different namespace and are never renamed, so those six still match them exactly. The renaming is scope-aware — a canonical name is the *level* of the binder that introduced it — so which binding every hole, scrutinee and subject reads stays pinned exactly |
| the static folds | `level`, `size`, `askNodes`, `codes`, `costSummary` folded from the elaborated `Plan` |
| the ask counts | `Agentic.Guards.askCounts` on the *printed* program — week-one code, which is what makes this a cross-check of the builder rather than a second reading of the same term |
| each world | per `request.worlds` in order: the world re-serialized, its trace event by event (`code`, `addressee`, `scope`, `prompt`, `draw`, `answer`), and `billFresh` / `billMemo` |

The builder-written ones are chosen to reach every rung and every corner the
corpus fixes: all
three reachable levels (`batch`, `pipeline`, `branch`), all four answer codes,
all three parties, draws 0–3, both scope states, `codes` as `null`, `[]` and a
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

**An input is a define supplied at run time.** `taking (input "subject"
noInputs) \subject -> …` makes the program a Haskell function of its inputs,
and `{subject}` splices as literal chunks wherever it is written, including
inside the `if` arms. It is deliberately not `main`'s parameter list:
`RawProgram` is `fns` and `main`, there is nowhere to print a parameter, and a
`main` holing a name no printed binder introduces is a program Lean refuses.
Because an input reaches the term only as literal chunks inside prompts, and no
static fold reads a prompt, **every fold is the same for every input** — which
is why `plan` and `cost` answer without one and say so:

```sh
nix develop -c cabal run agentic-run -- plan review-lite
nix develop -c cabal run agentic-run -- plan review-lite --input ./commit.diff
nix develop -c cabal run agentic-run -- run  review-lite --scripted \
    --input-arg subject='diff --git a/src/Export.hs b/src/Export.hs'
```

```
review-lite, as elaborated:

  inputs    subject (text) = 4.1 kB from ./commit.diff
  level     branch
  size      12
  askNodes  9
```

The `inputs` line names the input, where its text came from and how big it is,
and never the text itself, which can be a whole diff. `run` requires every
input; `plan` and `cost` bind a missing one to `""` and say so on that line,
and under `--raw` a note stands immediately above the printed program, because
a program printed with an empty subject is a different text from the one that
will run.

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

A program in this language is a value, and `agentic-run` is the four things you
can do: list the registered ones, then read, price or run any of them.

```sh
nix develop -c cabal build all              # library, examples, all four executables
nix develop -c cabal run agentic-run -- list
nix develop -c cabal run agentic-run -- plan harden
nix develop -c cabal run agentic-run -- cost harden
nix develop -c cabal run agentic-run -- run  harden --scripted
nix develop -c cabal run agentic-run -- run  harden --session my-session
nix develop -c cabal run agentic-run -- run  harden --engine acp --adapter stub
```

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

`<example>` is `harden` or `hello`: the two walked programs, written in
`Agentic.Workflow` as `Example.Harden`. **They
are the same values `tier1` pins against the frozen corpus** — nothing is
rebuilt, adapted or trimmed for execution — which is what makes a run evidence
about the language rather than about this executable. `Example.Isaac`'s five
are registered beside them, `review-lite` as a program of its subject; the
registry entry is `Fixed` or `Needs` accordingly.

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

  text -> tool cat: Write out the house style guide, at most four short lines.
    <- House style: two-space indent, no tabs, every public name documented, …
  text -> model author: Draft a patch satisfying: harden the parser …
    <- --- a/src/parse.c +++ b/src/parse.c @@ …
  verdict -> model reviewer-correct: … Is this patch correct? …
    <- approve
  verdict -> model reviewer-secure: … Is this patch secure? …
    <- approve
  verdict -> model reviewer-simple: Could this patch be simpler? …
    <- approve
  flag -> person owner: Apply this patch? …
    <- yes
  ack -> tool apply: Apply: … Write the patched file here, then reply DONE.
    <- done

  the run is over.
    answer      () — a workflow's value is the unit; what it did is the trace
    billFresh   7 (consultations the run reached)
    billMemo    7 (distinct questions, which is what was put)
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
2. `agent-deck session send <id> <message>` — the rendered question.
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
semantics: a world in `Agentic/Core/World.lean` is a function of the question,
and this one is a function of the question that happens to route every question
to the same place.

The addressee is not lost. It is the first thing the rendered question says, so
the agent knows whose part it is being asked to play:

```
[question for model author
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
agentic-run run harden --engine acp [--adapter stub|claude|codex|PATH] \
    [--adapter-arg ARG]... [--scratch DIR] [--timeout MS] [--verbose]
```

| option | what it is | default |
| --- | --- | --- |
| `--engine acp` | start an ACP adapter and speak line-delimited JSON-RPC 2.0 to it over a pipe this process owns | — |
| `--adapter` | the answering program: `stub` (`agent-cat/test/stub_adapter.py`, under `python3`), `claude` and `codex` (looked for on `PATH`, then at their machine-local nix-store pins), or a path | `stub`, announced when it was not typed |
| `--adapter-arg` | one argument appended to the adapter's `argv`; repeatable — `--adapter-arg --refuse` is how the stub is told to answer *no* to the owner | — |
| `--scratch` | the adapter's working directory, and the only place an act is authorized to write | a fresh temporary directory, printed |
| `--timeout` | milliseconds one request may take before the child is killed and the question named | `900000` |
| `--verbose` | narrate the transport on stderr | off |

The honest paragraph. **This transport can promise one thing the `agent-deck`
one cannot.** `session/prompt` answers with a `stopReason`, and exactly one of
ACP's five words — `end_turn` — means the agent finished; so when
`Agentic.Exec.requiresCompletedTurn` says an answer needs a completed turn (an
`act`, whose `Decode .ack` is total and would accept any bytes at all, or
anything asked of a `person`), this adapter can check it and does: a cancelled
act abandons the run with exit `3` rather than recording a receipt for something
that did not happen. `Agentic.AgentDeck` says in as many words that it cannot
make that check, because the CLI it drives reports no stop reason. Everything
else is the same runtime: the question is rendered by the same `renderQ` with
the same `Agentic.Exec.answerSpec` line, decoded by the same trusted base,
re-asked once by the same loop, and abandoned in the same words. What is
*not* here is Lean's `--session`/`--fork-session` handoff, its
`session/set_mode` and `session/set_config_option` scope calls (both axes travel
in the prompt header instead, exactly as they do for the deck), and its second
clock: one `--timeout` bounds a whole request, and a wedged pipe is a wedged
request.

Two policies are worth reading before pointing this at a directory you care
about. Each question gets a **new session** (`Exec.Settings.freshSessionPerQuestion`),
because a world is a function of the question and a session is a memory of the
ones before it — an approximation, and a policy rather than a theorem. And a
tool permission the agent asks for is granted **only during an act**
(`Exec.permissionByCode`): an ask — text, verdict or flag — is declined in the
schema's own `{"outcome":"cancelled"}`, so an agent cannot rewrite the workspace
during a turn that asked it only to think. Every decision is printed. The grant
is still an assumption and it is stated rather than proved: the runtime is
speaking to an adapter it started, in a directory it chose, and a tool call
inside that directory is authorized by a question that asked for one.

### Testing the transport without a live session

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
outside the process — a memoized question is a message the session never
received — and 13/6 is exactly what the pure `Agentic.World` fold gives for the
same program at the same world.

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
`Exec.lean:925` went on resolving, to an unrelated retry loop.

`ci/acp.sh` is twelve scenarios against the deterministic stub adapter,
`agent-cat/test/stub_adapter.py` — real ACP over real pipes, and never a real
agent. Five
of them are the transport's named failures; the two that matter most are
`cancelled-act`, where an act's turn is interrupted and the run is abandoned
rather than credited, and `write-on-ask`, where the adapter asks to edit the
workspace during a draft turn, is denied, and the run's directory is checked
afterwards to prove nothing was written.

`ci/policies.sh` is nineteen checks, and since wave three it pins **fail-over**
as well as the loud arm, the standing answer, the retry budgets and the
surface's own refusals: a question pinned `deep or broad`, a world that raises a
gap at `deep` and answers at `broad`, and four assertions — the run settles on
the spare, the trace names the model that *actually* answered, the fall-back is
narrated on the way, and, with no chain declared, the very same world and
program abandon in exactly the words they always did. That last one is the
acceptance criterion the design states, and it is what makes fail-over
free at every existing call site. Four more pin the executing world: a
`toolExec` act running `true` answers yes and pays for what follows, one
running `false` answers no and does not, two commands at one tool id are two
questions, and a command that cannot be run is a named gap rather than an
answer.

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
agentic.cabal      library (src) + internal library examples (example) + four executables
src/Agentic/Raw.hs      the Raw AST and its JSON codec
src/Agentic/Guards.hs   guardCheck, askCounts
src/Agentic/Text.hs     stringOp, Verdict — the trusted string base
src/Agentic/Plan.hs     the typed Plan and its static folds
src/Agentic/World.hs    WorldSpec, toWorld, trace, the bills, the event JSON
src/Agentic/Builder.hs  the production surface and its elaboration
src/Agentic/WF.hs       the [wf|…|] and [wft|…|] prompt quoters, and what a {hole} may name
src/Agentic/Workflow.hs the authoring surface: handles, questions, the indexed block
src/Agentic/Workflow/Do.hs        W.do — the one block grammar, workflow and revision
src/Agentic/Gen.hs      the generators the bisimulation draws from
src/Agentic/Observe.hs  the reply assembly both runners share
src/Agentic/Oracle.hs   the line-delimited JSON client for the Lean oracle
src/Agentic/Exec.hs     the IO interpreter: the memoizing fold and the decode loop
src/Agentic/AgentDeck.hs  one agent-deck session as an answering service
src/Agentic/Acp.hs      an ACP adapter this process starts, as an answering service
src/Agentic/Cli.hs      the runner as a function of its registry: the four verbs,
                        the flags, the refusals, the usage message
example/Example/Harden.hs the walked examples, written in the authoring surface
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
