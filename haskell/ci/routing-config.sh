#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"

cabal run routing-config-probe -- +RTS -N8 -RTS
cabal build agentic-run routing-fixed-point-probe >/dev/null
bin=$(cabal list-bin agentic-run)
fixed_bin=$(cabal list-bin routing-fixed-point-probe)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
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
python3 - "$root/test/stub_adapter.py" "$tmp/primary.py" <<'PY'
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
exec python3 "$root/test/stub_adapter.py" 2>>"$tmp/fallback.log"
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
by_axis = {item["axis"]: item for item in policy["realizations"]}
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
exec python3 "$root/test/stub_adapter.py" --refuse-set-config 2>>"$tmp/fallback.log"
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
deck_stub="$root/haskell/test/stub-deck.sh"
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

echo "routing config: all checks passed"
