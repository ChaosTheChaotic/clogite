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
  };

  outputs = { self, nixpkgs, sqlite-zstd, sqlite-regex }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

	  zig-deps = pkgs.callPackage ./deps.nix { };

          sqlite-zstd-lib = pkgs.rustPlatform.buildRustPackage {
            pname = "sqlite-zstd";
            version = "git";
            src = sqlite-zstd;
            
            cargoLock = {
              lockFile = "${sqlite-zstd}/Cargo.lock";
              allowBuiltinFetchGit = true;
            };

	    doCheck = false;

	    nativeBuildInputs = with pkgs; [
	      git
	      sqlite
	      pkg-config
	    ];

	    buildInputs = with pkgs; [
	      sqlite
              clang-tools
              llvmPackages.libclang.lib
	    ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.getVersion pkgs.clang}/include -isystem ${pkgs.glibc.dev}/include";
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

            postPatch = ''
              sed -i 's/crate-type = \["cdylib"\]/crate-type = ["staticlib", "cdylib"]/' Cargo.toml
              sed -i '/log::info/d' src/create_extension.rs
            '';

            buildFeatures = [ "build_extension" ];

            postInstall = ''
              mkdir -p $out/lib
              cp target/*/release/libsqlite_zstd.* $out/lib/
            '';
          };

          sqlite-regex-lib = pkgs.rustPlatform.buildRustPackage {
            pname = "sqlite-regex";
            version = "git";
            src = sqlite-regex;

            cargoLock = {
              lockFile = "${sqlite-regex}/Cargo.lock";
              allowBuiltinFetchGit = true;
            };

	    doCheck = false;

	    nativeBuildInputs = with pkgs; [
	      git
	      sqlite
	      pkg-config
	    ];

	    buildInputs = with pkgs; [
	      sqlite
              clang-tools
              llvmPackages.libclang.lib
	    ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.getVersion pkgs.clang}/include -isystem ${pkgs.glibc.dev}/include";
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

            postPatch = ''
	      if [ -f build.rs ]; then
		echo 'fn main() { println!("cargo:rustc-env=GIT_HASH=${sqlite-regex.rev or "unknown"}"); }' > build.rs
	      fi
              sed -i 's/crate-type =/crate-type = ["staticlib", "cdylib"]/' Cargo.toml
            '';

            postInstall = ''
              mkdir -p $out/lib
              cp target/*/release/libsqlite_regex.* $out/lib/
            '';
          };

        in {
          default = pkgs.stdenv.mkDerivation {
            pname = "clogite";
            version = "0.0.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig.hook ];
            
            buildInputs = [
              pkgs.sqlite
              sqlite-zstd-lib
              sqlite-regex-lib
            ];

	    preBuild = ''
	      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
	      mkdir -p $ZIG_GLOBAL_CACHE_DIR/p
	      cp -rL ${zig-deps}/* $ZIG_GLOBAL_CACHE_DIR/p/
	      chmod -R +w $ZIG_GLOBAL_CACHE_DIR/p/
	    '';

            zigBuildFlags = [
              "-Dsqlite-zstd-lib-path=${sqlite-zstd-lib}/lib"
              "-Dsqlite-regex-lib-path=${sqlite-regex-lib}/lib"
            ];
          };
        }
      );

      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              zig
              cargo
              rustc
              rustPlatform.rustLibSrc
              sqlite
              git
              clang-tools
              llvmPackages.libclang.lib
	      zon2nix
            ];
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.llvmPackages.libclang.lib}/lib/clang/${pkgs.lib.getVersion pkgs.clang}/include -isystem ${pkgs.glibc.dev}/include";
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          };
        }
      );
    };
}
