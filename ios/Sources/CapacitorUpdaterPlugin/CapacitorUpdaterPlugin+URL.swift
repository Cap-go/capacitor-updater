/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

// MARK: - URL Configuration Methods
extension CapacitorUpdaterPlugin {
    @objc func setUpdateUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setUpdateUrl called without allowModifyUrl")
            call.reject("setUpdateUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setUpdateUrl called without url")
            call.reject("setUpdateUrl called without url")
            return
        }
        self.updateUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: updateUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    // Used internally (e.g. ShakeMenu) to access the effective update URL.
    func getUpdateUrl() -> String {
        return updateUrl
    }

    @objc func setStatsUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setStatsUrl called without allowModifyUrl")
            call.reject("setStatsUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setStatsUrl called without url")
            call.reject("setStatsUrl called without url")
            return
        }
        self.implementation.statsUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: statsUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    @objc func setChannelUrl(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyUrl", false) {
            logger.error("setChannelUrl called without allowModifyUrl")
            call.reject("setChannelUrl called without allowModifyUrl set allowModifyUrl in your config to true to allow it")
            return
        }
        guard let url = call.getString("url") else {
            logger.error("setChannelUrl called without url")
            call.reject("setChannelUrl called without url")
            return
        }
        self.implementation.channelUrl = url
        if persistModifyUrl {
            UserDefaults.standard.set(url, forKey: channelUrlDefaultsKey)
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }

    @objc func getBuiltinVersion(_ call: CAPPluginCall) {
        call.resolve(["version": implementation.versionBuild])
    }

    @objc func getDeviceId(_ call: CAPPluginCall) {
        call.resolve(["deviceId": implementation.deviceID])
    }

    @objc func getPluginVersion(_ call: CAPPluginCall) {
        call.resolve(["version": self.pluginVersion])
    }

    @objc func getAppId(_ call: CAPPluginCall) {
        call.resolve([
            "appId": implementation.appId
        ])
    }

    @objc func setAppId(_ call: CAPPluginCall) {
        if !getConfig().getBoolean("allowModifyAppId", false) {
            logger.error("setAppId called without allowModifyAppId")
            call.reject("setAppId called without allowModifyAppId set allowModifyAppId in your config to true to allow it")
            return
        }
        guard let appId = call.getString("appId") else {
            logger.error("setAppId called without appId")
            call.reject("setAppId called without appId")
            return
        }
        implementation.appId = appId
        call.resolve()
    }

    @objc func setCustomId(_ call: CAPPluginCall) {
        guard let customId = call.getString("customId") else {
            logger.error("setCustomId called without customId")
            call.reject("setCustomId called without customId")
            return
        }
        self.implementation.customId = customId
        if persistCustomId {
            if customId.isEmpty {
                UserDefaults.standard.removeObject(forKey: customIdDefaultsKey)
            } else {
                UserDefaults.standard.set(customId, forKey: customIdDefaultsKey)
            }
            UserDefaults.standard.synchronize()
        }
        call.resolve()
    }
}
