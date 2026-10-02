#!/usr/bin/env bash
# The WM-040 manager conformance gate. Each subcommand runs one step, so that
# each step runs under its own timeout. bisim/manager/README.md describes the
# steps, the controls and the claim of each lane.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
: "${TMPDIR:?Use a short private temporary root}"
umask 077
export PYTHONDONTWRITEBYTECODE=1

steps=(closure lean build cases admission vertical history refusals corpus)
controls=(control-oracle control-model control-case)
state=${MANAGER_GATE_STATE:-$TMPDIR/agent-cat-manager-gate}
oracle=$root/bisim/.lake/build/bin/manager-oracle
seed=20261002

usage() {
  echo "usage: bash bisim/ci/manager.sh STEP" >&2
  echo "Run the steps in this order: ${steps[*]}" >&2
  echo "The controls follow the steps: ${controls[*]}" >&2
  echo "The steps keep their state in MANAGER_GATE_STATE, default $TMPDIR/agent-cat-manager-gate" >&2
  exit 2
}

cabal_build() {
  : "${CABAL_BUILDDIR:?Use the configured project environment}"
  bash test/cabal.sh build "$@" --with-compiler="$(command -v ghc)" \
    --with-hc-pkg="$(command -v ghc-pkg)" --ghc-options="-Werror -threaded -rtsopts"
}

checker() {
  local binary
  binary=$(bash test/cabal.sh list-bin manager-conformance-check)
  [[ -x $binary ]] || { echo "manager-conformance-check is not built; run the build step" >&2; exit 1; }
  printf '%s\n' "$binary"
}

vertical_root() {
  [[ -s $state/vertical-root ]] || { echo "no vertical root in $state; run the vertical step" >&2; exit 1; }
  local path
  path=$(cat "$state/vertical-root")
  [[ -d $path ]] || { echo "the vertical root $path is absent; run the vertical step" >&2; exit 1; }
  printf '%s\n' "$path"
}

# A fresh counterexample directory for one step.
counterexamples() {
  mkdir -p "$state/counterexamples"
  mktemp -d "$state/counterexamples/$1.XXXXXX"
}

# The worktree status and content digest, which no control may change.
tree_digest() {
  { git status --porcelain=v1 --untracked-files=all; git diff HEAD --binary; } | shasum -a 256
}

require_tree() {
  local after
  after=$(tree_digest)
  if [[ $after != "$1" ]]; then
    echo "CONTROL $2 changed the tree" >&2
    exit 4
  fi
  echo "CONTROL $2 left the tree unchanged"
}

setup_failed() {
  echo "CONTROL $1 setup failed: $2" >&2
  exit 3
}

# Prints the lane lines and the counterexample files, and exits with the worst
# lane status. A control passes only when a lane reports a mismatch.
control_result() {
  local name=$1 status=$2 directory=$3
  echo "CONTROL $name counterexamples kept in $directory:"
  local file count=0
  shopt -s globstar nullglob
  for file in "$directory"/**/*.json; do
    echo "  $file"
    count=$((count + 1))
  done
  echo "CONTROL $name kept $count counterexample files"
  if [[ $status -eq 0 ]]; then
    echo "CONTROL $name was not detected: every lane passed"
  else
    echo "CONTROL $name detected: a lane failed with status $status"
  fi
  exit "$status"
}

step_closure() {
  python3 - <<'PY'
import pathlib, re, sys
roots = {"Agentic": pathlib.Path("model"), "ManagerConformance": pathlib.Path("bisim/manager")}
start = sorted(pathlib.Path("bisim/manager").rglob("*.lean")) + sorted(pathlib.Path("model/Agentic/Manager").glob("*.lean"))
allowed = ("Init", "Lean", "Std", "Mathlib.Data.Finmap")
pattern = re.compile(r"^\s*(?:public\s+)?(?:meta\s+)?import\s+(?:all\s+)?([A-Za-z0-9_.]+)", re.M)
seen, external, bad = set(), set(), []
todo = list(start)
while todo:
    path = todo.pop()
    if path in seen:
        continue
    seen.add(path)
    for module in pattern.findall(path.read_text()):
        top = module.split(".")[0]
        if top == "Agentic" and not module.startswith("Agentic.Manager."):
            bad.append(f"{path} imports {module}")
        elif top in roots:
            source = roots[top].joinpath(*module.split(".")).with_suffix(".lean")
            if source.exists():
                todo.append(source)
            else:
                bad.append(f"{path} imports {module}, which has no source")
        else:
            external.add(module)
            if not any(module == name or module.startswith(name + ".") for name in allowed):
                bad.append(f"{path} imports {module}, which is outside Lean core and Mathlib.Data.Finmap")
for path in sorted(seen):
    print(f"closure {path}")
print("external imports:", " ".join(sorted(external)))
if bad:
    print("FAIL manager import closure", *bad, sep="\n  ")
    sys.exit(1)
print("PASS the manager import closure holds only Agentic.Manager, Lean core and Mathlib.Data.Finmap")
PY
}

