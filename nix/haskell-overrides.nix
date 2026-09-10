pkgs: final: prev:
{
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
