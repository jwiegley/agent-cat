# The rounds: how the surface got here

*The owner rejected the first textual surface outright on 2026-08-14 ("this
layout you've devised is extremely confusing … sloppy and imprecise"). What
followed was one review campaign, one design competition, one survey, and
three rounds of owner-driven revision, each validated adversarially. This
file is the short history; the sibling documents carry the full text.*

## The review (seven passes, 93 findings)

Seven concurrent read-only passes over frozen snapshot `d2fc0db`, each proven
history-isolated by a sentinel probe: deep review, Alexey-discipline,
abstraction-alignment, validated multi-model (aborted per its attestation
contract — PAL had one reachable non-Anthropic model), Ponytail, dead-code,
comment audit. Findings live in `review-findings.json`, summaries in
`review-pass-summaries.md`, and eighteen obr issues. The three that shaped
the redesign: the owner's misreading of `approved given patch` was the
layout's own suggestion (three-pass convergence); `Plan.revising` had been
frozen into an eleven-field grammar production with three binders spelled
`patch`; and the DSL was the only stratum with no meaning function — surface
shape had been settled by rubric, not equation.

## The competition (round seven)

Three independent designers — mirror-the-Lean, dataflow-first, and one
blinded from the incumbent grammar per the contamination rule — nine
adversarial attacks, one synthesis. `synthesis-round7.md`. The dataflow-first
skeleton won; its properties (one binding shape, two consumption sites, the
kind at the binder, arm-lists in one shape) survive to the final design.

## The survey (round seven and a half)

Ten families of surrounding systems, 87 rated ideas, a comparison judge.
`survey.md`. Three grammar amendments adopted ({$x} define-holes; no
shadowing; per-addressee serving clause), everything else defended or
refused with reasons; twelve evidence-backed differentiators recorded — the
headline: nothing shipping offers a pre-run per-branch cost enumeration, and
MCP's 2026 multi-round-trip spec independently rediscovers this system's
replay semantics.

## Round eight (owner)

Multi-line Markdown blocks demanded; designed as fenced text blocks and
validated by a byte-fidelity audit plus a fourteen-finding edge-case attack
(`block-syntax.md` is the corrected spec). Then eight directives on the
synthesized surface: kinds inferred; `via` for the serving model; the
review clause's `-> verdict` dropped; `amend` simplified; the loop's
outcome clauses (`giving { settled (…) … }`) replaced by the owner's
Maybe-reading — the loop binds a settled-or-not result and `case`
eliminates it; `case` replaces `branch on`; a statement-position bare `ask`
replaces `_ : receipt <-`.

Validation of round eight (two agents) then corrected the corrections:
the inference completeness claim was false (the honest rule is one
annotation per ground-free constraint component — and inference deletes the
repo's ill-typed example); the pending-option elimination is sound (the
option rides the graft's lambda; the rule is per-path) but is a checker
mode, not a free change; and the cold reader filed the loop's now-invisible
back-edge as fatal, `via` as unreadable, `at most n revisions` as
off-by-one ambiguous, and the unverified `DONE` prompt as a lie.

## Round nine (owner)

`if`/`else` restored for flags — `case` reserved for genuine sums. And the
`amend why` binder, still falling out of the sky, replaced by the language's
own machinery: the loop body's review is an ordinary binding with an
author-chosen name (`verdict <- panel, …`), consumed as `{verdict.reasons}`
by the normal scope rules; the `review` keyword deleted.

## Round ten (owner)

"Is `panel, all must approve` one term, or a hidden boolean expression
language?" Answered denotationally (`panel-rules.md`, attacked in
`panel-rules-attack.md`): one term today; the designed menu has exactly two
entries — the monoid (associative; silence sinks) and a counted quorum
(fixes objection-annihilation; gives up associativity for the parameter;
still exactly k questions, still pipeline-rung, because a threshold is a
read-out, not a branch). Bare `panel`, `a majority`, veto forms, best-of,
percentages, weights, and early exit refused with one-line reasons.
Validation fixes folded in: `amend patch { … }` (the back-edge named on the
page), `at most 2 amendments` (counts the visible step), `served by`
(replaces `via`), and the apply prompt stops demanding a `DONE` nothing
verifies.

The owner approved the resulting page — `flagship.wf` — on 2026-08-14:
"Yes, this is good."

## What implementation must honor

`GRAMMAR.md` is the spec; its "Implementation obligations" section is the
checklist the adversarial passes extracted. The kernel does not move. Every
DslFlagship theorem statement survives — five verbatim with proofs, the
rest recomputed by `decide +kernel` over a re-transcribed `flagshipRaw` at
unchanged cost.
