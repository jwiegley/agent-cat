# Workflow manager read-path diagnosis, October 2026

This record gives the diagnosis of the read-path saturation of the event
streams under burst. Both lenses of the Phase F review reported it as a
medium WM-041 finding. The diagnosis ran on 2026-10-03 on the tree of commit
`86c1e9e9` (PG1), with the `capacity-streams` mode of
`manager/test/service_http.py` at `-N8`. It names the dominant cost with
numbers, and it states the decision for the next subtask (PG3). It changed no
product source. The temporary counters and the two experiments below were
removed after the runs, and the tree was built again without them.

## Conditions

The host load was within the rule of `manager/CAPACITY.md` at the start of
each run: the one-minute load average was between 4.1 and 10.7, against at
most 16. One other manager process ran on the host during every run. It was
PID 61004, a `--manager serve` process that an earlier PF17 capacity run left
behind. The subtask left it alone. Thus no run below is a run of record. Each
configuration ran once, so each value is one sample. The host load at the
end of experiment A was 18.1, which is above the rule.

## Baseline

The baseline is one run of `capacity-streams` at `-N8` with the PG1 build
and no counters. The load average was 8.52 at the start and 5.43 at the end.
The mode passed, and 2 of its 14 ceiling keys were outside their ceilings.

| Key | Value | Ceiling |
| --- | --- | --- |
| `events.catch-up-p50-ms` | 1713.4 | at most 1000 |
| `events.catch-up-p95-ms` | 17392.6 | at most 5000 |
| `events.burst.catch-up-p95-ms` | 17698.4 | none |
| `events.reader-complete` | true | none |
| `events.dropped-reads` (CapacityHarness `dropped`) | 0 | none |
| `events.refused-reads` (CapacityHarness `refused`) | 15 | none |
| `events.delivery-p95-ms` | 30762.4 | none |
| `events.burst.delivery-p95-ms` | 38418.2 | none |
| `slow.independent-terminal-ms` | 44841.6 | none |
| `slow.independent-runtime-terminal-ms` | -155.1 | none |

No started response closed with no bytes, so `dropped` was 0. The 15 refused
reads were 503 responses before the response started. The manager observed
the terminal run status late. The runtime wrote the terminal event of the
independent run 155 ms before the answer was accepted, and the manager
reported the terminal status 44.8 seconds after the answer. In the burst
round, the 95th percentile from the terminal event of a run log to its last
`run.changed` invalidation was 38.4 seconds.

## Busy and erasure records

The manager fault log of the baseline held 32 records. The run with counters
held 20 records of the same kinds.

| Record | Baseline | Counter run |
| --- | --- | --- |
| `busy site=overview-cursor class=store StoreBusy` | 15 | 9 |
| `response GET /v1/runs unstarted public=503 storage-unavailable class=store StoreBusy` | 14 | 9 |
| `response GET /v1/requests unstarted public=503 storage-unavailable class=store StoreBusy` | 1 | 0 |
| `response GET /v1/events started public=503 storage-unavailable class=command StorageUnavailable` | 1 | 1 |
| `events write class=internal ResponseWriteTimeout erased=command StorageUnavailable` | 1 | 1 |

The other sites of `manager/STORAGE.md` had no record in either run. These
sites are `store-reader-admission`, `store-authorization-observation`,
`store-authorization-read-observation`, `store-sqlite-read`,
`store-sqlite-transaction`, `store-file-slot`, `store-gate`,
`configuration-guard` and the `state-*` sites. Each `overview-cursor` record
is a page of `/v1/runs` or `/v1/requests` whose event cursor changed during
its materialization. The page then refused with 503, and the harness counted
the refusal and read the page again. The `events write` record is the stopped
reader of the slow-consumer workload, which the manager ends after its
five-second write deadline, as designed.

So the read path met no admission deadline in these runs. The cost appears
as latency. The two database reader places, the configuration guard and the
Store gate were contended for most of the burst. Each wait completed within
its allowance.

## Counters

A local build added temporary counters at the owners below. The counters
wrote their totals to a file at the exit of the manager. One run of
`capacity-streams` at `-N8` used this build. The load average was 4.1 at the
start and 5.37 at the end. The run took 89 seconds, and its ceiling values
were near the baseline: `events.catch-up-p50-ms` 2174.2,
`events.catch-up-p95-ms` 16418.0, `slow.independent-terminal-ms` 37789.1 and
`events.refused-reads` 9. Times in the tables are sums over all threads.

### View revalidations per write

