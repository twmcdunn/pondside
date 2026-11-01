import XCTest
@testable import PondsideCore

final class SCLexerTests: XCTestCase {
    func kinds(_ s: String) -> [SCTokenKind] { SCLexer.tokenize(s).map(\.kind).filter { $0 != .whitespace } }

    func testTokenKinds() {
        XCTAssertEqual(kinds("SinOsc.ar(440, 0.1e-2) // hi"),
                       [.className, .punctuation, .identifier, .openParen, .number, .punctuation, .number, .closeParen, .comment])
        XCTAssertEqual(kinds("~a = \\sym ++ 'q r' ++ $a ++ \"s\\\"t\""),
                       [.environment, .punctuation, .symbol, .punctuation, .punctuation, .symbol, .punctuation, .punctuation,
                        .character, .punctuation, .punctuation, .string])
        XCTAssertEqual(kinds("var x = nil; 2pi; 0x1F; 2r101"), [.keyword, .identifier, .punctuation, .builtin, .punctuation,
                                                                 .number, .punctuation, .number, .punctuation, .number])
        XCTAssertEqual(kinds("/* a /* nested */ b */ x"), [.comment, .identifier])
    }

    func testTokensCoverTheText() {
        let text = "(\n{ SinOsc.ar([440, 442]) * 0.1 }.play;\n// \"unterminated\n\"str"
        let tokens = SCLexer.tokenize(text)
        XCTAssertEqual(tokens.first?.range.lowerBound, 0)
        XCTAssertEqual(tokens.last?.range.upperBound, text.utf16.count)
        for (a, b) in zip(tokens, tokens.dropFirst()) { XCTAssertEqual(a.range.upperBound, b.range.lowerBound) }
    }
}

final class SCRegionTests: XCTestCase {
    func testTopLevelBlocksAreTheOnesRunOneByOne() {
        let text = "// a\n(\n~a = (1 + 2);\n)\n~start.(0);\n(\n\"(\";\n)\n  x.(1)\n"
        let u = Array(text.utf16)
        let blocks = SCRegion.topLevelBlocks(in: text).map { String(decoding: u[$0], as: UTF16.self) }
        XCTAssertEqual(blocks, ["(\n~a = (1 + 2);\n)", "(\n\"(\";\n)"])
    }

    func offset(of marker: String, in text: String) -> Int { text.utf16.distance(from: text.utf16.startIndex, to: text.range(of: marker)!.lowerBound.samePosition(in: text.utf16)!) }

    func testSelectionWins() {
        XCTAssertEqual(SCRegion.evaluationRange(in: "1 + 2", selection: 0..<1), 0..<1)
    }

    func testOutermostLineStartingBlock() {
        let text = "x = 1;\n(\nvar a = (1 + 2);\n\"in (a string\".postln;\n)\ny = 2;"
        let caret = offset(of: "1 + 2", in: text)
        let r = SCRegion.evaluationRange(in: text, selection: caret..<caret)
        let s = Array(text.utf16)[r]
        XCTAssertEqual(String(decoding: s, as: UTF16.self), "(\nvar a = (1 + 2);\n\"in (a string\".postln;\n)")
        // Just after the closing paren still counts.
        let end = offset(of: ")\ny", in: text) + 1
        XCTAssertEqual(SCRegion.evaluationRange(in: text, selection: end..<end), r)
    }

    func testLineWhenNoBlock() {
        let text = "x = 1;\nf.(1, (2))\ny = 2;"
        let caret = offset(of: "1, (2)", in: text)
        let r = SCRegion.evaluationRange(in: text, selection: caret..<caret)
        XCTAssertEqual(String(decoding: Array(text.utf16)[r], as: UTF16.self), "f.(1, (2))")
    }

    func testMatchingBracketSkipsStrings() {
        let text = "{ \"}\" }"
        XCTAssertEqual(SCRegion.matchingBracket(in: text, at: 0), 6)
        XCTAssertEqual(SCRegion.matchingBracket(in: text, at: 6), 0)
    }
}

