/// A rational number of whole notes.
public struct LensFraction: Sendable, Hashable, Comparable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int = 1) {
        let sign = denominator < 0 ? -1 : 1
        let n = numerator * sign
        let d = denominator * sign
        let g = Self.gcd(abs(n), abs(d))
        self.numerator = n / g
        self.denominator = d / g
    }

    public static let zero = LensFraction(0)
    public static let one = LensFraction(1)

    public var isZero: Bool { numerator == 0 }
    public var double: Double { Double(numerator) / Double(denominator) }

    public static func * (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        LensFraction(lhs.numerator * rhs.numerator, lhs.denominator * rhs.denominator)
    }

    public static func + (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        LensFraction(
            lhs.numerator * rhs.denominator + rhs.numerator * lhs.denominator,
            lhs.denominator * rhs.denominator
        )
    }

    public static func - (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        lhs + LensFraction(-rhs.numerator, rhs.denominator)
    }

    public static func < (lhs: LensFraction, rhs: LensFraction) -> Bool {
        lhs.numerator * rhs.denominator < rhs.numerator * lhs.denominator
    }

    func wholeNoteUnits(divisions: Int) -> Int {
        let units = numerator * divisions * 4
        return max(0, Int((Double(units) / Double(denominator)).rounded()))
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return max(1, a)
    }
}
