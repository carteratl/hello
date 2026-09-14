#!/bin/bash
# Centralized configuration for building and packaging Startup Movie.
# Edit values here (and nowhere else) to cut a new version.

# --- Identity ---------------------------------------------------------------
APP_NAME="Startup Movie"                       # .app bundle display name
APP_EXECUTABLE="StartupMovie"                   # Mach-O executable name (no spaces)
APP_BUNDLE_ID="com.principledproductions.startupmovie"        # reverse-DNS app identifier
PKG_IDENTIFIER="com.principledproductions.startupmovie.pkg"   # reverse-DNS installer identifier
LAUNCH_AGENT_LABEL="com.principledproductions.startupmovie"   # LaunchAgent label + plist name

# --- Versioning -------------------------------------------------------------
APP_VERSION="1.0.1"      # CFBundleShortVersionString (marketing version)
BUILD_NUMBER="2"         # CFBundleVersion (build number)
PKG_VERSION="1.0.1"      # installer package version

# --- Behavior ---------------------------------------------------------------
STARTUP_DELAY="0"        # seconds to wait after login before presenting video (0 = immediate)
MIN_MACOS="12.0"         # LSMinimumSystemVersion / deployment target

# --- Paths ------------------------------------------------------------------
INSTALL_DIR="/Applications"                      # app install location
APP_SUPPORT_DIR="/Library/Application Support/${APP_NAME}"  # machine-wide state dir
VIDEO_SOURCE="videos/hellokojo.mp4"              # source movie; copied to Resources/startup.mp4

# --- Signing (supplied externally; never commit real values) ----------------
# Export these in your environment (or a local, untracked file) before building
# a production package. Leave empty for local/ad-hoc development builds.
#   DEVELOPER_ID_APP        e.g. "Developer ID Application: Example, Inc. (TEAMID)"
#   DEVELOPER_ID_INSTALLER  e.g. "Developer ID Installer: Example, Inc. (TEAMID)"
DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-}"
DEVELOPER_ID_INSTALLER="${DEVELOPER_ID_INSTALLER:-}"

# Notarization (optional; see build.sh notarize + README).
#   NOTARY_PROFILE   name of a stored `notarytool` keychain profile
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
