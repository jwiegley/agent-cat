# dsl

`agentic-dsl` is the pure Haskell authoring layer for agent-cat workflows. It
owns the typed structural AST, raw wire syntax, schema and text vocabulary,
builder, prompt quasiquoters, and the `QualifiedDo` workflow surface. It does
not plan, price, execute, route, or select engines.

## Public API

Workflow authors normally import:

- `Agentic.Workflow`
- `Agentic.Workflow.Do`
- `Agentic.WF` for `[wf|...|]` and `[wft|...|]`
- `Agentic.Schema`, `.Json`, and `.TH` for structured answers

Infrastructure consumers use the deliberately small facade set:

- `Agentic.DSL` — raw syntax, canonical text/JSON rules, and shared data
- `Agentic.DSL.Plan` — typed structural AST
- `Agentic.Builder` — advanced typed elaboration

The implementation modules `Agentic.Raw`, `Agentic.Text`, and
`Agentic.DSL.Json` are hidden by Cabal. Cross-package imports cannot reach them.

## Dependencies

`dsl` has no dependency on another agent-cat package. Downstream edges are:

```text
plan -> dsl
runtime -> plan -> dsl
workflow/* -> dsl
bisim -> dsl
```

A workflow imports symbolic model/profile names only. Concrete models, routing,
sessions, engines, cost, and execution are absent. Authors who intentionally
need engine-neutral run facts import the separate `runtime` package; that
choice is visible in their package manifest.

## Build

From this directory:

```sh
nix develop path:.. -c cabal build agentic-dsl
```

## Conventions

- Keep the AST typed and engine-independent.
- Add shared authoring capability here only when every supported engine can
  realize it.
- Do not inspect runtime, route, session, engine, plan-analysis, or cost state.
- Keep model references symbolic; model-definition files belong to CLI
  composition.
- Preserve raw encoding and authoring output unless changing the specification
  explicitly.