final class SCCompletionTests: XCTestCase {
    let library = SCClassLibrary(tsv: """
    C\tObject\t\tThe root
    C\tUGen\tObject\tUnit generator
    C\tSinOsc\tUGen\tInterpolating sine wavetable oscillator.
    C\tSaw\tUGen\tBand limited sawtooth.
    C\tString\tObject\tText
    C\tClass\tObject\tA class
    M\tSinOsc\tc\tar\tfreq=440.0,phase=0.0,mul=1.0,add=0.0
    M\tSinOsc\tc\tkr\tfreq=440.0,phase=0.0,mul=1.0,add=0.0
    M\tSinOsc\tc\tnew\tfreq
    M\tUGen\ti\trange\tlo=0.0,hi=1.0
    M\tObject\ti\tpostln\t
    M\tObject\ti\tfreq_\tx
    M\tString\ti\treverse\t
    M\tClass\ti\tname\t
    M\tObject\ti\t+\tb
    """)

    func labels(_ text: String, explicit: Bool = false) -> [String]? {
        SCCompletion.complete(text, caret: text.utf16.count, library: library, explicit: explicit)?.items.map(\.label)
    }

    func testClassNames() {
        XCTAssertEqual(labels("Si"), ["SinOsc"])
        XCTAssertNil(labels("S"))
        XCTAssertEqual(labels("S", explicit: true), ["Saw", "SinOsc", "String"])
    }

    func testClassMethodsIncludeInheritedFromClass() {
        // Class objects are Objects too.
        XCTAssertEqual(labels("SinOsc.")?.sorted(), ["ar", "kr", "name", "new", "postln"])
        XCTAssertEqual(SCCompletion.complete("SinOsc.k", caret: 8, library: library)?.replacing, 7..<8)
    }

    func testInstanceMethodsFromLiteralsAndConstructors() {
        XCTAssertEqual(labels("\"abc\".re"), ["reverse"])
        XCTAssertEqual(labels("SinOsc.ar(440).ra"), ["range"])
        // Setters only once asked for; operators never.
        XCTAssertEqual(labels("\"abc\".")?.sorted(), ["postln", "reverse"])
    }

    func testUnknownReceiverOffersEveryMethod() {
        XCTAssertEqual(labels("x.po"), ["postln"])
    }

    func testNothingInsideStringsOrComments() {
        XCTAssertNil(labels("\"Sin"))
        XCTAssertNil(labels("// Sin"))
    }

    func testVariablesAndEnvironment() {
        XCTAssertEqual(labels("var freq = 1; fr"), ["freq"])
        XCTAssertEqual(labels("~gain = 1; ~ga"), ["gain"])
    }

    func testSignatureHelp() {
        let s = SCCompletion.signature("SinOsc.ar(440, ", caret: 15, library: library)
        XCTAssertEqual(s?.method.name, "ar")
        XCTAssertEqual(s?.activeArgument, 1)
        XCTAssertEqual(s?.display, "SinOsc.ar(freq: 440.0, ‹phase: 0.0›, mul: 1.0, add: 0.0)")
        XCTAssertEqual(SCCompletion.signature("SinOsc.ar(mul: [1, 2", caret: 20, library: library)?.activeArgument, 2)
        XCTAssertEqual(SCCompletion.signature("SinOsc(", caret: 7, library: library)?.method.name, "new")
        XCTAssertEqual(SCCompletion.signature("SinOsc.ar(1).range(0, ", caret: 22, library: library)?.method.owner, "UGen")
        XCTAssertNil(SCCompletion.signature("SinOsc.ar(1);", caret: 13, library: library))
    }

    func testHelpTopic() {
        XCTAssertEqual(SCCompletion.helpTopic("SinOsc.ar", caret: 3, library: library), .init(word: "SinOsc"))
        XCTAssertEqual(SCCompletion.helpTopic("SinOsc.ar", caret: 9, library: library),
                       .init(word: "ar", className: "SinOsc", anchor: "*ar"))
        XCTAssertEqual(SCCompletion.helpTopic("x.postln", caret: 4, library: library), .init(word: "postln"))
    }
}

final class SCPostStreamTests: XCTestCase {
    func testRepliesAreSeparatedFromPosts() {
        var s = SCPostStream()
        XCTAssertEqual(s.feed("-> 3\npartial"), [.post("-> 3\npartial")])
        XCTAssertEqual(s.feed(" line\n\u{1E}PONDSIDE 7 file:///x"), [.post(" line\n")])
        XCTAssertEqual(s.feed(".html\nafter\n"), [.reply(id: 7, payload: "file:///x.html"), .post("after\n")])
    }
}
