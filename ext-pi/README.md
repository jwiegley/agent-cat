# ext-pi

`ext-pi` is a Pi extension that makes Pi the control plane for agent-cat
workflows. agent-cat remains the only workflow interpreter. The extension reads
the trusted runner executables that its configuration names, and it gathers
inputs and launches the runner in machine mode. It reduces the event stream of
the runner into a live monitor, delivers controls, and keeps durable references
to runs. It never searches the file system or `PATH` for a runner.

## Boundary

Pi loads `src/index.ts`, which registers the `/wf` command, the
`/wf-...` commands, and the `agent_cat_workflow` tool. The extension
imports no Haskell code and never interprets a `RawProgram` or a `Plan`. It
speaks three versioned process protocols of `agentic-run`: the descriptor that
`list --json` publishes (version 3, while versions 1 and 2 remain accepted), the
machine event stream (protocol version 2 when advertised, with version 1 retained
for older runners), and the correlated control channel. Descriptor v3 advertises
sanitized routing inspection and protocol negotiation; v2 completion carries a
verified private result reference.
In service mode only, the extension also communicates with the agent-cat
manager through the versioned `/v1` HTTP protocol, as the section "Manager
client" states.
The CLI and runtime own scheduling, persistence semantics, effects, and engine
behavior; the extension owns trusted
discovery, approval, supervision, the user interface, retention, and durable
run references.

## Supported host

The supported host is the built Pi fork at `~/src/fork/pi`, commit `7857926ee`.
The directory `node_modules/@earendil-works` holds one symbolic link for each
host package, and each link points into `~/src/fork/pi/packages`. The linked
packages are these, each at version 0.99.1:

| Package | Fork directory |
|---|---|
| `@earendil-works/chord` | `packages/chord` |
| `@earendil-works/pi-ai` | `packages/ai` |
| `@earendil-works/pi-client` | `packages/client` |
| `@earendil-works/pi-coding-agent` | `packages/coding-agent` |
| `@earendil-works/pi-protocol` | `packages/protocol` |
| `@earendil-works/pi-server` | `packages/server` |
| `@earendil-works/pi-telemetry` | `packages/telemetry` |
| `@earendil-works/pi-tui` | `packages/tui` |

`@earendil-works/pi-agent-core` 0.99.1 is not linked. It resolves from
`pi-coding-agent` through the `node_modules` directory at the root of the fork,
to `packages/agent`. The supported toolchain is Node 22.23.3, TypeScript 5.9.3,
and vitest 4.1.9.

The links are never replaced by a registry install. The `devDependencies` pins
of `package.json` and `package-lock.json` name older registry versions. They
differ from the supported set, and they are not used to install the host.
`test/host-versions.test.ts` enumerates every linked package, resolves it and
`pi-agent-core` through the Node resolver, and fails when a version is outside
the supported set, a linked package is not listed, or a listed package is
missing.

agent-cat owns `ext-pi` and its manager client. The Pi owner owns the host. The
fork is built for this extension and is not edited by agent-cat work.

## Manager client

`src/manager/` holds the TypeScript manager client. It states the behavior of
the Haskell client modules `Agentic.Manager.Client.Events`,
`Agentic.Manager.Client.Failure` and `Agentic.Manager.Client.Refresh`, of the
shared protocol codecs `Agentic.Manager.Protocol.Draft`,
`Agentic.Manager.Protocol.Preparation` and `Agentic.Manager.Protocol.Command`,
and of the service parsers of `Agentic.Tui.Service`. It imports no Haskell
code. `src/manager/profile.ts` and `src/manager/transport.ts` load a client
profile and perform the HTTPS requests of one session, and
`src/manager/session.ts` holds that session. The other modules perform no
I/O and hold no session.

`src/manager/json.ts` parses JSON text without loss. `parseJson` uses the
source text that `JSON.parse` of Node 22 gives to a reviver, and it keeps the
text of each number in a `JsonNumber`. Thus `123456789012345678901234567890`,
`1e400` and integers above 2^53 keep their exact value. `encodeJson` writes
compact JSON text. It writes the members of each object in code-unit order of
their names, and it writes each number as its source text. `jsonEqual`
compares two values as the manager compares them: numbers by exact decimal
value, so `1.0` equals `1`, and objects without regard to member order.
`boundedInteger` and `word64` give the integer of a number only when the
number is integral and inside the range. `parseJson` does not refuse a
duplicate member or deep nesting. The Haskell strict decoder refuses both.

