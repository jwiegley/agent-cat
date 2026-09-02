# Factory Droid live verification record

This record contains commands, configuration, and non-secret outcomes only. It deliberately omits all model response content.

## Authorization

After the failed diagnostic was disclosed, the user wrote:

> I approve this and all future questions. Complete this task autonomously without asking for my interaction, unless the item to be decided is critical.

The confirmed goal revision permits the disclosed pre-fix diagnostic, its automatic retry, and the authorized follow-up. It also states that an additional live call may be made when a critical new blocker requires one.

After that revision, the independent auditor rejected completion specifically because the then-recorded live run used an intermediate profile that omitted `max-output` and therefore did not exercise the final required policy. That rejection made a final-policy live turn a critical completion blocker. The user authorization quoted above and the goal's critical-blocker exception authorized that turn. At goal completion it was the sole final-policy acceptance smoke; every earlier post-fix turn remained classified as diagnostic.

After completion, the user explicitly requested a new acceptance target:

> Live acceptance with gpt-5.6-sol is fine, but let's change that to use gpt-5.6-luna.

That request authorized one replacement read-only/no-tool live turn. The original Sol acceptance remains below as truthful historical evidence; the new Luna run is the current acceptance.

## Pre-fix diagnostic (not acceptance)

Command:

```sh
cd haskell
"$(cabal list-bin agentic-run)" run structured \
  --engine acp --adapter droid --timeout 180000
```

Observed outcome:

- process exit: `3`;
- one authored structured occurrence;
- Droid persisted two completed model turns and two assistant messages because agent-cat automatically retried the undecodable assembled answer;
- both persisted assistant values independently decoded under the requested schema;
- zero tool blocks;
- Droid process count returned to its pre-run value.

This diagnostic exposed the defect: Factory Droid retained one event subscriber per opened ACP session, while agent-cat assembled chunks without checking `params.sessionId`. Each text delta therefore arrived once for the stale initial session and once for the current question session.

## Authorized post-fix diagnostic (not acceptance)

A temporary one-question text registry used marker:

```text
AGENT_CAT_DROID_SMOKE_1788303465110535000
```

Command shape:

```sh
cd haskell
"$work/droid-smoke" run one \
  --engine acp --adapter droid --timeout 180000
```

The outer verification shell exited `1` because its post-run Python verifier contained an unterminated f-string. The Factory turn itself had already completed. Local Droid evidence recorded one completed model turn, one nonempty assistant message, the marker once, zero tool blocks, and no remaining Droid process. This run was diagnostic evidence only because the runner exit status was not retained.

## Post-fix routed intermediate-policy diagnostic (not acceptance)

This authorized run proved live model/reasoning selection, but its profile omitted the output policy later required by the final goal. It is retained as diagnostic evidence and is not the acceptance smoke.

### Temporary registry source

The temporary binary named `droid-smoke` was compiled against the repository's `agentic` library from this program (the Haskell layout is normalized here; semantics and prompt bytes are unchanged):

```haskell
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
module Main (main) where

import Agentic.Cli (Registry (..), Row (..), cliMain)
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W

smokeProgram :: Program
smokeProgram = workflow W.do
  _ <- ask (servedBy (model "factory-smoke") "factory-profile") [wf|
    Reply with exactly AGENT_CAT_DROID_ROUTED_SMOKE_1788304692513363000 and nothing else.|]
  stop

registry :: Registry
registry = Registry
  { regBinary = "droid-smoke"
  , regNoun = "workflow"
  , regBanner = "one bounded routed Factory Droid ACP verification"
  , regRows =
      [ ("one", Row
          { rowExample = Fixed smokeProgram
          , rowDoc = "one no-tool routed Factory response"
          , rowHelp = "Temporary routed live verification workflow."
          , rowScript = [("Reply with exactly", "AGENT_CAT_DROID_ROUTED_SMOKE_1788304692513363000")]
          })
      ]
  }

main :: IO ()
main = cliMain registry
```

### Temporary routing profile

The diagnostic used this exact profile under its temporary `XDG_CONFIG_HOME`:

```yaml
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: factory-profile
    chain:
      - router: factory-droid
        model: gpt-5.6-sol
        thinking: low
```

At that intermediate revision, omitted `max-output` represented no output-limit control. The final representation makes the same policy explicit and keeps omission invalid:

```yaml
        max-output: unconstrained
```

The final offline routing gate exercises this exact explicit policy and proves that model and reasoning setters run while no max-output setter is sent.

