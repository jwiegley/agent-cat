# Engine maintenance

Every concrete engine depends on `api` and never on the DSL, the planner, the
runtime, the CLI, conformance support, or a sibling engine. Decode, retry,
fail-over, and memo policy stay in the runtime; model routing and
definition-file loading stay in the CLI. Preserve each transport's protocol,
permissions, completion evidence, and failure wording. Do not add a new
transport directory or placeholder until it is implemented in full.
