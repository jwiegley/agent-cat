# Decision models: a research record

Recorded on 2026-11-17. This record states what the vendors of decision models
documented on that date, as the research for the `decide` verb found it. It is
a record, and it is not revised to match later vendor changes or later code.
The current behavior of agent-cat is stated in the manual, in
`doc/model-routing-v2.md`, and in `engine/decisions/README.md`.

## 1. Scope and method

A decision model answers a typed question about some evidence with a
probability for each answer, instead of with generated text. The research
covered six areas: the TypeSafe System One API that serves Jev, the OpenRouter
Decisions API, the OpenAI Decisions API, the other decision models that
OpenRouter lists, the local runners and open weights, and the Haskell and
mathematical prior art for typing the answers.

Each claim below was taken from a vendor document, an OpenAPI schema, a model
card, or a live catalogue response, unless it is marked as secondary. Section
11 lists every detail that no primary source confirmed. Section 12 lists every
source that the research read.

## 2. The common concept

Every decision API takes three things: a model identifier, the evidence, and a
set of questions. Each question has a type, optional or required instructions,
and a description of its possible answers. The response holds one answer for
each question, token usage, and the model that answered.

Three question types are common to every provider:

- **Choice.** The question names a finite set of options and asks which one is
  right. The answer is a probability for each option, the option with the
  highest probability, and on most providers a confidence figure.
- **Yes/no.** System One calls this type `noul` and OpenAI calls it
  `predicate`. The answer is the probability that the statement holds.
- **Score.** The question names an ordered list of levels. The answer is a
  probability for each level, the expected level index, and on most providers a
  confidence figure.

Several providers add further types, such as `box` for an image region, and
these are described with each provider. A per-question `refusal` answer exists
on OpenRouter, OpenAI and some others, and other questions in the same request
can still receive answers.

## 3. TypeSafe System One (Jev)

TypeSafe serves its Jev models through the System One API. The primary sources
are the OpenAPI document at `https://api.typesafe.ai/openapi.json` (OpenAPI
3.1.0, `info.version` 0.2.0) and the documentation pages under
`https://docs.typesafe.ai`.

### 3.1 Endpoints and authentication

- `POST /v1/systemone` on `https://api.typesafe.ai` takes
  `application/json` or `multipart/form-data`.
- `GET /v1/models` returns `{"models": [{"name", "description",
  "release_date"}]}`. The list holds the aliases, and versioned identifiers are
  accepted by the `model` field whether or not the list holds them.
- Authentication is `Authorization: Bearer <API_KEY>`.
- Two optional request headers take only the value `"true"`.
  `TypeSafe-Danger-Zone-Images` enables assets and box questions, and
  `TypeSafe-Danger-Zone-Long-Context` enables long context.
- The Python SDK defaults to the base URL `https://api.typesafe.ai`, the model
  `jev-latest`, and a timeout of 10 seconds. It reads `TYPESAFE_API_KEY`,
  `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL` and `TYPESAFE_LOG_LEVEL`, and
  it exposes the response header `x-typesafe-request-id`. It honors
  `Retry-After` and `retry-after-ms`.
- In a multipart request the first part is named `request` and holds the JSON
  body. Each further part is an image, and each image part must be used by
  exactly one asset.

### 3.2 Request

The body `SystemOneRequest` requires `model`, `state` and `questions`.

- `model` is a model name or alias.
- `state` is a string, an object, or an array.
- `questions` is an object of at least one entry, keyed by identifiers that the
  caller chooses. The keys are not sent to the model. The schema sets no
  maximum, and the documentation says that only the request size limits the
  number of questions.
- `assets` is an optional object of image assets.

The question variants are discriminated by `type`:

| Type | Required fields | Answers |
|---|---|---|
| `noul` | `type` | `instructions` is optional. `criteria` is optional and holds `true` and `false` descriptions. |
| `choice` | `type`, `criteria` | `criteria` maps each option name to a description or to `null`, with 1 to 255 entries. An option without a description is read by its name alone. |
| `score` | `type`, `criteria` | `criteria` is an array of 1 to 10 descriptions, and the position of each entry is its level from 0. The documentation asks for at least two levels. |
| `box` | `type` | It takes no `criteria`, requires the images header, and requires Jev 1.14. |

Instructions, option descriptions, levels and criteria accept JSON structure as
well as strings. The OpenAPI schema does not permit `null` for a score level,
and the page on advanced use says that it does.

An image asset has `type` `"image"`, `format` `png`, `jpg` or `jpeg`, and either
`data_base64` or a multipart `part`. The asset key is matched as plain text in
`state`, `instructions` and `criteria`, and every asset must be referenced or
the request fails with 400.

### 3.3 Response

`SystemOneResponse` requires `model`, `answers` and `usage`. `model` is the
versioned identifier that answered, `answers` is keyed by the question keys,
and `usage` holds `input_tokens` and `output_tokens`. Output tokens are free of
charge.

