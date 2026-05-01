#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# Codex Desktop for Linux — Local App Builder
# Converts the official macOS Codex Desktop app to run on Linux
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${CODEX_BUILD_ROOT:-$SCRIPT_DIR}"
APP_DIR="${CODEX_APP_DIR:-$BUILD_ROOT/codex-app}"
ELECTRON_VERSION="40.0.0"
WORK_DIR="$(mktemp -d)"
ARCH="$(uname -m)"
DEFAULT_MIN_CODEX_CLI_VERSION="0.119.0-alpha.22"
BUILD_CACHE_DIR="${CODEX_GUI_BUILD_CACHE_DIR:-$BUILD_ROOT/.cache/codex-gui-build}"
NPM_CACHE_DIR="${CODEX_GUI_NPM_CACHE_DIR:-$BUILD_CACHE_DIR/npm}"
NPMRC_PATH="${CODEX_GUI_NPMRC_PATH:-$SCRIPT_DIR/.npmrc}"
NODE_TOOL_DIR="$BUILD_CACHE_DIR/node-tools"
NATIVE_MODULE_CACHE_DIR="$BUILD_CACHE_DIR/native-modules"
ELECTRON_ZIP_CACHE_DIR="$BUILD_CACHE_DIR/electron"
ASAR_BIN="${CODEX_GUI_ASAR_BIN:-}"
ELECTRON_REBUILD_BIN="${CODEX_GUI_ELECTRON_REBUILD_BIN:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

dependency_help() {
    cat <<'EOF'
Run the helper to prepare host dependencies:
  bash scripts/install-deps.sh

Or prepare them manually:
  sudo apt install nodejs npm python3 p7zip-full curl unzip build-essential         # Debian/Ubuntu
  sudo dnf install nodejs npm python3 7zip curl unzip @development-tools            # Fedora 41+ (dnf5)
  sudo dnf install nodejs npm python3 p7zip p7zip-plugins curl unzip                # Fedora <41 (dnf)
    && sudo dnf groupinstall 'Development Tools'
  sudo pacman -S nodejs npm python p7zip curl unzip base-devel                      # Arch
EOF
}

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'error "Failed at line $LINENO (exit code $?)"' ERR

CACHED_DMG_PATH="$SCRIPT_DIR/Codex.dmg"
FRESH_BUILD=0
REUSE_CACHED_DMG=1
PROVIDED_DMG_PATH=""

usage() {
    cat <<'HELP'
Usage: ./build-codex-gui.sh [OPTIONS] [path/to/Codex.dmg]

Converts the official macOS Codex Desktop app to run on Linux.

Options:
  -h, --help     Show this help message and exit
  --fresh        Remove existing app directory and cached DMG before building
  --reuse-dmg    Reuse cached Codex.dmg if present (default)

Environment variables:
  CODEX_APP_DIR                 Override the app output directory (default: ./codex-app)
  CODEX_GUI_BUILD_CACHE_DIR     Override build cache directory (default: ./.cache/codex-gui-build)
  CODEX_GUI_NPM_CACHE_DIR       Override npm cache directory for builder installs
  CODEX_GUI_NPMRC_PATH          Override npm config used by builder installs (default: ./.npmrc)
  CODEX_GUI_ASAR_BIN            Use a specific asar binary
  CODEX_GUI_ELECTRON_REBUILD_BIN Use a specific electron-rebuild binary

After building, launch with:
  ./run-codex-gui.sh
HELP
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fresh)
                FRESH_BUILD=1
                REUSE_CACHED_DMG=0
                ;;
            --reuse-dmg)
                REUSE_CACHED_DMG=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1 (see --help)"
                ;;
            *)
                [ -z "$PROVIDED_DMG_PATH" ] || error "Only one DMG path may be provided"
                PROVIDED_DMG_PATH="$1"
                ;;
        esac
        shift
    done
}

prepare_build() {
    if [ "$FRESH_BUILD" -eq 1 ] && [ -d "$APP_DIR" ]; then
        info "Removing existing app directory: $APP_DIR"
        rm -rf "$APP_DIR"
    fi

    if [ "$FRESH_BUILD" -eq 1 ] && [ "$REUSE_CACHED_DMG" -ne 1 ] && [ -f "$CACHED_DMG_PATH" ]; then
        info "Removing cached DMG: $CACHED_DMG_PATH"
        rm -f "$CACHED_DMG_PATH"
    fi
}

