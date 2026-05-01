#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="${CODEX_GUI_APP_DIR:-$SCRIPT_DIR/codex-app}"
WRAPPER_PATH="$SCRIPT_DIR/scripts/codex-gui-cli-wrapper.sh"
INTERNAL_LAUNCHER_PATH="$APP_DIR/.codex-linux/start-internal.sh"

usage() {
    cat <<'HELP'
Usage: ./run-codex-gui.sh [OPTIONS] [-- ELECTRON_FLAGS...]

Launch Codex Desktop locally in GUI-lite mode.

Options:
  --update        Download the latest upstream Codex.dmg and rebuild codex-app/
  --update-only   Download the latest upstream Codex.dmg, rebuild, then exit
  --rebuild       Rebuild codex-app/ from the cached Codex.dmg
  --rebuild-only  Rebuild from the cached Codex.dmg, then exit
  -h, --help      Show this help message and exit

Environment:
  CODEX_GUI_SESSION_HOME            Real Codex home to seed from and sync session DB to (default: ~/.codex)
  CODEX_GUI_ELECTRON_HOME           Use a fixed private Electron Codex home instead of a per-launch home
  CODEX_GUI_ELECTRON_RUNTIME_PARENT Parent for per-launch private Electron homes
  CODEX_GUI_RUNTIME_PARENT          Parent for per-launch private app-server homes
  CODEX_GUI_RUNTIME_HOME            Use a fixed private app-server home instead of per-launch homes
  CODEX_GUI_SYNC_GLOBAL_STATE=0     Do not copy .codex-global-state.json* back after GUI exit
  CODEX_GUI_REAL_HOME_AUDIT=warn    Audit real Codex home writes after launch (warn, fail, or 0)
  CODEX_GUI_LITE_MODE=0             Disable GUI-lite app-server proxying
  CODEX_GUI_DEFAULT_DISABLE_FEATURES Default app-server feature disables for GUI-lite
  CODEX_GUI_EXTRA_DISABLE_FEATURES  Optional Codex feature flags to disable for app-server
  CODEX_REAL_CLI_PATH=/path/codex   Use a specific Codex CLI binary
HELP
}

