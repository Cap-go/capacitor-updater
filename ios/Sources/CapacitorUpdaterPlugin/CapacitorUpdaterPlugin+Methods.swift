/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Capacitor

/// Runs JavaScript engine methods in call order, like the bridge queue ran every previous version.
///
/// Every method runs on one serial lane. Detached methods (`detachedPluginMethods`: network calls and
/// `set` / `reload` / `reset`, which can wait for `notifyAppReady` from the new page) run on a worker
/// while the lane waits until the engine reports that the method waits (`releaseMethodLane` hook) or
/// the method returns. What a detached method changes before waiting is in call order (set then reset);
/// its wait never blocks the calls that follow.
final class EngineMethodLanes {
    /// Detached methods running at once; more wait for a free slot (bursts of waiting calls).
    static let maxDetached = 32
    /// Longest the lane waits for a detached method to start waiting (a full queue, a slow step).
    static let defaultLaneHoldLimit: TimeInterval = 5
    private static let laneHoldKey = "app.capgo.updater.methodLaneHold"

    private let lane = DispatchQueue(label: "app.capgo.updater.methods", qos: .userInitiated)
    private let detached: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.capgo.updater.detached"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = EngineMethodLanes.maxDetached
        return queue
    }()
    private let laneHoldLimit: TimeInterval
    private let lock = NSLock()
    private var detachedMethods: Set<String> = []
    /// Detached methods submitted and not finished: below the cap, a submitted one starts at once.
    private var outstanding = 0

    init(laneHoldLimit: TimeInterval = EngineMethodLanes.defaultLaneHoldLimit) {
        self.laneHoldLimit = laneHoldLimit
    }

    func setDetachedMethods(_ names: [String]) {
        lock.lock()
        detachedMethods = Set(names)
        lock.unlock()
    }

    func isDetached(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detachedMethods.contains(name)
    }

    /// `releaseMethodLane` hook: the detached method running on this thread waits; the lane goes on.
    static func releaseCurrentThread() {
        let dictionary = Thread.current.threadDictionary
        guard let hold = dictionary[laneHoldKey] as? DispatchSemaphore else {
            return
        }
        dictionary.removeObject(forKey: laneHoldKey)
        hold.signal()
    }

    func submit(_ name: String, _ task: @escaping () -> Void) {
        let detached = isDetached(name)
        lane.async {
            guard detached else {
                task()
                return
            }
            let hold = DispatchSemaphore(value: 0)
            // Every slot busy: the method queues for one and the lane does not wait for it.
            self.lock.lock()
            let startsNow = self.outstanding < Self.maxDetached
            self.outstanding += 1
            self.lock.unlock()
            self.detached.addOperation {
                Thread.current.threadDictionary[Self.laneHoldKey] = hold
                task()
                self.lock.lock()
                self.outstanding -= 1
                self.lock.unlock()
                Self.releaseCurrentThread()
            }
            if startsNow {
                _ = hold.wait(timeout: .now() + self.laneHoldLimit)
            }
        }
    }
}

/// JavaScript methods implemented by the engine (`pluginMethod`).
extension CapacitorUpdaterPlugin {
    /// Runs an engine method through the method lanes, then reports its outcome.
    func dispatchEngineMethod(_ name: String, _ args: [String: Any], completion: @escaping (MethodOutcome) -> Void) {
        methodLanes.submit(name) { [weak self] in
            guard let self else {
                completion(.rejected(message: "Plugin unavailable", code: nil, data: nil))
                return
            }
            completion(self.runEngineMethod(name, args))
        }
    }

    /// Forwards a plugin call to the engine off the main thread, in call order, and settles it.
    func forward(_ call: CAPPluginCall) {
        let name = call.methodName ?? ""
        let args = (call.options as? [String: Any]) ?? [:]
        dispatchEngineMethod(name, args) { outcome in
            switch outcome {
            case .resolved(let value):
                if let value = value as? [String: Any] {
                    call.resolve(value)
                } else {
                    call.resolve()
                }
            case .rejected(let message, let code, let data):
                call.reject(message, code, nil, data)
            }
        }
    }

    @objc func notifyAppReady(_ call: CAPPluginCall) { forward(call) }
    @objc func setUpdateUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func setStatsUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func setChannelUrl(_ call: CAPPluginCall) { forward(call) }
    @objc func download(_ call: CAPPluginCall) { forward(call) }
    @objc func next(_ call: CAPPluginCall) { forward(call) }
    @objc func set(_ call: CAPPluginCall) { forward(call) }
    @objc func startPreviewSession(_ call: CAPPluginCall) { forward(call) }
    @objc func listPreviews(_ call: CAPPluginCall) { forward(call) }
    @objc func setPreview(_ call: CAPPluginCall) { forward(call) }
    @objc func resetPreview(_ call: CAPPluginCall) { forward(call) }
    @objc func deletePreview(_ call: CAPPluginCall) { forward(call) }
    @objc func checkPreviewUpdate(_ call: CAPPluginCall) { forward(call) }
    @objc func updatePreview(_ call: CAPPluginCall) { forward(call) }
    @objc func delete(_ call: CAPPluginCall) { forward(call) }
    @objc func setBundleError(_ call: CAPPluginCall) { forward(call) }
    @objc func list(_ call: CAPPluginCall) { forward(call) }
    @objc func reset(_ call: CAPPluginCall) { forward(call) }
    @objc func current(_ call: CAPPluginCall) { forward(call) }
    @objc func reload(_ call: CAPPluginCall) { forward(call) }
    @objc func setMultiDelay(_ call: CAPPluginCall) { forward(call) }
    @objc func cancelDelay(_ call: CAPPluginCall) { forward(call) }
    @objc func triggerUpdateCheck(_ call: CAPPluginCall) { forward(call) }
    @objc func getLatest(_ call: CAPPluginCall) { forward(call) }
    @objc func getMissingBundleFiles(_ call: CAPPluginCall) { forward(call) }
    @objc func getBundleDownloadSize(_ call: CAPPluginCall) { forward(call) }
    @objc func setChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func unsetChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func getChannel(_ call: CAPPluginCall) { forward(call) }
    @objc func listChannels(_ call: CAPPluginCall) { forward(call) }
    @objc func setCustomId(_ call: CAPPluginCall) { forward(call) }
    @objc func getBuiltinVersion(_ call: CAPPluginCall) { forward(call) }
    @objc func getDeviceId(_ call: CAPPluginCall) { forward(call) }
    @objc func getPluginVersion(_ call: CAPPluginCall) { forward(call) }
    @objc func isAutoUpdateEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func isAutoUpdateAvailable(_ call: CAPPluginCall) { forward(call) }
    @objc func getNextBundle(_ call: CAPPluginCall) { forward(call) }
    @objc func getFailedUpdate(_ call: CAPPluginCall) { forward(call) }
    @objc func setShakeMenu(_ call: CAPPluginCall) { forward(call) }
    @objc func isShakeMenuEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func setShakeChannelSelector(_ call: CAPPluginCall) { forward(call) }
    @objc func isShakeChannelSelectorEnabled(_ call: CAPPluginCall) { forward(call) }
    @objc func getAppId(_ call: CAPPluginCall) { forward(call) }
    @objc func setAppId(_ call: CAPPluginCall) { forward(call) }
    @objc func reportWebViewError(_ call: CAPPluginCall) { forward(call) }
}
