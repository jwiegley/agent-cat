# Party→backend routing: the implementable design

*2026-08-19. Written against `agent-cat` at pushed `2f86fda`, reading
`haskell/src/Agentic/{Cli,Exec,Acp,AgentDeck,Chains,World,Shell}.hs`,
`haskell/run/Main.hs`, `agent-workflows/src/Workflows/Parties.hs` — from the
owner's separate, private repository at `~/src/agent-workflows` — and the two
live gates
`haskell/ci/{acp,deck}.sh`. This executes the one open item of
`doc/research/pal-vs-agent-cat.md`: `acat-engine-party-routing-hcx`, "the one
thing PAL can do that agent-cat's runner cannot yet do — reach two different
model backends inside a single run".*

*A note on citations. The task brief located the run header at
`run/Main.hs:590` and `:622`. That file is now twenty-seven lines
(`cliMain examplesRegistry`); the header moved to `src/Agentic/Cli.hs:705`
(deck) and `:736`–`:744` (acp) when the CLI was extracted so that `wf` and
`agentic-run` could share one parser. Every line number below is against the
current tree.*

---

## The ruling, in one page

**The CLI surface.** One repeatable flag, `--route NAME=BACKEND`, on `run`
alone, refining a default route that `--engine acp --adapter …` and
`--session …` already are:

```
agentic-run run confer --engine acp --adapter claude \
    --route 'gpt-5.5-pro=acp:codex' \
    --route 'gemini-3.1-pro-preview=deck:gemini-pane'
```

**The resolution rule.** `NAME` is the **serving model** — the `servedBy` pin
and, independently, each of its `fallingBackTo` alternates — and never the
party. A question is routed by `scopeModelAxis (qScope q)`, the one field the
interpreter already computes, already relabels on fail-over, and already
records in the trace. A question with no model axis — an unpinned model ask, a
tool, a person — takes the default route. A `toolExec` addressee is never
routed at all, because `executingWorld` (`Shell.hs:181`) answers it before any
world beneath it is consulted.

**Why the semantics do not move, in three sentences.** Routing is a `WorldIO`
that dispatches to other `WorldIO`s on a value the interpreter has already
computed, installed at exactly the position `worldOfAcp cfg acp` occupies today
(`Cli.hs:779`), so `runPlanWith`, the memo table, the chain walk, `billFresh`,
`billMemo` and every `EventKey` field — code, addressee, scope, prompt, draw
(`World.hs:392`) — are untouched by construction rather than by argument.
No field of `EventKey` or of `eventJson` (`World.hs:508`) names a backend, so
two runs that differ only in their route table produce byte-identical traces
whenever they produce identical answers. And the frozen corpus cannot observe
the change at all, by the import graph and not by inspection: `tier0`,
`tier1` and `bisim` do not import `Agentic.Exec`, have no `WorldIO`, and decide
conformance against `Agentic.World`'s pure `WorldSpec` through
`Agentic.Observe`'s reply assembly.

**No STOP-AND-REPORT finding.** Nothing in this design moves a frozen reply.
Three sharp edges that *could* have, and where each is closed, are recorded in
§4.3.

**The change list.** One new 200-line module, ~15 lines in `Acp.hs`, ~180
added and ~60 removed in `Cli.hs`, one cabal line, ~90 lines of probe, ~90
lines of `ci/acp.sh`, one new manual gate. `Exec.hs`, `AgentDeck.hs`,
`Workflow.hs`, `Builder.hs`, `Plan.hs`, `World.hs`, `Raw.hs`, `Guards.hs` and
`Chains.hs` are **not touched**. Five landings, §8.

---

## 1. The CLI surface

### 1.1 The flag

```
  agentic-run run  <example> --engine acp [--adapter stub|claude|codex|PATH]
                             [--adapter-arg ARG]... [--scratch DIR]
                             [--route NAME=BACKEND]...
                             [--timeout MS] [--verbose]
  agentic-run run  <example> --session <id> [--binary PATH] [--poll MS]
                             [--route NAME=BACKEND]...
                             [--timeout MS] [--verbose]
```

and in the usage text (`Cli.hs:1024`–`:1083`), after `--scratch`:

```
  --route        NAME=BACKEND — put the questions this run pins to the model
                 NAME to BACKEND instead of to the default answerer.
                 Repeatable, at most once per NAME. BACKEND is
                 acp:stub|claude|codex|PATH (start an adapter of this run's
                 own) or deck:<id> (send to a live agent-deck session).
                 NAME is a *serving model* — a `served by` pin or one of its
                 spares — and not a party: routing the pin is what makes a
                 fail-over ladder cross providers. A pinned model no --route
                 names, every unpinned ask, and every tool and person take
                 the default. Refuses a NAME this program never pins
```

`--route` is **not** a `plan`/`cost` flag. It is execution policy; the static
folds do not read it, would not change if they did, and a price that varied
with a route table would be the first time in this language that who answers
changed what a program costs.

### 1.2 The default route

`--engine acp --adapter X` and `--session S` *become* the default route with no
change in spelling and no change in meaning: today they name the one backend
every question reaches, and after this change they name the backend every
question reaches that no `--route` claims. A command line with no `--route` is
the command line it is today, resolved by the same code path, and its header
prints the same words (§5).

`--route` without a default is refused. Unpinned asks, tools and persons have
nowhere to go:

```
--route refines this run's default answerer, and there is none:
give --engine acp or --session <id> as well
```

### 1.3 The backend grammar

`BACKEND` is `scheme:value`, split on the **first** colon — a `deck:` value may
be a session title containing one, and an `acp:` value may be a path.

