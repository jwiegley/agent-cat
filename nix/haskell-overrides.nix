pkgs: final: prev:
{
  # Use the upstream Name Constraints update and its compatible TLS family.
  crypton = prev.crypton_1_1_2;
  crypto-token = prev.crypto-token_0_2_0;
  hpke = prev.hpke_0_1_0;
  tls-session-manager = prev.tls-session-manager_0_1_0;
  crypton-x509 = final.callHackageDirect {
    pkg = "crypton-x509";
    ver = "1.9.1";
    sha256 = "sha256-8VZ64FbEiLj4o+Nm9ZzpNH7ZYs9w6rTkLvT9p2PgBf4=";
  } {};
  # SAN presence, including IP-only SANs, takes precedence over the common name.
  crypton-x509-validation = pkgs.haskell.lib.appendPatch (final.callHackageDirect {
    pkg = "crypton-x509-validation";
    ver = "1.9.1";
    sha256 = "sha256-YKufVgXC8qz80tScE3vENVrwJD1MgZYRNnjqirscrLA=";
  } {}) ./crypton-x509-validation-san.patch;
  crypton-x509-store = prev.crypton-x509-store_1_9_0;
  crypton-x509-system = prev.crypton-x509-system_1_9_0;
  crypton-connection = prev.crypton-connection_0_4_6;
  http-client-tls = prev.http-client-tls_0_4_0;
  tls = final.callHackageDirect {
    pkg = "tls";
    ver = "2.3.0";
    sha256 = "sha256-kip1dltP9SvauoTYSJ7Hi0bwM6bg5nVJnjTgQlZByhI=";
  } {};

  # Include upstream descriptor-exhaustion, shutdown, and response-header fixes.
  wai = final.callHackageDirect {
    pkg = "wai";
    ver = "3.2.5";
    sha256 = "sha256-Pmj0T7nVWbeJC2owVdM5gGUMSocVd2D0/lCKIy85Xp0=";
  } {};
  warp = pkgs.haskell.lib.overrideCabal (final.callHackageDirect {
    pkg = "warp";
    ver = "3.4.15";
    sha256 = "sha256-0xB1FnOmHpY5tz68twFs684HYKtiyb+sbjLZBER0VUA=";
  } {}) (old: {
    testToolDepends = (old.testToolDepends or []) ++ [ pkgs.curl ];
  });
  http2 = final.callHackageDirect {
    pkg = "http2";
    ver = "5.4.4";
    sha256 = "sha256-ftdFX8cWOWKhCKa++vFkVBStW8q/uTVJIUvP55pkLv8=";
  } {};
  http-semantics = final.callHackageDirect {
    pkg = "http-semantics";
    ver = "0.4.1";
    sha256 = "sha256-jzNgENa0Uj0ZGfg0N6zfbP2crSfRjBNpikKGgEl1hl4=";
  } {};
  network-run = final.callHackageDirect {
    pkg = "network-run";
    ver = "0.5.0";
    sha256 = "sha256-vbXh+CzxDsGApjqHxCYf/ijpZtUCApFbkcF5gyN0THU=";
  } {};
  time-manager = final.callHackageDirect {
    pkg = "time-manager";
    ver = "0.3.2";
    sha256 = "sha256-RSH3Uk/8mNVzXVSHhbPcfn3GVWqXUaWKUojJ7gtrXrs=";
  } {};
  # Bundled SQLite 3.45.0 predates the WAL-reset fix. Use the pinned system library.
  direct-sqlite = pkgs.haskell.lib.addExtraLibrary
    (pkgs.haskell.lib.enableCabalFlag prev.direct-sqlite "systemlib")
    pkgs.sqlite;
} // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  # Patch the bundled boot library without introducing a second process instance.
  # Both sets target the same platform in these native per-system flakes.
  buildHaskellPackages = final;
  ghc = prev.ghc.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      patch -d libraries/process -p1 < ${./process-close-fds-linux.patch}
    '';
  });
}