step_lean() {
  lake --dir bisim build --wfail ManagerConformance manager-oracle
  [[ -x $oracle ]] || { echo "lake did not produce $oracle" >&2; exit 1; }
  echo "PASS ManagerConformance and manager-oracle"
}

step_build() {
  cabal_build manager-conformance-check manager-vertical-check routing-fixed-point-probe
  echo "PASS manager-conformance-check, manager-vertical-check and routing-fixed-point-probe"
}

step_cases() {
  local check
  check=$(checker)
  "$check" cases --cases bisim/manager/cases --oracle "$oracle" --counterexamples "$(counterexamples cases)"
}

step_admission() {
  local check
  check=$(checker)
  "$check" admission --seed "$seed" --n 500 --oracle "$oracle" --counterexamples "$(counterexamples admission)"
}

step_vertical() {
  python3 - <<'PY'
import os
assert "GHCRTS" not in os.environ
assert not any(name.startswith("AGENT_CAT_") for name in os.environ)
PY
  local binary native work
  binary=$(bash test/cabal.sh list-bin manager-vertical-check)
  native=$(bash test/cabal.sh list-bin routing-fixed-point-probe)
  [[ -x $binary && -x $native ]] || { echo "the vertical binaries are not built; run the build step" >&2; exit 1; }
  mkdir -p "$state"
  rm -f "$state/vertical-root"
  work=$(mktemp -d "$TMPDIR/manager-vertical.XXXXXX")
  mkdir "$work/N8"
  echo "vertical root: $work/N8"
  "$binary" vertical "$work/N8" "$native" "$root" "$(command -v python3)" +RTS -N8 -RTS 2>&1 | tee "$work/N8.log"
  # The lineage section compares restart, resume and fork children of the
  # managed run and of the direct run. A run without those lines is no evidence.
  for line in "PASS WM022 non-network vertical lifecycle" \
      "RestartParent preserves direct answers" "ResumeParent preserves direct answers" \
      "ForkParent .* preserves direct answers"; do
    grep -q -- "$line" "$work/N8.log" || { echo "the vertical log has no line that matches: $line" >&2; exit 1; }
  done
  echo "managed/direct comparisons: $(grep -c '^PASS exact managed/direct native semantics' "$work/N8.log")"
  printf '%s\n' "$work/N8" > "$state/vertical-root"
  echo "PASS direct-versus-managed vertical at N8"
}

step_history() {
  local check history
  check=$(checker)
  history=$(vertical_root)
  "$check" history --root "$history" --oracle "$oracle" --counterexamples "$(counterexamples history)"
}

step_refusals() {
  local check history
  check=$(checker)
  history=$(vertical_root)
  "$check" refusals --root "$history" --oracle "$oracle" --counterexamples "$(counterexamples refusals)"
}

step_corpus() {
  local changed
  changed=$(git status --short bisim/corpus)
  if [[ -n $changed ]]; then
    printf 'FAIL bisim/corpus changed:\n%s\n' "$changed" >&2
    exit 1
  fi
  echo "PASS bisim/corpus is unchanged"
}