`src/manager/events.ts` holds the live-delivery decoders:

- `newSseParser`, `feedSse` and `closeSse` parse a server-sent-event stream
  incrementally. A line ends at LF or CRLF, and a carriage return elsewhere
  refuses. A comment-only block is a heartbeat. An `id` advances the last
  event identifier, and an `id` that is not a cursor refuses. A block above
  `SSE_BLOCK_BYTES` (16384 bytes, the terminating blank line included) and a
  block that is not UTF-8 refuse. A refusal is `InvalidResponse`. `feedSse`
  does not change the parser that it receives.
- `decodeEventBlock` and `decodeRouteBlock` decode one dispatched block as an
  invalidation of `/v1/events` or as a route record.
- `decodeInvalidation`, `decodeInvalidationEvent`, `decodeEventBatch` and
  `decodeRouteRecord` decode the JSON records. Each `encode` function gives
  back a JSON value that `jsonEqual` finds equal to the decoded value. A
  route-record body stays a lossless JSON value. Positions, sequence numbers
  and claim sizes are `bigint` values in the unsigned 64-bit range.
- `validCursor` and `validETag` check cursor and entity-tag syntax.
- `problemFailure(status, body)` gives `Refused` with the status and the code
  of a problem body, or `InvalidResponse`.

`src/manager/resources.ts` holds the decoders of the public resources and
the typed answer of a decision. Each decoder gives the decoded value, or
`InvalidResponse` when the value does not agree with the frozen
representation. A decoded value grants no ownership, approval, supervision or
control authority.

- `decodeDraftView`, `decodeReadiness`, `decodeInputDeclaration`,
  `decodeSuppliedInput` and `decodeInputError` decode a request and its
  readiness. `decodePreparation`, `decodeReview`, `decodeReviewInput`,
  `decodeReviewLineage` and `decodeReviewEdit` decode a preparation and its
  review. `decodeCommandReceipt` decodes a command receipt. Each `encode`
  function gives the canonical encoding of the decoded value, which is the
  encoding of the Haskell codec. A review keeps its policy and its result
  code as validated JSON values, and a root review has no lineage member.
- `decodeDecision`, `decodeControl`, `decodeRunItem` and
  `decodeOverviewMember` decode a decision, the controls of a run, one run
  item and one overview member `{"kind":K,K:member}`. A decision view and a
  control view keep the exact JSON value that they decode.
  `decisionProjection`, `controlProjection`, `runProjection` and
  `memberProjection` give the decoded fields. A UInt64 or UInt32 value is
  canonical decimal text, and an absent optional value is null.
- `answerValue(decision, input)` gives the typed JSON answer of the editor
  input. A flag takes `yes`, `no`, `true` or `false` in any letter case, so
  the input `no` gives JSON `false`. An empty receipt gives `null`, a text
  answer is the input itself, and a verdict takes JSON text. A structured
  question takes JSON text that agrees with the editor schema of the
  decision. Every other input, a structured question without an editor
  schema, and a recovery decision give the refusal `InvalidAnswer` with a
  reason. `answerBody(decision, value)` gives the closed answer body with
  the occurrence and the generation of the decision. A caller builds the
  body only from an accepted value, so a refused answer builds no command.

`src/manager/refresh.ts` holds the refresh coordinator of one client session.
Its functions return a new state and the actions that the caller performs.
They do not change the state that they receive, and no action is a send.

- `newRefresh`, `invalidateResource`, `completeFetch` and `advanceGeneration`
  coordinate the fetches of each resource key. An invalidation of an idle
  resource gives a `fetch` action for the current generation. An
  invalidation of a resource with a fetch in flight only marks it dirty, so
  any number of invalidations during one fetch give one later fetch. Only
  the completion of the fetch in flight of the current generation gives an
  `install` action, followed by one `fetch` action when the resource is
  dirty. Every other completion gives a `discard` action and changes
  nothing. `advanceGeneration`, for a resnapshot or an endpoint switch,
  advances the generation and makes every resource idle.
- `INITIAL_BACKOFF` and `reconnectDelay` give the reconnection delay: 1, 2,
  4, 8 and 16 seconds, and then `RECONNECT_BACKOFF_MAX_SECONDS` (30
  seconds). The caller resets the backoff to `INITIAL_BACKOFF` after a
  connection delivers an event. `jitteredMicroseconds(seconds, fraction)`
  gives a wait between half the delay and the whole delay. It clamps the
  fraction to the range from zero to one.
