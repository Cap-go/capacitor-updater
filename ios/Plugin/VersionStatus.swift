//
//  VersionStatus.swift
//  Plugin
//
//  Created by Martin DONADIEU on 05/05/2022.
//  Copyright © 2022 Capgo. All rights reserved.
//

import Foundation

public enum VersionStatus: LocalizedString {
    case SUCCESS = "success"
    case ERROR = error
    case PENDING  = "pending"

    var localizedString: String {
        return self.rawValue.v
    }

    init?(localizedString: String) {
        self.init(rawValue: LocalizedString(localized: localizedString))
    }
}
