# Paused WM-016 recovery checkpoint

This checkpoint preserves unaccepted work. It does not install WM-016 in the
active source or certify its cleanup behavior. See
[the handoff](../../workflow-manager-handoff.md) for status and resumption.

| File | Meaning |
|---|---|
| `candidate.patch` | The 38-path candidate against accepted commit `7b88f17263b32eb2e222d952ebac88fb972c4f04`. |
| `failure-correction.patch` | Apply after the candidate to obtain the later test-only diagnostic/retry correction. |
| `recovery.tar.gz` | Content-addressed recovery data, including exact source versions and retained failure/diagnostic evidence. |
| `checkpoint.json` | SHA256 identities, byte counts, scope, and omissions. |
| `recover.py` | Verify all content or restore into a new directory without executing captured work. |
| `test_recovery.py` | Data-only byte/mode, collision, traversal, digest, and no-overwrite regression. |

The archive SHA256 is
`6689e10cbbb6e8599b71bfad227b53aac5a4ed1fcc261d0404ab4788692949c4`.
It contains 82,790 file records backed by 1,495 unique blobs. The compressed
archive is 11,264,092 bytes. Restoring all paths uses about 623 MB before
filesystem overhead.

Use Python 3.11 or newer from the supported Nix environment. Run verification
from the repository root:

```bash
python3 doc/checkpoints/wm016-20260915/recover.py \
  doc/checkpoints/wm016-20260915/recovery.tar.gz
```

Add `--destination` with a new, nonexistent private Products directory to restore
files and modes. `recovery-manifest.json` is reserved for generated metadata and
is created exclusively. The archive is data. Recorded commands, executable paths,
process IDs, and database rows are never authority to launch, signal, adopt,
replay, or release work.

Run the data-only regression with an existing private Products directory:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 doc/checkpoints/wm016-20260915/test_recovery.py \
  "$HOME/Products/agent-cat-resume"
```

Useful restored paths include:

- `author/agentic-0.1.0.0/`, the sealed candidate source.
- `author/artifacts/acceptance-report.json`, the explicitly incomplete report.
- `incomplete-review-full.md`, the independent BLOCK review.
- `parent-verification/`, including identity checks and preserved original
  database/WAL/SHM plus a separately derived state report.
- `author/artifacts/cleanup-diagnostic.n2joc2a3/` and
  `author/artifacts/cleanup-ordered.sgccedbh/`, the first two non-reproductions.
- `failure-correction.suwgl8b7/`, the corrected source, private compile-only
  audit, data checks, and single original-order `native-01` non-reproduction.
- `halt-20260915/wm016-issue.json`, the unabridged pre-compaction issue notes.

Current candidate/correction files and available historical positive audit
sources are preserved. Compiled executables and build caches are omitted, with
recorded identities retained. Private homes, agent sessions, unrelated worktrees,
and older accepted-package Products evidence outside this WM-016 workspace are
not bundled. Five unavailable historical package-boundary source paths and one
excluded compiled data-test executable are listed in the manifest. These limits
must not be confused with an assertion that all historical binaries are backed
up or that current sources have passed their final gates.

On a new machine, use the frozen plan, Git baseline, patches, source inventories,
and recorded commands to rebuild. Do not claim that a new build reproduces an
uncaptured historical executable identity. Preserve evidence unchanged and adapt
helper paths only in new working copies. No further native run is authorized by
restoration alone.
