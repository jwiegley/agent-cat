# Model maintenance

Lean is the normative specification. Run `nix develop path:. -c lake build`
after a change, and never run two full builds concurrently, because
`Agentic.Core.DslFlagship` is memory-heavy. Conformance, oracle, and corpus
code live in `../bisim`, and dependencies point from there to here, never
back. Add no Haskell, runtime, engine, CLI, protocol, or filesystem policy.
Preserve theorem meaning and kernel checks; a change to the frozen corpus
requires explicit approval as a specification change.
