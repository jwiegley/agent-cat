# Runtime data broker

`DataBroker`, exported by `Agentic.Runtime`, represents typed request/reply
relations and ordered data delivery. `inProcessBroker` implements identity
delivery through the existing Haskell receivers. Runtime supplies the broker to
`runPlanBrokered`, while `cliMainWithBroker` carries the same object through CLI
execution, preflight controls, prepared frontend execution and final publication.
`cliMain` selects `inProcessBroker`. `runPlanPersisted` and
`worldOfEngineBrokered` take a broker explicitly. The runtime entry points
without persistence (`runPlanIO`, `runPlanWith`, `runPlanObserved` and
`runPlanControlled`), `worldOfEngine`, `worldOfEngineWith`, `activateEventSink`
and `withBufferedControlInputFor` select `inProcessBroker`. None of them takes a
run store, and no run with a run store reaches them.

## Meaning and authority

For a fixed plan, inputs, controls and engine observations, identity delivery
preserves the result, authored trace, exact bills, typed values and outcome.
Physical identifiers and timestamps retain their existing correspondence rules.
This is a realization obligation, not a new theorem about external effects.

Runtime remains the sole workflow interpreter. It selects destinations, reserves
lanes, claims memo entries, renders questions, decodes replies, chooses recovery
and performs workflow transitions. The manager retains authentication, exact
approval, admission, coordination and original worker ownership. Engine adapters
retain their physical protocol implementations and original resource scopes.
The broker delivers their data without assuming any of those authorities.

## Operations

| Operation | Delivery obligation |
| --- | --- |
| `brokerRequest` | Deliver the typed addressed request to the runtime-supplied answering receiver and return its typed answer. |
| `brokerStart` | Connect the selected opaque engine to the supplied attempt context for one logical question. |
| `brokerTurn` | Deliver one turn to its original conversation and return the engine response that runtime decodes. |
| `brokerUpdate` | Deliver an intermediate engine update to its original attempt receiver before runtime public-progress validation. An `EnginePermission` update produces no public progress. |
| `brokerSteer` | Deliver steering through the original engine capability and return its actual acknowledgement. |
| `brokerControl` | Deliver a validated control to the original runtime receiver. Its Boolean result determines whether that input loop continues. |
| `brokerEvent` | Deliver the runtime event to its original event sink. |
| `brokerLog` | Deliver diagnostic or narration text to its supplied receiver. |
| `brokerPersistence` | Supply the existing run-store operations, including final result publication, under their original ownership and failure contracts. |

Tools that a registry row answers in process and shell tools both run inside
the answering receiver that runtime supplies to `brokerRequest`. `brokerRequest`
therefore delivers their questions, and neither kind of tool starts an engine
conversation. The logs of both kinds of tool reach their receivers through
`brokerLog` of the broker that runs the plan. The CLI applies `brokerLog` to the
receiver that it gives the in-process tools. For each shell tool attempt,
runtime applies `brokerLog` to the log that the shell configuration names.

Receivers may discard data according to their existing policy. A log receiver
that suppresses machine-mode narration does not authorize a broker to publish
that narration elsewhere. Public progress validation and redaction remain in
runtime, and the broker does not turn private messages into public events.

## Correlation, order and lifetime

A reply belongs to its original invocation and type witness. A conversation
belongs to the original logical question, while updates and steering retain the
original physical attempt context. IDs, paths and messages are observations,
not replacements for these live capabilities. Receiver callbacks, engines,
conversations and steerers are local attachments and are not wire values.

Runtime reserves the original stateful and effect lanes in authored order.
Delivery preserves that order and the causal order within each conversation,
without inventing a total order between independent requests. Every effect
waits for the completion of each question reserved since the previous effect,
and every other question waits for the tail of the effect lane. Runtime applies
these waits before it offers a request to the broker. The existing event writer
assigns sequence numbers and writes durable journal data before mirrors.
Deferred activation publishes the start before forwarding queued control events.
A broker must not reorder those publications or acknowledge a mirror as though
it were the durable writer.