resolve_real_codex() {
    local candidate=""

    if [ -n "${CODEX_REAL_CLI_PATH:-}" ] && [ -x "$CODEX_REAL_CLI_PATH" ]; then
        echo "$CODEX_REAL_CLI_PATH"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        candidate="$(command -v codex)"
        if [ "$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")" != "$(readlink -f "$WRAPPER_PATH" 2>/dev/null || echo "$WRAPPER_PATH")" ]; then
            echo "$candidate"
            return 0
        fi
    fi

    for candidate in \
        "$HOME/.local/bin/codex" \
        "$HOME/.nvm/versions/node/current/bin/codex" \
        "$HOME/.nvm/versions/node"/*/bin/codex \
        "$HOME/.local/share/pnpm/codex" \
        "$HOME/.local/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "$candidate" ] && [ "$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")" != "$(readlink -f "$WRAPPER_PATH" 2>/dev/null || echo "$WRAPPER_PATH")" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

safe_realpath() {
    local path="$1"
    realpath -m "$path" 2>/dev/null || echo "$path"
}

path_is_same_or_within() {
    local candidate parent
    candidate="$(safe_realpath "$1")"
    parent="$(safe_realpath "$2")"

    [ "$candidate" = "$parent" ] && return 0
    [ "$parent" = "/" ] && return 0

    case "$candidate" in
        "$parent"/*) return 0 ;;
        *) return 1 ;;
    esac
}

require_private_codex_home() {
    local label="$1"
    local candidate="$2"

    if path_is_same_or_within "$candidate" "$CODEX_GUI_SESSION_HOME"; then
        echo "[run-codex-gui] Refusing to use $label inside the real Codex home: $candidate" >&2
        echo "[run-codex-gui] Set $label to a separate private runtime path outside $CODEX_GUI_SESSION_HOME." >&2
        exit 1
    fi
}

make_electron_home() {
    if [ -n "${CODEX_GUI_ELECTRON_HOME:-}" ]; then
        require_private_codex_home "CODEX_GUI_ELECTRON_HOME" "$CODEX_GUI_ELECTRON_HOME"
        mkdir -p "$CODEX_GUI_ELECTRON_HOME"
        chmod 700 "$CODEX_GUI_ELECTRON_HOME" 2>/dev/null || true
        echo "$CODEX_GUI_ELECTRON_HOME"
        return 0
    fi

    local parent="${CODEX_GUI_ELECTRON_RUNTIME_PARENT:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-gui/electron}"
    require_private_codex_home "CODEX_GUI_ELECTRON_RUNTIME_PARENT" "$parent"
    mkdir -p "$parent"
    chmod 700 "${parent%/codex-gui/electron}" "${parent%/electron}" "$parent" 2>/dev/null || true
    mktemp -d "$parent/run.XXXXXX"
}

seed_private_codex_home() {
    local source_home="$1"
    local target_home="$2"

    [ "${CODEX_GUI_SEED_SESSION_HOME:-1}" = "1" ] || return 0
    [ -d "$source_home" ] || return 0

    local source_real target_real
    source_real="$(safe_realpath "$source_home")"
    target_real="$(safe_realpath "$target_home")"
    [ "$source_real" != "$target_real" ] || {
        echo "[run-codex-gui] Refusing to use the real Codex home as the private Electron CODEX_HOME: $target_home" >&2
        echo "[run-codex-gui] Set CODEX_GUI_ELECTRON_HOME to a separate directory or unset it for a per-launch private home." >&2
        exit 1
    }

    if [ "${CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS:-0}" = "1" ]; then
        if ! cp -a "$source_home"/. "$target_home"/ 2>/dev/null; then
            echo "[run-codex-gui] warning: failed to seed private Electron CODEX_HOME from $source_home" >&2
        fi
        return 0
    fi

    if ! (
        cd "$source_home"
        tar \
            --exclude='./skills/.system' \
            --exclude='./skills/.system/*' \
            --exclude='./.tmp/plugins' \
            --exclude='./.tmp/plugins/*' \
            --exclude='./.tmp/plugins.sha' \
            --exclude='./plugins/cache' \
            --exclude='./plugins/cache/*' \
            --exclude='./vendor_imports' \
            --exclude='./vendor_imports/*' \
            -cpf - .
    ) | (
        cd "$target_home"
        tar -xpf -
    ) 2>/dev/null; then
        echo "[run-codex-gui] warning: failed to seed private Electron CODEX_HOME from $source_home" >&2
    fi
}

sync_electron_global_state_back() {
    [ "${CODEX_GUI_SYNC_GLOBAL_STATE:-1}" = "1" ] || return 0
    [ -n "${CODEX_HOME:-}" ] || return 0
    [ -d "$CODEX_HOME" ] || return 0
    [ -n "${CODEX_GUI_SESSION_HOME:-}" ] || return 0

    mkdir -p "$CODEX_GUI_SESSION_HOME"

    local state_file
    for state_file in \
        "$CODEX_HOME/.codex-global-state.json" \
        "$CODEX_HOME/.codex-global-state.json.bak"
    do
        [ -f "$state_file" ] || continue
        if ! cp -p "$state_file" "$CODEX_GUI_SESSION_HOME/${state_file##*/}" 2>/dev/null; then
            echo "[run-codex-gui] warning: failed to sync ${state_file##*/} back to $CODEX_GUI_SESSION_HOME" >&2
        fi
    done
}

real_home_audit_enabled() {
    case "${CODEX_GUI_REAL_HOME_AUDIT:-warn}" in
        0|false|False|FALSE|off|Off|OFF|no|No|NO)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

snapshot_real_session_home() {
    local output="$1"

    if [ ! -d "$CODEX_GUI_SESSION_HOME" ]; then
        : >"$output"
        return 0
    fi

    (
        cd "$CODEX_GUI_SESSION_HOME"
        LC_ALL=C find . -type f -printf '%P\t%s\t%T@\n' | LC_ALL=C sort
    ) >"$output"
}

