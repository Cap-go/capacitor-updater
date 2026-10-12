import Foundation
import UIKit

final class NativeUpdatePromptCoordinator {
    static let lastNativeVersionDefaultsKey = "CapacitorUpdater.nativeUpdatePromptLastNativeVersion"
    static let lastShownMsDefaultsKey = "CapacitorUpdater.nativeUpdatePromptLastShownMs"

    private static var sessionShownNativeVersions = Set<String>()

    static func resetSessionStateForTesting() {
        sessionShownNativeVersions.removeAll()
    }

    private let enabled: Bool
    private let onStoreCheck: Bool
    private let title: String?
    private let message: String?
    private let updateButton: String?
    private let laterButton: String?
    private let countryFilter: String?
    private let cooldownMs: TimeInterval
    private weak var plugin: CapacitorUpdaterPlugin?

    convenience init(plugin: CapacitorUpdaterPlugin) {
        let config = plugin.getConfig()
        self.init(
            plugin: plugin,
            enabled: config.getBoolean("nativeUpdatePrompt", false),
            onStoreCheck: config.getBoolean("nativeUpdatePromptOnStoreCheck", false),
            title: config.getString("nativeUpdatePromptTitle"),
            message: config.getString("nativeUpdatePromptMessage"),
            updateButton: config.getString("nativeUpdatePromptUpdateButton"),
            laterButton: config.getString("nativeUpdatePromptLaterButton"),
            countryFilter: config.getString("nativeUpdatePromptCountry"),
            cooldownHours: config.getInt("nativeUpdatePromptCooldownHours", 24)
        )
    }

    init(
        plugin: CapacitorUpdaterPlugin?,
        enabled: Bool = false,
        onStoreCheck: Bool = false,
        title: String? = nil,
        message: String? = nil,
        updateButton: String? = nil,
        laterButton: String? = nil,
        countryFilter: String? = nil,
        cooldownHours: Int = 24
    ) {
        self.plugin = plugin
        self.enabled = enabled
        self.onStoreCheck = onStoreCheck
        self.title = title
        self.message = message
        self.updateButton = updateButton
        self.laterButton = laterButton
        self.countryFilter = countryFilter
        let normalizedCooldownHours = max(1, cooldownHours)
        self.cooldownMs = TimeInterval(normalizedCooldownHours) * 60 * 60
    }

    var isOnStoreCheckEnabled: Bool {
        enabled && onStoreCheck
    }

    static func isNativeStoreUpdateBlock(response: AppVersion) -> Bool {
        if response.breaking == true {
            return true
        }
        if response.message == "store_update_required" {
            return true
        }
        let error = response.error ?? ""
        return error.hasPrefix("disable_auto_update")
    }

    func maybeShowForUpdateBlock(response: AppVersion) {
        guard enabled, Self.isNativeStoreUpdateBlock(response: response) else {
            return
        }
        scheduleShow()
    }

    func maybeShowForStoreUpdateAvailable() {
        guard isOnStoreCheckEnabled else {
            return
        }
        scheduleShow()
    }

    private func scheduleShow() {
        guard matchesCountryFilter() else {
            return
        }
        guard let plugin = plugin else {
            return
        }
        let nativeVersion = plugin.currentBuildVersionForNativeUpdatePrompt()
        guard !nativeVersion.isEmpty else {
            return
        }
        guard shouldShowForNativeVersion(nativeVersion) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            self.showDialog(nativeVersion: nativeVersion)
        }
    }

    func shouldShowForNativeVersion(_ nativeVersion: String) -> Bool {
        if Self.sessionShownNativeVersions.contains(nativeVersion) {
            return false
        }
        let lastVersion = UserDefaults.standard.string(forKey: Self.lastNativeVersionDefaultsKey) ?? ""
        let lastShown = UserDefaults.standard.double(forKey: Self.lastShownMsDefaultsKey)
        if nativeVersion == lastVersion, lastShown > 0 {
            let elapsed = Date().timeIntervalSince1970 - lastShown
            if elapsed < cooldownMs {
                return false
            }
        }
        return true
    }

    func matchesCountryFilter() -> Bool {
        guard let filter = countryFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else {
            return true
        }
        let deviceCountry = Self.currentDeviceRegionCode()
        if deviceCountry.isEmpty {
            return false
        }
        let normalizedDevice = deviceCountry.uppercased()
        return filter
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .contains(normalizedDevice)
    }

    private func showDialog(nativeVersion: String) {
        guard let plugin = plugin else {
            return
        }
        if let topVC = UIApplication.topViewController(plugin.bridge?.viewController),
           topVC.isKind(of: UIAlertController.self) {
            return
        }

        let dialogTitle = (title?.isEmpty == false ? title : nil) ?? "Update available"
        let dialogMessage = (message?.isEmpty == false ? message : nil)
            ?? "A new version of this app is available in the store. Update now to continue receiving live updates."
        let positive = (updateButton?.isEmpty == false ? updateButton : nil) ?? "Update"
        let negative = (laterButton?.isEmpty == false ? laterButton : nil) ?? "Not now"

        let alert = UIAlertController(title: dialogTitle, message: dialogMessage, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: negative, style: .cancel) { _ in
            self.recordShown(nativeVersion: nativeVersion)
        })
        alert.addAction(UIAlertAction(title: positive, style: .default) { _ in
            self.recordShown(nativeVersion: nativeVersion)
            plugin.openAppStoreFromNativeUpdatePrompt()
        })

        if let topVC = UIApplication.topViewController(plugin.bridge?.viewController) {
            topVC.present(alert, animated: true)
        }
    }

    func recordShown(nativeVersion: String) {
        Self.sessionShownNativeVersions.insert(nativeVersion)
        UserDefaults.standard.set(nativeVersion, forKey: Self.lastNativeVersionDefaultsKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastShownMsDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    private static func currentDeviceRegionCode() -> String {
        if #available(iOS 16, *) {
            return Locale.current.region?.identifier ?? ""
        }
        return Locale.current.regionCode ?? ""
    }
}
