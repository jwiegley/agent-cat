# Manager implementation boundary

This directory currently contains dependency probes and the manager import
policy. It does not yet contain a workflow-manager service. Implementation
follows the [approved design](../doc/research/workflow-manager.md) and its
[work packages](../doc/research/workflow-manager-implementation-plan.md).

## Selected facilities

The dependency evaluation on 2026-09-10 selected WAI 3.2.4, Warp 3.4.9,
warp-tls 3.4.14, and direct-sqlite 2.3.29 from the pinned Nix package set. The
SQLite binding uses its standard `systemlib` flag and the pinned SQLite 3.53.3,
not its bundled SQLite 3.45.0. The latter predates the
[WAL-reset correction](https://sqlite.org/wal.html#walresetbug).

Direct-sqlite supplies the public `open2`, `SQLOpenNoFollow`, statement, binding,
and backup interfaces needed at the storage boundary. The evaluation did not
select sqlite-simple, whose public opening interface does not expose these
flags. No internal connection constructor or alternate database implementation
is required. Production package dependencies are added when production code
first uses them, while the development shell already supplies the probe tools.

Cabal gates use `test/cabal.sh`, which disables repositories and isolates its
store below `CABAL_BUILDDIR`. This prevents a user-level Cabal store from mixing
a different TLS package instance with the Nix-provided HTTP client/server
libraries. No source download or dependency installation through Cabal is part
of the gate.

## Executable evidence

Run the probe in the configured development environment:

```sh
direnv exec . bash manager/ci/dependencies.sh
```

Build products and fresh private fixtures are placed below `CABAL_BUILDDIR` in
`~/Products`. The probe exercises the actual linked SQLite version, WAL and FULL
settings, bound Unicode values, transaction rollback, reader snapshots, database
symlink refusal, and replacement refusal through the shared `PrivateRoot` guard.
It also exercises bounded chunked HTTP input, incremental response flushing,
stream cleanup after client cancellation, a TLS 1.3 listener, certificate
validation, and plaintext refusal. These are library integration fixtures, not
manager endpoints or workflow executions.

The initial raw SQLite probe did not establish root-ownership refusal after an
open WAL database's parent directory was renamed. SQLite is not a substitute
for `PrivateRoot`. The retained-root probe requires the existing shared guard
to reject the replacement before an application write and checks that both the
retained database and substituted directory remain unchanged. WM-007 still owns
initial-open races, WAL/shared-memory companion-file handling, concurrent root
replacement, and publication durability. A successful pragma query is not a
power-loss test.

## Process containment

`containment_probe.py` demonstrates the limit of process-group termination:
a descendant that creates a new session survives termination of the original
group. The fixture then terminates that descendant through its retained private
pipe and checks cleanup. This is negative capability evidence, not a passing
claim of service containment.

The Linux candidate is a service control group with finite stop deadlines,
`KillMode=control-group`, and final killing enabled. The
[upstream systemd kill contract](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml)
states that this covers the unit's remaining control-group members. Actual
Linux execution and adversarial descendant tests remain required in WM-019.

The installed macOS `launchd.plist(5)` documentation, under
`AbandonProcessGroup`, promises cleanup only for processes with the job's
process-group ID. It therefore does not establish the stronger containment
contract. The existing native supervisor and control-EOF cleanup remain useful,
but they do not justify an unattended macOS capability by themselves. WM-019
must establish the stronger boundary or keep that release capability blocked.
No service installation or platform-containment acceptance is claimed here.

## Module policy

Server code may depend on the shared `Agentic.Runtime` facade and manager-owned
modules, not CLI composition, authoring, concrete engines, or runtime internals.
Client modules depend on their own implementation and public manager protocol
modules, without server state, runtime interpretation, SQLite, or WAI. Public
protocol modules do not depend on either side's implementation. The TUI receives
only the exact `Agentic.Manager.Client` facade exception.

The compiler-parsed gate in `test/source-boundaries.hs` enforces these rules
with positive and negative fixtures. It also rejects manager dependencies from
lower layers and preserves the existing terminal and runtime boundaries. No
empty public facade is introduced merely to make a package directory exist.
