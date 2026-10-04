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
  `storage-quota` is sent again within five seconds. A read whose
  connection closes with no response, or closes after a part of the body,
  is sent again within 30 seconds. The manager closes the connection in
  this way when the check of the view at response entry, or the check
  before a later 16 KiB write of the body, meets the Store allowance after
  the response has started.
  The latency of a named read runs from before its first attempt to the end
  of the body of its answer. The p50 and p95 values use the nearest-rank method: for n
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
- **Host load.** A run of record starts with a one-minute load average of
  at most 16, which is half of the 32 logical processors of the tested
  platform, and with no other manager process on the host. Before the start
  of each workload, the harness waits at most 600 seconds for the one-minute
  load average to fall to 16. It reads the load every 15 seconds and prints
  one `LOAD-WAIT` line for each reading above 16. It keeps the duration of
  the wait in milliseconds under the key `<workload>.host-load-wait-ms`. A
  load that stays above 16 does not stop the workload. The harness reads
  `os.getloadavg()` at the start and at the end of each workload. It keeps
  the one-minute and five-minute load averages under the keys
  `<workload>.host-load-1m-start`, `<workload>.host-load-1m-end`,
  `<workload>.host-load-5m-start` and `<workload>.host-load-5m-end`. At the
  start, it also counts the `--manager serve` processes whose configuration
  is not the configuration of its fixture. It keeps the count under the key
  `<workload>.other-managers-start` and their command lines in the file
  `other-managers-<workload>.txt` of the fixture directory. In a capacity
  mode, `<workload>` is the name of one lifetime: `reservations.r1`,
  `reservations.r16`, `cohorts`, `queue`, `drafts`, `pages`, `captures`,
  `streams`, `io-1`, `io-2` or `io-3`. In the storage, routes and failure
  modes, it is the key prefix of the mode: `storage`, `routes`,
  `failures.worker`, `failures.manager`, `failures.launched` or
  `failures.tui`. In the `failures-backup` mode, it is the name of one serve
  lifetime: `bk-setup`, `bk-case-1`, `bk-case-2`, `bk-other` or
  `bk-restored`. The `capacity-inputs` mode also keeps the duration of the
  setup of its legacy runs, which comes before the `pages` lifetime, under
  the key `pages.legacy-setup-ms`, and the one-minute load average before and
  after that setup under the keys `pages.legacy-setup-load-1m-start` and
  `pages.legacy-setup-load-1m-end`. These keys name no ceiling, so the
  summary lists them as unchecked. A run outside the rule keeps its record
  with its load, and it is not a run of record. The rule states the conditions of a measurement.
  It sets no ceiling.
- **Cleanup.** The harness stops each manager process that it started when
  the mode ends, also when the mode fails or receives SIGTERM. It sends
  SIGTERM, waits at most 25 seconds and then sends SIGKILL. A failed mode
  leaves no manager process of its fixture.

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

The `capacity-streams` mode of `manager/test/service_http.py` runs the
workloads of the sections "Event flood", "Slow consumer" and "Growth" in one
manager lifetime with its own manager root. It writes the file
`capacity-streams.json` in its fixture directory, the file
`capacity-streams-arrivals.json` with the lag of each event at each reader,
and the file `capacity-streams-run-logs.json` with the run-log bytes of each
run store. The `storage` and `routes` modes write the files
`storage-measure.json` and `routes-measure.json` in their fixture
directories, as the sections "Storage endings" and "Seal and prune cursors"
state. The `faults-io` mode writes the file `faults-io.json`, and the five
failure modes write their files `<mode>-measure.json`, as the sections "Disk
and I/O failure" and "Failure modes" state.

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

