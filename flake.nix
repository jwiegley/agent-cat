{
  description = "agentic-hs — a Haskell production implementation of agent-cat, conformance-tested against the Lean oracle";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # One GHC with `aeson` and `QuickCheck` already in its package
        # database. `aeson` drags in every other library the cabal file names —
        # text, bytestring, containers, vector, scientific — and base,
        # directory, filepath and process ship with the compiler, so the whole
        # dependency list is present before cabal ever consults an index. That
        # is deliberate: the shell is the environment, nothing is installed
        # globally, and a build needs no network once this shell has been
        # entered.
        #
        # `QuickCheck` arrives in week three, for `Agentic.Gen`'s generators
        # and the `bisim` runner that draws from them. It is a library
        # dependency, not a test-suite one: the generators are part of the
        # product's conformance surface, and `bisim` is an executable that
        # ships beside `tier0` and `tier1`.
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [ p.aeson p.QuickCheck ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ghc
            pkgs.cabal-install
          ];
        };
      });
}
