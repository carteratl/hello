import Foundation

/// Result of attempting to claim playback for the current boot.
enum ClaimResult {
    /// This process won the claim and should play the movie.
    case claimed
    /// The movie has already been played (or claimed) for this boot; exit.
    case alreadyPlayed
    /// No writable state store is available. The caller decides what to do; in
    /// practice this only happens in a misconfigured dev environment, where we
    /// prefer to play so the developer sees the video.
    case noState
}

/// Persists "which boot session already played the movie" and arbitrates
/// concurrent launches.
///
/// Design:
///   * A single small text file holds the boot id that has already played.
///   * The machine-wide path is preferred so the "once per boot" guarantee is
///     shared across ALL users (the first appropriate login after boot plays;
///     later logins / Fast User Switching do not). The installer makes this
///     file world-writable.
///   * A per-user fallback path is used only when the machine-wide path is not
///     writable (e.g. running from Xcode before the .pkg has ever been
///     installed) so development still works.
///   * All create/read/compare/write happens INSIDE an exclusive advisory lock
///     (`flock`) on the state file, and the file is opened with `O_CREAT` but
///     never truncated outside the lock. We record the claim before playing.
///     Together these guarantee:
///       - Two sessions launched at once (Fast User Switching) can never both
///         play — exactly one wins the claim; the rest see the recorded id.
///       - Relaunching the app within the same boot never replays.
final class BootStateStore {
    let primaryURL: URL
    let fallbackURL: URL

    init(appName: String) {
        primaryURL = URL(fileURLWithPath: "/Library/Application Support/\(appName)/last-played-boot")
        let userAppSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                      in: .userDomainMask).first!
        fallbackURL = userAppSupport.appendingPathComponent("\(appName)/last-played-boot")
    }

    private var candidates: [URL] { [primaryURL, fallbackURL] }

    /// Atomically claim playback for `bootID`.
    ///
    /// Uses the first candidate path that can be opened for read/write (creating
    /// it, without truncation, if necessary). Returns `.alreadyPlayed` if this
    /// boot already played, `.claimed` if this process should play (recording
    /// the claim before returning), or `.noState` if no path is usable.
    func claim(bootID: String) -> ClaimResult {
        for url in candidates {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            // O_CREAT (no O_TRUNC): create if missing, but never wipe an
            // existing record. All mutation happens under the lock below.
            let fd = open(url.path, O_RDWR | O_CREAT, 0o666)
            if fd < 0 { continue }   // not usable (e.g. /Library not writable) -> try fallback
            defer { close(fd) }

            if flock(fd, LOCK_EX) != 0 {
                Log.error("could not lock state file \(url.path): errno \(errno)")
                continue
            }
            defer { flock(fd, LOCK_UN) }

            let existing = readAll(fd: fd).trimmingCharacters(in: .whitespacesAndNewlines)
            if existing == bootID {
                return .alreadyPlayed
            }

            // Record the claim *before* playing so a crash/relaunch within the
            // same boot will not replay.
            writeAll(fd: fd, string: bootID + "\n")
            return .claimed
        }
        return .noState
    }

    /// Read the currently-recorded boot id without creating or mutating
    /// anything. Used by dry-run/self-test.
    func recordedBootID() -> String? {
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// The path `claim` would use, determined WITHOUT creating or truncating
    /// any file. For diagnostics only.
    func writablePathForDiagnostics() -> String? {
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                if access(url.path, W_OK) == 0 { return url.path }
            } else {
                // File missing: usable if we could create it in the directory.
                let dir = url.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if access(dir.path, W_OK) == 0 { return url.path }
            }
        }
        return nil
    }

    // MARK: - Low-level file helpers (operate on the locked fd)

    private func readAll(fd: Int32) -> String {
        lseek(fd, 0, SEEK_SET)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeAll(fd: Int32, string: String) {
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let bytes = Array(string.utf8)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        fsync(fd)
    }
}
