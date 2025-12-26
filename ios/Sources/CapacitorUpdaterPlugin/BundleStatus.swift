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

enum BundleStatus: LocalizedString, Decodable, Encodable {
    case SUCCESS = "success"
    case ERROR = "error"
    case PENDING  = "pending"
    case DELETED  = "deleted"
    case DOWNLOADING  = "downloading"

    var localizedString: String {
        return self.rawValue.value
    }

    init?(localizedString: String) {
        self.init(rawValue: LocalizedString(localized: localizedString))
    }
}