# ---- Check dependencies ----
check_deps() {
    local missing=()
    for cmd in node npm python3 7z curl unzip; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -ne 0 ]; then
        error "Missing dependencies: ${missing[*]}
$(dependency_help)"
    fi

    NODE_MAJOR=$(node -v | cut -d. -f1 | tr -d v)
    if [ "$NODE_MAJOR" -lt 20 ]; then
        error "Node.js 20+ required (found $(node -v))"
    fi

    if ! command -v make &>/dev/null || ! command -v g++ &>/dev/null; then
        error "Build tools (make, g++) required:
$(dependency_help)"
    fi

    # Prefer modern 7-zip if available (required for APFS DMG)
    if command -v 7zz &>/dev/null; then
        SEVEN_ZIP_CMD="7zz"
    else
        SEVEN_ZIP_CMD="7z"
    fi

    if "$SEVEN_ZIP_CMD" 2>&1 | grep -m 1 "7-Zip" | grep -q "16.02"; then
        error "System 7-zip is too old for modern APFS DMGs.
Install a newer 7zz first by running:
  bash scripts/install-deps.sh

That helper bootstraps a current 7zz into ~/.local/bin by default.
If ~/.local/bin is not on your PATH, add it before re-running this script:
  export PATH=\"$HOME/.local/bin:$PATH\"
Set SEVENZIP_SYSTEM_INSTALL=1 to place it into /usr/local/bin instead."
    fi

    info "All dependencies found (using $SEVEN_ZIP_CMD)"
}

check_npm_age_gate() {
    [ "${CODEX_GUI_REQUIRE_NPM_AGE_GATE:-1}" = "1" ] || return 0
    [ -f "$NPMRC_PATH" ] || error "Missing npm age-gate config: $NPMRC_PATH"

    local npm_min_age
    npm_min_age="$(npm --userconfig "$NPMRC_PATH" config get before 2>/dev/null || true)"
    if [ "$npm_min_age" = "null" ] || [ -z "$npm_min_age" ]; then
        error "npm age gate is not active. Expected $NPMRC_PATH to set min-release-age=7 for npm 11+."
    fi

    info "npm package age gate active via $NPMRC_PATH (resolved before=$npm_min_age)"
}

npm_age_gate_fingerprint() {
    if [ "${CODEX_GUI_REQUIRE_NPM_AGE_GATE:-1}" != "1" ]; then
        echo "disabled"
        return 0
    fi

    {
        printf 'npm=%s\n' "$(npm --version)"
        printf 'npmrc=%s\n' "$(sha256sum "$NPMRC_PATH" | awk '{ print $1 }')"
    } | sha256sum | awk '{ print $1 }'
}

age_gate_cache_current() {
    local stamp_path="$1"
    [ -f "$stamp_path" ] || return 1
    [ "$(cat "$stamp_path" 2>/dev/null || true)" = "$(npm_age_gate_fingerprint)" ]
}

write_age_gate_cache_stamp() {
    local stamp_path="$1"
    npm_age_gate_fingerprint >"$stamp_path"
}

npm_install_cached() {
    npm install \
        --userconfig "$NPMRC_PATH" \
        --cache "$NPM_CACHE_DIR" \
        --prefer-offline \
        --fetch-retries 1 \
        --fetch-retry-mintimeout 5000 \
        --fetch-retry-maxtimeout 15000 \
        --fetch-timeout 60000 \
        "$@" \
        2>&1 >&2
}

