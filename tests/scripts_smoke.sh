#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

info() {
    echo "[smoke] $*" >&2
}

fail() {
    echo "[smoke][FAIL] $*" >&2
    exit 1
}

assert_file_executable() {
    local path="$1"
    [ -x "$path" ] || fail "Expected file to be executable: $path"
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    grep -q -- "$pattern" "$path" || fail "Expected '$pattern' in $path"
}

assert_not_contains() {
    local path="$1"
    local pattern="$2"
    if grep -q -- "$pattern" "$path"; then
        fail "Did not expect '$pattern' in $path"
    fi
}

test_syntax() {
    info "Checking shell and Node syntax"
    bash -n "$REPO_DIR/build-codex-gui.sh"
    bash -n "$REPO_DIR/run-codex-gui.sh"
    bash -n "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh"
    bash -n "$REPO_DIR/scripts/verify-gui-lite-safety.sh"
    node --check "$REPO_DIR/scripts/codex-gui-appserver-proxy.mjs"
    node --check "$REPO_DIR/scripts/patch-gui-lite-behavior.js"
}

test_executables() {
    info "Checking executable scripts"
    assert_file_executable "$REPO_DIR/build-codex-gui.sh"
    assert_file_executable "$REPO_DIR/run-codex-gui.sh"
    assert_file_executable "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh"
    assert_file_executable "$REPO_DIR/scripts/verify-gui-lite-safety.sh"
    assert_file_executable "$REPO_DIR/scripts/codex-gui-appserver-proxy.mjs"
    assert_file_executable "$REPO_DIR/scripts/patch-gui-lite-behavior.js"
}

test_launcher_template_sanity() {
    info "Checking generated launcher template markers"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "nohup python3 -m http.server 5175"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "wait_for_webview_server"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "--app-id=codex-desktop"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "--ozone-platform-hint=auto"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "--disable-gpu-sandbox"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "MIN_CODEX_CLI_VERSION"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "ensure_local_cli_compatibility"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "codex_cli_version_gte"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "patch-gui-lite-behavior.js"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "CODEX_GUI_BUILD_CACHE_DIR"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "ensure_node_tooling"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "NATIVE_MODULE_CACHE_DIR"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "ELECTRON_ZIP_CACHE_DIR"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "npx --yes asar"
    assert_contains "$REPO_DIR/build-codex-gui.sh" ".codex-linux/start-internal.sh"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "CODEX_GUI_INTERNAL_LAUNCH"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "content/webview/assets/app-"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "npm install -g"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "codex-update-manager"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "run_cli_preflight"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "assets/codex.png"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "APP_NOTIFICATION_ICON_REPO"
}

test_gui_lite_scripts() {
    info "Checking GUI-lite scripts"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "CODEX_CLI_PRESERVE_PATH=1"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "build-codex-gui.sh"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "start-internal.sh"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "CODEX_GUI_INTERNAL_LAUNCH=1"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "CODEX_GUI_ELECTRON_HOME"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "vendor_imports"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "sync_electron_global_state_back"
    assert_contains "$REPO_DIR/run-codex-gui.sh" ".codex-global-state.json"
    assert_contains "$REPO_DIR/run-codex-gui.sh" "require_private_codex_home"
    assert_not_contains "$REPO_DIR/run-codex-gui.sh" 'chmod 700 "$CODEX_GUI_SESSION_HOME"'
    assert_not_contains "$REPO_DIR/run-codex-gui.sh" "npm install -g"
    assert_not_contains "$REPO_DIR/run-codex-gui.sh" "CODEX_GUI_PRUNE_CODEX_HOME"

    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "CODEX_GUI_SESSION_HOME"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "CODEX_GUI_RUNTIME_HOME"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "CODEX_GUI_DEFAULT_DISABLE_FEATURES"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "plugins"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "seed_runtime_home"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "sync_session_state_back"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "CODEX_GUI_BLOCK_SYSTEM_SKILL_BOOTSTRAP"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "CODEX_GUI_SEED_GENERATED_BOOTSTRAP_PATHS"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "lock_runtime_skills_bootstrap"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "vendor_imports"
    assert_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "require_private_codex_home"
    assert_not_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" 'chmod 700 "$CODEX_GUI_SESSION_HOME"'
    assert_not_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "cleanup_generated_codex_home"
    assert_not_contains "$REPO_DIR/scripts/codex-gui-cli-wrapper.sh" "rm -rf"

    assert_contains "$REPO_DIR/scripts/codex-gui-appserver-proxy.mjs" "skills/list"
    assert_contains "$REPO_DIR/scripts/codex-gui-appserver-proxy.mjs" "plugin/list"
    assert_contains "$REPO_DIR/scripts/codex-gui-appserver-proxy.mjs" "CODEX_GUI_BLOCK_APP_SERVER_METHODS"

    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "async listSkills"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "async listPlugins"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "primaryRuntimeBundledSkillsSync"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "bundledPluginsMarketplaceSync"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "recommendedSkillsFetcher"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "recommendedSkillInstallFunction"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "recommendedSkillsHandler"
    assert_contains "$REPO_DIR/scripts/patch-gui-lite-behavior.js" "installRecommendedSkillHandler"

    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "Gate 1/8"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "skills/.system"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "vendor_imports"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "custom-gui-lite-smoke"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "top-level codex-app/start.sh"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "LAUNCHER_SHA256"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "runtime smoke"
    assert_contains "$REPO_DIR/scripts/verify-gui-lite-safety.sh" "--require-stamp"
}

test_package_age_gate_configs() {
    info "Checking package manager age-gate configs"
    assert_contains "$REPO_DIR/.npmrc" "min-release-age=7"
    assert_contains "$REPO_DIR/pnpm-workspace.yaml" "minimumReleaseAge: 10080"
    assert_contains "$REPO_DIR/.yarnrc.yml" "npmMinimalAgeGate: \"7d\""
    assert_contains "$REPO_DIR/build-codex-gui.sh" "CODEX_GUI_NPMRC_PATH"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "check_npm_age_gate"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "age_gate_cache_current"
    assert_contains "$REPO_DIR/build-codex-gui.sh" ".codex-gui-npm-age-gate"
    assert_contains "$REPO_DIR/build-codex-gui.sh" "--userconfig"
    assert_not_contains "$REPO_DIR/build-codex-gui.sh" "find_cached_npx_binary"
}

test_removed_convenience_surfaces() {
    info "Checking removed convenience surfaces"
    [ ! -f "$REPO_DIR/Makefile" ] || fail "Top-level Makefile should not be restored; use shell scripts directly"
    [ ! -d "$REPO_DIR/assets" ] || fail "Repo-owned assets directory should not be restored; use upstream extracted webview assets"
}

main() {
    test_syntax
    test_executables
    test_launcher_template_sanity
    test_gui_lite_scripts
    test_package_age_gate_configs
    test_removed_convenience_surfaces
    info "All script smoke tests passed"
}

main "$@"
