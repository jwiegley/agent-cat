# Fix haskell/process#189 in Linux's bundled boot library. Replacing process
# separately would leave compiler plugins linked to two incompatible instances.
pkgs: final: prev:
pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  # Both sets target the same platform in these native per-system flakes.
  buildHaskellPackages = final;
  ghc = prev.ghc.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      patch -d libraries/process -p1 < ${./process-close-fds-linux.patch}
    '';
  });
}