- An `Uncertain` value keeps a sent command whose outcome is uncertain, with
  its exact bytes, key and precondition, its target, the precondition entity
  tag and the receipt location when one is known. `reconcileRead` gives the
  one read: the receipt when its location is known, and otherwise the
  target. `reconcile` gives `effect-observed`, `refused` or `uncertain`. With
  a receipt location, only the receipt state decides. Without one, the
  target observes the effect only when the caller sees the effect and the
  entity tag differs from the precondition. An `uncertain` report carries
  the same `Uncertain` value unchanged, and the client resends nothing.

`src/manager/profile.ts` loads a client profile as `connectClientProfile`
of `Agentic.Manager.Client` does. A client profile is a JSON object with
exactly these four fields:

```json
{
  "version": 1,
  "endpoint": "https://127.0.0.1:8443/v1",
  "credentialFile": "/absolute/path/to/credential",
  "caFile": "/absolute/path/to/ca.pem"
}
```

- `version` is 1.
- `endpoint` starts with `https://` and has the path `/v1` or `/v1/`. It has
  no user information, query or fragment, and no space, control character
  or backslash.
- `credentialFile` and `caFile` are absolute paths of at most 4096 bytes.
- The profile file and the credential file are regular files that the user
  owns, with no group or other permission bits and one link. The profile
  file holds at most 16384 bytes. The credential file holds 32 to 512
  visible ASCII bytes other than the comma.
- The CA file is a regular file of at most 1 MiB that no group or other
  user can write, and it holds at least one PEM certificate.

`ClientProfile.load` reads the files without following a final symbolic
link. It refuses before any request: `InvalidClientProfile` for a profile
that does not parse, has a missing or an extra field, has another version
or has a relative path, `InvalidEndpoint` for the endpoint,
`ClientFileUnavailable` for a file that is missing, too large, not regular
or not private, and `CredentialUnavailable` for credential bytes outside
the bounds. Only this module reads the credential file. A `ClientProfile`
keeps the credential path and fingerprint in private fields, and its JSON
form names only the endpoint. `authorization` reads the credential again
for each request and gives `CredentialChanged` when its fingerprint differs
from the fingerprint at load.

`src/manager/transport.ts` holds `ManagerTransport`, the HTTPS transport of
one loaded profile:

- Each request uses `node:https` with the CA file as its only trust anchors,
  TLS 1.3 as its only version and its own agent, so no environment proxy
  and no connection pool applies. It sends the bearer in `Authorization`,
  `Accept-Encoding: identity` and `Connection: close`. A redirect status
  gives `RedirectRefused`, and no redirect is followed. A JSON response is
  complete within 15 seconds, and its body is at most 1 MiB, or the request
  gives `TransportUnavailable` or `ResponseTooLarge`.
- `get` gives the status, the lossless JSON value, the `ETag` and the
  `Location` of a response with `version` 1. `post` sends a JSON body of at
  most 2 MiB once with `Content-Type: application/json`, an
  `Idempotency-Key` and an optional `If-Match`. It never resends.
  `commandKey` gives a new idempotency key of an authority epoch. A problem
  response gives `Refused` with its status and code.
- `streamEvents` opens one SSE connection to `/v1/events` with the cursor in
  `Last-Event-ID`, parses it with `feedSse`, and gives each invalidation and
  heartbeat in order. It ends at the end of the response or after 45 seconds
  without a byte, and gives the last complete event identifier.
  `pollEvents` reads one JSON batch of the same resource after a cursor.
- `followEvents` follows `/v1/events` as the event worker of the TUI does.
  After an end or a failure of the stream, it reconnects with the last
  complete event identifier after the jittered wait of `reconnectDelay`. A
  connection that delivered an item resets the backoff. After two
  consecutive ends without a delivery, or after another refusal of the
  stream, it polls every second from the cursor and connects the stream
  again when the backoff has passed. A 410 refusal ends it with
  `resnapshot`, a credential refusal ends it with `refused`, and `close`
  ends it with `closed`. Its `prefer` option gives the delivery preference
  before each connection and after each polling batch. While it gives
  `poll`, the loop reads polling batches from the cursor and connects no
  stream. Its `connected` option receives the delivery and the
  `Last-Event-ID` cursor of each stream connection and each polling batch.
- `dropStream` closes the open event stream as a dropped connection does,
  and the transport stays open.
