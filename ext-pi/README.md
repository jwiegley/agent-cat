# ext-pi

`ext-pi` is a Pi extension that makes Pi the control plane for agent-cat
workflows. agent-cat remains the only workflow interpreter. The extension reads
the trusted runner executables that its configuration names, and it gathers
inputs and launches the runner in machine mode. It reduces the event stream of
the runner into a live monitor, delivers controls, and keeps durable references
to runs. It never searches the file system or `PATH` for a runner.

## Boundary

Pi loads `src/index.ts`, which registers the `/wf` command, the
`/wf-...` commands, the `/wfm-...` commands of service mode, and the
`agent_cat_workflow` tool. The extension
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

## Host acceptance

The `pi-host-smoke` mode of `manager/test/service_http.py` accepts the host.
It starts the built fork in a pseudo-terminal against a running protected
manager, and it uses no paid provider and no network outside `127.0.0.1`.
The shared launcher `PiHost` of the harness starts Pi with this command, from
the repository root and with `node` from `PATH`:

```sh
node ext-pi/node_modules/@earendil-works/pi-coding-agent/dist/cli.js \
  --offline --no-extensions --no-skills --no-prompt-templates --no-themes \
  --no-context-files --approve \
  -e ext-pi/src/index.ts -e ext-pi/test/fixtures/faux-model.ts \
  --provider agent-cat-faux --model faux-1
```

The launcher builds the environment of Pi from an allowlist and not from the
environment of the harness. It passes `PATH`, `TERM`, `LANG`, `LC_ALL`,
`TMPDIR`, `USER`, `LOGNAME` and `SHELL`. It sets `HOME` and
`PI_CODING_AGENT_DIR` to new directories of the fixture, `PI_TELEMETRY` to
0, `AGENT_CAT_MANAGER_PROFILES` to a JSON array that holds the client
profile, `AGENT_CAT_STATE_DIR` to a directory of the fixture, and
`AGENT_CAT_FAUX_SCRIPT` to the faux script file. No provider key reaches Pi.
Pi needs no `settings.json` in the new configuration directory, and it
shows no first-run screen.

`test/fixtures/faux-model.ts` is a Pi extension that registers the local
provider `agent-cat-faux` with the model `faux-1` through
`pi.registerProvider` and a `streamSimple` function. It builds its replies
with the faux helpers of `@earendil-works/pi-ai` and makes no network
request. `AGENT_CAT_FAUX_SCRIPT` names the script file, and the extension
refuses to load without it. An empty file gives fixed text replies: reply N
is `agent-cat faux reply N`. Otherwise the file holds a JSON array of
replies, and Pi receives them in order, one for each model call. A reply is
one block or an array of blocks. A block is `{"text": TEXT}` or
`{"toolCall": {"name": NAME, "arguments": OBJECT}}`, with an optional `id`
in the tool call. A reply with a tool call stops with `toolUse`. After the
last scripted reply, the fixed text replies continue.
`test/faux-model.test.ts` checks the script rules and the registered stream.

The host is accepted when each of these steps passes:

1. The environment of the running Pi process holds `PI_TELEMETRY=0` and no
   variable whose name ends in `_API_KEY` or starts with `AWS_`.
2. Pi lists ext-pi and the faux extension as loaded, shows the faux model,
   and notifies the connection to the manager endpoint.
3. `/wfm-status` shows the connection to that endpoint with delivery `live`.
4. One prompt gives the reply `agent-cat faux reply 1` on the screen, and the
   session file of the new configuration directory records that reply from
   `agent-cat-faux/faux-1`.
5. `/quit` ends Pi with exit status 0 and the terminal modes restored.
6. The modification times of `.pi`, `.pi/agent/sessions` and the session
   directory of the working directory do not change under the `HOME` of the
   harness and under the home directory of the account, and an absent
   directory stays absent.

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
  review. `decodeCommandReceipt` decodes a command receipt, and
  `decodeCaptureReceipt` decodes a capture receipt: its identifier, its
  request and profile, its byte count as canonical decimal text of at most
  67108864, and its SHA-256. Each `encode`
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
  `postBytes` sends raw bytes of at most 64 MiB once in the same way, with
  `Content-Type: application/octet-stream`, as a capture sends them.
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
  Its `state` option receives the delivery state: `live` when a stream
  connection opens, `polling` after a successful polling batch, and
  `unreachable` when a stream connection does not open or a polling batch
  fails.
- `dropStream` closes the open event stream as a dropped connection does,
  and the transport stays open. A stream that is still opening at the call
  is closed when its response arrives, before it delivers anything.
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