| Path | Writes | Revalidations per write | Of which fresh |
| --- | --- | --- | --- |
| Event stream (`Application.hs` `send`, `Events.withStream`) | 897 SSE writes in 949 batches | 3.06 | 2.0 |
| Route streams (`Routes.routeStream`) | 1051 blocks in 676 batches | 1.64 | 1.0 |
| JSON responses (`Transport.respondBytes`) | 1083 chunks of 16 KiB | 1.0, and 1 at the entry of each response | 1.0 |

An SSE event write has three revalidations. The batch checks its view with
`authorizedViewRevision` under the materialization loans. After
`releaseResponseLoans`, the pump checks the view before the write, and
`Application.current` checks it again in `send`. A fresh revalidation takes
a reader place, the configuration guard twice (once for the reader admission
and once for the facts) and the Store gate three times. The three paths had
3928 fresh revalidations, which equals the sum of the fresh column times the
writes. All revalidations together numbered 12023 and took 251.3 seconds,
a mean of 20.9 ms.

### Facts-read retries

| Observation | Attempts | Retries | Retries per observation |
| --- | --- | --- | --- |
| `revalidateAuthorizedView` (`readObservationWithin` from `withAuthorizationReadObservation`) | 18575 | 6552 | 0.54 |
| First observation of a request (`withAuthorizationRequestReadObservation`) | 2474 | 27 | 0.01 |

`Store.runWithAdmission` advanced the authorization cell 3728 times. Of
these, 3208 were ingestion commits (86 percent), and 520 were the other
commits. When the retry rate is the same on each path, an SSE write has
about 1.7 facts-read retries.

### Reader places, configuration guard and Store gate

| Owner | Acquisitions | Contended | Wait | Hold |
| --- | --- | --- | --- | --- |
| Reader places, `globalDatabaseReaders` 2 (`withStoreReaderLoan`) | 16098 | 52386 waits for a returned place | 134.1 s | 81.6 s |
| Configuration guard (`tryConfigurationLoan`) | 82294 | 75290 (91 percent) | 172.5 s | 42.2 s |
| Store gate (`withGate`) | 788514 | 215066 | 11.0 s | 28.3 s |
| File slot | 1009 | 476 | 4.3 s | not measured |

No reader admission ended with `StoreLimit`. A reader that waits for a place
admits again after each returned place, and each admission takes a
configuration loan. Thus the reader admissions took 68484 of the 82294
configuration loans (83 percent), and the configuration guard was held for
47 percent of the run.

The Store gate admitted 689919 SQL reads (13.9 seconds) and 5216 SQL writes
(7.3 seconds).

### Ingestion

| Counter | Value |
| --- | --- |
| Runtime envelopes ingested (`State.ingestValidated`) | 3208 |
| Ingestion time, with the wait for a reader place | 94.3 s, a mean of 29.4 ms |
| Ingestion time with a reader place held | 40.4 s |
| Projection restores (`State.restoreProjection`) | 3211, 36.3 s |
| Envelopes read again by the restores | 326377, a mean of 102 for each ingestion |

`State.ingestValidated` holds one reader place for each envelope. In that
place it restores the projection of the run from sequence 0 with
`restoreProjectionCut`. `readEnvelope` reads each earlier envelope with at
least two SQL reads. So one ingestion costs SQL reads in proportion to the
length of the run log, and a run of n envelopes costs reads in proportion to
n squared. The restores made at least 652754 of the 689919 SQL reads
(95 percent). They took 90 percent of the time that ingestion held a reader
place, and ingestion held 49 percent of all reader-place time.

## Experiments

Two temporary changes measured the effect of each candidate site. Each
change ran in one build and one run, and each was removed after its run.

- **A.** An ingestion commit did not advance the authorization cell. This
  approximates the authorization revision split.
- **B.** The projection restore of a run continued from an in-memory
  checkpoint of the same run at a lower sequence, and it kept the existing
  comparison with the stored boundary. This approximates a replay that
  starts from a validated checkpoint.

| Value | Counters | A | B | A and B |
| --- | --- | --- | --- | --- |
| Load at start, at end | 4.1, 5.37 | 5.82, 18.1 | 10.71, 6.7 | 4.79, 5.5 |
| `events.catch-up-p50-ms` | 2174.2 | 2308.4 | 260.2 | 681.6 |
| `events.catch-up-p95-ms` | 16418.0 | 14468.7 | 4215.4 | 1950.6 |
| `events.delivery-p95-ms` | 25821.0 | 48393.5 | 11149.7 | 11554.1 |
| `slow.independent-terminal-ms` | 37789.1 | 50810.4 | 13997.2 | 13232.3 |
| `slow.pending-bytes-max` | 417738 | 427964 | 1665640 | 418576 |
| `events.refused-reads` | 9 | 42 | 2 | 0 |
| Ceiling keys outside their ceilings | 2 | 2 | 1 | 0 |
| Revalidation retries / attempts | 6552 / 18575 | 568 / 14037 | 6452 / 17242 | 480 / 12459 |
| SQL reads | 689919 | 740846 | 41379 | 38694 |
| Ingestion time with a reader place held | 40.4 s | 63.5 s | 4.6 s | 7.8 s |
| Waits for a returned reader place | 52386 | 42346 | 28641 | 13536 |
| Configuration loans, contended | 82294, 75290 | 60468, 56715 | 58090, 55790 | 31527, 28750 |