| Answer | Required fields |
|---|---|
| `noul` | `type`, `noul`, the probability of yes. There is no `confidence`. |
| `choice` | `type`, `choice`, `confidence`, `probabilities`. `choice` is the option with the highest probability, and `probabilities` maps each option to a number. The schema says the values sum to approximately 1, and the choice page says the sum is 1. |
| `score` | `type`, `score`, `confidence`, `legend`, `probabilities`. `score` is the probability-weighted mean of the level indices, `legend` maps `"0"`, `"1"` and so on to the levels, and `probabilities` uses the same keys. |
| `box` | `type`, `box`, `confidence`. `box` holds `top`, `bottom`, `left` and `right` in [0,1], and `confidence` may be `null`. |

The native response has no `id`, no `provider` and no `usage.cost`. The order
of the keys of `probabilities` is not documented, and the examples return keys
in an order different from the request.

### 3.4 Confidence and calibration

- Choice confidence is `(p_max − 1/n) / (1 − 1/n)` for `n` options. It depends
  only on the top probability.
- Score confidence is `max(0, 1 − Σ_i p_i·|i − m| / MAD_unif)`, where `m` is the
  most likely level and `MAD_unif = (1/n)·Σ_i |i − (n−1)/2|`.
- A yes/no answer has no confidence. The suggested equivalent is `|2p − 1|`.
- No formula is published for box confidence.
- Jev is trained for calibration with a method that TypeSafe calls RLCD. The
  primer says that outcomes given probability 0.2 should occur about 20 percent
  of the time, and that the rates describe groups of predictions. No
  calibration metric is published.
- The suggested yes/no thresholds are 0.7 for yes and 0.3 for no.

### 3.5 Limits

- `jev-1.14.0` (released 2026-10-14) supports choice, score, yes/no and box.
  `jev-1.13.0` supports choice, score and yes/no. Both cost $0.042 per million
  input tokens, and output is not billed. `jev-latest` and `jev-preview` point
  to `jev-1.14.0`.
- The default context is 64k tokens for a request and 32k for a question. The
  long-context header raises both to 262k.
- The body is at most 32 MiB of UTF-8 JSON without a byte order mark. `state`,
  `instructions` and `criteria` nest at most 64 levels, numbers must be finite,
  and one layer of `gzip`, `x-gzip` or `zstd` compression is accepted.
- An image is at most 16 MiB, each side is 280 to 1568 pixels, and the total is
  78,400 to 2,458,624 pixels. Images are never resized, and one rejected image
  fails the request. Images and box are labelled as not yet production-ready.
- Rate limits are set for each organization in the console, and an excess
  returns 429.

### 3.6 Errors

- 400 carries `{"detail": string | object}`, and a context overflow is reported
  with `max_tokens_exceeded`.
- 422 carries `{"detail": [ValidationError]}` with `loc`, `msg` and `type`.
- 401, 413, 415, 429 and 529 are documented without bodies. The SDK also maps
  403, 404 and 5xx, and it retries 429, 500, 502, 503 and 504 twice by default.

### 3.7 Primitives that do not exist, and known weaknesses

There is no multi-label, multi-select or ranking primitive. The documentation
recommends many yes/no questions in one request, a companion yes/no question
for "none of the above", and beam search over choice probabilities for a
hierarchy. It states that a choice leans toward the option that comes first,
that Jev cannot count or compare dates, that it reads content literally, and
that adversarial `state` can move an answer.

## 4. The OpenRouter Decisions API

OpenRouter serves many decision models behind one endpoint. The sources are
tagged S1 to S19 in section 12.

### 4.1 Endpoints and authentication

- `POST https://openrouter.ai/api/alpha/decisions` (`createApiAlphaDecisions`).
  The specification says that the shape of this alpha endpoint may change.
- `POST https://openrouter.ai/api/v1/systemone` (`createSystemone`) exists for
  the TypeSafe SDKs. Its request and response schemas are identical to the
  Decisions schemas. It maps a bare identifier such as `jev-1.13` to
  `typesafe/jev-1.13`, and `jev-latest` to `~typesafe/jev-latest`.
- Authentication is `Authorization: Bearer <OPENROUTER_API_KEY>`.
- The TypeSafe SDK takes the base URL `https://openrouter.ai/api` and appends
  `/v1/systemone`. The OpenRouter TypeScript SDK calls
  `openRouter.alpha.decisions.create`, and a client without
  `serverURL: 'https://openrouter.ai'` receives 404 on this path.
- The sibling endpoint `POST /api/alpha/extractions` takes the same envelope
  with `fields` in place of `questions`.

### 4.2 Request

`DecisionsRequest` requires `model`, `state` and `questions`, and it accepts
`assets`, `provider`, `session_id`, `trace` and `user`. The question schemas
match System One with one difference: the schema itself sets no option or level
bound, and the tutorial states 2 to 10 levels and at most 255 options. A box
question is served only by TypeSafe endpoints, and every other provider rejects
it with 400 before anything is sent upstream. Questions are answered in
parallel and cannot see each other's answers.

The `provider` field is the general OpenRouter `ProviderPreferences`, with
`allow_fallbacks`, `data_collection`, `ignore`, `only`, `order`, `max_price`,
`options`, latency and throughput preferences, `quantizations`,
`require_parameters`, `sort` and `zdr`. A request has no `models` fallback
array.

