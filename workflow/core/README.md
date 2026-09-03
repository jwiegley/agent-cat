# workflow/core

`agentic-workflow-core` owns stable, generally useful workflow definitions.

## Public API

`Workflow.Core.Harden` exports the canonical flagship `hardenProgram`, consumed by
both CLI and bisimulation.

## Dependencies and adjacent modules

The sole local dependency is `agentic-dsl`. CLI registers the value; bisim imports
the same value through a test-only edge. No sibling workflow or runtime package is
allowed.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-workflow-core
./bisim/ci/tier0.sh
```

## Conventions

Keep model references symbolic and behavior engine-independent. Registry, help,
model definitions, execution fixtures, planning, and pricing stay outside.
