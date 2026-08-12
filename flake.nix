{
  description = "agent-cat — a denotational design for agentic workflows, formalized in Lean 4";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            # Lean 4 (compiler + lake), from nixpkgs rather than elan: the
            # toolchain is exactly this derivation, `lake` runs with the Lean
            # it ships beside, and there is deliberately no lean-toolchain
            # file for elan to consult. The package is self-contained (no
            # Mathlib), so nothing here needs the network after this shell.
            pkgs.lean4
          ];
        };
      });
}