ensure_node_tooling() {
    mkdir -p "$BUILD_CACHE_DIR" "$NPM_CACHE_DIR" "$NODE_TOOL_DIR"

    local node_tool_stamp="$NODE_TOOL_DIR/.codex-gui-npm-age-gate"
    if ! age_gate_cache_current "$node_tool_stamp"; then
        info "Refreshing cached Node build tools for current npm age-gate config..."
        rm -rf "$NODE_TOOL_DIR/node_modules" "$NODE_TOOL_DIR/package-lock.json" "$NODE_TOOL_DIR/package.json"
    fi

    if [ -n "$ASAR_BIN" ]; then
        [ -x "$ASAR_BIN" ] || error "CODEX_GUI_ASAR_BIN is not executable: $ASAR_BIN"
    elif [ -x "$NODE_TOOL_DIR/node_modules/.bin/asar" ]; then
        ASAR_BIN="$NODE_TOOL_DIR/node_modules/.bin/asar"
    fi

    if [ -n "$ELECTRON_REBUILD_BIN" ]; then
        [ -x "$ELECTRON_REBUILD_BIN" ] || error "CODEX_GUI_ELECTRON_REBUILD_BIN is not executable: $ELECTRON_REBUILD_BIN"
    elif [ -x "$NODE_TOOL_DIR/node_modules/.bin/electron-rebuild" ]; then
        ELECTRON_REBUILD_BIN="$NODE_TOOL_DIR/node_modules/.bin/electron-rebuild"
    fi

    if [ -z "$ASAR_BIN" ] || [ -z "$ELECTRON_REBUILD_BIN" ]; then
        info "Installing cached Node build tools..."
        npm_install_cached \
            --prefix "$NODE_TOOL_DIR" \
            --ignore-scripts \
            @electron/asar \
            @electron/rebuild

        ASAR_BIN="$NODE_TOOL_DIR/node_modules/.bin/asar"
        ELECTRON_REBUILD_BIN="$NODE_TOOL_DIR/node_modules/.bin/electron-rebuild"
    fi

    [ -x "$ASAR_BIN" ] || error "asar binary is missing after tooling setup"
    [ -x "$ELECTRON_REBUILD_BIN" ] || error "electron-rebuild binary is missing after tooling setup"
    write_age_gate_cache_stamp "$node_tool_stamp"

    info "Using asar: $ASAR_BIN"
    info "Using electron-rebuild: $ELECTRON_REBUILD_BIN"
}

# ---- Download or find Codex DMG ----
get_dmg() {
    local dmg_dest="$CACHED_DMG_PATH"

    # Reuse existing DMG
    if [ -s "$dmg_dest" ]; then
        info "Using cached DMG: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
        echo "$dmg_dest"
        return
    fi

    info "Downloading Codex Desktop DMG..."
    local dmg_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
    info "URL: $dmg_url"

    if ! curl -L --progress-bar --max-time 600 --connect-timeout 30 \
            -o "$dmg_dest" "$dmg_url"; then
        rm -f "$dmg_dest"
        error "Download failed. Download manually and place as: $dmg_dest"
    fi

    if [ ! -s "$dmg_dest" ]; then
        rm -f "$dmg_dest"
        error "Download produced empty file. Download manually and place as: $dmg_dest"
    fi

    info "Saved: $dmg_dest ($(du -h "$dmg_dest" | cut -f1))"
    echo "$dmg_dest"
}

# ---- Extract app from DMG ----
extract_dmg() {
    local dmg_path="$1"
    info "Extracting DMG with 7z..."

    local extract_dir="$WORK_DIR/dmg-extract"
    local seven_log="$WORK_DIR/7z.log"
    local seven_zip_status=0

    mkdir -p "$extract_dir"
    if "$SEVEN_ZIP_CMD" x -y -snl "$dmg_path" -o"$extract_dir" >"$seven_log" 2>&1; then
        :
    else
        seven_zip_status=$?
    fi

    local app_dir
    app_dir=$(find "$extract_dir" -maxdepth 3 -name "*.app" -type d | head -1)

    if [ "$seven_zip_status" -ne 0 ]; then
        if [ -n "$app_dir" ]; then
            warn "7z exited with code $seven_zip_status but app bundle was found; continuing"
            warn "$(tail -n 5 "$seven_log" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"
        else
            cat "$seven_log" >&2
            error "Failed to extract DMG"
        fi
    fi

    [ -n "$app_dir" ] || error "Could not find .app bundle in DMG"

    info "Found: $(basename "$app_dir")"
    echo "$app_dir"
}

