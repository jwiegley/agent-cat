{
  description = "agent-cat — modular Haskell workflow library and runner";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # One GHC with `aeson`, `QuickCheck` and `yaml` already in its package
        # database. Together they cover the external dependencies declared by
        # the sibling Cabal packages: core types ship with GHC, `aeson` brings
        # text/bytestring/containers/vector/scientific, `QuickCheck` serves the
        # bisimulation package, and `yaml` serves CLI model-definition loading.
        # The shell is the environment; nothing is installed globally.
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [ p.aeson p.QuickCheck p.yaml ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ghc
            pkgs.cabal-install
          ];
        };
      });
}
