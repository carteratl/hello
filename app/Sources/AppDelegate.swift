import Cocoa
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Windows: one black window per screen. The main screen's window also hosts
    // the video layer; the others are just black so no desktop peeks through on
    // multi-display Macs.
    private var windows: [NSWindow] = []
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserverItem: AVPlayerItem?

    private var escapeMonitor: Any?
    private var startWatchdog: DispatchWorkItem?
    private var endWatchdog: DispatchWorkItem?

    private var cursorHidden = false
    private var isExiting = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.load()

        // (1) Resolve the movie first. If it is missing/unreadable we exit
        //     immediately, before showing anything and before touching state —
        //     the correct fallback is the ordinary desktop.
        guard let movieURL = config.movieURL,
              FileManager.default.isReadableFile(atPath: movieURL.path) else {
            Log.error("bundled movie missing or unreadable; exiting without playing")
            cleanExit(0)
            return
        }

        // Self-test / dry run: validate everything and exit without UI or state
        // changes. Safe to run repeatedly.
        if config.dryRun {
            runDryRun(config: config, movieURL: movieURL)
            cleanExit(0)
            return
        }

        // (2) Once-per-boot guard.
        if config.forcePlay {
            Log.info("SM_FORCE_PLAY set — bypassing once-per-boot guard (dev)")
        } else {
            let store = BootStateStore(appName: config.appName)
            let bootID = BootSession.currentBootID()
            switch store.claim(bootID: bootID) {
            case .alreadyPlayed:
                Log.info("movie already played for this boot (\(bootID)); exiting")
                cleanExit(0)
                return
            case .claimed:
                Log.info("claimed playback for boot \(bootID)")
            case .noState:
                Log.info("no writable state store; proceeding to play (dev fallback)")
            }
        }

        // (3) Wait briefly so we don't race desktop/session creation, then play.
        let delay = config.startupDelay
        Log.info("will present after \(delay)s delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.presentAndPlay(url: movieURL)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        showCursor()
    }

    // Never keep the app alive on an empty screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Presentation

    private func presentAndPlay(url: URL) {
        guard !isExiting else { return }
        guard let mainScreen = NSScreen.main else {
            Log.error("no main screen; exiting")
            cleanExit(0)
            return
        }

        // Build a black cover window for every screen.
        for screen in NSScreen.screens {
            let window = makeBlackWindow(frame: screen.frame)
            windows.append(window)
            if screen == mainScreen {
                attachPlayer(to: window, url: url)
            }
        }

        // Bring our windows to the foreground and capture key events (Escape).
        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()

        installEscapeMonitor()
        hideCursor()
        scheduleStartWatchdog()

        player?.play()
    }

    private func makeBlackWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(contentRect: frame,
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.level = .screenSaver               // above menu bar, Dock, most windows
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks fall through; no interaction
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = content
        return window
    }

    private func attachPlayer(to window: NSWindow, url: URL) {
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        player.volume = 1.0                        // audio plays normally

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect         // fill display, keep aspect, black bars
        layer.backgroundColor = NSColor.black.cgColor
        if let content = window.contentView {
            layer.frame = content.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            content.layer?.addSublayer(layer)
        }

        self.player = player
        self.playerLayer = layer

        let item = player.currentItem
        self.timeObserverItem = item
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerDidPlayToEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime, object: item)
        NotificationCenter.default.addObserver(
            self, selector: #selector(playerFailedToPlayToEnd(_:)),
            name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        item?.addObserver(self, forKeyPath: "status", options: [.new, .initial], context: nil)
    }

    // MARK: - Playback observation

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "status", let item = object as? AVPlayerItem else { return }
        switch item.status {
        case .readyToPlay:
            startWatchdog?.cancel()
            scheduleEndWatchdog(for: item)
        case .failed:
            Log.error("player item failed: \(item.error?.localizedDescription ?? "unknown")")
            finish(reason: "item failed")
        default:
            break
        }
    }

    @objc private func playerDidPlayToEnd(_ note: Notification) {
        Log.info("playback finished")
        finish(reason: "did play to end")
    }

    @objc private func playerFailedToPlayToEnd(_ note: Notification) {
        Log.error("playback failed to reach end")
        finish(reason: "failed to play to end")
    }

    // MARK: - Watchdogs (fail safe — never leave a black screen up)

    /// If playback has not become ready within a short window, give up.
    private func scheduleStartWatchdog() {
        let work = DispatchWorkItem { [weak self] in
            Log.error("playback did not start in time; exiting")
            self?.finish(reason: "start watchdog")
        }
        startWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    /// Hard cap based on the item's duration (plus slack) so a stuck player can
    /// never hold the black screen indefinitely.
    private func scheduleEndWatchdog(for item: AVPlayerItem) {
        endWatchdog?.cancel()
        let seconds = item.duration.isNumeric ? CMTimeGetSeconds(item.duration) : 60.0
        let cap = (seconds.isFinite && seconds > 0 ? seconds : 60.0) + 5.0
        let work = DispatchWorkItem { [weak self] in
            Log.error("end watchdog fired (cap \(cap)s); exiting")
            self?.finish(reason: "end watchdog")
        }
        endWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cap, execute: work)
    }

    // MARK: - Escape (emergency dismiss)

    private func installEscapeMonitor() {
        // Local monitor only — sees this app's own key events, so it needs no
        // Accessibility permission and does not simulate keystrokes.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Log.info("escape pressed; dismissing")
                self?.finish(reason: "escape")
                return nil
            }
            return event
        }
    }

    // MARK: - Teardown

    private func finish(reason: String) {
        guard !isExiting else { return }
        Log.info("finishing (\(reason))")
        cleanExit(0)
    }

    private func cleanExit(_ code: Int32) {
        if isExiting { return }
        isExiting = true

        startWatchdog?.cancel()
        endWatchdog?.cancel()

        player?.pause()

        if let item = timeObserverItem {
            item.removeObserver(self, forKeyPath: "status")
        }
        NotificationCenter.default.removeObserver(self)

        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }

        showCursor()

        for window in windows { window.orderOut(nil) }
        windows.removeAll()

        // exit() flushes stdio and guarantees the process is gone; there is no
        // work to defer and nothing to save.
        exit(code)
    }

    // MARK: - Cursor

    private func hideCursor() {
        NSCursor.hide()
        CGDisplayHideCursor(CGMainDisplayID())
        cursorHidden = true
    }

    private func showCursor() {
        if cursorHidden {
            NSCursor.unhide()
            CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
    }

    // MARK: - Dry run / self test

    private func runDryRun(config: Config, movieURL: URL) {
        let store = BootStateStore(appName: config.appName)
        let bootID = BootSession.currentBootID()
        let recorded = store.recordedBootID() ?? "(none)"
        let wouldPlay = (recorded != bootID)
        let lines = """
        SM_DRYRUN self-test
          appName         : \(config.appName)
          bootID          : \(bootID)
          recordedBootID  : \(recorded)
          wouldPlay       : \(wouldPlay)
          startupDelay    : \(config.startupDelay)s
          movie           : \(movieURL.path)
          movieReadable   : true
          statePrimary    : \(store.primaryURL.path)
          stateWritable   : \(store.writablePathForDiagnostics() ?? "(none)")
        """
        print(lines)
        Log.info("dry-run complete")
    }
}