Experiment A removed 91 percent of the revalidation retries. It did not
lower the catch-up or the delivery time in its run, because the
full-prefix restore still held the reader places. The host load of that run
rose to 18.1, so its latency values are uncertain.

Experiment B moved both catch-up keys within their ceilings, and it lowered
the delivery time and the late terminal status by more than half. In that
run the stopped reader stopped for 19.5 seconds only. The manager did not
end its connection, and the reader read 1665640 pending bytes. So
`slow.pending-bytes-max` was outside its ceiling of 1048576. The manager
source has no count of pending transport bytes. A stopped reader ends only
when one write of a batch, with its revalidations, exceeds the five-second
write deadline. The contract (`doc/api/README.md`) states at most 1048576
pending transport bytes for each reader. In the other runs the write
deadline ended the stopped reader before 1048576 bytes were pending. In run
B it did not.

The run with A and B together had all 14 ceiling keys within their
ceilings. Its ingestion still waited 137 seconds in total for reader places,
and the terminal status still came about 13 seconds late. The remaining
cost is the reader admission: each returned place admits every waiting
reader again through the configuration guard.

## Dominant cost

The dominant cost is the full-prefix projection replay in
`State.ingestValidated`, through `State.restoreProjectionCut` and
`State.readEnvelope`. In the counter run it made 95 percent of the SQL reads
and Store gate acquisitions and used 49 percent of all reader-place time. The
ingestion of each envelope waits for one of the two reader places and then
holds it for a replay of the whole run log. Ingestion falls behind the
runtime, so the manager observes terminal run status 38 to 45 seconds late.
Every fresh revalidation and every stream batch also waits for a reader
place, and the waiters admit again through the configuration guard, which
was 91 percent contended.

The grounding of the subtask is confirmed in part:

- `Store.runWithAdmission` advances the authorization cell after every
  commit that changed rows, and ingestion commits are 86 percent of these
  advances. The revalidations retry their facts read 0.54 times on average,
  so the retries are a real cost. They are not the dominant cost: their
  removal alone (experiment A) did not lower the latency.
- `State.ingestValidated` holds a reader place for each runtime envelope.
  This is the dominant cost, because of the replay that it runs in the
  place.

## Decision for PG3

PG3 takes a different site first, at its owner `State`. The ingestion of an
envelope continues the projection of its run from a validated checkpoint and
no longer replays the run log from sequence 0. The checkpoint stays valid
because the stored boundary of the run holds `lastSequence` and
`snapshotSha256`, and the restore already compares the projection with that
boundary. The source already marks this point with a `ponytail:` note at
`State.restoreRunProjection`. Then PG3 takes the authorization revision split
at `Store` and `Authorization`, so that only a commit that changes
authorization facts advances the cell that revalidation observes.

The reason is the measurement. The replay change alone (B) brought both
catch-up keys within their ceilings and cut the SQL reads by 94 percent. The
split alone (A) removed the retries but did not change the latency. Only the
two together (A and B) had every ceiling key within its ceiling. After PG3,
`capacity-streams` runs once more. Two items stay open for their owners
after PG3:

- The reader admission in `Store.withStoreReaderLoan` takes a configuration
  loan for every wakeup of a waiting reader. After A and B it still causes a
  wait of 137 seconds in total for ingestion and a terminal status about 13
  seconds late.
- The pending-transport-byte bound of `doc/api/README.md` has no count at
  the writer. Its ceiling held in the baseline and in the counter run
  because the write deadline ended the stopped reader first, and it did not
  hold in run B.

## Evidence

The logs, the counter totals, the patch of the temporary counters and the
experiments, and the kept fixture roots are in the private evidence
directory of the subtask
(`resume-20260923/PG/PG2/impl-r1`): `capacity-streams-before.log`,
`capacity-streams-counters.log`, `capacity-streams-expA.log`,
`capacity-streams-expB.log`, `capacity-streams-expAB.log`, the matching
`capacity-streams-*.json` and `*-server-streams.stderr` files, the
`*-diag-*.txt` counter totals and `diag-final.patch`.