| spelling | meaning |
|---|---|
| `acp:stub` / `acp:claude` / `acp:codex` | `adapterArgv` (`Acp.hs:367`), verbatim |
| `acp:/path/to/adapter` | anything else is a path, verbatim `adapterArgv` fallthrough |
| `deck:PANE` | `defaultDeckConfig PANE` |

Nothing new is parsed: `adapterArgv` and `defaultDeckConfig` already turn a
word into a backend, and the route parser is the colon and a lookup. An unknown
scheme is refused naming both:

```
unknown backend 'grpc:x' in --route: a backend is acp:<adapter>
(start an adapter of this run's own) or deck:<id> (send to a live
agent-deck session)
```

**Surrounding whitespace belongs to neither half, and is stripped from both the
`NAME` and the `value` before either is read.** This is a refusal and not a
convenience: no adapter is named `" "` and no session is addressed by a blank, so
a value that is only whitespace is a value the operator did not give. Untrimmed
it is one character rather than none, and `--route 'deep=acp: '` therefore passed
every check above and every refusal of §1.5, printed a header naming an adapter
with no name, **started one**, and was discovered by `posix_spawnp` — after the
spawn the whole of §1.5 exists to happen before. Trimmed, it takes exactly the
refusal `acp:` takes, in the place every other malformed shape is refused.

### 1.4 The knobs a route does not take

`--timeout`, `--verbose`, `--scratch`, `--binary`, `--poll` and `--adapter-arg`
stay **per-run** and apply to every route of the scheme they belong to. Two
reasons, and the second is the operative one:

1. A turn budget is a statement about how long *this run* will wait, not about
   which provider it waited on.
2. **A per-route adapter argument is a two-line wrapper script**, and a flag is
   forever. `adapterArgv` falls through to `[T.unpack name]` for any word it
   does not know, so `--route 'deep=acp:./bin/codex-refusing'` where that file
   is `exec codex-acp --whatever "$@"` buys the whole capability with no
   surface. `--route-arg` is **declined**, and §7 shows the gate that would
   have needed it working without it.

### 1.5 Validation, in the order an operator meets it

All five are usage errors — exit `1`, before an adapter is spawned or a token
is spent, which is the discipline `Cli.hs:356`–`:359` already states for
`--require-pinned`.

| what is wrong | the refusal |
|---|---|
| `--route` under `--scripted` | `--route names live backends and --scripted answers from a table; pick one` (it joins `liveFlags`, `Cli.hs:987`) |
| `--route` with no default | §1.2 |
| `NAME` appears in no `served by` in this program | `--route names the model 'X', which this <noun> never pins; the models it pins are: A, B, C` |
| `NAME` routed twice | `--route names the model 'X' twice; a model has one backend in a run` |
| bad `BACKEND` | §1.3 |

The third is the one worth defending. A route naming a model the program never
pins has configured nothing, and its operator believes otherwise — which is
exactly the failure `chooseTarget`'s existing refusals exist to prevent ("a
flag silently accepted by the transport it means nothing to is a run configured
by a line nobody read", `ci/acp.sh` scenario 12). The check is cheap and exact:
`servedChains (progRawOut prog)` (`Chains.hs:66`) already returns
`Map primary [alternates]` for the whole program, and the set of pinnable names
is its keys plus every alternate. The check runs in `withExample`, beside
`guardUnpinnedAsk`, before the plan and before the spawn.

The converse — a pinned model that **no** `--route` names — is **not** an
error. It takes the default, and the header says so. An exhaustive route table
would make `--route` unusable on any program with more than two pins, and the
whole point of a default is to be the answer for everything unremarkable.

### 1.6 One flag `--route` makes newly meaningful

`chooseTarget` currently forbids a flag by the engine the run *is*
(`Cli.hs:979`–`:987`): `--binary` and `--poll` "are not the acp engine's to
take". With a `deck:` route under an `acp` default, they are. The rule
generalizes to **the set of schemes this run's route table uses**, default
included:

```haskell
schemes :: RunOpts -> Set Scheme        -- the default's, plus every route's
forbid  :: Set Scheme -> [(Text, Bool)] -> Either Text ()
```

At an empty route table `schemes` is the singleton of the default's scheme and
the predicate is the one that exists today, refusal wording included. That is
the acceptance test for the generalization: `ci/acp.sh` scenario 12 must stay
green **unedited**.

---

## 2. Resolution: which name is routed

### 2.1 The two namespaces, as the tree already separates them

`agent-workflows/src/Workflows/Parties.hs` is the argument, written down before
this design existed:

```haskell
-- The serving models: Text, not parties.
gpt5Pro = "gpt-5.5-pro"
gemini  = "gemini-3.1-pro-preview"

-- The ladder.
reasoning p = p `servedBy` opus   `fallingBackTo` gpt5Pro `fallingBackTo` fable
broad     p = p `servedBy` fable  `fallingBackTo` gemini  `fallingBackTo` opus
lateral   p = p `servedBy` gemini `fallingBackTo` gpt5Pro `fallingBackTo` opus

-- The parties.
haskellPro = broad (model "haskell-pro")
```

Its own words: *"a serving model is what answers **for** an addressee, and the
addressee is the role"*. In the runtime these land in two different fields of
the same question: the party becomes `AddrModel "haskell-pro"` in
`qAddressee`, and the pin becomes `Just "fable"` in
`scopeModelAxis (qScope q)`.

### 2.2 The rule

> **A question is routed by its model axis. `Nothing` takes the default.**