- `downloadVerified` reads an artifact download of at most 64 MiB with
  `Accept: application/octet-stream`. It requires status 200,
  `application/octet-stream`, `Cache-Control: no-store`,
  `X-Content-Type-Options: nosniff` and an `attachment` disposition, and it
  gives the exact bytes only when their size and lowercase SHA-256 equal the
  values that the caller states. Every other response gives
  `InvalidResponse`, and a problem response gives its refusal.
- `close` aborts every open request, the open stream and every wait. Every
  later call and every result that arrives after `close` gives
  `ClientClosed`.

`src/manager/session.ts` holds `ManagerSession`, one session bound to the
endpoint of a loaded profile:

- `ManagerSession.connect` reads `/v1/capabilities` once and refuses the
  versions, scopes, transports and limits that this client does not
  support, as `requireCapabilities` of `Agentic.Manager.Client` does. The
  session keeps the authority epoch of that read for the idempotency keys of
  its commands. The binding gets a new random endpoint identity.
- `reference` gives a `Reference`, which carries the endpoint identity and a
  resource below `/v1/`. Every read, command and download checks that
  identity, and a reference of another binding gives `WrongEndpoint`.
  `switchEndpoint` binds the session to the endpoint of another profile with
  a new identity and new capabilities, advances the refresh generation,
  clears the watched resources and reads the overview again. A reference of
  the earlier binding is never sent to the new endpoint.
- `pageSet` assembles one complete page set, as `getPageSet` does, and
  `loadOverview` assembles the overview of `/v1/snapshot` with its `cursor`,
  its `oldestCursor` and its decoded members, as `loadOverview` does.
  `start` installs the overview and follows `/v1/events` from its cursor
  with `followEvents`. A 410 refusal reads the overview again in a new
  generation and follows from its cursor.
- `watch` reads a resource and reads it again after each related
  invalidation, through the refresh coordinator of `src/manager/refresh.ts`.
  An invalidation is related when its resource equals the watched resource
  or one of the two lies below the other. An invalidation of a request,
  preparation, run or decision, or of a resource below one, also reads the
  overview again. The session reads the watched resources one at a time,
  coalesces the invalidations that arrive during a read into one later read,
  and installs no read of an earlier generation. A read refused with 429
  `storage-quota` or 503 `storage-unavailable` is read again after 100
  milliseconds. `waitFor` waits until the installed read of a watched
  resource satisfies a predicate.
- `prepare` gives a `PendingCommand` with the exact JSON body, a new
  idempotency key and the optional `If-Match` tag. `send` sends it once.
  A 2xx response that names its location is `delivered`, with the decoded
  receipt of a 202 response. A 412 `stale-revision` refusal is `refused`.
  Every other failure, and a 2xx response that does not agree with the
  command, is `uncertain` and keeps the command unchanged.
  `reconcileCommand` makes the one read of `reconcileRead` and gives the
  report of `reconcile`. The session never sends a command again by itself.
- `download` gives the bytes of `downloadVerified` for a reference of the
  binding.
- The `delivery` option and `setDelivery` select `sse` or `poll` delivery. A
  change to `poll` closes the open stream, and the follow loop continues
  from its last complete event identifier with polling batches.
  `forceReconnect` is a test hook that closes the open stream, so the loop
  reconnects with `Last-Event-ID` set to the last delivered event
  identifier. The `onEvent` and `onConnect` options receive each delivered
  invalidation and each connection.

`test/manager-transport.test.ts` runs the transport against a local
`node:https` server on `127.0.0.1`. The test generates an EC P-256 CA and a
leaf certificate with the subject alternative name `IP:127.0.0.1` in a
temporary directory with `openssl` from `PATH`. It covers GET and POST with
their headers over TLS 1.3, a refused redirect, an oversized body, a server
certificate of another CA, the reconnection of a dropped stream with
`Last-Event-ID`, the polling fallback, a 410 refusal, `close` during an open
stream with a late response, and the profile refusals before any request.
For the session it covers the refusal of unsupported capabilities,
`WrongEndpoint` for a reference after `switchEndpoint`, an uncertain command
whose reconciliation sends nothing, a download whose digest or size differs,
the resumption after `forceReconnect` with the last delivered event
identifier, polling delivery and its end, and the read of a watched resource
after an invalidation.

