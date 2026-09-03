#!/usr/bin/env bash
# build-and-install.sh — Build swift-package-utilitykit binaries and install them.
#
# Usage:
#   ./scripts/build-and-install.sh              debug build, install to ~/.local/bin
#   ./scripts/build-and-install.sh --release     release build, install to ~/.local/bin
#   PREFIX=/opt/tools ./scripts/build-and-install.sh
#   ./scripts/build-and-install.sh --no-path-update   skip harness PATH wiring
#
# After installing, the install dir is wired into the harness PATH via
# scripts/path-wire.sh so fresh harness sessions find the binaries by name.
#
# The two binaries produced are:
#   swift-package-tool   — query, inspect, and format Swift source code (agentic)
#   normalizer-tool    — normalize/minify file syntax (also used by the SPM plugin)

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-$HOME/.local}"
RELEASE=false
VERBOSE=false
PATH_UPDATE="${PATH_UPDATE:-1}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release|-r)  RELEASE=true ;;
        --verbose|-v)  VERBOSE=true ;;
        --prefix=*)    PREFIX="${1#*=}" ;;
        --no-path-update) PATH_UPDATE=0 ;;
        --help|-h)     sed -n '2,14p' "$0"; exit 0 ;;
        *)             echo "unknown: $1"; exit 1 ;;
    esac
    shift
done

CONFIG="debug"
BUILD_DIR=".build/debug"
if $RELEASE; then
    CONFIG="release"
    BUILD_DIR=".build/release"
fi

echo "==> swift build -c $CONFIG"
if $VERBOSE; then
    swift build -c "$CONFIG"
else
    swift build -c "$CONFIG" 2>&1 | tail -3
fi

echo "==> install to $PREFIX/bin"
install -d "$PREFIX/bin"
for bin in swift-package-tool normalizer-tool; do
    install "$BUILD_DIR/$bin" "$PREFIX/bin/$bin"
    echo "    $PREFIX/bin/$bin"
done

if [ "$PATH_UPDATE" = "1" ]; then
    echo "==> wiring $PREFIX/bin into harness PATH"
    scripts/path-wire.sh "$PREFIX/bin"
else
    echo "==> skipping PATH wiring (PATH_UPDATE=0)"
fi

echo "==> done.  binaries installed in $PREFIX/bin"