```haskell
backendFor :: Routes b -> Q c -> b
backendFor rs q = case scopeModelAxis (qScope q) of
  Just m  -> Map.findWithDefault (routeDefault rs) m (routeByModel rs)
  Nothing -> routeDefault rs
```

Four arguments, in descending order of force.

**It is the only rule under which a fail-over ladder can cross providers, which
is the entire capability.** `askOrMemo` walks `candidates` (`Exec.hs:470`),
which relabels the model axis and leaves everything else alone:

```haskell
[ q {qScope = (qScope q) {scopeModelAxis = Just x}} | x <- … ]
```

`broad` is `fable`, then `gemini`, then `opus`. Route the pin and one party's
ladder reaches three backends in the order the program wrote, with **no change
to `Exec.hs`** — the relabelled question is routed by its new label the next
time round the loop. Route the *party* and `haskell-pro`'s three rungs all land
on one backend, which is the case that made the ladder worth writing.

**The pin already has exactly one meaning per run, and the party does not.**
`Agentic.Chains`' documented precondition is that *"the chain is a property of
the model, not of the question"* — a program may not say `deep or broad` here
and `deep or cheap` there, and `agentic-run` refuses to start on a table that
does (`Chains.hs:70`–`:86`). A route table keyed on the same names inherits
that coherence for free. Party names are per-program and per-role; two programs
in one registry may both have a `reviewer`.

**Attribution needs no new field.** The trace records the model axis of
whoever actually answered (`World.hs:513`, and `Exec.hs:327`–`:336` on why that
may differ from a frozen trace). Route on that axis and *route table + trace =
which backend answered*, totally and after the fact, with the route table
printed in the header (§5). Route on the party and the trace says nothing about
which backend answered a party whose pin fell over.

**It makes `--require-pinned` the honest precondition it already claims to be.**
`guardUnpinnedAsk` refuses a program that leaves a model ask without a `served
by`, so that no question "quietly reach[es] whatever model the transport
happened to have" (`Guards.hs:397`). Under this rule, `--route` is exactly the
promotion of that guarantee from *which model* to *which machine*: a run under
`--require-pinned` has every model question routed by name, and only tools and
persons take the default.

### 2.3 The alternates are routed, each on its own

An alternate is a model name, so it is routed like any other. `--route` may
name a primary, a spare, both, or neither; there is one namespace and one
table. This falls out of §2.2 and is worth stating only because it is the
answer to "what does a fail-over across backends *mean*": it means the
`n`-th rung of a ladder was served by a different process than the `n−1`-th,
and nothing else. No new concept.

### 2.4 What a cross-backend fail-over records

Exactly what a same-backend fail-over records today, and the reason it is
exactly that is the reason routing is safe:

| where | what it says |
|---|---|
| the trace | one `Event` at the answering rung's `scope.model`, memoized under **the answerer's** `questionKey` (`Exec.hs:371`–`:373`) — never the primary's |
| `stderr` | `"fable: <why>; falling back to gemini"` (`Exec.hs:438`) — unchanged wording; the backend is not named because the header already said which backend `gemini` is |
| the failed attempt | **nothing, anywhere**. "An `Event` carries an answer and a failed attempt has none, so the trace records the dialogue and `stderr` records the attempts" (`Exec.hs:334`) |
| `billFresh` | unchanged by construction — one event per ask node walked |
| `billMemo` | unchanged in the ordinary fail-over; rises only where one node was answered by different models at different times, which by `EventKey`'s own definition is two questions |

### 2.5 The hard constraint this rule buys, stated as a prohibition

> **There is no backend-level fail-over. Only model-level.**

A route is a **total, deterministic function of the pin, fixed for the run**. It
may not vary by attempt, by clock, by liveness probe, or by anything else.

The reason is the memo table. If one pin could be tried at two backends, the
same question — same code, same addressee, same scope, same prompt, same draw,
hence the same `EventKey` — would be put twice to two different processes. The
first answer is inserted; the second is a consultation the table cannot
distinguish from the first and the bill cannot see. That is the memo invariant
broken, and it is the one thing in this design that *would* have been a
stop-and-report. It is closed by construction: cross-provider recovery goes
through the pin ladder, which relabels the key, and there is nowhere else for
it to go.

The corollary an implementer must not miss: **a route whose backend is dead is
a dead question**, not a question that silently tries elsewhere. It raises the
gap its transport raises, `budgetedRecovery` prices it, and `askOrMemo` walks
the *model* chain. If the author wanted a spare they wrote one.

---

## 3. Lifecycle: several adapters, one run

### 3.1 Backends are deduplicated by spec

Two pins routed to `acp:codex` share **one** adapter. They are the same
provider; two processes would double nothing, and the header would lie about
how many agents this run started.

**This is safe today for a reason that is a constraint on tomorrow.**
`acpFreshPerQuestion` is `True` in `defaultAcpConfig` (`Acp.hs:330`) and
`chooseTarget` never overrides it (`Cli.hs:1014`–`:1018` set only
`acpTurnTimeoutMs` and `acpVerbose`), so every question opens its own session
and two pins sharing an adapter never share a conversation. **Any future flag
that exposes `acpFreshPerQuestion = False` must either disable this dedup or
key sessions by pin**, or two pins would silently share context — not a frozen-
reply change, but a real one, and exactly the kind that is discovered late.

### 3.2 Startup order

**The default first, then the named routes in the order they were typed.**

Default first because every run needs it, so a run whose default will not start
fails before spawning anything else. Typed order because the operator can then
read the header against their own command line — which means `RunOpts` carries
`roRoutes :: ![Text]` (a list, order preserved, as `roAdapterArgs` already
does at `Cli.hs:902`) and `Routes` keeps an ordered list for display beside the
`Map` for lookup.

