# Engine maintenance

Every concrete engine depends on `api` and never on the DSL, the planner, the
runtime, the CLI, conformance support, or a sibling engine. Decode, retry,
fail-over, and memo policy stay in the runtime. Model routing and the loading of
definition files stay in the CLI. Preserve the protocol, the permissions, the
completion evidence, and the failure wording of each transport. Do not add a
new transport directory or a placeholder until the transport is implemented in
full.
