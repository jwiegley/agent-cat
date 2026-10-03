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

        # The runner reads only these files.  Documentation, tests, fixtures and
        # the Lean model stay outside the source, so their commits keep the
        # derivation unchanged.
        haskellSource = pkgs.lib.fileset.fileFilter
          (file: file.hasExt "hs" || file.hasExt "c" || file.hasExt "h");
        runnerSource = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions ([
            ./agentic.cabal
            ./cabal.project
            (pkgs.lib.fileset.maybeMissing ./cabal.project.freeze)
            ./nix/haskell-overrides.nix
            ./nix/crypton-x509-validation-san.patch
            ./nix/process-close-fds-linux.patch
          ] ++ map haskellSource [
            ./dsl/src
            ./plan/src
            ./cost/src
            ./runtime/src
            ./runtime/cbits
            ./manager/src
            ./manager/cbits
            ./tui/src
            ./engine/api/src
            ./engine/acp/src
            ./engine/acp/claude/src
            ./engine/acp/codex/src
            ./engine/acp/droid/src
            ./engine/agent-deck/src
            ./cli/src
            ./cli/cbits
            ./cli/run
            ./workflow/example
            ./workflow/extra
            ./cli/example
          ]);
        };

        agentic-run = pkgs.stdenv.mkDerivation {
          pname = "agentic-run";
          version = "0.1.0.0";
          src = runnerSource;
          nativeBuildInputs = [ ghc pkgs.cabal-install ];
          LANG = "C.UTF-8";
          dontConfigure = true;
          # The same offline Cabal invocation as test/cabal.sh, against the GHC
          # of the development shell.  No package repository is read.
          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cabalOffline() {
              cabal --store-dir="$TMPDIR/cabal-store" --active-repositories=:none \
                "$1" --offline --builddir="$TMPDIR/dist" \
                --with-compiler="$(command -v ghc)" --with-hc-pkg="$(command -v ghc-pkg)" \
                --enable-optimization=1 "''${@:2}"
            }
            cabalOffline build -j"$NIX_BUILD_CORES" --ghc-options=-j exe:agentic-run
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -D -m 0755 "$(cabalOffline list-bin exe:agentic-run)" "$out/bin/agentic-run"
            runHook postInstall
          '';
          meta.mainProgram = "agentic-run";
        };
      in {
        packages.agentic-run = agentic-run;
        packages.default = agentic-run;

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