- The `transport` option makes the transport of each binding. It defaults
  to `ManagerTransport`, and a test can give another `SessionTransport`.
  The `onChange` option is called after each installed read or overview,
  each change of `deliveryState`, the end of the follow loop, a switch and
  `close`. `deliveryState` is `connecting` until the follow loop of the
  binding reports a state, and then `live`, `polling` or `unreachable`.

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
  the earlier binding is never sent to the new endpoint. A read or a page
  that arrives from the earlier transport after the switch gives
  `WrongEndpoint`.
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
- `prepareCapture` gives the `PendingCommand` of a capture of exact raw
  bytes for a request, as `prepareCapture` of `Agentic.Manager.Client`
  does: a POST of `/v1/captures?requestId=ID` with a new idempotency key
  and no `If-Match`. Bytes above the `captureBytes` limit of the
  capabilities give `ResponseTooLarge`, and bytes that are not UTF-8 give
  `InvalidResponse`. `send` sends the bytes with `postBytes`. A capture is
  `delivered` only for a 202 response whose body is a capture receipt and
  whose `Location` names `/v1/commands/{id}`, and the outcome then carries
  the decoded capture receipt. Every other response is `uncertain`. The
  manager receives the bytes and never a path.
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
`Last-Event-ID`, a drop during the opening of a stream, which delivers
nothing from that stream, the polling fallback, a 410 refusal, `close` during an open
stream with a late response, and the profile refusals before any request.
For the session it covers the refusal of unsupported capabilities,
`WrongEndpoint` for a reference after `switchEndpoint`, an uncertain command
whose reconciliation sends nothing, a capture of exact bytes with
`application/octet-stream` and its decoded receipt, a capture response
without a capture receipt, which is uncertain, and the refusal of bytes that
are not UTF-8 before any request, a download whose digest or size differs,
the resumption after `forceReconnect` with the last delivered event
identifier, polling delivery and its end, and the read of a watched resource
after an invalidation.

`test/manager-live.test.ts` runs only when `AGENT_CAT_MANAGER_PROFILE`
names a client profile. It drives one session against a running protected
manager whose profile runs the mixed-controls workflow of the
`engine/acp/test/retry_adapter.py` fixture. In seven ordered steps, each with
a timeout of 600 seconds, it connects and bootstraps the overview, creates a
request with an exact Unicode literal, sets the input and enqueues it,
approves the exact review with the preparation entity tag as `If-Match` and
the review selectors, follows the run through SSE with one `forceReconnect`
and requires that the next connection sends the last delivered event
identifier, answers the Bool question with JSON `false`, follows one phase
through polling delivery and returns to SSE, sends the offered retry, waits
for terminal success, downloads and verifies the result, and requires that
the delivered events equal a prefix of the polling listing of the bootstrap
cursor. The seventh step starts a second run, which waits at its person
question, opens the extension in service mode with a fake Pi host, requires
that `/wfm-status` shows the run running under owned supervision with live
delivery, and closes the extension and then the session during their live
streams. When `AGENT_CAT_MANAGER_REPORT` names a file, it writes the
identifiers and digests of the journey there. The `pi-client` mode of
`manager/test/service_http.py` runs it and checks the report against
manager facts that it reads with its own credential. After every client
connection has closed, the harness also reads that the second run is still
running under owned supervision and that its question is pending.

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
entries, or repeats a path. `/wf-status` states the active mode, and
`/wfm-status` states the service connection, as the section "Service mode"
states. The current-session, owned-child, deck, ACP, and remote Pi targets
stay local in both modes. The extension never advertises them as manager
capabilities.

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

## Service mode

When `AGENT_CAT_MANAGER_PROFILE` or `AGENT_CAT_MANAGER_PROFILES` names
client profiles, `session_start` does these steps in order:

1. It restores the local runs of `AGENT_CAT_STATE_DIR` through
   `RunSupervisor.restore`, which first refuses a manager state root or a
   directory beneath one. Restore and retention never read, prune or
   reconstruct manager storage.
2. It starts the current-session bridge, as in local mode.
3. It creates one `ServiceMode` of `src/service-mode.ts` for the configured
   profiles. Service mode loads the first profile, connects one
   `ManagerSession`, reads the overview and follows `/v1/events`. Pi does not
   wait for the connection.

Service mode holds the runs, requests and decision heads of the overview as
service observations: `ServiceRunView`, `ServiceRequestView` and
`ServiceDecisionView`. Each observation is keyed by the endpoint identity of
the binding and its resource. An observation is not an `OwnedRun` or a
`RestoredRun`. It has no local reducer, no file-system monitor, no local
process and no local run store, and it grants no supervision or control
authority. A decision head is the decision at position 0 of the queue of its
run. `ServiceMode` itself sends no manager command. Only the commands of the
sections "Requests and review in service mode", "Live monitor and
decisions in service mode", "Run controls in service mode" and "Results,
history, lineage and exports in service mode" send commands, through the
session of the active binding. `ServiceMode.subscribe` calls a listener after each change of the
connection or of the observations, and the live monitor uses it.

| Command | Purpose |
|---|---|
| `/wfm-status` | The active profile, the endpoint and its endpoint identity, the delivery state (`connecting`, `live`, `polling` or `unreachable`), the scopes, profiles and transports that the manager grants, the service runs, requests and decision heads, and, in a separate list, the command receipts of the active binding. |
| `/wfm-endpoints [NUMBER]` | Choose among the configured profiles, by number or from a list. |
| `/wfm [WORKFLOW]` | Create a request, collect its exact inputs, enqueue it, and show its exact review, as the section "Requests and review in service mode" states. |
| `/wfm-review [REQUEST_ID]` | Continue a request: collect its missing inputs and enqueue it, follow its admission, or show its exact review. |
| `/wfm-withdraw [REQUEST_ID]` | Withdraw a request before its start. |
| `/wfm-discard [REQUEST_ID]` | Discard the live preparation of a request in review. |
| `/wfm-monitor [RUN_ID]` | Show the live monitor of a service run, as the section "Live monitor and decisions in service mode" states. |
| `/wfm-answer [RUN_ID]` | Answer the head decision of a run with a typed answer, or send a recovery choice that the manager offers. |
| `/wfm-cancel [RUN_ID]` | Cancel a run after a confirmation, when its controls allow the cancel, as the section "Run controls in service mode" states. |
| `/wfm-steer [RUN_ID]` | Steer an attempt that the controls of the run offer for steering. |
| `/wfm-redirect [RUN_ID]` | Redirect an occurrence to a target that the controls of the run offer, in its dispatch window or for its attempt in flight. |
| `/wfm-result [RUN_ID [PATH]]` | Retrieve the verified result of a succeeded run and save its exact bytes to a new file, as the section "Results, history, lineage and exports in service mode" states. |
| `/wfm-history` | List every run of `/v1/runs` over all its pages, with legacy entries labelled observer. |
| `/wfm-restart [RUN_ID]` | Create a restart child request of a run, show its exact review with its lineage, and start the child run after an approval. |
| `/wfm-resume [RUN_ID]` | Create a resume child request of a run, show its exact review with its lineage, and start the child run after an approval. |
| `/wfm-fork [RUN_ID]` | Collect fork edits, create a fork child request of a run, show its exact review with its lineage, and start the child run after an approval. |
| `/wfm-export [RUN_ID [NAME]]` | Export the verified result of a run under a name, verify the exported bytes, and list the exports of the run. |

