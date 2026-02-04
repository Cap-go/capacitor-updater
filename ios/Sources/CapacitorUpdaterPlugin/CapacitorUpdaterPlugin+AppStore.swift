/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

// MARK: - App Store Update Methods
extension CapacitorUpdaterPlugin {
    @objc func getAppUpdateInfo(_ call: CAPPluginCall) {
        let country = call.getString("country", "US")

        appStoreUpdateManager.getAppUpdateInfo(country: country) { result in
            switch result {
            case .success(let info):
                call.resolve(info)
            case .failure(let error):
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func openAppStore(_ call: CAPPluginCall) {
        let appId = call.getString("appId")

        appStoreUpdateManager.openAppStore(appId: appId) { result in
            switch result {
            case .success:
                call.resolve()
            case .failure(let error):
                call.reject(error.localizedDescription)
            }
        }
    }

    @objc func performImmediateUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support in-app updates like Android's Play Store
        // Redirect users to the App Store instead
        logger.warn("performImmediateUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("In-app updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func startFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("startFlexibleUpdate is not supported on iOS. Use openAppStore() instead.")
        call.reject("Flexible updates are not supported on iOS. Use openAppStore() to direct users to the App Store.", "NOT_SUPPORTED")
    }

    @objc func completeFlexibleUpdate(_ call: CAPPluginCall) {
        // iOS doesn't support flexible in-app updates
        logger.warn("completeFlexibleUpdate is not supported on iOS.")
        call.reject("Flexible updates are not supported on iOS.", "NOT_SUPPORTED")
    }
}
