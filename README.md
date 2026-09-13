# Startup Movie

A tiny native macOS agent app that plays a bundled MP4 **once per macOS boot**,
during the first graphical login session after that boot, then quits — leaving
the user at the normal desktop. It is delivered as a signed `.pkg` for
deployment through an **Apple Business** Blueprint (macOS Packages).

It plays after a cold boot, restart, or shutdown→power-on. It does **not** play
after sleep/wake, lid close/open, display sleep, screen lock/unlock, Fast User
Switching, logout→login within the same boot, restarting Finder/Dock, or
relaunching the app itself.

---

## Contents

- [Architecture](#architecture)
- [How the post-boot launch works](#how-the-post-boot-launch-works)
- [How once-per-boot detection works](#how-once-per-boot-detection-works)
- [Why sleep/wake does not replay](#why-sleepwake-does-not-replay)
- [Where boot-session state is stored](#where-boot-session-state-is-stored)
- [Resetting state for development](#resetting-state-for-development)
- [Building the app](#building-the-app)
- [Replacing the video](#replacing-the-video)
- [Testing](#testing)
- [Building the .pkg](#building-the-pkg)
- [Installing locally](#installing-the-pkg-locally)
- [Uninstalling](#uninstalling)
- [Signing](#signing)
- [Notarization](#notarization)
- [Verifying signatures](#verifying-signatures)
- [Which artifact to upload to Apple Business](#which-artifact-to-upload-to-apple-business)
- [Deploying via an Apple Business Blueprint](#deploying-via-an-apple-business-blueprint)
- [Versioning](#versioning)
- [Failure behavior](#failure-behavior)

---

## Architecture

```
managed .pkg install
      │
      ▼
/Applications/Startup Movie.app          ← the agent app (LSUIElement, no Dock/menu)
/Library/LaunchAgents/com.principledproductions.startupmovie.plist   ← launches app at each GUI login
/Library/Application Support/Startup Movie/last-played-boot  ← once-per-boot state (shared)
      │
   full boot ──► user logs in ──► LaunchAgent runs the app in the user session
      │
      ▼
   app: is this boot already recorded?
        ├─ yes → exit immediately (sleep/wake, 2nd login, relaunch, FUS…)
        └─ no  → record boot id → wait ~1s → black fullscreen → play startup.mp4 once
                 → on end/failure/Esc/watchdog → restore cursor → quit
```

Source layout:

| Path | Purpose |
|------|---------|
| `app/Sources/main.swift` | Entry point; sets `.accessory` policy; installs uncaught-exception cursor restore. |
| `app/Sources/AppDelegate.swift` | Preflight, boot-guard, delay, black window(s), `AVPlayerLayer` playback, watchdogs, teardown. |
| `app/Sources/BootSession.swift` | Derives the boot id from `sysctl kern.boottime`. |
| `app/Sources/BootStateStore.swift` | `flock`-guarded, claim-before-play state file (machine-wide, per-user fallback). |
| `app/Sources/Config.swift` | Reads Info.plist keys + dev env vars. |
| `app/Sources/Log.swift` | Unified logging + stderr. |
| `app/Info.plist` | `LSUIElement`, version metadata, movie name/ext, startup delay. |
| `packaging/LaunchAgents/…plist` | The machine-wide LaunchAgent. |
| `packaging/scripts/postinstall` | Creates the shared, world-writable state file. |
| `packaging/distribution.xml` | `productbuild` distribution (unattended, all-users). |
| `config.sh` | **Single source of truth** for identifiers, versions, paths, signing identities. |
| `build.sh` / `Makefile` | Build + package + notarize + clean. |
| `scripts/` | `reset-state.sh`, `install-local.sh`, `uninstall.sh`. |
| `StartupMovie.xcodeproj` | Optional Xcode project for interactive development. |

Playback uses **AVFoundation** (`AVPlayer` + `AVPlayerLayer`), not QuickTime or
any external app. The window is a borderless, `screenSaver`-level, opaque black
window (one per display); the video uses `videoGravity = .resizeAspect` so it
fills the screen at its real aspect ratio with black bars, no chrome, no
controls. The cursor is hidden during playback and restored before exit.

---

## How the post-boot launch works

A **machine-wide LaunchAgent** at `/Library/LaunchAgents/com.principledproductions.startupmovie.plist`
is the launch mechanism. This is the correct, supported approach for a
package-deployed app that must run in the user's **graphical** session:

- `RunAtLoad = true` — launchd runs the app when the agent loads.
- `LimitLoadToSessionType = Aqua` — it loads **only** in a graphical login
  session, never in non-GUI contexts, so it never tries to show UI before a
  user session exists.
- It runs as the logged-in user (not root), which is exactly what video
  playback needs — no privileged helper, no root UI.
- Machine LaunchAgents in `/Library/LaunchAgents` are evaluated per user GUI
  session at login, which is why the trigger is "login-oriented."

**Why login-oriented is fine:** the agent may fire at every login, but the app
itself enforces once-per-boot semantics (below). This is the intended split:
`login triggers app → app decides whether to play`. There is no manual Login
Item to configure and no dependency on any user's home directory.

The `postinstall` script deliberately does **not** bootstrap/run the agent at
install time (that would play the movie in the middle of an unattended
install). launchd loads the agent automatically at the next graphical login —
i.e. after the next boot in the Blueprint flow.

Deprecated mechanisms (login items via AppleScript, `~/Library/LaunchAgents`
per-user hacks, `loginwindow` `LoginHook`) are intentionally avoided.

---

## How once-per-boot detection works

The boot session is identified natively from **`sysctl kern.boottime`** — the
kernel's record of when it finished booting (see `BootSession.currentBootID()`).
The id is a string like `boottime-1787862069.461871`.

State is a single small text file holding the boot id that has already played
(see [state location](#where-boot-session-state-is-stored)). On launch the app:

1. Verifies the bundled movie is present/readable (else exits — no state change).
2. Computes the current boot id.
3. **Claims** the boot atomically:
   - opens the state file for read/write (creating it, never truncating it),
   - takes an exclusive `flock`,
   - if the recorded id **equals** the current boot id → `already played` →
     **exit immediately**,
   - otherwise **writes the current boot id first (claim-before-play)**, then
     releases the lock and plays.

Recording the claim **before** playing (rather than after) is deliberate:

- Relaunching the app, or launchd invoking it more than once in the same boot,
  finds the id already recorded and exits — no replay.
- If two GUI sessions start at once (Fast User Switching), the `flock`
  serializes them and only the first records the id; the rest see it and exit.
  This is verified by a 40-way concurrency test (exactly one winner).

The `SM_FORCE_PLAY=1` environment variable bypasses the guard for development.
It is never set by the shipping LaunchAgent or package, so it cannot ship
enabled.

---

## Why sleep/wake does not replay

`kern.boottime` changes **only** when the kernel boots. It is unaffected by:

- sleep / wake, closing and reopening the lid, display sleep,
- screen lock / unlock,
- logout → login within the same boot,
- Fast User Switching,
- restarting Finder or Dock, or relaunching the app.

None of those reboot the kernel, so the boot id is unchanged, so the recorded id
still matches and the app exits immediately. Only a real cold boot / restart /
power-on produces a new `kern.boottime`, a new id, and therefore one new
playback. Wall-clock timestamps are intentionally **not** used — they cannot
distinguish a reboot from time simply passing.

---

## Where boot-session state is stored

- **Primary (production):** `/Library/Application Support/Startup Movie/last-played-boot`
  - machine-local, deterministic, shared across all users → "once per boot"
    applies to the whole machine, not per user;
  - created by the installer's `postinstall` as world-writable
    (dir `0777`, file `0666`) so any user's non-root GUI session can update it;
  - concurrent writers are serialized with `flock`.
- **Per-user fallback (development only):**
  `~/Library/Application Support/Startup Movie/last-played-boot`
  - used only when the machine-wide path is not writable (e.g. running from
    Xcode before the `.pkg` was ever installed), so development still works.

The file survives app termination, distinguishes reboot from sleep/wake (it
stores a boot id, not a flag), and does **not** permanently suppress future
playback — each new boot has a new id and plays once.

---

## Resetting state for development

Clear the recorded boot id so the next launch plays again without rebooting:

```bash
./scripts/reset-state.sh
# or: make reset-state
```

You can also bypass the guard entirely for a single run:

```bash
SM_FORCE_PLAY=1 "/Applications/Startup Movie.app/Contents/MacOS/StartupMovie"
```

When running from Xcode, the shared scheme already sets `SM_FORCE_PLAY=1`, so
every ⌘R plays regardless of state.

---

## Building the app

Requirements: **Xcode Command Line Tools** (full Xcode is *not* required for the
scripted build). Verify with `swiftc --version`.

```bash
./build.sh app        # builds a universal (arm64 + x86_64) Release .app into build/
```

`build.sh` compiles with `swiftc`, assembles `build/Startup Movie.app`, stamps
version metadata from `config.sh` into `Info.plist`, and bundles the video as
`Resources/startup.mp4`.

**Interactive development in Xcode** (needs full Xcode): open
`StartupMovie.xcodeproj` and press ⌘R. A build phase copies the source video in
as `startup.mp4`. The scheme sets `SM_FORCE_PLAY=1` so playback always runs;
press **Esc** to dismiss.

---

## Replacing the video

The app loads its movie by name (`startup` / `mp4`, from the `SMMovieResourceName`
/ `SMMovieResourceExtension` Info.plist keys) — no code change is ever needed.

- **Scripted build:** point `VIDEO_SOURCE` in `config.sh` at your MP4 (default
  `videos/hellokojo.mp4`). `build.sh` copies it to `Resources/startup.mp4`.
- **Xcode build:** the "Bundle startup.mp4" build phase copies
  `videos/hellokojo.mp4`; change that path (or the phase) to swap the asset.

The movie always lives **inside the app bundle**, never in a user's home
directory.

---

## Testing

### 1. Development playback testing

- **Self-test (no UI, no state change):**
  ```bash
  ./build.sh app
  SM_DRYRUN=1 "build/Startup Movie.app/Contents/MacOS/StartupMovie"
  ```
  Prints the boot id, resolved movie, state paths, and whether it *would* play.
- **Live playback without logging out:**
  ```bash
  SM_FORCE_PLAY=1 "build/Startup Movie.app/Contents/MacOS/StartupMovie"
  ```
  or ⌘R in Xcode. Press **Esc** to dismiss.

### 2. Boot-semantic testing (core acceptance criterion)

1. Restart the Mac. 2. Log in → **video plays**. 3. Sleep. 4. Wake →
**no play**. 5. Lock. 6. Unlock → **no play**. 7. Log out. 8. Log back in
(same boot) → **no play**. 9. Restart again. 10. Log in → **video plays**.

To watch decisions live: `log stream --predicate 'subsystem == "com.principledproductions.startupmovie"'`
(or read `/tmp/startupmovie.err.log`).

### 3. Deployment testing

See [Installing locally](#installing-the-pkg-locally). After install: restart,
log in, confirm the app starts automatically, the movie plays once, the app
exits, there is no Dock icon/menu-bar item, and sleep/wake does not replay.

---

## Building the .pkg

```bash
./build.sh            # or: ./build.sh pkg  /  make package
```

This builds the app (if needed), stages the payload, runs `pkgbuild` (component,
pinned non-relocatable to `/Applications`) and `productbuild` (unattended,
all-users distribution), signs the package if a signing identity is provided,
and writes the final artifact to:

```
dist/StartupMovie.pkg
```

The package is unattended (no interactive prompts), installs to deterministic
paths, and is idempotent/upgradeable: reinstalling overwrites the app in place
and `postinstall` re-initializes the shared state file so the next boot plays.

---

## Installing the .pkg locally

```bash
./scripts/install-local.sh          # runs: sudo installer -pkg dist/StartupMovie.pkg -target /
```

Verify installed paths:

```bash
ls -l "/Applications/Startup Movie.app"
ls -l "/Library/LaunchAgents/com.principledproductions.startupmovie.plist"
ls -ld "/Library/Application Support/Startup Movie"
pkgutil --pkg-info com.principledproductions.startupmovie.pkg
```

Then **restart and log in** for a true boot test. (To activate in the current
session without rebooting, log out/in, or bootstrap the agent manually — see the
hints printed by `install-local.sh`.)

---

## Uninstalling

```bash
./scripts/uninstall.sh
```

Removes the app, the LaunchAgent (unloading it for the current user), the state
directory, and the package receipt.

---

## Signing

Signing identities are supplied **externally** via environment variables (see
`config.sh`) and are never committed. Export them (e.g. in an untracked
`signing.local.sh` you `source`) before a production build:

```bash
export DEVELOPER_ID_APP="Developer ID Application: Example, Inc. (TEAMID)"
export DEVELOPER_ID_INSTALLER="Developer ID Installer: Example, Inc. (TEAMID)"
./build.sh            # app is signed with hardened runtime; pkg is productsign'd
```

- **App signing:** `codesign --options runtime --timestamp --sign "$DEVELOPER_ID_APP" "Startup Movie.app"`
  (done automatically by `build.sh` → `sign_app`).
- **Installer signing:** `productsign --sign "$DEVELOPER_ID_INSTALLER" <unsigned> dist/StartupMovie.pkg`
  (done automatically by `build.sh` → `sign_pkg`).

If the variables are unset, `build.sh` **ad-hoc** signs the app and leaves the
package unsigned — fine for local development, not for distribution.

---

## Notarization

Notarization **is advisable** for this deployment model. Although MDM push-install
of a Developer ID-signed pkg can bypass Gatekeeper prompts, notarizing (and
stapling) is the robust, future-proof choice: it keeps the package valid if it is
ever installed outside MDM, and aligns with Apple's expectations for distributed
software. Notarization requires Developer ID signing (above) and hardened runtime
(already applied to the app).

One-time credential setup:

```bash
xcrun notarytool store-credentials "StartupMovieNotary" \
  --apple-id "you@example.com" --team-id "TEAMID" --password "<app-specific-password>"
export NOTARY_PROFILE="StartupMovieNotary"
```

Then:

```bash
./build.sh              # produce the signed dist/StartupMovie.pkg
./build.sh notarize     # submit + wait + staple + validate
```

---

## Verifying signatures

```bash
# App
codesign --verify --deep --strict --verbose=2 "/Applications/Startup Movie.app"
spctl -a -vv --type execute "/Applications/Startup Movie.app"

# Installer package
pkgutil --check-signature dist/StartupMovie.pkg
spctl -a -vv --type install dist/StartupMovie.pkg

# Notarization ticket (after notarize)
xcrun stapler validate dist/StartupMovie.pkg
```

---

## Which artifact to upload to Apple Business

Upload **`dist/StartupMovie.pkg`** — the signed (and, recommended, notarized)
distribution package. That single file is the deployable artifact; it contains
the app, the LaunchAgent, and the postinstall that configures the shared state.

---

## Deploying via an Apple Business Blueprint

```
Build app  →  Build/sign (+notarize) StartupMovie.pkg
           →  Upload package to Apple Business → macOS Packages
           →  Add the package to a Blueprint
           →  Assign the Blueprint to the company Mac(s)
           →  Package installs on the managed Mac (unattended)
           →  Next full boot → user logs in → LaunchAgent runs the app
           →  App sees a new boot id → black fullscreen → plays startup.mp4 once → quits
```

The package is designed for exactly this: no interactive installer prompts, no
manual `.app` copy, no manually configured Login Items, deterministic paths, and
in-place upgrade when a newer package version is pushed.

---

## Versioning

All version metadata is centralized in `config.sh`:

| Field | `config.sh` variable | Where it lands |
|-------|----------------------|----------------|
| Application version | `APP_VERSION` | `CFBundleShortVersionString` |
| Build number | `BUILD_NUMBER` | `CFBundleVersion` |
| App identifier | `APP_BUNDLE_ID` | `CFBundleIdentifier` (`com.principledproductions.startupmovie`) |
| Package identifier | `PKG_IDENTIFIER` | pkg id (`com.principledproductions.startupmovie.pkg`) |
| Package version | `PKG_VERSION` | pkg + distribution version |

To cut a new version: bump the values in `config.sh` and run `./build.sh`.
Replace the placeholder `com.principledproductions` organization prefix with your real
reverse-DNS identifier.

---

## Failure behavior

The movie is decorative and must never trap the user. Every failure path exits
cleanly to the ordinary desktop, with the cursor restored and no lingering black
window:

- missing / unreadable movie → exit (before showing any UI, no state change);
- playback init failure or item `.failed` → exit;
- playback does not start within ~12s (start watchdog) → exit;
- playback overruns the video duration + 5s (end watchdog) → exit;
- uncaught exception → cursor restored via the top-level handler.

There are no retries that could repeatedly obscure the desktop, and no boot/login
loop: once a boot is recorded (which happens before playback), that boot will not
play again even if playback failed.