The safety path holds only while the Store can write. The separate safety
counter and the ledger reserve admit a cancel when ordinary commands refuse
with `rate-limit` or `storage-quota`. They do not admit a cancel after a disk
write failure. The first definite write failure, such as `EFBIG` under a
file-size limit, stops the Store for the rest of the lifetime, and every
later command and read of that lifetime refuses with 503
`storage-unavailable`, a whole-run cancel and a withdrawal included, until a
restart. The [disk and I/O failure](#disk-and-io-failure) workload shows this
behavior for `GET /v1/capabilities` and for the withdrawal of a queued
request, and [STORAGE.md](STORAGE.md#internal-transactions-and-bounds) states
it for every command and read.

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

The configuration sets `executionReservations` to 16,
`globalMutationLedgerBytes` to 67108864 and `globalConnections` to 16, and
installs the profiles `cap_01` to `cap_16`. The six SSE readers hold six
connections for the whole workload, so the base value of 8 would leave two
connections for the other eight credentials. The four credentials `E0`,
`E1`, `E2` and `E3` hold `observe` and `control`, so that each manager-log
record of their profiles is in their view. Each reads `GET /v1/snapshot`
before any request exists, and the four cursors name one durable position.
`E0` then polls `GET /v1/events` with `Accept: application/json` every 250
milliseconds. Each of `E1`, `E2` and `E3` opens two SSE readers, the limit
of two for each client. The first is an event reader of `/v1/events` at the
cursor of its own snapshot, because a cursor names the stream of its
credential. The second is a route reader at the floor of its route stream:
`E1` and `E2` read `/v1/routes`, and `E3` reads `/v1/runs/{id}/routes` of
the independent run. Each SSE reader decodes the chunks of the HTTP/1.1
response itself, and when its stream ends it connects again with
`Last-Event-ID` set to the identifier of its last complete block.

Five credentials submit and approve the work: one request of the
`delayed-person` workflow on `cap_16`, which waits at its person question as
the independent worker of the next section, then two rounds of 15 requests
of the `prompt-source` workflow on `cap_01` to `cap_15`, and then the burst
round of the next section. Each of the five creates, supplies and enqueues
three requests of a round and approves their reviews. A round starts when
every run of the round before it is terminal. Before the burst round, the
harness waits for the next UTC minute when a credential would otherwise send
more than 27 ordinary mutations in the current one. While a round runs, the
harness reads the request and run pages twice a second, because each read
holds the configuration guard and one of the two reader places. These
status reads and the polls of `E0` send a refused read again within 60
seconds in place of five, because the burst round saturates the read path.
An approval whose connection closes with no response is not sent again, and
the harness counts it.

Each event reader must hold the events of `E0` once and in order. Each route
reader must hold, once and in order, the records that the JSON batches of
its route give to its credential from the floor, read after the burst round.
A record of more than one block, such as the review of a burst request,
arrives as its size notice. The catch-up time of an event at an event reader
runs from the first arrival of that event at any reader, `E0` included, to
its arrival at that reader. The catch-up samples are those of the three event
readers. They leave out each arrival at the event reader of `E1` after the
next section stops it.

The harness also records these values, which name no ceiling: the events per
second that `E0` receives during each round
(`events.round1-per-second`, `events.round2-per-second` and
`events.burst-per-second`), the number of events of the view
(`events.count`), the reconnections of the SSE readers
(`events.reconnects`), the records and the transport bytes of each route
reader (`events.route.<reader>.records` and `events.route.<reader>.bytes`),
the reads and stream registrations whose connection closed with no response
or after a part of the body (`events.dropped-reads`), the refusals of reads
that the harness sent again (`events.refused-reads`), the slowest poll of
`E0` and the UTC time of its start (`events.poll-slowest-ms` and
`events.poll-slowest-at`), the approvals
whose connection closed with no response (`events.uncertain-approvals`), the
largest number of ordinary mutations of one credential in one UTC minute
(`events.mutations-per-credential-minute`), the p50 and p95 of the catch-up
time at each event reader (`events.reader.<reader>.catch-up-p50-ms` and
`-p95-ms`), and the p50 and p95 of the delivery time
(`events.delivery-p50-ms` and `-p95-ms`). The delivery time runs from the
`at` field of the last record of the run log of a run, its terminal event, to
the arrival of the last `run.changed` invalidation of that run at an event
reader, with the same samples left out. The harness also splits both times
into the two rounds and the burst round (`events.rounds.catch-up-p50-ms`,
`events.burst.catch-up-p50-ms` and the other keys of the same form). An
event belongs to the burst round when its first arrival comes after the stop
of the next section, and a delivery sample belongs to it when its run is a
burst run or the independent run, which ends during it. The ceiling keys use
every sample.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `events.reader-complete` | equals `true` | flag | Each reader receives each event or record of its view once and in order. |
| `events.catch-up-p50-ms` | at most 1000 | ms | From the first arrival of an event at any reader to its arrival at each event reader. One fifth of the five-second write deadline. |
| `events.catch-up-p95-ms` | at most 5000 | ms | From the first arrival of an event at any reader to its arrival at each event reader. The five-second write deadline. |
| `events.manager-rss-peak-bytes` | at most 348127232 | bytes | B + 2 H, where H is 16 supervised workers of 2097152 bytes each and six readers of 1048576 pending bytes each. |

The owner of the read path decided on 2026-10-03 to change the manager and
to keep the workload, the configuration of the mode and every ceiling. An
ingestion continues the projection of its run that the Store holds, and a
revalidation reads the authorization facts again only after a commit that
changed them, or after one second. The section
[Read path decision of 2026-10-03](#read-path-decision-of-2026-10-03) gives
the cause, the change and the values before and after it.

## Slow consumer

This workload runs inside the event flood. The event reader of `E1` opens its
connection with a receive buffer (`SO_RCVBUF`) of 4096 bytes. After the
second round it stops reading, and the burst round runs: 15 requests of the
`event-burst` workflow on `cap_01` to `cap_15`. That workflow of
`routing-fixed-point-probe` asks its model 64 times, so each of its runs
appends many runtime envelopes, and the manager publishes many invalidations
for four commands. The event reader of `E2`, of the same view, must receive
more than 1048576 bytes while the reader of `E1` is stopped, so that the
stopped stream receives more than the advertised bound. While it is stopped,
the harness answers the person question of the independent run on `cap_16`
with `true` through its own credential, and that run must succeed. When the
burst round and the independent run are terminal, the stopped reader reads
again. If its stream ended, it reconnects with `Last-Event-ID` set to the
identifier of its last complete block, and it must then hold every event of
`E0` once and in order.

The manager bounds the stopped stream in this way. It writes each batch in
writes of at most 16384 bytes, and the writes of one batch must complete
within five seconds. When the socket buffers of the stopped connection are
full, a write cannot complete, and the manager ends the stream at that
deadline. The pending bytes are the bytes of the response body, chunk framing
included, that the stopped reader reads from its stopped connection after it
reads again, until that connection ends or stays silent for one second. The
harness also records these values, which name no ceiling: the bytes that the
event reader of `E2` received while the reader of `E1` was stopped
(`slow.peer-bytes-while-stopped`), whether the manager ended the stopped
stream (`slow.stream-ended`), the reconnections of the stopped reader after
it reads again (`slow.reconnects-after-stop`), the length of the stop
(`slow.stopped-ms`), the bytes that the stopped reader had received before it
stopped (`slow.stopped-bytes-before`), the largest run log of the burst runs
(`slow.burst-run-log-bytes-max`), the time from the accepted answer to the
first status read that shows the terminal status of the independent run
(`slow.independent-terminal-ms`), whether a status read of the burst round
showed it (`slow.independent-terminal-in-round`), and the time from the
accepted answer to the `at` field of the terminal event of its run log
(`slow.independent-runtime-terminal-ms`). The status reads of the burst round
come twice a second and also watch the independent run, so the terminal key
has a resolution of about 500 ms. When no read of the round shows the
terminal status, the reads after the round give the key. The independent
answer is the latency of its command, and the independent run must end
succeeded.

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `slow.pending-bytes-max` | at most 1048576 | bytes | The advertised 1048576 pending transport bytes for each reader. |
| `slow.no-loss` | equals `true` | flag | A resumed or reconnected reader receives every later event once. |
| `slow.independent-run-succeeded` | equals `true` | flag | A slow reader does not impede an independent worker. |
| `slow.independent-answer-ms` | at most 5000 | ms | The five-second admission allowance. |
| `slow.manager-rss-peak-bytes` | at most 348127232 | bytes | B + 2 H, with H as in the event flood. |

## Growth

The growth keys use the lifetime of the event flood, which the
`capacity-streams` mode measures. The span of a growth key runs from after
the readers attach, before the request of the independent run, to the end of
the second round, while the manager serves. The burst round comes after the
span. Its commands are the rows that the span adds to the table `commands` of
`coordination.sqlite3`. The run log of a run is its file `flow.ndjson` and
its claim-check files `flow-claims` in its run store, and the run-log key is
the largest run log of the 31 runs of the two rounds and the independent run,
read after the lifetime ends. The manager log is every file under `flow` in
the manager root, and the manager-log key is its growth across the span
divided by the commands of the span. The ledger key is the growth of the
ledger charge across the span divided by the same commands. The WAL key is
the growth of `coordination.sqlite3-wal` across the span, divided by the same
commands. The serving manager schedules no checkpoint, and automatic
checkpointing is disabled, so the WAL grows with each commit until the Store
closes. The after-close key is the size of that file after the ordinary
shutdown of the lifetime, when SQLite has checkpointed the WAL at the close
of its last connection. An absent file counts as 0 bytes. The harness also
records the commands of the span (`growth.commands`) and the size of the WAL
at the end of the span (`growth.wal-bytes-serving`), which name no ceiling.

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
command is the append refusal, and a cancel of the run is then accepted. The
mode sends its ordinary commands and its cancels on one persistent
connection, samples the resident memory of each of its four lifetimes, and
prints one `MEASURE` line for each value. It writes the values to
`storage-measure.json`, with these values that name no ceiling: the ledger
charge at the refusal (`storage.ledger-bytes-at-ceiling`) and the latency of
each cancel (`storage.ledger-cancel-ms` and `storage.append-cancel-ms`). The
prints change no assertion of the mode.

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
mode that answers 200. Each batch uses a new connection, and its latency
leaves out the opening of that connection. The mode samples the resident
memory of each of its five lifetimes and prints one `MEASURE` line for each
value. It writes the values to `routes-measure.json`, with these values that
name no ceiling: the position at which the first seal starts the new active
file (`routes.seal-position`), the position of the create command after the
seal (`routes.create-after-seal-position`), the floor after the prune
(`routes.prune-floor-position`), the records of the second sealed segment
(`routes.second-segment-records`) and the number of batches
(`routes.batches`). The prints change no assertion of the mode.

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

The `faults-io` mode of `manager/test/service_http.py` runs this workload in
three lifetimes on the manager root of its fixture. The configuration
installs profile `cap_01` and sets `globalMutationLedgerBytes` to 67108864,
so that the command ledger does not refuse first.

The first lifetime runs two requests of the `prompt-source` workflow to
success. A `delayed-person` run then holds the one execution reservation at
its person question, and a second `delayed-person` request waits queued with
the reason `capacity`. The harness kills the manager with SIGKILL and waits
until no process of the worker groups remains. The restart therefore
quarantines the reservation of the lost run, and the queued request waits
with no worker. An ordinary shutdown releases the reservation, and the
restart would then prepare a review of the queued request with a new worker.

The harness reads the size S of the largest of the coordination database,
its WAL and the active manager log. The second lifetime starts on the same
root with the file-size limit `RLIMIT_FSIZE` of the manager process set to
S + 1048576 bytes and with `SIGXFSZ` ignored, both in the child before it
executes the manager, so that a write past the limit fails with `EFBIG`.
Worker processes inherit the limit, so the harness sends no approval and no
start in this lifetime. Four credentials then alternate a create of a
`prompt-source` draft and a `set-input` of that draft with a literal of 65536
ASCII bytes, until the first refusal or 100 commands. The refused command
must leave no command row, and the same command with a new idempotency key
must refuse in the same way. The harness then reads `GET /v1/capabilities`,
`/v1/requests`, the queued request and `/v1/runs`, and each read must answer
200 or refuse with 503 `storage-unavailable` or 429 `storage-quota`. It sends
the `withdraw` of the queued request, which is the control that the manager
offers for a request without a start. The withdraw must be accepted with its
command row or refused with 503 `storage-unavailable` and no row. The queued
request must have no review, and the runs and their run directories must not
change.

The harness then stops the manager, and a third lifetime starts without the
limit. Its command rows must equal the rows at the end of the second
lifetime, so that no command executes again, and no refused command may have
a row. It must serve every accepted draft, show the queued request withdrawn
exactly when the withdraw was accepted, and show the run of the first
lifetime with lost supervision. The reopen key holds when that lifetime
serves `GET /v1/capabilities` and, after its ordinary end, the flow verb
verifies its manager log.

The mode writes the file `faults-io.json` in its fixture directory, with
these values that name no ceiling: the size S (`disk.largest-file-bytes`),
the limit (`disk.limit-bytes`), the commands accepted before the refusal
(`disk.accepted-commands`), the outcome and latency of the withdraw
(`disk.withdraw-accepted` and `disk.withdraw-ms`) and whether the runs stayed
unchanged (`disk.no-run-started`).

| Key | Ceiling | Unit | Basis |
| --- | --- | --- | --- |
| `disk.refusal-status` | equals `503` | status | A definite write failure of the Store or of the manager log. |
| `disk.refusal-code` | equals `storage-unavailable` | code | A definite write failure of the Store or of the manager log. |
| `disk.refusal-ms` | at most 5000 | ms | A refusal is decided inside one admission allowance of five seconds. |
| `disk.no-receipt` | equals `true` | flag | A refused command leaves no command row. |
| `disk.reopen-verified` | equals `true` | flag | The next lifetime without the limit opens the Store and the flow verb verifies the log. |
| `disk.manager-rss-peak-bytes` | at most 272629760 | bytes | B + 2 H, where H is one supervised worker of 2097152 bytes. |

## Failure modes

The failure keys come from five modes, run once each at N8 with
measurement prints. Each mode prints one `MEASURE` line for each value and
writes the values to the file `<mode>-measure.json` in its fixture
directory. The four modes other than `failures-backup` also sample the
resident memory of each of their lifetimes. The `passed` key of a mode is
written after its last PASS line. The prints change no assertion of a mode.

- `failures-worker` of `manager/test/service_http.py`. The lost time runs
  from the SIGKILL of the worker process groups to the first read that shows
  the run with lost supervision.
- `failures-manager`. The restart time runs from the start of the second
  manager lifetime to its first 200 response of `GET /v1/capabilities`. The
  mode also records the release time of its cases 7 and 9
  (`failures.manager.release-7-to-review-ms` and
  `failures.manager.release-9-to-review-ms`), which name no ceiling.
- `failures-launched`. The release time runs from the reply of the accepted
  `release-quarantine` to the first read that shows the queued request in
  review.
- `tui-failures`, with its `DelayForwarder`. The unreachable time is the
  elapsed time of its step 2, from the SIGKILL of the manager to the header
  that shows the unreachable state, and the reconnect time runs from the
  start of the new lifetime in its step 3 to the end of that state. The mode
  also records two times of the delayed refresh of its step 8, which name no
  ceiling: from the `g` key that starts the overview read through the
  forwarder to the switch to the direct profile
  (`failures.tui.delayed-switch-ms`), and from that switch to the Manager
  overview of the direct endpoint (`failures.tui.direct-overview-ms`).
- `failures-backup` of `manager/test/service_http.py`. It runs local
  administration through `agentic-run --manager admin` with the offline
  configuration on a disposable manager root. A first lifetime creates one
  captured-input draft with a capture of 67108864 bytes and stops. Offline
  `status` then reports the state `stopped`, and its answer is the fencing
  evidence. The mode sets a file-size limit (`RLIMIT_FSIZE`, with `SIGXFSZ`
  ignored) above the largest of the database and its WAL and below the
  capture size. Case 1, the case of record, runs a backup under that limit:
  the database copy completes, and the copy of the capture fails with EFBIG.
  Case 2 stops a backup with SIGKILL while the temporary file of its capture
  copy exists. After each case, the backup refused with `storage-unavailable`
  or was killed, the destination holds no completion binding, a restore that
  names it refuses with `storage-unavailable` and leaves no
  `restore-in-progress` marker, the rows and the other files of the Store are
  unchanged, `check-store` reports `valid`, offline `status` reports the same
  authority epoch and stream identity, the next serve lifetime serves the
  draft, and a backup without the limit into a new destination completes.
  Case 3 stops a restoration from a complete backup with SIGKILL as soon as
  its `restore-in-progress` marker exists. The restoration verifies the
  capture of the root and that of the backup after the marker, so the
  capture of 67108864 bytes keeps the window open. Ordinary `serve` then
  exits with status 2, writes "manager service is unavailable" to
  standard error and serves no port. Offline `status` refuses with
  `storage-unavailable`, `check-store` reports `unavailable`, and the marker
  remains. Before the kill, a lifetime creates one more draft, and a backup
  of that Store is the other backup. On the fenced root, a restoration from
  the other backup and a restoration with fencing evidence of another
  authority epoch refuse with `state-conflict` and leave the marker bytes.
  The same restoration then completes: it answers new identities and
  removes the marker, `check-store` reports `valid`, and offline `status`
  reports the new identities. The next `serve` lifetime issues a new
  credential, which reads the draft of case 0, lists the requests without
  the draft of the other backup, and runs a new `prompt-source` request to
  success. When the kill
  of case 2 or case 3 lands outside its window, the case prints "not
  reached" and does not count. The mode writes the file
  `failures-backup-measure.json` with `failures.backup.passed` `true` after
  the PASS line of case 1 and a PASS or "not reached" line for cases 2 and
  3. It also writes values that name no ceiling: the capture size
  (`failures.backup.capture-bytes`), the largest database file
  (`failures.backup.largest-file-bytes`), the limit
  (`failures.backup.limit-bytes`), the code and latency of the refusal of
  case 1 (`failures.backup.limited-code` and `failures.backup.limited-ms`),
  and whether cases 2 and 3 were reached
  (`failures.backup.killed-backup-reached` and
  `failures.backup.killed-restore-reached`).
- The `restart-interruption` case of `manager-admission-check` keeps its
  private boundary. It takes an offline backup, cancels the restoration from
  that backup after its durable `restore-in-progress` marker, and requires
  that ordinary Store startup then refuses. It waits at the boundary
  `restore-marker`, which only the private copy of the tree that
  `python3 manager/test/admission_audit.py ROOT restore-interruption` builds
  contains. A direct run of `manager-admission-check restart-interruption
  WORK NATIVE` stops with the message "actual currentReview boundary was not
  reached". The suite of `manager-admission-check WORK NATIVE SOURCE
  PYTHON`, which the gate runs, does not contain the case. The
  `failures-backup` mode, not this case, gives `failures.backup.passed`.

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
| `failures.backup.passed` | equals `true` | flag | Case 1 of failures-backup passes, and no case of the mode fails. |

## Read path decision of 2026-10-03

The Phase F review reported that the event read path saturates in the burst
round of the event flood, and the measurement of 2026-10-02 gave two keys
outside their ceilings. The record
`doc/research/workflow-manager-read-path-diagnosis-2026-10.md` names the
cause. Each runtime envelope held one of the two reader places
(`globalDatabaseReaders` 2) for a replay of the whole run log from sequence
zero, which made 95 percent of the SQL reads. In addition, every commit,
ingestion included, advanced the authorization cell, so a revalidation read
the facts again before each write and repeated that read after about one
commit in two.

The owner kept the workload, the configuration of `capacity-streams`, every
ceiling, `globalDatabaseReaders` 2, the lock order file slot, configuration,
database, the five-second allowance, the 16 KiB write packing and the reader
admission of `Store.withStoreReaderLoan`. It changed two owners:

- `State.restoreProjectionCut` continues the projection of a run that the
  Store holds from its next sequence, and it keeps the comparison with the
  stored boundary. The section "Validated ingestion projections" of
  `manager/STORAGE.md` states the rule and its memory bound.
- `Store` keeps an authorization revision apart from the authorization cell.
  The cell still wakes the readers for new data. The revision advances only
  for a commit that changes authorization facts, which its owner marks.
  `Authorization.revalidateAuthorizedView` reads the facts again only when
  the revision changed or the last full check of the view started one second
  ago or earlier. It compares the expiry and the rotation cutoff with the
  current time before each write. `manager/STORAGE.md` and
  `manager/COMMANDS.md` state the rule.

`capacity-streams` ran once at N8 before the change (the uninstrumented
baseline of the record, on `86c1e9e9`) and once after it, on the final
source of this change. Neither run is a run of record, because one other
manager process ran on the host during both runs. The host load was 8.52 at
the start of the first run, and 5.6 at the start and 6.7 at the end of the
second.

| Key | Before | After | Ceiling |
| --- | --- | --- | --- |
| `events.catch-up-p50-ms` | 1713.4 | 3.4 | at most 1000 |
| `events.catch-up-p95-ms` | 17392.6 | 128.8 | at most 5000 |
| `events.reader-complete` | true | true | equals `true` |
| `events.burst.catch-up-p95-ms` | 17698.4 | 132.4 | none |
| `events.delivery-p95-ms` | 30762.4 | 9123.8 | none |
| `events.burst.delivery-p95-ms` | 38418.2 | 9967.5 | none |
| `events.dropped-reads` | 0 | 0 | none |
| `events.refused-reads` | 15 | 1 | none |
| `slow.independent-terminal-ms` | 44841.6 | 1777.3 | none |
| `slow.pending-bytes-max` | not recorded | 419174 | at most 1048576 |
| Ceiling keys outside their ceilings | 2 of 14 | 0 of 14 | |

After the change, no started response closed with no bytes. The one refused
read was a page of `/v1/runs` whose event cursor changed during its
materialization (`overview-cursor`), which the harness read again. The
stopped reader of the slow consumer ended at its five-second write deadline,
as designed.

### Terminal status of the independent run

Before this change, the harness read the status of the independent run only
after every run of the burst round had ended. So `slow.independent-terminal-ms`
held the rest of the burst round and not the time at which the manager
reported the terminal status. The value of the baseline, 44.8 seconds,
follows the length of its burst round, 48.9 seconds. The manager log of each
run shows the actual time. The `recorded_at` second of the last `run.changed`
invalidation of a run is the commit of its terminal ingestion, and the last
record of its run log is the terminal event of the runtime. For the
independent run, the manager committed the terminal status in the same
second as the terminal event in the baseline, in the run of the record with
both temporary changes A and B, and in every run of this change. So the late
terminal status of the record came from the harness and not from the
manager. The harness now times the terminal status with the status reads of
the burst round (see [Slow consumer](#slow-consumer)). With this timing, the
key after the change is 1.8 seconds.

### Burst delivery time

The delivery time of the burst runs, from the terminal event of a run log to
the last `run.changed` invalidation of the run at a reader, stays at about
ten seconds. The readers are not the cause: the catch-up of the burst round
is 132.4 ms at the 95th percentile. The cause is the rate of ingestion. In
the final run the runtime wrote the 2955 envelopes of the 15 burst runs in
about 2.5 seconds. The manager commits each envelope in one write
transaction while it holds a reader place, and it committed the terminal
ingestion of the burst runs 8.7 to 11.2 seconds after their terminal events,
about 270 envelopes each second. This backlog
has no ceiling. It ends when the burst ends, and it stays open for the
owner of `State.ingestValidated`.

### Reader admission

The record also names the reader admission of `Store.withStoreReaderLoan`:
when a place returns, every waiting reader admits again through the
configuration guard. The owner measured an ordered admission, in which a
returned place admits only the first waiting reader again, in two variants.
Each variant made the burst slower.

| Admission | Burst round | `events.burst.delivery-p95-ms` |
| --- | --- | --- |
| Every waiting reader admits again (kept) | 14.7, 15.6 and 16.0 s | 9209.0, 9708.4 and 9967.5 |
| Only the first waiting reader admits again | 18.1 s | 12409.7 |
| The same, and a new reader takes a free place | 18.4 s | 13531.8 |

The waiting readers that admit again wait together on the configuration
guard, which admits its waiters in order. So a returned place goes to the
next reader that holds the guard. With an ordered admission, the first
waiting reader starts its wait for the guard only after the place returns,
and the place stays empty for that wait. The owner therefore kept the
existing admission. The evidence of these runs is in the private evidence
directory of PG3.

The pending transport bytes of a stream have no count at the writer. Their
ceiling held in each run because the write deadline ended the stopped reader
first.

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
Each option `--exclude-section NAME` before the file names removes the
ceiling keys whose first dotted segment is `NAME`, and the measurements of
these keys, from the comparison. A part of the measurements, such as the
capacity modes without the failure modes, then has a summary that does not
list the keys of the other part as missing. A name that is not the first
segment of a ceiling key is an input error.

A ceiling of the form "at most N" holds when the measured number is N or
less, "at least N" when it is N or more, "N to M" when it lies between N and M
inclusive, and "equals" when the measured value has the same type and value.

## Measured values of 2026-10-02 at 9e329971 on macOS 27.0 arm64

These values were measured on 2026-10-02 on the platform of the section
[Tested platform](#tested-platform), with each mode run once at N8. Each
mode ran on the tree of one commit:

- `capacity-admission` on `7cf1408b`, the commit that adds the mode.
- `capacity-inputs` on `89bd367e`, the commit that adds the mode.
- `capacity-streams`, `storage` and `routes` on `9e329971`, the commit that
  adds the first mode and the prints of the other two.
- `faults-io`, `failures-worker`, `failures-manager`, `failures-launched`,
  `tui-failures` and `manager-admission-check` on `9e329971` with the change
  that adds this section.

The command `python3 manager/test/capacity_summary.py summary
manager/test/capacity-ceilings.json` with the seven measurement files
`capacity-admission.json`, `capacity-inputs.json`, `capacity-streams.json`,
`storage-measure.json`, `routes-measure.json`, `faults-io.json` and
`faults.json` reports 126 PASS, 3 FAIL and 0 MISSING for the 129 ceiling
keys. The file `faults.json` joins the files `<mode>-measure.json` of the
four failure modes and the outcome of the backup case. No ceiling changed
after a measurement.

The three FAIL results have these causes:

- `events.catch-up-p50-ms` is 1065.4 against at most 1000, and
  `events.catch-up-p95-ms` is 19521.6 against at most 5000. The read path of
  the manager saturates during the burst round of the slow-consumer
  workload. The two rounds without the burst give 14.2 and 842.9
  milliseconds (`events.rounds.catch-up-p50-ms` and
  `events.rounds.catch-up-p95-ms`), and the burst round alone gives 1553.6
  and 19873.7 milliseconds. This record does not change the manager. The
  section [Read path decision of 2026-10-03](#read-path-decision-of-2026-10-03)
  gives the change of the manager and the values after it.
- `failures.backup.passed` is `false`. The `restart-interruption` case did
  not run to its assertions. Its direct run stopped with the message "actual
  currentReview boundary was not reached", because the boundary
  `restore-marker` exists only in the private copy that `admission_audit.py
  restore-interruption` builds, as the section
  [Failure modes](#failure-modes) states. The audits of `admission_audit.py`
  were not run under the fast-validation direction of 2026-09-29. The suite
  of the gate, `manager-admission-check WORK NATIVE SOURCE PYTHON +RTS -N8`,
  passed with 146 PASS lines (`failures.backup.gate-passed` and
  `failures.backup.gate-pass-lines`). It holds no interrupted-backup case.

Under the file-size limit of the `faults-io` mode, the first refused command
was the eighth, a `set-input`, after the WAL of the coordination database
reached the limit of 4830768 bytes. The write failure poisoned the Store, so every
later command and read of that lifetime refused with 503
`storage-unavailable`, including `GET /v1/capabilities` and the withdraw of
the queued request. No command row, run or review was added. The third
lifetime served the committed state, and no command executed again.

| Key | Measured | Result |
| --- | --- | --- |
| `captures.aggregate-accepted-bytes` | 134217728 | PASS |
| `captures.aggregate-refusal-code` | `storage-quota` | PASS |
| `captures.aggregate-refusal-ms` | 1.7 | PASS |
| `captures.aggregate-refusal-status` | 429 | PASS |
| `captures.manager-rss-peak-bytes` | 287391744 | PASS |
| `captures.max-accepted` | true | PASS |
| `captures.oversize-refusal-code` | `size-limit` | PASS |
| `captures.oversize-refusal-ms` | 0.6 | PASS |
| `captures.oversize-refusal-status` | 413 | PASS |
| `captures.root-growth-overhead-bytes` | 137706 | PASS |
| `captures.upload-max-ms` | 1643.4 | PASS |
| `disk.manager-rss-peak-bytes` | 94568448 | PASS |
| `disk.no-receipt` | true | PASS |
| `disk.refusal-code` | `storage-unavailable` | PASS |
| `disk.refusal-ms` | 12.5 | PASS |
| `disk.refusal-status` | 503 | PASS |
| `disk.reopen-verified` | true | PASS |
| `drafts.client-accepted` | 4 | PASS |
| `drafts.client-refusal-code` | `storage-quota` | PASS |
| `drafts.client-refusal-ms` | 1.1 | PASS |
| `drafts.client-refusal-status` | 429 | PASS |
| `drafts.create-p50-ms` | 10.7 | PASS |
| `drafts.create-p95-ms` | 13.2 | PASS |
| `drafts.global-accepted` | 10 | PASS |
| `drafts.global-refusal-code` | `storage-quota` | PASS |
| `drafts.global-refusal-ms` | 1.9 | PASS |
| `drafts.global-refusal-status` | 429 | PASS |
| `drafts.manager-rss-peak-bytes` | 93356032 | PASS |
| `events.catch-up-p50-ms` | 1065.4 | FAIL |
| `events.catch-up-p95-ms` | 19521.6 | FAIL |
| `events.manager-rss-peak-bytes` | 132071424 | PASS |
| `events.reader-complete` | true | PASS |
| `failures.backup.passed` | false | FAIL |
| `failures.launched.manager-rss-peak-bytes` | 102367232 | PASS |
| `failures.launched.passed` | true | PASS |
| `failures.launched.release-to-review-ms` | 303.2 | PASS |
| `failures.manager.manager-rss-peak-bytes` | 111869952 | PASS |
| `failures.manager.passed` | true | PASS |
| `failures.manager.restart-ready-ms` | 1011.2 | PASS |
| `failures.tui.manager-rss-peak-bytes` | 104251392 | PASS |
| `failures.tui.passed` | true | PASS |
| `failures.tui.reconnect-ms` | 1336.0 | PASS |
| `failures.tui.unreachable-ms` | 1389.5 | PASS |
| `failures.worker.lost-ms` | 147.8 | PASS |
| `failures.worker.manager-rss-peak-bytes` | 102121472 | PASS |
| `failures.worker.passed` | true | PASS |
| `growth.ledger-bytes-per-command` | 131072 | PASS |
| `growth.manager-log-bytes-per-command` | 3291.2 | PASS |
| `growth.run-log-bytes-per-run` | 5018 | PASS |
| `growth.wal-bytes-after-close` | 0 | PASS |
| `growth.wal-bytes-per-command` | 298401.0 | PASS |
| `pages.client-refusal-code` | `storage-quota` | PASS |
| `pages.client-refusal-ms` | 29.1 | PASS |
| `pages.client-refusal-status` | 429 | PASS |
| `pages.continuation-before-expiry-status` | 200 | PASS |
| `pages.expired-continuation-code` | `view-expired` | PASS |
| `pages.expired-continuation-status` | 410 | PASS |
| `pages.first-page-after-expiry-status` | 200 | PASS |
| `pages.first-page-p50-ms` | 281.1 | PASS |
| `pages.first-page-p95-ms` | 1263.2 | PASS |
| `pages.global-refusal-code` | `storage-quota` | PASS |
| `pages.global-refusal-ms` | 29.7 | PASS |
| `pages.global-refusal-status` | 429 | PASS |
| `pages.held-sets` | 8 | PASS |
| `pages.manager-rss-peak-bytes` | 125829120 | PASS |
| `pages.set-bytes-max` | 1341617 | PASS |
| `queue.accepted-queued` | 100 | PASS |
| `queue.enqueue-p50-ms` | 16.6 | PASS |
| `queue.enqueue-p95-ms` | 19.9 | PASS |
| `queue.manager-rss-peak-bytes` | 102973440 | PASS |
| `queue.mutations-per-credential-minute` | 27 | PASS |
| `queue.refusal-code` | `state-conflict` | PASS |
| `queue.refusal-ms` | 3.6 | PASS |
| `queue.refusal-status` | 409 | PASS |
| `queue.requests-first-page-p50-ms` | 41.9 | PASS |
| `queue.requests-first-page-p95-ms` | 85.2 | PASS |
| `readers.holders-accepted` | 2 | PASS |
| `readers.holders-verified` | true | PASS |
| `readers.manager-rss-peak-bytes` | 74153984 | PASS |
| `readers.third-refusal-code` | `storage-quota` | PASS |
| `readers.third-refusal-status` | 429 | PASS |
| `readers.third-wait-ms` | 5001.1 | PASS |
| `reservations.r1.answer-p50-ms` | 26.7 | PASS |
| `reservations.r1.answer-p95-ms` | 37.0 | PASS |
| `reservations.r1.approve-p50-ms` | 22.5 | PASS |
| `reservations.r1.approve-p95-ms` | 25.8 | PASS |
| `reservations.r1.fifo-order` | true | PASS |
| `reservations.r1.manager-rss-peak-bytes` | 103841792 | PASS |
| `reservations.r1.peak-concurrent-runs` | 1 | PASS |
| `reservations.r1.release-to-review-p50-ms` | 188.1 | PASS |
| `reservations.r1.release-to-review-p95-ms` | 223.8 | PASS |
| `reservations.r16.answer-p50-ms` | 27.9 | PASS |
| `reservations.r16.answer-p95-ms` | 60.3 | PASS |
| `reservations.r16.approve-p50-ms` | 22.9 | PASS |
| `reservations.r16.approve-p95-ms` | 26.4 | PASS |
| `reservations.r16.fifo-order` | true | PASS |
| `reservations.r16.manager-rss-peak-bytes` | 117555200 | PASS |
| `reservations.r16.peak-concurrent-runs` | 16 | PASS |
| `reservations.r16.queued-capacity-reason` | true | PASS |
| `reservations.r16.release-to-review-p50-ms` | 253.4 | PASS |
| `reservations.r16.release-to-review-p95-ms` | 275.4 | PASS |
| `routes.batch-p50-ms` | 4.8 | PASS |
| `routes.batch-p95-ms` | 7.0 | PASS |
| `routes.below-floor-code` | `cursor-expired` | PASS |
| `routes.below-floor-status` | 410 | PASS |
| `routes.manager-rss-peak-bytes` | 99319808 | PASS |
| `routes.prune-floor` | true | PASS |
| `routes.seal-resume` | true | PASS |
| `safety.cancel-accepted` | true | PASS |
| `safety.cancel-ms` | 23.3 | PASS |
| `safety.cancel-to-cancelled-ms` | 150.8 | PASS |
| `safety.manager-rss-peak-bytes` | 103235584 | PASS |
| `safety.rate-refusal-code` | `rate-limit` | PASS |
| `safety.rate-refusal-ms` | 1.7 | PASS |
| `safety.rate-refusal-status` | 429 | PASS |
| `slow.independent-answer-ms` | 162.8 | PASS |
| `slow.independent-run-succeeded` | true | PASS |
| `slow.manager-rss-peak-bytes` | 132071424 | PASS |
| `slow.no-loss` | true | PASS |
| `slow.pending-bytes-max` | 124649 | PASS |
| `storage.append-cancel-accepted` | true | PASS |
| `storage.append-refusal-code` | `storage-unavailable` | PASS |
| `storage.append-refusal-ms` | 3.3 | PASS |
| `storage.append-refusal-status` | 503 | PASS |
| `storage.ledger-cancel-accepted` | true | PASS |
| `storage.ledger-refusal-code` | `storage-quota` | PASS |
| `storage.ledger-refusal-ms` | 1.6 | PASS |
| `storage.ledger-refusal-status` | 429 | PASS |
| `storage.manager-rss-peak-bytes` | 100941824 | PASS |

These measured values name no ceiling:

| Key | Measured |
| --- | --- |
| `disk.accepted-commands` | 7 |
| `disk.largest-file-bytes` | 3782192 |
| `disk.limit-bytes` | 4830768 |
| `disk.no-run-started` | true |
| `disk.withdraw-accepted` | false |
| `disk.withdraw-ms` | 0.4 |
| `events.burst-per-second` | 126.0 |
| `events.burst.catch-up-p50-ms` | 1553.6 |
| `events.burst.catch-up-p95-ms` | 19873.7 |
| `events.burst.delivery-p50-ms` | 33553.6 |
| `events.burst.delivery-p95-ms` | 44606.7 |
| `events.count` | 8384 |
| `events.delivery-p50-ms` | 383.1 |
| `events.delivery-p95-ms` | 41471.7 |
| `events.dropped-reads` | 2 |
| `events.mutations-per-credential-minute` | 27 |
| `events.poll-slowest-at` | `2026-10-03T03:33:34.201526+00:00` |
| `events.poll-slowest-ms` | 5901.2 |
| `events.reader.e0.catch-up-p50-ms` | 0.0 |
| `events.reader.e0.catch-up-p95-ms` | 255.1 |
| `events.reader.e1-2.catch-up-p50-ms` | 13.7 |
| `events.reader.e1-2.catch-up-p95-ms` | 787.6 |
| `events.reader.e2-1.catch-up-p50-ms` | 1189.5 |
| `events.reader.e2-1.catch-up-p95-ms` | 20711.1 |
| `events.reader.e3-1.catch-up-p50-ms` | 1121.0 |
| `events.reader.e3-1.catch-up-p95-ms` | 16187.9 |
| `events.reconnects` | 5 |
| `events.refused-reads` | 20 |
| `events.round1-per-second` | 66.1 |
| `events.round2-per-second` | 72.4 |
| `events.rounds.catch-up-p50-ms` | 14.2 |
| `events.rounds.catch-up-p95-ms` | 842.9 |
| `events.rounds.delivery-p50-ms` | 303.0 |
| `events.rounds.delivery-p95-ms` | 1379.6 |
| `events.route.e1-1.bytes` | 659257 |
| `events.route.e1-1.records` | 512 |
| `events.route.e2-2.bytes` | 659257 |
| `events.route.e2-2.records` | 512 |
| `events.route.e3-2.bytes` | 9617 |
| `events.route.e3-2.records` | 19 |
| `events.uncertain-approvals` | 0 |
| `failures.backup.boundary-not-reached` | true |
| `failures.backup.gate-pass-lines` | 146 |
| `failures.backup.gate-passed` | true |
| `failures.manager.release-7-to-review-ms` | 284.6 |
| `failures.manager.release-9-to-review-ms` | 289.5 |
| `failures.tui.delayed-switch-ms` | 2250.7 |
| `failures.tui.direct-overview-ms` | 58.0 |
| `growth.commands` | 124 |
| `growth.wal-bytes-serving` | 38575592 |
| `queue.capabilities-saturated-ms` | 3.1 |
| `reservations.r16.capabilities-saturated-ms` | 3.6 |
| `routes.batches` | 41 |
| `routes.create-after-seal-position` | 31 |
| `routes.prune-floor-position` | 30 |
| `routes.seal-position` | 30 |
| `routes.second-segment-records` | 4 |
| `safety.capabilities-saturated-ms` | 6.0 |
| `slow.burst-run-log-bytes-max` | 39600 |
| `slow.independent-runtime-terminal-ms` | -147.2 |
| `slow.independent-terminal-ms` | 53502.0 |
| `slow.peer-bytes-while-stopped` | 1665622 |
| `slow.reconnects-after-stop` | 1 |
| `slow.stopped-bytes-before` | 297627 |
| `slow.stopped-ms` | 58400 |
| `slow.stream-ended` | true |
| `storage.append-cancel-ms` | 21.9 |
| `storage.ledger-bytes-at-ceiling` | 524288 |
| `storage.ledger-cancel-ms` | 29.0 |

## Measured values of 2026-10-03 at e454fbd7 on macOS 27.0 arm64

These values are the runs of record of the capacity and failure modes. They
were measured on 2026-10-03 on the platform of the section
[Tested platform](#tested-platform), macOS 27.0 (build 26A428) on arm64.
Each mode ran once at N8 on the tree of commit `e454fbd7`, one mode at a
time. The six capacity modes `capacity-admission`, `capacity-inputs` (with
`ARTIFACT_CHECK`), `capacity-streams`, `faults-io`, `storage` and `routes`
ran first. The five failure modes `failures-worker`, `failures-manager`,
`failures-launched`, `tui-failures` and `failures-backup` ran after them.
Every mode exited with status 0.

The command `python3 manager/test/capacity_summary.py summary
manager/test/capacity-ceilings.json` with the eleven measurement files
`capacity-admission.json`, `capacity-inputs.json`, `capacity-streams.json`,
`faults-io.json`, `storage-measure.json`, `routes-measure.json`,
`failures-worker-measure.json`, `failures-manager-measure.json`,
`failures-launched-measure.json`, `tui-failures-measure.json` and
`failures-backup-measure.json` reports 129 PASS, 0 FAIL and 0 MISSING for
the 129 ceiling keys. It lists the host-load keys as unchecked, because they
name no ceiling. No ceiling changed after a measurement.

Each of the 22 workloads started at a one-minute load average of at most 16,
and the harness counted no other `--manager serve` process at the start of
any workload. Each workload thus meets the host-load rule of the section
[Measurement rules](#measurement-rules). The largest value at a start was
15.92, at the start of `reservations.r1`. Before `reservations.r1`, the
harness waited 30 seconds for the load to fall to 16.

The nine accepted first pages of `/v1/runs` in the `pages` lifetime took
977, 123, 129, 117, 140, 134, 111, 151 and 99 milliseconds in their order,
for a median of 129.1 milliseconds. The first of them also retains the
handles of the 4096 legacy entries for the first time in the lifetime.

In the `failures-backup` mode, the kill of case 2 and the kill of case 3 both
landed inside their windows, so all three cases counted. Under the file-size
limit of 1576960 bytes, the backup of case 1 refused with
`storage-unavailable` after 102.6 milliseconds.

| Key | Measured | Result |
| --- | --- | --- |
| `captures.aggregate-accepted-bytes` | 134217728 | PASS |
| `captures.aggregate-refusal-code` | `storage-quota` | PASS |
| `captures.aggregate-refusal-ms` | 1.1 | PASS |
| `captures.aggregate-refusal-status` | 429 | PASS |
| `captures.manager-rss-peak-bytes` | 276545536 | PASS |
| `captures.max-accepted` | true | PASS |
| `captures.oversize-refusal-code` | `size-limit` | PASS |
| `captures.oversize-refusal-ms` | 0.4 | PASS |
| `captures.oversize-refusal-status` | 413 | PASS |
| `captures.root-growth-overhead-bytes` | 137706 | PASS |
| `captures.upload-max-ms` | 690.4 | PASS |
| `disk.manager-rss-peak-bytes` | 95895552 | PASS |
| `disk.no-receipt` | true | PASS |
| `disk.refusal-code` | `storage-unavailable` | PASS |
| `disk.refusal-ms` | 10.4 | PASS |
| `disk.refusal-status` | 503 | PASS |
| `disk.reopen-verified` | true | PASS |
| `drafts.client-accepted` | 4 | PASS |
| `drafts.client-refusal-code` | `storage-quota` | PASS |
| `drafts.client-refusal-ms` | 1.3 | PASS |
| `drafts.client-refusal-status` | 429 | PASS |
| `drafts.create-p50-ms` | 10.2 | PASS |
| `drafts.create-p95-ms` | 13.1 | PASS |
| `drafts.global-accepted` | 10 | PASS |
| `drafts.global-refusal-code` | `storage-quota` | PASS |
| `drafts.global-refusal-ms` | 1.5 | PASS |
| `drafts.global-refusal-status` | 429 | PASS |
| `drafts.manager-rss-peak-bytes` | 95010816 | PASS |
| `events.catch-up-p50-ms` | 2.3 | PASS |
| `events.catch-up-p95-ms` | 106.1 | PASS |
| `events.manager-rss-peak-bytes` | 135331840 | PASS |
| `events.reader-complete` | true | PASS |
| `failures.backup.passed` | true | PASS |
| `failures.launched.manager-rss-peak-bytes` | 101302272 | PASS |
| `failures.launched.passed` | true | PASS |
| `failures.launched.release-to-review-ms` | 120.4 | PASS |
| `failures.manager.manager-rss-peak-bytes` | 111149056 | PASS |
| `failures.manager.passed` | true | PASS |
| `failures.manager.restart-ready-ms` | 1181.1 | PASS |
| `failures.tui.manager-rss-peak-bytes` | 103055360 | PASS |
| `failures.tui.passed` | true | PASS |
| `failures.tui.reconnect-ms` | 1085.6 | PASS |
| `failures.tui.unreachable-ms` | 1538.7 | PASS |
| `failures.worker.lost-ms` | 8.5 | PASS |
| `failures.worker.manager-rss-peak-bytes` | 100188160 | PASS |
| `failures.worker.passed` | true | PASS |
| `growth.ledger-bytes-per-command` | 131072 | PASS |
| `growth.manager-log-bytes-per-command` | 3294.6 | PASS |
| `growth.run-log-bytes-per-run` | 5017 | PASS |
| `growth.wal-bytes-after-close` | 0 | PASS |
| `growth.wal-bytes-per-command` | 297470.6 | PASS |
| `pages.client-refusal-code` | `storage-quota` | PASS |
| `pages.client-refusal-ms` | 33.7 | PASS |
| `pages.client-refusal-status` | 429 | PASS |
| `pages.continuation-before-expiry-status` | 200 | PASS |
| `pages.expired-continuation-code` | `view-expired` | PASS |
| `pages.expired-continuation-status` | 410 | PASS |
| `pages.first-page-after-expiry-status` | 200 | PASS |
| `pages.first-page-p50-ms` | 129.1 | PASS |
| `pages.first-page-p95-ms` | 977.4 | PASS |
| `pages.global-refusal-code` | `storage-quota` | PASS |
| `pages.global-refusal-ms` | 44.1 | PASS |
| `pages.global-refusal-status` | 429 | PASS |
| `pages.held-sets` | 8 | PASS |
| `pages.manager-rss-peak-bytes` | 117293056 | PASS |
| `pages.set-bytes-max` | 1341617 | PASS |
| `queue.accepted-queued` | 100 | PASS |
| `queue.enqueue-p50-ms` | 17.5 | PASS |
| `queue.enqueue-p95-ms` | 22.0 | PASS |
| `queue.manager-rss-peak-bytes` | 100925440 | PASS |
| `queue.mutations-per-credential-minute` | 27 | PASS |
| `queue.refusal-code` | `state-conflict` | PASS |
| `queue.refusal-ms` | 5.3 | PASS |
| `queue.refusal-status` | 409 | PASS |
| `queue.requests-first-page-p50-ms` | 52.5 | PASS |
| `queue.requests-first-page-p95-ms` | 109.1 | PASS |
| `readers.holders-accepted` | 2 | PASS |
| `readers.holders-verified` | true | PASS |
| `readers.manager-rss-peak-bytes` | 74055680 | PASS |
| `readers.third-refusal-code` | `storage-quota` | PASS |
| `readers.third-refusal-status` | 429 | PASS |
| `readers.third-wait-ms` | 5001.7 | PASS |
| `reservations.r1.answer-p50-ms` | 22.9 | PASS |
| `reservations.r1.answer-p95-ms` | 30.4 | PASS |
| `reservations.r1.approve-p50-ms` | 21.2 | PASS |
| `reservations.r1.approve-p95-ms` | 25.6 | PASS |
| `reservations.r1.fifo-order` | true | PASS |
| `reservations.r1.manager-rss-peak-bytes` | 104087552 | PASS |
| `reservations.r1.peak-concurrent-runs` | 1 | PASS |
| `reservations.r1.release-to-review-p50-ms` | 214.1 | PASS |
| `reservations.r1.release-to-review-p95-ms` | 278.8 | PASS |
| `reservations.r16.answer-p50-ms` | 23.8 | PASS |
| `reservations.r16.answer-p95-ms` | 29.0 | PASS |
| `reservations.r16.approve-p50-ms` | 22.6 | PASS |
| `reservations.r16.approve-p95-ms` | 28.7 | PASS |
| `reservations.r16.fifo-order` | true | PASS |
| `reservations.r16.manager-rss-peak-bytes` | 119504896 | PASS |
| `reservations.r16.peak-concurrent-runs` | 16 | PASS |
| `reservations.r16.queued-capacity-reason` | true | PASS |
| `reservations.r16.release-to-review-p50-ms` | 286.3 | PASS |
| `reservations.r16.release-to-review-p95-ms` | 307.5 | PASS |
| `routes.batch-p50-ms` | 7.6 | PASS |
| `routes.batch-p95-ms` | 37.2 | PASS |
| `routes.below-floor-code` | `cursor-expired` | PASS |
| `routes.below-floor-status` | 410 | PASS |
| `routes.manager-rss-peak-bytes` | 100352000 | PASS |
| `routes.prune-floor` | true | PASS |
| `routes.seal-resume` | true | PASS |
| `safety.cancel-accepted` | true | PASS |
| `safety.cancel-ms` | 18.3 | PASS |
| `safety.cancel-to-cancelled-ms` | 5.0 | PASS |
| `safety.manager-rss-peak-bytes` | 101171200 | PASS |
| `safety.rate-refusal-code` | `rate-limit` | PASS |
| `safety.rate-refusal-ms` | 1.2 | PASS |
| `safety.rate-refusal-status` | 429 | PASS |
| `slow.independent-answer-ms` | 32.6 | PASS |
| `slow.independent-run-succeeded` | true | PASS |
| `slow.manager-rss-peak-bytes` | 135331840 | PASS |
| `slow.no-loss` | true | PASS |
| `slow.pending-bytes-max` | 426823 | PASS |
| `storage.append-cancel-accepted` | true | PASS |
| `storage.append-refusal-code` | `storage-unavailable` | PASS |
| `storage.append-refusal-ms` | 2.1 | PASS |
| `storage.append-refusal-status` | 503 | PASS |
| `storage.ledger-cancel-accepted` | true | PASS |
| `storage.ledger-refusal-code` | `storage-quota` | PASS |
| `storage.ledger-refusal-ms` | 1.2 | PASS |
| `storage.ledger-refusal-status` | 429 | PASS |
| `storage.manager-rss-peak-bytes` | 100548608 | PASS |

These measured values name no ceiling:

| Key | Measured |
| --- | --- |
| `disk.accepted-commands` | 6 |
| `disk.largest-file-bytes` | 3712152 |
| `disk.limit-bytes` | 4760728 |
| `disk.no-run-started` | true |
| `disk.withdraw-accepted` | false |
| `disk.withdraw-ms` | 0.4 |
| `events.burst-per-second` | 489.4 |
| `events.burst.catch-up-p50-ms` | 4.2 |
| `events.burst.catch-up-p95-ms` | 113.4 |
| `events.burst.delivery-p50-ms` | 8288.7 |
| `events.burst.delivery-p95-ms` | 9144.6 |
| `events.count` | 8384 |
| `events.delivery-p50-ms` | 126.9 |
| `events.delivery-p95-ms` | 9009.2 |
| `events.dropped-reads` | 0 |
| `events.mutations-per-credential-minute` | 27 |
| `events.poll-slowest-at` | `2026-10-04T00:36:11.798351+00:00` |
| `events.poll-slowest-ms` | 217.3 |
| `events.reader.e0.catch-up-p50-ms` | 171.8 |
| `events.reader.e0.catch-up-p95-ms` | 557.2 |
| `events.reader.e1-2.catch-up-p50-ms` | 1.4 |
| `events.reader.e1-2.catch-up-p95-ms` | 14.5 |
| `events.reader.e2-1.catch-up-p50-ms` | 2.0 |
| `events.reader.e2-1.catch-up-p95-ms` | 82.4 |
| `events.reader.e3-1.catch-up-p50-ms` | 2.9 |
| `events.reader.e3-1.catch-up-p95-ms` | 115.9 |
| `events.reconnects` | 1 |
| `events.refused-reads` | 5 |
| `events.round1-per-second` | 122.6 |
| `events.round2-per-second` | 121.5 |
| `events.rounds.catch-up-p50-ms` | 1.8 |
| `events.rounds.catch-up-p95-ms` | 14.1 |
| `events.rounds.delivery-p50-ms` | 108.8 |
| `events.rounds.delivery-p95-ms` | 178.2 |
| `events.route.e1-1.bytes` | 659730 |
| `events.route.e1-1.records` | 512 |
| `events.route.e2-2.bytes` | 659730 |
| `events.route.e2-2.records` | 512 |
| `events.route.e3-2.bytes` | 9574 |
| `events.route.e3-2.records` | 19 |
| `events.uncertain-approvals` | 0 |
| `failures.backup.capture-bytes` | 67108864 |
| `failures.backup.killed-backup-reached` | true |
| `failures.backup.killed-restore-reached` | true |
| `failures.backup.largest-file-bytes` | 528384 |
| `failures.backup.limit-bytes` | 1576960 |
| `failures.backup.limited-code` | `storage-unavailable` |
| `failures.backup.limited-ms` | 102.6 |
| `failures.manager.release-7-to-review-ms` | 227.2 |
| `failures.manager.release-9-to-review-ms` | 673.9 |
| `failures.tui.delayed-switch-ms` | 1933.0 |
| `failures.tui.direct-overview-ms` | 34.7 |
| `growth.commands` | 124 |
| `growth.wal-bytes-serving` | 38451992 |
| `pages.legacy-setup-load-1m-end` | 7.44 |
| `pages.legacy-setup-load-1m-start` | 7.85 |
| `pages.legacy-setup-ms` | 21962.8 |
| `queue.capabilities-saturated-ms` | 2.7 |
| `reservations.r16.capabilities-saturated-ms` | 1.9 |
| `routes.batches` | 41 |
| `routes.create-after-seal-position` | 31 |
| `routes.prune-floor-position` | 30 |
| `routes.seal-position` | 30 |
| `routes.second-segment-records` | 4 |
| `safety.capabilities-saturated-ms` | 3.4 |
| `slow.burst-run-log-bytes-max` | 39596 |
| `slow.independent-runtime-terminal-ms` | -23.6 |
| `slow.independent-terminal-in-round` | true |
| `slow.independent-terminal-ms` | 1569.5 |
| `slow.peer-bytes-while-stopped` | 1666567 |
| `slow.reconnects-after-stop` | 1 |
| `slow.stopped-bytes-before` | 298473 |
| `slow.stopped-ms` | 15824 |
| `slow.stream-ended` | true |
| `storage.append-cancel-ms` | 5.8 |
| `storage.ledger-bytes-at-ceiling` | 524288 |
| `storage.ledger-cancel-ms` | 22.8 |

The host-load keys of each workload have these values. The wait is the time
that the harness waited for the load rule before the start of the workload.

| Workload | Load 1m at start | Load 1m at end | Wait ms | Other managers at start |
| --- | --- | --- | --- | --- |
| `reservations.r1` | 15.92 | 13.11 | 30214.8 | 0 |
| `reservations.r16` | 13.11 | 11.03 | 0.0 | 0 |
| `cohorts` | 11.03 | 10.55 | 0.0 | 0 |
| `queue` | 10.55 | 7.93 | 0.0 | 0 |
| `drafts` | 7.93 | 7.85 | 0.0 | 0 |
| `pages` | 7.44 | 3.64 | 0.0 | 0 |
| `captures` | 3.64 | 3.64 | 0.0 | 0 |
| `streams` | 3.53 | 3.21 | 0.0 | 0 |
| `io-1` | 3.36 | 3.25 | 0.0 | 0 |
| `io-2` | 3.25 | 3.25 | 0.0 | 0 |
| `io-3` | 3.25 | 3.25 | 0.0 | 0 |
| `storage` | 3.31 | 10.28 | 0.0 | 0 |
| `routes` | 11.22 | 14.47 | 0.0 | 0 |
| `failures.worker` | 14.67 | 15.74 | 0.0 | 0 |
| `failures.manager` | 15.12 | 10.94 | 0.0 | 0 |
| `failures.launched` | 10.94 | 7.3 | 0.0 | 0 |
| `failures.tui` | 7.3 | 4.31 | 0.0 | 0 |
| `bk-setup` | 4.13 | 4.13 | 0.0 | 0 |
| `bk-case-1` | 4.13 | 4.13 | 0.0 | 0 |
| `bk-case-2` | 4.04 | 4.04 | 0.0 | 0 |
| `bk-other` | 4.04 | 4.04 | 0.0 | 0 |
| `bk-restored` | 4.04 | 4.04 | 0.0 | 0 |
