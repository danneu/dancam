{
  description = "dancam dev shells -- cross-compile the Pi service to a static aarch64 musl binary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        # The Pi is a Raspberry Pi Zero 2 W: aarch64. We ship a single static
        # musl binary (nothing to install on the read-only car-image root). The
        # toolchain carries that target so cargo-zigbuild has its std library.
        target = "aarch64-unknown-linux-musl";
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          targets = [ target ];
        };
      in
      {
        # Cross-compile shell: `nix develop`, then
        #   cargo zigbuild --release --target aarch64-unknown-linux-musl \
        #     --manifest-path raspi/service/Cargo.toml
        # zig is the cross-linker; cargo-zigbuild drives it. Deps are pure Rust,
        # so no C cross-toolchain is needed.
        devShells.default = pkgs.mkShell {
          packages = [
            rustToolchain
            pkgs.zig
            pkgs.cargo-zigbuild
            pkgs.rsync
          ];

          env.DANCAM_TARGET = target;

          shellHook = ''
            echo "dancam cross shell. Build the Pi service with:"
            echo "  cargo zigbuild --release --target $DANCAM_TARGET --manifest-path raspi/service/Cargo.toml"
          '';
        };
      }
    );
}
