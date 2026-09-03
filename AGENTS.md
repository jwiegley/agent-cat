# Working in this repository

This file states the conventions that govern changes to agent-cat. Each source
directory carries its own `AGENTS.md` with the rules particular to that
directory; this file holds the rules that apply everywhere. The `README.md`
describes what the repository is, and the Texinfo manual in `doc/agent-cat.texi`
is the reference for the authoring surface and the runner.

## Method

Meaning comes before syntax. Every type in the Lean model opens its docstring
with the mathematical object it denotes, and every operation that carries a
semantic claim states its commuting equation beside the proved theorem. An
equation that will not close is recorded with a diagnosis. It is never weakened
to make something else pass, and a flagship theorem statement is never weakened
for the same reason.

Standard structure is preferred to bespoke vocabulary. Where Mathlib or the
Haskell base libraries supply a lawful structure, the model uses it, and laws
are inherited through morphisms rather than asserted. Agreement between this
design and the seed implementations that preceded it (agent-functor and incite)
is treated as evidence of contamination rather than as justification;
implementation precedent is not cited in support of a specification decision.

Progress on the mathematics is reported as theorem statements with their axiom
footprints. Process and tracking updates belong in the issue tracker.

## Examples and surfaces

An example file contains exactly what a user would write: no vocabulary tables,
no read-outs, no runner machinery. Any definition an example forces on its
author is a library gap and is fixed in the library. A keyword in the authoring
surface either says what it means or does not exist.

## Building

The Nix development shells are the only supported environments, and `direnv
allow .` wires the root shell up. The Haskell workspace builds from the
repository root with `nix develop path:. -c cabal build all`. The Lean model
builds with `nix develop path:./model -c bash -c 'cd model && lake build'`, and
the conformance oracle with the same shell in `bisim`. Never run two full Lean
builds at once: `model/Agentic/Core/DslFlagship.lean` proves its theorems by
running the checker inside the kernel, which takes minutes of wall clock and
several gigabytes of memory.

After a change, run the gates that own the changed layer. The deterministic
gates are `bisim/ci/tier0.sh`, `cli/ci/policies.sh`, `cli/ci/examples.sh`,
`cli/ci/routing-config.sh`, `engine/acp/ci/acp.sh`, and
`engine/agent-deck/ci/deck.sh`; `bisim/ci/tier1.sh` requires a prebuilt oracle
and refuses to build one. `engine/acp/ci/route-live.sh` contacts paid backends
and is run only by explicit operator choice. The documentation gates are
`make -C doc check` and `make -C doc check-haskell`. A change to the frozen
corpus under `bisim/corpus/` is a change to the specification and is reviewed
as one.

## Documentation

Documentation in this repository is Markdown or Texinfo, and it describes the
current state of the code. Design records and research dossiers live under
`doc/research/` and are kept as records rather than revised to match the
present. Prose in the manual is checked by `doc/check-prose.py`; write in
plain, formal English without contractions, marketing vocabulary, or runs of
very short sentences.

<!-- obr-agent-instructions-v1 -->

---

## Obr Workflow Integration

This project uses [obr](https://github.com/jwiegley/obr) for issue tracking.
Issues live in `PLAN.org` — an Org-mode file tracked in git, at `doc/`,
`docs/`, or the project root. `.obr/` is a per-machine cache (SQLite plus
metadata) that ignores itself; never commit anything under it. obr never
commits, pushes, pulls, or installs hooks: exporting and committing are
separate, explicit steps. (A few read-only commands do shell out to git to
report what it sees — `vcs-status`, `changelog`, `orphans` — and none of them
write.)

### Essential Commands

```bash
# View ready issues (open, unblocked, not deferred)
obr ready

# List and search
obr list --status=open # All open issues
obr show <id>          # Full issue details with dependencies
obr search "keyword"   # Full-text search

# Create and update
obr create "Title" -d "..." --type=task --priority=2
obr q "Title"          # Quick capture: create and print only the id
obr update <id> --status=in_progress
obr close <id> --reason="Completed"
obr close <id1> <id2>  # Close multiple issues at once

# Write the tracked surface
obr sync --flush-only  # Write PLAN.org from the database
obr sync --status      # Check whether DB and PLAN.org agree
```

### Workflow Pattern

1. **Start**: Run `obr ready` to find actionable work
2. **Claim**: Use `obr update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: Use `obr close <id> --reason="..."`
5. **Record**: Run `obr sync --flush-only`, then commit `PLAN.org` with the code

### Key Concepts

- **Dependencies**: Issues can block other issues. `obr ready` shows only open, unblocked work.
- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (use numbers 0-4, not words)
- **Types**: task, bug, feature, epic, chore, docs, question
- **Blocking**: `obr dep add <issue> <depends-on>` to add dependencies
- **Recording discovered work**: create an issue the moment you find work you are not doing now, and link it (`--deps discovered-from:<id>`)

### Session Protocol

**Before ending any session, run this checklist:**

```bash
obr sync --flush-only   # Write issue changes to PLAN.org
git status              # Check what changed
git add <files>         # Stage code changes AND PLAN.org together
git commit -m "..."     # One commit: the change and its issue state
```

### Best Practices

- Check `obr ready` at session start to find available work
- Record dependencies at creation time — they are what make `obr ready` meaningful
- Update status as you work (in_progress → closed)
- Use descriptive titles and set appropriate priority/type
- Commit `PLAN.org` together with the code that changes it; its diff is the review trail
- A fresh clone rebuilds the cache with: `obr init && obr sync --import-only --rebuild`

<!-- end-obr-agent-instructions -->
