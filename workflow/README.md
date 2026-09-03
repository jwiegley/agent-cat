# workflow

This container holds compiled workflow definitions. Each child is an independent
package whose only local dependency is [`../dsl`](../dsl).

## Scope and public APIs

- [`core`](core): empty reserved package for future stable workflows
- [`example`](example): teaching workflows via `Harden`, `Hello`, and `Structured`
- [`extra`](extra): narrower workflows via `Isaac`

The container itself has no code API.

## Dependencies and adjacent modules

```text
workflow/{example,extra} -> dsl; workflow/core -> (empty)
cli -> workflow/{example,extra}
bisim -> workflow/example (tests only)
```

Workflow packages never depend on each other.

## Build and test

```sh
nix develop path:.. -c cabal build agentic-workflow-core agentic-workflow-example agentic-workflow-extra
./cli/ci/examples.sh
./bisim/ci/tier0.sh
```

## Conventions

Definitions and authoring data only. Keep models symbolic and move registry/help,
canned execution replies, model definitions, planning, pricing, and execution above
this layer.
