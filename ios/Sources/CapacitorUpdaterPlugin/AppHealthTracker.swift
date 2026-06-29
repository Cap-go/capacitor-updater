import Foundation

final class AppHealthTracker {
    private let appSessionIdDefaultsKey = "CapacitorUpdater.appSessionId"
    private let appSessionForegroundDefaultsKey = "CapacitorUpdater.appSessionForeground"
    private let appSessionStartedAtDefaultsKey = "CapacitorUpdater.appSessionStartedAt"
    private let lastReportedUncleanSessionDefaultsKey = "CapacitorUpdater.lastReportedUncleanSessionId"

    private let implementation: CapgoUpdater

    init(implementation: CapgoUpdater) {
        self.implementation = implementation
    }

    static func shouldReportUncleanForegroundExit(
        previousSessionId: String?,
        lastReportedSessionId: String?,
        wasForeground: Bool
    ) -> Bool {
        guard wasForeground, let previousSessionId, !previousSessionId.isEmpty else {
            return false
        }
        return previousSessionId != lastReportedSessionId
    }

    func reportPreviousUncleanForegroundExit() {
        let defaults = UserDefaults.standard
        let previousSessionId = defaults.string(forKey: appSessionIdDefaultsKey)
        let lastReportedSessionId = defaults.string(forKey: lastReportedUncleanSessionDefaultsKey)
        let wasForeground = defaults.bool(forKey: appSessionForegroundDefaultsKey)

        guard Self.shouldReportUncleanForegroundExit(
            previousSessionId: previousSessionId,
            lastReportedSessionId: lastReportedSessionId,
            wasForeground: wasForeground
        ), let previousSessionId else {
            return
        }

        var metadata = [
            "exit_reason": "unclean_foreground_exit",
            "exit_source": "ios_session_marker",
            "previous_session_id": previousSessionId
        ]
        if let sessionStartedAt = defaults.string(forKey: appSessionStartedAtDefaultsKey), !sessionStartedAt.isEmpty {
            metadata["session_started_at"] = sessionStartedAt
        }

        let current = implementation.getCurrentBundle()
        implementation.sendStats(
            action: "app_crash",
            versionName: current.getVersionName(),
            oldVersionName: "",
            metadata: metadata
        )
        defaults.set(previousSessionId, forKey: lastReportedUncleanSessionDefaultsKey)
        defaults.synchronize()
    }

    func startSession() {
        let defaults = UserDefaults.standard
        defaults.set(UUID().uuidString, forKey: appSessionIdDefaultsKey)
        defaults.set(true, forKey: appSessionForegroundDefaultsKey)
        defaults.set(String(Int64(Date().timeIntervalSince1970 * 1000)), forKey: appSessionStartedAtDefaultsKey)
        defaults.synchronize()
    }

    func markForeground(_ isForeground: Bool) {
        UserDefaults.standard.set(isForeground, forKey: appSessionForegroundDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    func reportMemoryWarning() {
        let current = implementation.getCurrentBundle()
        implementation.sendStats(
            action: "app_memory_warning",
            versionName: current.getVersionName(),
            oldVersionName: "",
            metadata: ["source": "ios_memory_warning"]
        )
    }
}
