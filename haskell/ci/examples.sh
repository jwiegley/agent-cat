#!/usr/bin/env bash
#
# The example-numbers gate — every registered example program, against a table
# pinned in this file.
#
#     ./ci/examples.sh
#
# `Example.Harden.examples` is seven programs: the two walked ones the frozen
# corpus holds, and "Example.Isaac"'s five, which are an *experiment* about what
# the language can express and are deliberately **not** frozen (isaac-workflows
# §6, D10: "keep them out of the frozen corpus, and pin their numbers anyway").
# That decision leaves the five with numbers published in three places — each
# program's haddock, isaac-workflows §3's table, and this script — and nothing
# but this script to stop the first two going stale. tier0 and tier1 cannot: the
# five are in no corpus entry and in no tier1 case.
#
# So for every registered program, this gate runs
#
#   agentic-run plan <name> [input]        level, size, askNodes, cost
#   agentic-run cost <name> [input]        costSummary
#   agentic-run run  <name> --scripted [input]   exit 0, billFresh, billMemo
#
# where `[input]` is the input flag a program that takes one needs (D8) —
# `review-lite` is the only such program, and `inputsFor` below is where its
# subject comes from.
#
# and holds each field against the table below. Every pinned line cites where
# the same number is also published; a mismatch here means one of those places
# is now lying, and the fix is to find out which.
#
# The pinned numbers are not this script's invention. `harden` and `hello` are
# the two frozen corpus entries, so their static folds are already pinned twice
# over (tier0 replays them, tier1 rebuilds them from the very values this script
# runs); repeating them here is what makes this gate a statement about *the
# registry* rather than about the five unfrozen programs alone — a sixth Isaac
# program, or a change that moved the flagship, has to come through this table.
#
# The registry itself is read from the binary rather than transcribed: an
# example name the table does not carry, or a table row naming no example, is a
# failure. A new program cannot be registered without being priced.
#
# No Lean, no network, no agent: `--scripted` answers from `Main.hs`'s canned
# table. Runs on every commit, beside ci/tier0.sh, ci/deck.sh and ci/acp.sh.
# Exits 0 only if every field below matched exactly.
set -uo pipefail
# `|| exit` and not `set -e`: this gate counts failures rather than stopping at
# the first one, so nothing else exits for it. Everything below is relative to
# the package root, and a gate that ran somewhere else would report on nothing.
cd "$(dirname "$0")/.." || exit 1

work="$(mktemp -d "${TMPDIR:-/tmp}/agentic-examples.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0

note() { echo "ci/examples: $*"; }
bad() {
  # program, field, expected, actual — in that order, because a gate that says
  # only "the numbers moved" costs an afternoon finding out which one.
  echo "ci/examples: FAIL $1: $2: expected '$3', actual '$4'" >&2
  failures=$((failures + 1))
}

cat_run() { nix develop path:./. -c cabal run -v0 agentic-run -- "$@"; }

# ---------------------------------------------------------------------------
# The pinned table
# ---------------------------------------------------------------------------
#
# One row per registered program:
#
#   pin <name> <level> <size> <askNodes> <minFold> <maxFold> <paths> \
#              <billFresh> <billMemo>
#
# `codes` is not pinned here: it is `null` on six of the seven (they branch),
# and `hello`'s is pinned by the frozen corpus, which is a stronger place for it
# than this file.

names=()
declare -A pinLevel pinSize pinAsks pinMin pinMax pinPaths pinFresh pinMemo

pin() {
  names+=("$1")
  pinLevel[$1]=$2
  pinSize[$1]=$3
  pinAsks[$1]=$4
  pinMin[$1]=$5
  pinMax[$1]=$6
  pinPaths[$1]=$7
  pinFresh[$1]=$8
  pinMemo[$1]=$9
}

#   name              level     size asks  min  max paths fresh memo

