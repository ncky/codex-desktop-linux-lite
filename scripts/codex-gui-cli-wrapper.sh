#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
PROXY_PATH="$SCRIPT_DIR/codex-gui-appserver-proxy.mjs"
LOCKED_SKILLS_DIR=""
ORIGINAL_SKILLS_MODE=""

resolve_real_codex() {
    local candidate=""

    if [ -n "${CODEX_REAL_CLI_PATH:-}" ] && [ -x "$CODEX_REAL_CLI_PATH" ]; then
        echo "$CODEX_REAL_CLI_PATH"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        candidate="$(command -v codex)"
        if [ "$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")" != "$SELF_PATH" ]; then
            echo "$candidate"
            return 0
        fi
    fi

    for candidate in \
        "$HOME/.local/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "$candidate" ] && [ "$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")" != "$SELF_PATH" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

feature_list() {
    "$REAL_CODEX" features list 2>/dev/null || true
}

feature_supported() {
    local feature="$1"
    awk -v feature="$feature" '$1 == feature { found = 1 } END { exit found ? 0 : 1 }' <<<"$AVAILABLE_FEATURES"
}

append_disable_if_supported() {
    local feature="$1"
    if feature_supported "$feature"; then
        DISABLE_ARGS+=(--disable "$feature")
    fi
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
        echo "[codex-gui] refusing to use $label inside the real Codex home: $candidate" >&2
        echo "[codex-gui] set $label to a separate private runtime path outside $CODEX_GUI_SESSION_HOME" >&2
        exit 1
    fi
}

make_runtime_home() {
    if [ -n "${CODEX_GUI_RUNTIME_HOME:-}" ]; then
        require_private_codex_home "CODEX_GUI_RUNTIME_HOME" "$CODEX_GUI_RUNTIME_HOME"
        mkdir -p "$CODEX_GUI_RUNTIME_HOME"
        chmod 700 "$CODEX_GUI_RUNTIME_HOME" 2>/dev/null || true
        echo "$CODEX_GUI_RUNTIME_HOME"
        return 0
    fi

    local parent="${CODEX_GUI_RUNTIME_PARENT:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-gui/runs}"
    require_private_codex_home "CODEX_GUI_RUNTIME_PARENT" "$parent"
    mkdir -p "$parent"
    chmod 700 "${parent%/codex-gui/runs}" "${parent%/runs}" "$parent" 2>/dev/null || true
    mktemp -d "$parent/run.XXXXXX"
}

seed_runtime_home() {
    [ "${CODEX_GUI_SEED_SESSION_HOME:-1}" = "1" ] || return 0
    [ -d "$CODEX_GUI_SESSION_HOME" ] || return 0

    local source_real runtime_real
    source_real="$(safe_realpath "$CODEX_GUI_SESSION_HOME")"
    runtime_real="$(safe_realpath "$CODEX_HOME")"
    [ "$source_real" != "$runtime_real" ] || return 0

    if [ "${CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS:-0}" = "1" ]; then
        if ! cp -a "$CODEX_GUI_SESSION_HOME"/. "$CODEX_HOME"/ 2>/dev/null; then
            echo "[codex-gui] warning: failed to seed runtime CODEX_HOME from $CODEX_GUI_SESSION_HOME" >&2
        fi
        return 0
    fi

    if ! (
        cd "$CODEX_GUI_SESSION_HOME"
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
        cd "$CODEX_HOME"
        tar -xpf -
    ) 2>/dev/null; then
        echo "[codex-gui] warning: failed to seed runtime CODEX_HOME from $CODEX_GUI_SESSION_HOME" >&2
    fi
}

sync_session_state_back() {
    [ "${CODEX_GUI_SYNC_SESSION_STATE:-1}" = "1" ] || return 0
    [ -d "$CODEX_HOME" ] || return 0

    mkdir -p "$CODEX_GUI_SESSION_HOME"

    shopt -s nullglob
    local state_file
    for state_file in "$CODEX_HOME"/state_5.sqlite*; do
        if ! cp -p "$state_file" "$CODEX_GUI_SESSION_HOME/${state_file##*/}" 2>/dev/null; then
            echo "[codex-gui] warning: failed to sync ${state_file##*/} back to $CODEX_GUI_SESSION_HOME" >&2
        fi
    done
    shopt -u nullglob
}

lock_runtime_skills_bootstrap() {
    [ "${CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP:-1}" = "1" ] || return 0

    local skills_dir="$CODEX_HOME/skills"
    mkdir -p "$skills_dir"

    LOCKED_SKILLS_DIR="$skills_dir"
    ORIGINAL_SKILLS_MODE="$(stat -c '%a' "$skills_dir" 2>/dev/null || true)"

    if chmod a-w "$skills_dir" 2>/dev/null; then
        echo "[codex-gui] locked runtime skills root to block system skill bootstrap: $skills_dir" >&2
    else
        echo "[codex-gui] warning: failed to lock runtime skills root: $skills_dir" >&2
    fi
}

restore_runtime_skills_permissions() {
    [ -n "$LOCKED_SKILLS_DIR" ] || return 0
    [ -d "$LOCKED_SKILLS_DIR" ] || return 0

    if [ -n "$ORIGINAL_SKILLS_MODE" ]; then
        chmod "$ORIGINAL_SKILLS_MODE" "$LOCKED_SKILLS_DIR" 2>/dev/null || true
    else
        chmod u+w "$LOCKED_SKILLS_DIR" 2>/dev/null || true
    fi
}

REAL_CODEX="$(resolve_real_codex)" || {
    echo "Codex GUI wrapper could not find the real codex CLI. Set CODEX_REAL_CLI_PATH." >&2
    exit 1
}

case "${1:-}" in
    ""|--version|-V|version)
        exec "$REAL_CODEX" "$@"
        ;;
esac

if [ "${1:-}" != "app-server" ] || [ "${CODEX_GUI_LITE_MODE:-1}" != "1" ]; then
    exec "$REAL_CODEX" "$@"
fi

CODEX_GUI_SESSION_HOME="${CODEX_GUI_SESSION_HOME:-${CODEX_GUI_CODEX_HOME:-$HOME/.codex}}"
mkdir -p "$CODEX_GUI_SESSION_HOME"

CODEX_HOME="$(make_runtime_home)"
export CODEX_HOME
export CODEX_REAL_CLI_PATH="$REAL_CODEX"

seed_runtime_home

lock_runtime_skills_bootstrap
trap restore_runtime_skills_permissions EXIT

DEFAULT_DISABLE_FEATURES="${CODEX_GUI_DEFAULT_DISABLE_FEATURES:-apps browser_use enable_mcp_apps enable_request_compression plugin_hooks plugins remote_plugin skill_env_var_dependency_prompt skill_mcp_dependency_install tool_call_mcp_elicitation tool_search tool_suggest workspace_dependencies}"
DISABLE_FEATURES="$DEFAULT_DISABLE_FEATURES ${CODEX_GUI_EXTRA_DISABLE_FEATURES:-}"

DISABLE_ARGS=()
if [ -n "${DISABLE_FEATURES//[[:space:]]/}" ]; then
    AVAILABLE_FEATURES="$(feature_list)"
    for feature in $DISABLE_FEATURES; do
        append_disable_if_supported "$feature"
    done
fi

set +e
node "$PROXY_PATH" "$@" "${DISABLE_ARGS[@]}"
status=$?
set -e

restore_runtime_skills_permissions
trap - EXIT
sync_session_state_back

exit "$status"
