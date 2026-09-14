# Operator configuration

The operator file is private local authority. It is not an HTTP request, a
historical manifest, or a process-reported identity. The CLI loads it through
`loadManagerConfiguration`, installs it through `openManagerConfiguration`, and
reloads an installed binding through `reloadManagerConfiguration`. Each function
takes the existing CLI registry. Target validation calls the same `parseTarget`
and `chooseTarget` functions used by native commands, together with the existing
credential-bearing adapter argument policy. The CLI also supplies that same
credential predicate for every installed runner prefix. It does not look up a
workflow or load routing files.

## Version 1 format

The file is a JSON object with exactly six required fields:

- `version` is the integer 1.
- `managerRoot` is an absolute path to an existing private manager directory.
- `localRetentionRoots` lists absolute paths owned by configured local retention.
- `runners` lists installed runner definitions.
- `limits` contains the configurable fields of the frozen manager Limits contract.
- `profiles` lists installed profile definitions.

A runner has exactly `alias`, `executable`, and `prefix`. The executable is
absolute, and the prefix is an ordered array of argument strings. The native
FrontendInvocation codec validates aliases and invocation bounds. A profile
references a runner alias rather than copying process-reported executable data.
All runner definitions are checked, including definitions not used by a profile
and files containing no profiles. Prefix arguments that match the existing CLI
credential predicate, such as `--api-key`, refuse the complete file before root
marker publication or discovery. Active reload refuses them without changing
installed revisions, limits, or root ownership. Arbitrary wrapper prefixes are
not parsed as native target options, so non-native flags such as `--wrapper-mode`
remain valid. This reuses the existing conservative credential-word policy and
does not claim to detect secrets in every possible encoding.

A profile has exactly `id`, `runner`, `workspace`, `workspaceLabel`, `targetLabel`,
`targetArguments`, `environment`, `ownership`, `quarantined`, `personAnswering`,
and `resourceKeys`. The workspace is an operator-authorized absolute cwd. Target
arguments are ordered native CLI target options, without workflow inputs.
Environment bindings are an ordered array of objects with exactly `name` and
`value`. Values are literal strings, not ambient environment lookups. No manager
client or administrator environment is inherited. Profile validation rejects the
exact Runtime frontend-owned environment names before discovery or launch,
including empty values. Those bindings belong to the native proxy/bootstrap.
Other explicitly configured environment values are not silently rewritten.

Ownership is `service-owned` or `client-bound`. Client-bound profiles are refused
by this service configuration loader. The presence of any
`AGENT_CAT_PI_BRIDGE_SOCKET`, `AGENT_CAT_PI_BRIDGE_TOKEN_FILE`,
`AGENT_CAT_PI_REMOTE_SOCKET`, or `AGENT_CAT_PI_REMOTE_SESSION` environment binding
also refuses configuration, even when ownership says `service-owned`.
Quarantined service-owned profiles may be installed but cannot be selected or
probed. Ownership is an operator assertion about the complete target policy,
including named routes. Neither ACP transport nor executable naming proves it.

Person answering uses the native `engine` or `local-control` codec. Resource
keys identify operator-classified exclusive resources. They are not inferred
from labels, workflow names, or filenames. An empty list declares no exclusive
resource keys. The coordinator remains responsible for reservations and for
conservative scheduling of unclassified shared resources.

The limits object has exactly these required fields:

| Field | Inclusive bounds | Contract scope |
| --- | --- | --- |
| `drafts` | 1 to 2147483647 | Draft allowance under the frozen contract. |
| `globalDrafts` | 1 to 2147483647 | Global draft capacity. |
| `globalCaptureBytes` | 1 to 2147483647 | Global capture capacity. |
| `globalPageSets` | 1 to 2147483647 | Global page-set capacity. |
| `globalConnections` | 1 to 2147483647 | Global connection capacity. |
| `globalDatabaseReaders` | 1 to 2147483647 | Global database-reader capacity. |
| `globalMutationLedgerBytes` | 1 to 2147483647 | Global mutation-ledger capacity. |
| `safetyControlsPerMinute` | 1 to 2147483647 | Independent safety-control capacity. |
| `executionReservations` | 1 to 16 | Coordinator execution reservations, initially one. |

All other Limits fields remain fixed by the frozen contract and are not
configuration options. This module captures limits. The command layer enforces its current logical
ledger and mutation-rate limits under the same configuration boundary.
Each profile context retains the same configuration-limits snapshot. It is not
a per-profile quota allocation, and capacities are not multiplied by profile
count. Older selections retain facts about their revision, not authority to
bypass current coordinator limits.

For example, an operator file for a native scripted target has this shape:

```json
{
  "version": 1,
  "managerRoot": "/srv/agent-cat-manager",
  "localRetentionRoots": ["/srv/agent-cat-local"],
  "runners": [
    {"alias": "native", "executable": "/usr/local/bin/agentic-run", "prefix": []}
  ],
  "limits": {
    "drafts": 100,
    "globalDrafts": 1000,
    "globalCaptureBytes": 67108864,
    "globalPageSets": 10,
    "globalConnections": 32,
    "globalDatabaseReaders": 4,
    "globalMutationLedgerBytes": 67108864,
    "safetyControlsPerMinute": 60,
    "executionReservations": 1
  },
  "profiles": [
    {
      "id": "main",
      "runner": "native",
      "workspace": "/srv/review-workspace",
      "workspaceLabel": "Review workspace",
      "targetLabel": "Deterministic worker",
      "targetArguments": ["--scripted"],
      "environment": [{"name": "LANG", "value": "C.UTF-8"}],
      "ownership": "service-owned",
      "quarantined": false,
      "personAnswering": "local-control",
      "resourceKeys": ["workspace_review"]
    }
  ]
}
```

`cli/test/ManagerConfigurationProbe.hs` constructs and loads a private instance of this format
with real fixture executable and directory paths. It preserves the accepted
bytes as `valid-operator-v1.json` with mode 0600 in each emitted test directory.
That fixture uses synthetic credentials and native capability and descriptor
codecs. It is not a provider or service fixture.

## Bounds and file ownership

The configuration path must be absolute. Runtime opens every component without
following symbolic links and checks the opened file before reading it. The file
must be regular, owned by the effective user, and have no group or other access.
Its maximum size is 2097152 bytes. JSON may contain at most 64 nested containers.
Duplicate keys, including equivalent escaped keys, are rejected before Aeson
object maps can discard them. Unknown fields and missing required fields refuse.
Failures expose only fixed diagnostic categories.

Version 1 accepts at most 256 runners, profiles, local-retention roots, resource
keys per profile, and environment bindings per profile. Definitions and resource
keys must be distinct within their respective collections. IDs and resource keys
use 1 to 128 ASCII letters, digits, underscores, or hyphens. Public labels have a
4096 Unicode-character bound. Paths have a 4096-character bound. Environment
names have a 128-character bound, and values have a 65536-character bound. Native
environment constraints reject empty names, equals signs in names, and NULs.
Ordered argument arrays contain at most 4096 strings and at most 65536 aggregate
UTF-8 bytes. No path, argument, or environment binding may contain NUL.

The operator should replace files atomically rather than rewrite a live inode.
The bounded reader retains one opened file and refuses observed size changes.
It does not protect against arbitrary concurrent in-place writes by the same
trusted OS principal.

## Root and reload lifecycle

Before installation, the operator must durably provision the manager directory
and its ancestors. The loader never creates that tree. Initial installation opens
an existing PrivateRoot and acquires an exclusive nonblocking native directory
lease before validating separation and publishing any role marker. It validates
all policy and then uses the existing durable manager-role establishment
contract. An unmarked root must be empty. A role marker whose
publication was uncertain is not removed as rollback.

Installed operations retain the original PrivateRoot. Selection, snapshot reads,
probes, and reloads require its current identity, a valid existing manager role,
and root separation. Active reload additionally requires the same root path
binding. It never repairs a missing marker, transfers the root, or releases its
ownership when profiles are removed. Closing the handle closes its descriptor,
not the marker. An active coordination store retains a duplicate lease until its
own scope ends. A changed root requires a separate installation lifecycle, while
the old root remains manager-owned. Distinct opens in the same process and
other processes cannot acquire the same lease. Lease descriptors close on exec.

A configuration lock serializes probing, reload, and snapshot publication. A
probe holds it across both native queries. Successful reload changes all profile
revisions and the limits snapshot together. Even unchanged definitions receive
fresh revisions. Invalid candidates preserve installed revisions and limits.
The private profile registry is not exposed by InstalledConfiguration. A hidden
fail-fast snapshot callback holds this same lock through command acceptance,
with configuration-before-store lock ordering. It prevents reload or close from
interleaving with a command while adding no waiting mutation queue.

The parent coordinator must serialize approval commitment with configuration
reload, invalidate old unapproved selections, and retain the captured context of
already approved workers. A Selection is not approval. Actual worker launch must
use its explicit environment and authorized cwd. Installation acquires the
service ownership lease but creates no worker or approval implementation. The scoped [coordination store](STORAGE.md) uses this
same installed binding, with one active store slot per installation.

Program-dependent routing remains owned by actual native preparation. Parsing
argv and capturing literal environment values do not freeze executable contents,
workspace files, or referenced routing configuration. The operator must reload
when those policy inputs change, and the coordinator must validate effective
prepared policy and ownership before approval. The existing routing fingerprint
is not a credential-version token. Arbitrary trusted executable code is not
sandboxed.

## Retained native prepared association

Haskell composition supplies both TargetValidator and PreparedTargetValidator to
loadConfiguration. The latter is pure and retained with each immutable profile and
Selection, without serialized function identity. Metadata-only callers explicitly
use exactPreparedTarget. CLI composition uses the actual native parser and checks
exact arguments or its authorized ACP scratch derivation against the same bound
Worker response. It performs no later routing-file IO during acceptance and does
not grant execution from an unbound prepared DTO. Reload preserves the existing
revision/lifetime fence for unapproved selections.