# ---- Build native modules in a clean directory ----
build_native_modules() {
    local app_extracted="$1"

    # Read versions from extracted app
    local bs3_ver npty_ver
    bs3_ver=$(node -p "require('$app_extracted/node_modules/better-sqlite3/package.json').version" 2>/dev/null || echo "")
    npty_ver=$(node -p "require('$app_extracted/node_modules/node-pty/package.json').version" 2>/dev/null || echo "")

    [ -n "$bs3_ver" ] || error "Could not detect better-sqlite3 version"
    [ -n "$npty_ver" ] || error "Could not detect node-pty version"

    info "Native modules: better-sqlite3@$bs3_ver, node-pty@$npty_ver"

    local native_cache_key native_cache_dir native_cache_tmp native_cache_stamp
    native_cache_key="electron-${ELECTRON_VERSION}-${ARCH}-better-sqlite3-${bs3_ver}-node-pty-${npty_ver}"
    native_cache_dir="$NATIVE_MODULE_CACHE_DIR/$native_cache_key"
    native_cache_tmp="$NATIVE_MODULE_CACHE_DIR/.${native_cache_key}.tmp"
    native_cache_stamp="$native_cache_dir/.codex-gui-npm-age-gate"

    if [ -f "$native_cache_dir/.cache-ok" ] \
        && age_gate_cache_current "$native_cache_stamp" \
        && [ -d "$native_cache_dir/better-sqlite3" ] \
        && [ -d "$native_cache_dir/node-pty" ] \
        && find "$native_cache_dir/better-sqlite3" "$native_cache_dir/node-pty" -name '*.node' -type f 2>/dev/null | grep -q .; then
        info "Using cached rebuilt native modules: $native_cache_dir"
        rm -rf "$app_extracted/node_modules/better-sqlite3"
        rm -rf "$app_extracted/node_modules/node-pty"
        mkdir -p "$app_extracted/node_modules"
        cp -a "$native_cache_dir/better-sqlite3" "$app_extracted/node_modules/"
        cp -a "$native_cache_dir/node-pty" "$app_extracted/node_modules/"
        return 0
    fi

    # Build in a CLEAN directory (asar doesn't have full source)
    local build_dir="$WORK_DIR/native-build"
    mkdir -p "$build_dir"
    cd "$build_dir"

    echo '{"private":true}' > package.json

    info "Installing native module sources through the persistent npm cache..."
    npm_install_cached "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts
    npm_install_cached "better-sqlite3@$bs3_ver" "node-pty@$npty_ver" --ignore-scripts

    info "Compiling for Electron v$ELECTRON_VERSION (this takes ~1 min)..."
    "$ELECTRON_REBUILD_BIN" -v "$ELECTRON_VERSION" --force 2>&1 >&2

    info "Native modules built successfully"

    # Copy compiled modules back into extracted app
    rm -rf "$app_extracted/node_modules/better-sqlite3"
    rm -rf "$app_extracted/node_modules/node-pty"
    cp -r "$build_dir/node_modules/better-sqlite3" "$app_extracted/node_modules/"
    cp -r "$build_dir/node_modules/node-pty" "$app_extracted/node_modules/"

    mkdir -p "$NATIVE_MODULE_CACHE_DIR"
    rm -rf "$native_cache_tmp"
    mkdir -p "$native_cache_tmp"
    cp -a "$build_dir/node_modules/better-sqlite3" "$native_cache_tmp/"
    cp -a "$build_dir/node_modules/node-pty" "$native_cache_tmp/"
    write_age_gate_cache_stamp "$native_cache_tmp/.codex-gui-npm-age-gate"
    date -Is >"$native_cache_tmp/.cache-ok"
    rm -rf "$native_cache_dir"
    mv "$native_cache_tmp" "$native_cache_dir"
    info "Cached rebuilt native modules: $native_cache_dir"
}

# ---- Extract and patch app.asar ----
patch_asar() {
    local app_dir="$1"
    local resources_dir="$app_dir/Contents/Resources"

    [ -f "$resources_dir/app.asar" ] || error "app.asar not found in $resources_dir"

    info "Extracting app.asar..."
    cd "$WORK_DIR"
    "$ASAR_BIN" extract "$resources_dir/app.asar" app-extracted

    # Copy unpacked native modules if they exist
    if [ -d "$resources_dir/app.asar.unpacked" ]; then
        cp -r "$resources_dir/app.asar.unpacked/"* app-extracted/ 2>/dev/null || true
    fi

    # Remove macOS-only modules
    rm -rf "$WORK_DIR/app-extracted/node_modules/sparkle-darwin" 2>/dev/null || true
    find "$WORK_DIR/app-extracted" -name "sparkle.node" -delete 2>/dev/null || true

    # Build native modules in clean environment and copy back
    build_native_modules "$WORK_DIR/app-extracted"

    info "Patching Linux window behavior..."
    node "$SCRIPT_DIR/scripts/patch-linux-window-ui.js" "$WORK_DIR/app-extracted"

    info "Patching GUI-lite app-server hydration behavior..."
    node "$SCRIPT_DIR/scripts/patch-gui-lite-behavior.js" "$WORK_DIR/app-extracted"

    # Repack
    info "Repacking app.asar..."
    cd "$WORK_DIR"
    "$ASAR_BIN" pack app-extracted app.asar --unpack "{*.node,*.so,*.dylib}" 2>/dev/null

    info "app.asar patched"
}

