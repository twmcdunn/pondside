import PondsideTiming

/// Physical system cards plus their performed order. LilyPond's source
/// timing follows rests and repeats; the player needs no notation parser.
public struct PerformanceTimeline: Sendable {
    public struct Card: Sendable {
        public var page: Int
        public var band: ClosedRange<Double>
    }
    public struct Entry: Sendable {
        public var card: Int
        public var seconds: Double
    }
    public var cards: [Card]
    public var entries: [Entry]

    public init(log: TimingLog, pages: [EngravedPage]) {
        let cards = pages.enumerated().flatMap { index, page in
            EngravedPage.systems(of: page.staves).map { Card(page: index, band: $0) }
        }
        var cueLog = log
        for i in cueLog.rows.indices {
            // Cues over tacet/graphical passages anchor the same physical
            // systems as notes, without manufacturing musical time.
            if case .text = cueLog.rows[i].kind, cueLog.rows[i].origin != nil {
                cueLog.rows[i].kind = .note(staff: "", midi: 60)
            }
        }
        let track = PlayheadTrack(log: cueLog, pages: pages)
        var entries: [Entry] = []
        for stop in track.stops {
            let middle = (stop.position.top + stop.position.bottom) / 2
            let choices = cards.indices.filter { cards[$0].page == stop.position.page }
            guard let card = choices.min(by: {
                abs((cards[$0].band.lowerBound + cards[$0].band.upperBound) / 2 - middle)
                    < abs((cards[$1].band.lowerBound + cards[$1].band.upperBound) / 2 - middle)
            }), entries.last?.card != card else { continue }
            entries.append(Entry(card: card, seconds: stop.seconds))
        }
        self.cards = cards
        self.entries = entries
    }
}