### 4.3 Response

`DecisionsResponse` requires `model`, `answers` and `usage`, and it may carry
`id` (prefix `gen-dec-`), `provider` and `annotations`. `usage` holds
`input_tokens`, `output_tokens`, and optionally `cost`, `cost_details`,
`input_tokens_details` and `is_byok`.

The answer variants are `noul`, `choice`, `score`, `box` and `refusal`. Only
`type` and the value field are required. `confidence`, `probabilities` and
`legend` are optional in the schema. A refusal carries only its type. The
guide instructs a client to treat a refusal, a missing answer, or an unexpected
type as unanswered and never as a negative verdict.

Sources disagree on yes/no confidence: the guide shows one, live Jev captures
show none, and the schema allows it. The response `model` is the dated snapshot
that served the request, such as `typesafe/jev-1.13-20260917`. The guide claims
deterministic answers, and two cookbooks observed repeated answers that moved
by a few hundredths and by up to eight hundredths.

### 4.4 Errors

Every error body is `{"error": {"code", "message", "metadata"?}, ...}`. The
documented statuses are 400, 401, 402, 403, 404, 413, 429, 500, 502, 503, 524
and 529. A 402 whose `error.metadata.limit_source` is
`openrouter_in_flight_budget` is transient and is retried after
`Retry-After`, and a 402 whose `limit_source` is `openrouter_credits` is not
retryable. A capability mismatch fails with 400 before anything is sent
upstream, and routing then tries another endpoint of the same model. Providers
pass some statuses through, such as 422 from Mercury Decide and 413 from Clef.

### 4.5 Adapters and discovery

Every endpoint is served by one adapter chosen by its provider. The adapter
fixes the accepted question types and the media that it reads. Yes/no, choice
and score work on every adapter. Providers without a row in the adapter table
fall back to `TypeSafeDecisionsAdapter`, which reads no media.

`GET /api/v1/models?output_modalities=decisions` lists the decision models,
because the default modality is text. On 2026-11-17 it returned 44 entries from
17 author namespaces. Each entry lists the request paths that serve it, and a
client filters on `endpoints` rather than on the modality, because
`cloudflare/clairic` is listed as a decision model and serves only
`/api/alpha/extractions`. A tilde identifier such as `~typesafe/jev-latest` is
an alias with an `alias_target`.

Jev has a context of 262,144 tokens and costs $0.042 per million input tokens.

### 4.6 Usage patterns that the guides document

- Ask one small judgment per question and combine the answers in code.
- Gate an action with yes/no questions at an approval threshold such as 0.9
  and a block threshold such as 0.1, with review in between.
- Verify a cheap draft with a choice over `supported`, `unsupported` and
  `declined`, and escalate once.
- Keep policy a pure function of saved answers, so that a change of threshold
  replays answers already paid for.
- Pick thresholds again for each model, because probabilities differ between
  models on the same question, and check them again after a change of wording.
- Give a choice an explicit `none` or `other` option, because a choice always
  picks one of its options.

## 5. The OpenAI Decisions API

OpenAI released the Decisions API in beta with `gpt-6-luna` on 2026-10-06, and
made it generally available on 2026-10-22.

### 5.1 Endpoint

`POST https://api.openai.com/v1/decisions` with `Authorization: Bearer
$OPENAI_API_KEY`. The `model` field accepts only `gpt-6-luna`. The name
`gpt-6-luna-decisions` exists only on OpenRouter. The SDKs call
`client.decisions.create`.

### 5.2 Request

- `model` is a string.
- `input` is a string of at most 10,485,760 characters, or an array of at most
  131,072 message and tool items. Message content parts are `input_text`,
  `input_image` and `input_json`. Files, audio and item references are not
  supported.
- `questions` is an array of 1 to 400 questions, and the answers return in the
  same order.
  - `predicate`: `{instructions, type, name?}`.
  - `choice`: `{choices, instructions, type, name?}`, where `choices` is 2 to
    255 unique `{value, description?}` entries and `value` is a string or a
    boolean.
  - `score`: `{instructions, levels, type, name?}`, where `levels` is 2 to 10
    `{label, description?}` entries from lowest to highest.
- Optional prompt-cache fields and `safety_identifier`.

There is no `temperature`, `reasoning`, `logprobs` or `max_output_tokens`
parameter. Dependent decisions require separate requests.

### 5.3 Response

The response is `{answers, model, usage}`, with no `id` and no `provider`.
`answers` is an array in question order:

- `predicate`: `{name, probability, type}`.
- `choice`: `{choice, confidence, name, probabilities, type}`, where
  `probabilities` is an array of `{probability, value}`.
- `score`: `{confidence, name, probabilities, score, type}`, where
  `probabilities` is an array of `{label, probability, value}` with an integer
  `value`, and `score` is the probability-weighted mean of the indices.
- `refusal`: `{name, type}`.

`usage` holds input, cached and cache-write tokens, output and reasoning
tokens, and the total. The formula for `confidence` is not published, and a
predicate answer has none.

### 5.4 Pricing and limits

