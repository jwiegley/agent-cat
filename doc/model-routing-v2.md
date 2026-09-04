# Persona-aware model routing, version 2

Status: implemented runtime contract; only the future Brick routing pane is deferred.

Last checked: 2026-09-03.

## 1. Decision

Retain the established file name, `routing.yaml`, and introduce a strict version-2 schema. A workflow continues to name only a symbolic profile such as `deep-thinker`. CLI composition selects a persona, resolves that persona's profile through named concrete-model definitions and named engine instances, optionally consults a bounded `/v1/models` inventory, freezes one exact non-secret realization policy, and then hands the existing `ModelConfig` and engine-specific configuration to runtime preflight.

The design adds no persona, provider, endpoint, key, or discovered model to DSL or workflow source. Persona is operational context, not denotation.

The ordered profile chain remains the policy. The resolver does not infer “best” or “cheap” from vendor names, catalogue order, or mutable prices. To prefer a low-cost model, place its named model definition at the desired point in the selected persona's chain. This is explicit, deterministic, and sufficient for the requested personal-only OMLX case.

Version 1 remains supported without changed meaning. Mixed version-1 and version-2 user/project layers are refused with an actionable migration message rather than merged by guesswork.

## 2. Vocabulary

The implementation distinguishes four names which version 1 partially conflates:

- A **persona** is a named operational context such as `personal`, `work`, or `agent-cat`. It explicitly allowlists physical engine instances and concrete model aliases, then defines how symbolic profiles resolve. It is not an authentication identity or security sandbox.
- An **engine instance** is one concrete route and its process environment: for example, `codex-work`, `claude-personal`, or `omlx-hera`. Two aliases may share one physical backend when their process definitions—environment and catalogue—agree. Provider is per-realization provenance and preflight metadata and may differ, preserving valid version-1 routers during migration. Instances which use one executable with different endpoints or environments use distinct backend spellings, commonly distinct wrapper paths, so process sharing and child environment remain unambiguous.
- A **concrete model definition** is a stable local alias such as `openai-sol-work`. It belongs to one engine instance and resolves either to an exact model id or to one deterministic match from a discovered inventory.
- A **symbolic profile** is the name authored in Haskell, such as `deep-thinker`. Within a persona it is an ordered, non-empty chain of concrete model definitions plus generation settings.

After resolution, the runtime still receives the existing physical concepts: backend, exact model id, thinking level, output limit, and ACP options. The new dimensions end at CLI composition.

## 3. Present version-1 contract

Version 1 defines reusable routers and symbolic profiles:

```yaml
version: 1
routers:
  - name: codex-acp
    backend: acp:codex
    provider: openai
profiles:
  - name: deep-thinker
    chain:
      - router: codex-acp
        model: gpt-example
        thinking: xhigh
        max-output: 65536
```

The user file is `$XDG_CONFIG_HOME/agent-cat/routing.yaml`, falling back to `~/.config/agent-cat/routing.yaml`. The nearest `.agent-cat/routing.yaml` between cwd and the Git boundary is the project layer. Whole named routers and profiles in the project layer replace their user-layer counterparts. Explicit command-line routes have highest backend precedence (`Agentic.RoutingConfig`).

The decoder rejects unknown fields, duplicate names, empty chains, surrounding whitespace, unknown router references, non-positive output limits, non-scalar ACP options, and option names which may carry secrets. The resolver expands a profile chain into axes such as `deep-thinker`, `deep-thinker#2`, and so forth, preserves profile/rung provenance, and refuses an authored fallback chain combined with a multi-rung YAML chain.

ACP preflight opens a throwaway session, checks advertised model/thinking/output/option controls, validates offered values, and applies every setter before any question. Agent Deck verifies provider, model, thinking, and output metadata reported for the selected session. These checks remain authoritative in version 2.

## 4. Trust-separated files

Version 2 preserves the two-file discovery order but gives each layer a different authority. The conventional path assigns the role before YAML is decoded: `$XDG_CONFIG_HOME/agent-cat/routing.yaml` is the user layer and the nearest `.agent-cat/routing.yaml` is the project layer. Document shape can never promote a project file to user authority; a project-only user-shaped document is rejected as a project document before secret lookup. The legacy untagged loader remains available for version 1 but refuses version 2 because its authority would be unknowable.

### 4.1 User layer

The user layer may declare:

- secret references;
- engine instances, including endpoints and child-process environment;
- concrete model definitions;
- personas and their symbolic profiles; and
- the default persona.

This file is user-owned and should be mode 0600. It still contains no secret value.

### 4.2 Project layer

The project layer may declare only:

- the active persona; and
- profile overrides for that persona, referring to concrete model aliases already authorized by the user layer.

It may not declare or replace secrets, engine instances, adapter environment, catalogue URLs or headers, concrete model definitions, or the default persona. A checked-out repository can therefore ask for `agent-cat` and alter the ordering among model aliases the user has made available to that persona, but it cannot redirect a work credential to another endpoint.

