import Foundation
import PondsideCore
import PondsideEngrave

/// Shared instructions for every agent surface that can change score source.
public enum ScoreContract {
    public static let uri = "pondside://contract"
    public static let notice = "For managed .ly/.ily scores, preserve the generated shared-measure block and ordered voice wrappers, keep content within each shared meter, and put meter/break changes in the shared definitions rather than adding local commands; read the [complete .ly contract](pondside://contract) before editing."

    public static let documentation = """
    # Pondside .ly editing contract

    The .ly/.ily files are the only score state. Use minimal source edits; preserve unrelated text.
    A managed root has `% pondside-structure v1 ...` through `% end pondside-structure`.
    Keep that generated block, its helper implementations, marker flags and definitions intact.
    Each pondsideBar definition owns one literal meter, a skip of the same exact rational length,
    and optionally a final system/page break. Never edit the helper's Scheme implementation.

    Every score voice contains one `\\pondsideMeasure \\pondsideBarNAME { music }` wrapper for
    every shared definition, in the same order. Preserve all wrappers, including empty ones.
    Do not add sounding music outside these wrappers or rename, duplicate or reorder bars in one voice.
    Front-matter examples are templates, not score voices, and remain outside this timeline.

    Put meter changes at the start of the shared definition. A break before a selected measure
    belongs at the END of the preceding definition. When shared breaks are enabled, do not insert
    local \\break or \\pageBreak commands in voices. Do not insert local \\time, \\partial,
    \\cadenzaOn/Off, \\noBreak or \\noPageBreak into managed measure bodies.
    Coordinate structural changes across all affected files in one transaction.

    Each body's sounding content and ordinary rests must fit its shared meter. The helper pads
    short bodies with skips and LilyPond rejects overflow. `s1*0` is a selectable empty-measure
    anchor; retain it when a measure is empty. An unadorned full-measure rest follows the meter.
    Unmetered entry grows the shared definition across voices; ending it does not insert a local meter.

    Layout-only spans use proportional \\pondsideSpace anchors naming their own shared bar;
    their fractions must fit that bar. Evaluated contracts (`evaluated=1`) also use generated
    \\pondsideLayout anchors and \\pondsideTimeline. Preserve these anchors, the opt-out flags,
    custom music functions, layout policies and spacing sections. Do not flatten generated music
    or guess at opaque timing. Existing helpers must remain compatible with LilyPond 2.24 and 2.26.

    Preserve other notes' absolute pitches and inherited durations when inserting/deleting music.
    Cues, mockups, handlers and timing files are produced by Pondside's existing pipeline.
    Never introduce another timing pipeline or persistent score state.

    The edit tool checks the complete proposed source contract before writing. LilyPond validates
    interpreter-dependent timing during engraving. Repair diagnostics before declaring the edit done.
    Use File → Make Score Pondside-Ready to migrate or repair the contract; report an unsupported
    structural change instead of weakening the generated helper or bypassing validation.

    Further design and examples: docs/API.md#restore-defaults-and-structural-editing in the source
    repository. This resource is available in installed Pondside through resources/read, too.
    """

    /// The same preflight for tools and the GUI: reject before writing any file.
    public static func validateEdit(source: URL, text: String, root: URL) throws {
        try validateEdits([source: text], root: root)
    }

    public static func validateEdits(_ replacements: [URL: String], root: URL,
                                     allowingContractRemoval: Bool = false) throws {
        let before = SourceGraph.load(root: root)
        let after = SourceGraph.load(root: root, overrides: replacements)
        let rootID = SourceGraph.canonical(root).path
        let old = before.files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree) }
        let next = after.files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree) }
        try StructuralEditing.verifyProjectEdit(before: old, proposed: next, root: rootID,
                                                allowingContractRemoval: allowingContractRemoval)
    }
}
