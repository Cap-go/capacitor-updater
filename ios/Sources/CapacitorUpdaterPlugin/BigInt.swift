import BigInt

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
        var currentBase = base % mod
        var currentExp = exp

        while currentExp > 0 {
            if currentExp & 1 == 1 {
                result = (result * currentBase) % mod
            }
            currentBase = (currentBase * currentBase) % mod
            currentExp >>= 1
        }

        return BigInt(result)
    }
}