The status widget lists active local runs and active service runs in
separate sections, and the status line counts each kind.

A switch with `/wfm-endpoints` uses `ManagerSession.switchEndpoint`. The new
binding gets a new endpoint identity, the refresh generation advances, and
the observations of the earlier endpoint are cleared. A read of the earlier
endpoint that arrives after the switch is never installed, and a stored
reference of the earlier endpoint gives `WrongEndpoint` and is never sent to
the new endpoint. When the new profile refuses, the earlier endpoint stays
active, and the extension reports the reason.

These conditions give a refusal state, which `/wfm-status` and a
notification show. No refusal state sends a command:

| State | Cause |
|---|---|
| `refused` | An unsupported profile, which `ClientProfile.load` refuses. |
| `refused` | Capabilities whose versions the client does not support. |
| `refused` | A refused credential (401 or 403), at connection or during the event stream. |
| `unreachable` | A manager that does not answer, or a 5xx refusal at connection. `/wfm-endpoints` connects again. |

`session_shutdown`, which Pi also emits before an extension reload, closes
service mode. Service mode closes the transport and the event stream of its
session and sends no command. The manager keeps every run, request and
decision under its own supervision, and a later session start reads them
again from the overview. A connection that completes after the close is
closed at once.

The local commands, `/wf`, `/wf-launch` and the other `/wf-...` commands, and
the local actions of the `agent_cat_workflow` tool, work in both modes and act
only on local runs. The `manager-...` actions of the tool act on manager runs
through the session of the active binding, as the section "Commands" states.

## Requests and review in service mode

`src/manager-ui.ts` holds `ManagerRequests`, the human path of service mode.
The `manager-...` actions of the `agent_cat_workflow` tool call the same
functions of `ManagerRequests` with the values of the model, as the section
"Commands" states. It uses the native Pi dialogs `ctx.ui.select`, `ctx.ui.editor`,
`ctx.ui.input` and `ctx.ui.confirm`, and a `ReviewComponent` of `pi-tui`
through `ctx.ui.custom`. Each command acts through the session of the active
binding and refuses while the manager is not connected.

`/wfm [WORKFLOW]` does these steps in order:

1. It reads `/v1/profiles` and the catalogue `/v1/workflows?profileId=ID`
   as complete page sets. With more than one ready profile, the user selects
   one. The user selects the workflow, or `WORKFLOW` names it.
2. It creates the request with `POST /v1/requests`, bound to the revisions
   of the catalogue entry.
3. For each missing declared input, the user selects `Literal text`,
   `Captured text` or `Captured file`. A literal is the exact editor text,
   with its Unicode and its whitespace. The leading-whitespace rule of the
   local `/wf` does not apply. A capture sends the exact bytes of the editor
   text, or of a local file that the user names, with `POST
   /v1/captures?requestId=ID` and a new idempotency key. The notification of
   the capture names the capture identifier, the byte count and the SHA-256
   of its receipt. A `set-input` with source `capture` then binds the
   capture identifier. The manager receives the bytes and never the path.
4. Each `set-input` carries the entity tag of the request as it was read
   before the editor opened. When the request changed during editing, the
   manager refuses the command with 412. The editor text stays a draft, and
   the editor opens again for the same input with the draft. A draft is
   removed when its `set-input` reaches its effect.
5. It enqueues the request and follows it. Each change of the phase, the
   admission state, the queue position or the blocking reasons gives one
   notification, until the request is in `review` with a live preparation.
6. It shows the review component. The component lists the complete exact
   review: the five approval selectors (`reviewDigest`, `requestRevision`,
   `profileRevision`, `descriptorRevision` and `processGeneration`), the
   entity tag that the approval binds as `If-Match`, the program SHA-256,
   the person answering, the workflow, the profile, the workspace, the
   target, the policy, the result code, each input with its source, size and
   SHA-256, the plan, the run facts, the pins, the warnings, and the lineage
   when the review has one. It wraps long lines and scrolls with `j`, `k` and
   the arrow keys. Outside the Pi TUI, the review is a notification, and a
   select gives the choice.
7. `a` asks for an explicit confirmation that names the preparation, the
   review digest and the entity tag. Only that confirmation sends `approve`,
   with the displayed selectors and the displayed entity tag as `If-Match`.
   The command then waits until the request names its run. Escape, `q`, `n`
   or a refused confirmation declines the review and sends nothing, so the
   request stays in review. `d` discards the preparation, and `w` withdraws
   the request.

