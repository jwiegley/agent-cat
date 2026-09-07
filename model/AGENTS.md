# Model maintenance

Lean is the normative specification. Verify a change with `nix develop path:.
-c lake build`, and never run two full builds at the same time, because
`Agentic.Core.DslFlagship` needs several gigabytes of memory. Conformance,
oracle, and corpus code live in `../bisim`, and dependencies point from there
to here, never back. Add no Haskell, runtime, engine, CLI, protocol, or
filesystem policy. Preserve the meaning of the theorems and the kernel checks.
A change to the frozen corpus requires explicit approval as a specification
change.