`test/manager-live.test.ts` runs only when `AGENT_CAT_MANAGER_PROFILE`
names a client profile. It drives one session against a running protected
manager whose profile runs the mixed-controls workflow of the
`engine/acp/test/retry_adapter.py` fixture. In six ordered steps, each with
a timeout of 600 seconds, it connects and bootstraps the overview, creates a
request with an exact Unicode literal, sets the input and enqueues it,
approves the exact review with the preparation entity tag as `If-Match` and
the review selectors, follows the run through SSE with one `forceReconnect`
and requires that the next connection sends the last delivered event
identifier, answers the Bool question with JSON `false`, follows one phase
through polling delivery and returns to SSE, sends the offered retry, waits
for terminal success, downloads and verifies the result, and requires that
the delivered events equal a prefix of the polling listing of the bootstrap
cursor. When `AGENT_CAT_MANAGER_REPORT` names a file, it writes the
identifiers and digests of the journey there. The `pi-client` mode of
`manager/test/service_http.py` runs it and checks the report against
manager facts that it reads with its own credential.

`test/manager-vectors.test.ts` reads `../test/manager_client_vectors.json` and
runs every case of its `events`, `resources` and `refresh` sections with the
pass criteria of the `vectors` mode of `manager-client-check` and of the
resource vector tests of the TUI service. Each resource case decodes to its
stated projection or refuses with `InvalidResponse`, and each answer case
gives its stated answer body or refuses with `InvalidAnswer`. It feeds each `sse` stream
whole, at each listed split, at every single split point of a stream of at
most 2048 bytes, and one byte at a time. It runs each refresh sequence step
by step and checks the exact actions and the coordinator rules of each step.
It fails when a subsection is empty, and it asserts the number of cases of
each subsection. For each resources subsection it also asserts the number of
cases that decode and the number that refuse.

## Configuration

Set the user-owned environment variables before you start Pi:

```sh
export AGENT_CAT_RUNNER=/absolute/path/to/agentic-run
export AGENT_CAT_STATE_DIR=$HOME/.pi/agent/agent-cat       # optional
export AGENT_CAT_RETENTION_DAYS=30                         # 0 disables age pruning
export AGENT_CAT_MAX_RUNS=100                              # 0 disables count pruning
```

For an ordered catalogue over several runners, set `AGENT_CAT_RUNNERS` instead
of `AGENT_CAT_RUNNER`:

```sh
export AGENT_CAT_RUNNERS='[{"id":"stable","executable":"/opt/agentic-run","allowedCwds":["/work"]},{"id":"next","executable":"/opt/agentic-run-next"}]'
```

The extension runs in local mode unless a manager client profile is
configured. Service mode is active only when one of these variables is set:

```sh
export AGENT_CAT_MANAGER_PROFILE=/absolute/path/to/profile.json
export AGENT_CAT_MANAGER_PROFILES='["/absolute/first.json","/absolute/second.json"]'
```

`AGENT_CAT_MANAGER_PROFILE` names one client profile.
`AGENT_CAT_MANAGER_PROFILES` is a JSON array of 1 to 8 distinct absolute
client-profile paths. The section "Service configuration" states how to
obtain a profile. The extension refuses to start when both variables are
set, when a path is relative, or when the array is empty, holds more than 8
entries, or repeats a path. `/wf-status` states the active mode. The
current-session, owned-child, deck, ACP, and remote Pi targets stay local in
both modes. The extension never advertises them as manager capabilities.

A remote Pi server requires a private transport in addition. The session
identifier is optional. When it is omitted, the extension uses the
authenticated discovery of Pi and asks the user to select a durable session:

```sh
export AGENT_CAT_PI_REMOTE_SOCKET=/absolute/private/pi.sock
export AGENT_CAT_PI_REMOTE_SESSION=<known-session-id>  # optional
```

The runner path and the state directory must be absolute. No project file and
no repository scan grants trust to a runner, and every mutable launch also
requires the project-trust decision of Pi for the working directory. The
extension refuses adapter arguments that contain credential-like flags or
values. Under routing version 2, credentials remain environment references that
agent-cat resolves. The extension receives neither those references nor their
values. A routing-only private manifest contains only the sanitized launch,
persona, and model-alias arguments. Lineage carries that exact target vector
forward instead of silently selecting current defaults. Explicit targets remain
explicit across lineage. Remote
transport authentication occurs before any Pi protocol bytes are exchanged.
The Unix transport relies on private socket permissions, and a remote session
is acquired exclusively across client connections.

Protocol-v2 runs retain typed public tool, complete plan/todo, and context-usage
updates separately from answer chunks. Obvious credential-bearing diagnostic
lines are redacted before persistence. ACP thought chunks are not public reasoning
summaries and are ignored. Engines that report no optional progress acquire none.

