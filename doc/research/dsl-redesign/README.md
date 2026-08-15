# dsl-redesign: the design record

The owner rejected the first textual surface; this directory records the
review that substantiated the rejection, the redesign, and the approved
result. Tracker: obr `acat-k28`.

| file | what it is |
|---|---|
| `GRAMMAR.md` | **the design of record** — the approved surface, its rules, elaboration, obligations |
| `flagship.wf` | the approved example (round ten), the page the owner accepted |
| `ROUNDS.md` | the short history of how it got here |
| `block-syntax.md` | multi-line Markdown text blocks, post-validation spec |
| `panel-rules.md` / `panel-rules-attack.md` | the panel acceptance-rule derivation and its adversarial check |
| `synthesis-round7.md` | the design-competition synthesis (superseded in detail) |
| `survey.md` | the ten-family survey and comparison judge |
| `review-pass-summaries.md` / `review-findings.json` / `review-design-digest.md` | the seven-pass review record |

Reading order for a newcomer: `ROUNDS.md`, then `flagship.wf`, then
`GRAMMAR.md`. Nothing here is implemented yet; `Agentic/Core/Dsl/*` still
holds the rejected surface, and the obr issues carry the work.
