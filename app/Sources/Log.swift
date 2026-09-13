import Foundation
import os

/// Minimal logging. Uses the unified logging system (visible in Console.app and
/// `log stream --predicate 'subsystem == "com.principledproductions.startupmovie"'`) and also
/// writes to stderr so it shows up in the LaunchAgent's StandardErrorPath log.
enum Log {
    private static let logger = Logger(subsystem: "com.principledproductions.startupmovie",
                                       category: "startup-movie")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        FileHandle.standardError.write(Data(("[StartupMovie] " + message + "\n").utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data(("[StartupMovie][error] " + message + "\n").utf8))
    }
}
