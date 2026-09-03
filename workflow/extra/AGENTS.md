# Extra workflow maintenance

Import only `dsl` modules and standard libraries. Keep model and profile
references symbolic, and avoid assumptions about the runtime or the engines.
Keep the shared prompt text in one place for the workflow definitions and the
CLI fixtures. Registry, help, routing, and scripted execution behavior belong
in `cli`.
