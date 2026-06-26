import XCTest
@testable import FilterCore

/// Covers DetectionEngine.scoreBlocks — the check window's paragraph-block scoring.
final class AIBlockTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func engine(
        stage1: PrimaryClassifier?,
        stage2: PrimaryClassifier? = nil,
        licenseGate: @escaping @Sendable () -> Bool = { true }
    ) -> DetectionEngine {
        DetectionEngine(
            classifierProvider: { stage1 },
            stage2Provider: { stage2 },
            defaults: defaults,
            licenseGate: licenseGate)
    }

    private func markerFractionClassifier() -> MockClassifier {
        MockClassifier { t in
            let tokens = t.split(whereSeparator: { $0.isWhitespace })
            guard !tokens.isEmpty else { return 0 }
            return Double(tokens.filter { $0 == "ROBOT" }.count) / Double(tokens.count)
        }
    }

    /// A blank line is a hard section break: the human and AI paragraphs become
    /// two blocks, scored low and high.
    func testBlankLineSeparatesBlocks() async {
        let human = Array(repeating: "alpha", count: 40).joined(separator: " ")
        let ai = Array(repeating: "ROBOT", count: 40).joined(separator: " ")
        let text = human + "\n\n" + ai

        guard let blocks = await engine(stage1: markerFractionClassifier()).scoreBlocks(text: text) else {
            return XCTFail("expected blocks")
        }
        XCTAssertEqual(blocks.count, 2, "blank line splits into two blocks")
        XCTAssertLessThan(blocks[0].probability, 0.1, "human block reads low")
        XCTAssertGreaterThan(blocks[1].probability, 0.9, "AI block reads high")
        XCTAssertLessThan(blocks[0].range.location, blocks[1].range.location, "blocks stay in order")
    }

    /// Short single-newline lines (the bullet-list case) merge into one block
    /// instead of shredding into tiny per-line fragments.
    func testShortLinesMergeWithinSection() async {
        let line = Array(repeating: "ROBOT", count: 8).joined(separator: " ")
        let text = Array(repeating: line, count: 6).joined(separator: "\n")   // 48 words, no blank lines

        let blocks = await engine(stage1: markerFractionClassifier()).scoreBlocks(text: text)
        XCTAssertEqual(blocks?.count, 1, "single-newline lines merge into one block")
        XCTAssertGreaterThan(blocks?.first?.probability ?? 0, 0.9)
    }

    /// A lone short section (under the floor) yields nothing to score.
    func testTinySectionDropped() async {
        let blocks = await engine(stage1: MockClassifier(probability: 0.9)).scoreBlocks(text: "just five short words here")
        XCTAssertNil(blocks)
    }

    /// Ambiguous Stage-1 blocks are arbitrated by Stage-2 in a single batch.
    func testScoreBlocksEscalatesAmbiguousToStage2() async {
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let stage1 = MockClassifier(probability: 0.60, id: "s1")
        let stage2 = MockClassifier(probability: 0.95, id: "s2")

        let blocks = await engine(stage1: stage1, stage2: stage2).scoreBlocks(text: text)
        XCTAssertEqual(blocks?.first?.probability ?? 0, 0.95, accuracy: 0.001,
                       "the ambiguous block's score comes from Stage-2")
        XCTAssertEqual(stage2.callCount, 1, "Stage-2 runs once, batched")
    }

    /// The headline is a length-weighted mean and stays within the block range —
    /// the 38/19/63/66 case that wrongly read 74% as a whole-blob score.
    func testDocumentScoreStaysWithinBlockRange() {
        let blocks = [0.38, 0.19, 0.63, 0.66].enumerated().map {
            AIBlockScore(range: NSRange(location: $0.offset * 100, length: 100), probability: $0.element)
        }
        let doc = AIBlockScore.documentScore(blocks)!
        XCTAssertEqual(doc, (0.38 + 0.19 + 0.63 + 0.66) / 4, accuracy: 0.001, "equal lengths → plain mean")
        XCTAssertLessThanOrEqual(doc, 0.66, "never exceeds the most-AI block")
        XCTAssertGreaterThanOrEqual(doc, 0.19, "never below the least")
    }

    func testDocumentScoreWeightsByLength() {
        let blocks = [
            AIBlockScore(range: NSRange(location: 0, length: 900), probability: 0.10),
            AIBlockScore(range: NSRange(location: 900, length: 100), probability: 0.90),
        ]
        // 0.9·0.10 + 0.1·0.90 = 0.18, not the 0.50 a plain mean would give.
        XCTAssertEqual(AIBlockScore.documentScore(blocks)!, 0.18, accuracy: 0.001)
        XCTAssertNil(AIBlockScore.documentScore([]))
    }

    /// No license → no inference, nil result.
    func testScoreBlocksUnlicensedReturnsNil() async {
        let stage1 = MockClassifier(probability: 0.9)
        let text = Array(repeating: "word", count: 40).joined(separator: " ")
        let blocks = await engine(stage1: stage1, licenseGate: { false }).scoreBlocks(text: text)
        XCTAssertNil(blocks)
        XCTAssertEqual(stage1.callCount, 0)
    }
}
