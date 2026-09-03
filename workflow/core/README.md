# workflow/core

`agentic-workflow-core` reserves package boundary for future stable, generally useful
workflow definitions. It intentionally contains no workflows yet.

## Public API

None. This package builds as an empty library.

## Dependencies and adjacent modules

It has no local dependencies while empty. Future workflows may depend only on
`agentic-dsl`; no runtime, engine, registry, or sibling workflow package is allowed.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-workflow-core
./cli/ci/examples.sh
```

## Conventions

When core workflows exist, keep model references symbolic and behavior
engine-independent. Registry, help, model definitions, execution fixtures, planning,
and pricing stay outside.
