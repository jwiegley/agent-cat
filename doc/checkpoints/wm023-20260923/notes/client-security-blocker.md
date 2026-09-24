# Pinned TLS certificate validation blocks service-client enablement

The pinned local environment reports crypton-x509-validation1.6.14 and crypton-x5091.7.7. Both are affected by CVE-2026-9648, according to HSEC-2026-0008 and CERT/CC VU#862559. Certificate Name Constraints are not enforced. A compromised name-constrained intermediate CA can therefore issue certificates outside its authorized namespace that affected clients accept.

The Haskell advisory identifies fixes in crypton-x509-validation1.9.1 and crypton-x5091.9.1. The installed versions were rechecked with ghc-pkg in canonical direnv and the private environment at2026-09-23T09:58:41Z. No dependency version, lock file, compiler or live configuration has been changed.

Sources:

- https://haskell.github.io/security-advisories/advisory/HSEC-2026-0008.html
- https://www.kb.cert.org/vuls/id/862559

The current task forbids dependency-version changes without explicit authorization. Mandatory authentication safety must precede enabled frontend functionality. The next authorized decision is whether to update the affected certificate packages, and any compatibility-required dependent packages, through the existing Nix setup. Validation must remain local. Do not disable certificate checks, add permissive hooks, alter trust implicitly, or weaken negative assertions.

Separately, the real-manager public Client check failed with TransportUnavailable. A focused fixture reproduced rejection of a trusted certificate with CN localhost and the correct IP SAN127.0.0.1 when connecting to127.0.0.1. The same client boundary suite passed with a matching CN. This IP-SAN interoperability failure is distinct from the Name Constraints vulnerability. Its positive assertion remains in client_native.py and must not be changed to accept failure merely to pass the suite.

Preserved evidence in the service-tui.purvEwEv unit:

- client-profile-build-first,09:30:24–09:30:32Z, failed because the proposed readSignedObject name was not exported. Inspection of the pinned module identified readSignedObjectFromMemory.
- client-profile-build-second,09:31:53–09:31:58Z, passed Werror compilation.
- client-check-build-first,09:43:14–09:43:19Z, failed because header-limit record selectors are not public. The pinned public managerSetMaxHeaderLength and managerSetMaxNumberHeaders setters are now used.
- client-check-build-second,09:47:52–09:48:05Z, passed.
- client-native-first,09:48:25–09:48:40Z, passed twelve client-boundary cases at N1 then N8, including trusted/untrusted TLS, wrong host, exact maximum-length nonce, lost reply without retry, changed credential, page mismatch, and original HTTP task cancellation/join. These are an external API fixture, not workflow or TUI acceptance. Root: /Users/johnw/Products/k.M0a5ItPm/tmp/client.imzrX3px.
- client-manager-native-first,09:50:49–09:51:08Z, failed at N1 before client observations completed. Root: /Users/johnw/Products/k.M0a5ItPm/tmp/client-manager.pG6gynLA.
- client-ip-san-diagnostic,09:54:49–09:54:50Z, failed the newly added positive IP-SAN case at N1. Root: /Users/johnw/Products/k.M0a5ItPm/tmp/client.YNNO3FpX.

Completion requires explicit approval for the targeted dependency update, verified fixed certificate validation including constrained-CA refusal, correction or explicit supported handling of the positive IP-SAN case without hostname bypass, relevant owning local gates at N1 then N8, and continuation of the real public-client/TUI journey. Existing WM001–WM022/G0/G1 acceptance records remain closed. The pending service application remains isolated and unreviewed, and no new WM/G milestone is accepted.