Each send is one command, and nothing is sent again by itself. Each send
gives one notification that begins with `Command OPERATION` and states its
outcome: `accepted` with the receipt identifier and the receipt state,
`refused` with the status and code, or `uncertain`. An uncertain send is
reconciled with one read through `ManagerSession.reconcileCommand`, under the
rules of `reconcile` in `src/manager/refresh.ts`. Without a receipt location,
the read of the target observes the effect only when the command sees its
effect there and the entity tag differs from the precondition. An answer or
a recovery choice sees its effect when the decision is no longer pending, and
a retry sees its effect when the controls name another head. The other
commands see no effect in their target, so they stay uncertain. A reconciled
effect gives an `accepted` notification that names the read. The command is
never sent again, also when it stays uncertain. For each command except
`approve`, the command waits until its receipt settles, and the notification
names the settled state and the effect. An approval names the state of its
receipt at acceptance, and the run that the request then names is its
execution fact. Execution
facts are separate notifications: the admission of a request, and `Execution:
the manager started run RUN for request REQUEST`. `/wfm-status` lists the
command records of the active binding under `Command receipts:`, after the
service runs, requests and decision heads. A command whose required scopes
the credential lacks is not sent.

`/wfm-review` continues a request from its phase: a draft collects its
missing inputs and is enqueued, a queued or preparing request is followed,
and a request in review shows its review. `/wfm-withdraw` sends `withdraw`
with the entity tag of the request. `/wfm-discard` sends `discard` with the
entity tag of the live preparation. The manager then returns the request to
`draft`, and `/wfm-review` prepares a new review. Each of the three commands
takes a request identifier, or offers the open requests of the overview.

## Live monitor and decisions in service mode

`/wfm-monitor [RUN_ID]` opens a `ServiceMonitorComponent` of
`src/manager-ui.ts` for a run, or offers the service runs of the overview.
Its `ServiceMonitor` watches `/v1/runs/RUN_ID/snapshot`,
`/v1/runs/RUN_ID/control` and the decision queue `/v1/decisions?runId=RUN_ID`
through the session, so each related event of the manager reads them again,
and each change of service mode draws the monitor again. The monitor sends no
command. It shows these lines, which `serviceMonitorLines` gives:

| Line | Content |
|---|---|
| `Service run RUN_ID, workflow NAME` | The run and the workflow of its snapshot. |
| `Delivery: STATE` | The delivery state of the session. |
| `Observation: ...` | `current` when the latest read of each resource completed. `stale (CODE)` when a later read failed, and the last complete read stays in view. `refused (CODE)` when a resource has no complete read. |
| `Runtime: STATUS` | The runtime status of the snapshot, or `not yet observed`, followed by any supervision other than `owned`. |
| `Decisions: N pending` | The pending decisions of the queue, the head first. A question line names its code and its prompt. A recovery line names its gap, its message and its choices. |
| `Offers: ...` | The operations that the controls offer, and `cancel` when the manager allows it. |
| `Terminal: STATUS` | The terminal status of the run, followed by its failure when it has one. |
| `Result: ...` | For a succeeded run, `verified N bytes` and `Result SHA-256: DIGEST` of the retrieved bytes, or the state of the retrieval. Other runs have no download. |

When the snapshot of a succeeded run names a referenced or verified result,
the monitor reads `/v1/runs/RUN_ID/outputs` and downloads the verified result
once through `ManagerSession.download`, which checks its size and SHA-256. A
result that the manager has not verified yet is read again after the next
change of the snapshot. The component keeps the Terminal and Result lines in
view at every height, scrolls the other lines with `j`, `k` and the arrow
keys, and closes with `q` or Escape. Outside the Pi TUI, one notification
gives the lines after the first reads.

`/wfm-answer [RUN_ID]` acts on the head of a run, or offers the runs whose
head is pending. It reads the queue `/v1/decisions?runId=RUN_ID` as a complete
page set, takes the pending decision at position 0, and reads that decision
and the controls of the run. An offer counts only when the controls are
owned, name the decision as their head, and address its occurrence and its
generation.

- A question needs an `answer` offer. The typed editor names the decision,
  the code and the prompt. `answerValue` gives the typed JSON value, so the
  flag input `no` gives JSON `false`, and an input that does not agree with
  the code or the editor schema is refused before any send, after which the
  editor opens again with the draft. The answer body of `answerBody` goes to
  `/v1/decisions/ID` with the decision entity tag as `If-Match`.
- A 412 `stale-revision` refusal keeps the typed text as a draft and names
  it in a notification. Nothing is sent again. The command reads the
  decision once more. While the same decision is the pending head, the
  editor opens again with the draft. The manager serves only pending
  decisions, so a decision that another client answered reads as 404
  `unavailable-resource`, and the notification states that the kept draft is
  not sent.
- A recovery decision offers only the choices of `recoveryActions`: `Retry`
  when a `retry` offer addresses the decision, and each choice that a
  `choose-recovery` offer carries with the same target, such as `Fail over
  to TARGET` or `Abandon`. A retry goes to `/v1/runs/RUN_ID/control` with the
  control entity tag, and another choice goes to `/v1/decisions/ID` with the
  decision entity tag. A decision without an offered choice sends nothing.

Each send follows the rules of the section "Requests and review in service
mode", and the answer or the choice that reaches its effect gives one
notification, for example `Answer false reached decision ID of run RUN_ID.`

## Run controls in service mode

