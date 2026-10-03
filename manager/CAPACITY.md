# Capacity and failure ceilings

This document states the workloads and the accepted ceilings of the WM-041
capacity and failure evidence for the manager. The ceilings were set before
any measurement ran, and the commit that adds this document precedes every
commit that adds a measurement. Each ceiling follows from an advertised bound
of [HTTP framing and limits](../doc/api/README.md#http-framing-and-limits), from
a configurable limit of [the operator configuration](CONFIGURATION.md), or
from a fixed allowance that this document states, with the headroom stated
beside it. No ceiling comes from a trial run.

The file `manager/test/capacity-ceilings.json` holds the same ceilings under
the same keys. The tool `manager/test/capacity_summary.py` compares the two
and compares measurements with the ceilings, as the section
[The summary tool](#the-summary-tool) describes.

## Tested platform

The ceilings apply to one machine and one set of workers:

- macOS 27.0 (build 26A428) on arm64, an Apple M3 Ultra with 32 logical
  processors and 549755813888 bytes of memory.
- GHC 9.10.3, with the manager started with the RTS option `-N8`.
- The registry executable `routing-fixed-point-probe` as the runner, with
  its scripted target (`--scripted`) and with the ACP fixture adapters of
  `engine/acp/test`. These deterministic workers isolate the overhead of the
  manager from the latency of a provider.
- The manager listens on 127.0.0.1 with TLS 1.3, and every client of a
  workload is a harness client on the same machine.

No claim of this document extends to another platform, another worker or
another workload. A passing summary shows that the measured workloads stayed
inside their ceilings on this machine. It does not show the capacity of the
manager under other conditions.

## Measurement rules

Each workload runs one manager lifetime unless its section states more.
The measurements of a workload use these rules:

- **Resident memory.** The harness reads the resident size of the manager
  process every 250 milliseconds from the start of the lifetime to its end.
  Each sample is the field `pti_resident_size`, in bytes, that `proc_pidinfo`
  returns for the flavor `PROC_PIDTASKINFO`. This call needs no entitlement
  for a process of the same user. A `ps` without the task-port entitlement
  refuses its `rss` keyword, so the harness does not use `ps`. The sampler
  stops before the harness stops the manager. The peak is the largest
  sample, and the harness refuses a peak when more than one sample in a
  hundred failed. Worker processes are not counted.
- **Latency.** The harness takes `time.monotonic()` before it writes a
  request and after it reads the complete response body. Each credential
  keeps one persistent TLS connection for its ordinary requests. Before a
  request, the harness opens a new connection when the connection has been
  idle for ten seconds, before the 15-second connection timeout of the
  server closes it. The latency of a command does not include the opening
  of a connection. A read that receives 503 `storage-unavailable` or 429
  `storage-quota` is sent again within five seconds, and the latency of a
  named read runs from before its first attempt to the end of the body of
  its answer. The p50 and p95 values use the nearest-rank method: for n
  sorted samples, the q percentile is the sample at position ceil(q n),
  counted from 1.
- **Responsiveness under saturation.** At the saturation point of the
  workload at sixteen, of the queue workload and of the safety path, the
  harness sends one `GET /v1/capabilities` with no further attempt. It must
  answer 200 within 5000 milliseconds, the five-second read budget, timed
  from before the request, including the opening of a connection, to the end
  of its body. A failure ends the mode. The record keeps each time under the
  key `<workload>.capabilities-saturated-ms`, which names no ceiling, so the
  summary lists it as unchecked.
- **Refusals.** A refusal is the HTTP status and the problem `code` of the
  response. Its timing is the latency of that one request.
- **Growth.** File sizes come from `stat` of the regular files under the
  manager root after the lifetime ends, unless the key states another moment.
  The command ledger charge is the `bytes` column of `command_ledger_usage`
  in `coordination.sqlite3`.
- **Mutation rate.** Every workload keeps each credential at no more than
  27 ordinary mutations in one UTC minute, three fewer than the advertised 30.
  More credentials divide the commands of a workload where it needs more. The
  one exception is the credential `S` of the safety path, which reaches the
  rate on purpose.
- **Several lifetimes.** For a workload of more than one lifetime, the
  resident peak is the largest peak of its lifetimes.

## Allowances and headroom

Three allowances apply to every workload:

- **Base resident memory B** is 268435456 bytes. It covers the GHC runtime
  with eight capabilities, the TLS state, the two SQLite caches of 2048 KiB
  each and the idle structures of the manager.
- **Held bytes H** are the bytes that the advertised bounds let the workload
  hold in the manager at one time. A supervised worker counts 2097152 bytes:
  one encoded native control of 1048576 bytes and one runtime protocol frame
  of 1048576 bytes. A capture, a download or a page set counts its bound of
  67108864 bytes, and an SSE reader counts its 1048576 pending bytes.
- **The resident ceiling** is B + 2 H. The factor 2 is the headroom for the
  copying collector of GHC, which can hold two copies of live data during a
  major collection.

The latency ceilings derive from the five-second admission allowance of the
Store and the five-second budget of each read, transaction and write. A p95
ceiling is the full five seconds. A p50 ceiling is one fifth of it for a
command and one tenth of it for a read, so that a median near the allowance
fails before the tail reaches it.

## Common configuration

Every workload starts from the base configuration of
`manager/test/service_http.py`: `drafts` 100, `globalDrafts` 100,
`globalCaptureBytes` 67108864, `globalPageSets` 2, `globalConnections` 8,
`globalDatabaseReaders` 2, `globalMutationLedgerBytes` 16777216,
`safetyControlsPerMinute` 100 and `executionReservations` 1. A workload
section names each value that it changes.

The `capacity-admission` mode of `manager/test/service_http.py` runs the
workloads of the four sections that follow. The two reservation workloads,
the cohort part of the section at sixteen and the queue workload each run in
their own manager lifetime with their own manager root, and the safety path
continues the lifetime of the queue workload. The mode writes the file `capacity-admission.json` in its fixture
directory.

The `capacity-inputs` mode of `manager/test/service_http.py` runs the
workloads of the sections "Drafts", "Page sets", "Captures" and "Artifact
readers", in that order. The drafts workload, the page-set workload and the
capture workload each run in their own manager lifetime with their own
manager root. The artifact readers run below HTTP in the executable
`manager-artifact-check`, which the environment variable `ARTIFACT_CHECK`
of the mode names. The mode writes the file `capacity-inputs.json` in its
fixture directory after each workload.

The capacity profiles are `cap_01` to `cap_20`. Each one names the runner of
`routing-fixed-point-probe` with the target arguments `--scripted`,
`personAnswering` `local-control`, and its own resource key, `cap_key_01` to
`cap_key_20`. A workload uses the profiles that its section names. The
harness issues every credential through local administration before the
workload begins, with the scopes `observe`, `submit` and `control` unless the
section states other scopes. A request runs through four ordinary commands:
create, `set-input`, `enqueue` and `approve`. The literal input of every
request is the ASCII text `capacity` unless the section states another.

## Execution reservations at one

The configuration sets `executionReservations` to 1 and installs the profiles
`cap_01` to `cap_20`. Four credentials create and enqueue 20 requests of the
`delayed-person` workflow, request i on profile `cap_i`, in the order 1 to
20. The first request reaches review, and the others stay queued. The harness
approves each review as it appears, waits until its run waits at its person
question, and answers the question with `true`. The run then succeeds, the
cleanup of its worker releases the reservation, and the next request reaches
review. The harness reads `GET /v1/requests`, `GET /v1/runs` and
`GET /v1/decisions` in rounds, with a pause of 50 milliseconds between
rounds, to find each review, each person question and each terminal run, and
to count the runs that are not terminal. The k-th release-to-review time runs
from the first read that shows the k-th run terminal to the first read that
shows the k-th waiting request in review or later.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `reservations.r1.peak-concurrent-runs` | equals `1` | count | The configured executionReservations of 1. |
| `reservations.r1.fifo-order` | equals `true` | flag | Admission selects the oldest eligible request. |
| `reservations.r1.approve-p50-ms` | at most 1000 | ms | POST of the approval. One fifth of the five-second admission allowance. |
| `reservations.r1.approve-p95-ms` | at most 5000 | ms | POST of the approval. The five-second admission allowance. |
| `reservations.r1.answer-p50-ms` | at most 1000 | ms | POST of the answer. One fifth of the five-second admission allowance. |
| `reservations.r1.answer-p95-ms` | at most 5000 | ms | POST of the answer. The five-second admission allowance. |
| `reservations.r1.release-to-review-p50-ms` | at most 1000 | ms | From the terminal run to the review of the next queued request. One fifth of the five-second admission allowance. |
| `reservations.r1.release-to-review-p95-ms` | at most 5000 | ms | From the terminal run to the review of the next queued request. The five-second admission allowance. |
| `reservations.r1.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Execution reservations at sixteen

The configuration sets `executionReservations` to 16 and installs the
profiles `cap_01` to `cap_20`. Four credentials create and enqueue 20
requests of the `delayed-person` workflow, request i on profile `cap_i`, in
the order 1 to 20. Requests 1 to 16 reach review, and the harness approves
them. When their 16 runs wait at their person questions, the harness reads
the blocking reasons of requests 17 to 20, which hold no resource key in
common with a run, and each of them must name capacity. The harness then
answers the runs in the order 1 to 16, one answer each second, and approves
each later review as it appears. Requests 17 to 20 must reach review in their
queue order. The harness reads the collections as in the workload at one,
and the release-to-review times pair the first four terminal runs with
requests 17 to 20.

After this workload, the mode starts one more lifetime with its own manager
root. It sets `executionReservations` to 16 and installs four cohort profiles
with the runner and target of the capacity profiles. `cap_shared_a` and
`cap_shared_b` share the resource key `cap_key_shared`. `cap_plain_a` and
`cap_plain_b` have no resource key, so they share the unclassified resource.
One credential enqueues one request on `cap_shared_a` and waits for its
review, and then enqueues one on `cap_shared_b`. It does the same for
`cap_plain_a` and `cap_plain_b`. The requests of `cap_shared_b` and
`cap_plain_b` must wait queued with exactly the blocking reason
`profile-busy`. The manager names `capacity` first when no reservation is
free, so this reason also shows a free reservation. The harness then
discards each holding review, and the waiting request of its pair must reach
review without a client command that names it. The harness discards that
review too. This part has no ceiling key.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `reservations.r16.peak-concurrent-runs` | equals `16` | count | The configured executionReservations of 16. |
| `reservations.r16.fifo-order` | equals `true` | flag | Admission selects the oldest eligible request. |
| `reservations.r16.queued-capacity-reason` | equals `true` | flag | A queued request without a free reservation names capacity among its blocking reasons. |
| `reservations.r16.approve-p50-ms` | at most 1000 | ms | POST of the approval. One fifth of the five-second admission allowance. |
| `reservations.r16.approve-p95-ms` | at most 5000 | ms | POST of the approval. The five-second admission allowance. |
| `reservations.r16.answer-p50-ms` | at most 1000 | ms | POST of the answer. One fifth of the five-second admission allowance. |
| `reservations.r16.answer-p95-ms` | at most 5000 | ms | POST of the answer. The five-second admission allowance. |
| `reservations.r16.release-to-review-p50-ms` | at most 1000 | ms | From the terminal run to the review of the next queued request. One fifth of the five-second admission allowance. |
| `reservations.r16.release-to-review-p95-ms` | at most 5000 | ms | From the terminal run to the review of the next queued request. The five-second admission allowance. |
| `reservations.r16.manager-rss-peak-bytes` | at most 335544320 | bytes | B + 2 H, where H is 16 supervised workers of 2097152 bytes each. |

## Queue at one hundred

The configuration sets `globalMutationLedgerBytes` to 67108864 and installs
profile `cap_01`. The ordinary ledger capacity is then (67108864 - 2097152)
div 131072 = 496 commands. One request of the `delayed-person` workflow runs
to its person question and holds the one reservation. Twelve credentials then
create, set the input of and enqueue one request at a time until 100 requests
are queued, so that at most twelve drafts exist at once. A 101st request is
created and given its input, and its enqueue is the refusal under test. The
harness reads the first page of `GET /v1/requests` after each tenth enqueue.
The workload issues 307 ordinary commands, including the refused enqueue.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `queue.accepted-queued` | equals `100` | count | The advertised queue of 100 requests. |
| `queue.refusal-status` | equals `409` | status | The 101st enqueue refuses as a state conflict. |
| `queue.refusal-code` | equals `state-conflict` | code | The 101st enqueue refuses as a state conflict. |
| `queue.refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `queue.mutations-per-credential-minute` | at most 27 | count | The workload keeps three permits of the 30 ordinary mutations per minute in reserve. |
| `queue.enqueue-p50-ms` | at most 1000 | ms | POST of the enqueue. One fifth of the five-second admission allowance. |
| `queue.enqueue-p95-ms` | at most 5000 | ms | POST of the enqueue. The five-second admission allowance. |
| `queue.requests-first-page-p50-ms` | at most 500 | ms | GET of the first page of /v1/requests. One tenth of the five-second read budget. |
| `queue.requests-first-page-p95-ms` | at most 5000 | ms | GET of the first page of /v1/requests. The five-second read budget. |
| `queue.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Safety path

This workload continues the lifetime of the queue workload, with the queue
full and the first run at its person question. A thirteenth credential `S`,
which has not yet issued a command, waits for the start of a UTC minute and
then creates 30 draft requests. Its 31st create in that minute is the refusal under test. In the same
minute, after a read of `GET /v1/requests` shows 100 requests still queued,
`S` sends a whole-run cancel of the first run. The harness then reads the
run until it is cancelled.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `safety.rate-refusal-status` | equals `429` | status | The 31st ordinary mutation of one credential in one UTC minute. |
| `safety.rate-refusal-code` | equals `rate-limit` | code | The 31st ordinary mutation of one credential in one UTC minute. |
| `safety.rate-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `safety.cancel-accepted` | equals `true` | flag | A whole-run cancel uses the separate safety counter and the ledger reserve. |
| `safety.cancel-ms` | at most 5000 | ms | The five-second admission allowance. |
| `safety.cancel-to-cancelled-ms` | at most 10000 | ms | The five-second worker write deadline and one five-second read. |
| `safety.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Drafts

The configuration sets `drafts` to 4 and `globalDrafts` to 10 and installs
profile `cap_01`. Credential `A` creates five draft requests, and its fifth
create is the refusal at the allowance of a client. Credentials `B` and `C`
create three draft requests each, so that ten drafts exist. Credential `D`
then creates one draft request, which is the refusal at the global capacity.
No draft is enqueued.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `drafts.client-accepted` | equals `4` | count | The configured drafts of 4. |
| `drafts.client-refusal-status` | equals `429` | status | A draft beyond the allowance of its client. |
| `drafts.client-refusal-code` | equals `storage-quota` | code | A draft beyond the allowance of its client. |
| `drafts.client-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `drafts.global-accepted` | equals `10` | count | The configured globalDrafts of 10. |
| `drafts.global-refusal-status` | equals `429` | status | A draft beyond the global capacity. |
| `drafts.global-refusal-code` | equals `storage-quota` | code | A draft beyond the global capacity. |
| `drafts.global-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `drafts.create-p50-ms` | at most 1000 | ms | POST of a new request. One fifth of the five-second admission allowance. |
| `drafts.create-p95-ms` | at most 5000 | ms | POST of a new request. The five-second admission allowance. |
| `drafts.manager-rss-peak-bytes` | at most 268435456 | bytes | B + 2 H, where H is 0. |

## Captures

The configuration sets `globalCaptureBytes` to 134217728 and installs profile
`cap_01`. Each capture body is the ASCII text `capacity` repeated and cut to
its length, and each upload is one `POST /v1/captures` with
`application/octet-stream`. Credential `A` creates the draft requests R1, R2
and R3 of the `captured-input` workflow. It uploads 67108864 bytes for R1, then
67108865 bytes for R2, which the bound of one capture refuses, then 67108864
bytes for R2, so that the global capacity is full. It then uploads one byte
for R3, which the global capacity refuses. The root growth overhead is the
growth of the manager root, the database, its WAL and the capture files,
across one accepted upload, minus the 67108864 bytes of the capture.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `captures.max-accepted` | equals `true` | flag | The advertised capture of 67108864 bytes. |
| `captures.oversize-refusal-status` | equals `413` | status | A capture of 67108865 bytes. |
| `captures.oversize-refusal-code` | equals `size-limit` | code | A capture of 67108865 bytes. |
| `captures.oversize-refusal-ms` | at most 60000 | ms | The upload floor of 1118481 bytes per second, which moves 67108864 bytes in 60 seconds. |
| `captures.aggregate-accepted-bytes` | equals `134217728` | bytes | The configured globalCaptureBytes of 134217728. |
| `captures.aggregate-refusal-status` | equals `429` | status | One byte beyond globalCaptureBytes. |
| `captures.aggregate-refusal-code` | equals `storage-quota` | code | One byte beyond globalCaptureBytes. |
| `captures.aggregate-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `captures.upload-max-ms` | at most 60000 | ms | The upload floor of 1118481 bytes per second, which moves 67108864 bytes in 60 seconds. |
| `captures.root-growth-overhead-bytes` | at most 1048576 | bytes | One sixty-fourth of the capture for its rows and WAL frames. |
| `captures.manager-rss-peak-bytes` | at most 402653184 | bytes | B + 2 H, where H is one capture of 67108864 bytes. |

## Artifact readers

The verified result of a program is its receipt, about 103 bytes long, and
one write of the manager answers its download. No HTTP client can hold a
download place long enough to measure the limit of two places. This workload
therefore runs below HTTP, in the command `manager-artifact-check
capacity-readers DIRECTORY`. The check opens its own Store root in the
directory with the base configuration, one credential with the scopes
`observe` and `export`, and one verified source result. Two holders each
start a download of that result through `withArtifactDownloadWithin` with
the total deadline of 300 seconds (`artifactResponseDeadline`). Each holder
charges one artifact response place, returns the loans of its view and keeps
the place. When both holders keep a place, a third download starts. After
the third download ends, the holders send their bodies through
`respondBytes`, and the check compares the size and the SHA-256 digest of
each body with the artifact metadata. The status and the code of the third
download are the public problem of its refusal, from `faultProblem`. Its
wait runs from before its start to its refusal. The check prints the
measured values on one line that starts with `CAPACITY-READERS`. The check
process holds the Store, so the harness samples its resident memory under
the rules for the manager.

This workload and the basis of its ceilings are a correction that was made
before any readers measurement ran. The first form of the workload read the
result of a `prompt-source` run through two slow HTTP clients, and it could
not hold a place because that result is a receipt. The correction keeps the
values of the ceilings, except that H of `readers.manager-rss-peak-bytes` no
longer counts a capture, because the readers no longer continue the lifetime
of the capture workload. That ceiling is now 536870912 bytes in place of
671088640 bytes.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `readers.holders-accepted` | equals `2` | count | Two artifact response places for each Store. |
| `readers.holders-verified` | equals `true` | flag | A download returns exact verified bytes. |
| `readers.third-refusal-status` | equals `429` | status | The public problem of a third download while both places are held. |
| `readers.third-refusal-code` | equals `storage-quota` | code | The public problem of a third download while both places are held. |
| `readers.third-wait-ms` | 5000 to 6000 | ms | The five-second place wait and one second for the refusal. |
| `readers.manager-rss-peak-bytes` | at most 536870912 | bytes | B + 2 H, where H is two downloads of 67108864 bytes each. |

## Page sets

The configuration sets `globalPageSets` to 8 and binds a local retention root
with `--legacy-history`, as the `pages` mode does. Before the manager starts,
one local frontend run writes one completed run into the root, and copies of
that run under new run identifiers fill it to 4096 entries, so that `/v1/runs`
spans four windows of 1024 members and each set has more than one page. Five
observe credentials `P1` to `P5` read the first page of `GET /v1/runs`:

1. `P1` opens two sets, A at time t0 and B. A third first page of `P1` is the
   refusal at the client bound.
2. `P2`, `P3` and `P4` open two sets each, so that eight sets are held. A
   first page of `P5` is the refusal at the global bound.
3. Fifty-eight seconds after the first page of set A, `P1` follows the
   `next` token of set A. Sixty-one seconds after the first page of set B, it
   follows the `next` token of set B.
4. When every set has expired, `P5` reads a first page again and then follows
   every page of that set to its end.

The set bytes are the largest sum of the body bytes of the pages of one
window of the set that `P5` reads in step 4.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `pages.held-sets` | equals `8` | count | The configured globalPageSets of 8. |
| `pages.client-refusal-status` | equals `429` | status | A third set of one client. |
| `pages.client-refusal-code` | equals `storage-quota` | code | A third set of one client. |
| `pages.client-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `pages.global-refusal-status` | equals `429` | status | A ninth set while eight sets are held. |
| `pages.global-refusal-code` | equals `storage-quota` | code | A ninth set while eight sets are held. |
| `pages.global-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `pages.continuation-before-expiry-status` | equals `200` | status | A continuation 58 seconds after the first page, within the 60-second lifetime. |
| `pages.expired-continuation-status` | equals `410` | status | A continuation 61 seconds after the first page. |
| `pages.expired-continuation-code` | equals `view-expired` | code | A continuation 61 seconds after the first page. |
| `pages.first-page-after-expiry-status` | equals `200` | status | Expiry returns the capacity of the set. |
| `pages.set-bytes-max` | at most 67108864 | bytes | The advertised page-set bound. |
| `pages.first-page-p50-ms` | at most 500 | ms | GET of the first page of /v1/runs. One tenth of the five-second read budget. |
| `pages.first-page-p95-ms` | at most 5000 | ms | GET of the first page of /v1/runs. The five-second read budget. |
| `pages.manager-rss-peak-bytes` | at most 1342177280 | bytes | B + 2 H, where H is eight sets of 67108864 bytes each. |

## Event flood

The configuration sets `executionReservations` to 16 and
`globalMutationLedgerBytes` to 67108864 and installs the profiles `cap_01` to
`cap_16`. One observe credential `E0` reads `GET /v1/snapshot` and then polls
`GET /v1/events` with `Accept: application/json` every 250 milliseconds.
Three observe credentials `E1`, `E2` and `E3` each open two SSE readers of
`/v1/events` at the cursor of that snapshot, which is six readers in all.
Five credentials submit and approve the work: one request of the
`delayed-person` workflow on `cap_16`, which waits at its person question as
the independent worker of the next section, and then two rounds of 15
requests of the `prompt-source` workflow on `cap_01` to `cap_15`, which run
to success without an answer. The second round starts when every run of the
first round is terminal. The catch-up time of an event at an SSE reader runs
from the first arrival of that event at any reader to its arrival at that
reader. The catch-up samples leave out the second SSE reader of `E1` during
the second round, because the next section stops it. The harness also records
the events per second that `E0` receives during each round.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `events.reader-complete` | equals `true` | flag | Each reader receives each event of its view once and in order. |
| `events.catch-up-p50-ms` | at most 1000 | ms | From the terminal event at the polling reader to that event at each SSE reader. One fifth of the five-second write deadline. |
| `events.catch-up-p95-ms` | at most 5000 | ms | From the terminal event at the polling reader to that event at each SSE reader. The five-second write deadline. |
| `events.manager-rss-peak-bytes` | at most 348127232 | bytes | B + 2 H, where H is 16 supervised workers of 2097152 bytes each and six readers of 1048576 pending bytes each. |

## Slow consumer

This workload runs inside the event flood. The second SSE reader of `E1` opens
its connection with a receive buffer (`SO_RCVBUF`) of 4096 bytes. When the
second round starts, it stops reading. While it is stopped, the harness
answers the person question of the independent run on `cap_16` with `true`
through its own credential, and that run must succeed. When the second round
and the independent run are terminal, the stopped reader reads again. If its
stream ended, it reconnects with `Last-Event-ID` set to the identifier of its
last complete block. The pending bytes are the bytes that the stopped reader
reads from its stopped connection after it reads again. The harness also
records the bytes that the first SSE reader of `E1` received while the second
reader was stopped, so that a reader of the evidence can see how close the
stall came to its bound.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `slow.pending-bytes-max` | at most 1048576 | bytes | The advertised 1048576 pending transport bytes for each reader. |
| `slow.no-loss` | equals `true` | flag | A resumed or reconnected reader receives every later event once. |
| `slow.independent-run-succeeded` | equals `true` | flag | A slow reader does not impede an independent worker. |
| `slow.independent-answer-ms` | at most 5000 | ms | The five-second admission allowance. |
| `slow.manager-rss-peak-bytes` | at most 348127232 | bytes | B + 2 H, with H as in the event flood. |

## Growth

The growth keys use the lifetimes of the workloads above. The run log of a
run is its file `flow.ndjson` and its claim-check files `flow-claims` in its
run store, and the run-log key is the largest run log of the runs of the
sixteen-reservation workload and of the event flood. The manager log is every
file under `flow` in the manager root, and the manager-log key is its growth
across the queue workload divided by the number of accepted ordinary commands
of that workload. The ledger key is the growth of the ledger charge across one
accepted ordinary command. The WAL key is the growth of
`coordination.sqlite3-wal` across the queue workload, read while the manager
serves, divided by the same number of commands. The serving manager schedules
no checkpoint, and automatic checkpointing is disabled, so the WAL grows with
each commit until the Store closes. The after-close key is the size of that
file after the ordinary shutdown of the queue lifetime, when SQLite has
checkpointed the WAL at the close of its last connection. An absent file
counts as 0 bytes.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `growth.run-log-bytes-per-run` | at most 1048576 | bytes | No advertised bound. The JSON page bound of 1048576 bytes. |
| `growth.manager-log-bytes-per-command` | at most 131072 | bytes | The logical ledger charge C of one command, which the log shares with the ledger. |
| `growth.ledger-bytes-per-command` | equals `131072` | bytes | The logical ledger charge C of one command. |
| `growth.wal-bytes-per-command` | at most 524288 | bytes | No advertised bound. Four times C, for the receipt, acknowledgement and effect transactions and their events. |
| `growth.wal-bytes-after-close` | equals `0` | bytes | SQLite checkpoints the WAL and removes it when the last connection closes. |

## Storage endings

The `storage` mode of `manager/test/service_http.py` supplies these values
through measurement prints. Its case 1 sets `globalMutationLedgerBytes` to
R + 4 C = 2621440, so that the four commands of one run fill the ordinary
capacity. The next ordinary command is the ledger refusal, and a cancel of the
run is then accepted. Its case 2 raises the ceiling to 16777216 and renames the
active manager log away while a run waits at its question. The next ordinary
command is the append refusal, and a cancel of the run is then accepted.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `storage.ledger-refusal-status` | equals `429` | status | An ordinary command at the ledger ceiling L minus R. |
| `storage.ledger-refusal-code` | equals `storage-quota` | code | An ordinary command at the ledger ceiling L minus R. |
| `storage.ledger-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `storage.ledger-cancel-accepted` | equals `true` | flag | A cancel may use the reserve R. |
| `storage.append-refusal-status` | equals `503` | status | An ordinary command whose manager-log append fails. |
| `storage.append-refusal-code` | equals `storage-unavailable` | code | An ordinary command whose manager-log append fails. |
| `storage.append-refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `storage.append-cancel-accepted` | equals `true` | flag | A cancel ends the run while appends fail. |
| `storage.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Seal and prune cursors

The `routes` mode supplies these values through measurement prints. Its case
12 seals the manager log of the first lifetime and resumes a cursor of that
lifetime across the seal. Its case 13 seals the second lifetime, removes the
oldest segment as the pruner removes it, and reads the floor and the cursors
below it. The batch latency covers every `GET /v1/routes` JSON batch of the
mode.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `routes.seal-resume` | equals `true` | flag | A cursor of the first lifetime resumes across a seal. |
| `routes.prune-floor` | equals `true` | flag | After a prune the floor is the start of the oldest remaining segment. |
| `routes.below-floor-status` | equals `410` | status | A cursor below the retained floor. |
| `routes.below-floor-code` | equals `cursor-expired` | code | A cursor below the retained floor. |
| `routes.batch-p50-ms` | at most 500 | ms | GET of one JSON batch of /v1/routes. One tenth of the five-second read budget. |
| `routes.batch-p95-ms` | at most 5000 | ms | GET of one JSON batch of /v1/routes. The five-second read budget. |
| `routes.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Disk and I/O failure

The configuration installs profile `cap_01`. The first lifetime runs one
request of the `prompt-source` workflow to success and then ends with an
ordinary shutdown. The harness reads the size S of the largest
regular file under the manager root. The second lifetime starts on the same
root with the file-size limit `RLIMIT_FSIZE` of the manager process set to
S + 1048576 bytes and with `SIGXFSZ` ignored, both in the child before it
executes the manager, so that a write past the limit fails with `EFBIG`.
Worker processes inherit the limit. Two credentials then alternate a create
and a `set-input` with a literal of 65536 ASCII bytes until the first refusal
or 100 commands. The harness then stops the manager, and a third lifetime
starts without the limit. The reopen key holds when that lifetime serves
`GET /v1/capabilities` and the flow verb verifies its manager log.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `disk.refusal-status` | equals `503` | status | A definite write failure of the Store or of the manager log. |
| `disk.refusal-code` | equals `storage-unavailable` | code | A definite write failure of the Store or of the manager log. |
| `disk.refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `disk.no-receipt` | equals `true` | flag | A refused command leaves no command row. |
| `disk.reopen-verified` | equals `true` | flag | The next lifetime without the limit opens the Store and the flow verb verifies the log. |
| `disk.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Failure modes

The failure keys come from existing modes, run once each at N8 with
measurement prints:

- `failures-worker` of `manager/test/service_http.py`. The lost time runs
  from the SIGKILL of the worker process groups to the first read that shows
  the run with lost supervision.
- `failures-manager`. The restart time runs from the start of the second
  manager lifetime to its first 200 response of `GET /v1/capabilities`.
- `failures-launched`. The release time runs from the reply of the accepted
  `release-quarantine` to the first read that shows the queued request in
  review.
- `tui-failures`, with its `DelayForwarder`. The unreachable time is the
  elapsed time of its step 2, from the SIGKILL of the manager to the header
  that shows the unreachable state, and the reconnect time is the elapsed
  time of its step 3, from the start of the new lifetime to the end of that
  state.
- The `restart-interruption` case of `manager-admission-check`, run as
  `manager-admission-check restart-interruption WORK NATIVE +RTS -N8`. It
  takes an offline backup, cancels the restoration from that backup after its
  durable `restore-in-progress` marker, and requires that ordinary Store
  startup then refuses. It runs no manager process, so it has no resident
  key.

The `failures-worker` mode also covers the loss of the private worker pipes,
because the SIGKILL of the worker process groups closes them.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `failures.worker.passed` | equals `true` | flag | Every numbered case of failures-worker passes. |
| `failures.worker.lost-ms` | at most 10000 | ms | The five-second worker write deadline and one five-second read. |
| `failures.worker.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |
| `failures.manager.passed` | equals `true` | flag | Every numbered case of failures-manager passes. |
| `failures.manager.restart-ready-ms` | at most 30000 | ms | The 30-second reconnect backoff cap of a client. |
| `failures.manager.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |
| `failures.launched.passed` | equals `true` | flag | Every numbered case of failures-launched passes. |
| `failures.launched.release-to-review-ms` | at most 5000 | ms | The five-second admission allowance. |
| `failures.launched.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |
| `failures.tui.passed` | equals `true` | flag | Every numbered step of tui-failures passes. |
| `failures.tui.unreachable-ms` | at most 50000 | ms | The 45-second reconnect idle limit and five seconds of headroom. |
| `failures.tui.reconnect-ms` | at most 35000 | ms | The 30-second backoff cap and five seconds of headroom. |
| `failures.tui.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |
| `failures.backup.passed` | equals `true` | flag | The restart-interruption case of manager-admission-check passes. |

## Bounds outside these workloads

These workloads measure the queue, the execution reservations, the drafts,
the captures, the artifact readers, the page sets, the SSE readers and their
pending bytes, the mutation rate, the safety controls and the mutation ledger.
The other advertised bounds stay with their existing checks and are not
capacity ceilings here: the request target, the request headers, the JSON
body and depth, the encoded native control, the SSE block, the JSON page, the
route batch, the live collection, the prepared review lifetime, replay
retention, client liveness, `globalConnections` and `globalDatabaseReaders`.
Hostile and slow input, malformed frames, the framing-limit negatives of the
`boundary` mode and the replacement of the manager root under a running
manager belong to the later security stage.

## The summary tool

`python3 manager/test/capacity_summary.py ceilings JSON DOCUMENT` reads the
ceiling tables of this document, which are the tables with the columns Key,
Ceiling, Unit and Basis. It fails when a key of the JSON has no row, when a
row has no key in the JSON, or when the ceiling or the unit of a row differs
from the JSON.

`python3 manager/test/capacity_summary.py summary JSON MEASUREMENTS...` reads
one or more measurement files. Each file is one JSON object whose members map
a ceiling key to a number, a string or a boolean, and two files may not give
one key different values. The command prints one line for each ceiling key in
key order: `PASS` or `FAIL` with the measured value, or `MISSING` when no file
gives the key. It prints `UNCHECKED` for a measured key that names no
ceiling, such as the events per second of the flood. It exits 1 when a key
fails or is missing, and 2 when an input file does not have this form.

A ceiling of the form "at most N" holds when the measured number is N or
less, "at least N" when it is N or more, "N to M" when it lies between N and M
inclusive, and "equals" when the measured value has the same type and value.
