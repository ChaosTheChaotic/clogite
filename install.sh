#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname -- "$(readlink -f -- "$BASH_SOURCE")" )" >/dev/null 2>&1 && pwd -P )"

INSTALL_DIR="$HOME/.local/share/clogite"
LIB_DIR="$INSTALL_DIR/lib"

mkdir -p "$LIB_DIR"

git clone --depth 1 https://github.com/asg017/sqlite-regex /tmp/sqlite-regex
cd /tmp/sqlite-regex
cargo build --release
cp target/release/libsqlite_regex.so "$LIB_DIR/"

cd "$SCRIPT_DIR"
zig build --release -Dsqlite-regex-lib-path="$LIB_DIR" --prefix "$INSTALL_DIR"

echo "Installed to $INSTALL_DIR. Add $INSTALL_DIR/bin to your PATH."