`/wfm-cancel [RUN_ID]`, `/wfm-steer [RUN_ID]` and `/wfm-redirect [RUN_ID]`
act on a run, or offer the running service runs of the overview. Each
command reads `/v1/runs/RUN_ID/control` once. It sends a control only when
those controls are owned and offer it, and otherwise it states that the
manager offers no such control and sends nothing. The control goes to
`/v1/runs/RUN_ID/control` with the control entity tag as `If-Match`.

- `/wfm-cancel` needs `cancelAllowed`. After a confirmation it sends
  `{"operation":"cancel"}`.
- `/wfm-steer` needs a `steer` offer, which names one attempt and its
  timings. The command asks for the attempt when the controls offer more
  than one, for the steering text, and for the timing when the offer has
  more than one. Empty text sends nothing. The body names the operation, the
  occurrence, the attempt, the timing and the text.
- `/wfm-redirect` needs a `redirect` offer with targets. The manager offers
  the dispatch-window redirect while the dispatch window of the occurrence
  is open, and the live redirect for the attempt in flight of an occurrence
  that is not an effect. The command reads `/v1/runs/RUN_ID/snapshot` once
  and labels each offered target with its occurrence and its place:
  `dispatch window open` or `attempt N in flight`. The body names the
  operation, the occurrence and the target. It names no attempt, because the
  runtime decides the redirect from the occurrence and its active attempts.

Each command follows the send rules of the section "Requests and review in
service mode". It waits until the receipt settles: at `effect-observed`,
`refused` or `unresolved`, at an acknowledgement that rejects the control
(`rejected-stale`, `unsupported` or `failed`), or, for a cancel, at an
acknowledgement that accepts, queues or delivers it, because the runtime
cancellation names no control and the receipt records no cancel effect.
The command then gives the receipt notification and after it the runtime
acknowledgement with its state and its message verbatim, for example
`Acknowledgement of command ID: rejected-stale: redirect target is not a live
candidate that remains in the approved fail-over chain`. A steer that reaches
the effect `steered` and a redirect that reaches the effect `redirected` each
give one more notification. After an accepting cancel acknowledgement, the
command waits for the terminal status of the run snapshot and states it, for
example `Execution: run RUN_ID is cancelled.`

`test/manager-ui.test.ts` checks that the review lists every selector and
consent fact, that the component wraps the review within the width and
reaches every line by scrolling, and the choice of each key. It also checks
that `recoveryActions` lists only offered choices for the head of owned
controls, the lines of a running and a terminal run, the stale and refused
observation lines, and that the monitor component keeps the Terminal and
Result lines in view at 12 rows. It also checks that cancel, steer and
redirect are offered only from owned controls that offer them, the place of
a redirect offer in a snapshot, and when a control receipt settles.
`test/manager-ui-live.test.ts` runs only when `AGENT_CAT_MANAGER_PROFILE`
names a client profile. It drives the extension with a fake Pi host, a fake
UI and a transport that records each POST, against a running manager with the
mixed fixture, in twelve ordered steps, each with a timeout of 600 seconds. It
enters an exact Unicode literal for `prompt-source` while the check changes
the request through its own session, so the first `set-input` is refused
with 412 and the editor opens again with the draft. It approves the displayed
review and requires that the approve body names the selectors of the
preparation. It captures exact editor text for `captured-input`. It declines
a review, requires that nothing was sent to the preparation and that the
request is still in review, and then discards the preparation and withdraws
the request. It starts a mixed-controls run, requires that `/wfm-monitor`
shows the runtime status, the current observation and the Bool question,
answers the question through `/wfm-answer` with `no`, which sends JSON
`false`, requires that the recovery choices equal the offered choices and
selects Retry, and requires that a second `/wfm-monitor` ends with the
Terminal and Result lines of the verified result. It then starts a second
mixed-controls run. While the editor of `/wfm-answer` is open, it writes the
decision to the handshake file that `AGENT_CAT_MANAGER_HARNESS_ANSWER`
names, and the harness answers first through HTTP with its own credential.
The answer of the extension receives 412, the draft is kept, and the
extension sends nothing more to the decision. The check then abandons the
recovery, or retries it when no abandon is offered. It then starts a third
mixed-controls run, which waits at its question, cancels it through
`/wfm-cancel`, requires that the one cancel POST is `{"operation":"cancel"}`,
that the receipt notification comes before the notification of the runtime
acknowledgement, which names the state and the message of the receipt, and
that the run ends cancelled. The three steps of results, exports and restart
that the section "Results, history, lineage and exports in service mode"
describes follow. The tool step of the section "Commands" follows them, and
then the history step. The last step closes the extension. The `pi-client` mode of
`manager/test/service_http.py` runs it before the session check and confirms
each step against manager facts: the answer commands, the retry command, the
answers of the run stores as JSON `false`, the verified result, that the
preempted decision has only the answer command of the harness, and that the
cancelled run has only the cancel command of the report, whose receipt
records an accepting acknowledgement, and ended cancelled.

`test/service-mode.test.ts` drives the extension with a fake Pi host, a fake
UI and an injected fake transport. It requires that restore reaches only the
local state directory, that the manager capabilities offer no local target,
that shutdown and reload close the transport without a POST, that a late
overview of the earlier endpoint is never installed after a switch and a
stored reference of that endpoint is refused, and that a 401, an unsupported
profile, an unsupported capability version and an unreachable manager show
their refusal states. It requires that `/wfm-redirect` sends the live
redirect of an attempt in flight with the control entity tag and reports
the receipt and then the delivered acknowledgement, that a rejected-stale
acknowledgement of a dispatch-window redirect is reported verbatim, that
`/wfm-steer` sends the editor text with the chosen timing, that
`/wfm-cancel` reports the accepting acknowledgement and then the cancelled
run, and that no control is sent when the controls offer none or the manager
does not own them. It also requires that `/wfm-answer` sends the flag input
`No` as JSON `false` with the decision entity tag, and that an uncertain send
is reconciled with one read of the decision and never sent again, both while
the decision stays pending and after it changed. The last step of `test/manager-live.test.ts` starts a
second run, closes the extension and the session during their live
streams, and the `pi-client` mode of `manager/test/service_http.py` then
confirms over HTTP that the run is still running under owned supervision.

