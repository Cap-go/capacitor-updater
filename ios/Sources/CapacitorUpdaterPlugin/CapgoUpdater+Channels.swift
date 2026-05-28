/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import ZIPFoundation
import Alamofire
import Compression
import UIKit

extension CapgoUpdater {
    func unsetChannel(defaultChannelKey: String, configDefaultChannel: String) -> SetChannel {
        let setChannel: SetChannel = SetChannel()

        // Clear persisted defaultChannel and revert to config value
        UserDefaults.standard.removeObject(forKey: defaultChannelKey)
        UserDefaults.standard.synchronize()
        self.defaultChannel = configDefaultChannel
        self.logger.info("Persisted defaultChannel cleared, reverted to config value: \(configDefaultChannel)")

        setChannel.status = "ok"
        setChannel.message = "Channel override removed"
        return setChannel
    }

    func setChannel(channel: String, defaultChannelKey: String, allowSetDefaultChannel: Bool) -> SetChannel {
        let setChannel: SetChannel = SetChannel()

        // Check if setting defaultChannel is allowed
        if !allowSetDefaultChannel {
            logger.error("setChannel is disabled by allowSetDefaultChannel config")
            setChannel.message = "setChannel is disabled by configuration"
            setChannel.error = "disabled_by_config"
            return setChannel
        }

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping setChannel due to rate limit (429). Requests will resume after app restart.")
            setChannel.message = "Rate limit exceeded"
            setChannel.error = "rate_limit_exceeded"
            return setChannel
        }

        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }
        guard let channelURL = URL(string: self.channelUrl) else {
            logger.error("Invalid channel URL")
            setChannel.message = "Channel URL is invalid"
            setChannel.error = "invalid_config"
            return setChannel
        }
        var parameters: InfoObject = self.createInfoObject()
        parameters.channel = channel
        guard let request = createRequest(url: channelURL, method: "POST", parameters: parameters.toParameters()) else {
            setChannel.error = "Request failed: invalid request"
            return setChannel
        }

        let result = performRequest(request, label: "setChannel")

        if self.checkAndHandleRateLimitResponse(statusCode: result.response?.statusCode) {
            setChannel.message = "Rate limit exceeded"
            setChannel.error = "rate_limit_exceeded"
            return setChannel
        }

        if result.timedOut {
            setChannel.error = "Request timed out"
            return setChannel
        }

        if let error = result.error {
            self.logger.error("Error setting channel")
            self.logger.debug("Error: \(error.localizedDescription)")
            setChannel.error = "Request failed: \(error.localizedDescription)"
            return setChannel
        }

        guard let data = result.data else {
            setChannel.error = "Request failed: empty response"
            return setChannel
        }

        guard let responseValue = try? JSONDecoder().decode(SetChannelDec.self, from: data) else {
            setChannel.error = "decode_error"
            return setChannel
        }

        let statusCode = result.response?.statusCode ?? 0
        if statusCode < 200 || statusCode >= 300 {
            setChannel.message = responseValue.message ?? "Server error: \(statusCode)"
            setChannel.error = responseValue.error ?? "response_error"
            return setChannel
        }

        if let error = responseValue.error {
            setChannel.error = error
        } else if responseValue.unset == true {
            UserDefaults.standard.removeObject(forKey: defaultChannelKey)
            UserDefaults.standard.synchronize()
            self.logger.info("Public channel requested, channel override removed")

            setChannel.status = responseValue.status ?? "ok"
            setChannel.message = responseValue.message ?? "Public channel requested, channel override removed. Device will use public channel automatically."
        } else {
            self.defaultChannel = channel
            UserDefaults.standard.set(channel, forKey: defaultChannelKey)
            UserDefaults.standard.synchronize()
            self.logger.info("defaultChannel persisted locally: \(channel)")

            setChannel.status = responseValue.status ?? ""
            setChannel.message = responseValue.message ?? ""
        }
        return setChannel
    }

    func getChannel() -> GetChannel {
        let getChannel: GetChannel = GetChannel()

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping getChannel due to rate limit (429). Requests will resume after app restart.")
            getChannel.message = "Rate limit exceeded"
            getChannel.error = "rate_limit_exceeded"
            return getChannel
        }

        if (self.channelUrl ).isEmpty {
            logger.error("Channel URL is not set")
            getChannel.message = "Channel URL is not set"
            getChannel.error = "missing_config"
            return getChannel
        }
        guard let channelURL = URL(string: self.channelUrl) else {
            logger.error("Invalid channel URL")
            getChannel.message = "Channel URL is invalid"
            getChannel.error = "invalid_config"
            return getChannel
        }
        let parameters: InfoObject = self.createInfoObject()
        guard let request = createRequest(url: channelURL, method: "PUT", parameters: parameters.toParameters()) else {
            getChannel.error = "Request failed: invalid request"
            return getChannel
        }

        let result = performRequest(request, label: "getChannel")

        if self.checkAndHandleRateLimitResponse(statusCode: result.response?.statusCode) {
            getChannel.message = "Rate limit exceeded"
            getChannel.error = "rate_limit_exceeded"
            return getChannel
        }

        if result.timedOut {
            getChannel.error = "Request timed out"
            return getChannel
        }

        if let error = result.error {
            if let data = result.data, let bodyString = String(data: data, encoding: .utf8) {
                if bodyString.contains("channel_not_found") && result.response?.statusCode == 400 && !self.defaultChannel.isEmpty {
                    getChannel.channel = self.defaultChannel
                    getChannel.status = "default"
                    return getChannel
                }
            }

            self.logger.error("Error getting channel")
            self.logger.debug("Error: \(error.localizedDescription)")
            getChannel.error = "Request failed: \(error.localizedDescription)"
            return getChannel
        }

        guard let data = result.data else {
            getChannel.error = "Request failed: empty response"
            return getChannel
        }

        guard let responseValue = try? JSONDecoder().decode(GetChannelDec.self, from: data) else {
            getChannel.error = "decode_error"
            return getChannel
        }

        let statusCode = result.response?.statusCode ?? 0
        if let error = responseValue.error {
            if error == "channel_not_found", statusCode == 400, !self.defaultChannel.isEmpty {
                getChannel.channel = self.defaultChannel
                getChannel.status = "default"
                return getChannel
            }
            getChannel.error = error
            getChannel.message = responseValue.message ?? ""
            return getChannel
        }

        if statusCode < 200 || statusCode >= 300 {
            getChannel.message = responseValue.message ?? "Server error: \(statusCode)"
            getChannel.error = "response_error"
        } else {
            getChannel.status = responseValue.status ?? ""
            getChannel.message = responseValue.message ?? ""
            getChannel.channel = responseValue.channel ?? ""
            getChannel.allowSet = responseValue.allowSet ?? true
        }
        return getChannel
    }

    func listChannels() -> ListChannels {
        let listChannels: ListChannels = ListChannels()

        // Check if rate limit was exceeded
        if CapgoUpdater.rateLimitExceeded {
            logger.debug("Skipping listChannels due to rate limit (429). Requests will resume after app restart.")
            listChannels.error = "rate_limit_exceeded"
            return listChannels
        }

        if (self.channelUrl).isEmpty {
            logger.error("Channel URL is not set")
            listChannels.error = "Channel URL is not set"
            return listChannels
        }

        // Create info object and convert to query parameters
        let infoObject = self.createInfoObject()

        // Create query parameters from InfoObject
        var urlComponents = URLComponents(string: self.channelUrl)
        var queryItems: [URLQueryItem] = urlComponents?.queryItems ?? []

        for (key, value) in infoObject.toParameters() {
            queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
        }

        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            logger.error("Invalid channel URL")
            listChannels.error = "Invalid channel URL"
            return listChannels
        }

        guard let request = createRequest(url: url, method: "GET", expectsJSONResponse: true) else {
            listChannels.error = "Invalid channel URL"
            return listChannels
        }

        let result = performRequest(request, label: "listChannels")

        if self.checkAndHandleRateLimitResponse(statusCode: result.response?.statusCode) {
            listChannels.error = "rate_limit_exceeded"
            return listChannels
        }

        if result.timedOut {
            listChannels.error = "Request timed out"
            return listChannels
        }

        if let error = result.error {
            self.logger.error("Error listing channels")
            self.logger.debug("Error: \(error.localizedDescription)")
            listChannels.error = "Request failed: \(error.localizedDescription)"
            return listChannels
        }

        guard let data = result.data else {
            listChannels.error = "Request failed: empty response"
            return listChannels
        }

        guard let responseValue = try? JSONDecoder().decode(ListChannelsDec.self, from: data) else {
            listChannels.error = "decode_error"
            return listChannels
        }

        let statusCode = result.response?.statusCode ?? 0
        if let error = responseValue.error {
            listChannels.error = error
            return listChannels
        }

        if statusCode < 200 || statusCode >= 300 {
            listChannels.error = "response_error"
            return listChannels
        }

        if let channels = responseValue.channels {
            listChannels.channels = channels.map { channel in
                var channelDict: [String: Any] = [:]
                channelDict["id"] = channel.id ?? ""
                channelDict["name"] = channel.name ?? ""
                channelDict["public"] = channel.public ?? false
                channelDict["allow_self_set"] = channel.allowSelfSet ?? false
                return channelDict
            }
        }

        return listChannels
    }
}