Uncached input costs $0.10 per million tokens, cache writes are charged, and
output is free. The limits are 1 to 400 questions, 2 to 255 choices, 2 to 10
levels, and the input bounds above. Rate limits specific to Decisions, an image
cap, and a context window specific to Decisions are not published. The
service is eligible for zero data retention and HIPAA, with regional
processing in the US and the EU.

### 5.5 Logprobs

OpenAI positions Decisions for its fixed answer types and Structured Outputs
for an arbitrary schema. The Chat Completions API still documents `logprobs`,
and the guide for GPT-6 migration says to omit `logprobs` and `top_logprobs`.
Whether logprobs work on `gpt-6-luna` with reasoning off is stated only by a
secondary source. No OpenAI statement says that Decisions is implemented
through logprobs.

## 6. Other hosted decision models

The following table summarizes the models that OpenRouter listed on
2026-11-17 other than Jev and Luna. The context is that of the catalogue, in
tokens.

| Model | Context | Notes |
|---|---|---|
| `microsoft/microsoft-decision-1`, `-1.1` | 32,768 | Served by Azure. The native API is `POST <foundry-endpoint>/providers/microsoft/v1/systemone` with `model` set to the deployment name and an Entra bearer token or an `api-key` header. Images go in `assets`. Option and level limits are not published. |
| `perplexity/pplx-decider-v1.2`, `-flash-v1.2`, `-v1.3:free`, `-flash-v1.3:free` | 262,144 | The native API is `POST https://api.perplexity.ai/v1/decisions` with 1 to 255 options and 1 to 10 levels, `mode: "web_grounding"`, and a `locate` type on v1.3. An unknown top-level field returns 400. `pplx-decider-v1.1-27b` has no endpoint. |
| `cloudflare/clef`, `clef-flash`, `clef-omni` | 65,537, 24,576, 65,536 | Workers AI reads about the first 2,000 tokens of text and drops the rest without an error. The native endpoint is `POST https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/ai/run/@cf/cloudflare/clef`, with 1 to 64 questions and a top-level `images` array. |
| `inception/mercury-decide` | 65,536 | No live endpoint on OpenRouter. The native API is `POST https://api.inceptionlabs.ai/v1/decisions` with an `extract` type, and its text parts in a `state` array are `{"type":"text"}` objects. |
| `liquid/d1`, `d1.1`, `d1.2`, `d1.2-ultra`, `d1-ultra` | 32,768 to 65,536 | The native API is `POST https://api.liquid.ai/decisions/v1/systemone` with up to 128 questions. d1.2 adds native `box`, `boxes`, `spans`, `text`, `number`, `date` and multi-select choice, which the OpenRouter adapter does not pass. `liquid/d1` expires on 2026-11-20. |
| `upstage/solar-decide`, `-flash` | 524,288 | Served through the System One schema. No primary Upstage document gives the native URL or limits. |
| `respan/span-02` | 131,072 | The native API is `POST https://api.respan.ai/api/v1/decisions` with a `number` type and a `reasoning` control. `model` must be `span-02`, `respan/span-02`, or absent. The guide says 1 to 679 options and the reference says 255. |
| `scaledown/classify-1` | 1,000,000 | The native endpoint is `/v1/scaledown` on `api.scaledown.xyz`, and it reads only `state.text` and `state.document`. |
| `togethercomputer/tev1-4b-experimental` | 32,768 | Served through chat completions. It answers one option letter for 2 to 24 options, with no native probabilities. |
| `jaredpalmer/kev-4b` | 8,192 | Served by SiliconFlow over the System One contract. |
| `google/gemini-decision-1` | 262,144 | Up to 255 options and 255 levels. Every question needs instructions. |
| `heygen/heygen-decision-1`, `-turbo` | 131,072, 262,144 | At most 4 images and 1 video. |
| `parallel/decisions-fast` | 32,000 | Web-grounded, at most 100 questions, priced per request. |
| `morph/reflex` | 65,536 | At most 16 images. |
| `baseten/joey-1`, `elephant-1`, `mammoth-1` | 16,384 | Described as compatible with TypeSafe System One. |
| `nace-ai/drex-v1.5`, `drex-v2.0`, `drex-max`, `drex-max-finance` | 131,072 to 262,144 | Served by DeepInfra with at most 4 images. |

## 7. Local runners and open weights

Almost every open decision model exposes `POST /v1/systemone` with the
System One request and response. The local runners differ from OpenRouter in
four ways: they report no `id`, `provider` or `usage.cost`, they add
`latency_ms`, the request `model` is optional except on the Ollama forks, and
the response may omit `model`.

### 7.1 Nace.AI Drex

The weights and code are in `https://github.com/nace-ai/drex-decision-models`.

| Model | Repository | Backbone | Weights licence |
|---|---|---|---|
| Drex Max | `nace-ai/drex-max-v1` | A dense 27B model with a 255-way readout head | Nace.AI Open RAIL-M |
| Drex v2.0 | `nace-ai/drex-v2.0` | Qwen3.6-35B-A3B with a pointer head | Nace.AI Open RAIL-M |
| Drex v1.5 | `nace-ai/drex-v1.5` | MiMo-V2.6-Distill-Qwen-9B with a pointer head | Nace.AI Open RAIL-M |
| Drex DLM | `nace-ai/drex-dlm` | Efficient-DLM-8B with a pointer head | CC BY-NC 4.0 |