### Compile and run commands

`$work` was a private `mktemp -d` directory removed after verification. The package database and unit ID are repository build artifacts produced by `cabal build all`.

```sh
cd haskell
db="$PWD/dist-newstyle/packagedb/ghc-9.10.3"
nix develop -c ghc -v0 -O0 \
  -outputdir "$work/ghc" \
  -package-db "$db" \
  -package-id agentic-0.1.0.0-inplace \
  "$work/Smoke.hs" -o "$work/droid-smoke"

XDG_CONFIG_HOME="$work/xdg" \
  "$work/droid-smoke" run one \
  --engine acp --adapter droid --timeout 180000
```

### Recorded outcome

```text
exit_status=0
prompts=1
responses=1
nonempty=true
marker_occurrences=1
header_configured=true
model_ids=['gpt-5.6-sol']
reasoning_efforts=['low']
billFresh=1
billMemo=1
model_turn_outcomes=1
assistant_messages=1
tool_blocks=0
permission_events=false
droid_processes_before=0
droid_processes_after=0
terminated=true
```

The response bytes are intentionally absent from this record.

## Original final-policy post-fix acceptance (superseded target)

This was the acceptance smoke for the completed goal. It ran after the required policy became: positive integer output bound or explicit `max-output: unconstrained`, with omission invalid. The later Luna run supersedes only its designation as the current target; these observations remain unchanged.

The temporary registry source was the source above with these exact substitutions:

```text
AGENT_CAT_DROID_ROUTED_SMOKE_1788304692513363000
  -> AGENT_CAT_DROID_FINAL_SMOKE_1788307913689375000
regBanner = "one bounded final-policy Factory Droid ACP verification"
rowDoc = "one no-tool final-policy Factory response"
rowHelp = "Temporary final-policy live verification workflow."
```

The temporary routing profile was:

```yaml
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: factory-profile
    chain:
      - router: factory-droid
        model: gpt-5.6-sol
        thinking: low
        max-output: unconstrained
```

The compile and run commands were the commands above. The shell printed the exact command shape and process exit before post-processing:

```text
marker=AGENT_CAT_DROID_FINAL_SMOKE_1788307913689375000
command=XDG_CONFIG_HOME=<mktemp>/xdg <mktemp>/droid-smoke run one --engine acp --adapter droid --timeout 180000
exit_status=0
```

Recorded non-secret outcome:

```text
prompts=1
responses=1
nonempty=true
marker_occurrences=1
header_configured=true
model_ids=['gpt-5.6-sol']
reasoning_efforts=['low']
billFresh=1
billMemo=1
model_turn_outcomes=1
assistant_messages=1
tool_blocks=0
permission_events=false
droid_processes_before=0
droid_processes_after=0
terminated=true
```

The response bytes are intentionally absent from this record.

## Current Luna acceptance

Installed Droid `0.209.1` listed `gpt-5.6-luna` and supported reasoning levels including `low`. The temporary registry source was the source above with these substitutions:

```text
AGENT_CAT_DROID_ROUTED_SMOKE_1788304692513363000
  -> AGENT_CAT_DROID_LUNA_SMOKE_1788318657333830000
regBanner = "one no-tool Luna Factory Droid ACP verification"
rowDoc = "one no-tool Luna Factory response"
rowHelp = "Temporary Luna live verification workflow."
```

The temporary routing profile was:

```yaml
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: factory-profile
    chain:
      - router: factory-droid
        model: gpt-5.6-luna
        thinking: low
        max-output: unconstrained
```

The compile and run commands were the commands above. One preceding local harness invocation stopped before compilation or process spawn because an empty `pgrep` failed under `pipefail`; it made no Droid or Factory call. The corrected harness made exactly one live turn:

```text
marker=AGENT_CAT_DROID_LUNA_SMOKE_1788318657333830000
command=XDG_CONFIG_HOME=<mktemp>/xdg <mktemp>/droid-smoke run one --engine acp --adapter droid --timeout 180000
exit_status=0
```

Recorded non-secret outcome:

```text
prompts=1
responses=1
nonempty=true
marker_occurrences=1
header_configured=true
model_ids=['gpt-5.6-luna']
reasoning_efforts=['low']
billFresh=1
billMemo=1
model_turn_outcomes=1
assistant_messages=1
tool_blocks=0
permission_events=false
droid_processes_before=0
droid_processes_after=0
terminated=true
```

The response bytes are intentionally absent from this record.
