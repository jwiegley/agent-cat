# Workflow manager release evidence

This record gives the identities of the local release artifacts of the workflow
manager and the checks that produced them. Every check ran on one macOS host of
the system `aarch64-darwin`, with no binary cache, no package repository and no
external host.

## Package identities

The flake package `agentic-run` was built with the flake reference
`.#agentic-run` from the Git worktree. The base revision is
`eca320c9ef1ce6838527acfcf051f5b56e73f910`, and the working copy held the
package change to `flake.nix` without a commit. The derivation path depends
only on `flake.nix`, `flake.lock` and the filtered source, so a commit of the
same files keeps it.

| Item | Identity |
|---|---|
| Derivation path | `/nix/store/6y76igrq76s9g2byl8wdjimbc4vsrn9h-agentic-run-0.1.0.0.drv` |
| Output path | `/nix/store/lc8qfj9nwxrlm4582wswn9vk3h48zigv-agentic-run-0.1.0.0` |
| Filtered source | `/nix/store/1m2g1kmy6m9rplv5ckn7c72pz2slml4r-source` |
| SHA-256 of `bin/agentic-run` | `6ad55c59c69d57923b2ec929d3cd937405ada1fe430f36ef0f056dbfa995e4fc` |
| Source distribution | `agentic-0.1.0.0.tar.gz`, 1897636 bytes |
| SHA-256 of the source distribution | `471817ca146cfb0192b3dbcd0d0ab45c5d03799b9b549bfc686e192af1decbce` |
| Compiler | GHC 9.10.3 from the GHC environment of the root shell |
| Build tool | cabal-install 3.16.1.0 |
| Nix | Nix 2.34.8 (Determinate Nix 3.21.7) |

The build ran with `--no-update-lock-file` and `--option substitute false`.
Nix built one derivation, the package itself, and found every other input in
the local store. The build took 330 seconds of wall clock, of which the build
phase took 5 minutes and 23 seconds. The one-minute load average was 6.3 at the
start and 14.6 at the end.

The built `bin/agentic-run list` printed the ten registered programs, and
`bin/agentic-run run hello --scripted` printed the documented trace with
`billFresh 3` and `billMemo 3`. `doc/check-manual-cli.py` passed against the
built executable.

The derivation path was the same in three evaluations: from the worktree, from
a copy of its tracked files in a temporary directory with the reference
`path:<copy>#agentic-run`, and from the worktree after an edit of `README.md`
only. The flake fingerprint changed with that edit, so the edit reached the
flake source. The edit was then reverted.

The listing of the source distribution from `test/cabal.sh sdist` includes
`nix/haskell-overrides.nix`, `nix/crypton-x509-validation-san.patch` and
`nix/process-close-fds-linux.patch`.

## Acceptance of the packaged artifact

The `package` mode of `manager/test/service_http.py` accepts the packaged
executable through a running manager. It reads the path of `bin/agentic-run`
from `PACKAGE_RUNNER` and uses that file in place of the runner argument of
the harness. The file is the manager process and the runner of the one
profile of the fixture, whose target arguments are `--scripted`. The mode
issues a credential with `observe`, `submit` and `control`, creates a request
of the `hello` workflow, which needs no provider and no input, enqueues it and
approves the exact review. It waits for the terminal run, downloads the
verified result and compares the SHA-256 of the downloaded bytes with the
published digest. It requires that the supervisor manifest of the worker run
names the packaged executable. It then reads `status` through the live
channel, stops the manager through `shutdown` and requires exit status 0.

```sh
out=$(nix build .#agentic-run --no-update-lock-file --option substitute false --print-out-paths --no-link)
schemas=$(mktemp -d)
direnv exec . bash -c "\$(bash test/cabal.sh list-bin manager-store-check) schema-fixtures $schemas"
fixture=$(mktemp -d)
mkdir "$fixture/N8"
SCHEMA_FIXTURES="$schemas" PACKAGE_RUNNER="$out/bin/agentic-run" direnv exec . python3 -B manager/test/service_http.py \
  "$PWD" "$fixture/N8" "$out/bin/agentic-run" 8 package
```