| Runner | Command or endpoint |
|---|---|
| Python server (v1.5, v2.0, DLM) | `python serve.py --model weights/<m> --host 127.0.0.1 --port 8000`. It needs no `Authorization` header, and it accepts a batch of up to 1,024 decisions under `requests`. |
| Drex Max in Python | `python -m drex_max --model ... --request ...`, a command-line tool with no HTTP server. |
| llama.cpp fork `github.com/nace-ai/llama.cpp` | `llama-server ... --port 8000` (DLM on 8097), without images. |
| Ollama fork `github.com/nace-ai/ollama` | `http://127.0.0.1:11434/v1/systemone`. The request must name `model`. |
| MLX (Drex Max) | `python drex_max_mlx.py ...`, text only. |
| Kapitsa | `kapitsa-systemone --model ... --port 8000`. |

Every runner defaults to a context of 16,384 tokens. The response of
`request-format.md` shows `legend` as an array, and the Drex Max card shows it
as an object keyed by level. The local `serve.py` response has no `model`. The
documentation states that the local score confidence approximates the hosted
one.

### 7.2 Kev

`https://github.com/jaredpalmer/kev` publishes Apache-2.0 weights at 0.8B, 4B,
9B and 27B. `python -m kev.serve --run jaredpalmer/kev-4b --port 8009` serves
`POST /v1/systemone`, `GET /v1/models`, `POST /v1/systemone/permute` and
`POST /v1/systemone/separate`. Setting `KEV_API_KEY` makes the server require
`Authorization: Bearer`. Choice and score accept 1 to 255 entries, the
response adds `latency_ms`, and oversized input returns 422. A fitted
temperature is applied at load. Choice confidence is
`(p_max − 1/K)/(1 − 1/K)` and score confidence is
`max(0, 1 − E|level − mode|/D)`.

### 7.3 Cloudflare Clef

The weights are Apache-2.0 on Hugging Face. Clef and Clef-flash run under
SGLang with `sglang serve --model-path Cloudflare/clef-flash --port 30000`, and
the server answers System One requests at `/v1/systemone`. An absent
`instructions` makes the question identifier the prompt. The confidence formula
is not published.

### 7.4 Ollama

Ollama 0.35 and later serve `POST /v1/systemone` on `localhost:11434`. It takes
up to 64 questions, 2 to 255 choice criteria, and 2 to 10 score criteria as
strings, and it requires `instructions` on every type. It requires
`probabilities` and `confidence` on choice and score answers. Its confidence is
`1 − H(p)/ln N`. It has no `refusal` type and no `box`.

### 7.5 Other local options

Perplexity Decider for Mac serves `pplx-decider-flash-v1.2` at
`http://127.0.0.1:8080/v1/decisions` with no API key. Liquid publishes open
weights under the LFM Open License, and llama.cpp supports only yes/no, choice
and score for them. Together Tev1 runs under vLLM or SGLang as a chat model
that answers one letter.

## 8. The common contract

The intersection of the System One providers that the research read is the
following request and response. The OpenAI native API and the Tev1 native
format need adapters.

```
request:  { "model": string,
            "state": non-empty string,
            "questions": { id: Q, ... } }              1 to 64 entries
id:       [A-Za-z0-9_.-]{1,100}
noul:     {"type":"noul",   "instructions": string, "criteria"?: {"true": string, "false": string}}
choice:   {"type":"choice", "instructions": string, "criteria": {key: string | null, ...}}
score:    {"type":"score",  "instructions": string, "criteria": [string, ...]}   2 to 10 levels

response: { "model": string,
            "answers": { id: A },                      a key may be missing
            "usage": { "input_tokens": int, "output_tokens": int } }
A:        {"type":"noul", "noul": p}
        | {"type":"choice", "choice": key, "probabilities"?: {key: p}, "confidence"?: c}
        | {"type":"score", "score": x, "probabilities"?: {"0": p, ...}, "legend"?: ..., "confidence"?: c}
        | {"type":"refusal"}
```

A portable client always sends `instructions` as a string, because Ollama and
Gemini require it and Clef substitutes the question identifier. It keeps
criteria as strings, prefers a string `state`, and leaves out media, assets,
box and every vendor extension. Confidence is not comparable across vendors,
and thresholds must be chosen again for each model.

## 9. Per-provider differences

| Aspect | System One (TypeSafe, OpenRouter, local runners) | OpenAI `/v1/decisions` |
|---|---|---|
| Evidence | `state`: a string, object or array | `input`: a string or typed items |
| Questions | an object keyed by the caller | an array with optional `name` |
| Yes/no | `noul` with optional `criteria` | `predicate` with instructions only |
| Choice options | `criteria: {name: description}` | `choices: [{value, description}]`, 2 to 255 |
| Choice answer | object `{name: p}` | array `[{value, probability}]` |
| Score levels | `criteria: [description, ...]` | `levels: [{label, description}]`, 2 to 10 |
| Score answer | object `{"0": p}` with `legend` | array `[{value, label, probability}]` |
| Box | TypeSafe endpoints only | absent |
| Refusal | `{type: "refusal"}` on OpenRouter | `{type: "refusal", name}` |
| Envelope | `id`, `provider` and `usage.cost` on OpenRouter only | `answers`, `model` and `usage` only |
| Question cap | none on TypeSafe, 64 on Ollama and Clef, 128 on Liquid | 400 |

