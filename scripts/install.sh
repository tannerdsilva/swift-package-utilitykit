#!/usr/bin/env bash
# install.sh — One-command install/remove of swift-package-utilitykit.
#
# Builds release binaries, installs them to PREFIX/bin, and installs the Hermes
# plugin into ~/.hermes/plugins/ (either as a symlink or a copy).
#
# Usage:
#   ./scripts/install.sh                    interactive install (prompts for everything)
#   ./scripts/install.sh --remove           interactive removal
#   ./scripts/install.sh --symlink          noninteractive, symlink plugin (PLUGIN_MODE=symlink)
#   ./scripts/install.sh --copy             noninteractive, copy plugin (PLUGIN_MODE=copy)
#   ./scripts/install.sh --remove --force   noninteractive removal (no prompt)
#
# Variants:
#   --debug              build + install debug binaries (default: release)
#   --no-plugin          skip the Hermes plugin entirely
#   --no-interactive     never prompt, even on a tty (for CI / make delegation)
#
# Notes:
#   --symlink / --copy (or PLUGIN_MODE env) are REQUIRED in noninteractive mode.
#   In interactive mode the prompt handles this; the flags are ignored.
#
# This script is the single source of truth for install/remove maintenance
# operations; the Makefile's install/install-release/install-plugin/remove
# targets are thin delegates that map their knobs onto these flags.
#
# Options (via env vars):
#   PREFIX=/opt/homebrew    Parent directory for binaries (default: ~/.local)
#   BIN_DIR=/opt/bin        Exact binary install path (overrides PREFIX/bin)
#   SWIFT_CODE_QUERY_PATH   Custom path for swift-package-tool binary
#   HERMES_PLUGINS_DIR      Custom Hermes plugins directory
#   PATH_UPDATE=0           Skip wiring the install dir into the harness PATH
#
# After installing binaries, the script wires the install dir into the
# harness PATH (idempotent, marker-guarded export in ~/.profile and any
# existing ~/.bash_profile / ~/.bashrc / ~/.zshrc) via scripts/path-wire.sh,
# so the tools are discoverable by name inside the agent harness.  Pass
# --no-path-update (or PATH_UPDATE=0) to skip this and manage PATH yourself.

set -euo pipefail

# ---- config -----------------------------------------------------------------

PREFIX="${PREFIX:-$HOME/.local}"
HERMES_PLUGINS_DIR="${HERMES_PLUGINS_DIR:-${HERMES_PLUGINS:-$HOME/.hermes/plugins}}"
PLUGIN_NAME="swift-package-utilitykit"
BINARIES="swift-package-tool normalizer-tool"
PATH_UPDATE="${PATH_UPDATE:-1}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd 2>/dev/null || echo "/tmp/swift-package-utilitykit")"
PLUGIN_SRC="$REPO_DIR/hermes-plugin"
PLUGIN_DST="$HERMES_PLUGINS_DIR/$PLUGIN_NAME"

# Resolve the actual binary install directory.
# BIN_DIR takes precedence; otherwise PREFIX/bin.
if [ -n "${BIN_DIR:-}" ]; then
    INSTALL_DIR="$BIN_DIR"
else
    INSTALL_DIR="$PREFIX/bin"
fi

# ---- parse flags ------------------------------------------------------------

MODE="install"             # install | remove
BUILD_CONFIG="release"     # release | debug
PLUGIN=1                   # 1 = install Hermes plugin, 0 = --no-plugin
NO_INTERACTIVE=0           # 1 = --no-interactive
PLUGIN_MODE="${PLUGIN_MODE:-}"   # symlink | copy  (empty = prompt in interactive)
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove|-r)          MODE="remove"; shift ;;
        --symlink|-s)         PLUGIN_MODE="symlink"; shift ;;
        --copy|-c)            PLUGIN_MODE="copy"; shift ;;
        --force|-f)           FORCE=1; shift ;;
        --debug)              BUILD_CONFIG="debug"; shift ;;
        --no-plugin)          PLUGIN=0; shift ;;
        --no-interactive)     NO_INTERACTIVE=1; shift ;;
        --no-path-update|-n)  PATH_UPDATE=0; shift ;;
        --help|-h)
            sed -n '2,38p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ---- helpers ----------------------------------------------------------------

info()  { printf "\033[36m==>\033[0m %s\n" "$*"; }
ok()    { printf "\033[32m  OK\033[0m  %s\n" "$*"; }
warn()  { printf "\033[33m  WARN\033[0m %s\n" "$*"; }
fail()  { printf "\033[31m  FAIL\033[0m %s\n" "$*"; exit 1; }

is_interactive() {
    # True when stdin is a terminal AND no noninteractive mode was selected
    [ "$NO_INTERACTIVE" != "1" ] && \
    [ -t 0 ] && \
    [ "$PLUGIN_MODE" != "symlink" ] && [ "$PLUGIN_MODE" != "copy" ]
}

