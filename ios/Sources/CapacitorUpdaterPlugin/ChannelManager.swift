/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Alamofire

/// Manages channel operations (get, set, list, unset) for the CapacitorUpdater plugin.
class ChannelManager {
    private let logger: Logger
    private let alamofireSession: Session
    private let createInfoObject: () -> InfoObject
    private let isRateLimited: () -> Bool
    private let checkRateLimitResponse: (Int?) -> Bool

    // Configuration
    var channelUrl: String = ""
    var timeout: Double = 20
    var defaultChannel: String = ""

    init(logger: Logger,
         alamofireSession: Session,
         createInfoObject: @escaping () -> InfoObject,
         isRateLimited: @escaping () -> Bool,
         checkRateLimitResponse: @escaping (Int?) -> Bool) {
        self.logger = logger
        self.alamofireSession = alamofireSession
        self.createInfoObject = createInfoObject
        self.isRateLimited = isRateLimited
        self.checkRateLimitResponse = checkRateLimitResponse
    }

    /// Unset the channel override and revert to config default
    func unsetChannel(defaultChannelKey: String, configDefaultChannel: String) -> SetChannel {
        let setChannel = SetChannel()

        // Clear persisted defaultChannel and revert to config value
        UserDefaults.standard.removeObject(forKey: defaultChannelKey)
        UserDefaults.standard.synchronize()
        self.defaultChannel = configDefaultChannel
        logger.info("Persisted defaultChannel cleared, reverted to config value: \(configDefaultChannel)")

        setChannel.status = "ok"
        setChannel.message = "Channel override removed"
        return setChannel
    }

    /// Set the channel for updates
    func setChannel(channel: String, defaultChannelKey: String, allowSetDefaultChannel: Bool) -> SetChannel {
        let setChannel = SetChannel()

        // Check if setting defaultChannel is allowed
        if !allowSetDefaultChannel {
            logger.error("setChannel is disabled by allowSetDefaultChannel config")
            setChannel.message = "setChannel is disabled by configuration"
            setChannel.error = "disabled_by_config"
            return setChannel
        }

        // Check if rate limit was exceeded
        if isRateLimited() {
            logger.debug("Skipping setChannel due to rate limit (429). Requests will resume after app restart.")
            setChannel.message = "Rate limit exceeded"
            setChannel.error = "rate_limit_exceeded"
            return setChannel
        }

        if channelUrl.isEmpty {
            logger.error("Channel URL is not set")
            setChannel.message = "Channel URL is not set"
            setChannel.error = "missing_config"
            return setChannel
        }

        let semaphore = DispatchSemaphore(value: 0)
        var parameters = createInfoObject()
        parameters.channel = channel

        let request = alamofireSession.request(channelUrl, method: .post, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: SetChannelDec.self) { response in
            // Check for 429 rate limit
            if self.checkRateLimitResponse(response.response?.statusCode) {
                setChannel.message = "Rate limit exceeded"
                setChannel.error = "rate_limit_exceeded"
                semaphore.signal()
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        setChannel.error = error
                    } else {
                        // Success - persist defaultChannel
                        self.defaultChannel = channel
                        UserDefaults.standard.set(channel, forKey: defaultChannelKey)
                        UserDefaults.standard.synchronize()
                        self.logger.info("defaultChannel persisted locally: \(channel)")

                        setChannel.status = responseValue.status ?? ""
                        setChannel.message = responseValue.message ?? ""
                    }
                }
            case let .failure(error):
                self.logger.error("Error setting channel")
                self.logger.debug("Error: \(error)")
                setChannel.error = "Request failed: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        return setChannel
    }

