# TUI maintenance

The local TUI is a process frontend. Import descriptor, protocol, control,
snapshot, store-reference, and catalogue contracts from `Agentic.Runtime`.
Service-client code may import the public `Agentic.Manager.Client` facade,
not manager server code or client implementation submodules. Never import
`Agentic.Cli`, DSL authoring types, plans, costs, workflow registries, or
concrete engines. Local mode launches the configured executable by direct argv
in machine mode. Keep navigation and reduction pure. Brick owns drawing and terminal
events only. Protocol frames are lossless and ordered, repaint notifications
may coalesce, and all in-memory text, subprocess output, files, and diagnostics
are bounded. Render untrusted text through Brick/Vty widgets, never as terminal
escapes. Every action remains keyboard reachable. Test pure projections first,
then fixed-size rendering and deterministic PTY process behavior. Support macOS
and Linux only until the machine-control process contract is portable.