# ---- Download or reuse Linux Electron ----
download_electron() {
    local electron_arch
    case "$ARCH" in
        x86_64)  electron_arch="x64" ;;
        aarch64) electron_arch="arm64" ;;
        armv7l)  electron_arch="armv7l" ;;
        *)       error "Unsupported architecture: $ARCH" ;;
    esac

    local electron_zip_name="electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"
    local electron_zip_path="$ELECTRON_ZIP_CACHE_DIR/$electron_zip_name"
    local url="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-${electron_arch}.zip"

    mkdir -p "$ELECTRON_ZIP_CACHE_DIR"

    if [ -s "$electron_zip_path" ]; then
        info "Using cached Electron: $electron_zip_path ($(du -h "$electron_zip_path" | cut -f1))"
    else
        info "Downloading Electron v${ELECTRON_VERSION} for Linux..."
        info "URL: $url"
        if ! curl -L --fail --progress-bar --max-time 600 --connect-timeout 30 \
                -o "$electron_zip_path.tmp" "$url"; then
            rm -f "$electron_zip_path.tmp"
            error "Electron download failed. Re-run with network access or place the zip at: $electron_zip_path"
        fi
        mv "$electron_zip_path.tmp" "$electron_zip_path"
        info "Cached Electron: $electron_zip_path ($(du -h "$electron_zip_path" | cut -f1))"
    fi

    mkdir -p "$APP_DIR"
    cd "$APP_DIR"
    unzip -qo "$electron_zip_path"

    info "Electron ready"
}

# ---- Extract webview files ----
extract_webview() {
    local app_dir="$1"
    mkdir -p "$APP_DIR/content/webview"

    # Webview files are inside the extracted asar at webview/
    local asar_extracted="$WORK_DIR/app-extracted"
    if [ -d "$asar_extracted/webview" ]; then
        cp -r "$asar_extracted/webview/"* "$APP_DIR/content/webview/"
        # Replace transparent startup background with an opaque color for Linux.
        # The upstream app relies on macOS vibrancy for the transparent effect;
        # on Linux the transparent background causes flickering.
        local webview_index="$APP_DIR/content/webview/index.html"
        if [ -f "$webview_index" ]; then
            sed -i 's/--startup-background: transparent/--startup-background: #1e1e1e/' "$webview_index"
        fi
        info "Webview files copied"
    else
        warn "Webview directory not found in asar — app may not work"
    fi
}

# ---- Detect minimum compatible Codex CLI version from the desktop bundle ----
detect_min_codex_cli_version() {
    local asar_extracted="$WORK_DIR/app-extracted"
    local build_dir="$asar_extracted/.vite/build"

    if [ ! -d "$build_dir" ]; then
        warn "Could not locate Vite build directory to detect minimum Codex CLI version; using fallback $DEFAULT_MIN_CODEX_CLI_VERSION"
        MIN_CODEX_CLI_VERSION="$DEFAULT_MIN_CODEX_CLI_VERSION"
        return 0
    fi

    local detected_version=""
    detected_version="$(node - "$build_dir" <<'NODE'
const fs = require('fs');
const path = require('path');

const buildDir = process.argv[2];
const needle = 'codex-app-server-version-unsupported:';
const versionPattern = /\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\b/g;

const candidates = [];
for (const entry of fs.readdirSync(buildDir)) {
  if (!entry.endsWith('.js')) {
    continue;
  }

  const filePath = path.join(buildDir, entry);
  const source = fs.readFileSync(filePath, 'utf8');
  let index = source.indexOf(needle);
  while (index !== -1) {
    const start = Math.max(0, index - 2048);
    const matches = Array.from(
      source.slice(start, index).matchAll(versionPattern),
      (match) => match[0],
    ).filter((value) => value !== '0.0.0');
    if (matches.length > 0) {
      candidates.push(matches[matches.length - 1]);
    }
    index = source.indexOf(needle, index + needle.length);
  }
}

if (candidates.length === 0) {
  process.exit(1);
}

console.log(candidates[candidates.length - 1]);
NODE
)" || true

    if [ -n "$detected_version" ]; then
        MIN_CODEX_CLI_VERSION="$detected_version"
        info "Detected minimum compatible Codex CLI version: $MIN_CODEX_CLI_VERSION"
    else
        warn "Could not detect minimum Codex CLI version from desktop bundle; using fallback $DEFAULT_MIN_CODEX_CLI_VERSION"
        MIN_CODEX_CLI_VERSION="$DEFAULT_MIN_CODEX_CLI_VERSION"
    fi
}

