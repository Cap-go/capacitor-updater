/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

// MARK: - Channel Management Methods
extension CapacitorUpdaterPlugin {
    @objc func getLatest(_ call: CAPPluginCall) {
        let channel = call.getString("channel")
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.getLatest(url: URL(string: self.updateUrl)!, channel: channel)
            if res.error != nil {
                call.reject( res.error!)
            } else if res.message != nil {
                call.reject( res.message!)
            } else {
                call.resolve(res.toDict())
            }
        }
    }

    @objc func unsetChannel(_ call: CAPPluginCall) {
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate", false)
        DispatchQueue.global(qos: .background).async {
            let configDefaultChannel = self.getConfig().getString("defaultChannel", "")!
            let res = self.implementation.unsetChannel(defaultChannelKey: self.defaultChannelDefaultsKey, configDefaultChannel: configDefaultChannel)
            if res.error != "" {
                call.reject(res.error, "UNSETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                if self.checkAutoUpdateEnabled() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    self.backgroundDownload()
                }
                call.resolve(res.toDict())
            }
        }
    }

    @objc func setChannel(_ call: CAPPluginCall) {
        guard let channel = call.getString("channel") else {
            logger.error("setChannel called without channel")
            call.reject("setChannel called without channel", "SETCHANNEL_INVALID_PARAMS", nil, [
                "message": "setChannel called without channel",
                "error": "missing_parameter"
            ])
            return
        }
        let triggerAutoUpdate = call.getBool("triggerAutoUpdate") ?? false
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.setChannel(channel: channel, defaultChannelKey: self.defaultChannelDefaultsKey, allowSetDefaultChannel: self.allowSetDefaultChannel)
            if res.error != "" {
                // Fire channelPrivate event if channel doesn't allow self-assignment
                if res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed") {
                    self.notifyListeners("channelPrivate", data: [
                        "channel": channel,
                        "message": res.error
                    ])
                }
                call.reject(res.error, "SETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : (res.error.contains("cannot_update_via_private_channel") || res.error.contains("channel_self_set_not_allowed")) ? "channel_private" : "request_failed"
                ])
            } else {
                if self.checkAutoUpdateEnabled() && triggerAutoUpdate {
                    self.logger.info("Calling autoupdater after channel change!")
                    self.backgroundDownload()
                }
                call.resolve(res.toDict())
            }
        }
    }

    @objc func getChannel(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.getChannel()
            if res.error != "" {
                call.reject(res.error, "GETCHANNEL_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                call.resolve(res.toDict())
            }
        }
    }

    @objc func listChannels(_ call: CAPPluginCall) {
        DispatchQueue.global(qos: .background).async {
            let res = self.implementation.listChannels()
            if res.error != "" {
                call.reject(res.error, "LISTCHANNELS_FAILED", nil, [
                    "message": res.error,
                    "error": res.error.contains("Channel URL") ? "missing_config" : "request_failed"
                ])
            } else {
                call.resolve(res.toDict())
            }
        }
    }
}
