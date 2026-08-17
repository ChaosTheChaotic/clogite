{
  description = "Clogite";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sqlite-zstd = {
      url = "github:phiresky/sqlite-zstd";
      flake = false;
    };
    sqlite-regex = {
      url = "github:asg017/sqlite-regex";
      flake = false;
    };
    sqlite-loadable-rs = {
      url = "github:asg017/sqlite-loadable-rs";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sqlite-zstd,
      sqlite-regex,
      sqlite-loadable-rs,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          zig-deps = pkgs.callPackage ./deps.nix { };

          sqlite-bundle = pkgs.rustPlatform.buildRustPackage {
            pname = "sqlite-bundle";
            version = "0.0.0";

            src = ./deps/sqlite-bundle;

            cargoLock = {
              lockFile = ./deps/sqlite-bundle/Cargo.lock;
            };

            doCheck = false;

            nativeBuildInputs = with pkgs; [
              pkg-config
              clang-tools
            ];
            buildInputs = with pkgs; [
              sqlite.dev
              llvmPackages.libclang.lib
            ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.getVersion pkgs.clang}/include -isystem ${pkgs.glibc.dev}/include";
            PKG_CONFIG_PATH = "${pkgs.sqlite.dev}/lib/pkgconfig";

            prePatch = ''
              mkdir -p vendor
              cp -r ${sqlite-zstd} vendor/sqlite-zstd
              cp -r ${sqlite-regex} vendor/sqlite-regex
              cp -r ${sqlite-loadable-rs} vendor/sqlite-loadable-rs
              chmod -R +w vendor/
            '';

            postPatch = ''
              sed -i 's|../../vendor/|./vendor/|g' Cargo.toml

              cat > vendor/sqlite-regex/build.rs <<'EOF'
              fn main() {
                  println!("cargo:rustc-env=GIT_HASH={}", 
                           std::env::var("GIT_HASH").unwrap_or_else(|_| "unknown".to_string()));
              }
              EOF

              sed -i 's/crate-type.*/crate-type = ["rlib"]/' vendor/sqlite-zstd/Cargo.toml
              sed -i 's/features = \["functions".*/features = ["functions", "blob", "array"]/' vendor/sqlite-zstd/Cargo.toml
              sed -i '/log::info!/d' vendor/sqlite-zstd/src/create_extension.rs

              sed -i 's/crate-type.*/crate-type = ["rlib"]/' vendor/sqlite-regex/Cargo.toml
              sed -i 's|sqlite-loadable.*|sqlite-loadable = { path = "../../vendor/sqlite-loadable-rs"}|' vendor/sqlite-regex/Cargo.toml
              sed -i 's/scalar_function_raw(\([^)]*\))\([^.]\)/scalar_function_raw(\1).0\2/g' vendor/sqlite-regex/src/captures.rs

              sed -i 's/crate-type.*/crate-type = ["rlib"]/' vendor/sqlite-loadable-rs/Cargo.toml
              sed -i 's/bundled//g' vendor/sqlite-loadable-rs/Cargo.toml
            '';

            postInstall = ''
              mkdir -p $out/lib
              cp target/*/release/libsqlite_bundle.a $out/lib/
            '';
          };

        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "clogite";
            version = "0.0.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig.hook ];

            buildInputs = [
              pkgs.sqlite.dev
              sqlite-bundle
            ];

            preBuild = ''
              export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
              mkdir -p $ZIG_GLOBAL_CACHE_DIR
            '';

            zigBuildFlags = [
              "--system"
              "${zig-deps}"
              "-Dskip-rust=true"
              "-Dbundle-lib-path=${sqlite-bundle}/lib"
            ];
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              zig
              cargo
              rustc
              rustPlatform.rustLibSrc
              sqlite.dev
              git
              clang-tools
              llvmPackages.libclang.lib
              zon2nix
            ];
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.getVersion pkgs.clang}/include -isystem ${pkgs.glibc.dev}/include";
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
            PKG_CONFIG_PATH = "${pkgs.sqlite.dev}/lib/pkgconfig";
          };
        }
      );
    };
}
