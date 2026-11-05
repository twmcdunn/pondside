// swift-tools-version: 6.0
import PackageDescription

// The portability seam (docs/DESIGN.md): everything below PondsideUI must
// build and test on Linux. CI builds these targets on Linux on every push,
// and scripts/check-seam.sh rejects Apple-only imports in them.

var products: [Product] = [
    .executable(name: "pondside", targets: ["PondsideCLI"]),
    .library(name: "PondsideCore", targets: ["PondsideCore"]),
    .library(name: "PondsideEngrave", targets: ["PondsideEngrave"]),
    .library(name: "PondsideTiming", targets: ["PondsideTiming"]),
    .library(name: "PondsideLexicon", targets: ["PondsideLexicon"]),
    .library(name: "PondsideBridge", targets: ["PondsideBridge"]),
]

// External packages are UI-only: the portable modules depend on nothing.
var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    // Portable — no AppKit, no SwiftUI, no Apple-only Foundation.
    .target(name: "PondsideCore"),
    .target(name: "PondsideEngrave", dependencies: ["PondsideCore", "PondsideTiming"], resources: [.copy("Playback")]),
    .target(name: "PondsideTiming", dependencies: ["PondsideCore"]),
    .target(name: "PondsideLexicon", dependencies: ["PondsideCore"], resources: [.copy("Core")]),
    .target(name: "PondsideBridge", dependencies: ["PondsideCore", "PondsideEngrave", "PondsideTiming", "PondsideLexicon"]),
    .executableTarget(name: "PondsideCLI", dependencies: ["PondsideCore", "PondsideEngrave", "PondsideTiming", "PondsideLexicon", "PondsideBridge"]),

    // Shared real-world scores live in Tests/Scores and are read by path.
    .testTarget(name: "PondsideCoreTests", dependencies: ["PondsideCore"]),
    .testTarget(name: "PondsideTimingTests", dependencies: ["PondsideTiming"]),
    .testTarget(name: "PondsideBridgeTests", dependencies: ["PondsideBridge"]),
    .testTarget(name: "PondsideLexiconTests", dependencies: ["PondsideLexicon", "PondsideEngrave"]),
    .testTarget(name: "PondsideEngraveTests", dependencies: ["PondsideEngrave"], resources: [.copy("Fixtures")]),
]

#if os(macOS)
// ─────────────────────────── seam ───────────────────────────
// macOS only. Treated as disposable: a port replaces these two targets.
products.append(.executable(name: "PondsideApp", targets: ["PondsideApp"]))
dependencies.append(.package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.5.1")))
dependencies.append(.package(url: "https://github.com/jiyimeta/swift-sheet-music", exact: "4.11.0"))
targets += [
    .target(name: "PondsideUI", dependencies: ["PondsideCore", "PondsideEngrave", "PondsideTiming", "PondsideLexicon", "PondsideBridge",
                                               .product(name: "SwiftTerm", package: "SwiftTerm"),
                                               .product(name: "SheetMusicCore", package: "swift-sheet-music"),
                                               .product(name: "SheetMusicMusicXML", package: "swift-sheet-music"),
                                               .product(name: "SheetMusicLayout", package: "swift-sheet-music"),
                                               .product(name: "SheetMusicLayoutApple", package: "swift-sheet-music"),
                                               .product(name: "SheetMusicUI", package: "swift-sheet-music")], resources: [.copy("Performance")]),
    .executableTarget(name: "PondsideApp", dependencies: ["PondsideUI"]),
]
#endif

let package = Package(
    name: "Pondside",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