Project profile overrides are whole-profile replacements, matching the simple version-1 merge rule. Every referenced model alias must be in the selected persona's model allowlist, and its owning engine must be in that persona's engine allowlist.

### 4.3 Why the authority is asymmetric

Allowing project configuration to pair a user secret with a project-provided base URL creates a credential-exfiltration path. Treating both layers as equal would make merely entering a repository sufficient to authorize its network destination. The loader therefore parses user and project files with distinct top-level types and rejects privileged fields in the project file before resolving a secret.

## 5. Version-2 schema

The model identifiers below are illustrative policy names supplied in the request. Their presence in this document does not assert that any provider currently offers them.

### 5.1 User file

```yaml
version: 2
default-persona: personal

secrets:
  anthropic-personal:
    env: ANTHROPIC_PERSONAL_API_KEY
  openai-work:
    env: OPENAI_WORK_API_KEY
  omlx-personal:
    env: OMLX_HERA_API_KEY

engines:
  claude-personal:
    backend: acp:claude
    provider: anthropic
    environment:
      ANTHROPIC_API_KEY:
        secret: anthropic-personal
    catalogue:
      dialect: anthropic
      url: https://api.anthropic.com/v1/models
      auth:
        header: x-api-key
        secret: anthropic-personal
      headers:
        anthropic-version: "2023-06-01"
      timeout-ms: 5000
      max-bytes: 4194304
      cache:
        fresh-for: 24h
        stale-if-error: 7d

  codex-work:
    backend: acp:codex
    provider: openai
    environment:
      OPENAI_API_KEY:
        secret: openai-work
    catalogue:
      dialect: openai
      url: https://api.openai.com/v1/models
      auth:
        header: authorization
        scheme: bearer
        secret: openai-work
      timeout-ms: 5000
      max-bytes: 4194304
      cache:
        fresh-for: 24h
        stale-if-error: 7d

  omlx-hera:
    backend: acp:omlx-hera
    provider: openai-compatible
    environment:
      OPENAI_BASE_URL:
        value: https://omlx-hera.example/v1
      OPENAI_API_KEY:
        secret: omlx-personal
    catalogue:
      dialect: openai
      url: https://omlx-hera.example/v1/models
      auth:
        header: authorization
        scheme: bearer
        secret: omlx-personal
      timeout-ms: 2000
      max-bytes: 4194304
      cache:
        fresh-for: 1h
        stale-if-error: 24h

models:
  anthropic-opus-personal:
    engine: claude-personal
    select:
      - exact: claude-opus-5

  openai-sol-work:
    engine: codex-work
    select:
      - exact: gpt-5.6-sol
      - prefix: gpt-5.6-sol-
        order: newest

  glm-next-personal:
    engine: omlx-hera
    select:
      - exact: GLM-5.3-Next

personas:
  personal:
    engines:
      - claude-personal
      - omlx-hera
    models:
      - anthropic-opus-personal
      - glm-next-personal
    profiles:
      deep-thinker:
        chain:
          - model: anthropic-opus-personal
            thinking: max
            max-output: unconstrained
          - model: glm-next-personal
            thinking: high
            max-output: 65536
            options:
              temperature: 0

  work:
    engines:
      - codex-work
    models:
      - openai-sol-work
    profiles:
      deep-thinker:
        chain:
          - model: openai-sol-work
            thinking: xhigh
            max-output: 65536

  agent-cat:
    engines:
      - claude-personal
      - omlx-hera
    models:
      - anthropic-opus-personal
      - glm-next-personal
    profiles:
      deep-thinker:
        chain:
          - model: anthropic-opus-personal
            thinking: max
            max-output: unconstrained
```

### 5.2 Project file

```yaml
version: 2
persona: agent-cat
```

A project which wishes to change an authorized ordering may do so without acquiring engine authority:

```yaml
version: 2
persona: agent-cat
profiles:
  deep-thinker:
    chain:
      - model: glm-next-personal
        thinking: high
        max-output: 65536
      - model: anthropic-opus-personal
        thinking: max
        max-output: unconstrained
```

This override expresses a low-cost preference directly: OMLX is first. It remains valid only because the user-owned `agent-cat` persona authorizes both engine instances and both model aliases.

### 5.3 Field semantics

#### `secrets`

Each secret is a name mapped to one environment-variable source. The source name is non-secret and may appear in a diagnostic; its value may not. Environment lookup is delayed until a live command needs the referenced engine.

Version 2 intentionally supports no literal, shell command, keychain program, or inline encrypted payload. Environment indirection is enough to satisfy the initial requirement without creating another execution surface. File and operating-system keyring providers may be added under a later schema version if a concrete deployment requires them.

#### `engines`

An engine instance has:

- `backend`: the existing `acp:` or `deck:` grammar;
- `provider`: non-secret identity used for preflight/provenance;
- optional `environment`: exact child environment bindings, each from a non-secret literal or a named secret; and
- optional `catalogue`: an informational model endpoint.

