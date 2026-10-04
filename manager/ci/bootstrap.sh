#!/usr/bin/env bash
# The bootstrap of a manager from nothing, as manager/OPERATIONS.md states it:
# a stub run outside the checkout, --manager init, the listening line of
# serve, status through the serve configuration, a second client from
# --manager add-client, both clients against /v1/capabilities, shutdown, and
# the refusal lines of an unknown profile, a stopped manager and a certificate
# file that others can read. It uses an isolated HOME below TMPDIR, whose
# short path leaves room for the administration socket.
set -euo pipefail
source=$(cd "$(dirname "$0")/../.." && pwd -P)
cd "$source"
: "${CABAL_BUILDDIR:?Run through the configured project environment}"
umask 077
unset GHCRTS
bash test/cabal.sh build exe:agentic-run --with-compiler="$(command -v ghc)" --with-hc-pkg="$(command -v ghc-pkg)" \
  --ghc-options="-Werror -threaded -rtsopts"
runner=$(bash test/cabal.sh list-bin exe:agentic-run)
work=$(mktemp -d "${TMPDIR:-/tmp}/manager-bootstrap.XXXXXX")
work=$(cd "$work" && pwd -P)
mkdir "$work/home" "$work/tmp" "$work/cwd" "$work/clients"
export HOME="$work/home" TMPDIR="$work/tmp"
for name in ${!AGENT_CAT_@}; do unset "$name"; done
root="$work/root"
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
admin() { printf '%s' "$2" | "$root/bin/agentic-run" --manager admin --config "$1"; }
fail() { echo "FAIL bootstrap: $*" >&2; exit 1; }
mode() { python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1"; }

(cd "$work/cwd" && "$runner" run hello --engine acp --adapter stub > "$work/hello.log" 2>&1) \
  || fail "the stub hello run outside the checkout failed; see $work/hello.log"
echo "PASS stub hello run from $work/cwd"

"$runner" --manager init --root "$root" --port "$port" > "$work/init.log"
for file in serve.json offline.json tls/certificate.pem tls/key.pem client/profile.json client/profile.credential; do
  [[ $(mode "$root/$file") == 600 ]] || fail "$file is not mode 0600"
done
for directory in manager admin workspace tls bin client; do
  [[ $(mode "$root/$directory") == 700 ]] || fail "$directory is not mode 0700"
done
[[ $(readlink "$root/bin/agentic-run") == "$runner" ]] || fail "bin/agentic-run does not link to the runner"
grep -q "\"port\": $port," "$root/serve.json" && grep -q "\"127.0.0.1:$port\"" "$root/serve.json" \
  || fail "serve.json does not hold the port"
echo "PASS init layout, modes, link and port"

"$root/bin/agentic-run" --manager serve --config "$root/serve.json" > "$work/serve.out" 2> "$work/faults.log" &
serve=$!
for _ in $(seq 1 100); do [[ -s $work/serve.out ]] && break; sleep 0.1; done
[[ $(cat "$work/serve.out") == "manager listening on https://127.0.0.1:$port/v1" ]] || fail "serve did not print its URL"
admin "$root/serve.json" '{"version": 1, "operation": "status"}' | grep -q '"ready":true,.*"state":"serving"' \
  || fail "status through serve.json is not serving and ready"
echo "PASS serve line and live status"

"$root/bin/agentic-run" --manager add-client --config "$root/serve.json" --profile-file "$work/clients/second.json" \
  --profile person > /dev/null
for profile in "$root/client/profile.json" "$work/clients/second.json"; do
  credential=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["credentialFile"])' "$profile")
  status=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$root/tls/certificate.pem" \
    -H "Authorization: Bearer $(cat "$credential")" "https://127.0.0.1:$port/v1/capabilities")
  [[ $status == 200 ]] || fail "$profile answered $status"
done
echo "PASS init and add-client profiles answer 200"

unknown=$("$root/bin/agentic-run" --manager add-client --config "$root/serve.json" \
  --profile-file "$work/clients/third.json" --profile nosuch 2>&1) && fail "an unknown profile was accepted"
[[ $unknown == *"no configured profile has the id nosuch"* ]] || fail "the unknown profile is not named: $unknown"
admin "$root/serve.json" '{"version": 1, "operation": "shutdown"}' > /dev/null
wait "$serve" || fail "serve exited with status $?"
stopped=$(admin "$root/serve.json" '{"version": 1, "operation": "status"}' 2>&1) && fail "status answered with no manager"
[[ $stopped == *"no manager serves on this administrationRoot"* ]] || fail "no line names the stopped manager: $stopped"
chmod 644 "$root/tls/certificate.pem"
refused=$("$root/bin/agentic-run" --manager serve --config "$root/serve.json" 2>&1) && fail "serve accepted a readable certificate"
[[ $refused == *"https.certificateFile $root/tls/certificate.pem is refused"* ]] || fail "the certificate is not named: $refused"
echo "PASS refusal lines name the unknown profile, the stopped manager and the certificate file"
echo "Private bootstrap evidence: $work"
