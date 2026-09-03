# Extra workflow maintenance

Import only `dsl` modules and standard libraries. Keep model and profile
references symbolic and avoid runtime or engine assumptions. Keep the shared
prompt text single-sourced between the workflow definitions and the CLI
fixtures. Registry, help, routing, and scripted execution behavior belong in
`cli`.
