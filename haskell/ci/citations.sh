#!/usr/bin/env bash
#
# The citation gate — every `<File>.lean:<N>` written in `haskell/` resolves.
#
# The Haskell package claims to be a port rather than a rewrite, and the
# mechanism of that claim is a citation: a docstring naming the Lean file and
# line that states the same thing. A citation that no longer resolves is worse
# than no citation at all — it reads as evidence and is not, and the reader who
# checks it is the one who is misled. That is not hypothetical. The retirement
# commit deleted `Agentic/Core/Acp.lean`, `Agentic/Core/Rpc.lean` and
# `test/AcpSmoke.lean` outright and cut 584 lines from `Agentic/Core/Exec.lean`
# and 132 from `Agentic/Core/Explain.lean`, and 58 of the 254 citations in
# `haskell/` were left naming a file that no longer existed or a line past the
# end of one — while a citation to line 925 of `Exec.lean`, intended for a
# permission policy, still resolved to an unrelated retry loop.
#
#     ./ci/citations.sh
#
# What it checks, for every `X.lean:N` in a Haskell source, comment or
# docstring under `haskell/`:
#
#   1. the file exists somewhere under the repository root, and
#   2. `N` is within that file's line count.
#
# It checks the *continuation* form too — a bare `@:N@`, which the tree uses
# for a second line of the file just cited (`@Exec.lean:523@ … and @:530@`).
# A continuation resolves against the nearest `X.lean` named before it in the
# same file, which is how a reader resolves it, and it is the form that rots
# most quietly: it carries no filename, so a grep for a moved file never sees
# it. One of the citations this gate was written for was exactly that.
#
# What it deliberately does not check: that line `N` still says what the
# docstring claims it says. Nothing mechanical can. The convention the tree
# follows — and what a reader should assume — is that a citation names the line
# where the cited thing *begins*: the `def`, `theorem`, `structure`,
# `inductive`, `abbrev` or `instance` line, or the first line of a cited
# passage. A citation with no line number (`Exec.lean`, naming a file) is left
# alone here, including the handful that name a *deleted* file as the subject
# of a sentence saying it is gone.
#
# Exits 0 when every citation resolves; 1 with a named list otherwise.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

root="$(cd .. && pwd)"

# Every .lean in the tree, minus build output, as "<relative path>\t<lines>".
index="$(mktemp "${TMPDIR:-/tmp}/agentic-citations.XXXXXX")"
trap 'rm -f "$index"' EXIT

find "$root" -name '*.lean' -not -path '*/.lake/*' -not -path '*/dist-newstyle/*' \
  -print0 |
  while IFS= read -r -d '' f; do
    # `awk END{print NR}` and not `wc -l`: a file whose last line carries no
    # newline is one line shorter to `wc`, and a citation to that last line
    # would then fail for a reason that is about the file's bytes and not
    # about the citation.
    printf '%s\t%s\n' "${f#"$root"/}" "$(awk 'END { print NR }' "$f")"
  done >"$index"

leancount="$(wc -l <"$index" | tr -d ' ')"

# Every citation written in a Haskell source under haskell/, as
# "<file>:<line>:<path>:<N>". The path part may be bare (`Exec.lean`) or
# partial (`Agentic/Core/Exec.lean`); it resolves if the one file it names, or
# a file whose path ends in `/<what was written>`, exists. Bare continuations
# are resolved here against the file most recently named above them in the same
# source — `awk` carries that cursor, reset at each file — so what reaches the
# loop below is uniform.
citations="$(mktemp "${TMPDIR:-/tmp}/agentic-cited.XXXXXX")"
sources="$(mktemp "${TMPDIR:-/tmp}/agentic-sources.XXXXXX")"
trap 'rm -f "$index" "$citations" "$sources"' EXIT
# F4 (fess wave-1): scan the docs and gate scripts too — the bare-reference
# class this gate exists to kill has lived in README.md and ci/*.sh before.
find . \( -name '*.hs' -o -name '*.md' -o -name '*.sh' \) \
  -not -path '*/dist-newstyle/*' | sort >"$sources"

if [ ! -s "$sources" ]; then
  echo "ci/citations: no Haskell sources found under $(pwd) — wrong directory?" >&2
  exit 1
fi

# shellcheck disable=SC2046
awk '
    FNR == 1 { cur = "" }
    {
      line = $0
      while (match(line, /(([A-Za-z0-9_]+\/)*[A-Za-z0-9_]+\.lean:[0-9]+)|(@:[0-9]+@)/)) {
        tok = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (substr(tok, 1, 2) == "@:") {
          n = substr(tok, 3, length(tok) - 3)
          if (cur != "") print FILENAME ":" FNR ":" cur ":" n
        } else {
          split(tok, parts, ":")
          cur = parts[1]
          print FILENAME ":" FNR ":" tok
        }
      }
    }
  ' $(cat "$sources") >"$citations"

total=0
failures=0

report() { echo "ci/citations: FAIL $*" >&2; failures=$((failures + 1)); }

while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  total=$((total + 1))

  # `./src/Agentic/Exec.hs:55:Exec.lean:618` — the last two fields are the
  # citation, everything before them is where it was written.
  cited="${hit##*:}"                     # 619
  rest="${hit%:*}"                       # ./src/Agentic/Exec.hs:55:Exec.lean
  path="${rest##*:}"                     # Exec.lean
  where="${rest%:*}"                     # ./src/Agentic/Exec.hs:55
  where="haskell/${where#./}"

  # The .lean files this citation could mean.
  matches="$(awk -F'\t' -v p="$path" \
    'index($1, p) == length($1) - length(p) + 1 && \
     (length($1) == length(p) || substr($1, length($1) - length(p), 1) == "/") \
     { print $1 "\t" $2 }' "$index")"

  n="$(printf '%s' "$matches" | grep -c . || true)"

  if [ "$n" -eq 0 ]; then
    report "$where cites $path:$cited — no such file under $root"
    continue
  fi

  # In range for at least one candidate is in range: a partial path that names
  # two files is ambiguous, not wrong, and the citation stands if either fits.
  fits=0
  best=""
  while IFS=$'\t' read -r f lines; do
    [ -n "$f" ] || continue
    best="$f ($lines lines)"
    if [ "$cited" -le "$lines" ] && [ "$cited" -ge 1 ]; then fits=1; fi
  done <<<"$matches"

  if [ "$fits" -eq 0 ]; then
    report "$where cites $path:$cited — past the end of $best"
  fi
done <"$citations"

echo "ci/citations: $total citations checked against $leancount Lean files"

if [ "$failures" -gt 0 ]; then
  echo "ci/citations: $failures stale citation(s)" >&2
  exit 1
fi

# F4 (fess wave-1): the floor. A gate that scanned sources and found nothing
# is a broken gate, not a clean tree — the awk, the find or the format
# changed under it. 200 is well under the ~254 live today and well over
# noise; re-derive it if the citation discipline genuinely shrinks.
if [ "$total" -lt 200 ]; then
  echo "ci/citations: only $total citations found — below the 200 floor; the scan is broken, not the tree" >&2
  exit 1
fi
echo "ci/citations: every citation resolves"
