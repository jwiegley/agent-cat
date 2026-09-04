#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"

cabal run routing-config-probe -- +RTS -N8 -RTS
cabal run routing-v2-probe -- +RTS -N8 -RTS
cabal run routing-discovery-probe -- +RTS -N8 -RTS
cabal build agentic-run routing-fixed-point-probe >/dev/null
bin=$(cabal list-bin agentic-run)
fixed_bin=$(cabal list-bin routing-fixed-point-probe)
tmp=$(mktemp -d)
server_pid=
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/xdg/agent-cat" "$tmp/work"

# Static/scripted commands do not consult machine-local live routing policy.
printf 'version: 99\n' >"$tmp/xdg/agent-cat/routing.yaml"
XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden --scripted +RTS -N8 -RTS >/dev/null

# A live run validates YAML before trying even a nonexistent adapter.
set +e
invalid=$(XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden \
  --engine acp --adapter definitely-not-an-adapter +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'routing configuration:' <<<"$invalid"
grep -q 'unsupported routing configuration version 99' <<<"$invalid"
! grep -q 'transport:' <<<"$invalid"

# Programs may inspect run.routes while their Haskell value is built. One
# synthetic row converges on its configured pin; the other alternates forever
# and must be refused before the deliberately missing default adapter starts.
cat >"$tmp/xdg/agent-cat/routing.yaml" <<'EOF'
version: 1
routers:
  - name: fixture
    backend: acp:stub
    provider: fixture
profiles:
  - name: deep
    chain:
      - router: fixture
        model: stub-default
        thinking: high
        max-output: 65536
EOF
mkdir -p "$tmp/fixed-work"
XDG_CONFIG_HOME="$tmp/xdg" "$fixed_bin" run convergent \
  --engine acp --adapter stub --scratch "$tmp/fixed-work" \
  +RTS -N8 -RTS >"$tmp/fixed.out" 2>"$tmp/fixed.err"
grep -q 'the run is over' "$tmp/fixed.out"

set +e
cycle=$(XDG_CONFIG_HOME="$tmp/xdg" "$fixed_bin" run cyclic \
  --engine acp --adapter definitely-not-an-adapter +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'routing configuration and run facts form a cycle' <<<"$cycle"
! grep -q 'transport:' <<<"$cycle"

# The first fixture dies on Draft; the second is the ordinary ACP stub. This is
# a transport gap rather than a semantic answer, so the YAML-owned second rung
# must answer the same authored question.
python3 - "$root/engine/acp/test/stub_adapter.py" "$tmp/primary.py" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = "    text = prompt_text(params)\n"
assert needle in source
Path(sys.argv[2]).write_text(
    source.replace(needle, needle + '    if "Draft" in text:\n        raise SystemExit(9)\n', 1)
)
PY
cat >"$tmp/primary" <<EOF
#!/bin/sh
exec python3 "$tmp/primary.py" 2>>"$tmp/primary.log"
EOF
cat >"$tmp/fallback" <<EOF
#!/bin/sh
exec python3 "$root/engine/acp/test/stub_adapter.py" 2>>"$tmp/fallback.log"
EOF
chmod +x "$tmp/primary" "$tmp/fallback"
cat >"$tmp/xdg/agent-cat/routing.yaml" <<EOF
version: 1
routers:
  - name: primary
    backend: acp:$tmp/primary
    provider: fixture
  - name: fallback
    backend: acp:$tmp/fallback
    provider: fixture
profiles:
  - name: deep
    chain:
      - router: primary
        model: deep
        thinking: high
        max-output: 65536
        options:
          mode: plan
          temperature: 0.25
          web-search: true
      - router: fallback
        model: author
        thinking: low
        max-output: 32768
EOF
cp "$tmp/xdg/agent-cat/routing.yaml" "$tmp/valid-routing.yaml"

XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden \
  --engine acp --adapter "$tmp/fallback" --scratch "$tmp/work" \
  +RTS -N8 -RTS >"$tmp/run.out" 2>"$tmp/run.err"
grep -q 'deep = acp:.*primary; fixture/deep; thinking high; max-output 65536; options mode=plan,temperature=0.25,web-search=true' "$tmp/run.out"
grep -q 'deep#2 = acp:.*fallback; fixture/author; thinking low' "$tmp/run.out"
grep -q 'deep may be answered instead by deep#2' "$tmp/run.out"
grep -q 'falling back to deep#2' "$tmp/run.err"
grep -q "set config model='deep'" "$tmp/primary.log"
grep -q "set config effort='high'" "$tmp/primary.log"
grep -q 'set config max-output=65536' "$tmp/primary.log"
grep -q "set config mode='plan'" "$tmp/primary.log"
grep -q 'set config temperature=0.25' "$tmp/primary.log"
grep -q 'set config web-search=True' "$tmp/primary.log"
grep -q "set config model='author'" "$tmp/fallback.log"
grep -q "set config effort='low'" "$tmp/fallback.log"
python3 - "$tmp/fallback.log" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
configured = next(i for i, line in enumerate(lines) if "set config model='author'" in line)
prompted = next(i for i, line in enumerate(lines) if "prompt matched 'Draft'" in line)
assert configured < prompted
PY
grep -q 'billFresh   7' "$tmp/run.out"
grep -q 'billMemo    7' "$tmp/run.out"

# Structured runs persist the declared chain; the event journal identifies the
# rung that actually answered after failover.
rm -rf "$tmp/work" && mkdir "$tmp/work"
AGENT_CAT_RUN_STORE="$tmp/store" XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" machine routing-config-probe harden \
  --engine acp --adapter "$tmp/fallback" --scratch "$tmp/work" \
  +RTS -N8 -RTS >"$tmp/machine.out" 2>"$tmp/machine.err"
python3 - "$tmp/store/manifest.json" "$tmp/xdg/agent-cat/routing.yaml" "$tmp/store/events.ndjson" <<'PY'
import json
import sys
manifest = json.load(open(sys.argv[1]))
policy = manifest["run"]["policy"]
assert policy["routingSources"] == [sys.argv[2]]
assert set(policy) == {"kind", "default", "routes", "scratch", "adapterArgs", "binary", "pollMs", "timeoutMs", "routingSources", "realizations", "verbose"}
by_axis = {item["axis"]: item for item in policy["realizations"]}
assert all(set(item) == {"profile", "axis", "rung", "backend", "router", "provider", "model", "thinking", "maxOutput", "options"} for item in by_axis.values())
assert by_axis["deep"]["model"] == "deep"
assert by_axis["deep"]["thinking"] == "high"
assert by_axis["deep"]["maxOutput"] == 65536
assert by_axis["deep#2"]["model"] == "author"
assert by_axis["deep#2"]["maxOutput"] == 32768
assert by_axis["deep#2"]["rung"] == 2
assert by_axis["deep#2"]["backend"].endswith("/fallback")
events = [json.loads(line) for line in open(sys.argv[3]) if line.strip()]
sources = [item["event"].get("source") for item in events
           if item["event"].get("type") == "occurrence.completed"]
assert "asked:model author@deep#2" in sources, sources
PY

# Factory Droid advertises model and reasoning but no output-limit control. An
# optional-bound profile must therefore configure both advertised settings and run,
# while a declared unsupported setting remains a preflight failure below.
mkdir -p "$tmp/droid-bin"
cat >"$tmp/droid-bin/droid" <<EOF
#!/bin/sh
[ "\$1" = exec ] && [ "\$2" = --output-format ] && [ "\$3" = acp ] || exit 64
shift 3
exec python3 "$root/engine/acp/test/stub_adapter.py" --no-max-output-option "\$@" 2>>"$tmp/droid.log"
EOF
chmod +x "$tmp/droid-bin/droid"
cat >"$tmp/xdg/agent-cat/routing.yaml" <<'EOF'
version: 1
routers:
  - name: factory-droid
    backend: acp:droid
    provider: factory
profiles:
  - name: deep
    chain:
      - router: factory-droid
        model: deep
        thinking: high
        max-output: unconstrained
EOF
rm -rf "$tmp/work" && mkdir "$tmp/work"
rm -f "$tmp/droid.log"
PATH="$tmp/droid-bin:$PATH" XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden \
  --engine acp --adapter "$tmp/fallback" --scratch "$tmp/work" \
  +RTS -N8 -RTS >"$tmp/droid.out" 2>"$tmp/droid.err"
grep -qE '^  deep += acp:droid; factory/deep; thinking high; max-output unconstrained$' "$tmp/droid.out"
grep -q "set config model='deep'" "$tmp/droid.log"
grep -q "set config effort='high'" "$tmp/droid.log"
! grep -q 'set config max-output' "$tmp/droid.log"
grep -q 'billFresh   7' "$tmp/droid.out"
grep -q 'billMemo    7' "$tmp/droid.out"
cp "$tmp/valid-routing.yaml" "$tmp/xdg/agent-cat/routing.yaml"

# Every ACP rung is preflighted before the scheduler starts. A valid primary
# with an unavailable later fallback must therefore spend no token and mutate
# neither adapter session.
rm -f "$tmp/primary.log" "$tmp/fallback.log"
python3 - "$tmp/xdg/agent-cat/routing.yaml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
start = text.index("profiles:\n")
path.write_text(text[:start] + '''profiles:
  - name: deep
    chain:
      - router: primary
        model: deep
        thinking: high
        max-output: 65536
      - router: fallback
        model: author
        thinking: max
        max-output: 32768
''')
PY
set +e
unsupported=$(XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden \
  --engine acp --adapter "$tmp/fallback" --scratch "$tmp/work" \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q "option 'effort' does not offer \"max\"" <<<"$unsupported"
! grep -q 'prompt matched' "$tmp/primary.log"
! grep -q 'prompt matched' "$tmp/fallback.log"
! grep -q 'set config' "$tmp/primary.log"
! grep -q 'set config' "$tmp/fallback.log"

# Catalogue membership is not enough: prove every setter on throwaway sessions.
# The later fallback advertises all values but rejects session/set_config_option.
cp "$tmp/valid-routing.yaml" "$tmp/xdg/agent-cat/routing.yaml"
cat >"$tmp/fallback" <<EOF
#!/bin/sh
exec python3 "$root/engine/acp/test/stub_adapter.py" --refuse-set-config 2>>"$tmp/fallback.log"
EOF
chmod +x "$tmp/fallback"
rm -f "$tmp/primary.log" "$tmp/fallback.log"
set +e
setter_refusal=$(XDG_CONFIG_HOME="$tmp/xdg" "$bin" run harden \
  --engine acp --adapter "$tmp/primary" --scratch "$tmp/work" \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q "answered 'session/set_config_option' with error" <<<"$setter_refusal"
grep -q "set config model='deep'" "$tmp/primary.log"
! grep -q 'prompt matched' "$tmp/primary.log"
! grep -q 'prompt matched' "$tmp/fallback.log"
! grep -q 'set config' "$tmp/fallback.log"

# Deck profiles are verified against the existing session catalogue before the
# first send. Matching metadata runs; mismatch and missing metadata send nothing.
cat >"$tmp/xdg/agent-cat/routing.yaml" <<'EOF'
version: 1
routers:
  - name: deck-fixture
    backend: deck:stub
    provider: anthropic
profiles:
  - name: deep
    chain:
      - router: deck-fixture
        model: fixture-model
        thinking: high
        max-output: 65536
EOF
deck_stub="$root/engine/agent-deck/test/stub-deck.sh"
rm -rf "$tmp/deck-ok" && mkdir "$tmp/deck-ok"
DECK_STUB_STATE="$tmp/deck-ok" DECK_STUB_BUSY=0 XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS >"$tmp/deck.out" 2>"$tmp/deck.err"
[ "$(cat "$tmp/deck-ok/sends")" -eq 7 ]
grep -q 'deep = deck:stub; anthropic/fixture-model; thinking high; max-output 65536' "$tmp/deck.out"

rm -rf "$tmp/deck-mismatch" && mkdir "$tmp/deck-mismatch"
set +e
mismatch=$(DECK_STUB_STATE="$tmp/deck-mismatch" DECK_STUB_MODEL=wrong XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'reports model "wrong", required "fixture-model"' <<<"$mismatch"
[ ! -e "$tmp/deck-mismatch/sends" ]

rm -rf "$tmp/deck-provider" && mkdir "$tmp/deck-provider"
set +e
no_provider=$(DECK_STUB_STATE="$tmp/deck-provider" DECK_STUB_PROVIDER= XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'does not report provider; required "anthropic"' <<<"$no_provider"
[ ! -e "$tmp/deck-provider/sends" ]

rm -rf "$tmp/deck-missing" && mkdir "$tmp/deck-missing"
set +e
missing=$(DECK_STUB_STATE="$tmp/deck-missing" DECK_STUB_OMIT_MAX_OUTPUT=1 XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'does not report max-output; required 65536' <<<"$missing"
[ ! -e "$tmp/deck-missing/sends" ]

# Discovery assigns authority from the path before decoding. A project-only file
# with a complete user-shaped document cannot define a secret or engine and can
# never be promoted to the missing user layer.
mkdir -p "$tmp/project-only/xdg" "$tmp/project-only/work/.agent-cat"
cat >"$tmp/project-only/work/.agent-cat/routing.yaml" <<'EOF'
version: 2
default-persona: hostile
secrets:
  exfil:
    environment: PROJECT_ONLY_SECRET
engines:
  stolen:
    backend: acp:stub
    provider: fixture
    environment:
      DESTINATION_SECRET:
        secret: exfil
models:
  selected:
    engine: stolen
    select: [{exact: fixture-model}]
personas:
  hostile:
    engines: [stolen]
    models: [selected]
    profiles:
      deep:
        chain: [{model: selected, thinking: low, max-output: 1}]
EOF
set +e
project_only=$(cd "$tmp/project-only/work" && \
  XDG_CONFIG_HOME="$tmp/project-only/xdg" \
  "$bin" --routing --offline --json 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'project routing has unknown field' <<<"$project_only"
! grep -q 'PROJECT_ONLY_SECRET' <<<"$project_only"
cat >"$tmp/project-only/work/.agent-cat/routing.yaml" <<'EOF'
version: 2
persona: hostile
EOF
set +e
selector_without_user=$(cd "$tmp/project-only/work" && \
  XDG_CONFIG_HOME="$tmp/project-only/xdg" \
  "$bin" --routing --offline --json 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'requires one user document' <<<"$selector_without_user"

# Version 2 lowers through the same Agent Deck metadata preflight. Catalogue or
# alias resolution never supplies synthetic session metadata.
mkdir -p "$tmp/v2-deck-xdg/agent-cat"
cat >"$tmp/v2-deck-xdg/agent-cat/routing.yaml" <<'EOF'
version: 2
default-persona: fixture
secrets: {}
engines:
  local-deck:
    backend: deck:stub
    provider: anthropic
models:
  selected:
    engine: local-deck
    select:
      - exact: fixture-model
personas:
  fixture:
    engines: [local-deck]
    models: [selected]
    profiles:
      deep:
        chain:
          - model: selected
            thinking: high
            max-output: 65536
EOF
rm -rf "$tmp/v2-deck-ok" && mkdir "$tmp/v2-deck-ok"
DECK_STUB_STATE="$tmp/v2-deck-ok" DECK_STUB_BUSY=0 \
XDG_CONFIG_HOME="$tmp/v2-deck-xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS >"$tmp/v2-deck.out" 2>"$tmp/v2-deck.err"
[ "$(cat "$tmp/v2-deck-ok/sends")" -eq 7 ]
grep -q 'deep = deck:stub; anthropic/fixture-model; thinking high; max-output 65536' "$tmp/v2-deck.out"

rm -rf "$tmp/v2-deck-mismatch" && mkdir "$tmp/v2-deck-mismatch"
set +e
v2_deck_mismatch=$(DECK_STUB_STATE="$tmp/v2-deck-mismatch" \
  DECK_STUB_MODEL=wrong XDG_CONFIG_HOME="$tmp/v2-deck-xdg" \
  "$bin" run harden --session stub --binary "$deck_stub" --poll 0 --timeout 30000 \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'reports model "wrong", required "fixture-model"' <<<"$v2_deck_mismatch"
[ ! -e "$tmp/v2-deck-mismatch/sends" ]

# A live v2 run discovers one exact inventory before ACP preflight. The same
# inventory selecting a model the adapter does not advertise must still fail
# before the first prompt: catalogue evidence never replaces engine evidence.
mkdir -p "$tmp/discovery-xdg/agent-cat" "$tmp/discovery-cache" "$tmp/discovery-work"
touch "$tmp/catalogue-control"
python3 "$root/cli/test/model_catalogue_server.py" \
  "$tmp/catalogue-port" "$tmp/catalogue-count" "$tmp/catalogue-control" &
server_pid=$!
for _ in $(seq 1 200); do
  [ -s "$tmp/catalogue-port" ] && break
  sleep 0.01
done
[ -s "$tmp/catalogue-port" ]
catalogue_port=$(cat "$tmp/catalogue-port")
cat >"$tmp/discovery-xdg/agent-cat/routing.yaml" <<EOF
version: 2
default-persona: fixture
secrets: {}
engines:
  local:
    backend: acp:stub
    provider: fixture
    catalogue:
      dialect: openai
      url: http://127.0.0.1:$catalogue_port/openai
      timeout-ms: 5000
      max-bytes: 4194304
      cache:
        fresh-for: 24h
        stale-if-error: 7d
models:
  selected:
    engine: local
    select:
      - exact: stub-default
personas:
  fixture:
    engines: [local]
    models: [selected]
    profiles:
      deep:
        chain:
          - model: selected
            thinking: high
            max-output: 65536
EOF
mkdir "$tmp/discovery-parent-work"
XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
AGENT_CAT_RUN_STORE="$tmp/discovery-parent" \
  "$bin" machine catalogue-parent harden --engine acp --adapter stub \
  --scratch "$tmp/discovery-parent-work" +RTS -N8 -RTS \
  >"$tmp/discovery-parent.out" 2>"$tmp/discovery-parent.err"
python3 - "$tmp/discovery-parent/manifest.json" <<'PY'
import json
from pathlib import Path
import sys
policy = json.loads(Path(sys.argv[1]).read_text())["run"]["policy"]
realization = {value["axis"]: value for value in policy["realizations"]}["deep"]
assert realization["inventory"]["source"] == "fresh"
PY
sleep 1
XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" run harden --engine acp --adapter stub --scratch "$tmp/discovery-work" \
  +RTS -N8 -RTS >"$tmp/discovery.out" 2>"$tmp/discovery.err"
grep -q 'deep = acp:stub; fixture/stub-default; thinking high; max-output 65536' "$tmp/discovery.out"
grep -q "set config model='stub-default'" "$tmp/discovery.err"
[ "$(cat "$tmp/catalogue-count")" -eq 1 ]
XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" lineage-check restart "$tmp/discovery-parent" harden \
  --engine acp --adapter stub --scratch "$tmp/discovery-parent-work" \
  +RTS -N8 -RTS >"$tmp/discovery-lineage.out" 2>"$tmp/discovery-lineage.err"

XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" --routing --json >"$tmp/routing-inspection.json"
python3 - "$tmp/routing-inspection.json" "$tmp/discovery-xdg/agent-cat/routing.yaml" <<'PY'
import json
from pathlib import Path
import sys
value = json.loads(Path(sys.argv[1]).read_text())
assert value["version"] == 2
assert value["persona"] == {"name": "fixture", "source": "user-default"}
assert value["models"][0]["alias"] == "selected"
assert value["models"][0]["model"] == "stub-default"
assert value["models"][0]["inventory"]["source"] == "fresh-cache"
assert value["models"][0]["inventory"]["cacheAgeSeconds"] >= 1
assert value["profiles"][0]["rungs"][0]["engine"] == "local"
text = Path(sys.argv[1]).read_text()
assert "127.0.0.1" not in text
assert "authorization" not in text.lower()
PY
XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" --routing >"$tmp/routing-inspection.txt"
grep -q 'persona: fixture (user-default)' "$tmp/routing-inspection.txt"
grep -q 'deep: selected -> stub-default on local (fresh-cache)' "$tmp/routing-inspection.txt"
[ "$(cat "$tmp/catalogue-count")" -eq 1 ]

printf 'fail\n' >"$tmp/catalogue-control"
set +e
refresh_failure=$(XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" --routing --refresh-models --json 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'endpoint sha256:' <<<"$refresh_failure"
grep -q 'discovery failed: http-status-503' <<<"$refresh_failure"
! grep -q '127.0.0.1' <<<"$refresh_failure"
[ "$(cat "$tmp/catalogue-count")" -eq 2 ]
XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" --routing --offline --json >"$tmp/routing-offline.json"
python3 - "$tmp/routing-offline.json" <<'PY'
import json
from pathlib import Path
import sys
value = json.loads(Path(sys.argv[1]).read_text())
assert value["models"][0]["inventory"]["source"] == "offline-cache"
PY
[ "$(cat "$tmp/catalogue-count")" -eq 2 ]
empty=''
printf '%s' "$empty" >"$tmp/catalogue-control"

python3 - "$tmp/discovery-xdg/agent-cat/routing.yaml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = "    select:\n      - exact: stub-default\n"
replacement = "    select:\n      - prefix: gpt-sol-\n        order: newest\n"
assert needle in text
path.write_text(text.replace(needle, replacement, 1))
PY
rm -rf "$tmp/discovery-work" && mkdir "$tmp/discovery-work"
set +e
catalogue_mismatch=$(XDG_CONFIG_HOME="$tmp/discovery-xdg" XDG_CACHE_HOME="$tmp/discovery-cache" \
  "$bin" run harden --engine acp --adapter stub --scratch "$tmp/discovery-work" \
  +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 2 ]
grep -q 'does not offer "gpt-sol-a"' <<<"$catalogue_mismatch"
! grep -q 'prompt matched' <<<"$catalogue_mismatch"
[ "$(cat "$tmp/catalogue-count")" -eq 2 ]
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=

# Migration creates an offline v2 user file, preserves the source byte-for-byte,
# and refuses both source and destination overwrite.
cp "$tmp/valid-routing.yaml" "$tmp/migration-source-before.yaml"
"$bin" --migrate-routing "$tmp/valid-routing.yaml" --output "$tmp/migrated-routing.yaml" \
  >"$tmp/migrate.out"
cmp "$tmp/valid-routing.yaml" "$tmp/migration-source-before.yaml"
python3 - "$tmp/migrated-routing.yaml" <<'PY'
from pathlib import Path
import os
import sys
path = Path(sys.argv[1])
assert path.stat().st_mode & 0o077 == 0
text = path.read_text()
assert "version: 2" in text
assert "catalogue:" not in text
assert "environment:" not in text
PY
mkdir -p "$tmp/migrated-xdg/agent-cat"
cp "$tmp/migrated-routing.yaml" "$tmp/migrated-xdg/agent-cat/routing.yaml"
XDG_CONFIG_HOME="$tmp/migrated-xdg" "$bin" --routing --offline --json \
  >"$tmp/migrated-inspection.json"
python3 - "$tmp/migrated-inspection.json" <<'PY'
from pathlib import Path
import json
import sys
value = json.loads(Path(sys.argv[1]).read_text())
assert value["version"] == 2
rungs = value["profiles"][0]["rungs"]
assert [(r["model"], r["thinking"], r["maxOutput"]) for r in rungs] == [
    ("deep", "high", 65536),
    ("author", "low", 32768),
]
assert all(r["inventory"]["source"] == "static-unverified" for r in rungs)
PY

# Every valid v1 router remains migratable when two provenance names share one
# process backend. V2 preserves each provider while sharing the identical empty
# process environment/catalogue definition.
cat >"$tmp/shared-backend-v1.yaml" <<'EOF'
version: 1
routers:
  - name: a
    backend: acp:stub
    provider: alpha
  - name: b
    backend: acp:stub
    provider: beta
profiles:
  - name: first
    chain:
      - router: a
        model: deep
        thinking: high
        max-output: 65536
  - name: second
    chain:
      - router: b
        model: author
        thinking: low
        max-output: 32768
EOF
cp "$tmp/shared-backend-v1.yaml" "$tmp/shared-backend-before.yaml"
"$bin" --migrate-routing "$tmp/shared-backend-v1.yaml" \
  --output "$tmp/shared-backend-v2.yaml" >/dev/null
cmp "$tmp/shared-backend-v1.yaml" "$tmp/shared-backend-before.yaml"
mkdir -p "$tmp/shared-backend-xdg/agent-cat"
cp "$tmp/shared-backend-v2.yaml" "$tmp/shared-backend-xdg/agent-cat/routing.yaml"
XDG_CONFIG_HOME="$tmp/shared-backend-xdg" "$bin" --routing --offline --json \
  >"$tmp/shared-backend-inspection.json"
python3 - "$tmp/shared-backend-inspection.json" <<'PY'
from pathlib import Path
import json
import sys
value = json.loads(Path(sys.argv[1]).read_text())
engines = {engine["name"]: engine for engine in value["engines"]}
assert engines["a"]["backend"] == engines["b"]["backend"] == "acp:stub"
assert engines["a"]["provider"] == "alpha"
assert engines["b"]["provider"] == "beta"
profiles = {profile["name"]: profile["rungs"][0] for profile in value["profiles"]}
assert profiles["first"]["provider"] == "alpha"
assert profiles["second"]["provider"] == "beta"
assert profiles["first"]["model"] == "deep"
assert profiles["second"]["model"] == "author"
PY

# The empty-but-valid v1 policy also has an equivalent v2 representation.
printf 'version: 1\n' >"$tmp/empty-v1.yaml"
"$bin" --migrate-routing "$tmp/empty-v1.yaml" \
  --output "$tmp/empty-v2.yaml" >/dev/null
mkdir -p "$tmp/empty-xdg/agent-cat"
cp "$tmp/empty-v2.yaml" "$tmp/empty-xdg/agent-cat/routing.yaml"
XDG_CONFIG_HOME="$tmp/empty-xdg" "$bin" --routing --offline --json \
  >"$tmp/empty-inspection.json"
python3 - "$tmp/empty-inspection.json" <<'PY'
from pathlib import Path
import json
import sys
value = json.loads(Path(sys.argv[1]).read_text())
assert value["version"] == 2
assert value["persona"] == {"name": "default", "source": "user-default"}
assert value["engines"] == []
assert value["models"] == []
assert value["profiles"] == []
PY
before_output=$(cat "$tmp/migrated-routing.yaml")
set +e
overwrite=$("$bin" --migrate-routing "$tmp/valid-routing.yaml" \
  --output "$tmp/migrated-routing.yaml" 2>&1)
overwrite_status=$?
same_source=$("$bin" --migrate-routing "$tmp/valid-routing.yaml" \
  --output "$tmp/valid-routing.yaml" 2>&1)
same_status=$?
set -e
[ "$overwrite_status" -eq 1 ]
[ "$same_status" -eq 1 ]
grep -q 'refuses to overwrite existing' <<<"$overwrite"
grep -q 'refuses to overwrite its source' <<<"$same_source"
[ "$before_output" = "$(cat "$tmp/migrated-routing.yaml")" ]
cmp "$tmp/valid-routing.yaml" "$tmp/migration-source-before.yaml"

# Persona precedence is explicit and model-alias overrides stay inside the
# selected persona; all of these exact aliases remain offline.
mkdir -p "$tmp/persona-xdg/agent-cat" "$tmp/persona-project/.agent-cat" \
  "$tmp/persona-default" "$tmp/persona-work"
persona_adapter="$root/engine/acp/test/stub_adapter.py"
cat >"$tmp/persona-xdg/agent-cat/routing.yaml" <<EOF
version: 2
default-persona: personal
secrets: {}
engines:
  local:
    backend: acp:$persona_adapter
    provider: fixture
models:
  deep-model:
    engine: local
    select:
      - exact: deep
  author-model:
    engine: local
    select:
      - exact: author
personas:
  personal:
    engines: [local]
    models: [deep-model, author-model]
    profiles:
      deep:
        chain:
          - model: deep-model
            thinking: high
            max-output: 65536
  work:
    engines: [local]
    models: [author-model]
    profiles:
      deep:
        chain:
          - model: author-model
            thinking: low
            max-output: 32768
EOF
cat >"$tmp/persona-project/.agent-cat/routing.yaml" <<'EOF'
version: 2
persona: work
profiles:
  deep:
    chain:
      - model: author-model
        thinking: minimal
        max-output: 16384
EOF
(cd "$tmp/persona-project" && XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" --routing --offline --json) >"$tmp/persona-project.json"
AGENT_CAT_PERSONA=personal XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" --routing --offline --json >"$tmp/persona-environment.json"
(cd "$tmp/persona-project" && AGENT_CAT_PERSONA=personal \
  XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" --routing --persona work --offline --json) >"$tmp/persona-command.json"
(cd "$tmp/persona-default" && XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" --routing --offline --json) >"$tmp/persona-default.json"
python3 - "$tmp/persona-project.json" "$tmp/persona-environment.json" \
  "$tmp/persona-command.json" "$tmp/persona-default.json" <<'PY'
from pathlib import Path
import json
import sys
project, environment, command, default = [json.loads(Path(path).read_text()) for path in sys.argv[1:]]
assert project["persona"] == {"name": "work", "source": "project"}
assert project["profiles"][0]["rungs"][0]["maxOutput"] == 16384
assert environment["persona"] == {"name": "personal", "source": "environment"}
assert command["persona"] == {"name": "work", "source": "command-line"}
assert default["persona"] == {"name": "personal", "source": "user-default"}
PY
(cd "$tmp/persona-project" && XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" run harden --engine acp --adapter "$persona_adapter" --scratch "$tmp/persona-work" \
  --persona personal --realize deep=author-model --offline +RTS -N8 -RTS) \
  >"$tmp/persona-run.out" 2>"$tmp/persona-run.err"
grep -q 'fixture/author; thinking high; max-output 65536' "$tmp/persona-run.out"
grep -q "set config model='author'" "$tmp/persona-run.err"

set +e
managed_route=$(XDG_CONFIG_HOME="$tmp/persona-xdg" \
  "$bin" run harden --engine acp --adapter stub --route deep=acp:stub \
  --offline 2>&1)
managed_status=$?
v1_option=$(XDG_CONFIG_HOME="$tmp/xdg" \
  "$bin" run harden --engine acp --adapter definitely-not-an-adapter \
  --persona personal 2>&1)
v1_status=$?
scripted_persona=$("$bin" run harden --scripted --persona personal 2>&1)
scripted_status=$?
set -e
[ "$managed_status" -eq 1 ]
[ "$v1_status" -eq 1 ]
[ "$scripted_status" -eq 1 ]
grep -q 'raw --route cannot replace version-2 managed axis' <<<"$managed_route"
grep -q -- '--persona, --realize, --offline, and --refresh-models require version-2 routing' <<<"$v1_option"
! grep -q 'transport:' <<<"$v1_option"
grep -q -- "--persona is not --scripted's to take" <<<"$scripted_persona"

# V2 resolves only the selected engine's environment after routing converges,
# before creating a machine store or starting even the default adapter.
mkdir -p "$tmp/v2-xdg/agent-cat" "$tmp/v2-work"
cat >"$tmp/v2-adapter" <<EOF
#!/bin/sh
printf 'dest=%s source=%s unselected=%s keep=%s\n' \
  "\${ROUTING_DEST:+present}" "\${ROUTING_SOURCE:+present}" \
  "\${UNSELECTED_DEST:+present}" "\${KEEP_ME:-}" >"$tmp/v2-child.log"
exec python3 "$root/engine/acp/test/stub_adapter.py"
EOF
chmod +x "$tmp/v2-adapter"
cat >"$tmp/v2-xdg/agent-cat/routing.yaml" <<EOF
version: 2
default-persona: personal
secrets:
  personal-key:
    env: ROUTING_SOURCE
  other-key:
    env: UNSELECTED_SOURCE
engines:
  selected:
    backend: acp:$tmp/v2-adapter
    provider: fixture
    environment:
      ROUTING_DEST:
        secret: personal-key
      KEEP_ME:
        value: kept
  unselected:
    backend: acp:never-started
    provider: fixture
    environment:
      UNSELECTED_DEST:
        secret: other-key
models:
  selected-model:
    engine: selected
    select:
      - exact: stub-default
personas:
  personal:
    engines: [selected]
    models: [selected-model]
    profiles:
      deep:
        chain:
          - model: selected-model
            thinking: high
            max-output: 65536
EOF

set +e
v2_missing=$(AGENT_CAT_RUN_STORE="$tmp/v2-store-missing" \
  XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" machine v2-secret-missing harden --engine acp --adapter "$tmp/v2-adapter" \
  --scratch "$tmp/v2-work" +RTS -N8 -RTS 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q "requires secret 'personal-key' from environment variable ROUTING_SOURCE, which is unset" <<<"$v2_missing"
[ ! -e "$tmp/v2-store-missing" ]
[ ! -e "$tmp/v2-child.log" ]

set +e
v2_argv=$(ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
  AGENT_CAT_RUN_STORE="$tmp/v2-store-argv" XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" machine v2-secret-argv harden --engine acp --adapter "$tmp/v2-adapter" \
  --adapter-arg --api-key 2>&1)
status=$?
set -e
[ "$status" -eq 1 ]
grep -q 'credential-bearing adapter argv is forbidden for version-2 routing' <<<"$v2_argv"
! grep -q 'routing-secret-sentinel-7f3d' <<<"$v2_argv"
[ ! -e "$tmp/v2-store-argv" ]
[ ! -e "$tmp/v2-child.log" ]

ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
AGENT_CAT_RUN_STORE="$tmp/v2-store" XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" machine v2-secret-success harden --engine acp --adapter "$tmp/v2-adapter" \
  --scratch "$tmp/v2-work" +RTS -N8 -RTS >"$tmp/v2.out" 2>"$tmp/v2.err"
[ "$(cat "$tmp/v2-child.log")" = 'dest=present source= unselected= keep=kept' ]
! grep -R -F 'routing-secret-sentinel-7f3d' \
  "$tmp/v2-store" "$tmp/v2.out" "$tmp/v2.err" "$tmp/v2-child.log"
! grep -R -F 'unselected-secret-sentinel-2a6b' \
  "$tmp/v2-store" "$tmp/v2.out" "$tmp/v2.err" "$tmp/v2-child.log"

python3 - "$tmp/v2-store/manifest.json" <<'PY'
from pathlib import Path
import hashlib
import json
import re
import sys
policy = json.loads(Path(sys.argv[1]).read_text())["run"]["policy"]
assert policy["routingVersion"] == 2
assert policy["persona"] == "personal"
assert policy["personaSource"] == "user-default"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", policy["policyDigest"])
unsigned = dict(policy)
digest = unsigned.pop("policyDigest")
canonical = json.dumps(unsigned, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
assert digest == "sha256:" + hashlib.sha256(canonical).hexdigest()
realization = {value["axis"]: value for value in policy["realizations"]}["deep"]
assert realization["engine"] == "selected"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", realization["engineFingerprint"])
assert realization["modelAlias"] == "selected-model"
assert realization["model"] == "stub-default"
assert realization["selector"] == {"kind": "exact", "value": "stub-default"}
assert realization["inventory"]["source"] == "static-unverified"
PY
ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" --routing --offline --json >"$tmp/v2-inspection.json"
python3 - "$tmp/v2-inspection.json" <<'PY'
from pathlib import Path
import json
import sys
text = Path(sys.argv[1]).read_text()
value = json.loads(text)
assert value["engines"][0]["credentialReady"] is True
assert value["models"][0]["model"] == "stub-default"
for forbidden in ["routing-secret-sentinel-7f3d", "unselected-secret-sentinel-2a6b",
                  "personal-key", "ROUTING_SOURCE", "ROUTING_DEST"]:
    assert forbidden not in text
PY
ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
AGENT_CAT_RUN_STORE="$tmp/v2-store-second" XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" machine v2-secret-second harden --engine acp --adapter "$tmp/v2-adapter" \
  --scratch "$tmp/v2-work" +RTS -N8 -RTS >"$tmp/v2-second.out" 2>"$tmp/v2-second.err"
python3 - "$tmp/v2-store/manifest.json" "$tmp/v2-store-second/manifest.json" <<'PY'
from pathlib import Path
import json
import sys
first, second = [json.loads(Path(path).read_text())["run"]["policy"] for path in sys.argv[1:]]
assert first == second
assert first["policyDigest"] == second["policyDigest"]
PY
ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" lineage-check restart "$tmp/v2-store" harden \
  --engine acp --adapter "$tmp/v2-adapter" --scratch "$tmp/v2-work" \
  +RTS -N8 -RTS >/dev/null 2>"$tmp/v2-lineage.err"
cp "$tmp/v2-xdg/agent-cat/routing.yaml" "$tmp/v2-routing-before-environment.yaml"
python3 - "$tmp/v2-xdg/agent-cat/routing.yaml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert "        value: kept" in text
path.write_text(text.replace("        value: kept", "        value: changed", 1))
PY
set +e
changed_environment=$(ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
  UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
  XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" lineage-check restart "$tmp/v2-store" harden \
  --engine acp --adapter "$tmp/v2-adapter" --scratch "$tmp/v2-work" \
  +RTS -N8 -RTS 2>&1)
environment_status=$?
set -e
[ "$environment_status" -eq 3 ]
grep -q 'restart launch does not match the parent fingerprint/policy' <<<"$changed_environment"
! grep -q 'routing-secret-sentinel-7f3d' <<<"$changed_environment"
cp "$tmp/v2-routing-before-environment.yaml" "$tmp/v2-xdg/agent-cat/routing.yaml"
set +e
changed_source=$(ROUTING_SOURCE='routing-secret-sentinel-7f3d' \
  UNSELECTED_SOURCE='unselected-secret-sentinel-2a6b' \
  XDG_CONFIG_HOME="$tmp/v2-xdg" \
  "$bin" lineage-check restart "$tmp/v2-store" harden \
  --engine acp --adapter "$tmp/v2-adapter" --scratch "$tmp/v2-work" \
  --persona personal +RTS -N8 -RTS 2>&1)
changed_status=$?
set -e
[ "$changed_status" -eq 3 ]
grep -q 'restart launch does not match the parent fingerprint/policy' <<<"$changed_source"
! grep -q 'routing-secret-sentinel-7f3d' <<<"$changed_source"

echo "routing config: all checks passed"
