import Foundation

public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)
}

public struct Rect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The smallest rect containing all points; nil for an empty sequence.
    public init?(enclosing points: some Sequence<Point>) {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for p in points {
            any = true
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        guard any else { return nil }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var area: Double { width * height }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func intersects(_ r: Rect) -> Bool {
        minX <= r.maxX && r.minX <= maxX && minY <= r.maxY && r.minY <= maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }

    /// 0 inside, else the distance to the nearest edge.
    public func distance(to p: Point) -> Double {
        let dx = max(minX - p.x, 0, p.x - maxX), dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The overlap of two rectangles, or nil when they don't meet.
    public func intersection(_ r: Rect) -> Rect? {
        let nx = max(minX, r.minX), ny = max(minY, r.minY)
        let mx = min(maxX, r.maxX), my = min(maxY, r.maxY)
        guard mx >= nx, my >= ny else { return nil }
        return Rect(x: nx, y: ny, width: mx - nx, height: my - ny)
    }

    public func union(_ r: Rect) -> Rect {
        let nx = min(minX, r.minX), ny = min(minY, r.minY)
        return Rect(x: nx, y: ny, width: max(maxX, r.maxX) - nx, height: max(maxY, r.maxY) - ny)
    }

    /// The smallest rectangle containing the transformed corners.
    public func transformed(by t: AffineTransform) -> Rect {
        let pts = [Point(minX, minY), Point(maxX, minY), Point(minX, maxY), Point(maxX, maxY)].map(t.apply)
        return Rect(enclosing: pts) ?? self
    }
}

/// An affine transform with SVG matrix semantics:
/// x' = a·x + c·y + e,  y' = b·x + d·y + f.
public struct AffineTransform: Hashable, Sendable, Codable {
    public var a, b, c, d, e, f: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }

    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public static func translation(_ tx: Double, _ ty: Double) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, e: tx, f: ty)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> AffineTransform {
        AffineTransform(a: sx, b: 0, c: 0, d: sy, e: 0, f: 0)
    }

    public static func rotation(degrees: Double) -> AffineTransform {
        let r = degrees * .pi / 180
        return AffineTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), e: 0, f: 0)
    }

    /// The transform that applies `self` first, then `next`.
    public func then(_ next: AffineTransform) -> AffineTransform {
        AffineTransform(
            a: next.a * a + next.c * b,
            b: next.b * a + next.d * b,
            c: next.a * c + next.c * d,
            d: next.b * c + next.d * d,
            e: next.a * e + next.c * f + next.e,
            f: next.b * e + next.d * f + next.f)
    }

    public func apply(_ p: Point) -> Point {
        Point(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    /// Mean linear scale factor, used to scale stroke widths.
    public var scaleFactor: Double { abs(a * d - b * c).squareRoot() }

    public var isIdentity: Bool { self == .identity }
}