Startup is **eager**: every routed backend is connected before the first
question. Two reasons.

1. **The header must be true before the first question is put.** A header that
   promised three backends and then failed to start the third mid-run would
   have been a false statement at the moment it was read.
2. **It costs nothing.** `connectAcp` spawns, shakes hands and opens a session
   (`Acp.hs:841`–`:844`); `session/new` carries no prompt and spends no tokens.
   An adapter a branch never reaches costs one process and one handshake. A
   `deck:` route costs strictly less — `worldOfDeck` holds no connection at all,
   only a `DeckConfig`, and every command is a fresh `agent-deck` invocation.

The failure mode is therefore the right one: a mistyped adapter path fails at
exit `2` with `AcpAdapterMissing` naming the program and the pin it was routed
for, with nothing spent.

### 3.3 The bracket, and shutdown on error

No new machinery. `withAcp` is `bracket (connectAcp cfg) closeAcp`
(`Acp.hs:798`), and several of them is a fold:

```haskell
-- | Every adapter live for the duration of @k@, closed on every exit path.
-- A failure to start the n-th closes the n−1 already open, because each is
-- inside the previous one's bracket.
withAcps :: [(k, AcpConfig)] -> ([(k, Acp)] -> IO a) -> IO a
withAcps [] k = k []
withAcps ((n, c) : rest) k =
  withAcp c $ \a -> withAcps rest (k . ((n, a) :))
```

Nesting gives the three properties for free: LIFO shutdown, a mid-run exception
unwinding every adapter, and a failed connect closing everything already
connected. `closeAcp` is already best-effort and swallows its own failures
(`Acp.hs:866`–`:873`) precisely so that a second error cannot hide the first —
which matters more with four adapters than with one.

### 3.4 Scratch directories: one, shared

**One run directory. Every ACP route gets it as its `acpCwd`; `executingWorld`
gets it as its `shellCwd`. `--scratch` stays one flag.**

This preserves today's invariant exactly rather than generalizing it. Today the
run has one directory, it is the adapter's `cwd`, it is where
`permissionByCode` authorizes writes, and it is where a `running` tool's
command runs (`Cli.hs:720`–`:722`, `:744`, `:752`–`:758`). Per-backend
directories would break something real: a `toolExec` gate checks a build that
some *other* party's act produced, and a gate that ran in a directory the act
did not write to is a gate that always passes.

The obvious objection — concurrent writes from several adapters — does not
arise. `execIn` is a sequential fold (`Exec.hs:345`–`:356`); there is never
more than one turn in flight in a run. Worth stating out loud, because the
objection is the first thing a reviewer will raise and the answer is
structural.

### 3.5 The permission axis needs no routing

`permissionByCode :: Code -> Addressee -> Permission` (`Acp.hs:658`) is a pure
function of the question, holding no connection state: an `ack` is granted, and
everything else is cancelled. It is therefore uniform across backends by
construction, and `sayAcp` sets it per question on the connection it is about to
prompt (`Acp.hs:1237`). Four adapters, four `acpAsked` refs, one policy. Nothing
to design and nothing to configure — and this is the design's own argument for
`permissionByCode` being a function of the code rather than "a field of the
connection", which its haddock made two waves before there were two connections.

### 3.6 Gap budgets: `esRetry*` stays per-run

`esRetryUndecodable`, `esRetryTransportRefusal` and `esRetryEmptyOrProtocol`
(`Exec.hs:986`–`:995`) remain **one budget for the run**. Three observations:

1. **`gapBudget` prices a gap kind, not a provider.** "Could not read a flag
   from this reply" costs the same re-ask whoever produced it, and the
   provider-shaped answer to a provider-shaped failure is already the model
   ladder.
2. **Per-route budgets are already structurally free, and deliberately
   unexposed.** `worldOfAcpWith :: ExecSettings -> …` and `worldOfDeckWith ::
   ExecSettings -> …` each close over their own settings
   (`Acp.hs:1206`, `AgentDeck.hs:467`), and routing builds one `WorldIO` per
   backend — so per-route settings would be a change of *argument*, not of
   structure.
3. **There is no per-run surface for them either.** Nothing under `ci/` builds
   an `ExecSettings` other than `defaultExecSettings`, and the CLI has no flag
   for any of the three. Inventing a per-*route* spelling for a knob with no
   per-*run* spelling would be designing the second storey of an unbuilt house.

So: when a `--retry-undecodable N` flag is wanted, it lands per-run; if it is
ever wanted per-route, `--retry-undecodable NAME:N` reaches the seam that
already exists, and `Exec.hs` is still not touched.

---

## 4. Attribution: the semantics are untouched

### 4.1 Where routing sits

`runCmd`'s composition today (`Cli.hs:779`, and `:678`–`:683` on why it is
composed there and nowhere else):

```haskell
announcingWorld (say . ("  " <>)) (executingWorld (shellAt dir) (worldOfAcp cfg acp))
```

and after:

```haskell
announcingWorld (say . ("  " <>)) (executingWorld (shellAt dir) (routedWorld backends))
```

The whole runtime of this feature is one function:

```haskell
-- | Dispatch each question to the backend its model axis names.
routedWorld :: Routes WorldIO -> WorldIO
routedWorld rs = WorldIO $ \c q -> worldAskIO (backendFor rs q) c q
```

