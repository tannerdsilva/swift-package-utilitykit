#!/usr/bin/env bash
# path-wire.sh — Make an install directory permanently discoverable on the
# agentic-harness PATH by writing an idempotent, marker-guarded `export PATH`
# line into the shell init files the harness sources.
#
# Motivation: agent harnesses (Hermes and friends) build their terminal
# environment from a *login* bash that sources ~/.profile, ~/.bash_profile,
# and ~/.bashrc (whichever exist), NOT from interactive zsh rc files.  A plain
# `install` of a binary into ~/.local/bin is therefore invisible to the
# harness unless the install dir is also wired into one of those files.  This
# script does that wiring for the calling installer, so "install the tool" is
# sufficient — no manual "add it to your PATH" step that gets forgotten.
#
# Usage:
#   path-wire.sh <dir>              add <dir> to harness PATH (idempotent)
#   path-wire.sh --remove           strip every swift-package-utilitykit PATH block
#   path-wire.sh --remove --dir <dir>
#                                   strip only blocks that export <dir>
#
# Behavior:
#   * Always considers ~/.profile, creating it if missing — that is THE file a
#     login bash reads on macOS and the first file a Hermes login-shell
#     snapshot sources.
#   * Appends to ~/.bash_profile / ~/.bashrc / ~/.zshrc only when the file
#     already exists.
#   * Skips a file that already exports <dir> (marker block OR a bare PATH
#     export containing the dir) so re-runs never duplicate.
#   * Writes the export under a `# >>> swift-package-utilitykit >>>` /
#     `# <<< swift-package-utilitykit <<<` marker block; --remove strips only
#     that block and preserves everything else in the file.
#   * Uses a $HOME-relative path in the export when <dir> is under $HOME so
#     the wiring survives the home directory moving.
#
# Env:
#   PATH_WIRE_SKIP=1   no-op (for callers that manage PATH themselves)

set -euo pipefail

MARKER_HEAD='# >>> swift-package-utilitykit >>> PATH (managed by scripts/path-wire.sh, do not edit)'
MARKER_TAIL='# <<< swift-package-utilitykit <<<'

info() { printf "\033[36m  ==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[32m  OK\033[0m  %s\n" "$*"; }
warn() { printf "\033[33m  WARN\033[0m %s\n" "$*"; }

# ---- arg parsing ------------------------------------------------------------

MODE="add"          # add | remove
DIR=""
REMOVE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove|-r) MODE="remove"; shift ;;
        --dir)       REMOVE_DIR="$2"; shift 2 ;;
        --help|-h)   sed -n '2,38p' "$0"; exit 0 ;;
        -*)
            printf "path-wire.sh: unknown option: %s\n" "$1" >&2
            exit 1
            ;;
        *) DIR="$1"; shift ;;
    esac
done

# ---- helpers ----------------------------------------------------------------

# Files a bash login shell / harness snapshot reads, in source order.
# ~/.profile is always included (created when missing); the rest are only
# touched when they already exist on disk.
candidates() {
    local home="${HOME:-}"
    [[ -n "$home" ]] || home="$(cd ~ && pwd)"
    printf '%s\n' "$home/.profile"
    for f in .bash_profile .bashrc .zshrc; do
        [[ -f "$home/$f" ]] && printf '%s\n' "$home/$f"
    done
    return 0
}

# $HOME-relative form of a dir when possible (keeps wiring portable).
export_dir_value() {
    local dir="$1" home="${HOME:-}"
    home="$(cd ~ && pwd 2>/dev/null || true)"
    if [[ -n "$home" && "$dir" == "$home"/* ]]; then
        printf '$HOME/%s' "${dir#"$home"/}"
    else
        printf '%s' "$dir"
    fi
}

# Does the file already reference $1 in a PATH export, or carry our marker?
already_wired() {
    local file="$1" dir="$2" home="${HOME:-}"
    home="$(cd ~ && pwd 2>/dev/null || true)"
    local portable="$dir"
    [[ -n "$home" && "$dir" == "$home"/* ]] && portable="\$HOME/${dir#"$home"/}"
    grep -Fq -- "$MARKER_HEAD" "$file" && return 0
    grep -Fq -- "$dir"       "$file" && return 0
    grep -Fq -- "$portable"  "$file" && return 0
    return 1
}

# ---- add --------------------------------------------------------------------

do_add() {
    local dir="$1"

    # Already on the live PATH?  Nothing to persist.
    case ":$PATH:" in
        *":$dir:"*) info "  already on PATH: $dir"; return 0 ;;
    esac

    info "wiring $dir into harness PATH..."

    local value
    value="$(export_dir_value "$dir")"
    local changed=0

    for file in $(candidates); do
        if [[ ! -f "$file" ]]; then
            if ! touch "$file" 2>/dev/null; then
                warn "cannot create $file — skipping"
                continue
            fi
        fi
        if already_wired "$file" "$dir"; then
            continue
        fi
        if ! [[ -w "$file" ]]; then
            warn "not writable: $file — skipping"
            continue
        fi
        {
            printf '\n%s\n' "$MARKER_HEAD"
            printf 'export PATH="%s:$PATH"\n' "$value"
            printf '%s\n' "$MARKER_TAIL"
        } >> "$file"
        ok "  $file"
        changed=1
    done

    if [[ "$changed" == "1" ]]; then
        echo ""
        ok "PATH wired. New harness sessions (and login shells) will find the tools."
        echo "    A restart of the harness — or a new session — picks this up automatically."
    else
        info "  nothing to change (dir already exported or file set empty)"
    fi
}

# ---- remove -----------------------------------------------------------------

do_remove() {
    local only_dir="$1"
    local found=0

    for file in $(candidates); do
        [[ -f "$file" ]] || continue
        if grep -Fq -- "$MARKER_HEAD" "$file"; then
            # Optionally restrict to blocks exporting a specific dir: check
            # every line between the markers.
            if [[ -n "$only_dir" ]]; then
                if ! grep -Fq -- "$only_dir" "$file"; then
                    continue
                fi
            fi
            found=1
            local tmp
            tmp="$(mktemp "${file}.pathwire.XXXXXX")"
            if awk -v h="$MARKER_HEAD" -v t="$MARKER_TAIL" '
                    index($0, h) == 1 { skip = 1; next }
                    skip && index($0, t) == 1 { skip = 0; next }
                    skip { next }
                    { print }
                ' "$file" > "$tmp"; then
                mv "$tmp" "$file"
                ok "  stripped PATH block from $file"
            else
                rm -f "$tmp"
                warn "failed to edit $file — leaving untouched"
            fi
        fi
    done

    if [[ "$found" == "1" ]]; then
        echo ""
        info "PATH wiring removed."
    else
        info "no swift-package-utilitykit PATH wiring found."
    fi
}

# ---- dispatch ---------------------------------------------------------------

[[ "${PATH_WIRE_SKIP:-0}" == "1" ]] && exit 0

case "$MODE" in
    add)
        [[ -n "$DIR" ]] || { echo "path-wire.sh: missing <dir> argument" >&2; exit 1; }
        do_add "$DIR"
        ;;
    remove)
        do_remove "$REMOVE_DIR"
        ;;
esac
