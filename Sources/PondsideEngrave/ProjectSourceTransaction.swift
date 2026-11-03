import Foundation
import PondsideCore

/// Coordinated writes to an existing include graph. Revision checks precede
/// writes; a failure restores completed writes without overwriting a newer
/// external revision. Each individual replacement is atomic on disk.
public enum ProjectSourceTransaction {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public static func replace(expected: [URL: ContentHash], replacements: [URL: String],
                               willWrite: (URL, String) -> Void = { _, _ in },
                               write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        guard replacements.keys.allSatisfy({ expected[$0] != nil }) else {
            throw Failure("A project edit refers to a file outside its revision snapshot.")
        }
        var originals: [URL: Data] = [:]
        for (url, revision) in expected {
            let data = try Data(contentsOf: url)
            guard ContentHash(bytes: data) == revision else {
                throw Failure("\(url.lastPathComponent) changed on disk. Resolve that change before editing structure.")
            }
            originals[url] = data
        }
        var written: [URL] = []
        do {
            for url in replacements.keys.sorted(by: { $0.path < $1.path }) {
                guard let text = replacements[url], let original = originals[url],
                      try Data(contentsOf: url) == original else {
                    throw Failure("\(url.lastPathComponent) changed while the project edit was being prepared.")
                }
                willWrite(url, text)
                try write(Data(text.utf8), url)
                written.append(url)
            }
        } catch {
            var failures: [String] = []
            for url in written.reversed() {
                do {
                    guard let original = originals[url], let replacement = replacements[url],
                          try Data(contentsOf: url) == Data(replacement.utf8) else {
                        failures.append(url.lastPathComponent + " changed again")
                        continue
                    }
                    willWrite(url, String(decoding: original, as: UTF8.self))
                    try write(original, url)
                } catch { failures.append(url.lastPathComponent) }
            }
            guard failures.isEmpty else {
                throw Failure("The project edit failed and could not restore \(failures.joined(separator: ", ")). Check these files before continuing. Original error: \(error)")
            }
            throw error
        }
    }
}