`WorldIO` is `forall c. SCode c -> Q c -> IO (El c)` (`Exec.hs:208`). A
`routedWorld` is a `WorldIO` built from `WorldIO`s; it can answer or fail, and
— exactly as `Exec.hs:876`–`:883` requires of any answerer — it cannot name
who it was, cannot forge an event and cannot delete one. **Routing is
substitution at the same type.** That is the argument in full.

Three consequences follow from the position rather than from care:

- **`toolExec` is never routed.** `executingWorld` intercepts `AddrToolExec`
  before consulting the world beneath it (`Shell.hs:182`–`:184`), so a
  program-authored command reaches no backend at all. D5's guarantee — that a
  gate is an exit code rather than a model's claim about one — is unaffected by
  which providers the run reached.
- **Announcement is unchanged.** `announcingWorld` is outermost, prints one
  line per consultation, and a memo hit prints nothing (`Exec.hs:227`–`:232`).
  Routing changes neither the count nor the wording.
- **The chain walk is above routing, not beside it.** `askOrMemo` computes the
  candidate sequence as a pure function of the question and the chain table
  (`Exec.hs:393`), consults the memo, and only then calls `worldAskIO`. Routing
  is what happens *inside* that call.

### 4.2 Nothing that identifies a run's answer names a backend

| structure | fields | mentions a backend? |
|---|---|---|
| `EventKey` (`World.hs:392`) | code, addressee, scope, prompt, draw | no |
| `Event` (`World.hs:318`) | the above, plus the answer | no |
| `eventJson` (`World.hs:508`) | `code`, `addressee`, `scope`, `prompt`, `draw`, `answer` | no |
| `scopeJson` (`World.hs:490`) | `model`, `mode`, both always present | no |
| `billFresh` / `billMemo` (`World.hs:436`, `:456`) | length; distinct `EventKey`s | no |

Two runs of one program that differ only in their route table and that produce
identical answers produce **byte-identical traces and identical bills**. There
is no field in which they could differ.

### 4.3 Three edges that could have moved a frozen reply, and where each closes

**The corpus cannot reach the change, by the import graph.** `tier0`, `tier1`
and `bisim` do not import `Agentic.Exec` — grep the tree: its importers are
`Cli`, `Acp`, `AgentDeck`, `Chains`, `Shell`, `Text` and the two example
libraries, and nothing under `tier0/`, `tier1/` or `bisim/`. The conformance
executables have no `WorldIO`, no interpreter and no transport; they decide
against `Agentic.World`'s pure `WorldSpec` through `Agentic.Observe`'s reply
assembly. A change confined to `WorldIO` is not merely *unlikely* to move a
frozen reply — it is unreachable from the code that decides one.

**A backend-level retry would have broken the memo invariant.** Closed by
§2.5's prohibition, which is why that prohibition is stated as a rule of the
design rather than left as an implementation detail.

**Deduplicating adapters could have shared conversation context.** Closed
today by `acpFreshPerQuestion = True` being the CLI's only setting (§3.1), and
recorded there as a constraint on the flag that would change it.

### 4.4 Where backend attribution *does* live

Not in the trace, and it should not be. The trace records who answered; the
header records which machine each name is (§5); the stderr narration records
the attempts. Composing header and trace recovers the backend for every event,
totally — and the composition is the operator's, deliberately, because putting
the backend in the trace would put execution policy into a structure the
frozen corpus compares by equality.

---

## 5. Header honesty

The line that must stop being printed when it stops being true is
`Cli.hs:743`:

> `; every addressee — model, tool and person — is this one adapter`

and its deck twin at `:711`.

### 5.1 One backend: unchanged, because it is still true

A run with no `--route` prints today's header **verbatim**, including that
clause. The sentence is not a lie when there is one backend; it is a lie when
there are two. This is not a compatibility hedge, it is the honest reading —
and it has a useful side effect: `ci/acp.sh` and `ci/deck.sh` stay green
without a single edited assertion, which is what makes step 3 of §8 a refactor
rather than a rewrite.

### 5.2 Two or more: a table, and a stated remainder

```
running confer against 3 backends:
  default                 the claude adapter: claude-agent-acp
                          — every unpinned ask, every tool and every person
  gpt-5.5-pro             the codex adapter: codex-acp
  gemini-3.1-pro-preview  agent-deck session gemini-pane
  fable, opus             the default (no --route names them)
  cwd /tmp/agentic-run-1234, 900000ms to a turn, a new session per question
  a `running` tool's command runs in /tmp/agentic-run-1234
  fable may be answered instead by gemini, opus — a fail-over is narrated on
  stderr, and the trace records who answered
```

Six requirements on it, each earned:

1. **Count the backends, deduplicated** (§3.1) — the count is processes, not
   route lines, or the header overstates what was started.
2. **Name the default first, and say what falls to it** — because the
   remainder is the part an operator cannot compute from the flag list.
3. **Print the pinned models this program has that no `--route` claims**, on
   their own line. `servedChains` already has that set in hand for the §1.5
   check, so this costs a `Map.difference`. Without it, a mistyped route reads
   as an absent one.
4. **Keep the working-directory lines** (`Cli.hs:744`) — one directory, shared,
   and the sentence is unchanged because the fact is.
5. **Keep the chain lines** (`Cli.hs:784`–`:789`) — a ladder that now crosses
   providers is more worth printing, not less, and the existing wording
   ("the trace records who answered") remains exactly true.
6. **Never claim a backend answered anything.** The header states policy before
   the run; only the trace states outcome.

### 5.3 The deck arm's directory caveat generalizes

`Cli.hs:715`–`:717` says a `running` tool's command runs in this process's
directory, which the deck session "need not share". With a mixed route table
that caveat holds for the `deck:` routes and not for the `acp:` ones. Print it
**once, per route**, on the route's own line — `— its working directory is its
own; this run's tools run in <dir>` — rather than as a run-wide sentence that
would be false of the ACP routes.

