# engine/api

`engine/api/src` defines `Agentic.Engine`, the only interface that the runtime
and the concrete engines share. It contains neutral values for requests,
results, completion, failures, steering, lanes, and common model settings, and
it names no concrete transport.

## Public module

`Agentic.Engine` exposes the `Engine` type class. The class has one operation
that starts a logical conversation and one optional ordered lane. The runtime
translates typed plan requests into `EngineRequest` values, and an instance
returns raw `EngineResult` values. `ModelConfig` carries only the settings that
both current engines implement, which are the model, the thinking level, and
the maximum output. Symbolic profiles, routers, provider identity,
backend-specific options, and file loading remain in the CLI.

`EngineUpdate` keeps streamed answer chunks separate from optional public message,
tool, todo, usage, and explicitly public reasoning-summary updates. An engine may
emit none. An engine may also supply exact values through
`enginePublicRedactionValues`; these are private filtering context, not updates. The
runtime alone validates, bounds, redacts, persists, or omits presentation facts;
they do not alter `EngineResult`.

`EnginePermission` carries an `EnginePermissionReport`. An adapter sends one
for each permission request that it answers during the active turn. The report
names the question under way, the tool call that the agent asked for, and the
answer, which is a grant with the selected option or a refusal. It is not
public progress, and the runtime emits no public event for it.

## Value codecs

`encodeEngineRequest`, `encodeEngineResult`, `encodeEngineSteering` and
`encodeEnginePermissionReport` write a JSON object with the field `version`
set to `engineCodecVersion`, which is 1. The matching decoders refuse a value
that is not an object, a missing field, an unknown field, a field of the wrong
type and every other version. For each value `x`, `decode (encode x)` is
`Right x`. The draw is a JSON string of canonical decimal digits, so an
`Integer` of any size stays exact. Text is carried unchanged. A completion is
an object with the field `state`, and an incomplete completion also carries
its `reason`. A permission answer is an object with the field `outcome`, and a
grant also carries its `option`. The line decoder that produces the JSON value
refuses duplicate keys.

## Dependencies

This directory imports no other agent-cat directory. The runtime, the ACP
engine, and the agent-deck engine depend on it.

## Build and test

```sh
nix develop path:. -c cabal test engine-api-test
```

The test suite drives a deterministic fake engine through the complete public
contract. It also round-trips each codec through JSON bytes on Unicode, empty
text, draws above 2^64, every intent and answer kind, all three completions,
both steering values and granted and refused permissions. It checks that each
decoder refuses an unknown field, a missing field, a missing version and
version 2.

## Conventions

Add only capabilities that every supported engine shares. Typed planning and
runtime policy stay above this interface, and concrete wire detail stays below
it.