The paths differ as well. OpenRouter serves `/api/alpha/decisions` and
`/api/v1/systemone`. TypeSafe, Liquid, Microsoft, Kev, Drex, self-hosted Clef
and Ollama serve `/v1/systemone`. Perplexity, Inception, Respan and OpenAI
serve `/v1/decisions`, and ScaleDown serves `/v1/scaledown`.

## 10. The mathematical object and Haskell prior art

A choice over a finite set of options `T` denotes a point of the standard
simplex `Δ(T) = {f : T → ℝ≥0 | Σ f = 1}`, which is an element of the finite
distribution monad. A yes/no answer is a point of `[0,1] ≅ Δ(Bool)`. A score
with `n` levels is a point of `Δ(Fin n)` together with its expectation. The
algebras of the distribution monad are the convex spaces (Jacobs, Fritz, and
the nLab), whose binary axioms are `c_0(x,y) = x`, `c_p(x,x) = x`,
`c_p(x,y) = c_{1−p}(y,x)` and `c_p(x, c_q(y,z)) = c_{pq}(c_r(x,y),z)` when
`p(1−q) = (1−pq)r`. Mathlib states the simplex as `stdSimplex` and the
distribution functor laws as `PMF.map_id` and `PMF.map_comp`.

The Hackage survey found no package that fits as the answer carrier. The
`distribution` package (2017) holds the closest design, a zero-free map from
values to `Rational`. `probability` holds duplicates in a list, so its `Eq` is
not semantic. `monad-bayes` and `statistics` use `Double`. The `scientific`
package decodes JSON numbers exactly, and advisory HSEC-2026-0007 requires a
bound on the exponent before a conversion to `Rational`.

The answers are exact decimals on the wire. A rational carrier keeps them
exact, so the sum, the expected level and the membership of the reported
choice in the argmax set are decidable without a tolerance. The example
`0.79·1 + 0.21·2 = 1.21` holds exactly in the rationals. No primary source
states that the probabilities sum to 1, that they are rounded, or how ties are
broken.

## 11. Details not confirmed from a primary source

The decisions engine marks each of the following details with an
`UNCONFIRMED(Uk)` comment beside the code in
`engine/decisions/src/Agentic/Decisions/Wire.hs` that depends on it, or leaves
it to a URL that the user configures.

| # | Detail | Status on 2026-11-17, and what the engine does |
|---|---|---|
| U1 | OpenRouter `/api/v1/systemone` for models other than Jev | The live catalogue lists only `/api/alpha/decisions` for most models. The example configuration uses the alpha path, which is documented as subject to change. |
| U2 | Whether a provider omits an option whose probability is zero | No source says. A missing option reads as 0. |
| U3 | A bound on the sum of the probabilities | Every source says "approximately 1". The engine adds a narration note outside 1 ± 1/100 and rejects nothing on that ground. |
| U4 | `probabilities` is optional on OpenRouter | A choice or score answer without it is refused, so some models may be unusable until an operator checks them live. |
| U5 | The confidence formulas, and whether a yes/no answer carries confidence | The engine ignores `confidence`. |
| U6 | The OpenRouter translation of `noul` into the OpenAI `predicate` for `openai/gpt-6-luna-decisions` | Inferred from the adapter table. The engine sends `noul`. |
| U7 | Perplexity, Inception and Respan at their native `/v1/decisions` with a System One body | Reachable by URL with `system-one` and not verified. Perplexity rejects unknown top-level fields, Inception's text parts differ, and Respan accepts only the model `span-02`. |
| U8 | Microsoft Foundry authentication and the deployment name as `model` | Documented on Microsoft Learn, without a fixture. |
| U9 | The URL and authentication of the hosted Nace (Drex) API | Not found. Only local runners are covered. |
| U10 | Drex `legend` as an array or an object | Both are documented. The engine ignores `legend`. |
| U11 | Local responses without `model`, `id` or `cost` | Every narration field is optional. |
| U12 | Whether a score level may be `null` | The OpenAPI schema and Ollama forbid it, and a TypeSafe page permits it. The engine always sends strings. |
| U13 | The classification of the transient 402 by `error.metadata.limit_source` | Documented by OpenRouter, without a fixture from a live endpoint. |
| U14 | The Respan option limit (679 or 255) and the Tev1 limit of 24 | An engine definition sets its own `limits`, and the default is 255 options and 10 levels. |
| U15 | Whether every provider answers the questions of one request independently | It matters only for a batch of questions, which the engine does not send. |
| U16 | Whether Kev on loopback needs `Authorization: Bearer` | Documented when `KEV_API_KEY` is set. The routing URL rule refuses an authenticated plain-HTTP URL. |
| U17 | The error statuses and the error envelope of the OpenAI Decisions API | The research recorded those of OpenRouter and TypeSafe only. The engine classifies an OpenAI status by the same table. |