    /// Get the current channel
    func getChannel() -> GetChannel {
        let getChannel = GetChannel()

        // Check if rate limit was exceeded
        if isRateLimited() {
            logger.debug("Skipping getChannel due to rate limit (429). Requests will resume after app restart.")
            getChannel.message = "Rate limit exceeded"
            getChannel.error = "rate_limit_exceeded"
            return getChannel
        }

        if channelUrl.isEmpty {
            logger.error("Channel URL is not set")
            getChannel.message = "Channel URL is not set"
            getChannel.error = "missing_config"
            return getChannel
        }

        let semaphore = DispatchSemaphore(value: 0)
        let parameters = createInfoObject()
        let request = alamofireSession.request(channelUrl, method: .put, parameters: parameters, encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: GetChannelDec.self) { response in
            defer {
                semaphore.signal()
            }

            // Check for 429 rate limit
            if self.checkRateLimitResponse(response.response?.statusCode) {
                getChannel.message = "Rate limit exceeded"
                getChannel.error = "rate_limit_exceeded"
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    if let error = responseValue.error {
                        getChannel.error = error
                    } else {
                        getChannel.status = responseValue.status ?? ""
                        getChannel.message = responseValue.message ?? ""
                        getChannel.channel = responseValue.channel ?? ""
                        getChannel.allowSet = responseValue.allowSet ?? true
                    }
                }
            case let .failure(error):
                if let data = response.data, let bodyString = String(data: data, encoding: .utf8) {
                    if bodyString.contains("channel_not_found") && response.response?.statusCode == 400 && !self.defaultChannel.isEmpty {
                        getChannel.channel = self.defaultChannel
                        getChannel.status = "default"
                        return
                    }
                }

                self.logger.error("Error getting channel")
                self.logger.debug("Error: \(error)")
                getChannel.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return getChannel
    }

    /// List all available channels
    func listChannels() -> ListChannels {
        let listChannels = ListChannels()

        // Check if rate limit was exceeded
        if isRateLimited() {
            logger.debug("Skipping listChannels due to rate limit (429). Requests will resume after app restart.")
            listChannels.error = "rate_limit_exceeded"
            return listChannels
        }

        if channelUrl.isEmpty {
            logger.error("Channel URL is not set")
            listChannels.error = "Channel URL is not set"
            return listChannels
        }

        let semaphore = DispatchSemaphore(value: 0)

        // Create info object and convert to query parameters
        let infoObject = createInfoObject()

        // Create query parameters from InfoObject
        var urlComponents = URLComponents(string: channelUrl)
        var queryItems: [URLQueryItem] = []

        // Convert InfoObject to dictionary using Mirror
        let mirror = Mirror(reflecting: infoObject)
        for child in mirror.children {
            if let key = child.label, let value = child.value as? CustomStringConvertible {
                queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
            } else if let key = child.label {
                // Handle optional values
                let mirror = Mirror(reflecting: child.value)
                if let value = mirror.children.first?.value {
                    queryItems.append(URLQueryItem(name: key, value: String(describing: value)))
                }
            }
        }

        urlComponents?.queryItems = queryItems

        guard let url = urlComponents?.url else {
            logger.error("Invalid channel URL")
            listChannels.error = "Invalid channel URL"
            return listChannels
        }

        let request = alamofireSession.request(url, method: .get, requestModifier: { $0.timeoutInterval = self.timeout })

        request.validate().responseDecodable(of: ListChannelsDec.self) { response in
            defer {
                semaphore.signal()
            }

            // Check for 429 rate limit
            if self.checkRateLimitResponse(response.response?.statusCode) {
                listChannels.error = "rate_limit_exceeded"
                return
            }

            switch response.result {
            case .success:
                if let responseValue = response.value {
                    // Check for server-side errors
                    if let error = responseValue.error {
                        listChannels.error = error
                        return
                    }

                    // Backend returns direct array, so channels should be populated by our custom decoder
                    if let channels = responseValue.channels {
                        listChannels.channels = channels.map { channel in
                            var channelDict: [String: Any] = [:]
                            channelDict["id"] = channel.id ?? ""
                            channelDict["name"] = channel.name ?? ""
                            channelDict["public"] = channel.public ?? false
                            channelDict["allow_self_set"] = channel.allow_self_set ?? false
                            return channelDict
                        }
                    }
                }
            case let .failure(error):
                self.logger.error("Error listing channels")
                self.logger.debug("Error: \(error)")
                listChannels.error = "Request failed: \(error.localizedDescription)"
            }
        }
        semaphore.wait()
        return listChannels
    }
}
