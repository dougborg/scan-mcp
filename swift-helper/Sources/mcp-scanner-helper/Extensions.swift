// Adapted from scanline (https://github.com/klep/scanline), MIT licensed.

import Foundation

extension IndexSet {
    /// Returns the smallest member >= `value`, or nil if none.
    func integerGreaterThanOrEqualTo(_ value: Int) -> Int? {
        if contains(value) { return value }
        let idx = integerGreaterThan(value)
        return idx == NSNotFound ? nil : idx
    }
}
