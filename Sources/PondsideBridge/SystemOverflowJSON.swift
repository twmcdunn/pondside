import Foundation
import PondsideCore
import PondsideEngrave

extension SystemOverflow {
    /// For `check` and the app's document state: where the system is and by
    /// how much it runs into the right margin.
    public var json: JSONValue {
        var out: [String: JSONValue] = ["page": .number(Double(page + 1)),
                                        "mm_past_margin": .number((amountMM * 10).rounded() / 10),
                                        "message": "system runs into the right margin: automatic line breaks are off, so move a bar to another system (a \\break) or narrow its content; spacing settings can't shrink it"]
        if let first {
            out["first"] = ["file": .string(first.path), "line": .number(Double(first.line)),
                            "column": .number(Double(first.column))]
        }
        return .object(out)
    }

    /// Overflows in a compile's SVG pages, when `sources` turn automatic
    /// line breaks off.
    public static func json(svgs: [URL], sources: [String]) -> [JSONValue] {
        guard applies(toSources: sources) else { return [] }
        let pages = svgs.compactMap { try? Data(contentsOf: $0) }.map(EngravedPage.init(svg:))
        return detect(in: pages).map(\.json)
    }
}