The mode needs both `PACKAGE_RUNNER` and `SCHEMA_FIXTURES`. The schema step
follows the `hello` run and is described under
[schema upgrade and refusal](#schema-upgrade-and-refusal).

The run of record passed at `-N8` on 2026-10-03. The base revision was
`5710785a3de642c166929c3dff7204a76af62fa0`, and the working copy held the
change to `manager/test/service_http.py` and to the documentation without a
commit. These files are outside the filtered source, so `nix build` with
substitution disabled built nothing and printed the output path of the table
above. The one-minute load average was 8.5 at the start and 8.3 at the end.

| Item | Identity |
|---|---|
| Derivation path | `/nix/store/6y76igrq76s9g2byl8wdjimbc4vsrn9h-agentic-run-0.1.0.0.drv` |
| Output path | `/nix/store/lc8qfj9nwxrlm4582wswn9vk3h48zigv-agentic-run-0.1.0.0` |
| SHA-256 of `bin/agentic-run` | `6ad55c59c69d57923b2ec929d3cd937405ada1fe430f36ef0f056dbfa995e4fc` |
| Runner version in the catalogue and the supervisor manifest | `0.1.0.0` |
| Workflow | `hello`, `workflow_117d409316e9bd8244415684a88f2d8327304e414da4a7ca078e905906abce16` |
| Program hash in the supervisor manifest | `785260762a2848e71d20e3e522a8e477d76b13142cc18e3fe7fcdfebaf085cbb` |
| Run | `run_60ead7e72ec2880e4439e45aa232b106808eaf05086fc063`, worker run `native-13321-1539500648564000` |
| Verified result | `artifact_aede23c426668a33b6ae22874bdd2ec39c6a52f0e58fd8465c7e40f532cc6046`, 103 bytes |
| SHA-256 of the downloaded result | `54b4cee307f3dc2eb37cd42f48d70e6bd01f9be94e859ed43f7bc34da31fb6c9`, equal to the published digest |

The live `status` answered `state` `serving`, `live` and `ready` `true`, with
0 active reservations and 0 owned workers after the run. `shutdown` answered
`{"state": "stopped"}`, and the serve process exited with status 0. The result
holds the identifier of the worker run, so its digest differs from one run to
the next.

## Schema upgrade and refusal

The `schema-fixtures DIR` lane of `manager-store-check` writes the manager
roots `schema-1` to `schema-11` and `schema-13` in `DIR`. Each root holds its
manager role marker and a coordination database. The database of `schema-N`
holds the tables of schema version N, which are the version-one statements and
the migrations of `Agentic.Manager.Schema` up to that version. The database of
`schema-13` holds the tables of version 12 with `user_version` 13. Each
database has one service metadata row with an authority epoch derived from its
version.

After the `hello` run, the `package` mode copies each root of
`SCHEMA_FIXTURES` and gives the copy a serve configuration and an offline
configuration. For each older root, the packaged executable runs offline
`status`, which reports the authority epoch of the fixture. `PRAGMA
user_version` then reads 12, and offline `check-store` reports `valid`. The
mode issues a credential offline, starts `RUNNER --manager serve`, requires
200 on `GET /v1/capabilities` with the authority epoch of the fixture, stops
the manager through `shutdown` and requires exit status 0. For `schema-13`,
offline `status` refuses with `storage-unavailable`, `RUNNER --manager serve`
exits with status 2, and `user_version` stays 13.

The run of record of the schema step passed at `-N8` on 2026-10-03 with the
output path of the table above. The base revision was
`8fcb49991c9b49ac0095275572f49dcf81818fc0`, and the working copy held the
change to `manager/test/StoreCheck.hs`, `manager/test/service_http.py` and
the documentation without a commit. These files are outside the filtered
source, so `nix build` with substitution disabled built nothing. The one-minute
load average was 6.2 at the start and 5.9 at the end. All eleven older roots
upgraded to version 12, passed `check-store` and served, and the version 13
root was refused by offline administration and by serve.