---

## 6. Scripted mode: unchanged, and confirmed from the code

`--scripted` is unaffected, and here is the verification rather than the
assumption.

**The scripted world does not read the scope.** `scriptedReply`
(`Exec.hs:1335`) is:

```haskell
scriptedReply table c q =
  fromMaybe (scriptedDefault c q) (snd <$> find (\e -> fst e `T.isPrefixOf` qPrompt q) table)
```

It reads `qPrompt` and nothing else — not `qScope`, not `qAddressee`. Since
routing dispatches on `scopeModelAxis (qScope q)` and the scripted world is
blind to it, a route table could not change a scripted answer even if one were
permitted. `scriptedDefault` (`Exec.hs:1350`) reads `qPrompt` at `SText` and
ignores the question entirely at the other three codes.

**The scripted arm builds no executing layer.** `runCmd`'s `Scripted` arm is
`walkWith id (scriptedWorld script)` (`Cli.hs:703`) — `id`, not
`executingWorld` — which is that mode's defining property and the reason it
owes the operator the line at `:700`–`:702` saying no command was run.

**The scripted arm does build a chain table**, because `walkWith`
(`Cli.hs:766`) runs `servedChains` for every target. It never fires:
`scriptedWorldWith` raises no `TurnGapError` — the only failure it can produce
is decode exhaustion at `defaultExecSettings`, whose recovery answers `FailOver`
only after the budget is spent, at which point `askOrMemo` finds a candidate
list it never left. This is worth knowing because it means the §1.5 refusal
(`--route` under `--scripted`) is a *usability* refusal and not a correctness
one: routes would be inert, and a flag that is silently inert is the defect
`chooseTarget` exists to prevent.

**Conclusion.** `--scripted` joins `liveFlags` for `--route` and needs no other
change. Scripted answers are engine-independent *and* route-independent, and
the second follows from the first because a route is only ever a choice among
engines.

---

## 7. The test plan

### 7.1 `test/PolicyProbe.hs` — the pure half (+~90 lines)

A fifth section, in the shape of the four that exist. Everything here is pure
or uses `pureWorldIO`; no process, no network, no Lean, no corpus — so it runs
on every commit in `ci/policies.sh` beside the rest.

| probe | asserts |
|---|---|
| `parseBackend` | the three `acp:` spellings, `deck:`, first-colon split on a value containing a colon, and the unknown-scheme refusal **wording** |
| `parseRoute` | `NAME=BACKEND` splits on the first `=`; a missing `=` refuses with the shape in the message |
| `backendFor`, pinned | a question at `scope.model = Just "gemini"` picks `gemini`'s backend |
| `backendFor`, unrouted pin | a question at `Just "fable"` with no `fable` route picks the default |
| `backendFor`, unpinned | `scopeModelAxis = Nothing` picks the default — one probe each for `AddrModel`, `AddrTool`, `AddrPerson` |
| **routing is invisible to the fold** | run `hardenProgram` twice through `routedWorld` over a route table whose every backend is `pureWorldIO w` for the *same* `w`, once with an empty table and once with three routes; assert **the two traces are equal**, event for event, and both bills agree. This is §4.2 made executable |
| **routing does not intercept `toolExec`** | `executingWorld sh (routedWorld rs)` where every routed backend raises on being consulted; a `toolExec` program settles, proving no question reached routing |
| **cross-backend fail-over** | extend the existing D6 fail-over probe: `deep or broad`, two *distinct* worlds, `deep`'s raising a gap and `broad`'s answering. Assert the run settles, the trace names `broad`, the narration is the existing wording, and — the acceptance criterion — **with no alternates declared the same two worlds abandon in exactly the words they always did** |

The last one is the probe that proves the capability without a process: two
`WorldIO`s *are* two backends as far as `routedWorld` is concerned.

**Two of these are weaker than they read, and shipped stronger.** Behind one
shared `w`, the invisibility probe's two traces are equal *however* the questions
were dispatched — including by a dispatcher that ignored the table — and a
program whose every question is a command never reaches routing at all, so
neither probe as tabled above can catch a wrong dispatcher. As shipped, the
invisibility probe's four backends are **distinct worlds that answer alike**,
each noting that it was consulted, so the same rows also say where the questions
went; and the `toolExec` probe is two commands around a **pinned ask**, at a
table whose default raises and whose one route answers, so a command that reached
routing and an ask that reached the default fail in two different places. The
shipped section also gains three probes this table does not name: that
surrounding whitespace is part of neither half of a route — `acp: ` is a blank
adapter, and untrimmed it survived every refusal and was found out by
`posix_spawnp` *after* a spawn — that `routeBackends` is the distinct backends
with the default first, and that connecting the table with `fmap` moves no
question. Eleven probes in total; the gate's stated count is thirty.

### 7.2 `test/SurfaceRefusals.hs` — **nothing**, and that is the right answer

`SurfaceRefusals` holds programs the *authoring surface* refuses to make — four
bottoms whose `ErrorCall` wording `PolicyProbe` forces, because "a refusal has
no corpus entry to be pinned against". A route is not something an author
writes. It is not in `Agentic.Workflow`, it has no `Program`, and there is
nothing for the surface to refuse. Every route refusal is a **CLI** refusal at
exit `1`, and the place those are pinned is `ci/acp.sh` scenario 12's own lane.
Adding a route case to `SurfaceRefusals` would be putting a command-line
mistake in the file that holds program mistakes.

