{
  description = "agent-cat — modular Haskell workflow library and runner";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # One GHC with the dependencies declared by the single Cabal package.
        # HTTP/TLS and SHA-256 support belong to bounded routing discovery; no
        # external fetch executable or provider SDK is used.
        hs = pkgs.haskellPackages.extend (import ./nix/haskell-overrides.nix pkgs);
        ghc = hs.ghcWithPackages (p: [
          p.aeson
          p.async
          p.brick
          p.crypton
          p.http-client
          p.http-client-tls
          p.QuickCheck
          p.vty
          p."vty-unix"
          p.yaml
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ghc
            pkgs.cabal-install
          ];
        };
      });
}
