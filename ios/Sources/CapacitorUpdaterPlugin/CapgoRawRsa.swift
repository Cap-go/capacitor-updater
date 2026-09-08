/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import Foundation
import Security
import os.log

/// Isolated raw RSA primitives for Capgo v2 checksum/session-key recovery.
/// SonarCloud automatic analysis has no Swift // NOSONAR; this file is excluded
/// in `.sonarcloud.properties` because `.rsaEncryptionRaw` is intentional wire
/// compatibility with Node `privateEncrypt` / `publicDecrypt`.
enum CapgoRawRsa {
    private static let log = OSLog(subsystem: "ee.forgr.capacitor_updater", category: "RSA")

    static func supportsCapgoRecovery(key: SecKey) -> Bool {
        SecKeyGetBlockSize(key) == 256
            && SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) // NOSONAR intentional raw RSA for Node privateEncrypt / Capgo checksum recovery
    }

    static func recoverSignatureBlock(key: SecKey, data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        guard let recovered = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, data as CFData, &error) as Data? else { // NOSONAR intentional raw RSA for Node privateEncrypt / Capgo checksum recovery
            os_log(
                "RSA raw recovery failed: %{public}@",
                log: log,
                type: .error,
                String(describing: error?.takeRetainedValue())
            )
            return nil
        }
        return recovered
    }
}