## Results, history, lineage and exports in service mode

`/wfm-result`, `/wfm-restart`, `/wfm-resume`, `/wfm-fork` and `/wfm-export`
act on a run that the arguments name, or offer the terminal service runs of
the overview. Each command that sends a command follows the send rules of
the section "Requests and review in service mode".

`/wfm-result [RUN_ID [PATH]]` reads `/v1/runs/RUN_ID` once. A legacy entry,
a run that did not succeed and a run without a referenced or verified result
retrieve nothing, and the command states the reason. The command then waits
until `/v1/runs/RUN_ID/outputs` states a verified result whose artifact is
the one that its verification names, at most 120 seconds. A read of the
outputs makes the manager verify a referenced result.
`ManagerSession.download` downloads the artifact and checks the exact bytes
against the size and SHA-256 of that verification. The command then asks
for the path of a new file, unless the arguments name one. A relative path
names a file below the current directory of Pi. `saveExact` publishes the
bytes as `Agentic.Tui.Save` does. It writes them to a new private file in
the destination directory with an exclusive create, mode 0600, no symbolic
link, a full write and an fsync, and a hard link then publishes that file at
the path. A link never replaces an existing entry, so an existing file,
directory or symbolic link at the path refuses the save, the notification
names the cause (for example `EEXIST`), and the entry stays as it is. A
failure before the link removes the private file. A save reports the size,
the path and the SHA-256, for example `Saved the verified 103 bytes of run
RUN_ID to PATH, SHA-256 DIGEST.`

`/wfm-history` reads every page of `/v1/runs` as one page set and gives one
notification. The first line counts the managed runs and the observer
entries. Each run then has one line in the order of the collection: its
identifier, workflow, profile and runtime status, its supervision, its
lineage (for example `restart of run PARENT`), and the verification state of
its result. A legacy entry, which has `observer` supervision, reads
`observer (legacy entry, read only)`.

`/wfm-restart`, `/wfm-resume` and `/wfm-fork` read the first page of
`/v1/runs/RUN_ID/lineage-requests` once. An operation that the page does not
list as eligible sends nothing, and the notification names the eligible
operations or the refusal code of the page. `/wfm-fork` first reads the run
snapshot and lists each completed or reused occurrence with its code, its
current edit and its intent. For each occurrence the user keeps, drops or
replaces the answer. A replacement opens the editor with the published
answer, and `forkReplacementValue` types the text by the code of the
occurrence: text as given, a flag from yes, no, true or false, an
acknowledgement from empty text, and a verdict or a structured answer from
JSON text. A refused text opens the editor again with the text, and nothing
is sent. The command then sends `{"operation":"restart"}`,
`{"operation":"resume"}` or `{"operation":"fork","edits":EDITS}` to the
lineage collection with the entity tag of its first page as `If-Match`. On
the effect `lineage-created`, it states the child request, enqueues it
without `set-input`, because its inputs come from the parent run, and opens
its exact review in the review component. The review shows the lineage
operation, the parent run and each edit. Only an approval of that review
starts the child run, whose `parentRunId` and `lineage` name the parent run
and the operation.

`/wfm-export [RUN_ID [NAME]]` asks for the name unless the arguments name
it. A name that is not 1 to 128 ASCII letters, digits, dots, underscores or
hyphens that start with a letter or a digit sends nothing. The command reads
the first page of `/v1/runs/RUN_ID/exports` once and sends `{"name":NAME}`
with the entity tag of that page as `If-Match`. On the effect `exported`, it
reads the export receipt `/v1/exports/export_COMMAND` that the effect names.
The receipt must be the published export of this command, run and name. The
command downloads the exported bytes and checks them against the size and
SHA-256 of the receipt, states the receipt and the verified download, and
then lists the export collection of the run.

