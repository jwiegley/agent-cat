# Heavy review — 2026-08-12

Seven independent read-only passes over a frozen snapshot (deep, Alexey-discipline,
abstraction, validated-multi-model, ponytail, dead-code, comment audit); 80 raw
findings consolidated to 24. The validated pass aborted honestly (PAL provider
keys broken — acat-sb0); its machine-checked leads are folded in as single-source.
Every finding below is tracked in obr; this file preserves the review's verdict
and the finding→issue mapping.

## Verdict against the governing lens

1. **Simplest, purest?** Locally yes (no `sorry`, only `Classical.choice`, real
   quotients), globally no: the canonical objects are discovered but never named
   once — five monoid presentations, the join-order written three times, category
   laws three times, `deriv` = `withScope` proved twice.
2. **Generalized to the underlying objects?** Monoids/semirings found but
   under-unified; missing structures: idempotent-comm-monoid→order, `Preorder`,
   and a least-fixed-point axiom (`retry_fixed` has multiple solutions at `Cost`).
3. **Free of representational choices?** No: decidability hypotheses in the
   semantic layer (4 passes; excludes the trace monoid from panels, denies the
   meaning category identities at function-typed objects); panel licences proved
   about `List` folds; `Cost` ℕ-quantized with attainment-dependent completeness.

## Finding → issue

| Finding (severity) | Issue |
|---|---|
| Star unreachable at matrices; no `ConwayStar Prop`; naming overclaim (high) | acat-ruz |
| `retry_fixed` under-determines meaning; LFP axiom missing (high) | acat-zms |
| `SqZero` cannot carry a meaning; no probability carrier (high) | acat-ozh |
| Decidability in the semantic layer (high, 4 passes) | acat-192 |
| Class under-axiomatized; `CsumAdditive` derivable from two-point agreement (high) | acat-9kn |
| Panel: licences about lists, no `delta`/`conv_comm`/addition/`total_add` (high) | acat-ubt |
| Five monoid presentations; `deriv`=`withScope`; order ×3; Scope `Mul`/`One` hazard (high) | acat-47y (absorbs acat-7rm) |
| Grade under-soundness: `scale n (bounded 0)` (high) | acat-l59 (sharpened) |
| False/overclaiming prose; §-citation errors; README drift (high+medium) | acat-1lk |
| Dead weight, zero consumers (low ×10) | acat-1g4 |
| `cachedAt` tautology (medium) | acat-bf8 |
| §3 fibration absent (medium; is the pending stratum) | acat-444 (comment) |
| Context: lawless `Interior`, disconnected, wrong "four consequences" (medium) | acat-npb |
| Session: unused constraint, no product (medium) | acat-135 |
| `toMonadic` violates its own rationale (medium) | acat-ejy (comment) |
| Cost quantization breaks claimed Mathlib path (medium) | acat-467 (comment) |
| PAL MCP keys broken (environment) | acat-sb0 |

## Fix order

1 acat-1lk → 2 acat-1g4 → 3 acat-192 → 4 acat-9kn → 5 acat-47y → 6 acat-ruz →
7 acat-zms → 8 acat-ubt → 9 acat-ozh → 10 acat-l59 → then bf8, npb, 135, ejy.
Verification at every step: `direnv exec ~/src/agent-cat lake build` green and
`grep -rn sorry Agentic/` empty.
