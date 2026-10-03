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
