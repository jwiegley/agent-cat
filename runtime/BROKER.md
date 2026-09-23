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
| `brokerUpdate` | Deliver an intermediate engine update to its original attempt receiver before runtime public-progress validation. |
| `brokerSteer` | Deliver steering through the original engine capability and return its actual acknowledgement. |
| `brokerControl` | Deliver a validated control to the original runtime receiver. Its Boolean result determines whether that input loop continues. |
| `brokerEvent` | Deliver the runtime event to its original event sink. |
| `brokerLog` | Deliver diagnostic or narration text to its supplied receiver. |
| `brokerPersistence` | Supply the existing run-store operations, including final result publication, under their original ownership and failure contracts. |

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
without inventing a total order between independent requests. The existing event
writer assigns sequence numbers and writes durable journal data before mirrors.
Deferred activation publishes the start before forwarding queued control events.
A broker must not reorder those publications or acknowledge a mirror as though
it were the durable writer.

The default broker adds no queue or execution worker. Existing frame, payload,
reader and Store-admission bounds continue to apply. An implementation that adds
buffering must bound it without weakening those limits or silently dropping a
response, control or terminal event. Borrowed receivers cannot outlive their
original resource scope. The machine control-input scope propagates synchronous
receiver failure to its runtime and cancels and joins its original reader on exit.

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
steering, event/log delivery, persistence and uncertainty without effect replay.
The ACP progress probe also runs Hello World and an injected-reply fixture through
real local ACP processes, checking consumed answers and durable events. These
checks do not establish completion of the manager service or a frontend journey.