Reusable answers are scoped to one act. The epoch of a question is the number
of effects that runtime reserved before it in plan order, so each effect starts
a new epoch for the questions after it. Runtime looks up and stores a reusable
answer by its epoch and bare question, and no reusable answer crosses an effect.
A broker that wraps `persistenceLookupAnswer` or `persistenceStoreAnswer` must
deliver the epoch unchanged and must not supply an answer from another epoch.

The default broker adds no queue or execution worker. Existing frame, payload,
reader and Store-admission bounds continue to apply. An implementation that adds
buffering must bound it without weakening those limits or silently dropping a
response, control or terminal event. Borrowed receivers cannot outlive their
original resource scope. The machine control-input scope propagates synchronous
receiver failure to its runtime and cancels and joins its original reader on exit.

## Flow records

`Agentic.Runtime.Flow`, exported by `Agentic.Runtime`, defines the record of the
actor flow, its writer and `flowBroker`. A machine run with a run store writes
a run log and carries its broker operations through that log, as the next two
sections state. No manager writes a flow log at present.

A `Record` names one of seventeen schemas, a sender, an address, the
identifiers that it concerns, the position of its ask when it is a reply, a body
and the time at which the writer appended it. The schema fixes the role of the
record as an ask, a reply or a tell, and its route class. A reply may answer
only the asks that its schema names. A body is inline when its compact encoding
is at most 65536 bytes. A larger body is a claim check that names its SHA-256
and its size, and the `event` schema names a line of `events.ndjson` by its
sequence number.

`decodeFlowLine` refuses a line above `maxFrameBytes` before it decodes any
byte. It also refuses a duplicate key at any depth, an unknown or a missing
field, and any bytes other than the encoder's rendering of the decoded record,
so `decodeFlowLine (encodeFlowLine r)` returns `r`. The run-log body codecs use
the existing strict codecs: `requestJson` and the exact `El` codec for
questions and answers, the version-1 engine codecs for engine requests, results,
steering and permission reports, and `encodeControlFor` and `decodeControlFor`
at the protocol that a control body names. Each body decoder refuses any value
that its encoder does not write.

`openFlowWriter` creates the log as an exclusive private file in a
`PrivateRoot`. One lock orders its appends. Under that lock the writer takes the
time of the record, encodes the record with its `FlowCodec`, decodes the bytes
with the same codec, writes a claim-check body as the exclusive private file
`flow-claims/<sha256>` and then appends the line. A claim-check file that
already exists is used only when its bytes are equal. The writer flushes each
line and does not synchronize it. After a failed line write it refuses every
later append. `appendAsk`, `appendTell` and `appendReply` return the
0-based position of the record and the record decoded from its bytes. The
writer keeps only the schema of each position, and it refuses a reply whose
position does not name an earlier ask that the reply may answer.
`readFlowContent` verifies the size, digest and exact encoding of a claim check
before it returns the body.

## Run log

When `AGENT_CAT_RUN_STORE` names a run store, `runMachineWith` creates the run
log `flow.ndjson` in that store with `withRunLog` and the strict codec. A run
without a run store writes no run log.

The first record is `start`, from the intake of the run to the workflow of the
run. The composition root chooses the intake as an explicit option. The
frontend worker that the manager starts uses `Manager`. Every other machine
command uses `Principal (LocalAccount uid owner)`, where `uid` is the real user
identifier of the process and `owner` is the value of `AGENT_CAT_RUN_OWNER`,
recorded as declared and not authenticated. The body names the native run
identifier, the SHA-256 of the compact encoding of the printed program, the
SHA-256 of the compact encoding of the target policy, the person-answering mode
under protocol 2 or later, the target label, the lineage operation, the parent
run and each input by name, UTF-8 size and SHA-256. The frontend preparation
computes its program hash with the same function.

The event sink `handlesEventSinkLogged` holds the run log and writes the events
of the run. Under its one writer lock, event `n` appends the `event` record that
names `n`, from the workflow of the run to the public audience, then writes line
`n` of `events.ndjson` and then the stdout mirror. Events that deferred
activation forwards pass through the same sink, so the run log records them
too. The writer flushes each line and does not synchronize it.