`/wf` requires Pi to run inside Agent Deck. It reads the inherited
`AGENTDECK_INSTANCE_ID`, and it never scans for another Agent Deck session or
asks the user to name one.

## Service configuration

Service mode needs a running agent-cat manager with HTTPS, a client
credential for each client and a client profile for each credential. The
manager configuration names the HTTPS address, the certificate and key, the
allowed hosts and peers, and the profiles, as `manager/CONFIGURATION.md`
states. The operator starts the manager with this command:

```sh
agentic-run --manager serve --config /absolute/path/to/configuration.json
```

The operator issues a client credential through local administration. The
request names the scopes and the profile identifiers of the credential, and
the manager writes the bearer into the private output file:

```sh
echo '{"version":1,"operation":"issue-credential","label":"Pi","scopes":["observe","submit","control"],"profileIds":["profile_1"],"expiresAt":"2999-01-01T00:00:00Z","outputFile":"/absolute/path/to/credential"}' \
  | agentic-run --manager admin --config /absolute/path/to/configuration.json
```

The client profile names the endpoint, that credential file and the CA file
that signed the certificate of the manager, as the section "Manager client"
states. The profile file and the credential file are private to the user.
Set `AGENT_CAT_MANAGER_PROFILE` to the absolute path of the profile. The
`observe` scope reads, `submit` creates, edits, enqueues and approves
requests, and `control` answers decisions and sends run controls.

## Source-aware inputs

A workflow author declares where each named input normally comes from, in the
ordinary input chain:

```haskell
taking (argsInput :> stdinInput :> input "tone" :> noInputs) \args body tone -> …
```

`argsInput` declares the command-tail input under the default name `args`, and
`stdinInput` declares the standard-input value under the default name `input`.
`argsInputAs` and `stdinInputAs` choose other names. Names are unique. A
workflow can declare at most one command-tail source and at most one
standard-input source.

`/wf` takes the workflow name and the unsplit command-tail text on its first
line, and then it takes a multiline body:

```text
/wf review Scope of the review

  These are instructions on what I want the review to focus on
```

This binds `args` to `Scope of the review` and `input` to the body. The
extension removes only the leading whitespace of the body, and it preserves the
internal and trailing whitespace. A missing tail or body value falls back to
the ordinary input editor. Tail or body text without a matching declaration
fails before any confirmation and before any run state is created.

The same declaration serves a direct pipe into the runner:

```sh
cat instructions.txt | agentic-run run review --session "$AGENTDECK_INSTANCE_ID" \
  --input-arg args='Scope of the review'
```

Machine mode reserves file descriptor 0 for that payload and takes control
NDJSON on inherited file descriptor 3. Descriptor version 3 retains protocol
version 1 while advertising negotiation and routing capabilities. A runner that
publishes descriptor version 1 remains prompt-only and keeps its controls on
standard input. A multiline body requires descriptor version 2 or 3 and support
for the control descriptor.

## Commands

| Command | Purpose |
|---|---|
| `/wf [RUNNER:WORKFLOW]` | Launch in the current Agent Deck session. Omit the name to select from the catalogue. |
| `/wf-help RUNNER:WORKFLOW` | Show the exact `help` output of the runner. |
| `/wf-plan RUNNER:WORKFLOW` | Show `plan --json --raw` with the actual inputs. |
| `/wf-launch RUNNER:WORKFLOW` | Launch wizard for alternate targets. |
| `/wf-status` | Summaries of active and recent runs. |
| `/wf-monitor [RUN_ID]` | Live monitor in authored order. The arrow keys or `j` and `k` move, Enter folds, and Escape closes. |
| `/wf-steer [RUN_ID]` | Steer one exact attempt. |
| `/wf-retry [RUN_ID]` | Retry an occurrence that waits after automatic recovery is spent. |
| `/wf-recover [RUN_ID]` | Choose one runner-offered retry, fail-over, or abandon action. |
| `/wf-redirect RUN_ID OCCURRENCE_ID RESERVED_TARGET` | Redirect a scheduler-reserved occurrence during the thirty-second decision window. |
| `/wf-grant` | Issue a one-time scoped grant for model-initiated starts, lineage, or controls. |
| `/wf-restart PARENT_RUN_ID` | Start a new run from scratch with immutable lineage. |
| `/wf-resume PARENT_RUN_ID` | Resume a compatible run semantically. |
| `/wf-fork PARENT_RUN_ID` | Fork a workflow immutably, with drops or replacements of persisted answers. This is distinct from a Pi conversation fork. |
| `/wf-diff CHILD_RUN_ID` | Compare lineage, identity, answer edits, and outcomes with the immutable parent. |
| `/wf-cancel RUN_ID` | Cancel an owned live run after approval. |

