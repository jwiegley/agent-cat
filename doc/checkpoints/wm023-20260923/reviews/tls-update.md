## Review

- **Correct:** `broker-source/nix/haskell-overrides.nix:3–27` adds targeted certificate/TLS family and compatibility aliases. Existing canonical overrides remain unchanged. No jailbreak, test disabling, or compiler change introduced.
- **Correct:** `broker-source/nix/crypton-x509-validation-san.patch:7` fixes shared validator dispatch. SAN presence selects existing DNS/IP matching instead of CN fallback. Chain/signature checks remain untouched in upstream `Data/X509/Validation.hs:293–309`.
- **Correct:** `broker-source/agentic.cabal:130` replaces `memory` with `ram`. Other Cabal/service/client changes are outside this verdict.
- **Correct:** `broker-source/manager/test/client_native.py:62–94,231–233` covers independently checked constrained-CA cases, positive IP-only SAN, matching-CN rejection, DNS-form IP rejection, and refusal before HTTP requests. `manager/test/ClientCheck.hs:95–104` requires expected failure category rather than accepting arbitrary failure.

### Finding

**P2 — Source archive omits newly referenced patch.**

`broker-source/nix/haskell-overrides.nix:18` references `crypton-x509-validation-san.patch`, but `broker-source/agentic.cabal:13–16` includes only overrides and existing process patch in `extra-source-files`. Cabal source archives therefore omit this new dependency of their shipped override.

Smallest fix: add patch to `extra-source-files` before publishing source archives. This requires one explicitly approved Cabal hunk beyond current common-settings-only scope. Repository integration need not block on this packaging note.

### Evidence checked

- `tls-nix-ghc-fifth.validation.log:1054–1058`: all **582 upstream tests passed**.
- `tls-client-build-relink.command:4–5` selects patched compiler environment and forces recompilation. `tls-client-build-relink.log:117–122` confirms driver compilation and linking.
- `tls-client-native-relinked.log:4–40`, corresponding exit file: **18 cases passed at N1 and N8**, exit 0.
- `tls-name-constraints-red.log:6–11` remains failed regression evidence.
- `tls-client-native-san.log:7–11` remains failed stale-executable evidence, not patch validation.

No commands, tests, Git operations, or edits performed by reviewer.

### Residual risks

`acat-tls-name-forms-6gbo` remains unresolved. Upstream `Data/X509/Validation.hs:649–663` lacks IP Name Constraints matching and treats unsupported forms as nonmatches. DNS normalization and constraint inheritance remain outside demonstrated coverage.

**Merge verdict: OK with notes — bounded dependency/SAN improvement can integrate independently.** This does not approve service/client WIP, general-CA service acceptance, TUI completion, or additional milestones.