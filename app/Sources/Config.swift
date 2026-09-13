import Foundation

/// Runtime configuration, resolved from the app's Info.plist (so the behavior
/// can be tuned without touching code) and a small number of environment
/// variables used only for development/testing.
struct Config {
    /// Human-readable app name. Also used to locate the machine-wide state
    /// directory: `/Library/Application Support/<appName>/`.
    let appName: String

    /// URL of the bundled movie, or nil if it could not be found.
    let movieURL: URL?

    /// Seconds to wait after launch before presenting the video, so playback
    /// does not race the creation of the desktop/session.
    let startupDelay: TimeInterval

    /// Development override: when true, ignore the once-per-boot guard and play
    /// regardless. Driven by the `SM_FORCE_PLAY` env var only — it is never set
    /// by the shipping LaunchAgent, so it cannot accidentally ship enabled.
    let forcePlay: Bool

    /// Development/self-test mode: validate configuration (boot id, movie,
    /// state paths), print a summary, and exit WITHOUT showing any UI or
    /// mutating state. Driven by the `SM_DRYRUN` env var.
    let dryRun: Bool

    static func load() -> Config {
        let bundle = Bundle.main

        let appName = (bundle.object(forInfoDictionaryKey: "SMAppName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Startup Movie"

        // The movie is looked up by name/extension so that replacing the asset
        // never requires code changes — only the bundled file changes.
        let movieName = (bundle.object(forInfoDictionaryKey: "SMMovieResourceName") as? String) ?? "startup"
        let movieExt = (bundle.object(forInfoDictionaryKey: "SMMovieResourceExtension") as? String) ?? "mp4"
        let movieURL = bundle.url(forResource: movieName, withExtension: movieExt)

        let delay = (bundle.object(forInfoDictionaryKey: "SMStartupDelaySeconds") as? NSNumber)?.doubleValue ?? 1.0

        let env = ProcessInfo.processInfo.environment
        let forcePlay = (env["SM_FORCE_PLAY"] == "1")
        let dryRun = (env["SM_DRYRUN"] == "1")

        return Config(appName: appName,
                      movieURL: movieURL,
                      startupDelay: max(0, delay),
                      forcePlay: forcePlay,
                      dryRun: dryRun)
    }
}