Further points that no primary source settled:

- The key order of `probabilities` on any provider.
- Streaming, batch endpoints and logprob access for Jev, and a per-question
  timeout.
- Calibration benchmarks for any model, and a formula for box confidence.
- A provider-specific `provider.options` schema for OpenRouter Decisions
  models, and response headers specific to Decisions.
- The `state` shapes of ScaleDown Classify-1 and Respan Span-01.
- Which Respan adapter serves `respan/span-02` on OpenRouter.
- How OpenRouter maps yes/no and score questions onto Tev1, and whether it
  returns probabilities for it.
- Whether Inception's native path is `/v1/decisions`, as its documentation
  says, or `/v1/systemone`, as the OpenRouter page says.
- The native request schema and limits of Microsoft-Decision-1, and the native
  endpoint and limits of Upstage.
- A Python HTTP server for Drex Max, vLLM support for Drex or Kev, and support
  for Drex in upstream Ollama or llama.cpp.
- A confidence formula for Clef and a local `box` primitive on any model.
- The licence text of Nace.AI Open RAIL-M, which only secondary sources
  characterize.

Out of the scope of the research and of the engine: `box`, images and a JSON
`state`, multi-label answers, the Respan `number`, Perplexity `locate` and
Inception `extract` types, native Tev1, the Cloudflare Workers envelope, and a
fallback through logprobs.

## 12. Sources

### TypeSafe

- https://api.typesafe.ai/openapi.json
- https://docs.typesafe.ai/llms.txt
- https://docs.typesafe.ai/models.md
- https://docs.typesafe.ai/primitives.md
- https://docs.typesafe.ai/primitives/advanced.md
- https://docs.typesafe.ai/primitives/box.md
- https://docs.typesafe.ai/primitives/choice.md
- https://docs.typesafe.ai/primitives/score.md
- https://docs.typesafe.ai/images.md
- https://docs.typesafe.ai/confidence.md
- https://docs.typesafe.ai/introduction/machine-learning-primer.md
- https://docs.typesafe.ai/model-jaggedness.md
- https://docs.typesafe.ai/api/errors.md
- https://docs.typesafe.ai/sdk/python/api/constants.md
- https://docs.typesafe.ai/sdk/python/api/exceptions.md
- https://docs.typesafe.ai/sdk/python/api/retries.md

### OpenRouter

- S1: https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request.md
- S2: https://openrouter.ai/docs/guides/features/decisions.md
- S3: https://openrouter.ai/docs/guides/community/jev.md
- S4: https://openrouter.ai/docs/guides/community/typesafe-sdk.md
- S5: https://openrouter.ai/docs/guides/community/multimodal-decisions.md
- S6: https://openrouter.ai/docs/cookbook/building-agents/gate-tool-calls-with-jev.md
- S7: https://openrouter.ai/docs/cookbook/evaluate-and-optimize/jev-verified-cascade.md
- S8: https://openrouter.ai/blog/tutorials/how-to-use-jev/
- S9: https://openrouter.ai/blog/tutorials/jev-vs-llm-when-to-use-each/
- S10: https://openrouter.ai/api/v1/models?output_modalities=decisions
- S11: https://openrouter.ai/docs/guides/community/jev-tutorial.md
- S12: https://openrouter.ai/docs/cookbook/evaluate-and-optimize/jev-classification.md
- S13: https://openrouter.ai/docs/cookbook/coding-agents/auto-approve-permission-prompts-with-jev.md
- S14: https://openrouter.ai/docs/api/api-reference/systemone/submit-a-system-one-request.md
- S15: https://openrouter.ai/docs/openapi/openapi.yaml
- S16: https://openrouter.ai/docs/client-sdks/typescript/sdks/decisions/README.md
- S17: https://openrouter.ai/docs/api_reference/limits.md
- S18: https://openrouter.ai/api/v1/models/{id}/endpoints
- S19: https://openrouter.ai/docs/app-attribution.md
- https://openrouter.ai/docs/guides/community/extractions
- https://openrouter.ai/rankings/decisions
- https://openrouter.ai/{id}, the model pages, including
  https://openrouter.ai/openai/gpt-6-luna-decisions
- https://openrouter.ai/nace-ai/drex-max and https://openrouter.ai/nace-ai/drex-v2.0,
  which returned HTTP 404 on 2026-11-17
- https://openrouter.ai/blog/insights/what-is-jev/

### OpenAI

