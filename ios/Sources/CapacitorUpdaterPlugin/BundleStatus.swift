/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

struct LocalizedString: ExpressibleByStringLiteral, Equatable {

    let value: String

    init(key: String) {
        self.value = NSLocalizedString(key, comment: "")
    }
    init(localized: String) {
        self.value = localized
    }
    init(stringLiteral val: String) {
        self.init(key: val)
    }
    init(extendedGraphemeClusterLiteral val: String) {
        self.init(key: val)
    }
    init(unicodeScalarLiteral val: String) {
        self.init(key: val)
    }
}

func == (lhs: LocalizedString, rhs: LocalizedString) -> Bool {
    return lhs.value == rhs.value
}

enum BundleStatus: LocalizedString, CaseIterable, Decodable, Encodable {
    case SUCCESS = "success"
    case ERROR = "error"
    case PENDING  = "pending"
    case DELETED  = "deleted"
    case DOWNLOADING  = "downloading"

    var storedValue: String {
        switch self {
        case .SUCCESS:
            return "success"
        case .ERROR:
            return "error"
        case .PENDING:
            return "pending"
        case .DELETED:
            return "deleted"
        case .DOWNLOADING:
            return "downloading"
        }
    }

    var localizedString: String {
        return self.rawValue.value
    }

    init?(localizedString: String) {
        let normalized = localizedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = BundleStatus.allCases.first(where: { $0.localizedString == normalized }) else {
            return nil
        }
        self = status
    }

    init?(storedValue: String) {
        guard let status = BundleStatus.fromStoredValue(storedValue) else {
            return nil
        }
        self = status
    }

    private static func fromStoredValue(_ value: String) -> BundleStatus? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let status = BundleStatus(localizedString: normalized) {
            return status
        }

        let storedValue = normalized.lowercased()
        return BundleStatus.allCases.first(where: { $0.storedValue == storedValue })
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self),
           let status = BundleStatus.fromStoredValue(value) {
            self = status
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self),
           let key = container.allKeys.first,
           let status = BundleStatus.fromStoredValue(key.stringValue) {
            self = status
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid bundle status")
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.storedValue)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