# The flagship. Also `test/corpus/example-000-the-flagship-single-file.json`
# (`level branch, size 36, askNodes 19, costSummary {5, 15, 9}`), which tier0
# replays and tier1 rebuilds from `Example.Harden.hardenProgram` itself; the
# haddock on that value; haskell/README.md; and isaac-workflows §3's reference
# line. The 7/7 bill is the corpus's own world, and is reached three further
# ways: ci/deck.sh's `happy`, ci/acp.sh's `happy`, and the Lean demo's
# `expectedApply`.
pin harden            branch      36   19    5   15     9     7    7

# The small one. Also `test/corpus/example-001-hello.json` (`level pipeline,
# size 4, askNodes 3, codes [text, text, receipt], costSummary {3, 3, 1}`), the
# haddock on `Example.Harden.helloProgram`, and ci/acp.sh's `hello` for the
# bill.
pin hello             pipeline     4    3    3    3     1     3    3

# The five Isaac programs. Each number below is published twice more: in the
# program's own haddock in `example/Example/Isaac.hs`, and in
# `doc/research/isaac-workflows.md` §3's table. Nothing else pins them — that is
# what this script is for.

# Isaac.hs:957-960; isaac-workflows §3, `plan-feature` row. The one pipeline of
# the five: one path, so its price is exact and its bill must equal it.
pin plan-feature      pipeline    14   13   13   13     1    13   13

# Isaac.hs:1127-1129; isaac-workflows §3 and Finding 3.2. The two paths are the
# router's two outcomes priced apart; the scripted run takes the `yes` arm, so
# the bill is `maxFold`.
#
# **This row moved in wave 2 (D1 + D8), and here is the arithmetic.** Two
# changes landed on this program together, and only one of them is visible in
# these numbers:
#
#   * D8 — the opening tool leaf that fetched the commit became an input
#     (`taking (input "subject" noInputs)`), and an input is a *define*, which
#     reaches prompts as data and leaves no node behind. That removes one ask
#     node from the prefix every path shares: size 13 → 12, askNodes 10 → 9,
#     minFold 8 → 7, maxFold 9 → 8, and the scripted bill 9/9 → 8/8. `paths`
#     is untouched — the router still decides two — and so is `level`, which
#     the `if` decides.
#   * D1 — the closing act, written out once per arm, became one
#     `review-lite.report` function called from both. That moves **nothing**,
#     and the prediction was made before the change: a call is priced at the
#     callee's own `bodyAsks` with the arguments ignored, and `graft` splices
#     the callee's node at the call site rather than adding one, so `size`,
#     `askNodes` and every path in `costM` are what they were. The printed
#     program is what changed: two `act`s became two `callStmt`s and one `fns`
#     entry.
#
# The subject the scripted run is given is the text the deleted script entry
# used to return (`Example.Isaac.isaacScript`, the `readCommit` row), so the
# rendered prompts — and therefore the memo table and the bill — are the ones
# this row pinned before.
#
# `doc/research/isaac-workflows.md` was updated with this re-pin: §3's
# review-lite row, Finding 3.2 and §5's I1 all carry the numbers below, and
# Finding 3.2 states the duplicated tail in the past tense.
pin review-lite       branch      12    9    7    8     2     8    8

# Isaac.hs:1288-1290; isaac-workflows §3 and Finding 3.3. Two loops, so the
# range is real; the scripted world settles on the first check, which is why 12
# sits well below `maxFold`.
pin ship-feature-lite branch     149   78    4   24    36    12   12

# Isaac.hs:1420-1422; isaac-workflows §3 and Finding 3.4. The `atMost 4` fixer
# loop is G9's bounded refusal made of numbers: 27 is a bound an operator can
# read.
pin grind-tests       branch     144   73    9   27    36    15   15

# Isaac.hs:1590-1592; isaac-workflows §3 and Finding 3.5. The only registered
# program whose two bills differ: 16 ask nodes walked, 15 questions put. The
# gap is the memo table, and it is the same phenomenon ci/deck.sh's `objects`
# scenario observes from outside the process.
pin stack-prs         branch     155   70    4   24    43    16   15