Sensitive-looking environment names cannot take `value`; they must take `secret`. Unknown environment-binding fields are refused. Adapter arguments remain separate and retain the existing credential-bearing argv refusal. A SHA-256 engine-definition fingerprint covers backend, provider, non-secret environment structure and literals, secret alias/source names, and catalogue policy; it never covers a secret value. This fingerprint participates in persisted lineage compatibility.

A `deck:` engine normally omits `environment`: the selected Agent Deck session was created elsewhere, and its credentials and endpoint are external. Its reported provider/model/thinking metadata remain the verification surface. A catalogue may still be configured for display, but it does not reconfigure that session.

#### `catalogue`

`dialect` selects the response decoder, not the execution engine. Version 2 supports:

- `openai`: an object with `object: "list"` and a `data` array containing unique model objects with `id`, optional numeric `created`, and optional `owned_by`; and
- `anthropic`: cursor-paginated objects with `data`, `has_more`, `first_id`, and `last_id`, whose models carry `id`, optional `created_at`, display name, limits, and capability metadata.

`url` is complete, not a base to which hidden path rules are applied. HTTPS is required whenever `auth` is present; plain HTTP is accepted only without authentication and only for a syntactically valid literal IPv4 `127/8` or IPv6 `::1` address. The URL contains no user-info component or fragment. Query keys are percent-decoded as UTF-8 before credential-shape checks, and malformed percent encoding is refused. Redirects are disabled.

`auth` supplies one header from a secret reference. `scheme: bearer` prefixes the value with `Bearer `; absence of `scheme` sends the raw value, as Anthropic's `x-api-key` requires. Literal values are forbidden for credential-shaped headers. Additional `headers` use non-sensitive RFC-token names. The final explicit header set—including literal headers, resolved authentication, and the generated request id—is limited to 64 entries and 61,440 aggregate name/value bytes; every value is at most 8,192 bytes and contains no control/newline. The auth header cannot be duplicated among literals.

A catalogue URL is at most 8,192 UTF-8 bytes. Its query is at most 4,096 bytes and 64 items. `timeout-ms` is in `1..60000`; `max-bytes` is in `1..4194304`. Discovery is further bounded to 100 pages, 10,000 models, and 512 UTF-8 bytes per id. Cache durations are positive integer `s`, `m`, `h`, or `d` values no greater than one year, and `stale-if-error` is not shorter than `fresh-for`. Values outside these maxima are refused at decode time rather than trusted to exhaust memory later.

A discovered id is non-empty, has no leading/trailing or embedded whitespace, and contains no Unicode control or format character. It otherwise remains opaque; punctuation such as `/`, `:`, `.`, `_`, `+`, and `-` is not assigned semantics by the parser.

#### `models`

A concrete model definition belongs to exactly one engine and has a non-empty, ordered `select` list.

- `exact` names a model id. It can resolve without an inventory and is marked `static-unverified` when no usable inventory exists. The engine's ordinary ACP/deck preflight remains final.
- `prefix` requires an inventory. One match resolves directly; multiple matches require `order`.
- `order: newest` compares normalized creation timestamps supplied by the selected catalogue dialect and then uses model id ascending as a deterministic tie-breaker. A match missing the required timestamp makes that selector unusable rather than “probably old.”
- `order: id-descending` is available only when explicitly written; the resolver never assumes that lexical order means recency.

Selectors are tried in declaration order. API response order is ignored.

Regular expressions, arbitrary predicates, capability expressions, and price optimizers are absent from version 2. They are not required to express the requested examples, and each would introduce a policy language of its own.

#### `personas`

A persona carries two explicit allowlists and then defines whole symbolic profiles: `engines` authorizes physical engine instances, while `models` authorizes concrete model aliases. A model alias is eligible only when it appears in the persona's `models` list and its owning engine appears in the persona's `engines` list. Thus two personas may share one engine while admitting different models on it.

Each profile chain is non-empty, and every rung must name a model eligible for that persona. Project profile overrides and `--realize` may select only from the same model allowlist; project configuration cannot widen either allowlist. The same symbolic name may resolve differently in every persona.

A profile rung retains the version-1 generation requirements: `thinking`, `max-output`, and optional non-secret scalar ACP `options`. Generation settings remain on the rung rather than the model alias because one exact model may serve distinct symbolic profiles at different effort or output limits.

## 6. Persona selection

The active persona is chosen once per live routing operation with this precedence:

1. explicit `--persona NAME`;
2. `AGENT_CAT_PERSONA`;
3. project-layer `persona`;
4. user-layer `default-persona`.

No cwd substring, Git remote, organization name, branch, hostname, or email address is inferred. A repository selects a project persona by committing the explicit project-layer field; a command can override it visibly.

A missing or unknown persona is a setup refusal before secret resolution, discovery, adapter spawn, store creation, or paid work. Agent-cat never falls back from `work` to `personal` or from one project's persona to another.

Persona does not become a `run.*` workflow fact. A workflow cannot branch on it. The selected persona and its resolved policy are recorded in non-secret run provenance so that resume/fork compatibility and frontend display remain honest.

## 7. Child-process environment

### 7.1 Required engine change

