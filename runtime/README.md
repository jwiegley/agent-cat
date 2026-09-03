# runtime

`agentic-runtime` executes typed plans against any `Agentic.Engine.Engine`. It owns
scheduling, memoization, decode/re-ask, recovery and failover, effect ordering and
journaling, generic routing, controls, machine protocol, persistence,
restart/resume/fork support, and program-authored shell execution.

## Public API

`Agentic.Runtime` is the main public facade. `Agentic.Runtime.Facts` is the narrow
Text-only sub-facade for validating and presenting facts supplied by a host. Typed
execution, generic routing, control/machine protocol, persistence, and shell
realization otherwise remain behind the main facade; all seven implementation
modules are Cabal-hidden.


## Dependencies and adjacent modules

```text
runtime -> plan -> dsl
runtime -> engine/api
cli -> runtime
```

Runtime imports only Plan and engine APIs; even `Agentic.Runtime.Facts` has no DSL
types. No concrete engine, workflow package, CLI, Pi, or bisim module is allowed
here.

## Build and test

```sh
nix develop path:.. -c cabal build agentic-runtime
./cli/ci/policies.sh
```

ACP/deck gates exercise the same runtime through neutral engines.

## Conventions

Treat engines as opaque values; never dispatch on identity. Keep typed translation,
rendering, decode/retry, failover, memo, scheduling, effects, and persistence here.
Preserve protocol versions, private storage, ordering, and failure behavior.
