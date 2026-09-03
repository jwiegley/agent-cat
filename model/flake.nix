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
            # Lean 4 (compiler + lake), from nixpkgs rather than elan. The
            # repository DOES carry a lean-toolchain file (v4.30.0, which this
            # derivation must match) and lakefile.toml requires Mathlib at the
            # same tag, so a cold build needs the network once — `lake exe
            # cache get` for Mathlib's objects, or hours of elaboration on a
            # cache miss. After that, everything is local. (This comment once
            # claimed the opposite on both counts; connection.md §3.9 filed
            # the correction.)
            pkgs.lean4
            # Manual source is Texinfo; `make -C doc check` builds Info and HTML.
            pkgs.texinfo
          ];
        };
      });
}
