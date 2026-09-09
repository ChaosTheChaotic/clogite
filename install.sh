#!/usr/bin/env bash

SCRIPT_DIR="$( cd "$( dirname -- "$(readlink -f -- "$BASH_SOURCE")" )" >/dev/null 2>&1 && pwd -P )"

INSTALL_DIR="$HOME/.local/share/clogite"

if command -v nix &>/dev/null; then
	echo "Notice: Nix is installed on this system. You might prefer using the provided flake modules."
	echo "You have 3 seconds to ctrl+c if you want to cancel"
	sleep 3
	echo "Continuing with standard Zig build..."
	echo
fi

mkdir -p "$INSTALL_DIR"

cd "$SCRIPT_DIR" || exit 1
zig build --release --prefix "$INSTALL_DIR"

echo "Installed to $INSTALL_DIR. Add $INSTALL_DIR/bin to your PATH and init it in ~/.zshrc."
echo "export PATH=$INSTALL_DIR/bin:\$PATH"
echo "eval \"$(clogite init false true)\""
echo "'false' 'true' as args disables the zsh HISTFILE and enables the integration for zsh autosuggestions to be used from the clogite db"