`AcpConfig` now carries an opaque `ChildEnvironment`. Its default preserves complete ambient inheritance for v1. CLI composition resolves selected v2 environment bindings immediately before discovery/spawn, passes one exact redacted map to ACP, and leaves `Agentic.Engine.ModelConfig` unchanged.

### 7.2 Persona is not automatically a security boundary

An ACP adapter may also read credentials from files under `HOME`, `XDG_CONFIG_HOME`, or its own profile directory. Selecting an environment variable does not prevent that. Accordingly:

- engine definitions can set non-secret profile/base-directory variables explicitly;
- help calls persona a routing context, not credential isolation; and
- deployments requiring strict separation use distinct adapter profiles, operating-system accounts, or sandboxes.

Version 2 claims no more isolation than the spawned adapter provides.

### 7.3 Inheritance policy

The implementation preserves the ambient environment needed for `PATH`, locale, home/config lookup, temporary files, proxies, and adapter operation, then overlays declared bindings. Before spawn, it removes every variable name declared in any configured engine's `environment` map and every source environment-variable name declared under version-2 `secrets`; it then installs only the selected engine's resolved bindings. This rule follows declared data rather than guessing from provider names or credential-shaped spellings. Undeclared ambient credentials remain one reason persona is not an isolation boundary.

A wholly allowlisted environment would be stronger but risks silently breaking adapters whose required variables are not yet known. Make complete environment isolation a later explicit engine option once adapter requirements have been measured. Regardless of inheritance, resolved secret values are wrapped in a redacted type whose `Show` instance cannot reveal them, are never included in target policy, and are dropped after process construction as far as ordinary Haskell lifetime permits.

## 8. Discovery and cache

### 8.1 When network access occurs

Static commands remain offline. `list`, `help`, `plan`, and `cost` do not load secrets or call a model endpoint. Discovery runs only for:

- a live run whose used engine declares a catalogue; exact selectors consult it opportunistically, while prefix selectors require it;
- explicit routing inspection or refresh; or
- TUI routing display requested by the operator.

This preserves the current distinction in which routing configuration attaches only to commands that can reach a live backend.

### 8.2 HTTP client

`Agentic.RoutingDiscovery` uses `http-client` and `http-client-tls`; it never invokes `curl`. Authorization therefore never enters process argv, executable availability is not an undeclared contract, and body/redirect behavior remains bounded Haskell code.

The client:

- verify TLS through the standard manager and refuse authenticated plain HTTP; unauthenticated HTTP is restricted to loopback addresses;
- disable redirects;
- apply connection and response timeouts;
- stream and stop at `max-bytes` before decoding;
- recheck total URL bytes, query bytes, and query-item count after adding pagination parameters;
- bound the complete explicit request-header count and bytes, including resolved authentication and the generated request id;
- bound pages and entries;
- reject duplicate/empty/oversized model ids and malformed pagination;
- permit unknown response object fields for provider compatibility; and
- include a generated request id where supported and never expose authorization in diagnostics.

The OpenAI API uses bearer authentication and returns a `data` array of model objects (`GET /v1/models`, OpenAI API reference). Anthropic's endpoint uses `x-api-key` and `anthropic-version`, defaults to 20 entries, accepts up to 1,000, and paginates with `after_id`/`last_id` (`GET /v1/models`, Claude API reference). OpenAI-compatible servers such as Ollama expose `/v1/models` but may assign different meanings to metadata such as `created` and `owned_by`; the dialect parser therefore treats ids as authoritative and ordering metadata only under an explicit selector rule (Ollama OpenAI compatibility documentation).

### 8.3 Cache layout

Inventories live beneath:

```text
$XDG_CACHE_HOME/agent-cat/models/<persona>/<engine-fingerprint>.json
```

with `~/.cache` as the XDG fallback. Each mode-0600 atomic record is bounded to 8 MiB before allocation and contains:

- cache schema version;
- persona and engine names;
- a SHA-256 engine fingerprint over backend, provider, non-secret environment bindings, secret alias/source names, catalogue URL/dialect/headers/auth reference, limits, and cache policy—but never a secret value;
- a separate endpoint fingerprint retained as selection provenance;
- retrieval time and optional validators such as ETag;
- normalized model ids and permitted metadata; and
- response provenance sufficient to explain selection.

Caches are never shared across personas or differently fingerprinted engine definitions. A base URL may itself be private, so the path and routine diagnostic use its digest rather than the URL. Managed cache directories are mode 0700 and must be real directories rather than symbolic links.

Changing the value behind one secret reference does not change the fingerprint: no secret-derived digest is persisted. Ordinary key rotation for the same account can reuse the cache; changing the account behind an existing environment-variable name requires `--refresh-models` or a new secret alias, which produces a new fingerprint.

### 8.4 Freshness and failure

