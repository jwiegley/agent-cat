# Actor flow amendment

This record amends the scope of the [manager design](workflow-manager.md) and
the [implementation plan](workflow-manager-implementation-plan.md). The
operator decided the amendment on 2026-09-26, after revision 4 of the
actor-flow design record. It replaces the manager-broker amendment of
2026-09-25, which the operator withdrew and which was never recorded here.

The design and the implementation plan remain historical records. This
amendment changes one exclusion in each of them and the order of the work that
follows Phase A. It changes no other behavioral guarantee except the six
differences below.

## The narrowed exclusion

The design lists a message broker among the things that the implementation
must not add, in its section on decisions left to implementation. The plan
excludes a message broker from the release. This amendment narrows both
exclusions. It permits two kinds of in-process append-only log:

- The run log. Each runner keeps one log for each run that has a store.
- The manager log. The manager keeps one log for each Store stream identity in
  its private root, outside SQLite.

These exclusions remain in force:

- An external broker or any carrier of records between processes.
- The adoption of surviving workers.
- A remote engine connector.

## The model

Users, language models and tools are actors that receive and send messages.
An actor may send without first receiving a message. A user is recorded as the
principal that the receiving edge authenticated. The record makes no claim
about whether a person or a program used that principal. The workflow of a
request receives or presents the initial inputs and routes each output until a
stop condition holds. Its intake is the manager in service mode and the
launching interface in local modes. The runtime remains the sole interpreter
of the plan.

Every message is one record with a schema, a sender, an address, identifiers
and a body. The schema comes from a closed list, and it fixes the codec of the
body, the role of the record and its route class. An ask expects a reply. A
reply names the position of its ask in the same log. A tell expects no reply.
An ask without a reply is uncertain once its log ends, and uncertainty never
permits a second delivery. Each body is the existing typed value at the
boundary that it crosses. Each codec is strict, and its decoding exactly
inverts its encoding. A body above 64 KiB is a claim check on a private file.

The broker appends each record to the log of its writer before delivery. The
receiver acts on the value decoded from the appended bytes. The broker serves
any restriction of a log, live or replayed, to an authorized reader. It never
originates, alters, reorders, retries, re-routes or re-delivers a message. It
never answers an ask, grants approval, computes a bill or enforces a rule.
`DataBroker` keeps its nine operations, and `events.ndjson` keeps its bytes.

## The six differences

No behavioral guarantee changes except these six differences:

- **D1.** A failed append to the run log fails the run through the existing
  observer-failure path.
- **D2.** A failed append of a reply can leave an effect potentially executed.
- **D3.** A codec defect fails an operation before delivery.
- **D4.** A failed manager append before a commit or a dispatch refuses the
  command, except a cancel. Any other failed manager append leads to a gap
  notice.
- **D5.** An ordinary command that would pass the ceiling of the manager log is
  refused with `storage-quota`.
- **D6.** After increment 3, the runtime accepts a redirect of an in-flight
  attempt that is not an effect, within the approved candidates and the
  approved fail-over budget.

These remain binding: the settled Store policy and schema version 12, exact
consent before spending, no opaque replay and no promise of exactly-once
effects, the distinct facts of intent, delivery, acknowledgement, effect,
terminal state, cleanup and release, original ownership without adoption, the
restart and restore fences, bounded parsing and typed values, the frozen `/v1`
contract with additive extensions only, observation protocols 1 to 3, the
native frames, the run-store formats and the local frontend modes. The
ordering claims of the run log hold for process crashes. The consent records
of the manager survive operating-system crashes.

## Placement of the increments

Phase A proceeds unchanged. Each increment lands as reviewed deltas, which are
revalidated at N1 and then at N8.

1. **Increment 1: the logs, the local reader and the permission reports.** It
   lands after the operator accepts Phase A and before Phase B resumes WM025
   to WM027, within 16 engineering days. Delta 1a adds the run log, the
   versioned engine codecs, the `EnginePermission` report of the ACP adapter
   and a local reader. Delta 1b adds the manager log. Increment 1 makes no
   `/v1` change. It adds no service subscription, no live re-route and no
   enforcement at any writer.
2. **Increment 2: service subscription.** It lands inside WM025 and WM026. It
   adds a `/v1` route resource and begins with a written threat model.
3. **Increment 3: live re-route and asks that people answer.** It lands
   between WM027 and WM028. It adds difference D6 and a reviewed policy field
   that names the asks that a person answers.

RabbitMQ and the integrations of John Mark remain deferred, and they are not
prerequisites of acceptance. Validation stays local to one macOS machine. This
amendment does not authorize a paid backend or a new Lean or oracle build.
