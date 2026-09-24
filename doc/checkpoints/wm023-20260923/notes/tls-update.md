# Authorized TLS dependency update

The user explicitly authorized the targeted Nix update to crypton-x5091.9.1 and crypton-x509-validation1.9.1. Work resumed on2026-09-23 at18:33:19Z. The next refocus deadline is19:33:19Z. The compiler remains GHC9.10.3 and flake.lock is unchanged. All execution remains on this macOS host. There is no paid backend, live configuration change, deployment or new Lean/oracle build.

## Candidate scope

Source is the existing isolated broker-source worktree. Canonical remains at tracking checkpoint8f6bbc4, with application baseline678326b. The bounded integration is nix/haskell-overrides.nix, nix/crypton-x509-validation-san.patch, its required extra-source-files entry and the common-settings memory-to-ram change in agentic.cabal, plus the one-line certificate-CN regression in manager/test/DependencyProbe.hs. The other Cabal changes and all service/client application WIP remain outside this integration. The reviewer identified the missing source-distribution patch entry and parent added it. The existing dependency probe now uses CNlocalhost with its correct IP SAN127.0.0.1, so its standard trusted TLS check requires the corrected IP-SAN path instead of accidentally succeeding through matching CN fallback.

The certificate1.9 family requires crypton1.1, the crypton ASN.1 packages, ram and time-hourglass. The existing Nix pin supplies the compatible aliases crypton1.1.2, crypto-token0.2.0, hpke0.1.0, tls-session-manager0.1.0, crypton-x509-store/system1.9.0, crypton-connection0.4.6 and http-client-tls0.4.0. The selected tls2.3.0 is the first ram-based TLS release. It avoids adding the optional ML-KEM implementation introduced later. None of the selected package tests or version bounds were disabled.

The attempted packaged tls2.4.1 build exposed missing downloaded ML-KEM test vectors. That failed build is retained, not passed or suppressed. Other retained dependency failures were the old crypto-token memory/ram class mismatch and the old http-client-tls crypton upper bound. Supporting aliases resolve those actual dependency incompatibilities.

## SAN correction

Upstream1.9.1 tests whether DNS alternative names exist before entering its IP-address matcher. An IP-only SAN therefore falls back to common-name matching. The one-line dependency patch tests the presence of the SAN extension instead. Existing name matching and chain validation remain the owners. No client hook, trust bypass, certificate replacement or disabled check is added. A matching common name cannot override a mismatched IP SAN, an IP-only SAN cannot authorize a DNS reference through its common name, and a DNS-form IP string cannot authorize an IP reference.

The public-client fixture now contains paired constrained-CA positive and negative cases, checked independently by OpenSSL. The pre-update executable accepted an excluded DNS name and failed the regression at18:49:18–18:49:21Z. The original positive IP-SAN failure persists in the earlier logs. The new dependency patch passes both the positive IP-only case and the matching-CN negative cases after actual relinking.

The first build against the patched1.9.1 derivation reused the old static client executable because the package version and public ABI had not changed. It did not validate the patch. Parent confirmed the new library's public validation hook separately, then forced recompilation and relinking. That failed stale-executable run remains recorded.

## Evidence

Every prefix retains command, start, end, exit and log files in this unit.

- tls-nix-ghc,18:37:15–18:39:36Z, exit1, old crypto-token byte-array class mismatch.
- tls-nix-ghc-second,18:40:38–18:42:08Z, exit1, optional ML-KEM test-vector acquisition failure.
- tls-nix-ghc-third,18:43:33–18:45:49Z, exit1, old http-client-tls crypton upper bound.
- tls-nix-ghc-fourth,18:46:20–18:46:57Z, exit0, unpatched1.9.1 family.
- tls-name-constraints-red,18:49:18–18:49:21Z, exit1 at the intended excluded-DNS refusal. Root /Users/johnw/Products/k.M0a5ItPm/tmp/constraints-red.whkDP1Ir.
- tls-client-build,18:50:27–18:52:16Z, exit0, current family compilation.
- tls-client-native,18:53:14–18:53:19Z, exit1 at the original positive IP-SAN case. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-client.0fHIuIbm.
- tls-nix-ghc-fifth,19:00:18–19:03:03Z, exit0, SAN-patched family. Its retained validation build log reports all582 upstream tests passed.
- tls-client-build-san,19:04:09–19:04:34Z, exit0, but tls-client-native-san,19:04:34–19:04:39Z, exit1, still used the old static client executable. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-client.Sexqx4Ae.
- tls-client-build-relink,19:06:20–19:08:44Z, exit0, explicit -fforce-recomp and relink with the patched package set.
- tls-client-native-relinked,19:08:44–19:09:09Z, exit0. All18 public-client cases passed at N1 then N8. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-client.4rUzfpwm.
- tls-client-manager,19:10:00–19:10:11Z, exit0. The actual public Client now connects to the protected manager, assembles real pages, polls, enforces endpoint/session bindings, and observes client closure at N1 and N8. The service fixture also checks TLS1.3, polling/SSE, quotas, revocation, original joins and restart. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-manager.skFWIQtZ.