- A cache younger than `fresh-for` is used without network access unless explicit refresh was requested.
- An expired cache prompts a refresh.
- If refresh fails and the cache age is within `stale-if-error`, the stale inventory may be used, marked `stale-cache` with age and failure class.
- A cache older than that bound is unusable.
- An exact selector may still resolve statically when no inventory is usable; its provenance is `static-unverified`, and ordinary engine preflight decides availability. When a usable inventory exists and omits that id, the selector does not override the evidence: resolution tries the next selector or fails.
- A prefix selector without usable inventory fails before adapter startup.
- Explicit `--offline` performs no network operation. It uses a permitted cache or exact static selector and reports which.
- Explicit `--refresh-models` refuses on refresh failure rather than silently using stale data, because refresh was the command's purpose.

Staleness never changes candidate order. It changes only provenance and whether an inventory-dependent selector has evidence.

## 9. Resolution algorithm

Resolution proceeds in the following order:

1. Discover user and nearest project files.
2. Decode each strictly, select the all-v1 or all-v2 path, and refuse mixed versions.
3. For version 2, enforce layer authority before merging anything.
4. Select one persona by the precedence in Section 6.
5. Overlay project profile replacements onto that persona; validate all names, references, engine and model allowlists, options, URLs, headers, and secret sources without reading secret values.
6. Build the workflow under the existing run-fact/routing fixed point to discover the symbolic model names it actually serves.
7. Reject the existing ambiguity between an authored fallback chain and a multi-rung configured profile.
8. Determine only the engine instances needed by those profiles and resolve every secret they require. A missing secret is a named setup failure before discovery, adapter startup, or store creation; no secret value enters the message.
9. Obtain one frozen inventory per needed engine which declares a catalogue, using the cache/network rules in Section 8. Exact selectors use this evidence opportunistically; inventory-dependent selectors require it.
10. Resolve each concrete model alias by its ordered selectors. Record selector index, exact model id, source, timestamp, and cache age.
11. Expand each symbolic chain to runtime axes `profile`, `profile#2`, and onward, as version 1 does.
12. Freeze a `ResolvedRouting` containing persona, engine alias, backend, provider, model alias, exact model id, generation settings, options, and discovery provenance.
13. Start every required backend and run existing ACP/deck preflight. Catalogue evidence does not replace adapter evidence.
14. Persist the non-secret resolved policy and its digest before the first question.

The frozen selection cannot change in the middle of a run. A newly appearing model, refreshed cache, endpoint outage, or edited default persona affects the next run only.

### 9.1 Command-line route overrides

Raw version-1 `--route MODEL=BACKEND` behavior remains unchanged for version-1 configuration and unconfigured symbolic names.

For a version-2 configured axis, changing only the backend can separate a model from the engine environment, credential, inventory, and provider through which it was validated. Version 2 therefore overrides with a concrete model alias, whose declaration carries the engine:

```text
--realize AXIS=MODEL-ALIAS
```

The alias must appear in the selected persona's model allowlist, and its owning engine must appear in that persona's engine allowlist. A raw `--route` against a version-2 managed axis is refused with guidance to use `--realize` or a project profile override. This is a new-v2 restriction, not a change to existing v1 files.

## 10. Provenance and inspection

The sanitized inspection mode is:

```text
agentic-run --routing --json [--persona NAME] [--offline | --refresh-models]
```

Its JSON contains:

- schema version, selected persona with selection source, and available persona/model-alias choices;
- contributing config paths;
- engine aliases, backend/provider, credential readiness as a boolean, and catalogue status;
- concrete aliases and selected exact ids with selector/provenance;
- symbolic profiles and ordered resolved rungs; and
- warnings for stale inventory or static-unverified exact ids.

It omits secret values and references, authorization/header values, adapter environment names and values, raw endpoint URLs, and inventories not selected by a profile. Human output likewise uses endpoint fingerprints rather than URLs.

ext-pi consumes this mode today; the future TUI consumes the same contract. Neither frontend parses YAML, applies precedence, or resolves a model. A leading option avoids reserving a downstream workflow name.

The machine run manifest's policy includes the following fields plus a canonical SHA-256 policy digest:

```json
{
  "persona": "personal",
  "profile": "deep-thinker",
  "axis": "deep-thinker",
  "rung": 1,
  "engine": "claude-personal",
  "backend": "acp:claude",
  "provider": "anthropic",
  "modelAlias": "anthropic-opus-personal",
  "model": "claude-opus-5",
  "thinking": "max",
  "maxOutput": null,
  "inventory": {
    "source": "fresh",
    "fingerprint": "sha256:…",
    "fetchedAt": "…"
  }
}
```

This is non-secret and makes a run explainable. The immutable manifest retains the complete frozen provenance snapshot and its digest. Semantic restart/resume compares the stable execution projection exactly: persona and selection source, engine/backend/provider, exact model and selector, endpoint and engine fingerprints, settings, options, and routes remain significant. Observation-only `inventory.source`, `fetchedAt`, `cacheAgeSeconds`, and `warning` fields—and the full-snapshot digest derived from them—do not make an otherwise identical catalogue-backed run incompatible. Restart remains available when the stable projection differs.

## 11. Worked outcomes

### 11.1 Work `deep-thinker`

