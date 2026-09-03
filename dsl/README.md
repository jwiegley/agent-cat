# dsl

`dsl/src` is the pure authoring layer of the `agentic` package, and it is the
root of the dependency graph. It owns the raw first-order syntax, the schema and
text vocabulary, the typed structural tree, the builder, the prompt
quasiquoters, and the `QualifiedDo` workflow surface. The builder elaborates an
authored construction into a `RawProgram` and a typed `Plan` at the same time.
This layer does not plan, price, execute, or route a workflow, and it does not
select an engine.

## Public modules

A workflow author imports four modules. `Agentic.Workflow` provides the
authoring vocabulary. `Agentic.Workflow.Do`, imported qualified as `W`, provides
the block grammar. `Agentic.WF` provides the `[wf|...|]` and `[wft|...|]`
quasiquoters. `Agentic.Schema` and its `Json` and `TH` companions provide
structured answers. Infrastructure consumers use three smaller facades.
`Agentic.DSL` exposes the raw syntax, its canonical text and JSON rules, and
shared data. `Agentic.DSL.Plan` exposes the typed structural tree.
`Agentic.Builder` exposes typed elaboration. The implementation modules
`Agentic.Raw`, `Agentic.Text`, and `Agentic.DSL.Json` are hidden by the Cabal
file, so no other directory can reach them.

## Dependencies

This directory depends on no other agent-cat directory. The directories `plan`,
`runtime`, every `workflow` directory, and `bisim` depend on it. A workflow
imports symbolic model and profile names only. Concrete models, routing,
sessions, engines, cost, and execution are absent from this layer. A workflow
that needs one of the four runner-supplied run facts declares it with an
ordinary `input` under the reserved `run.` prefix. The Text-only module
`Agentic.Runtime.Facts` names and reads those facts, and hosts such as the CLI
import it. A workflow never imports it.

## Build and test

The directory builds as part of the single package. Run these commands from the
repository root:

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/policies.sh
```

The frozen corpus pins the raw encoding and the printed output of the authoring
surface. A change here that moves those bytes is a change to the specification.

## Conventions

Keep the tree typed and independent of engines. Add a shared authoring
capability only when every supported engine can realize it. Do not inspect
runtime, route, session, engine, plan-analysis, or cost state. Keep model
references symbolic, because model-definition files belong to `cli`. Preserve
the raw encoding and the authoring output unless the specification changes
deliberately.