# ---------------------------------------------------------------------------
# The renderings the CLI prints, rebuilt from the table
# ---------------------------------------------------------------------------

# `renderSummary` in run/Main.hs, which `plan`'s `cost` line and `cost`'s
# `costSummary` line share so the two cannot disagree.
summaryOf() {
  local n=$1 word=paths
  [ "${pinPaths[$n]}" = 1 ] && word=path
  echo "minFold ${pinMin[$n]}, maxFold ${pinMax[$n]}, over ${pinPaths[$n]} $word"
}

# The value on a `  <label>   <value>` line, or the empty string if there is no
# such line — which fails the comparison and prints as an absence.
field() {
  sed -n "s/^  *$2  *//p" "$1" | head -1
}

# ---------------------------------------------------------------------------
# The inputs a program takes
# ---------------------------------------------------------------------------
#
# A program may be a program *of its inputs* (D8): `review-lite` takes the
# commit it reviews, where it used to open by asking a tool for one. `run`
# requires every input, so the gate has to supply it — and what it supplies is
# the very text the deleted script entry returned, which is what keeps this
# row's bill comparable to the one it replaced.
#
# It goes through a file rather than through `--input-arg` because the text has
# a newline in it. One trailing newline is stripped on the way in
# (run/Main.hs), so the file's two lines are the two lines the old canned
# answer was.
printf '%s\n' \
  'diff --git a/src/Export.hs b/src/Export.hs' \
  '+  writeFile path body' > "$work/review-lite.subject"

# The flags are carried in an __array__ rather than echoed as a string, because
# the value of `--input-file` is a path under $TMPDIR, and a $TMPDIR with a
# space in it is one this gate must still work under. A string would have to be
# left unquoted at the call sites to split into two words, and then the split
# would fall wherever the spaces happen to be; an array says "two words" and
# means it, whatever is inside either one. Empty stays empty: `"${ins[@]}"` of
# an empty array expands to no words at all, which is what a program that takes
# no input needs.
ins=()
inputsFor() {
  case "$1" in
    review-lite) ins=(--input-file "subject=$work/review-lite.subject") ;;
    *) ins=() ;;
  esac
}

# ---------------------------------------------------------------------------
# The registry, read from the binary
# ---------------------------------------------------------------------------
#
# An unknown example is refused with the full list of names, so the registry is
# available without a second entry point to keep in step. Both directions are
# checked: a program registered and not pinned is a program whose numbers
# nobody is watching, and a row naming no program is a row about something that
# has gone.

nix develop path:./. -c cabal build all > "$work/build" 2>&1 \
  || { echo "ci/examples: the build failed:" >&2; cat "$work/build" >&2; exit 1; }

cat_run plan --no-such-example > "$work/registry" 2>&1
registered=$(sed -e 's/^.*there is //' -e 's/ and /\n/g' "$work/registry")
[ -n "$registered" ] || { echo "ci/examples: could not read the registry: $(cat "$work/registry")" >&2; exit 1; }

for n in $registered; do
  [ -n "${pinLevel[$n]+set}" ] || bad "$n" registry "a pinned row" "registered, and pinned nowhere in ci/examples.sh"
done
for n in "${names[@]}"; do
  echo "$registered" | grep -qx "$n" || bad "$n" registry "a registered example" "pinned here, and registered nowhere"
done

# ---------------------------------------------------------------------------
# Every program, field by field
# ---------------------------------------------------------------------------