Context: project has no selector, CLI supplies `--persona work`.

Resolution:

```text
deep-thinker
  persona: work                 (--persona)
  model alias: openai-sol-work
  engine: codex-work
  backend: acp:codex
  exact model: gpt-5.6-sol
  thinking: xhigh
```

If the exact id appears in a fresh OpenAI inventory, provenance is `fresh`. If inventory fails, the exact selector remains `static-unverified`; ACP preflight must still advertise and accept it before spend.

### 11.2 Personal `deep-thinker`

Context: no explicit or project selector; user default is `personal`.

Resolution begins with `anthropic-opus-personal` on `claude-personal`, producing exact `claude-opus-5` through `acp:claude`. The second rung is the personal-only `glm-next-personal` on `omlx-hera`. It is a runtime failover, not an engine the `work` persona can reach.

### 11.3 Project-specific low-cost ordering

Context: `.agent-cat/routing.yaml` selects `agent-cat` and replaces `deep-thinker` with the OMLX alias first.

Resolution uses `GLM-5.3-Next` on `omlx-hera`, then Claude as the spare. This is the requested low-cost mixture. No price database or name heuristic participates; the project profile's declared order is the policy.

### 11.4 Unavailable discovery endpoint

- Exact-only alias: select the exact id as `static-unverified`; retain the network failure as a warning; require engine preflight.
- Prefix-only alias with fresh-enough cache: use the cache and mark its age/source.
- Prefix-only alias with no permitted cache: fail setup and name persona, engine, alias, endpoint fingerprint, and failure class. Do not mention authorization or attempt another persona.

### 11.5 Stale cache

A cache older than `fresh-for` but younger than `stale-if-error` is used only after refresh fails and is reported as stale. A cache beyond `stale-if-error` cannot satisfy a prefix selector. `--refresh-models` never degrades to stale.

### 11.6 Missing credential

If `OPENAI_WORK_API_KEY` is absent, resolution fails before the catalogue request, adapter spawn, run-store creation, or paid turn:

```text
routing configuration: persona 'work', engine 'codex-work' requires secret
'openai-work' from environment variable OPENAI_WORK_API_KEY, which is unset
```

No fallback to personal occurs. No partial secret value is printed.

### 11.7 Ambiguous selector

A prefix matching several ids without `order` is a configuration error. With `order: newest`, every contender must provide a valid dialect-normalized creation time; equal times use id ascending. API array order never decides.

### 11.8 Invalid project authority

A project file containing `engines`, `models`, `secrets`, `default-persona`, catalogue fields, or environment bindings is refused before merge. The message identifies the forbidden field and states that it belongs in the user file.

### 11.9 Deterministic fallback

The selected exact id of every rung is frozen before engines start. Runtime failover follows the profile's expanded `#N` axes exactly as today. Discovery is not retried during failover, and a later API response cannot reorder the chain.

## 12. Data types and module ownership

Parsing, discovery, inspection, and resolution remain in CLI ownership:

```text
cli/src/Agentic/RoutingConfig.hs       strict v1/v2 decode, merge, validation
cli/src/Agentic/RoutingDiscovery.hs    bounded HTTP and cache
cli/src/Agentic/RoutingInspect.hs      sanitized human/JSON projection
cli/src/Agentic/Cli.hs                 command/flag composition and preflight
engine/acp/src/Agentic/Acp.hs          resolved child environment only
runtime/...                            no config parsing or secret lookup
```

Indicative internal types are:

```haskell
newtype PersonaName = PersonaName Text
newtype EngineName = EngineName Text
newtype ModelAlias = ModelAlias Text
newtype SecretName = SecretName Text

data SecretRef = SecretEnv Text

data EngineDef = EngineDef
  { engineBackend     :: Backend
  , engineProvider    :: Text
  , engineEnvironment :: Map Text EnvBinding
  , engineCatalogue   :: Maybe Catalogue
  }

data ModelDef = ModelDef
  { concreteEngine    :: EngineName
  , concreteSelectors :: NonEmpty ModelSelector
  }

data Persona = Persona
  { personaEngines  :: Set EngineName
  , personaModels   :: Set ModelAlias
  , personaProfiles :: Map Text ProfileV2
  }
```

The implementation modules remain Cabal-hidden; `Agentic.RoutingConfig` exposes the existing high-level resolver surface. Secret-bearing resolved environment values receive no `Eq`, `Show`, `ToJSON`, or persistence instance, while `ChildEnvironment` renders only a redacted binding count.

`ModelConfig` remains:

```haskell
ModelConfig
  { modelName      :: Text
  , modelThinking  :: Thinking
  , modelMaxOutput :: Maybe Integer
  }
```

ACP options remain in `AcpModelConfig`; provider identity remains in `DeckModelConfig`. This preserves the abstractions established by the modularization.

## 13. Validation contract

