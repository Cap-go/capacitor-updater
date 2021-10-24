import Foundation

@objc public class CapacitorUpdater: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
