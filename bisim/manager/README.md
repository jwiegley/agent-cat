# Manager conformance

This directory holds the Lean side of the manager conformance lane. The lane
is separate from the workflow conformance lane of `bisim/lean` and from the
frozen corpus of `bisim/corpus`. It compares an implementation of the
coordination state with the coordination model of `model/Agentic/Manager`.

## Layout

| Path | Contents |
| --- | --- |
| `ManagerConformance/Exec.lean` | The model at string identities and values, the finite evidence table, and the deciders of `openDecision`, `answer`, `resolve`, `release` and `verify`. |
| `ManagerConformance/Admission.lean` | The finite forms of the admission and approval guards, and the deciders of `admit` and `approve`. |
| `ManagerConformance/Witnesses.lean` | The closed witness states and evidence tables. |
| `ManagerConformance/Codec.lean` | The pinned encoding, the history entry, the step of the oracle, and the round trips of the witnesses. |
| `ManagerConformance/Checks.lean` | The decider witnesses and the axiom footprints. |
| `ManagerConformance/Cases.lean` | The retained cases with their outcomes. |
| `ManagerOracle.lean` | The executable `manager-oracle`. |
| `ManagerCases.lean` | The executable `manager-cases`, which writes `cases/`. |
| `cases/` | The retained requests and their expected responses. |

The import closure contains `Agentic.Manager.*`, Lean core, and the closure
of `Mathlib.Data.Finmap`. It contains no `Agentic.Core` module and not the
root module of the model.

## Build and run

Run each command from the root of the repository, through the project
environment.

```sh
lake --dir bisim build --wfail ManagerConformance manager-oracle manager-cases
for request in bisim/manager/cases/*.request.json; do
  bisim/.lake/build/bin/manager-oracle < "$request" |
    diff - "${request%.request.json}.expected.json" || echo "FAIL $request"
done
```

The build elaborates every `#guard` of the library. A changed outcome, a
broken round trip or a new axiom fails the build. The loop replays each
retained request through the oracle and compares the response with the
retained response byte for byte.

The command `bisim/.lake/build/bin/manager-cases bisim/manager/cases` writes
the retained cases again. After it runs, `git status --short
bisim/manager/cases` must be empty unless a case or the encoding changed.

## The oracle

`manager-oracle` reads one request per line on standard input and writes one
response per line on standard output. It ignores an empty line and stops at
the end of its input. It reads no clock, file or environment variable.

A request is an object with exactly four fields.

| Field | Value |
| --- | --- |
| `version` | The string `agent-cat-manager-conformance/1`. |
| `state` | A coordination state. |
| `evidence` | An evidence table. |
| `entry` | One history entry. |

The response has one of three forms.

| Response | Meaning |
| --- | --- |
| `{"accepted":true,"state":S}` | The entry is accepted, and `S` is the next state. |
| `{"accepted":false}` | The model refuses the entry. The response gives no reason. |
| `{"error":M}` | The request is not valid JSON, or the decoder refuses it. The response has no state. |

The decoder reads the version before any other field. A version other than
`agent-cat-manager-conformance/1` receives an error. A missing field, an
unknown field at any depth, an unknown tag, an unknown enumeration value, or
a set or map that is not in strictly increasing order also receives an error.

## Scope of the oracle

The oracle evaluates only the abstract coordination transitions. For a
transition entry, it applies the decider of that transition, or
`Coordination.delivery` for a `delivery` entry. The theorem `Step.exec_eq`
proves that each decider equals its model transition at the evidence of the
table. The theorem `step_eq` proves that the step of the oracle is the
coordination step of `Agentic.Manager.Meaning` over the model transitions.
For an observation entry, the oracle returns the state unchanged.

The oracle does not evaluate the runtime fold of observations, the HTTP
service, SQLite storage, process containment, delivery to a worker, or a
physical engine effect. A response of the oracle makes no claim about these
boundaries.

## The encoding

### Representation

Every identity and every value of the model is a JSON string. The model is
instantiated at `I = String` and `V = String`. The oracle gives no meaning to
the content of a string. Two strings are equal only when they have the same
characters.

The order of strings is the order of their Unicode code points. For UTF-8
text, this order is the byte order. Sets and map keys use this order.

| Model value | JSON value |
| --- | --- |
| Identity or value | A string. |
| `Bool` | `true` or `false`. |
| `Nat` | A non-negative integer. |
| `Option α` | `null` for `none`, and the encoding of the value for `some`. The field is always present. |
| `List α` | An array in the order of the list. |
| `Finset String` | An array of strings in strictly increasing order. |
| `Finmap` with string keys | An array of two-element arrays `[key, value]` in strictly increasing order of the keys. |
| An enumeration | A string that names the constructor. |
| An alternative with arguments | An object with the field `tag`, which names the alternative, and one field for each argument. |

### Field order

The encoder writes the fields of each object in increasing order of their
names. A decoder accepts the fields of an object in any order. The tables
below list the fields in the order of the model structures. The retained
files show the written order.

