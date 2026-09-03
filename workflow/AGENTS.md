# Workflow maintenance

- Every workflow source may import only DSL authoring modules.
- Do not import or describe planner, cost, runtime, routing, engines, CLI, Pi, or
  concrete provider/model implementation details.
- Keep model references symbolic.
- Put registry/help/scripted-execution metadata in `cli`, not here.
- Preserve canonical program values consumed by both CLI and bisimulation.
