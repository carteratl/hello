import Foundation

/// Identifies the current macOS boot session.
enum BootSession {
    /// A stable identifier for the current boot, derived from `kern.boottime`.
    ///
    /// Why `kern.boottime`:
    ///   * It is the wall-clock instant the kernel finished booting.
    ///   * It changes on every real boot / restart / power-on.
    ///   * It is **NOT** affected by sleep/wake, display sleep, closing the lid,
    ///     screen lock/unlock, logout/login, Fast User Switching, or restarting
    ///     Finder/Dock — none of those re-boot the kernel.
    ///
    /// This is exactly the "play once per boot, not once per login" distinction
    /// the app needs, so it is the boot-session key we persist.
    static func currentBootID() -> String {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        let rc = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        if rc == 0 {
            // Include microseconds for extra uniqueness; boottime is constant
            // for the life of a boot, so this string is stable within a boot
            // and different across boots.
            return "boottime-\(tv.tv_sec).\(tv.tv_usec)"
        }
        // Extremely unlikely fallback. Uptime is monotonic-ish and at least
        // avoids returning a constant; a bad read must not crash the app.
        Log.error("sysctl kern.boottime failed (rc=\(rc)); using uptime fallback")
        return "uptime-fallback-\(Int(ProcessInfo.processInfo.systemUptime))"
    }
}