# ---- remove -----------------------------------------------------------------

do_remove() {
    info "Removing swift-package-utilitykit..."

    local found_bins=""
    local found_plugin=""

    # check multiple common install locations
    local remove_dirs="$INSTALL_DIR $HOME/.local/bin /usr/local/bin"
    if [ -n "${BIN_DIR:-}" ]; then
        remove_dirs="$BIN_DIR $remove_dirs"
    fi
    # collapse duplicates (default INSTALL_DIR == $HOME/.local/bin)
    remove_dirs="$(printf '%s\n' $remove_dirs | awk '!seen[$0]++' | tr '\n' ' ')"

    for d in $remove_dirs; do
        for bin in $BINARIES; do
            if [ -f "$d/$bin" ]; then
                found_bins="$found_bins $d/$bin"
            fi
        done
    done

    if [ -L "$PLUGIN_DST" ] || [ -d "$PLUGIN_DST" ]; then
        found_plugin="$PLUGIN_NAME"
    fi

    if [ -z "$found_bins" ] && [ -z "$found_plugin" ]; then
        info "Nothing to remove."
        exit 0
    fi

    info "Found: binaries(${found_bins:-none}) plugin(${found_plugin:-none})"

    if [ "$FORCE" != "1" ] && is_interactive; then
        printf "  Remove all? [y/N] "
        read -r _confirm
        case "$_confirm" in
            y|Y|yes|YES) :;;
            *) info "Cancelled."; exit 0;;
        esac
    fi

    for bin_path in $found_bins; do
        local dir
        dir=$(dirname "$bin_path")
        if [ ! -w "$dir" ] 2>/dev/null; then
            sudo rm -f "$bin_path"
            ok "Removed $bin_path (sudo)"
        else
            rm -f "$bin_path"
            ok "Removed $bin_path"
        fi
    done

    if [ -L "$PLUGIN_DST" ] || [ -d "$PLUGIN_DST" ]; then
        rm -rf "$PLUGIN_DST"
        ok "Removed $PLUGIN_DST"
    fi

    if [ "$PATH_UPDATE" = "1" ]; then
        info "Removing harness PATH wiring..."
        "$REPO_DIR/scripts/path-wire.sh" --remove || true
    fi

    info "Removal complete."
    exit 0
}

# ---- install ----------------------------------------------------------------