# Edits a copied Lean file. Each edit must match exactly once. "drop" removes
# the declaration that a docstring and the named theorem begin, up to the next
# blank line. "replace" replaces one text.
lean_edit() {
  python3 - "$@" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
arguments = sys.argv[2:]
while arguments:
    action = arguments.pop(0)
    if action == "drop":
        name = arguments.pop(0)
        marker = f"\ntheorem {name} "
        if text.count(marker) != 1:
            sys.exit(f"{path}: theorem {name} is not declared exactly once")
        at = text.index(marker)
        begin = text.rfind("\n/--", 0, at)
        end = text.index("\n\n", at)
        text = text[:begin] + text[end:]
        print(f"CONTROL removed theorem {name} from {path.name}")
    elif action == "replace":
        old, new = arguments.pop(0), arguments.pop(0)
        if text.count(old) != 1:
            sys.exit(f"{path}: the text to replace does not occur exactly once: {old!r}")
        text = text.replace(old, new)
        print(f"CONTROL replaced in {path.name}: {old.strip()!r} -> {new.strip()!r}")
    else:
        sys.exit(f"unknown edit {action}")
path.write_text(text)
PY
}

# Copies the bisim package without its build state. The Lake packages are
# cloned, so the copy reuses the prebuilt Mathlib and never fetches.
copy_bisim() {
  local target=$1
  mkdir -p "$target/.lake"
  cp bisim/lakefile.toml bisim/lake-manifest.json bisim/lean-toolchain "$target/"
  cp -R bisim/manager "$target/manager"
  /bin/cp -Rc bisim/.lake/packages "$target/.lake/packages"
}

