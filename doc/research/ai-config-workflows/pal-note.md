# Coordinator note for the architecture phase: the confer workflow

*From the coordinator, 2026-08-19 — read alongside the four inventories.*

The owner wants agent-cat to offer **workflow-native parity with PAL MCP** —
PAL stays configured as an inline alternative, and nothing is being removed;
the goal is that avoiding it becomes a per-run choice. The full analysis is
`doc/research/pal-vs-agent-cat.md`; the consequence for the architecture is
one additional requirement:

**The design must include a `confer` workflow** — the workflow-native
counterpart of PAL's `consensus` tool, and the natural workflow-shaped
alternative wherever the owner's `wiggum`/`heavy` skills say "confer via
PAL" (an alternative offered, not a replacement mandated). Shape: a roster of model
parties, optional stance rubrics (for / against / neutral as `[wf|…|]`
defines), one question put to each, a verdict/document fold (panel or
`panelText`), and a synthesis ask. It should take the decision text and
optional file context as inputs.

Constraint to design around: today both engines bind every addressee to ONE
backend per run (`run/Main.hs:590,622`), so confer is single-backend until
`acat-engine-party-routing-hcx` (party→backend routing) lands — design the
roster so that routing slots in without changing the program text.

Also fold in, where the triage touches them: PAL's `challenge` is a one-line
anti-sycophancy rubric (a shared define, not a workflow); PAL's guided
investigations (debug/codereview/planner/precommit/…) are prior art the
corpus's own commands already cover — the triage should not invent separate
workflows to mirror PAL's tool names.
