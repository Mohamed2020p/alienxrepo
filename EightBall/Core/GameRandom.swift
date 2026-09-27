import Foundation

/// A small seedable random generator (SplitMix64). Used for the rack shuffle, the AI's noise and everything the Python game did
/// with `random`. The same seed always gives the same sequence on every device.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    /// A generator seeded from the system's random source.
    init() {
        self.state = UInt64.random(in: 0...UInt64.max)
    }

    static func randomSeed() -> UInt64 {
        return UInt64.random(in: 0...UInt64.max)
    }

    mutating func next() -> UInt64 {
        let gamma: UInt64 = 0x9E3779B97F4A7C15
        let m1: UInt64 = 0xBF58476D1CE4E5B9
        let m2: UInt64 = 0x94D049BB133111EB
        state = state &+ gamma
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* m1
        z = (z ^ (z >> 27)) &* m2
        return z ^ (z >> 31)
    }
}

/// Helpers that mirror the parts of Python's `random` the game used.
extension SplitMix64 {
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        let raw: UInt64 = self.next()
        let bits: UInt64 = raw >> 11
        return Double(bits) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in [a, b).
    mutating func uniform(_ a: Double, _ b: Double) -> Double {
        let u: Double = nextUnit()
        return a + (b - a) * u
    }

    /// Normally distributed (Box-Muller).
    mutating func gauss(_ mu: Double, _ sigma: Double) -> Double {
        let u1: Double = 1.0 - nextUnit()          // (0, 1]
        let u2: Double = nextUnit()
        let mag: Double = sqrt(-2.0 * log(u1))
        let z: Double = mag * cos(2.0 * Double.pi * u2)
        return mu + sigma * z
    }

    /// A random index 0 ..< count (0 when count <= 1).
    mutating func index(_ count: Int) -> Int {
        if count <= 1 {
            return 0
        }
        let v: Int = Int(nextUnit() * Double(count))
        if v >= count {
            return count - 1
        }
        return v
    }
}
