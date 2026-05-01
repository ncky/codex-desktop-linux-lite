#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_PATH="$REPO_ROOT/run-codex-gui.sh"
WRAPPER_PATH="$SCRIPT_DIR/codex-gui-cli-wrapper.sh"
PROXY_PATH="$SCRIPT_DIR/codex-gui-appserver-proxy.mjs"

usage() {
    cat <<'HELP'
Usage: scripts/verify-gui-lite-safety.sh <codex-app-dir> [OPTIONS]

Verifies that the generated Codex Desktop Linux app is still patched for
GUI-lite mode before it is launched.

Options:
  --write-stamp     Write a safety stamp after all requested checks pass
  --require-stamp   Require the existing safety stamp to match app files
  --runtime-smoke   Run the app-server wrapper against a temp Codex home
  -h, --help        Show this help message and exit
HELP
}

info() {
    echo "[gui-lite-verify] $*" >&2
}

fail() {
    echo "[gui-lite-verify] ERROR: $*" >&2
    exit 1
}

APP_DIR="${1:-}"
if [ -z "$APP_DIR" ]; then
    usage >&2
    exit 1
fi
shift

WRITE_STAMP=0
REQUIRE_STAMP=0
RUNTIME_SMOKE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --write-stamp)
            WRITE_STAMP=1
            ;;
        --require-stamp)
            REQUIRE_STAMP=1
            ;;
        --runtime-smoke)
            RUNTIME_SMOKE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
    shift
done

[ -d "$APP_DIR" ] || fail "app directory not found: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"
STAMP_PATH="$APP_DIR/.codex-linux/gui-lite-safety.env"
INTERNAL_LAUNCHER_PATH="$APP_DIR/.codex-linux/start-internal.sh"

sha_file() {
    sha256sum "$1" | awk '{ print $1 }'
}

sha_tree() {
    local root="$1"
    if [ ! -d "$root" ]; then
        echo "missing"
        return 0
    fi

    find "$root" -type f -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sha256sum \
        | awk '{ print $1 }'
}

current_app_asar_sha() {
    sha_file "$APP_DIR/resources/app.asar"
}

current_launcher_sha() {
    sha_file "$INTERNAL_LAUNCHER_PATH"
}

current_webview_sha() {
    sha_tree "$APP_DIR/content/webview"
}

forbidden_paths() {
    local root="$1"
    [ -d "$root" ] || return 0

    find "$root" \
        \( \
            -path '*/skills/.system' -o \
            -path '*/skills/.system/*' -o \
            -path '*/.tmp/plugins' -o \
            -path '*/.tmp/plugins/*' -o \
            -path '*/.tmp/plugins.sha' -o \
            -path '*/plugins/cache' -o \
            -path '*/plugins/cache/*' -o \
            -path '*/vendor_imports' -o \
            -path '*/vendor_imports/*' \
        \) -print
}

info "Gate 1/8: checking generated app layout"
[ -f "$APP_DIR/resources/app.asar" ] || fail "patched app.asar is missing: $APP_DIR/resources/app.asar"
[ -d "$APP_DIR/content/webview" ] || fail "webview content is missing: $APP_DIR/content/webview"
[ -d "$APP_DIR/.codex-linux" ] || fail "local metadata directory is missing: $APP_DIR/.codex-linux"
[ -x "$INTERNAL_LAUNCHER_PATH" ] || fail "internal launcher is missing or not executable: $INTERNAL_LAUNCHER_PATH"
[ ! -e "$APP_DIR/start.sh" ] || fail "top-level codex-app/start.sh exists; use only ./run-codex-gui.sh"

info "Gate 2/8: checking launcher does not contain install or updater behavior"
launcher_forbidden="$(mktemp)"
if grep -n -E 'npm install -g|codex-update-manager|pkexec|systemctl --user|dpkg -i|rpm -U|pacman -U|build-deb|build-rpm|build-pacman' \
    "$INTERNAL_LAUNCHER_PATH" >"$launcher_forbidden"; then
    sed -n '1,20p' "$launcher_forbidden" >&2
    rm -f "$launcher_forbidden"
    fail "launcher still contains native install/update behavior"
fi
rm -f "$launcher_forbidden"

if grep -q '__MIN_CODEX_CLI_VERSION__' "$INTERNAL_LAUNCHER_PATH"; then
    fail "launcher minimum CLI version placeholder was not replaced"
fi