A failed run-log append fails the run through the existing observer-failure
path. The sink throws the original exception, writes no line for that event and
fails every later event, as it does after a failed durable write. The run stops
with that exception, and `events.ndjson` holds exactly the lines whose records
the run log holds.

## Carriage

`flowBroker :: FlowCodec -> RunFlow -> DataBroker -> DataBroker` wraps a broker
and keeps its nine operations and their types. When the run has a run store,
`runMachineWith` wraps the broker that it receives, so `cliMain` wraps
`inProcessBroker` and the `--broker-test` runners of
`cli/test/RoutingFixedPointProbe.hs` wrap their counting brokers. A run without
a run store uses the broker that it receives.

Every path of a store-backed run delivers through the broker of that run. The
command-line interface builds each engine world with `worldOfEngineBrokered`
and the broker of the run, so an engine ask without attempt context uses that
broker. Under `flowBroker`, such an ask has no occurrence scope and is refused
before delivery. `announcingWorld` delivers the narration of an ask without
attempt context through `brokerLog` of `inProcessBroker`, and `brokerLog`
appends nothing.

Preflight controls start before the program and the run store exist. The
control loop of `withMachineControls` delivers each control through the broker
in a cell. The cell holds the broker of the command until `runMachineWith`
fills it with the broker of the run, before `activateEventSinkBrokered`
publishes the start and forwards the queued events. The cell returns to the
broker of the command when the run ends. A control delivered before activation
therefore appears in the run log only as its acknowledgement event, and every
control delivered after activation has its `control` record. A prepared
frontend run reads its controls with the broker of the run from the start.

`RunFlow` holds the run log writer, the runtime protocol of the run, the native
run identifier, the intake actor, the answerer function, the failure classifier
and an optional occurrence scope. `runFlowFor` builds it from the `start`
record, the intake and the names of the tools that the run answers in process.
The answerer of a request is the candidate that `requestTarget` names, with a
kind that `requestAnswerer` resolves from the run target and the
person-answering mode in `start` and from the in-process tool names. It never
takes the kind from an engine report. A person question under local control
goes to the intake. Under the scripted target the table answers every other
question as a fixture. Otherwise an in-process tool is a registry tool, a
command is a program command, and every other question, including a person
question in engine mode, goes to the model that the runtime routed it to.

The operations append these records. The runtime of the run sends each ask and
receives each reply.

| Operation | Records |
| --- | --- |
| `brokerRequest` | `question` to the answerer, then `answer` from the answerer or `failure`. When a control supplied the answer, the `answer` comes from the intake and its identifiers name that control as the command. |
| `brokerStart` | `engine-start` to the answerer of the question in flight, then `done` or `failure`. The conversation is not recorded. |
| `brokerTurn` | `turn`, then `engine-result` or `failure`. |
| `brokerSteer` | `steer`, then `done`, or `failure` of class `refused` when the engine returns a refusal. |
| `brokerControl` | `control` from the intake, whose identifiers name the control identifier as the command. |
| `brokerUpdate` | `permission` from `Adapter` with the name of the answerer, for an `EnginePermission` update only. |
| `brokerEvent`, `brokerLog`, `brokerPersistence` | nothing. The event sink appends each `event` record, as the previous section states. |

Carriage rule. Each ask or tell is appended before delivery, and the receiver
gets the value decoded from the appended bytes. The runtime gets the value
decoded from the reply record. A body above 65536 bytes is read back from its
verified claim check. A receiver that raises a synchronous exception has a
`failure` record with the runtime failure class and message of that exception,
and the original exception propagates. An asynchronous exception appends
nothing, so its ask stays without a reply.

- **D1.** A failed run-log append fails the operation, and the run stops through
  the existing observer-failure path or with the exception of the operation.
- **D2.** When the reply append fails after the receiver returned, the operation
  raises the append failure and the runtime does not receive that reply. An
  effect in that position is potentially executed.
