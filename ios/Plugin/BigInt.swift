import BigInt

// Extension to serialize BigInt to bytes array
extension BigInt {
    func serializeToBytes() -> [UInt8] {
        let byteCount = (self.bitWidth + 7) / 8
        var bytes = [UInt8](repeating: 0, count: byteCount)

        var value = self
        for i in 0..<byteCount {
            bytes[byteCount - i - 1] = UInt8(truncatingIfNeeded: value & 0xFF)
            value >>= 8
        }

        return bytes
    }
}

// Add this custom power function to ensure safer handling of power operations

// Manual exponentiation using the square-and-multiply algorithm
// which is more efficient and avoids using the built-in functions that might handle BigInt differently
extension BigInt {
    func manualPower(_ exponent: BigInt, modulus: BigInt) -> BigInt {
        // Quick checks
        if modulus == 0 {
            return 0
        }

        if exponent == 0 {
            return 1
        }

        guard let base = self.magnitude as? BigUInt,
              let exp = exponent.magnitude as? BigUInt,
              let mod = modulus.magnitude as? BigUInt else {
            return 0
        }

        // Square and multiply algorithm for modular exponentiation
        var result = BigUInt(1)
        var x = base % mod
        var e = exp

        while e > 0 {
            if e & 1 == 1 {
                result = (result * x) % mod
            }
            x = (x * x) % mod
            e >>= 1
        }

        return BigInt(result)
    }
}
