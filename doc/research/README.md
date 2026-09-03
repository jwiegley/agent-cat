# Research records

This directory holds the design records and research dossiers behind
agent-cat. They are records of how a decision arose, and they are not revised
to match the present. Several of them carry a dated banner that says which
parts a later decision overtook. Current behavior is governed by the source,
the tests, the root `README.md`, and the Texinfo manual in
`../agent-cat.texi`.

## The current design

| Record | What it is |
|---|---|
| `connection.md` | The design of record for the connection between the Haskell implementation and the Lean model. It explains why the project chose reimplementation with conformance testing over extraction, a foreign-function interface, or a subprocess oracle, and it defines the boundary, the request schema, and the corpus that followed. |
| `request-intent-representation.md` | The ruling that places execution intent in the executable `Plan` as `Request = Q × Intent`. It gives the erasing denotation, the operational policies, the alternatives, and the evidence ceilings. |
| `isaac-workflows.md` | How the incite workflows were read, priced, and ported into the authoring surface, and the decisions D1 through D8 that shaped its vocabulary. |
| `dslate-design/` | The implementation designs for those decisions. They cover functions and inputs, text panels and deciders, the revising redesign, and receipts with fail-over. |
| `source-aware-workflow-inputs.md` | The approved design for command-tail and standard-input workflow inputs, descriptor version 2, and the control file descriptor. |
| `pi-workflow-extension.md` | The design of the Pi extension as the control plane of agent-cat. It gives the capability matrix, the options that were considered, the machine protocol, and the delivered roadmap. |
| `pal-subsumption/` | The plan, the routing design, the confer workflow design, and the parity matrix for workflow-native parity with the PAL MCP server, together with a live routing log. |
| `pal-vs-agent-cat.md` | The analysis on which the PAL-parity track rests. |
| `ai-config-workflows/pal-note.md` | The coordinator note for the architecture phase of that track. |
| `isaac-review/` | Read-only reviews of agent-functor and incite, the two projects that this repository acknowledges. |

## The re-derivation

| Record | What it is |
|---|---|
| `rederive-meaning-first.md`, `rederive-algebra-first.md`, `rederive-decontaminate.md` | Three independent re-derivations of the kernel. One of them was blinded from every existing repository. |
| `rederivation-kernel.md` | The synthesis of the three. |
| `contamination-ledger.md` | The file-and-line ledger of where the first calculus took its shape from the seed implementation. |
| `attack-simplicity.md`, `attack-adequacy.md`, `attack-realizability.md` | Three adversarial attacks on the re-derived kernel. The last one has compiled Lean probes under `attack-realizability-lean/`. |
| `profunctor-design.md` and `profunctor-design/` | A categorical frame, a Haskell evaluator design, a Lean-side study with compiled probes, and an attack. They examine what profunctors would give the formalization. |

## The superseded calculus

| Record | What it is |
|---|---|
| `denotational-design-rev2.md` | The exploratory denotational design of 2026-08-11, converted from HTML and superseded on 2026-08-26. |
| `term-calculus-walkthrough.md` | The walkthrough of the pre-rederivation `Term` calculus as it stood on 2026-08-12, converted from HTML and historical since 2026-08-20. |
| `term-algebra-results.md` | The permanent record of what the `Term` calculus proved, written from the live sources before their removal. Cite this page rather than the removed module names. |
| `dsl-proposal-A.md`, `dsl-proposal-B.md`, `dsl-chosen.md` | The two grammar proposals for the retired `.wf` language and the grammar that was chosen. |
| `reviews/2026-08-12-heavy-review.md` | The seven-pass review of the `Term` calculus and the mapping from its findings to tracker issues. |
