#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_DIR/scripts/lib/package-common.sh"
APP_DIR="${APP_DIR_OVERRIDE:-$REPO_DIR/codex-app}"
DIST_DIR="${DIST_DIR_OVERRIDE:-$REPO_DIR/dist}"
SPEC_TEMPLATE="$REPO_DIR/packaging/linux/codex-desktop.spec"
DESKTOP_TEMPLATE="$REPO_DIR/packaging/linux/codex-desktop.desktop"
SERVICE_TEMPLATE="$REPO_DIR/packaging/linux/codex-update-manager.service"
ICON_SOURCE="$REPO_DIR/assets/codex.png"
PACKAGED_RUNTIME_TEMPLATE="$REPO_DIR/packaging/linux/codex-packaged-runtime.sh"

PACKAGE_NAME="${PACKAGE_NAME:-codex-desktop}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(date -u +%Y.%m.%d.%H%M%S)}"
UPDATER_BINARY_SOURCE="${UPDATER_BINARY_SOURCE:-$REPO_DIR/target/release/codex-update-manager}"
UPDATER_SERVICE_SOURCE="${UPDATER_SERVICE_SOURCE:-$SERVICE_TEMPLATE}"
PACKAGED_RUNTIME_SOURCE="${PACKAGED_RUNTIME_SOURCE:-$PACKAGED_RUNTIME_TEMPLATE}"

map_arch() {
    case "$(uname -m)" in
        x86_64)  echo "x86_64" ;;
        aarch64) echo "aarch64" ;;
        armv7l)  echo "armv7hl" ;;
        *)       error "Unsupported architecture: $(uname -m)" ;;
    esac
}

# RPM version must not contain '+'; split PACKAGE_VERSION on '+' into version and release
rpm_version_parts() {
    local base
    base="${PACKAGE_VERSION%%+*}"
    local hash
    hash="${PACKAGE_VERSION#*+}"
    if [ "$base" = "$PACKAGE_VERSION" ]; then
        hash="1"
    fi
    RPM_VERSION="$base"
    RPM_RELEASE="$hash"
}

main() {
    ensure_app_layout
    ensure_file_exists "$SPEC_TEMPLATE" "spec template"
    ensure_file_exists "$DESKTOP_TEMPLATE" "desktop template"
    ensure_file_exists "$UPDATER_SERVICE_SOURCE" "updater service template"
    ensure_file_exists "$ICON_SOURCE" "icon"
    ensure_file_exists "$PACKAGED_RUNTIME_SOURCE" "packaged launcher runtime helper"
    command -v rpmbuild >/dev/null 2>&1 || error "rpmbuild is required (install rpm-build)"

    ensure_updater_binary

    local arch
    arch="$(map_arch)"
    rpm_version_parts
    local rpm_ver="$RPM_VERSION"
    local rpm_rel="$RPM_RELEASE"

    local build_root
    build_root="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$build_root'" EXIT

    local br="$build_root/BUILDROOT"
    stage_common_package_files "$br"
    stage_update_builder_bundle "$br"
    write_launcher_stub "$br"

    local spec_file="$build_root/codex-desktop.spec"
    sed \
        -e "s/__PACKAGE_NAME__/$PACKAGE_NAME/g" \
        -e "s/__RPM_VERSION__/$rpm_ver/g" \
        -e "s/__RPM_RELEASE__/$rpm_rel/g" \
        -e "s/__ARCH__/$arch/g" \
        "$SPEC_TEMPLATE" > "$spec_file"

    local rpmbuild_dir="$build_root/rpmbuild"
    mkdir -p \
        "$rpmbuild_dir/RPMS" \
        "$rpmbuild_dir/SRPMS" \
        "$rpmbuild_dir/BUILD" \
        "$rpmbuild_dir/SOURCES" \
        "$rpmbuild_dir/SPECS"

    mkdir -p "$DIST_DIR"
    info "Building $PACKAGE_NAME-${rpm_ver}-${rpm_rel}.${arch}.rpm"
    rpmbuild -bb \
        --buildroot "$br" \
        --define "_rpmdir $rpmbuild_dir/RPMS" \
        --define "_srcrpmdir $rpmbuild_dir/SRPMS" \
        --define "_builddir $rpmbuild_dir/BUILD" \
        --define "_sourcedir $rpmbuild_dir/SOURCES" \
        --define "_specdir $build_root" \
        --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
        "$spec_file" >&2

    local rpm_file
    rpm_file="$(find "$rpmbuild_dir/RPMS" -name "*.rpm" | head -n 1)"
    [ -f "$rpm_file" ] || error "rpmbuild did not produce an RPM"

    local output_file="$DIST_DIR/${PACKAGE_NAME}-${rpm_ver}-${rpm_rel}.${arch}.rpm"
    cp "$rpm_file" "$output_file"
    info "Built package: $output_file"
}

main "$@"
