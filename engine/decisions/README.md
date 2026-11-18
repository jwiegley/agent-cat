# engine/decisions

`engine/decisions/src` adapts a decisions HTTP endpoint to `Agentic.Engine`. A
decisions endpoint answers a decision question with a probability for each of
its options, which is a point of the simplex over those options. The engine
owns the HTTP exchange, the timeout, the bound on the size of a response, the
classification of failures, and the translation between the neutral
`EngineDecision` and the vendor bodies.

## Public modules

`Agentic.Decisions` exposes `DecisionsEndpoint`, `DecisionsModel`, and
`DecisionsEngine` with its constructor `newDecisionsEngine`, and it re-exports
the wire vocabulary that a routing definition needs: `Dialect`, `Limits`,
`defaultLimits`, and `reservedBodyKeys`. An endpoint holds
its dialect, its URL, its headers with the resolved credential, the secret
values that no public update may show, a timeout, a byte bound, and the
option limits. A model selector maps the model axis of a request to the model
identifier and the realization options that the body carries.
`newDecisionsManager` is the one place where TLS trust is chosen: an `https`
URL uses the TLS manager of `http-client-tls`, and any other URL uses a manager
without TLS.

`Agentic.Decisions.Wire` is pure, and it holds every vendor field name. It
encodes a request in one of two dialects. `system-one` is the body of the
OpenRouter Decisions API, of the TypeSafe System One API and of the local
runners that copy it, and `openai` is the body of the OpenAI Decisions API.
One request asks one question under the key `decision`, and the options are
sent in option order. The module decodes a response into the record that the
answer contract of `Agentic.Engine.Decision` names: a JSON object whose keys
are the option names in option order, each a decimal in [0,1], with a positive
sum. A yes/no probability p becomes `{"False": 1 - p, "True": p}` in exact
decimal arithmetic. An option that the vendor leaves out reads as 0. A
refusal, a missing answer, an unexpected answer type, a missing distribution,
an unknown option, a value outside [0,1], a zero sum, an exponent outside
±4096, and a repeated key are protocol failures. Each detail that no primary
source confirms carries an `UNCONFIRMED(Uk)` comment beside its code.

## Behavior

A request without a decision, or one that does not ask for a structured
answer, is refused with the protocol failure "a decisions engine answers
decision questions only". A model that cannot be selected, a decision outside
the endpoint's limits, and a realization option that names a reserved body
key are refused in the same way. None of these refusals sends a request.

The engine posts the body with redirects off, under the configured timeout,
and reads at most the configured number of bytes. A connection failure and a
timeout are transport failures. The statuses 408, 425, 429, 500, 502, 503,
504, 524 and 529, and a 402 whose `error.metadata.limit_source` is
`openrouter_in_flight_budget`, are transport failures. Every other status that
is not a success, a body over the bound, and a malformed body are protocol
failures. Retries are left to the runtime. A re-ask sends the same decision
again, because the engine does not send the prompt text.

The narration of an answer is one line that names the dialect, the model, the
token counts, and the cost and the request identifier when the vendor reports
them. A sum of probabilities outside 1 ± 1/100, and a reported choice that is
not the most probable option, add a note. A note changes no answer.

## Dependencies

`engine/api` is the sole local dependency. The CLI builds this engine from a
routing definition, and the runtime never imports this directory.

## Build and test

```sh
direnv exec . test/cabal.sh build all
direnv exec . bash engine/decisions/ci/decisions.sh
direnv exec . bash engine/decisions/ci/triage.sh
```

The gate checks that the engine imports only the engine API, that
`Agentic.Decisions` names no vendor field, and that every unconfirmed detail
is marked. It then runs `engine-decisions-test`. The suite checks the request
bodies and every response fixture in `test/fixtures`, runs the engine against
a `warp` stub on the loopback interface inside the test process, and checks
law L13: every accepted answer decodes at the decision's schema and holds the
vendor's probabilities. No test contacts an endpoint outside the process.

The second gate, `ci/triage.sh`, runs the `triage` example through
`agentic-run run --routing` once for each dialect. Its endpoint is
`test/stub_decisions.py`, a stub that listens on the loopback interface and
answers from a table keyed by the instructions of each question, and its
routing file is `test/triage-routing.yaml`. It checks the run that the
scripted table predicts, fail-over from a model that answers HTTP 529 to a
second model, abandonment when no rung is left, and fail-over from a
decisions model to the deterministic ACP stub adapter, whose fixed text is no
number record. Neither gate contacts an endpoint beyond the loopback
interface.

`ci/route-live.sh` runs the same example against a hosted endpoint and spends
money on a real account. An operator runs it only by explicit choice, and it
refuses to run unless `AGENT_CAT_DECISIONS_LIVE` holds the word `spend`.