for n in "${names[@]}"; do
  want_summary=$(summaryOf "$n")
  inputsFor "$n"

  # plan — the static folds, decided by the elaborated term alone.
  cat_run plan "$n" "${ins[@]}" > "$work/$n.plan" 2>&1
  code=$?
  [ "$code" = 0 ] || bad "$n" "plan exit" 0 "$code"
  [ "$(field "$work/$n.plan" level)" = "${pinLevel[$n]}" ] \
    || bad "$n" level "${pinLevel[$n]}" "$(field "$work/$n.plan" level)"
  [ "$(field "$work/$n.plan" size)" = "${pinSize[$n]}" ] \
    || bad "$n" size "${pinSize[$n]}" "$(field "$work/$n.plan" size)"
  [ "$(field "$work/$n.plan" askNodes)" = "${pinAsks[$n]}" ] \
    || bad "$n" askNodes "${pinAsks[$n]}" "$(field "$work/$n.plan" askNodes)"
  [ "$(field "$work/$n.plan" cost)" = "$want_summary" ] \
    || bad "$n" "plan cost" "$want_summary" "$(field "$work/$n.plan" cost)"

  # cost — the same summary, from the other verb.
  cat_run cost "$n" "${ins[@]}" > "$work/$n.cost" 2>&1
  code=$?
  [ "$code" = 0 ] || bad "$n" "cost exit" 0 "$code"
  [ "$(field "$work/$n.cost" costSummary)" = "$want_summary" ] \
    || bad "$n" costSummary "$want_summary" "$(field "$work/$n.cost" costSummary)"

  # run --scripted — the bill actually paid, against the table's pair. stdin is
  # /dev/null: a scripted run asks nobody, and this is what makes that a fact
  # rather than a hope.
  cat_run run "$n" --scripted "${ins[@]}" < /dev/null > "$work/$n.run" 2>&1
  code=$?
  [ "$code" = 0 ] || bad "$n" "run --scripted exit" 0 "$code"
  fresh=$(sed -n 's/^ *billFresh  *\([0-9][0-9]*\).*/\1/p' "$work/$n.run" | head -1)
  memo=$(sed -n 's/^ *billMemo  *\([0-9][0-9]*\).*/\1/p' "$work/$n.run" | head -1)
  [ "$fresh" = "${pinFresh[$n]}" ] || bad "$n" billFresh "${pinFresh[$n]}" "$fresh"
  [ "$memo" = "${pinMemo[$n]}" ] || bad "$n" billMemo "${pinMemo[$n]}" "$memo"

  note "$n: ${pinLevel[$n]}, size ${pinSize[$n]}, askNodes ${pinAsks[$n]}, $want_summary; scripted ${pinFresh[$n]}/${pinMemo[$n]}, exit 0"
done

# ---------------------------------------------------------------------------
# The folds do not depend on the input
# ---------------------------------------------------------------------------
#
# D8's whole claim, as a check rather than as a sentence: an input reaches the
# term only as literal chunks inside prompts, and no static fold reads a
# prompt, so `level`, `size`, `askNodes`, `codes` and `costSummary` are the
# same for every input — which is what lets `plan` and `cost` answer for a
# program whose subject is not in hand. Two runs at two different subjects,
# and the five fold lines compared.
#
# It also pins the other half: the printed programs *do* differ, because the
# subject splices into prompts. A pair that agreed on both would mean the
# input was reaching nothing.

cat_run plan review-lite --raw --input-arg subject=AAAA > "$work/indep.a" 2>&1
cat_run plan review-lite --raw --input-arg subject=BBBBBBB > "$work/indep.b" 2>&1
foldsOf() { grep -E '^  (level|size|askNodes|codes|cost) ' "$1"; }

if [ "$(foldsOf "$work/indep.a")" = "$(foldsOf "$work/indep.b")" ]; then
  note "review-lite: the folds are the same at two different inputs"
else
  bad review-lite "folds under two inputs" "the same five lines" "they moved"
fi

if diff -q "$work/indep.a" "$work/indep.b" > /dev/null; then
  bad review-lite "the printed program under two inputs" "different prompts" "identical"
else
  note "review-lite: the printed program differs at two different inputs"
fi

# ---------------------------------------------------------------------------

if [ "$failures" = 0 ]; then
  echo "ci/examples: ${#names[@]} programs pinned, 0 failed"
else
  echo "ci/examples: $failures field(s) moved" >&2
fi
exit $((failures > 0))