control_oracle() {
  local before ctl copy status=0 directory history
  before=$(tree_digest)
  history=$(vertical_root)
  ctl=$(mktemp -d "$TMPDIR/manager-control-oracle.XXXXXX")
  copy=$ctl/bisim
  echo "CONTROL control-oracle copy: $copy"
  copy_bisim "$copy"
  python3 - "$copy" "$root/model" <<'PY' || setup_failed control-oracle "the copied Lake configuration does not name ../model once"
import json, pathlib, sys
copy, model = pathlib.Path(sys.argv[1]), sys.argv[2]
lakefile = copy / "lakefile.toml"
text = lakefile.read_text()
assert text.count('path = "../model"') == 1
lakefile.write_text(text.replace('path = "../model"', f"path = {json.dumps(model, ensure_ascii=False)}"))
manifest = copy / "lake-manifest.json"
data = json.loads(manifest.read_text())
entries = [p for p in data["packages"] if p.get("type") == "path" and p["name"] == "agentic"]
assert len(entries) == 1 and entries[0]["dir"] == "../model"
entries[0]["dir"] = model
manifest.write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n")
print(f"CONTROL the copy requires the model at {model}")
PY
  # The broken decider accepts an answer only when the key is not the head.
  lean_edit "$copy/manager/ManagerConformance/Exec.lean" \
    replace "  | some (head :: tail) =>
    if head.key = key ∧ head.command = none ∧" "  | some (head :: tail) =>
    if head.key ≠ key ∧ head.command = none ∧" \
    drop answerExec_eq || setup_failed control-oracle "the edit of Exec.lean"
  # These declarations of the oracle closure use answerExec_eq or the head check.
  lean_edit "$copy/manager/ManagerConformance/Codec.lean" \
    drop Step.exec_eq drop step_eq \
    replace "-- An accepted answer records an answer receipt, and an accepted verification records an artifact.
#guard ((answerExec pending \"command-1\" \"client-1\" \"run-1\" first \"yes\").bind
    (verifyExec · table \"artifact-1\" \"reference-1\" \"output\")).map
    (roundTrips encodeState decodeState) = some true
" "" || setup_failed control-oracle "the edit of Codec.lean"
  timeout 1800 lake --dir "$copy" build manager-oracle || setup_failed control-oracle "the build of the broken manager-oracle"
  [[ -x $copy/.lake/build/bin/manager-oracle ]] || setup_failed control-oracle "the broken manager-oracle is absent"
  directory=$ctl/counterexamples
  local check
  check=$(checker)
  echo "CONTROL control-oracle cases lane with the broken oracle"
  timeout 300 "$check" cases --cases bisim/manager/cases --oracle "$copy/.lake/build/bin/manager-oracle" \
    --counterexamples "$directory/cases" || status=$?
  echo "CONTROL control-oracle history lane with the broken oracle on $history"
  local lane=0
  timeout 300 "$check" history --root "$history" --oracle "$copy/.lake/build/bin/manager-oracle" \
    --counterexamples "$directory/history" || lane=$?
  (( lane > status )) && status=$lane
  # The copy keeps its sources and counterexamples, not the cloned packages.
  rm -rf "$copy/.lake/packages"
  require_tree "$before" control-oracle
  control_result control-oracle "$status" "$directory"
}

control_model() {
  local before ctl status=0 log
  before=$(tree_digest)
  ctl=$(mktemp -d "$TMPDIR/manager-control-model.XXXXXX")
  echo "CONTROL control-model copy: $ctl"
  # The clone holds the model sources and the model .lake state.
  /bin/cp -Rc model "$ctl/model"
  copy_bisim "$ctl/bisim"
  # The broken model answers any unreserved head, whatever its key. The three
  # theorems that state the head condition no longer hold, so they are removed.
  lean_edit "$ctl/model/Agentic/Manager/Coordination.lean" \
    replace "  | some (head :: tail) =>
    if head.key = key ∧ head.command = none ∧ s.commands.lookup command = none ∧" "  | some (head :: tail) =>
    if head.command = none ∧ s.commands.lookup command = none ∧" \
    drop Coordination.answer_fifo drop Coordination.answer_nonhead drop Coordination.answer_reserved \
    || setup_failed control-model "the edit of Coordination.lean"
  echo "CONTROL control-model builds Agentic.Manager of the copied model"
  timeout 1800 lake --dir "$ctl/bisim" build --wfail +Agentic.Manager.History +Agentic.Manager.Coordination \
    +Agentic.Manager.Meaning || setup_failed control-model "Agentic.Manager of the copied model does not build"
  echo "CONTROL control-model: Agentic.Manager of the copied model builds"
  log=$ctl/manager-conformance.log
  echo "CONTROL control-model builds ManagerConformance against the copied model"
  timeout 1800 lake --dir "$ctl/bisim" build --wfail ManagerConformance > "$log" 2>&1 || status=$?
  cat "$log"
  rm -rf "$ctl/bisim/.lake/packages"
  require_tree "$before" control-model
  if [[ $status -eq 0 ]]; then
    echo "CONTROL control-model was not detected: ManagerConformance builds against the broken model"
    exit 0
  fi
  # Name the declaration at each error position of Exec.lean.
  python3 - "$log" "$ctl/bisim/manager/ManagerConformance/Exec.lean" <<'PY'
import re, sys
log, source = open(sys.argv[1]).read(), open(sys.argv[2]).read().splitlines()
lines = sorted({int(n) for n in re.findall(r"^error: \S*ManagerConformance/Exec\.lean:(\d+):\d+:", log, re.M)})
for line in lines:
    names = [m.group(1) for text in source[:line] if (m := re.match(r"(?:theorem|def) (\S+)", text))]
    print(f"CONTROL control-model: the build fails at Exec.lean:{line}, in {names[-1] if names else 'no declaration'}")
if not lines:
    print("CONTROL control-model: the build fails without an error in Exec.lean")
PY
  echo "CONTROL control-model detected: the build of ManagerConformance failed with status $status"
  exit "$status"
}

control_case() {
  local before ctl status=0
  before=$(tree_digest)
  ctl=$(mktemp -d "$TMPDIR/manager-control-case.XXXXXX")
  cp -R bisim/manager/cases "$ctl/cases"
  python3 - "$ctl/cases/answer-head.expected.json" <<'PY' || setup_failed control-case "the edit of answer-head.expected.json"
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
assert text.startswith('{"accepted":true,"state":') and text.count('"authority":"authority-1"') == 1
path.write_text(text.replace('"authority":"authority-1"', '"authority":"authority-2"'))
print("CONTROL control-case: the expected state of answer-head has the authority authority-2")
PY
  local check
  check=$(checker)
  timeout 300 "$check" cases --cases "$ctl/cases" --oracle "$oracle" --counterexamples "$ctl/counterexamples" || status=$?
  require_tree "$before" control-case
  control_result control-case "$status" "$ctl/counterexamples"
}

[[ $# -eq 1 ]] || usage
case $1 in
  closure) step_closure ;;
  lean) step_lean ;;
  build) step_build ;;
  cases) step_cases ;;
  admission) step_admission ;;
  vertical) step_vertical ;;
  history) step_history ;;
  refusals) step_refusals ;;
  corpus) step_corpus ;;
  control-oracle) control_oracle ;;
  control-model) control_model ;;
  control-case) control_case ;;
  *) usage ;;
esac