do_install() {
    info "Installing swift-package-utilitykit..."

    # ---- prerequisites ------------------------------------------------------

    info "Checking prerequisites..."

    # Swift toolchain
    if ! command -v swift &>/dev/null; then
        fail "Swift toolchain not found. Install Swift 6.0+ from https://swift.org/download/"
    fi
    SWIFT_VER=$(swift --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")
    SWIFT_MAJOR=${SWIFT_VER%%.*}
    if [ "$SWIFT_MAJOR" -lt 6 ] 2>/dev/null; then
        fail "Swift 6.0+ required (found $SWIFT_VER). Install from https://swift.org/download/"
    fi
    ok "Swift $SWIFT_VER toolchain found"

    # Hermes Agent (optional)
    if ! command -v hermes &>/dev/null; then
        warn "Hermes Agent not found in PATH. Install from https://hermes-agent.nousresearch.com/docs"
        warn "Plugin will be installed but won't be active until Hermes is available."
    else
        ok "Hermes Agent found"
    fi

    # ---- build --------------------------------------------------------------

    info "Building $BUILD_CONFIG binaries..."
    cd "$REPO_DIR"
    swift build -c "$BUILD_CONFIG" 2>&1 | tail -3
    ok "Build complete"

    # ---- install binaries ---------------------------------------------------

    info "Installing binaries to $INSTALL_DIR..."

    local SUDO_CMD=""
    # A missing INSTALL_DIR is not an error: walk up to the nearest existing
    # ancestor and escalate to sudo only when that ancestor isn't writable, so
    # a fresh machine with no ~/.local yet installs without a password prompt.
    local ancestor="$INSTALL_DIR"
    while [ "$ancestor" != "/" ] && [ ! -d "$ancestor" ]; do
        ancestor="$(dirname "$ancestor")"
    done
    if [ ! -w "$ancestor" ] 2>/dev/null; then
        SUDO_CMD="sudo"
        info "Using sudo for $INSTALL_DIR (not writable by current user)"
    fi

    if is_interactive; then
        printf "  Install binaries to $INSTALL_DIR? [Y/n] "
        read -r _confirm
        _confirm="${_confirm:-y}"
        case "$_confirm" in
            y|Y|yes|YES) :;;
            *) info "Cancelled."; exit 0;;
        esac
    fi

    $SUDO_CMD mkdir -p "$INSTALL_DIR"
    for bin in $BINARIES; do
        $SUDO_CMD install ".build/$BUILD_CONFIG/$bin" "$INSTALL_DIR/$bin"
        ok "  $INSTALL_DIR/$bin"
    done

    # ---- install plugin -----------------------------------------------------

    if [ "$PLUGIN" = "1" ]; then
        info "Installing Hermes plugin..."

        mkdir -p "$HERMES_PLUGINS_DIR"

        # Remove previous installation
        if [ -L "$PLUGIN_DST" ] || [ -d "$PLUGIN_DST" ]; then
            rm -rf "$PLUGIN_DST"
            ok "  Removed previous plugin at $PLUGIN_DST"
        fi

        # Determine plugin mode
        local mode=""
        if is_interactive; then
            # Interactive: prompt always, ignore PLUGIN_MODE env var
            while true; do
                printf "  Install plugin as [s]ymlink or [c]opy? [S/c] "
                read -r _choice
                _choice="${_choice:-s}"
                case "$_choice" in
                    s|S|symlink) mode="symlink"; break;;
                    c|C|copy)    mode="copy";   break;;
                esac
            done
        else
            # Noninteractive: PLUGIN_MODE is required and must be valid
            if [ -z "$PLUGIN_MODE" ]; then
                fail "PLUGIN_MODE is required in noninteractive mode. Set PLUGIN_MODE=symlink or PLUGIN_MODE=copy."
            fi
            case "$PLUGIN_MODE" in
                symlink|copy) mode="$PLUGIN_MODE";;
                *) fail "PLUGIN_MODE must be symlink or copy (got '$PLUGIN_MODE').";;
            esac
        fi

        if [ "$mode" = "symlink" ]; then
            ln -sf "$PLUGIN_SRC" "$PLUGIN_DST"
            ok "  Plugin symlinked: $PLUGIN_DST -> $PLUGIN_SRC"
        else
            cp -R "$PLUGIN_SRC" "$PLUGIN_DST"
            ok "  Plugin copied: $PLUGIN_SRC -> $PLUGIN_DST"
        fi
    else
        info "Skipping Hermes plugin (--no-plugin)..."
    fi

    # ---- wire install dir into harness PATH -------------------------------

    if [ "$PATH_UPDATE" = "1" ]; then
        local _path_confirm="y"
        if is_interactive; then
            printf "  Add $INSTALL_DIR to the harness PATH (writes shell rc files)? [Y/n] "
            read -r _path_confirm
            _path_confirm="${_path_confirm:-y}"
        fi
        case "$_path_confirm" in
            y|Y|yes|YES)
                info "Wiring $INSTALL_DIR into the harness PATH..."
                "$REPO_DIR/scripts/path-wire.sh" "$INSTALL_DIR"
                ;;
            *) warn "PATH wiring skipped. Add $INSTALL_DIR to your shell PATH manually." ;;
        esac
    else
        warn "PATH wiring skipped (PATH_UPDATE=0). Add $INSTALL_DIR to your shell PATH manually."
    fi

    # Let this process resolve the just-installed binaries (the rc wiring only
    # affects fresh shells), so verification below reflects the final state.
    export PATH="$INSTALL_DIR:$PATH"

    # ---- verify -------------------------------------------------------------

    info "Verifying installation..."

    if command -v swift-package-tool &>/dev/null; then
        VER=$(swift-package-tool --version 2>&1)
        ok "  swift-package-tool $VER"
    else
        warn "  swift-package-tool not found in PATH. Add $INSTALL_DIR to your PATH."
    fi

    if [ "$PLUGIN" = "1" ] && command -v hermes &>/dev/null; then
        if hermes plugin list 2>/dev/null | grep -q "$PLUGIN_NAME"; then
            ok "  Hermes plugin registered"
        else
            warn "  Plugin installed but not yet registered. Run: hermes plugin reload"
        fi
    fi

    # ---- done ---------------------------------------------------------------

    echo ""
    printf "\033[32m✓ Installation complete!\033[0m\n"
    echo ""
    echo "  Binaries:  $INSTALL_DIR/{swift-package-tool,normalizer-tool}"
    if [ "$PLUGIN" = "1" ]; then
        echo "  Plugin:    $PLUGIN_DST ($mode)"
    else
        echo "  Plugin:    (skipped — --no-plugin)"
    fi
    echo ""
    echo "  Next steps:"
    echo "    1. Restart Hermes or start a new shell so the wired PATH takes effect"
    echo "    2. Restart Hermes or run:  hermes plugin reload"
    echo "    3. Verify tools:           swift-package-tool --version"
    echo "    4. Test plugin:            hermes tool list | grep pkg_"
    echo ""
    echo "  The install directory was wired into the harness PATH automatically"
    echo "  (PATH_UPDATE=1). Fresh harness sessions and login shells will find the"
    echo "  binaries by name. Run ./scripts/install.sh --no-path-update to opt out."
    echo ""
}

# ---- dispatch ---------------------------------------------------------------

case "$MODE" in
    remove)  do_remove ;;
    install) do_install ;;
esac
