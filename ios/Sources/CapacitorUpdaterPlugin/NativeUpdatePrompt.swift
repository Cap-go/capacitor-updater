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

    init(plugin: CapacitorUpdaterPlugin) {
        self.plugin = plugin
        let config = plugin.getConfig()
        self.enabled = config.getBoolean("nativeUpdatePrompt", false)
        self.onStoreCheck = config.getBoolean("nativeUpdatePromptOnStoreCheck", false)
        self.title = config.getString("nativeUpdatePromptTitle")
        self.message = config.getString("nativeUpdatePromptMessage")
        self.updateButton = config.getString("nativeUpdatePromptUpdateButton")
        self.laterButton = config.getString("nativeUpdatePromptLaterButton")
        self.countryFilter = config.getString("nativeUpdatePromptCountry")
        let cooldownHours = max(1, config.getInt("nativeUpdatePromptCooldownHours", 24))
        self.cooldownMs = TimeInterval(cooldownHours) * 60 * 60
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
