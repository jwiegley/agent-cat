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

        # One GHC with the dependencies declared by the single Cabal package.
        # HTTP/TLS and SHA-256 support belong to bounded routing-v2 discovery;
        # no external fetch executable or provider SDK is used.
        ghc = pkgs.haskellPackages.ghcWithPackages (p: [
          p.aeson
          p.crypton
          p.crypton-connection
          p.crypton-x509-store
          p.http-client
          p.http-client-tls
          p.libyaml
          p.QuickCheck
          p.tls
          p.yaml
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            ghc
            pkgs.cabal-install
            # Test-only: generate an ephemeral loopback TLS certificate.
            pkgs.openssl
          ];
        };
      });
}
