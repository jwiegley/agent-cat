# Workflow manager storage scope amendment

This record amends the SQLite acceptance scope of the
[implementation plan](workflow-manager-implementation-plan.md), following the
operator's instruction on 2026-09-12:

> Skip this test, drop the requirement. I want to continue.

The original design and implementation plan remain historical records. This
amendment supersedes their SQLite directory-replacement confinement obligation
in decision D2 and WM-007, including that obligation as a prerequisite for
WM-009 and G0. It does not change the dependency graph or any other package's
acceptance criteria.

## Withdrawn obligation

The selected binding's initial-open and database, WAL, and shared-memory
companion-file confinement experiment under directory replacement is omitted.
The manager does not claim that SQLite pathname operations remain confined to
a retained directory when that directory or an ancestor is replaced. Retaining
or revalidating a `PrivateRoot` is not evidence of such a SQLite guarantee.

The experiment did not run and has no passing result. The provider restriction
on the rejected experiment remains in force. Neither this scope amendment nor
continuation of ordinary database implementation authorizes retrying that
experiment, reconstructing it through another route, or adding a custom VFS.

## Retained contract

Manager database storage uses an operator-controlled private directory on a
local filesystem. Its pathname and ancestor namespace remain stable while the
manager is active. Moving the root or restoring database files requires an
offline procedure, not replacement beneath a running service. Concurrent
namespace replacement can invalidate pathname-based storage assumptions and is
outside the SQLite confinement guarantee now specified for this project.

Existing private ownership and permissions checks, root-role refusal, configured
root separation, no-follow checks, and their regression tests remain intact.
Ordinary SQLite transaction, rollback, migration, locking, backup, WAL,
`synchronous=FULL`, and error-handling obligations remain in their owning
packages. Durability claims remain limited to their actual evidence.

The shared immutable-capture publication contract is unchanged. Its retained
parent descriptors, no-clobber installation, synchronization, revalidation,
directory-replacement checks, and explicit uncertain outcomes remain required.
Existing Store and export semantics remain unchanged.

## Acceptance accounting

WM-007 may close on its independently accepted durable-publication work after
recording this withdrawal. Such closure does not certify the original SQLite
confinement clause. G0 and subsequent work use the amended scope and retain the
omitted experiment as a documented limitation, never as a successful check.
