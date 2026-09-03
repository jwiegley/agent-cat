# Extra workflow maintenance

- Import only `agentic-dsl` modules and standard libraries.
- Keep model/profile references symbolic and avoid runtime/engine assumptions.
- Keep shared prompt text single-sourced for workflow definitions and CLI fixtures.
- Put registry, help, routing, and scripted execution behavior in CLI.
