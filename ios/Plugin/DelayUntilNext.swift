/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

//
//  DelayUntilNext.swift
//  Plugin
//
//  Created by Luca Peruzzo on 12/09/22.
//  Copyright © 2022 Capgo. All rights reserved.
//

import Foundation
enum DelayUntilNext: Decodable, Encodable, CustomStringConvertible {
    case background
    case kill
    case nativeVersion
    case date

    var description: String {
        switch self {
        case .background: return "background"
        case .kill: return "kill"
        case .nativeVersion: return "nativeVersion"
        case .date: return "date"
        }
    }
}
