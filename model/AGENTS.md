# Model maintenance

- Treat Lean as the normative mathematical specification.
- Run `nix develop path:. -c lake build` after changes.
- Never run concurrent full builds: `Agentic.Core.DslFlagship` is memory-heavy.
- Keep conformance/oracle/corpus code in `../bisim`; dependencies point from
  bisim to model, never back.
- Do not add Haskell, runtime, engine, CLI, protocol, or filesystem policy here.
- Preserve theorem meaning and kernel checks; a corpus change requires explicit
  specification approval.
