# Core workflow maintenance

- Import only `agentic-dsl` modules and standard libraries.
- Keep models symbolic and workflow behavior engine-independent.
- Preserve the canonical `hardenProgram` consumed by CLI and bisimulation.
- Keep registry, help, model definitions, and execution fixtures outside this package.