The `agent_cat_workflow` tool lets a model discover, start, inspect, control,
restart, resume, or fork runs. Starts from the tool are limited to the
scripted, tool-free child, and known remote targets. Every mutation requires an
unused matching grant from `/wf-grant`, and an unresolved or expired grant
refuses before anything is spent. Controls wait for the terminal acknowledgement
of agent-cat, and they report `delivered`, `rejected-stale`, `unsupported`, or
`failed` verbatim. A request is never presented as a success.

## Routing selection

`/wf` always uses the current Agent Deck session and does not inspect or load
routing configuration. `/wf-launch` offers routing configuration as a distinct
live target when a trusted descriptor-version-3 runner advertises inspection.
For that target, Pi invokes `agentic-run --routing --json`, offers the configured
persona or another user-owned persona, and offers optional concrete model aliases
for the workflow's managed profile axes. It passes the CLI-owned routing-only
launch arguments and fingerprint plus explicit persona and realization choices.
The runner requires full pin coverage. Explicit ACP, Agent Deck, current-session,
owned-child, and remote targets do not load routing configuration. Raw `--route`
remains available for explicit native ACP and Agent Deck targets.

The extension validates the sanitized version-2 projection and rejects fields
for secrets, environment bindings, headers, authorization, or endpoint URLs. It
never opens `routing.yaml`, resolves a selector, reads a cache, or interprets an
engine. Descriptor-version-1 and version-2 runners, and a version-3 runner that
uses version-1 routing, retain the previous route wizard. Supervisor manifests
have mode 0600 and store only the selected non-secret argument vector.

## Targets and containment

| Target | What answers | Containment |
|---|---|---|
| Scripted | The registered canned table. | Offline. No command runs. |
| Routing configuration | Configured profile engines. Every engine-bound question must have a configured pin. | Containment depends on every selected engine. |
| Native ACP | One explicit adapter plus optional raw pin routes. The built-in adapters are `stub`, `claude`, `codex`, and `droid`, and `droid` launches `droid exec --output-format acp`. | The scratch directory of agent-cat, which is not an operating-system sandbox. |
| Native agent-deck | The Agent Deck session that `/wf` inherits, or a session chosen in `/wf-launch`, plus optional raw pin routes. | The workspace of that session. |
| Current Pi session | Visible, exclusive injected turns in the current project. | Not a sandbox. |
| Owned Pi child | An in-memory Pi session with tools disabled. | The scratch directory of agent-cat. |
| Remote Pi session | A known or discovered session under an exclusive lease. | Its remote workspace, which is not a sandbox. |

For Droid, install and authenticate the `droid` executable before you start Pi,
or inherit `FACTORY_API_KEY` into the environment of Pi. Never enter a key in
the editor for adapter arguments. Select a Factory model and a reasoning level
through the symbolic routing profile of agent-cat, and not through adapter
arguments. The `servedBy` name of the workflow must match the profile, and a
Droid router uses `backend: acp:droid`. Droid exposes no output-limit control,
so the output policy must be stated explicitly:

```yaml
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: deep
    chain:
      - router: factory-droid
        model: gpt-5.6-luna
        thinking: low
        max-output: unconstrained
```

Pi passes the selected routes to agent-cat, and agent-cat preflights the
advertised model and reasoning setters before any prompt. If `max-output` is
omitted, or if any declared setting is unsupported, the run is refused. An
effectful workflow cannot use the tool-free child target. The current and
remote live targets require an explicit confirmation of charge and ownership.
The intent-based permission policy of agent-cat under ACP remains
authoritative.

## Persistence and recovery

Supervisor state is private under `STATE/runs/<run-id>/`, and agent-cat's own
store is the `runtime/` child of that directory. New runs use frontend manifest
version 2, shared with the terminal frontend; legacy extension manifests remain
readable. Pi transcript entries hold references and terminal status, never copied
prompts or credentials. A mode-0600 owner heartbeat lets another Pi or TUI process
attach read-only to a live run's event stream while controls stay with the original
exclusive supervisor; a dead owner leaves the run `orphaned`. State sharing occurs
only when those frontends are explicitly given the same `AGENT_CAT_STATE_DIR`.