- https://developers.openai.com/api/docs/changelog
- https://developers.openai.com/api/docs/guides/decisions
- https://developers.openai.com/api/reference/resources/decisions/methods/create
- https://developers.openai.com/api/docs/guides/decisions-voice
- https://developers.openai.com/api/docs/guides/private-link
- https://developers.openai.com/api/docs/models/gpt-6-luna
- https://developers.openai.com/api/docs/guides/latest-model
- https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
- https://developers.openai.com/api/reference/resources/responses/methods/create
- https://developers.openai.com/cookbook/examples/using_logprobs
- https://platform.openai.com/decisions
- Secondary: https://huggingface.co/blog/a2aprotocol/getting-started-with-the-openai-decisions-api-thre
- Secondary: https://aiweekly.co/alerts/openai-launches-decisions-api-public-beta-on-gpt-6-luna
- Secondary: https://www.orcarouter.ai/blog/openai-decisions-api-gpt-6-luna
- Secondary: https://aiengineerguide.com/tools/model-migration-linter/errors/openai-gpt-6-sampling-with-reasoning/

### Other hosted providers

- https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision
- https://commandline.microsoft.com/microsoft-decision-1-model-foundry/
- https://ai.azure.com/catalog/models/Microsoft-Decision-1
- https://docs.perplexity.ai/docs/decisions/quickstart
- https://docs.perplexity.ai/docs/decisions/decider-for-mac
- https://huggingface.co/perplexity-ai/pplx-decider-v1.2
- https://developers.cloudflare.com/workers-ai/models/clef/
- https://developers.cloudflare.com/workers-ai/models/clef-omni/index.md
- https://docs.inceptionlabs.ai/capabilities/decisions
- https://docs.inceptionlabs.ai/api-reference/decisions/create-a-decision
- https://docs.liquid.ai/lfm/models/decision-models
- https://docs.liquid.ai/lfm/models/d1
- https://respan.ai/docs/documentation/span-02/question-types
- https://respan.ai/docs/documentation/span-02/concept
- https://respan.ai/docs/apis/gateway/run-span-02
- https://docs.scaledown.ai/api-reference/decisions-overview
- https://docs.ollama.com/api/systemone
- Secondary: https://flaviocopes.com/clef/
- Secondary: https://www.llmreference.com/model/drex-max/nace-ai
- Secondary, for the Upstage URL: https://api.upstage.ai/v1/systemone

### Local runners and open weights

- https://github.com/nace-ai/drex-decision-models
- https://raw.githubusercontent.com/nace-ai/drex-decision-models/main/docs/request-format.md
- https://github.com/nace-ai/llama.cpp and https://github.com/nace-ai/ollama
- https://huggingface.co/nace-ai/drex-max-v1
- https://huggingface.co/nace-ai/drex-max, which returned HTTP 401 on 2026-11-17
- https://huggingface.co/nace-ai/drex-v2.0
- https://huggingface.co/nace-ai/drex-v1.5
- https://huggingface.co/nace-ai/drex-dlm
- https://github.com/jaredpalmer/kev
- https://huggingface.co/jaredpalmer/kev-4b
- https://huggingface.co/Cloudflare/clef
- https://huggingface.co/Cloudflare/clef-flash
- https://huggingface.co/Cloudflare/clef-omni
- https://huggingface.co/togethercomputer/Tev1-4B-experimental

### Mathematics and Haskell

- https://ncatlab.org/nlab/show/distribution+monad
- https://ncatlab.org/nlab/show/convex+space
- https://www.cs.auckland.ac.nz/~cristian/crispapers/TCS%202010%20Proceedings/10001/10001.pdf
- https://arxiv.org/pdf/0911.3834
- https://arxiv.org/abs/0903.5522v2
- https://leanprover-community.github.io/mathlib4_docs/Mathlib/Analysis/Convex/StdSimplex.html
- https://leanprover-community.github.io/mathlib4_docs/Mathlib/Probability/ProbabilityMassFunction/Constructions.html
- https://web.engr.oregonstate.edu/~erwig/papers/PFP_JFP06.pdf
- https://hackage-content.haskell.org/package/probability-0.2.9.1/docs/Numeric-Probability-Distribution.html
- https://hackage-content.haskell.org/package/distribution-1.1.1.0/docs/Data-Distribution-Core.html
- https://hackage-content.haskell.org/package/monad-bayes-1.3.0.5/docs/Control-Monad-Bayes-Enumerator.html
- https://hackage-content.haskell.org/package/statistics-0.16.5.0/docs/Statistics-Distribution.html
- https://hackage-content.haskell.org/package/vector-space-0.19/docs/Data-Basis.html
- https://hackage-content.haskell.org/package/linear-1.23.3/docs/Linear-Vector.html
- https://hackage.haskell.org/package/free-vector-spaces
- https://hackage-content.haskell.org/package/adjunctions-4.4.4/docs/Data-Functor-Rep.html
- https://hackage.haskell.org/package/TotalMap
- https://hackage.haskell.org/package/total-map
- https://hackage.haskell.org/package/finitary
- https://hackage-content.haskell.org/package/finite-typelits-0.2.1.0/docs/Data-Finite.html
- https://hackage.haskell.org/package/universe-base
- https://hackage.haskell.org/package/swarm-0.5.0.0/docs/Swarm-Util-UnitInterval.html
- https://hackage.haskell.org/package/refined
- https://hackage-content.haskell.org/package/scientific-0.3.10.0/docs/Data-Scientific.html
- https://haskell.github.io/security-advisories/advisory/HSEC-2026-0007
- https://www.rfc-editor.org/rfc/rfc8259#section-6