### Enumerations

| Type | Values |
| --- | --- |
| `RequestPhase` | `draft`, `queued`, `preparing`, `review`, `startPending`, `associated`, `withdrawn`, `refused` |
| `PreparationPhase` | `live`, `consumed`, `invalidated` |
| `Supervision` | `owned`, `cleanupPending`, `lost`, `observer` |
| `Delivery` | `notAttempted`, `attempted`, `uncertain`, `failed` |
| `Acknowledgement` | `accepted`, `queued`, `delivered`, `rejectedStale`, `unsupported`, `controlFailed` |
| `Resolution` | `resolved`, `notEffective` |

### Records

| Record | Fields |
| --- | --- |
| Readiness | `required` (set), `supplied` (map of strings), `invalid` (set) |
| Request | `revision`, `profile`, `profileRevision`, `phase` (`RequestPhase`), `queueOrdinal` (natural number or `null`), `inputs` (Readiness), `preparation` (string or `null`), `run` (string or `null`) |
| Profile | `revision`, `enabled` (Boolean), `resources` (set) |
| Reservation | `slot`, `exclusive` (set) |
| Prepared | `request`, `requestRevision`, `profile`, `profileRevision`, `run`, `nativeRun`, `worker`, `generation`, `authority`, `revision`, `digest`, `review`, `phase` (`PreparationPhase`) |
| DecisionKey | `id`, `revision`, `occurrence`, `attempt` (string or `null`), `generation` |
| Decision | `key` (DecisionKey), `command` (string or `null`) |
| Receipt | `client`, `intent` (Intent), `delivery` (`Delivery`), `acknowledgements` (array of `Acknowledgement`), `effect` (string or `null`) |

A field without a stated type is a string.

| Alternative | Tag | Fields |
| --- | --- | --- |
| Intent `start` | `start` | `prepared` (Prepared) |
| Intent `answer` | `answer` | `run`, `decision` (DecisionKey), `value` |
| Artifact `referenced` | `referenced` | `reference` |
| Artifact `verified` | `verified` | `reference`, `value` |
| Artifact `unavailable` | `unavailable` | `reference` |

### The coordination state

The state encodes every field of `Coordination String String`.

| Field | Value |
| --- | --- |
| `generation` | String. |
| `authority` | String. |
| `slots` | Set. |
| `profiles` | Map to Profile. |
| `requests` | Map to Request. |
| `reservations` | Map to Reservation. |
| `preparations` | Map to Prepared. |
| `runs` | Map to the string of a request. |
| `supervision` | Map to `Supervision`. |
| `decisions` | Map to an array of Decision. The array is the pending FIFO, head first. |
| `commands` | Map to Receipt. |
| `captures` | Map to a string value. |
| `artifacts` | Map to Artifact. |

### The evidence table

| Field | Elements |
| --- | --- |
| `live` | Prepared records that are live. |
| `unexpired` | Prepared records that are not expired. |
| `cleaned` | Objects `{owner, lease}`, with `lease` a Reservation, for confirmed cleanups. |
| `opened` | Objects `{run, key}`, with `key` a DecisionKey, for opened decisions. |
| `resolutions` | Objects `{run, key, command, resolution}`, with `resolution` a `Resolution`. |
| `verified` | Objects `{reference, value}` for verified contents. |

### The history entry

An entry is a tagged transition with its arguments, or an observation.

| Tag | Fields | Model operation |
| --- | --- | --- |
| `admit` | `id`, `request` (Request), `profile` (Profile), `lease` (Reservation) | `Coordination.admit` |
| `approve` | `command`, `client`, `preparation`, `revision`, `digest`, `prepared` (Prepared), `request` (Request), `profile` (Profile) | `Coordination.approve` |
| `openDecision` | `run`, `key` (DecisionKey) | `Coordination.openDecision` |
| `answer` | `command`, `client`, `run`, `key` (DecisionKey), `value` | `Coordination.answer` |
| `resolve` | `run`, `command`, `key` (DecisionKey), `resolution` (`Resolution`) | `Coordination.resolve` |
| `delivery` | `command`, `knowledge` (`Delivery`) | `Coordination.delivery` |
| `release` | `owner` | `Coordination.release` |
| `verify` | `artifact`, `reference`, `value` | `Coordination.verify` |
| `observation` | `run`, `event` | The identity on the coordination state. |

## Representation assumptions

- An identity is an opaque string label. It denotes no path, process handle
  or authority.
- A fact of the evidence holds exactly when the table lists it. The caller
  supplies the table. The oracle does not check the table against a worker,
  a clock, a filesystem or a transport.
- The order and the repetition of the elements of an evidence list have no
  effect on a response, because each guard tests membership only. The
  encoder keeps the order of the list.
- The order of a decision array is significant. It is the FIFO order of the
  pending decisions of a run.
- A map has at most one value for each key, and a set has no repeated
  element. The decoder refuses a repeated key or element, because each
  array must be strictly increasing.
