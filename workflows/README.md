# Manual authoring workflow

`agent-cat-manual.js` is the checked-in Pi dynamic workflow for researching,
drafting, reviewing, and validating this manual. Pass the file contents as the
`script` of a `workflow` tool call from the repository root.

The workflow accepts four optional arguments:

- `mode`: `whole` (the default) or `update`;
- `scope`: the chapter or bounded change to produce; and
- `requirements`: additional acceptance conditions; and
- `smoke`: `true` for a strictly bounded mechanics run that still exercises all
  fourteen calls and six phases.

A complete run uses fourteen agent calls across Inventory, Draft, Synthesize,
Review, Revise, and Validate phases. The five draft and five review identities
remain in the returned ledgers even when an agent fails. No model, provider,
credential, or machine path is fixed in the script.

The Validate phase renders the candidate from a temporary file and reports the
actual commands and diagnostics. After integrating the returned Texinfo, run the
two project gates named in its result:

```sh
make -C doc check
make -C doc check-haskell
```

The first command checks Info and HTML rendering, cross-references, source-backed
examples, top-level API and CLI coverage, and all three indexes. The second
compiles and runs the complete manual example, checks deterministic CLI
transcripts and defaults, and derives wildcard-exported children and exported
class instances through GHCi to verify the compiler-generated coverage ledger.
