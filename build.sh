#!/bin/bash
#
# build.sh — build the Startup Movie app and produce a distributable installer.
#
# Usage:
#   ./build.sh              Build the Release .app and StartupMovie.pkg
#   ./build.sh app          Build only the .app bundle
#   ./build.sh pkg          Build the .app and the .pkg (default)
#   ./build.sh notarize     Notarize + staple dist/StartupMovie.pkg (needs NOTARY_PROFILE)
#   ./build.sh clean        Remove build/ and dist/ outputs
#
# Signing is controlled entirely by environment variables (see config.sh):
#   DEVELOPER_ID_APP        -> Developer ID Application identity for the .app
#   DEVELOPER_ID_INSTALLER  -> Developer ID Installer identity for the .pkg
# If unset, the app is ad-hoc signed and the package is left unsigned so that
# local development works with only the Command Line Tools installed.
#
# This script requires ONLY the Xcode Command Line Tools (swiftc, pkgbuild,
# productbuild, codesign) — full Xcode is not needed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# shellcheck source=config.sh
source "$ROOT/config.sh"

BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"
STAGE_DIR="$BUILD_DIR/stage"
COMPONENT_PKG="$BUILD_DIR/component.pkg"
FINAL_PKG="$DIST_DIR/StartupMovie.pkg"
PLISTBUDDY="/usr/libexec/PlistBuddy"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
build_app() {
    log "Verifying required video asset: $VIDEO_SOURCE"
    [ -f "$ROOT/$VIDEO_SOURCE" ] || die "Video asset not found at '$VIDEO_SOURCE'. Place your MP4 there (see config.sh: VIDEO_SOURCE)."

    log "Compiling universal (arm64 + x86_64) Release binary with swiftc"
    local sdk; sdk="$(xcrun --sdk macosx --show-sdk-path)"
    local sources=("$ROOT"/app/Sources/*.swift)
    local objdir="$BUILD_DIR/obj"
    rm -rf "$objdir"; mkdir -p "$objdir"

    local slices=()
    for arch in arm64 x86_64; do
        log "  - slice: $arch"
        if swiftc -O -sdk "$sdk" \
            -target "${arch}-apple-macos${MIN_MACOS}" \
            -framework Cocoa -framework AVFoundation \
            -o "$objdir/${APP_EXECUTABLE}.${arch}" \
            "${sources[@]}" 2> "$objdir/${arch}.log"; then
            slices+=("$objdir/${APP_EXECUTABLE}.${arch}")
        else
            warn "Could not build $arch slice (see $objdir/${arch}.log); continuing without it."
        fi
    done
    [ ${#slices[@]} -gt 0 ] || die "Compilation failed for all architectures."

    log "Assembling app bundle: $APP_BUNDLE"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

    lipo -create -output "$APP_BUNDLE/Contents/MacOS/${APP_EXECUTABLE}" "${slices[@]}"
    lipo -info "$APP_BUNDLE/Contents/MacOS/${APP_EXECUTABLE}"

    cp "$ROOT/app/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

    log "Stamping version metadata into Info.plist"
    "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
    "$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER"           "$APP_BUNDLE/Contents/Info.plist"
    "$PLISTBUDDY" -c "Set :CFBundleIdentifier $APP_BUNDLE_ID"       "$APP_BUNDLE/Contents/Info.plist"
    "$PLISTBUDDY" -c "Set :LSMinimumSystemVersion $MIN_MACOS"       "$APP_BUNDLE/Contents/Info.plist"
    "$PLISTBUDDY" -c "Set :SMAppName $APP_NAME"                     "$APP_BUNDLE/Contents/Info.plist"
    "$PLISTBUDDY" -c "Set :SMStartupDelaySeconds $STARTUP_DELAY"    "$APP_BUNDLE/Contents/Info.plist"

    log "Bundling video asset as Resources/startup.mp4"
    cp "$ROOT/$VIDEO_SOURCE" "$APP_BUNDLE/Contents/Resources/startup.mp4"

    sign_app
}

sign_app() {
    if [ -n "${DEVELOPER_ID_APP}" ]; then
        log "Signing app with Developer ID: $DEVELOPER_ID_APP (hardened runtime)"
        codesign --force --options runtime --timestamp \
            --sign "$DEVELOPER_ID_APP" "$APP_BUNDLE"
    else
        warn "DEVELOPER_ID_APP not set — ad-hoc signing the app (development only)."
        codesign --force --sign - "$APP_BUNDLE"
    fi
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" \
        && log "App signature verified." \
        || warn "App signature verification reported issues."
}

# ---------------------------------------------------------------------------
build_pkg() {
    [ -d "$APP_BUNDLE" ] || build_app

    log "Staging package payload"
    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR/Applications"
    mkdir -p "$STAGE_DIR/Library/LaunchAgents"
    mkdir -p "$STAGE_DIR${APP_SUPPORT_DIR}"

    cp -R "$APP_BUNDLE" "$STAGE_DIR/Applications/"
    cp "$ROOT/packaging/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist" \
       "$STAGE_DIR/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

    # Strip extended attributes (quarantine/provenance/etc.) so the package
    # payload does not carry AppleDouble "._" entries. Safe for the bundle: the
    # code signature lives in Contents/_CodeSignature, not in an xattr.
    xattr -rc "$STAGE_DIR"

    chmod +x "$ROOT/packaging/scripts/postinstall"

    log "Building component package with pkgbuild"
    mkdir -p "$BUILD_DIR"

    # Pin the app to /Applications: mark it non-relocatable so the installer
    # never redirects it to a pre-existing copy elsewhere. This keeps install
    # paths deterministic and makes upgrades overwrite in place.
    local complist="$BUILD_DIR/component.plist"
    pkgbuild --analyze --root "$STAGE_DIR" "$complist" >/dev/null
    "$PLISTBUDDY" -c "Set :0:BundleIsRelocatable false" "$complist" 2>/dev/null || true

    pkgbuild \
        --root "$STAGE_DIR" \
        --component-plist "$complist" \
        --identifier "$PKG_IDENTIFIER" \
        --version "$PKG_VERSION" \
        --scripts "$ROOT/packaging/scripts" \
        --install-location "/" \
        --ownership recommended \
        "$COMPONENT_PKG"

    log "Building distribution package with productbuild"
    local dist="$BUILD_DIR/distribution.xml"
    sed -e "s|__APP_TITLE__|${APP_NAME}|g" \
        -e "s|__MIN_MACOS__|${MIN_MACOS}|g" \
        -e "s|__PKG_IDENTIFIER__|${PKG_IDENTIFIER}|g" \
        -e "s|__PKG_VERSION__|${PKG_VERSION}|g" \
        -e "s|__COMPONENT_PKG__|component.pkg|g" \
        "$ROOT/packaging/distribution.xml" > "$dist"

    mkdir -p "$DIST_DIR"
    local unsigned="$BUILD_DIR/StartupMovie-unsigned.pkg"
    productbuild \
        --distribution "$dist" \
        --package-path "$BUILD_DIR" \
        "$unsigned"

    sign_pkg "$unsigned"
    verify_pkg
    log "Done. Installer: $FINAL_PKG"
}

sign_pkg() {
    local unsigned="$1"
    if [ -n "${DEVELOPER_ID_INSTALLER}" ]; then
        log "Signing installer with Developer ID Installer: $DEVELOPER_ID_INSTALLER"
        productsign --sign "$DEVELOPER_ID_INSTALLER" "$unsigned" "$FINAL_PKG"
    else
        warn "DEVELOPER_ID_INSTALLER not set — leaving package unsigned (development only)."
        cp "$unsigned" "$FINAL_PKG"
    fi
}

verify_pkg() {
    log "Package summary"
    pkgutil --payload-files "$FINAL_PKG" | sed 's/^/    /' || true
    if [ -n "${DEVELOPER_ID_INSTALLER}" ]; then
        pkgutil --check-signature "$FINAL_PKG" || warn "pkg signature check reported issues."
    fi
}

# ---------------------------------------------------------------------------
notarize() {
    [ -f "$FINAL_PKG" ] || die "No package at $FINAL_PKG. Run ./build.sh first."
    [ -n "${NOTARY_PROFILE}" ] || die "NOTARY_PROFILE not set. Store credentials with:
    xcrun notarytool store-credentials <profile-name> --apple-id <id> --team-id <TEAMID> --password <app-specific-password>"
    log "Submitting to Apple notary service (this may take a few minutes)"
    xcrun notarytool submit "$FINAL_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$FINAL_PKG"
    xcrun stapler validate "$FINAL_PKG"
    log "Notarized and stapled: $FINAL_PKG"
}

clean() {
    log "Removing build/ and dist/"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
}

# ---------------------------------------------------------------------------
case "${1:-pkg}" in
    app)      build_app ;;
    pkg)      build_pkg ;;
    notarize) notarize ;;
    clean)    clean ;;
    *)        die "Unknown command '$1' (use: app | pkg | notarize | clean)" ;;
esac
