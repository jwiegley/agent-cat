pkgs: final: prev:
{
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