- The slot and the keys of a reservation are separate domains in the model.
  The encoding writes `slot` and `exclusive` as given and does not write the
  derived union.
- The event of an observation is an opaque string. Its coordination effect
  reaches the state only through the explicit transitions that it justifies,
  so an observation entry does not change the state.

## Retained cases

Each case in `cases/` is the pair `<name>.request.json` and
`<name>.expected.json`. Each file holds one line.

| Prefix | Source |
| --- | --- |
| `model-` | The scenarios of `model/test/ManagerChecks.lean`, at the decimal strings of the natural-number identities of that file. A chained scenario is one case for each entry. Its intermediate states are fixed by `#guard`. |
| No prefix | The witnesses of the deciders in `ManagerConformance/Checks.lean`. |
| `error-` | Malformed requests: an unknown or missing version, an unknown field of the request or of the state, an unknown entry tag, an unsorted set, and text that is not JSON. |

The cases contain accepted and refused entries. `ManagerConformance/Cases.lean`
fixes the outcome of each case and the round trip of each request.

## The Haskell lanes

The executable `manager-conformance-check` of `agentic.cabal` holds the
Haskell side of the lane. Its module `manager/test/Agentic/Manager/Test/Oracle.hs`
holds the encoding of this file as typed records, and the connection to one
`manager-oracle` process. The decoder of the module refuses the same
malformed requests as the decoder of the oracle.

The executable takes the oracle from `--oracle`, else from the environment
variable `ORACLE`, else from `bisim/.lake/build/bin/manager-oracle`. It does
not build the oracle. A missing or non-executable binary stops the lane with
status 1 and the message `oracle binary not found, and the lane is not green`. A
closed pipe, a response that is not in the encoding, or no response within 60
seconds also stops the lane with status 1.

Run each lane from the root of the repository, after the oracle is built.

```sh
bash test/cabal.sh build manager-conformance-check
check=$(bash test/cabal.sh list-bin manager-conformance-check)
"$check" admission --seed 20261002 --n 500 --counterexamples "$TMPDIR/manager-cx"
"$check" cases --cases bisim/manager/cases --counterexamples "$TMPDIR/manager-cx"
```

### The admission lane

The lane compares `oldestEligible` of `Agentic.Manager.Admission.Policy`
with the `admit` decider of the oracle. QuickCheck generators with a fixed
`QCGen` make the situations from the seed. The default seed is `20261002`,
and the default number of situations is 500. Each situation has a slot limit
from one to four, one to four profiles, one to six queued candidates, and
held reservations. A profile has a subset of four operator keys, or the
unclassified cohort when the subset is empty, and it can be disabled. A
candidate has a profile, a distinct queue ordinal, and inputs that are ready,
missing or invalid. The held reservations occupy distinct slots below the
limit and hold disjoint keys, as the reservation exclusivity of the model
requires.

The lane encodes a situation as a coordination state. The slots are
`slot-0` to `slot-<limit-1>`. An operator key `k` is the string `key:k`, and
the unclassified cohort is the string `unclassified`. A held reservation has
the owner `held-<slot>`. Each candidate is a queued request whose profile
revision is the revision of its profile.

For each candidate at each slot, the lane submits one `admit` entry with the
stored profile and a lease of the keys of that profile. The responses must
agree with the choice of `oldestEligible`.

| Choice of `oldestEligible` | Required response |
| --- | --- |
| The candidate at the chosen slot | Accepted, with the state that admits the candidate at that slot. |
| The chosen candidate at another slot | Any response except an error. The model accepts the candidate at any free slot, and the policy chooses the lowest. |
| Another candidate | Refused. |
| No candidate | Refused for every candidate and every slot. |

The lane prints the number of situations with a choice (`accepted`) and
without a choice (`refused`), and the number of responses of each kind. A run
that does not contain both accepted and refused situations fails.

### The cases lane

The lane replays each request of `bisim/manager/cases`, or of the directory
that `--cases` names. The response of the oracle must equal the retained
response byte for byte. The typed decoder must refuse each request whose
retained response is an error. For every other request, the typed decoder
must read the request, and the typed encoder must write the request and the
retained response back to the same bytes.

### Mismatches

A mismatch writes the file `<counterexamples>/<n>.json`, prints
`MANAGER-CONFORMANCE mismatch`, and makes the lane exit with status 1 after
the last situation or case. In the admission lane, `<n>` is the index of the
situation, and the file holds the first disagreeing request of the
situation. In the cases lane, `<n>` is the name of the case. The file holds
the seed (`null` for a case), the reason, the request, the expected outcome
and the response of the oracle. The default directory is
`manager-conformance-counterexamples` in the temporary directory of the
system.

### Limits of the admission lane

The lane does not generate a held slot at or above the limit. The policy
counts every held reservation against the limit, so a reservation that a
capacity reduction leaves above the limit can exhaust the capacity. The model
has no limit apart from its set of slots, and it admits a candidate at any
slot of that set that no reservation holds. The model therefore states no
outcome for a reduced capacity.
