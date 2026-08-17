#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname -- "$(readlink -f -- "$BASH_SOURCE")" )" >/dev/null 2>&1 && pwd -P )"

INSTALL_DIR="$HOME/.local/share/clogite"

mkdir -p "$INSTALL_DIR"

cd "$SCRIPT_DIR"
zig build --release --prefix "$INSTALL_DIR"

echo "Installed to $INSTALL_DIR. Add $INSTALL_DIR/bin to your PATH."
