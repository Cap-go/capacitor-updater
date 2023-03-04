/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation

struct LocalizedString: ExpressibleByStringLiteral, Equatable {

    let v: String

    init(key: String) {
        self.v = NSLocalizedString(key, comment: "")
    }
    init(localized: String) {
        self.v = localized
    }
    init(stringLiteral value: String) {
        self.init(key: value)
    }
    init(extendedGraphemeClusterLiteral value: String) {
        self.init(key: value)
    }
    init(unicodeScalarLiteral value: String) {
        self.init(key: value)
    }
}

func ==(lhs: LocalizedString, rhs: LocalizedString) -> Bool {
    return lhs.v == rhs.v
}

enum BundleStatus: LocalizedString, Decodable, Encodable {
    case SUCCESS = "success"
    case ERROR = "error"
    case PENDING  = "pending"
    case DELETED  = "deleted"
    case DOWNLOADING  = "downloading"

    var localizedString: String {
        return self.rawValue.v
    }

    init?(localizedString: String) {
        self.init(rawValue: LocalizedString(localized: localizedString))
    }
}