- **D3.** A record whose bytes do not decode fails the operation before
  delivery. Otherwise the receiver acts on the decoding, even when the codec
  changed the value.

`runPlanScoped` takes the broker of the run and a function from a `FlowScope`
to the broker of one occurrence, and `runPlanBrokered` is `runPlanScoped` with
the constant function. The runtime creates the scope of each occurrence before
the occurrence dispatches anything. The scope holds the occurrence identifier,
the epoch, an attempt field that the runtime leaves empty at present, a cell
for the control that supplied the answer, and a cell for the answerer of the
question in flight. `brokerRequest` empties the answer cell before delivery. A
local person answer writes the control identifier that
`waitForRuntimePersonAnswer` returns into the answer cell before its receiver
returns, and `brokerRequest` reads the cell when it appends the answer.
`flowScopedBroker` wraps the broker with the scoped flow, so the records of an
occurrence name its occurrence and epoch. Only `brokerRequest` sets the answerer
cell, for the duration of its receiver, and `brokerStart`, `brokerTurn`,
`brokerSteer` and `brokerUpdate` address the answerer that it holds. An engine
operation without a scope or without a question in flight is refused before
delivery.

The runtime broker checks run `flowBroker` over a recording broker, under the
strict codec and under a codec that changes the values that it decodes. A mirror
that hands on the original values fails those checks. The checks also cover a
failed reply append, undecodable bytes and bodies, receiver failures,
asynchronous exceptions, the answerer of each kind of request, and the scopes of
two concurrent occurrences.

## Failure and extension

Success means that the original receiver operation returned successfully.
Publication, acknowledgement, runtime termination, worker exit and resource
release remain distinct facts. Exceptions and failure distinctions propagate
without being converted into success, reusable ownership or a retryable result.
A broker does not retry an opaque effect or an uncertain publication. Runtime
retains its existing, explicit decode and recovery policy.

Another implementation supplies the same `DataBroker` operations. It may use a
different transport, but it must correlate returned data to the original local
receivers and preserve these obligations. A separate transport needs its own
session protocol and cannot serialize Haskell callbacks or reconstruct execution
authority from message IDs. No RabbitMQ implementation or external wire protocol
is included. Native JSON, protocol versions, store formats and artifact encoding
remain owned by their existing adapters.

The runtime broker checks exercise consumed replies, authored traces, exact bills,
steering, event/log delivery, shell tool log delivery, persistence, unchanged
epoch delivery for reusable answers and uncertainty without effect replay.
The ACP progress probe also runs Hello World and an injected-reply fixture through
real local ACP processes, checking consumed answers and durable events. It
compares the Hello World `events.ndjson`, with each timestamp replaced, with the
golden file `test/fixtures/flow/hello-events.ndjson`, and it checks that the
Hello World and injected-reply run logs hold a question, an engine start, a
turn, an engine result and an answer for each occurrence.

The flow probe `test/flow_probe.py` reads the run logs of store-backed machine
runs as JSON lines. It checks that a registry tool, a program command, a
fixture, a model and a local person answer each name their sender, that an
engine answer that names another target leaves the sender unchanged, that a
person question in engine mode goes to the model, and that a model answer with
approval phrases and control frames adds no `start` and no `control` record. It
checks the three retry forms: two `engine-start` records under one question for
a transport-gap retry, two `turn` records for a decoding re-ask and two
`question` records for a fail-over. Its structural check requires every
`attempt.started` event to lie inside an open question of its occurrence, and
inside an open turn when the question goes to a model, and requires every
acknowledgement of a control delivered after activation to follow a `control`
record with its identifier. The check fails on a copy of a log without one turn
record. In each broker-test run, the counts of the inner broker equal the
records of the run log. A static check lists every source line under
`runtime/src` and `cli/src` that names `inProcessBroker` and fails on a line
outside its allowlist. With `--journey FIXTURE`, the probe checks that the
control records and control-supplied answers of a frontend journey come from
the manager and name a command identifier. These checks do not establish
completion of the manager service or a frontend journey.