The state directory is a local root. Before restore, reconstruction, or
retention, the extension applies the local-use check of the section
"State-root roles" of `runtime/README.md`. It canonicalizes the configured path,
then reads `.agentic-root-role.json` in the state directory and in each
ancestor, at most 256 directories. An absent marker means an unmarked
directory. The exact bytes `{"version":1,"role":"manager"}` followed by one LF
mark a manager root. Any other content, a file that is not regular, or a
symbolic link refuses. When the state directory is a manager root or lies
beneath one, session start fails with an error that names the manager root.
Restore and retention then delete nothing, and the extension does not create
its current-session bridge in that directory.

agent-cat persists six kinds of state. These are an immutable manifest with a
fixed reference to a private `program.json`, an append-only event journal, and
schema-indexed reusable answers that are keyed by the complete bare question.
The other three are a journal of started and completed effects, atomic
checkpoints, and ownership and lineage. Resume reuses only exact compatible
answers. A changed program, target, or policy refuses before a child is
created. A corrupt or unknown store version, a mismatched checkpoint count, an
invalid stored-answer schema, or any started or completed parent effect also
refuses. Restart is always a new run.
Fork inherits only matching bare-question answers. It can drop or replace
selected answers after the schema-validating preflight of the runner, and it
never mutates its parent. `/wf-diff` reports the durable edit hashes and
the resulting occurrence differences. Steered answer groups are marked as not
replayable.

When the extension restarts, it reconstructs terminal records from snapshots or
from agent-cat events. A malformed manifested run is isolated as
`corrupt-store`. A fresh directory without a manifest is ignored, so that it
cannot hide valid history, and stale incomplete directories follow retention
cleanup. A run that is not terminal and has no owned control channel is shown
as `orphaned`, and it is never presented as live or controllable. Restart,
resume, or fork such a run instead.

## Security and limits

Processes are spawned with a direct argument vector and never through a shell.
Input and program files are mode 0600, and transient launch inputs are deleted
after terminal cleanup; Agent Deck message files are mode 0600 and deleted
after each send, and prompt text never enters an argument vector or a machine
diagnostic. Run and store directories are private to the user. Protocol frames
are bounded at 1 MiB with canonical UTC timestamps and fail-closed sequence and
lifecycle reduction; in-memory attempt-output tails are bounded at 64 KiB, and
redacted standard-error logs at 10 MiB. Public progress text, collections, event
counts, and tool histories are bounded; stored event identities use fixed-size
digests. Environment values with credential-like
names or common token syntax are redacted. Cancellation is graceful first and
falls back to a process-group TERM and KILL. Retention never prunes an orphaned
run or an immutable parent that retained lineage references.

Unsupported or stale controls produce explicit acknowledgements. Modes without a
terminal user interface can list runs and show bounded textual monitors, but
launch and lineage approval refuse when interactive approval is unavailable.

## Build and test

The host packages link into the built Pi fork as the section "Supported host"
states. Do not run `npm ci` or `npm install`, because either command replaces
those links with the registry pins of `package-lock.json`.

```sh
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" npm run test:integration
```

The live check of the manager session runs through the `pi-client` mode of
the HTTPS harness. From the repository root, with a built
`routing-fixed-point-probe` as the runner and `node` on `PATH`:

```sh
python3 -B manager/test/service_http.py "$PWD" "$(mktemp -d)" "$(bash test/cabal.sh list-bin -ftui-tests routing-fixed-point-probe)" 8 pi-client
```

Remote discovery and control use Pi's Chord `SessionDirectory`,
`SessionManagement`, `AgentController`, and `Transcript` services. Boundary
follow-up uses `AgentController.followUp`. Correlated current-session turns
require `ExtensionAPI.startTaskTurn`, and the current-session choice is hidden
when that method is absent.

Set `PI_PACKAGE_DIR` to the coding-agent package directory of a built Pi
checkout to use it for the adapters and integration fixtures. For
`~/src/fork/pi`, this is `~/src/fork/pi/packages/coding-agent`. Its matching
client, server, and Chord packages resolve through Node's package resolution.
The integration gate requires a built runner and these Pi packages. It checks
that every named test exists and exercises native ACP, native deck, current,
owned-child, and remote targets without a paid call. Remote follow-up support
is checked through an actual control exchange rather than a class-name probe.

## Conventions

Keep this package a strict protocol client. Preserve project trust, explicit
grants, private files, bounded logs and events, fail-closed reduction, and
process cleanup. Add runner capability through versioned protocol fields, and
not through source imports or inference from prose.