`doc/check-model-routing-v2.hs` is an executable design oracle, not production routing code. It extracts all four YAML blocks in this document; scans mapping scopes for duplicate keys before `Data.Yaml`; decodes strict version-2 user and project records; validates references, layer authority, persona eligibility, URL/auth/query policy, sensitive literals, headers, durations, body/timeout bounds, and child-environment scrubbing; and evaluates selector, cache-age, normal, offline, and explicit-refresh decisions over deterministic in-memory inventories and environments. It compiles under `-Wall -Werror` and is part of `make -C doc check`.

The production probes are independent of that oracle. The decoder retains pinned
libyaml duplicate warnings for block and flow mappings; resolver tests reverse
inventory order and exercise engine fingerprints; local HTTP/cache tests cover
oversized cache files and symbolic-link directory refusal as well as response
bounds. The CLI gate checks exact persisted policy and lineage changes.

The checked trace is:

| Case | Expected outcome |
|---|---|
| Documented YAML blocks | no duplicate mapping key at any nesting level |
| Synthetic nested duplicate | refused before `Data.Yaml` decoding |
| Version-1 block | explicitly remains version 1 |
| Version-2 user/project blocks | all references and both persona allowlists validate |
| Persona selection | CLI, environment, project, then user default |
| Catalogue URLs | HTTPS auth; no user-info, fragment, secret query, or authenticated HTTP |
| Sensitive/non-scalar literals | credential environment/header/profile options and nested options refused |
| Bounds | header, timeout, body, and duration limits enforced |
| Discovery/cache mode | normal, offline, explicit refresh, and age windows produce distinct decisions |
| Work `deep-thinker` | `openai-sol-work` → `gpt-5.6-sol` |
| Personal `deep-thinker` | Claude Opus, then personal-only OMLX |
| `agent-cat` project override | OMLX first, then Claude |
| Work model eligibility | personal GLM alias excluded |
| Project profile under `work` | personal GLM alias refused despite project override authority |
| Unavailable inventories | exact ids become `static-unverified` |
| Permitted stale inventory | newest matching prefix selected as `stale-cache` |
| Reversed inventory order | identical selection |
| Ambiguous unordered prefix | refused |
| Missing work credential | refused before discovery |
| Codex child environment | selected destination installed; source and unselected secrets scrubbed |
| Project engine declaration | refused by the project schema |

Run it directly with:

```sh
nix develop path:. -c runghc -Wall -Werror doc/check-model-routing-v2.hs
```

### 13.1 Decoder tests

Test unknown fields, duplicate map keys, empty/whitespace names, reserved `#`, invalid backend grammar, unknown references, unauthorized persona engines or models, empty chains/selectors, invalid durations/limits/URLs/headers, secret literals, sensitive literal environment values, nested/non-scalar options, project privilege escalation, and mixed schema versions.

YAML duplicate keys must be detected rather than silently overwritten. If the selected YAML decoder cannot retain duplicate object keys, decode the named collections in list form or add a token-level duplicate check before semantic decoding, as version 1 already does for named routers/profiles.

### 13.2 Pure resolver tests

Use in-memory inventories and environments to establish:

- persona precedence;
- project whole-profile replacement;
- engine and model allowlists;
- exact and prefix selector order;
- timestamp normalization and deterministic tie-breaking;
- no reliance on API array/map order;
- current axis generation and authored/configured-chain ambiguity refusal;
- static-unverified, fresh, cached, stale, and offline provenance;
- raw v1 route compatibility and v2 managed-route refusal; and
- complete non-secret target policy.

The production property probe permutes inventory order while preserving the same resolved output; the independent executable oracle checks the same invariant over its own types.

### 13.3 HTTP/cache tests

Use local deterministic servers. Cover timeouts, status errors, TLS/plain URL policy, redirect refusal, oversized and chunked bodies, malformed JSON, unknown fields, duplicate ids, item/page bounds, Anthropic pagination loops, OpenAI-compatible missing metadata, cache fingerprint separation, atomic replacement, torn/corrupt cache, stale windows, and explicit refresh semantics.

No test calls a vendor endpoint.

### 13.4 Secret tests

Seed distinctive sentinel values and scan:

- stdout/stderr and exceptions;
- process argv;
- environment diagnostics;
- routing-inspection JSON;
- runtime and frontend manifests;
- event, effect, snapshot, and stderr logs; and
- cache files.

Configure distinct selected and unselected secret sentinels. The selected value may occur only in the selected destination variable of the spawned test double; source-variable names are scrubbed, and every unselected value is absent from the child. Also test that a project file cannot pair a user secret with a project endpoint.

### 13.5 Engine preflight tests

Catalogue success does not waive existing preflight. Exercise an inventory which advertises a model while ACP omits its model setter, rejects the value, or lacks thinking/output controls; each run must fail before a prompt. Exercise Agent Deck metadata mismatch in the same manner.

## 14. Migration

### 14.1 Version 1

All-version-1 discovered files retain their present decoder, merge, command-line route precedence, generated axes, preflight, and persisted policy. No environment secret or network discovery is introduced on that path.

### 14.2 Version 2 adoption

The mechanical command is:

```text
agentic-run --migrate-routing routing.yaml --output routing-v2.yaml
```