### 7.3 `ci/acp.sh` — the ci lane (+~90 lines, three scenarios)

The gate runs against `test/stub_adapter.py` and never against a real agent
(its own header says so), and the route lane keeps that rule. Two routed
backends, both stubs, distinguished by **outcome** rather than by a flag —
which is §1.4's claim, discharged.

**The flagship is already the fixture this needs, and no new one is owed.**
`harden` (`Example/Harden.hs:157`–`:171`) contains, in this order:

| ask | routed by |
|---|---|
| `tool "cat"` — the style guide | **default** (no model axis) |
| `model "author" \`servedBy\` "deep"` — the draft, and later the amendment | **`deep`'s route** |
| `model "reviewer-correct"`, `model "reviewer-secure"` — the panel | **default** (deliberately unpinned: Isaac's I5, "the absence of a pin is the absence of the words", so the two lenses stay comparable) |
| `person "owner"`, `tool "apply"` | **default** |

One distinct pin, three unpinned model asks, a tool, a person and an act — the
`Just` case and the `Nothing` case of §2.2 in one program, with the tool
question asked *before* the routed one so that ordering is observable.

**Scenario 13 — two adapters, and each question went to the right one.**
Default is the plain stub; `--route 'deep=acp:$state/bin/stub-writing'`, where
that wrapper is two lines:

```sh
#!/bin/sh
exec python3 "$STUB" --write-on-ask "$@"
```

`--write-on-ask` is the measured defect `ci/acp.sh` scenario 4 already pins: the
adapter asks permission to rewrite `parse.c` *during a turn that was only asked
a question*, and `permissionByCode` denies it. So the routed stub announces
itself, by denial, on exactly the questions it answered. Assert:

- `want_line "permission DENIED  to 'edit parse.c while answering' during the text question put to model author"` — the routed adapter answered the author;
- `want_no_line "during the text question put to model reviewer-correct"` — the
  **unpinned** reviewers went to the default, which never asks to write;
- `want_no_file parse.c` and `want_file applied.c` — the denial held and the act
  still ran, on the default adapter, in the one shared directory (§3.4);
- `want_bills 7 7` — identical to scenario 1, because routing changes no bill;
- the header names **2 backends**, with `deep` on its own line and
  `— every unpinned ask, every tool and every person` on the default's.

That pair of `want_line`/`want_no_line` assertions is the resolution rule
(§2.2) proved end-to-end in the flagship: one program, two processes, dispatch
by pin, with no new fixture, no new flag and no edited assertion elsewhere.

**Scenario 14 — a route to a dead adapter fails before anything is spent.**
Route `deep` to `/usr/bin/false`, default to the stub. Assert exit `2`,
`closed its output while the initialize handshake was outstanding`, the pin
`deep` named in the message, and `want_no_line billFresh`. This is the scenario
that pins eager startup (§3.2): under lazy startup the same command line would
answer the `cat` question first and *then* fail, so `billFresh` would appear.
Asserting its absence is asserting the startup order.

**Scenario 15 — the four usage refusals, none of which spawns anything.**
`--route` with `--scripted`; `--route` with no default; `--route` naming a
model the program never pins; `--route` naming one model twice. All `exit 1`,
all `want_no_line billFresh`, each asserted on its wording — the same shape as
scenario 12, which must itself stay green **unedited** (§1.6).

Scenario count in the summary line moves `12` → `15`.

### 7.4 `ci/route-live.sh` — the live smoke (NEW, ~80 lines, manual only)

The proof the whole track exists for: **the claude adapter and the codex
adapter answering different parties of one program.** Not in any automatic
lane — it spends real money on real accounts, which is the same reason
`ci/tier1.sh` is nightly and fails loudly rather than degrading when its
prerequisite is absent.

**It needs no new program.** The flagship is the smoke, for the same reason it
is the ci fixture (§7.3): one pin, three unpinned model asks:

```
agentic-run run harden --engine acp --adapter claude --route 'deep=acp:codex'
```

Codex drafts the patch and writes the amendment; Claude reviews it three ways,
asks the owner, and applies it. One program, two providers, one bill — which is
the sentence `doc/research/pal-vs-agent-cat.md` says the runner cannot yet
produce.

Assertions, in the order they discriminate:

1. the header names **2 backends**, one `claude-agent-acp` and one `codex-acp`,
   with `deep` on the codex line;
2. two adapter processes exist during the run and **none after it** — the
   `pgrep` check `ci/acp.sh` scenario 11 already uses, at the bracket instead of
   at the timeout;
3. **the flagship's frozen numbers, unchanged on whichever branch the owner
   chose**, which is §4.2 observed on the real wire rather than argued — see the
   grading note below;
4. the announced consultations name the parties, and the draft is visibly a
   different voice from the reviews — the only assertion here a single-backend
   run could not also satisfy;
5. exit `0`.

**How assertion 3 is graded, and why it is not `7/7`.** The flagship ends by
asking a **person** whether to apply the patch, and in a live run that person is
a real one behind a real adapter. Both answers are correct: *yes* is seven
consultations and a written `applied.c` in the one shared directory both
providers were pointed at (§3.4); *no* is six and nothing written — `ci/acp.sh`
scenario 2 pins that branch as right behaviour and `Harden.bill_refuse_demo` is
the theorem it comes from. Nothing this script controls decides which comes back.
So the assertion is that the run landed **squarely on one branch** — `7/7` with
`applied.c`, or `6/6` without it, and never a mixture — and an earlier draft of
this list, which asked for `7/7` and a written `applied.c` as two separate
assertions, would have failed a well-behaved *no*.

Two negative controls it buys for free:

- the same command with `--route` removed reaches `claude` for everything —
  today's behaviour, today's header, today's bills;
- `--route 'author=acp:codex'` is **refused** at exit `1`, because `author` is a
  party and not a pin (§1.5's third refusal). That is the resolution rule
  defended at the command line, where an operator will actually make the
  mistake.

When the **confer** workflow lands (§8.3), it becomes the second smoke — a
roster whose `reasoning` / `broad` / `lateral` rungs pin `opus`, `fable`,
`gpt-5.5-pro` and `gemini-3.1-pro-preview`, which is a four-backend route table
and the direct replacement for a PAL `consensus` call. It is a better
demonstration and a worse *test*, because its bills are not frozen anywhere;
`harden` stays the smoke that can be held to a number.

### 7.5 What no gate covers, said out loud

`ci/policies.sh` already records that nothing under `ci/` builds an
`ExecSettings` other than the default. This design adds no `ExecSettings`
surface (§3.6), so that gap neither widens nor closes. The route lane covers
process lifecycle, dispatch and refusals; it does not cover two *different
providers*' behaviour, which only §7.4 can, and which is manual on purpose.

---

## 8. The change list

Files, sizes, and the order to land them.

### 8.1 The files

| file | change | ± lines |
|---|---|---|
| `haskell/src/Agentic/Route.hs` | **new.** `Backend`, `Routes`, `parseBackend`, `parseRoute`, `backendFor`, `routedWorld`, dedup. Mostly haddock; the executable part is ~50 lines | +200 |
| `haskell/src/Agentic/Acp.hs` | `withAcps`, a fold of `withAcp`, beside it and exported (§3.3) | +15 |
| `haskell/src/Agentic/Cli.hs` | `Target` becomes `Scripted \| Routed Routes`; `runCmd`'s three arms become two; `RunOpts` gains `roRoutes`; `chooseTarget` gains §1.5 and generalizes `forbid` per §1.6; the header becomes a function of `Routes` (§5); usage gains `--route` | +180 / −60 |
| `haskell/agentic.cabal` | `Agentic.Route` in the library's `exposed-modules` | +1 |
| `haskell/test/PolicyProbe.hs` | §7.1's fifth section | +90 |
| `haskell/test/SurfaceRefusals.hs` | **none** (§7.2) | 0 |
| `haskell/ci/acp.sh` | §7.3's scenarios 13–15; summary count 12→15 | +90 |
| `haskell/ci/policies.sh` | check count in the header comment | +2 / −2 |
| `haskell/ci/route-live.sh` | **new**, manual (§7.4) | +80 |
| `haskell/agentic.cabal` description | one paragraph, in the style of the existing week-by-week narrative | +12 |

**Not touched, and this is the design's headline:** `Exec.hs`, `AgentDeck.hs`,
`Workflow.hs`, `Workflow/Do.hs`, `Builder.hs`, `Plan.hs`, `World.hs`, `Raw.hs`,
`Guards.hs`, `Chains.hs`, `Shell.hs`, `Observe.hs`, `Text.hs`, `WF.hs`,
`run/Main.hs`, `tier0/`, `tier1/`, `bisim/`, the corpus, and every Lean file.

### 8.2 The order

**1. `Agentic.Route`, alone.** The module, its cabal line, and §7.1's pure
probes for `parseBackend`, `parseRoute` and `backendFor`. Nothing imports it;
no behaviour changes anywhere. Green everywhere by construction. *This landing
is where the resolution rule (§2) gets reviewed, before any wiring exists to
argue about.*

**2. `withAcps` in `Acp.hs`.** Fifteen lines, unused, `-Wall`-clean because it
is exported. Green.

**3. `Cli.hs`: the `Routed` refactor at an empty route table.** Today's
behaviour expressed in the new shape — `--engine acp --adapter X` builds
`Routed (Routes (BackendAcp …) [])`, the single-backend header prints today's
words verbatim (§5.1), `forbid`'s generalization is the identity at one scheme
(§1.6). **No new flag.** *The acceptance test is that `ci/acp.sh` and
`ci/deck.sh` pass with not one assertion edited* — which is the same acceptance
test `Cli.hs`'s own header states for its extraction from `run/Main.hs`, and
the reason this step is safe to make the risky one.

**4. `Cli.hs`: `--route`.** Parsing, §1.5's five refusals, the multi-backend
header (§5.2), `withAcps` wired, `routedWorld` installed. `ci/acp.sh` gains
scenarios 13–15; `PolicyProbe` gains the fold-invisibility, toolExec and
cross-backend fail-over probes. **This is the landing that closes
`acat-engine-party-routing-hcx`.**

**5. `ci/route-live.sh` and the cabal narrative paragraph.** The manual gate,
run once by hand, its transcript pasted into the issue as the evidence that two
providers answered one program.

### 8.3 What lands next, and is not this

The **confer** workflow — roster of parties, stance rubrics, verdict fold,
synthesis — is the other half of PAL subsumption and belongs in
`agent-workflows/src/Workflows/`, not here. It is single-backend-runnable the
day it is
written and cross-backend the day step 4 lands, and `Workflows.Parties`'
`reasoning` / `broad` / `lateral` ladders are already the roster it will draw
from. Nothing in this design is blocked on it, and it is not blocked on this
design.

And, as the owner has ruled: **PAL MCP stays configured.** Nothing here removes
it, migrates off it, or edits a line of its configuration. What this buys is the
option — a run that reaches three providers, priced before it starts, traced
after it ends, and held to a semantics the corpus decides.