`test/manager-ui.test.ts` checks that `saveExact` publishes the exact bytes
with mode 0600, refuses an existing path, a symbolic link, a relative path
and a missing directory, and leaves no private file. It also checks the fork
targets of a snapshot, the typed replacements, the lineage bodies, and the
decoders of the export and lineage collections. `test/service-mode.test.ts`
requires that `/wfm-history` reads both pages of a two-page `/v1/runs` and
labels the legacy entry observer, that `/wfm-fork` sends one fork with a
typed replacement and a drop and the entity tag of the lineage collection
after a refused replacement text, and that an ineligible restart and an
invalid export name send nothing. `test/manager-ui-live.test.ts` saves the
verified result of its monitored run, requires mode 0600 and the size and
SHA-256 that the monitor showed, and requires that a second save to the same
path refuses and leaves the file unchanged. It exports that result once and
requires the one export POST with the entity tag of the collection, the
published receipt and its verified download. It restarts the run of its
first step, approves the review that shows the restart lineage, and requires
that the child run succeeds and names its parent and the lineage restart. It
then requires that `/wfm-history` lists every run of every page of
`/v1/runs` in the order of the collection. The `pi-client` mode of
`manager/test/service_http.py` confirms each of these steps with its own
credential: the saved file against its own download, the one published
export and its download against the published file, the one restart command
with its child request, the consumed child preparation with the restart
lineage, the parent and lineage of the child run, and the run identifiers of
every page of `/v1/runs`.

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
| `/wf-redirect RUN_ID OCCURRENCE_ID TARGET` | Redirect an occurrence, as the section "Local redirect" states: to a scheduler-reserved target during the thirty-second dispatch window, or to a live candidate of its fail-over chain while its attempt runs. |
| `/wf-restart PARENT_RUN_ID` | Start a new run from scratch with immutable lineage. |
| `/wf-resume PARENT_RUN_ID` | Resume a compatible run semantically. |
| `/wf-fork PARENT_RUN_ID` | Fork a workflow immutably, with drops or replacements of persisted answers. This is distinct from a Pi conversation fork. |
| `/wf-diff CHILD_RUN_ID` | Compare lineage, identity, answer edits, and outcomes with the immutable parent. |
| `/wf-cancel RUN_ID` | Cancel an owned live run after approval. |
| `/wfm-status` | Service mode: the manager connection, the service runs, requests and decision heads, and the command receipts. |
| `/wfm-endpoints [NUMBER]` | Service mode: choose the active client profile. |
| `/wfm [WORKFLOW]` | Service mode: create a manager request, enter its exact inputs, enqueue it, and review and approve it. |
| `/wfm-review [REQUEST_ID]` | Service mode: continue a manager request or show its exact review. |
| `/wfm-withdraw [REQUEST_ID]` | Service mode: withdraw a manager request before its start. |
| `/wfm-discard [REQUEST_ID]` | Service mode: discard the live preparation of a manager request in review. |
| `/wfm-monitor [RUN_ID]` | Service mode: the live monitor of a manager run, with its Terminal and Result lines. |
| `/wfm-answer [RUN_ID]` | Service mode: answer the head decision of a manager run, or send an offered recovery choice. |
| `/wfm-cancel [RUN_ID]` | Service mode: cancel a manager run when its controls allow it. |
| `/wfm-steer [RUN_ID]` | Service mode: steer an attempt that the controls of a manager run offer. |
| `/wfm-redirect [RUN_ID]` | Service mode: redirect an occurrence of a manager run to an offered target. |
| `/wfm-result [RUN_ID [PATH]]` | Service mode: save the verified result of a manager run to a new file with mode 0600. |
| `/wfm-history` | Service mode: list every manager run over all pages, with legacy entries labelled observer. |
| `/wfm-restart [RUN_ID]` | Service mode: restart a manager run through an approved child request. |
| `/wfm-resume [RUN_ID]` | Service mode: resume a manager run through an approved child request. |
| `/wfm-fork [RUN_ID]` | Service mode: fork a manager run with dropped or replaced answers through an approved child request. |
| `/wfm-export [RUN_ID [NAME]]` | Service mode: export the verified result of a manager run under a name. |

The `agent_cat_workflow` tool lets a model discover, start, inspect, control,
restart, resume, or fork local runs, and, in service mode, act on manager
runs. Starts from the tool are limited to the scripted, tool-free child, and
known remote targets. The `list`, `status` and `inspect` actions only read.

Every mutation from the tool is a model-initiated mutation, and a human must
confirm its exact content in Pi before anything is spent or sent. Each
mutation requires a trusted project and an interactive Pi UI. Without the UI,
the tool refuses before it discovers the workflow, reads the run or sends a
manager request. The human confirms the following review:

- A `start` shows the launch review of `/wf-launch`: the runner, the working
  directory, the target, the routing, the containment, the effects and the
  persistence. The exact value of each input follows as a JSON string, in
  the order of the descriptor. A start on the owned child or on a remote
  session first shows the same target confirmation as `/wf-launch`.
- A `restart`, `resume` or `fork` shows its lineage review: the operation,
  the parent run, the workflow, the runner, the working directory, the
  target and its arguments, the containment, the effects, the exact inputs,
  and each fork edit with its occurrence and its replacement value.
- A control (`cancel`, `steer`, `retry`, `recover` or `redirect`) shows its
  kind, the run, and the occurrence, the attempt, the timing, the target and
  the text that it carries. The target and the text are JSON strings.

The service actions call the functions of the matching `/wfm...` commands of
`ManagerRequests`, so a tool action and a human command reach the same manager
transitions, each after its own checks. The model gives the values that the
human command collects through the Pi dialogs:

| Action | Parameters | Confirmation in Pi |
|---|---|---|
| `manager-list` | none | None. It lists each ready profile with its workspace and target, and each workflow with its declared inputs. |
| `manager-status` | none | None. It gives the text of `/wfm-status` without the client profile path. |
| `manager-inspect` | `runId` | None. It gives the monitor lines of `/wfm-monitor` outside the Pi TUI. |
| `manager-result` | `runId`, optional `path` | None without `path`: it gives the size, the SHA-256 and the exact UTF-8 text of the verified result. With `path`, `Save manager result?` shows the run, the absolute path, the size and the SHA-256, and only then `saveExact` writes the file. |
| `manager-start` | `workflow`, `inputsJson`, optional `profileId` | `Create manager request?` shows the profile, its workspace and target, the workflow, its two revisions, and each input as a JSON string. The inputs must be exactly the declared inputs. After the create, each `set-input` of a literal and the `enqueue`, the exact review of `/wfm` opens, and its approval needs the confirmation `Approve this exact review?`. |
| `manager-answer` | `runId`, `answer` | `Send manager answer?` shows the decision, the run, the code, the prompt and the typed value that `answerValue` gives for the text, for example `value=false` for `false`. |
| `manager-control` | `runId`, `controlKind`, and the fields of the kind | `Send manager control?` shows `kind=KIND`, the run, and the fields of the kind. A `cancel` has no fields. A `steer` shows the occurrence, the attempt, the timing and the text. A `redirect` shows the occurrence, the target and its place. A `retry`, `failover` or `abandon` shows the decision, the occurrence and the offered choice, and `target` names one fail-over target. |
| `manager-lineage` | `runId`, `lineageOperation`, optional `forkEditsJson` | `OPERATION manager run?` shows the operation, the run and each fork edit with its typed value. After the lineage request, the exact review of the child request opens, and its approval needs its own confirmation. |
| `manager-export` | `runId`, `name` | `Export manager result?` shows the scope, the verified result of the run, and the name. |

A service mutation sends only what the controls, the decision or the
collections of the manager offer. A steer, a redirect or a recovery choice
that no offer matches, an answer to a recovery decision, a recovery choice
for a question, and inputs other than the declared inputs refuse before the
confirmation and send nothing. A model command that receives 412 is not sent
again. The fork edits of `manager-lineage` are a JSON array of
`{"type":"drop","occurrenceId":"N"}` and
`{"type":"replace","occurrenceId":"N","value":"TEXT"}`, where
`forkReplacementValue` types `TEXT` by the code of the occurrence, as in
`/wfm-fork`. The notifications of the command, in order, are the text of the
result. The result is an error unless the command reached its effect: the
started run, the answer or the choice, the control, the child run, the
verified export or the retrieved result. The bearer, the credential path and
the client profile path never appear in a tool parameter or a tool result.

A decline sends nothing and launches nothing, and the tool reports the
decline as an error. A declined review of `manager-start` or
`manager-lineage` sends no approval and leaves the request in review, as
`/wfm-review` states. No tool parameter grants a mutation. The parameter
schema leaves additional properties open, so a field that a model adds, such
as `grantId`, `approved` or `consent`, reaches the tool, and the tool ignores
it. Controls wait for the terminal acknowledgement of agent-cat, and they
report `delivered`, `rejected-stale`, `unsupported`, or `failed` verbatim. A
request is never presented as a success.

`test/extension.test.ts` drives the service actions with the fake transport of
`test/fixtures/fake-manager.ts`. It requires that `manager-start` without a UI
refuses before any request, that a declined request confirmation sends
nothing, that a declined review sends no approve POST, that a confirmed review
sends one approve POST with the selectors of the preparation, that `/wfm`
sends the same operations, that `manager-answer` sends JSON `false` only after
the confirmation of the typed value, and that no tool result contains the
bearer, the credential path or the profile path. The tool step of
`test/manager-ui-live.test.ts` starts mixed-controls twice through
`manager-start`, declines the first exact review and approves the second,
answers the question through `manager-answer` with `false`, and retries the
recovery through `manager-control`. The `pi-client` mode of
`manager/test/service_http.py` confirms that the declined review has no
approve command, that the run store records JSON `false`, that the run
succeeded, and that the tool request reached the same manager transitions as
the request of the human path: `set-input`, `enqueue`, `approve`, `answer` and
`retry`.

## Local redirect

`OwnedRun.redirect` of `src/supervisor.ts` sends `redirectOccurrence` in one
of two places. It refuses a terminal run and an unknown occurrence first.

- While the dispatch window of the occurrence is open, the target must be one
  of the targets that the scheduler reserved.
- While an attempt of the occurrence runs, the extension checks only that the
  target is non-empty text. The runtime accepts the redirect only for a
  question that is not an effect and a live candidate after the current
  candidate in the approved fail-over chain. It answers `rejected-stale` with
  its message otherwise, and the run continues.
- Elsewhere the redirect is refused before any send with `occurrence ID is
  neither in its dispatch window nor running an attempt`.

`expectedAttemptId` is null in both places, because the runtime decides the
redirect from `expectedOccurrenceId` and its active attempts. `/wf-redirect`
and the `redirect` action of the tool report the acknowledgement state and
message verbatim. After `occurrence.redirected` of a live redirect, the
report also names the stopped attempt, for example `redirect delivered
(redirect-ID): redirect delivered to the in-flight attempt; stopped attempt
0:0`. A target can contain spaces, so `/wf-redirect` takes the rest of its
arguments after the occurrence as the target.

`test/supervisor.test.ts` checks these cases with the fake runner: the
control frame of a live redirect names the occurrence, a null
`expectedAttemptId` and the given target, the delivered and the
`rejected-stale` acknowledgements are reported verbatim, and a redirect
outside both places is refused before any send. The ext-pi integration suite
cannot host a live candidate chain, because the `controlled` workflow and
the holding ACP adapter of the live redirect case of `test/control_probe.py`
belong to `routing-fixed-point-probe` and not to `agentic-run`. That case of
`test/control_probe.py` checks the live redirect against the runtime.

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

The host acceptance of the section "Host acceptance" runs in the same way
with the mode `pi-host-smoke`.

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

Keep this package a strict protocol client. Preserve project trust, the human
confirmation of each model-initiated mutation, private files, bounded logs and events, fail-closed reduction, and
process cleanup. Add runner capability through versioned protocol fields, and
not through source imports or inference from prose.