grep -q 'CODEX_GUI_INTERNAL_LAUNCH' "$INTERNAL_LAUNCHER_PATH" \
    || fail "internal launcher no longer rejects direct execution"

info "Gate 3/8: checking desktop bundle no longer directly hydrates skills/plugins"
bundle_forbidden="$(mktemp)"
if grep -R -a -n -E 'skills/list|plugin/list' \
    "$APP_DIR/content/webview" "$APP_DIR/resources/app.asar" >"$bundle_forbidden"; then
    sed -n '1,20p' "$bundle_forbidden" >&2
    rm -f "$bundle_forbidden"
    fail "patched app still contains direct skills/list or plugin/list calls"
fi
rm -f "$bundle_forbidden"

info "Gate 4/8: checking wrapper and proxy protections are present"
[ -x "$RUNNER_PATH" ] || fail "run-codex-gui.sh is missing or not executable: $RUNNER_PATH"
[ -x "$WRAPPER_PATH" ] || fail "CLI wrapper is missing or not executable: $WRAPPER_PATH"
[ -f "$PROXY_PATH" ] || fail "app-server proxy is missing: $PROXY_PATH"
grep -q 'CODEX_GUI_ELECTRON_HOME' "$RUNNER_PATH" \
    || fail "launcher no longer assigns a private Electron CODEX_HOME"
grep -q 'vendor_imports' "$RUNNER_PATH" \
    || fail "launcher no longer excludes vendor_imports while seeding Electron home"
grep -q 'sync_electron_global_state_back' "$RUNNER_PATH" \
    || fail "launcher no longer syncs GUI global state back from the private Electron home"
grep -q '.codex-global-state.json' "$RUNNER_PATH" \
    || fail "launcher no longer persists .codex-global-state.json"
grep -q 'require_private_codex_home' "$RUNNER_PATH" \
    || fail "launcher no longer rejects private Electron homes inside the real Codex home"
if grep -q 'chmod 700 "$CODEX_GUI_SESSION_HOME"' "$RUNNER_PATH"; then
    fail "launcher must not chmod the real Codex home"
fi
grep -q 'CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP' "$WRAPPER_PATH" \
    || fail "wrapper no longer blocks app-server system skill bootstrap"
grep -q 'CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS' "$WRAPPER_PATH" \
    || fail "wrapper no longer excludes generated bootstrap paths while seeding"
grep -q 'vendor_imports' "$WRAPPER_PATH" \
    || fail "wrapper no longer excludes vendor_imports while seeding app-server home"
grep -q 'require_private_codex_home' "$WRAPPER_PATH" \
    || fail "wrapper no longer rejects private app-server homes inside the real Codex home"
if grep -q 'chmod 700 "$CODEX_GUI_SESSION_HOME"' "$WRAPPER_PATH"; then
    fail "wrapper must not chmod the real Codex home"
fi
grep -q 'skills/list' "$PROXY_PATH" \
    || fail "proxy no longer blocks skills/list"
grep -q 'plugin/list' "$PROXY_PATH" \
    || fail "proxy no longer blocks plugin/list"

info "Gate 5/8: checking safety stamp state"
APP_ASAR_SHA="$(current_app_asar_sha)"
LAUNCHER_SHA="$(current_launcher_sha)"
WEBVIEW_SHA="$(current_webview_sha)"

if [ "$REQUIRE_STAMP" -eq 1 ]; then
    [ -f "$STAMP_PATH" ] || fail "safety stamp is missing; rebuild with ./run-codex-gui.sh --rebuild-only"

    stamped_app_asar_sha="$(awk -F= '$1 == "APP_ASAR_SHA256" { print $2 }' "$STAMP_PATH")"
    stamped_launcher_sha="$(awk -F= '$1 == "LAUNCHER_SHA256" { print $2 }' "$STAMP_PATH")"
    stamped_webview_sha="$(awk -F= '$1 == "WEBVIEW_SHA256" { print $2 }' "$STAMP_PATH")"

    [ "$stamped_app_asar_sha" = "$APP_ASAR_SHA" ] \
        || fail "app.asar changed after safety verification; rebuild before launching"
    [ "$stamped_launcher_sha" = "$LAUNCHER_SHA" ] \
        || fail "internal launcher changed after safety verification; rebuild before launching"
    [ "$stamped_webview_sha" = "$WEBVIEW_SHA" ] \
        || fail "webview content changed after safety verification; rebuild before launching"
fi

