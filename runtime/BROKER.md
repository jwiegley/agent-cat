# Runtime data broker

`DataBroker`, exported by `Agentic.Runtime`, represents typed request/reply
relations and ordered data delivery. `inProcessBroker` implements identity
delivery through the existing Haskell receivers. Runtime supplies the broker to
`runPlanBrokered`, while `cliMainWithBroker` carries the same object through CLI
execution, preflight controls, prepared frontend execution and final publication.
`cliMain` and the existing runtime entry points select `inProcessBroker`.

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
actor flow and its writer. A machine run with a run store writes a run log, as
the next section states. No manager writes a flow log at present, and
`inProcessBroker` delivers data as the sections above state.

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
golden file `test/fixtures/flow/hello-events.ndjson`. These
checks do not establish completion of the manager service or a frontend journey.
