# dsl

`dsl/src` is the pure authoring layer of the `agentic` package and the root of
its dependency graph. It owns the raw first-order syntax, the schema and text
vocabulary, the typed structural AST, the builder that elaborates authored
constructions into a `RawProgram` and a typed `Plan` at once, the prompt
quasiquoters, and the `QualifiedDo` workflow surface. It does not plan, price,
execute, route, or select engines.

## Public modules

A workflow author imports `Agentic.Workflow` for the authoring vocabulary,
`Agentic.Workflow.Do` qualified as `W` for the block grammar, `Agentic.WF` for
the `[wf|...|]` and `[wft|...|]` quasiquoters, and `Agentic.Schema` with its
`Json` and `TH` companions for structured answers. Infrastructure consumers use
three smaller facades: `Agentic.DSL` for the raw syntax, its canonical text and
JSON rules, and shared data; `Agentic.DSL.Plan` for the typed structural AST;
and `Agentic.Builder` for typed elaboration. The implementation modules
`Agentic.Raw`, `Agentic.Text`, and `Agentic.DSL.Json` are hidden by the Cabal
file, so no other directory can reach them.

## Dependencies

This directory depends on no other agent-cat directory. `plan`, `runtime`
through `plan`, every `workflow` directory, and `bisim` depend on it. A workflow
imports symbolic model and profile names only; concrete models, routing,
sessions, engines, cost, and execution are absent from this layer. A workflow
that wants one of the four runner-supplied run facts declares it with an
ordinary `input` under the reserved `run.` prefix; the Text-only
`Agentic.Runtime.Facts` module that names and reads those facts is imported by
hosts such as the CLI, never by a workflow.

## Build and test

The directory builds as part of the single package from the repository root:

```sh
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
./cli/ci/policies.sh
```

The frozen corpus pins the raw encoding and the printed output of the authoring
surface, so a change here that moves those bytes is a change to the
specification.

## Conventions

Keep the AST typed and engine-independent, and add a shared authoring capability
only when every supported engine can realize it. Do not inspect runtime, route,
session, engine, plan-analysis, or cost state. Keep model references symbolic;
model-definition files belong to `cli`. Preserve the raw encoding and the
authoring output unless the specification is being changed deliberately.