info "Gate 6/8: checking real session home is not required for verification"
VERIFY_TMP=""
cleanup_verify_tmp() {
    if [ -n "$VERIFY_TMP" ] && [ -d "$VERIFY_TMP" ]; then
        rm -rf "$VERIFY_TMP"
    fi
}
trap cleanup_verify_tmp EXIT

if [ "$RUNTIME_SMOKE" -eq 1 ]; then
    info "Gate 7/8: running app-server wrapper smoke test in a temporary Codex home"

    real_codex="${CODEX_REAL_CLI_PATH:-}"
    if [ -z "$real_codex" ]; then
        real_codex="$(command -v codex 2>/dev/null || true)"
    fi
    [ -n "$real_codex" ] && [ -x "$real_codex" ] \
        || fail "Codex CLI not found for runtime smoke; set CODEX_REAL_CLI_PATH"

    VERIFY_TMP="$(mktemp -d)"
    mkdir -p "$VERIFY_TMP/home" "$VERIFY_TMP/cache" "$VERIFY_TMP/state" "$VERIFY_TMP/session-home"
    mkdir -p "$VERIFY_TMP/session-home/skills/custom-gui-lite-smoke"
    printf '# Custom GUI-lite smoke skill\n' >"$VERIFY_TMP/session-home/skills/custom-gui-lite-smoke/SKILL.md"
    mkdir -p "$VERIFY_TMP/session-home/skills/.system" "$VERIFY_TMP/session-home/.tmp/plugins" "$VERIFY_TMP/session-home/plugins/cache" "$VERIFY_TMP/session-home/vendor_imports/skills"
    printf 'generated system skill marker\n' >"$VERIFY_TMP/session-home/skills/.system/marker.txt"
    printf 'generated plugin marker\n' >"$VERIFY_TMP/session-home/.tmp/plugins/marker.txt"
    printf 'generated cache marker\n' >"$VERIFY_TMP/session-home/plugins/cache/marker.txt"
    printf 'generated vendor import marker\n' >"$VERIFY_TMP/session-home/vendor_imports/skills/marker.txt"

    smoke_log="$VERIFY_TMP/app-server-smoke.log"
    set +e
    env \
        HOME="$VERIFY_TMP/home" \
        XDG_CACHE_HOME="$VERIFY_TMP/cache" \
        XDG_STATE_HOME="$VERIFY_TMP/state" \
        CODEX_REAL_CLI_PATH="$real_codex" \
        CODEX_GUI_SESSION_HOME="$VERIFY_TMP/session-home" \
        CODEX_GUI_LITE_MODE=1 \
        CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP=1 \
        timeout --kill-after=2 8 "$WRAPPER_PATH" app-server \
        </dev/null >"$smoke_log" 2>&1
    smoke_status=$?
    set -e

    if [ "$smoke_status" -ne 0 ]; then
        sed -n '1,120p' "$smoke_log" >&2
        fail "app-server wrapper smoke test failed with status $smoke_status"
    fi

    bad_paths="$(mktemp)"
    {
        forbidden_paths "$VERIFY_TMP/state/codex-gui"
    } >"$bad_paths"

    if [ -s "$bad_paths" ]; then
        sed -n '1,80p' "$bad_paths" >&2
        rm -f "$bad_paths"
        fail "runtime smoke seeded or created forbidden skills/plugin/vendor bootstrap paths"
    fi
    rm -f "$bad_paths"

    if ! find "$VERIFY_TMP/state/codex-gui" \
        -path '*/skills/custom-gui-lite-smoke/SKILL.md' \
        -type f \
        | grep -q .; then
        fail "runtime smoke did not seed custom skills from the real session home"
    fi

    info "Gate 7/8 passed: runtime smoke seeded custom state without creating skills/.system, plugin caches, or vendor_imports"
else
    info "Gate 7/8 skipped: runtime smoke was not requested"
fi

if [ "$WRITE_STAMP" -eq 1 ]; then
    info "Gate 8/8: writing safety stamp"
    mkdir -p "$(dirname "$STAMP_PATH")"
    cat >"$STAMP_PATH" <<EOF
APP_ASAR_SHA256=$APP_ASAR_SHA
LAUNCHER_SHA256=$LAUNCHER_SHA
WEBVIEW_SHA256=$WEBVIEW_SHA
VERIFIED_AT=$(date -Is)
RUNTIME_SMOKE=$([ "$RUNTIME_SMOKE" -eq 1 ] && echo passed || echo skipped)
EOF
else
    info "Gate 8/8: safety stamp write not requested"
fi

info "GUI-lite safety verification passed"
