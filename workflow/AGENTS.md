# Workflow maintenance

A workflow source imports only the DSL authoring modules. It never imports or
describes the planner, cost, runtime, routing, engines, the CLI, Pi, or a
concrete provider or model. Model references stay symbolic. Registry, help,
and scripted-execution metadata belong in `cli`. Preserve the canonical
program values that both the CLI and the conformance suite consume.
