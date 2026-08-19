# Coordinator note for the architecture phase: the confer workflow

*From the coordinator, 2026-08-19 — read alongside the four inventories.*

The owner has ruled that agent-cat should replace **PAL MCP** entirely. The
full analysis is `doc/research/pal-vs-agent-cat.md`; the consequence for the
architecture is one additional requirement:

**The design must include a `confer` workflow** — the designated replacement
for PAL's `consensus` tool and for the "confer via PAL for real decisions"
clause in the owner's `wiggum`/`heavy` skills. Shape: a roster of model
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