The updated private environment selects /nix/store/70qgc49k6yrkbyvbxgsvznb65l83wc9k-ghc-9.10.3-with-packages after entering canonical direnv. The derivation has an explicit local GC root tls-ghc-san in this unit. Prior package-set roots and failed runs remain preserved.

## Residual security and acceptance limits

Issue acat-tls-name-forms-6gbo records a source-grounded residual concern in upstream1.9.1. isIncludedIn has no AltNameIP implementation. Its fallback returns Nothing, which nsNotMatch treats as no exclusion. DNS normalization/subdomain boundaries and constraint inheritance also require review before claiming general-CA security acceptance. This update is not complete PKIX assurance, and those unexercised cases must not be described as passing. No service/client application integration or enabled general-CA service acceptance is requested here.

The actual TUI path remains unimplemented. Earlier service-loan review clearance and slow-response liveness obligations remain pending. WM001–WM022/G0/G1 stay accepted, and no further WM/G milestone is closed.

## Integration checks and review

Reviewer63fdf53f-c03b-463a-9c3d-bbdfdb66a43f returned OK with notes for bounded dependency/SAN integration, not service/client or general-CA acceptance. The complete report is tls-update-review.tls-update-review.md. The short workflow summary at tls-update-review.md is truncated and is not the complete verdict. The reviewer identified a missing source-distribution patch entry. Parent added that entry and changed the existing dependency probe certificate CN tolocalhost, retaining its correct IP SAN. These are the small packaging and regression additions described in the scope above.

tls-owning-build,19:14:04–19:18:04Z, built the four current executables, then failed its direct probe compilation because -package agentic left Agentic.Runtime hidden. Explicit selection of the registered main library unit, -package-id agentic-0.1.0.0-inplace, compiled the same probe. No shared Cabal wrapper or production owner was changed.

tls-owning-native,19:20:34–19:21:42Z, failed at N1. Dependency and admission checks passed, as did the real public Client observation. The mixed workflow request then remained queued with waiting admission, preparationId:null and runId:null until its observation deadline. Its server stderr was empty. The exact cause is not established and no automatic replay was attempted. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-owning.k0E71nvQ remains preserved. This is not a completed workflow under the updated environment.

tls-dependency-only,19:23:56–19:23:57Z, completed the owning dependency probe at N1 and N8, then failed because the offline wrapper adds an unsupported --offline option to sdist. The subsequent local-only archive command used Cabal directly with active-repositories:none. No download or resolver step is required for sdist.

tls-canonical-gates began19:26:30Z. Canonical library compilation, the strengthened owning dependency probe at N1/N8, exact SAN-patch source-archive comparison and make -C doc check completed. Root /Users/johnw/Products/k.M0a5ItPm/tmp/tls-canonical.ISgxuXLm is retained. The bash tool then timed out after900seconds while check-haskell was still compiling the full Haskell workspace. The original end/exit receipts are absent, and tls-canonical-gates.timeout records the limited process observation without claiming original joins or cleanup.

tls-canonical-haskell resumed only make -C doc check-haskell at19:43:35–19:45:39Z, exit0. It completed the Haskell workspace build, manual CLI check,134 compiler-exported children and112 class-instance checks. It did not run Lean or build an oracle. This later result does not turn the earlier timed-out invocation into a pass.

At19:47:05Z parent checked that canonical Nix override, SAN patch and dependency probe bytes match the isolated candidate, the Cabal delta contains only the two intended entries, and flake.nix/flake.lock remain unchanged. Refocus remains the actual frontend path, with deadline20:47:05Z.

tls-final-check passed19:52:29–19:52:33Z, including the final prose gate and equality of227 shared tracker records with all four authority-only records preserved. The authority export contains231issues,325dependencies,149labels and304comments. Canonical Nix evaluation resolved the exact tested /nix/store/70qgc49k6yrkbyvbxgsvznb65l83wc9k-ghc-9.10.3-with-packages derivation.

At19:53:18Z canonical was clean after commit70bf071075a8c76357c8bb35510748aa2490fbf7, six files with148 insertions and66 deletions including tracking. Only the bounded dependency improvement was integrated. No push occurred. Service/client application WIP remains in broker-source, and its dependency changes already match canonical. The shared build directory was last rebuilt from canonical. Rebuild the isolated components before any further native service check, rather than reusing a stale executable. The existing cached direnv environment was not globally regenerated. Tests enter it and then source the recorded private environment selecting the updated Nix derivation.