# ---- Install app.asar ----
install_app() {
    cp "$WORK_DIR/app.asar" "$APP_DIR/resources/"
    if [ -d "$WORK_DIR/app.asar.unpacked" ]; then
        cp -r "$WORK_DIR/app.asar.unpacked" "$APP_DIR/resources/"
    fi
    info "app.asar installed"
}

# ---- Create internal launcher script ----
create_start_script() {
    local launcher_path="$APP_DIR/.codex-linux/start-internal.sh"

    mkdir -p "$APP_DIR/.codex-linux"
    rm -f "$APP_DIR/start.sh"

    cat > "$launcher_path" << 'SCRIPT'
#!/bin/bash
set -euo pipefail

LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$(cd "$LAUNCHER_DIR/.." && pwd)"
WEBVIEW_DIR="$APP_ROOT/content/webview"
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/codex-desktop"
LOG_FILE="$LOG_DIR/launcher.log"
APP_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/codex-desktop"
APP_PID_FILE="$APP_STATE_DIR/app.pid"
APP_NOTIFICATION_ICON_NAME="codex-desktop"
APP_NOTIFICATION_ICON_BUNDLE="$LAUNCHER_DIR/$APP_NOTIFICATION_ICON_NAME.png"
APP_NOTIFICATION_ICON_SYSTEM="/usr/share/icons/hicolor/256x256/apps/$APP_NOTIFICATION_ICON_NAME.png"
MIN_CODEX_CLI_VERSION="__MIN_CODEX_CLI_VERSION__"
CODEX_CLI_PRESERVE_PATH="${CODEX_CLI_PRESERVE_PATH:-0}"

mkdir -p "$LOG_DIR" "$APP_STATE_DIR"

if [ "${CODEX_GUI_INTERNAL_LAUNCH:-0}" != "1" ]; then
    echo "This is an internal launcher. Use ./run-codex-gui.sh from the repo root."
    exit 1
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'HELP'
Usage: ./run-codex-gui.sh [OPTIONS] [-- ELECTRON_FLAGS...]

Launches the Codex Desktop app.

Options:
  -h, --help                  Show this help message and exit
  --disable-gpu               Completely disable GPU acceleration
  --disable-gpu-compositing   Disable GPU compositing (fixes flickering)
  --ozone-platform=x11        Force X11 instead of Wayland

Extra flags are passed directly to Electron.

Logs: ~/.cache/codex-desktop/launcher.log
HELP
    exit 0
fi

exec >>"$LOG_FILE" 2>&1

echo "[$(date -Is)] Starting Codex Desktop launcher"

read_codex_cli_version() {
    local cli_path="$1"
    local raw=""

    raw="$("$cli_path" --version 2>/dev/null || "$cli_path" version 2>/dev/null || true)"
    RAW_VERSION_OUTPUT="$raw" node - <<'NODE'
const raw = process.env.RAW_VERSION_OUTPUT ?? '';
const match = raw.match(/\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\b/);
if (match) {
  console.log(match[0]);
}
NODE
}

codex_cli_version_gte() {
    local candidate="$1"
    local minimum="$2"

    CANDIDATE_VERSION="$candidate" MINIMUM_VERSION="$minimum" node - <<'NODE'
function parseVersion(input) {
  const match = /^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)(?:-(?<prerelease>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$/.exec(input);
  if (!match?.groups) {
    return null;
  }

  return {
    major: Number(match.groups.major),
    minor: Number(match.groups.minor),
    patch: Number(match.groups.patch),
    prerelease: (match.groups.prerelease ?? '')
      .split('.')
      .filter(Boolean)
      .map((part) => (/^\d+$/.test(part) ? Number(part) : part)),
  };
}

function compareVersions(leftRaw, rightRaw) {
  const left = parseVersion(leftRaw);
  const right = parseVersion(rightRaw);
  if (!left || !right) {
    return null;
  }

  for (const key of ['major', 'minor', 'patch']) {
    if (left[key] !== right[key]) {
      return left[key] - right[key];
    }
  }

  const leftPrerelease = left.prerelease;
  const rightPrerelease = right.prerelease;
  if (leftPrerelease.length === 0 && rightPrerelease.length === 0) {
    return 0;
  }
  if (leftPrerelease.length === 0) {
    return 1;
  }
  if (rightPrerelease.length === 0) {
    return -1;
  }

  const maxLength = Math.max(leftPrerelease.length, rightPrerelease.length);
  for (let index = 0; index < maxLength; index += 1) {
    const leftPart = leftPrerelease[index];
    const rightPart = rightPrerelease[index];
    if (leftPart == null) {
      return -1;
    }
    if (rightPart == null) {
      return 1;
    }
    if (leftPart === rightPart) {
      continue;
    }
    if (typeof leftPart === 'number' && typeof rightPart === 'number') {
      return leftPart - rightPart;
    }
    if (typeof leftPart === 'number') {
      return -1;
    }
    if (typeof rightPart === 'number') {
      return 1;
    }
    return String(leftPart).localeCompare(String(rightPart));
  }

  return 0;
}

const candidate = process.env.CANDIDATE_VERSION ?? '';
const minimum = process.env.MINIMUM_VERSION ?? '';
const comparison = compareVersions(candidate, minimum);
process.exit(comparison != null && comparison >= 0 ? 0 : 1);
NODE
}

ensure_local_cli_compatibility() {
    local detected_path="${CODEX_CLI_PATH:-}"
    local check_path="${CODEX_REAL_CLI_PATH:-}"

    if [ -z "$detected_path" ]; then
        detected_path="$(find_codex_cli || true)"
    fi
    if [ -z "$check_path" ]; then
        check_path="$detected_path"
    fi

    if [ -z "$detected_path" ] || [ -z "$check_path" ]; then
        notify_error "Codex CLI not found. This launcher will not install it automatically; put a compatible codex binary in PATH or set CODEX_REAL_CLI_PATH."
        return 1
    fi

    local installed_version=""
    installed_version="$(read_codex_cli_version "$check_path" || true)"
    if [ -z "$installed_version" ]; then
        notify_error "Codex CLI version could not be detected from $check_path"
        return 1
    fi

    if ! codex_cli_version_gte "$installed_version" "$MIN_CODEX_CLI_VERSION"; then
        notify_error "Codex CLI $installed_version is below the minimum supported app-server version $MIN_CODEX_CLI_VERSION. This launcher will not update it automatically."
        return 1
    fi

    CODEX_CLI_PATH="$detected_path"
    export CODEX_CLI_PATH
}

resolve_notification_icon() {
    local candidate
    for candidate in \
        "$APP_NOTIFICATION_ICON_BUNDLE" \
        "$APP_NOTIFICATION_ICON_SYSTEM" \
        "$APP_ROOT"/content/webview/assets/app-*.png
    do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    echo "$APP_NOTIFICATION_ICON_NAME"
}

find_codex_cli() {
    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
        export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
        # shellcheck disable=SC1090
        . "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true
        if command -v codex >/dev/null 2>&1; then
            command -v codex
            return 0
        fi
    fi

    local candidate
    for candidate in \
        "$HOME/.nvm/versions/node/current/bin/codex" \
        "$HOME/.nvm/versions/node"/*/bin/codex \
        "$HOME/.local/share/pnpm/codex" \
        "$HOME/.local/bin/codex" \
        "/usr/local/bin/codex" \
        "/usr/bin/codex"
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

notify_error() {
    local message="$1"
    local icon
    icon="$(resolve_notification_icon)"
    echo "$message"
    if command -v notify-send >/dev/null 2>&1; then
        notify-send \
            -a "Codex Desktop" \
            -i "$icon" \
            -h "string:desktop-entry:codex-desktop" \
            "Codex Desktop" \
            "$message"
    fi
}

wait_for_webview_server() {
    echo "Waiting for webview server on :5175"

    local attempt
    for attempt in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1', 5175)); s.close()" 2>/dev/null; then
            echo "Webview server is ready"
            return 0
        fi
        sleep 0.1
    done

    return 1
}

clear_stale_pid_file() {
    if [ ! -f "$APP_PID_FILE" ]; then
        return 0
    fi

    local pid=""
    pid="$(cat "$APP_PID_FILE" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$APP_PID_FILE"
    fi
}

clear_stale_pid_file
pkill -f "http.server 5175" 2>/dev/null || true
sleep 0.5

if [ -d "$WEBVIEW_DIR" ] && [ "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
    cd "$WEBVIEW_DIR"
    nohup python3 -m http.server 5175 &> /dev/null &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT

    # Wait for the HTTP server to be ready (up to 5 seconds)
    echo "Waiting for webview server..."
    for i in $(seq 1 50); do
        if python3 -c "import socket; s=socket.socket(); s.settimeout(0.5); s.connect(('127.0.0.1',5175)); s.close()" 2>/dev/null; then
            echo "Webview server ready."
            break
        fi
        sleep 0.1
    done
fi

if [ -z "${CODEX_CLI_PATH:-}" ]; then
    CODEX_CLI_PATH="$(find_codex_cli || true)"
    export CODEX_CLI_PATH
fi
export CHROME_DESKTOP="${CHROME_DESKTOP:-codex-desktop.desktop}"

ensure_local_cli_compatibility

if [ -z "$CODEX_CLI_PATH" ]; then
    notify_error "Codex CLI not found. Put a compatible codex binary in PATH or set CODEX_CLI_PATH."
    exit 1
fi

echo "Using CODEX_CLI_PATH=$CODEX_CLI_PATH"

cd "$APP_ROOT"
echo "$$" > "$APP_PID_FILE"
exec "$APP_ROOT/electron" \
    --no-sandbox \
    --class=codex-desktop \
    --app-id=codex-desktop \
    --ozone-platform-hint=auto \
    --disable-gpu-sandbox \
    --disable-gpu-compositing \
    --enable-features=WaylandWindowDecorations \
    "$@"
SCRIPT

    sed -i "s/__MIN_CODEX_CLI_VERSION__/$MIN_CODEX_CLI_VERSION/" "$launcher_path"
    chmod +x "$launcher_path"
    info "Internal launcher created"
}

verify_gui_lite_safety() {
    local real_codex="${CODEX_REAL_CLI_PATH:-}"

    if [ -z "$real_codex" ]; then
        real_codex="$(command -v codex 2>/dev/null || true)"
    fi

    [ -n "$real_codex" ] || error "Codex CLI not found. Safety verification requires a compatible existing codex binary; this builder will not install it automatically."
    [ -x "$real_codex" ] || error "Codex CLI is not executable: $real_codex"

    info "Running GUI-lite safety verification before accepting generated app..."
    CODEX_REAL_CLI_PATH="$real_codex" \
        "$SCRIPT_DIR/scripts/verify-gui-lite-safety.sh" "$APP_DIR" --runtime-smoke --write-stamp
}

# ---- Main ----
main() {
    echo "============================================" >&2
    echo "  Codex Desktop for Linux — Local Builder"   >&2
    echo "============================================" >&2
    echo ""                                             >&2

    parse_args "$@"
    check_deps
    check_npm_age_gate
    prepare_build
    ensure_node_tooling

    local dmg_path=""
    if [ -n "$PROVIDED_DMG_PATH" ]; then
        [ -f "$PROVIDED_DMG_PATH" ] || error "Provided DMG not found: $PROVIDED_DMG_PATH"
        dmg_path="$(realpath "$PROVIDED_DMG_PATH")"
        info "Using provided DMG: $dmg_path"
    else
        dmg_path=$(get_dmg)
    fi

    local app_dir
    app_dir=$(extract_dmg "$dmg_path")

    patch_asar "$app_dir"
    detect_min_codex_cli_version
    download_electron
    extract_webview "$app_dir"
    install_app
    create_start_script
    verify_gui_lite_safety

    echo ""                                             >&2
    echo "============================================" >&2
    info "Build complete!"
    echo "  Run:  ./run-codex-gui.sh"                   >&2
    echo "============================================" >&2
}

main "$@"
