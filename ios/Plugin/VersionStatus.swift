//
//  VersionStatus.swift
//  Plugin
//
//  Created by Martin DONADIEU on 05/05/2022.
//  Copyright © 2022 Capgo. All rights reserved.
//

import Foundation

struct LocalizedString: ExpressibleByStringLiteral, Equatable {

    let v: String

    init(key: String) {
        self.v = NSLocalizedString(key, comment: "")
    }
    init(localized: String) {
        self.v = localized
    }
    init(stringLiteral value:String) {
        self.init(key: value)
    }
    init(extendedGraphemeClusterLiteral value: String) {
        self.init(key: value)
    }
    init(unicodeScalarLiteral value: String) {
        self.init(key: value)
    }
}

func ==(lhs:LocalizedString, rhs:LocalizedString) -> Bool {
    return lhs.v == rhs.v
}

enum VersionStatus: LocalizedString {
    case SUCCESS = "success"
    case ERROR = "error"
    case PENDING  = "pending"


    var localizedString: String {
        return self.rawValue.v
    }

}