It creates one engine per v1 router, one exact concrete alias per `(router, model)` pair, one `default` persona whose engine and model allowlists contain exactly those generated names, and equivalent profile chains. Multiple v1 routers may retain different provider provenance while sharing one backend, and an empty valid v1 policy migrates to an empty default persona. Exclusive creation refuses an existing destination or the source path. Since v1 has no secret or endpoint data, generated environment and catalogue fields remain absent and inspection stays offline.

After review, the user replaces both user/project files together. A mixed pair is refused, making partial migration visible.

### 14.3 Descriptor and ext-pi

Descriptor version 3 advertises persona/routing inspection and protocol negotiation while retaining machine protocol version 1. ext-pi accepts descriptor versions 1, 2, and 3, reads sanitized routing JSON, and passes `--persona`/`--realize`; it never reads routing files, secret references, or model caches.

### 14.4 Rollback

Version 1 support remains intact. Rollback consists of restoring version-1 files and omitting v2-only options; no store conversion is necessary. Runs made under v2 preserve their frozen target policy and remain inspectable from their manifests even if a persona definition is later removed.

## 15. Rejected alternatives

| Alternative | Reason for rejection |
|---|---|
| Put persona in workflow source or `run.persona` | Couples denotation to machine/account context and permits workflows to branch on credentials. |
| Let project files define engines or endpoints | Permits a repository to redirect user-owned credentials. |
| Store keys in YAML, even encrypted | Requires decryption/key management, risks logs and diffs, and is unnecessary when environment indirection suffices. |
| Invoke `curl` for discovery | Exposes headers through argv or an ad hoc config file and makes process availability part of routing. |
| Choose the first `/v1/models` entry | Provider ordering is not a portable preference contract; Anthropic and OpenAI-compatible servers differ. |
| Regex/capability/price policy language | Not required for the stated examples and creates a second DSL whose determinism and migration must be maintained. |
| Silently skip a rung with missing credentials | Changes authored fallback policy and can cross persona boundaries without consent. |
| Extend protocol v1 with unknown event kinds | Existing clients reject them correctly; negotiation is the compatible path. |
| Put endpoint and discovery in `Agentic.Engine` | Model-file I/O and realization are CLI composition responsibilities; runtime and engines remain identity-neutral. |

## 16. Implementation sequence

1. **Complete:** strict v2 data types, authority validation, and unchanged v1 decoding.
2. **Complete:** persona selection and deterministic pure resolution.
3. **Complete:** redacted ACP child environments and sentinel non-disclosure tests.
4. **Complete:** bounded discovery/cache with deterministic local servers.
5. **Complete:** frozen persisted policy, digest, and lineage comparison.
6. **Complete:** inspection, migration, persona/cache options, and model-alias overrides.
7. **Complete for ext-pi; deferred for TUI:** both consume the same sanitized output, but no Brick code exists yet.
8. **Complete:** examples, manual, source-boundary checks, and downstream compatibility gates.

Every stage retains the non-paid ACP/deck fixtures and existing v1 routing probe.

## 17. Source register

### Local authority

- `cli/src/Agentic/{RoutingConfig,RoutingConfig/V2,RoutingDiscovery,RoutingSecrets,RoutingInspect,Cli}.hs`
- `cli/model-definitions.example.yaml`, routing/config/discovery probes, and deterministic catalogue fixture
- `engine/api/src/Agentic/Engine.hs`, `engine/acp/src/Agentic/Acp.hs`, and `engine/agent-deck/src/Agentic/AgentDeck.hs`
- `runtime/src/Agentic/Runtime/{Protocol,Control,Store}.hs`
- `ext-pi/src/{catalogue,types,launch,reducer,supervisor,index}.ts`, tests, and `ext-pi/README.md`
- `doc/routing-v2-verification.md` for exact commands, outcomes, review remediation, and residuals

The original design audit inspected revision `9df3cd3b6d42fa315b82b43db1749643cb45d9c4`; implementation evidence is recorded in `doc/routing-v2-verification.md`.

### External authority

- OpenAI API authentication/header guidance and model-list rendering, accessed 2026-09-03: <https://developers.openai.com/api/reference/overview.md> and <https://developers.openai.com/api/reference/resources/models/methods/list.md>
- OpenAI's machine-readable specification pinned at commit `b60c665790380f8413ecd1666ddfd6fc1a429c94` (`OpenAI-API-Ref-Source-Revision: 1051358`): <https://github.com/openai/openai-openapi/blob/b60c665790380f8413ecd1666ddfd6fc1a429c94/openapi.json>
- Anthropic model-list authentication, pagination, limits, and metadata, accessed 2026-09-03 under required API header `anthropic-version: 2023-06-01`: <https://platform.claude.com/docs/en/api/models/list>
- Ollama's OpenAI-compatible `/v1/models` metadata qualifications, accessed 2026-09-03: <https://docs.ollama.com/api/openai-compatibility>

Endpoint schemas and provider behavior remain volatile and must be rechecked when a supported provider changes its model-list contract.
