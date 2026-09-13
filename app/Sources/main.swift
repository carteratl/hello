import Cocoa

// Startup Movie — a background/agent app that plays a bundled MP4 once per
// macOS boot, during the first graphical login session after that boot, then
// quits. See README.md for architecture and deployment details.

// Last-resort safety: if something throws uncaught, make sure we never leave
// the mouse cursor hidden for the user. We cannot cleanly recover here, but we
// can undo the two global cursor-hiding calls the app may have made.
NSSetUncaughtExceptionHandler { _ in
    NSCursor.unhide()
    CGDisplayShowCursor(CGMainDisplayID())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Agent-style app: no Dock icon, no menu bar. This mirrors LSUIElement in
// Info.plist and also covers the case of running the raw binary directly.
app.setActivationPolicy(.accessory)
app.run()
