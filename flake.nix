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

        # One GHC for package builds and manager dependency probes.
        hs = pkgs.haskellPackages.extend (import ./nix/haskell-overrides.nix pkgs);
        ghc = hs.ghcWithPackages (p: [
          p.aeson
          p.async
          p.brick
          p.direct-sqlite
          p.crypton
          p.crypton-connection
          p.crypton-x509-store
          p.http-client
          p.http-client-tls
          p.libyaml
          p.QuickCheck
          p.tls
          p.vty
          p."vty-unix"
          p.wai
          p.warp
          p.warp-tls
          p.yaml
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ghc
            pkgs.cabal-install
            pkgs.lean4
            # Test-only: generate an ephemeral loopback TLS certificate.
            pkgs.openssl
            (pkgs.python3.withPackages (p: [ p.pyyaml p.jsonschema p.openapi-spec-validator ]))
          ];
        };
      });
}