audit_real_session_home() {
    real_home_audit_enabled || return 0

    local before="$1"
    [ -f "$before" ] || return 0

    local after
    after="$(mktemp "${TMPDIR:-/tmp}/codex-gui-real-home-after.XXXXXX")"
    snapshot_real_session_home "$after"

    local unexpected
    unexpected="$(
        comm -3 "$before" "$after" | awk -F '\t' '
            {
                line = $0
                sub(/^\t/, "", line)
                path = line
                sub(/\t.*/, "", path)
                if (
                    path != "state_5.sqlite" &&
                    path != "state_5.sqlite-shm" &&
                    path != "state_5.sqlite-wal" &&
                    path != ".codex-global-state.json" &&
                    path != ".codex-global-state.json.bak"
                ) {
                    print path
                }
            }
        ' | LC_ALL=C sort -u
    )"

    rm -f "$after"

    if [ -z "$unexpected" ]; then
        echo "[run-codex-gui] real Codex home audit passed; only allowlisted state files changed." >&2
        return 0
    fi

    echo "[run-codex-gui] WARNING: real Codex home changed outside the allowlist during GUI run:" >&2
    sed 's/^/[run-codex-gui]   /' <<<"$unexpected" >&2
    echo "[run-codex-gui] Allowed real-home writes are state_5.sqlite* and .codex-global-state.json*." >&2
    echo "[run-codex-gui] No files were deleted or pruned by this audit." >&2

    case "${CODEX_GUI_REAL_HOME_AUDIT:-warn}" in
        fail|strict)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

rebuild_app() {
    local mode="$1"

    case "$mode" in
        latest)
            "$SCRIPT_DIR/build-codex-gui.sh" --fresh
            ;;
        cached)
            "$SCRIPT_DIR/build-codex-gui.sh" --fresh --reuse-dmg
            ;;
        missing)
            "$SCRIPT_DIR/build-codex-gui.sh" --reuse-dmg
            ;;
        *)
            echo "[run-codex-gui] internal error: unknown rebuild mode $mode" >&2
            exit 1
            ;;
    esac
}

launch_args=()
launch_after_build=1
while [ $# -gt 0 ]; do
    case "$1" in
        --update)
            rebuild_app latest
            ;;
        --update-only)
            rebuild_app latest
            launch_after_build=0
            ;;
        --rebuild)
            rebuild_app cached
            ;;
        --rebuild-only)
            rebuild_app cached
            launch_after_build=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            launch_args+=("$@")
            break
            ;;
        *)
            launch_args+=("$1")
            ;;
    esac
    shift || true
done

if [ "$launch_after_build" -eq 0 ]; then
    exit 0
fi

if [ -e "$APP_DIR/start.sh" ]; then
    echo "[run-codex-gui] Found stale top-level codex-app/start.sh; rebuilding generated app." >&2
    rebuild_app cached
elif [ ! -x "$INTERNAL_LAUNCHER_PATH" ]; then
    rebuild_app missing
fi

if ! real_codex="$(resolve_real_codex)"; then
    echo "[run-codex-gui] Codex CLI not found. This launcher will not install it automatically." >&2
    echo "[run-codex-gui] Put a compatible codex binary in PATH or set CODEX_REAL_CLI_PATH." >&2
    exit 1
fi

export CODEX_REAL_CLI_PATH="$real_codex"
export CODEX_CLI_PATH="$WRAPPER_PATH"
export CODEX_CLI_PRESERVE_PATH=1
export CODEX_GUI_SESSION_HOME="${CODEX_GUI_SESSION_HOME:-${CODEX_GUI_CODEX_HOME:-$HOME/.codex}}"
export CODEX_GUI_LITE_MODE="${CODEX_GUI_LITE_MODE:-1}"
export CODEX_GUI_INTERNAL_LAUNCH=1

mkdir -p "$CODEX_GUI_SESSION_HOME"

launcher_codex_home="$(make_electron_home)"
export CODEX_HOME="$launcher_codex_home"
export CODEX_GUI_ELECTRON_HOME="$launcher_codex_home"
seed_private_codex_home "$CODEX_GUI_SESSION_HOME" "$CODEX_HOME"

"$SCRIPT_DIR/scripts/verify-gui-lite-safety.sh" \
    "$APP_DIR" \
    --require-stamp \
    --runtime-smoke

real_home_snapshot_before=""
if real_home_audit_enabled; then
    real_home_snapshot_before="$(mktemp "${TMPDIR:-/tmp}/codex-gui-real-home-before.XXXXXX")"
    snapshot_real_session_home "$real_home_snapshot_before"
fi

finish_launch() {
    local status=$?
    local audit_status=0
    trap - EXIT
    sync_electron_global_state_back
    if [ -n "$real_home_snapshot_before" ]; then
        audit_real_session_home "$real_home_snapshot_before" || audit_status=$?
        rm -f "$real_home_snapshot_before"
    fi
    if [ "$audit_status" -ne 0 ]; then
        exit "$audit_status"
    fi
    exit "$status"
}

trap finish_launch EXIT
"$INTERNAL_LAUNCHER_PATH" "${launch_args[@]}"
