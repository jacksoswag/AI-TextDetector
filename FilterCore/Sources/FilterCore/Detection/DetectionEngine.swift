import Foundation

/// One paragraph block in the check window's AI heat field: where it sits in the
/// analyzed string (a UTF-16 `NSRange`) and its AI probability from the same
/// Stage-1 → Stage-2 cascade the on-screen scan uses. The check view turns these
/// into the background gradient and the per-block hover tooltips.
public struct AIBlockScore: Sendable {
    public let range: NSRange
    public let probability: Double

    public init(range: NSRange, probability: Double) {
        self.range = range
        self.probability = probability
    }
}

extension AIBlockScore {
    /// The document-level AI score: a length-weighted mean of the block
    /// probabilities. It sits within [min, max] of the blocks by construction, so
    /// the headline can never exceed the most-AI block or undercut the least —
    /// unlike scoring the whole text as one max-biased blob. nil with no blocks.
    public static func documentScore(_ blocks: [AIBlockScore]) -> Double? {
        let totalWeight = blocks.reduce(0.0) { $0 + Double($1.range.length) }
        guard totalWeight > 0 else { return nil }
        let weighted = blocks.reduce(0.0) { $0 + $1.probability * Double($1.range.length) }
        return weighted / totalWeight
    }
}

public final class DetectionEngine: @unchecked Sendable {
    
    private let classifierProvider: @Sendable () -> PrimaryClassifier?
    private let stage2Provider: @Sendable () -> PrimaryClassifier?
    /// License gate for every scoring path — `evaluate`, `refine`, and the manual
    /// `analyze`. When it returns false (no license) the always-on path comes back
    /// `.unlicensed` and `analyze` returns nil; nothing is scored. Defaults to
    /// always-on, so tests and benchmarks are unaffected. The app passes
    /// `{ LicenseManager.isCurrentlyActive() }`.
    private let licenseGate: @Sendable () -> Bool

    private let temporalStabilizer: TemporalStabilizer
    private let cache = DetectionCache()

    private let defaults: UserDefaults
    private let trust: DomainTrustManager

    private let classifierLock = NSLock()
    private var stage1Classifier: PrimaryClassifier??
    private var stage2Classifier: PrimaryClassifier??
    /// Sticky highlight decisions per block id, so the hysteresis dead band
    /// returns the remembered state instead of recomputing a midpoint each
    /// scan. Both `evaluate` and `refine` read/write this, and a stale refine
    /// can overlap a new evaluate, so all access is guarded by `highlightLock`.
    private var lastHighlight: [String: Bool] = [:]
    private let highlightLock = NSLock()

    /// A classifier's (probability, uncertainty) for one block, from cache or a
    /// fresh batch. Shared by `evaluate` and `refine`.
    private struct Scored {
        var p1: Double
        var unc1: Double
    }

    public init(
        classifierProvider: @escaping @Sendable () -> PrimaryClassifier? = { CoreMLClassifier.loadDefault() },
        stage2Provider: @escaping @Sendable () -> PrimaryClassifier? = { CoreMLClassifier.loadStage2() },
        defaults: UserDefaults = .appGroup,
        trust: DomainTrustManager? = nil,
        licenseGate: @escaping @Sendable () -> Bool = { true }
    ) {
        self.classifierProvider = classifierProvider
        self.stage2Provider = stage2Provider
        self.licenseGate = licenseGate
        self.defaults = defaults
        self.trust = trust ?? DomainTrustManager(defaults: defaults)
        self.temporalStabilizer = TemporalStabilizer()
    }
    
    private func getStage1() -> PrimaryClassifier? {
        classifierLock.lock(); defer { classifierLock.unlock() }
        if let resolved = stage1Classifier { return resolved }
        let loaded = classifierProvider()
        stage1Classifier = .some(loaded)
        return loaded
    }
    
    private func getStage2() -> PrimaryClassifier? {
        classifierLock.lock(); defer { classifierLock.unlock() }
        if let resolved = stage2Classifier { return resolved }
        let loaded = stage2Provider()
        stage2Classifier = .some(loaded)
        return loaded
    }

    /// Load and ANE-compile both models off the hot path (call once at launch).
    /// Without this the first detection of a session pays the model load + ANE
    /// compile (~0.5s each) inline; warming them here moves that to startup.
    public func preload() async {
        if let s1 = getStage1() { _ = try? await s1.score(texts: ["warm up the model"]) }
        if let s2 = getStage2() { _ = try? await s2.score(texts: ["warm up the model"]) }
    }

    /// Score one piece of pasted text for the manual check window and return the
    /// calibrated AI probability (0...1), or nil if no license is active or no
    /// model could be loaded.
    ///
    /// The whole app is paid, so this surface is license-gated like `evaluate`
    /// and `refine`: with no license it returns nil and runs no inference. Once
    /// licensed it still bypasses the always-on quietness gates — the master
    /// enable switch, the word-count floor, trusted domains, and the
    /// confidence/"unknown" gate. Those keep the background overlay quiet and
    /// false-positive-averse; the check window is the opposite contract — the
    /// user pasted text and asked for a verdict, so one is always returned.
    public func analyze(text: String) async -> Double? {
        guard licenseGate() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stage1 = getStage1(),
              let s1 = (try? await stage1.score(texts: [trimmed]))?.first else { return nil }

        var pBase = s1.aiProbability
        // Escalate the ambiguous middle to Stage-2, mirroring evaluate()'s gate
        // (the small Stage-1 model reads formal human prose as AI across this
        // band) but without its word floor — a one-off check uses the best model
        // available regardless of length.
        let ambiguous = pBase >= 0.40 && pBase <= 0.93
        if (ambiguous || s1.uncertainty >= 0.50), let stage2 = getStage2(),
           let s2 = (try? await stage2.score(texts: [trimmed]))?.first {
            pBase = s2.aiProbability
        }

        return pBase
    }

    /// Score the check window's text as paragraph blocks, the same unit the
    /// on-screen scan works in, through the same Stage-1 → Stage-2 cascade — no
    /// sliding window. Each block is scored by Stage-1 in one batch; the ambiguous
    /// ones (the documented 0.40–0.93 band, or high cross-window dispersion) are
    /// arbitrated by Stage-2 in a second batch. No length floor on escalation: a
    /// one-off check uses the best model regardless of length, and batching keeps
    /// it cheap. Returns nil with no license or no model.
    ///
    /// Consecutive lines are GROUPED into blocks rather than scored one-per-line:
    /// a structured document (headings, one-line bullets) otherwise shreds into
    /// tiny fragments the model reads unreliably, which then drag the average
    /// toward whichever class short text leans. Lines accumulate until a block
    /// reaches `targetWords`, breaking at a blank line (a real section boundary);
    /// a leftover section under `minBlockWords` is dropped.
    public func scoreBlocks(text: String) async -> [AIBlockScore]? {
        guard licenseGate() else { return nil }
        let targetWords = 80
        let minBlockWords = 20

        let ns = text as NSString
        var lines: [(range: NSRange, words: Int)] = []
        ns.enumerateSubstrings(
            in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]
        ) { substring, range, _, _ in
            guard let substring,
                  !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            lines.append((range, TextMetrics.wordCount(substring)))
        }

        var ranges: [NSRange] = []
        var texts: [String] = []
        var i = 0
        while i < lines.count {
            let start = lines[i].range.location
            var end = NSMaxRange(lines[i].range)
            var words = lines[i].words
            var j = i
            while words < targetWords, j + 1 < lines.count {
                // A blank line (2+ newlines between two lines) is a hard break.
                let gap = ns.substring(with: NSRange(location: end, length: lines[j + 1].range.location - end))
                if gap.filter({ $0 == "\n" }).count >= 2 { break }
                j += 1
                end = NSMaxRange(lines[j].range)
                words += lines[j].words
            }
            if words >= minBlockWords {
                let range = NSRange(location: start, length: end - start)
                ranges.append(range)
                texts.append(ns.substring(with: range))
            }
            i = j + 1
        }

        guard !texts.isEmpty, let stage1 = getStage1() else { return nil }
        if Task.isCancelled { return nil }

        let s1 = (try? await stage1.score(texts: texts)) ?? []
        guard s1.count == texts.count else { return nil }
        var probabilities = s1.map(\.aiProbability)

        // Escalate the ambiguous middle to Stage-2 in one batch, mirroring
        // evaluate()'s gate (0.40–0.93, or dispersed) but without its word floor.
        let escalateIndices = s1.indices.filter {
            (s1[$0].aiProbability >= 0.40 && s1[$0].aiProbability <= 0.93) || s1[$0].uncertainty >= 0.50
        }
        if !escalateIndices.isEmpty, !Task.isCancelled, let stage2 = getStage2() {
            let s2 = (try? await stage2.score(texts: escalateIndices.map { texts[$0] })) ?? []
            for (k, index) in escalateIndices.enumerated() where k < s2.count {
                probabilities[index] = s2[k].aiProbability
            }
        }

        return zip(ranges, probabilities).map { AIBlockScore(range: $0, probability: $1) }
    }

    /// When `deferStage2` is true the slow Stage-2 model is NOT run here.
    /// Blocks the gate would escalate come back as Stage-1 verdicts flagged
    /// `needsRefinement`, and the caller asks `refine(...)` for them off the
    /// hot path. The default (false) keeps the synchronous two-stage cascade
    /// for callers that want one authoritative array (tests, benchmarks).
    public func evaluate(
        blocks: [BlockInput],
        domain: String?,
        source: TextSource = .native,
        deferStage2: Bool = false
    ) async -> [BlockVerdict] {
        let settings = SettingsSnapshot.current(defaults)
        
        guard settings.isEnabled else {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .disabled) }
        }
        if let domain, trust.isTrusted(domain) {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .trustedDomain) }
        }
        if PersonalSurfaces.isPersonalSurface(domain) {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .personalSurface) }
        }
        guard licenseGate() else {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .unlicensed) }
        }

        let stage1 = getStage1()

        // One slot per input block, in order. Each slot is either a finished
        // placeholder verdict (tooShort / modelUnavailable) or a scoreable block
        // carrying its cache key and word count (computed once here and reused by
        // the escalation gate). The final assembly walks these in order so the
        // one-verdict-per-input-in-order invariant holds.
        enum Slot {
            case placeholder(BlockVerdict)
            case scoreable(block: BlockInput, key: String, words: Int)
        }

        var slots: [Slot] = []
        slots.reserveCapacity(blocks.count)

        // With no Stage-1 classifier every scoreable block fails fast. Too-short
        // blocks become placeholders; the rest get a cache key. Cache misses go
        // into one batched Stage-1 call.
        var missTexts: [String] = []
        var missKeys: [String] = []
        var seenMissKeys = Set<String>()
        var cachedScored: [String: Scored] = [:]

        for block in blocks {
            let words = TextMetrics.wordCount(block.text)
            guard words >= settings.minWords else {
                slots.append(.placeholder(BlockVerdict(
                    id: block.id, result: .insufficientData,
                    shouldHighlight: false, skipReason: .tooShort)))
                continue
            }

            guard let stage1 else {
                slots.append(.placeholder(BlockVerdict(
                    id: block.id, result: .insufficientData,
                    shouldHighlight: false, skipReason: .modelUnavailable)))
                continue
            }

            let key = TextMetrics.cacheKey(block.text, detectorID: stage1.id)
            slots.append(.scoreable(block: block, key: key, words: words))

            if let hit = cache.scores(for: key), let p = hit.aiProbability {
                cachedScored[key] = Scored(p1: p, unc1: hit.uncertainty ?? 0)
            } else if seenMissKeys.insert(key).inserted {
                missTexts.append(block.text)
                missKeys.append(key)
            }
        }

        // Cancellation: before the Stage-1 call, bail out returning a verdict per
        // input in order (placeholders pass through; not-yet-scored scoreables
        // become insufficientData with no skipReason).
        if Task.isCancelled {
            return slots.map { slot in
                switch slot {
                case .placeholder(let v): return v
                case .scoreable(let block, _, _):
                    return BlockVerdict(id: block.id, result: .insufficientData,
                                        shouldHighlight: false)
                }
            }
        }

        // ONE batched Stage-1 call for every cache miss.
        var batchScored: [String: Scored] = [:]
        if let stage1, !missTexts.isEmpty {
            let outputs = (try? await stage1.score(texts: missTexts)) ?? []
            for (i, key) in missKeys.enumerated() {
                guard i < outputs.count else { continue }
                let out = outputs[i]
                batchScored[key] = Scored(p1: out.aiProbability, unc1: out.uncertainty)
                cache.insert(CachedScores(
                    aiProbability: out.aiProbability, uncertainty: out.uncertainty), for: key)
            }
        }

        func stage1Result(for key: String) -> Scored? {
            cachedScored[key] ?? batchScored[key]
        }

        // Escalate every block that isn't clearly human (< escalationLow) or
        // already-confident AI by Stage-1 (> escalationHigh): the small Stage-1
        // detector confuses formal/academic HUMAN prose for AI across the whole
        // ambiguous middle, so the stronger Stage-2 model arbitrates that band
        // (the documented 0.40–0.93 gate, replacing the old ±0.10-around-threshold
        // window that left most false positives unescalated). High cross-window
        // dispersion also escalates. ALL escalation is gated on a word floor:
        // the Stage-2 model (ModernBERT-large) is heavy and less reliable on very
        // short text, so short blocks are never sent to it; they rely on Stage-1
        // plus the confidence gate in makeVerdict. These signals come from Stage-1
        // alone, so we do NOT load the ~757MB Stage-2 model to compute them
        // (deferred mode must not pay that load on a confident-only scan;
        // refine() loads it lazily off the hot path).
        let escalationLow = 0.40
        let escalationHigh = 0.93
        let dispersionFloor = 0.50
        let escalationMinWords = 120

        var escalationKeys = Set<String>()
        for slot in slots {
            guard case let .scoreable(_, key, words) = slot,
                  let scored = stage1Result(for: key) else { continue }
            guard words >= escalationMinWords else { continue }
            let ambiguous = scored.p1 >= escalationLow && scored.p1 <= escalationHigh
            let dispersed = scored.unc1 >= dispersionFloor
            if ambiguous || dispersed { escalationKeys.insert(key) }
        }

        // Cancellation: bail before any Stage-2 work.
        if Task.isCancelled {
            return slots.map { slot in
                switch slot {
                case .placeholder(let v): return v
                case .scoreable(let block, _, _):
                    return BlockVerdict(id: block.id, result: .insufficientData,
                                        shouldHighlight: false)
                }
            }
        }

        // Synchronous cascade: ONE batched Stage-2 call over the borderline
        // subset (loads Stage-2 only if there is something to escalate). Deferred
        // mode skips this entirely — those blocks return Stage-1 verdicts flagged
        // `needsRefinement`, and the caller drives Stage-2 via refine() so the
        // heavier Stage-2 model never blocks confident highlights.
        var stage2Scored: [String: Scored] = [:]
        if !deferStage2, !escalationKeys.isEmpty, let stage2 = getStage2() {
            var escalateTexts: [String] = []
            var escalateKeys: [String] = []
            var seen = Set<String>()
            for slot in slots {
                guard case let .scoreable(block, key, _) = slot,
                      escalationKeys.contains(key), seen.insert(key).inserted else { continue }
                escalateTexts.append(block.text)
                escalateKeys.append(key)
            }
            let outputs = (try? await stage2.score(texts: escalateTexts)) ?? []
            for (i, key) in escalateKeys.enumerated() where i < outputs.count {
                let out = outputs[i]
                stage2Scored[key] = Scored(p1: out.aiProbability, unc1: out.uncertainty)
            }
        }

        // Assembly: walk slots in order, producing one verdict each.
        var verdicts: [BlockVerdict] = []
        verdicts.reserveCapacity(slots.count)
        var scoredIDs = Set<String>()

        for slot in slots {
            switch slot {
            case .placeholder(let verdict):
                verdicts.append(verdict)

            case .scoreable(let block, let key, _):
                guard let scored = stage1Result(for: key) else {
                    // No Stage-1 output for a scoreable block — fail fast, never
                    // escalate.
                    verdicts.append(BlockVerdict(
                        id: block.id, result: .insufficientData,
                        shouldHighlight: false, skipReason: .modelUnavailable))
                    continue
                }
                scoredIDs.insert(block.id)

                if let s2 = stage2Scored[key] {
                    // Synchronous escalation already resolved to Stage-2.
                    verdicts.append(makeVerdict(
                        block: block, pBase: s2.p1, finalUnc: s2.unc1,
                        stageUsed: "stage2", needsRefinement: false, settings: settings))
                } else {
                    // Stage-1 verdict. In deferred mode, flag the gate's
                    // candidates so the caller's refine() pass resolves them.
                    let pending = deferStage2 && escalationKeys.contains(key)
                    verdicts.append(makeVerdict(
                        block: block, pBase: scored.p1, finalUnc: scored.unc1,
                        stageUsed: "stage1", needsRefinement: pending, settings: settings))
                }
            }
        }

        // Prune EMA and sticky-highlight state for paragraphs no longer on screen
        // so they can't leak into future scans or grow unboundedly now that ids
        // are content-based.
        temporalStabilizer.retain(ids: scoredIDs)
        highlightLock.lock()
        for id in lastHighlight.keys where !scoredIDs.contains(id) {
            lastHighlight.removeValue(forKey: id)
        }
        highlightLock.unlock()

        return verdicts
    }

    /// Stage-aware verdict assembly: temporal smoothing → sticky hysteresis →
    /// confidence gate. Shared by the synchronous loop, the deferred Stage-1
    /// pass, and `refine`. Mutates `lastHighlight`; the caller records `block.id`
    /// in its scored-id set for pruning.
    private func makeVerdict(
        block: BlockInput,
        pBase: Double, finalUnc: Double, stageUsed: String,
        needsRefinement: Bool, settings: SettingsSnapshot
    ) -> BlockVerdict {
        // The model already applies its fitted Platt scaling in CoreMLClassifier,
        // so the final probability is the model's calibrated output as-is.
        let pFinal = pBase
        // NOTE: `invertedConfidence` is INVERTED by construction — highest at
        // p=0.5 (most uncertain), lowest at the extremes. It is recorded for
        // telemetry only; the confidence gate below uses an explicitly-oriented
        // test, never this value, so "more = surer" must not be assumed of it.
        let invertedConfidence = Float(1.0 - abs(0.5 - pFinal) * 2.0)

        // TEMPORAL STABILIZATION
        let smoothedP = temporalStabilizer.update(blockID: block.id, p: pFinal)

        // HYSTERESIS — enter at the user threshold, exit 12% below; in the dead
        // band stick to the remembered decision instead of a midpoint. This
        // decides only whether the score CLEARS THE BAR; the confidence gate
        // below decides whether clearing the bar is enough to actually paint.
        let enterHighlight = settings.threshold
        let exitHighlight = max(0.05, settings.threshold - 0.12)
        highlightLock.lock()
        let remembered = lastHighlight[block.id]
        let clearsBar: Bool
        if smoothedP >= enterHighlight {
            clearsBar = true
        } else if smoothedP <= exitHighlight {
            clearsBar = false
        } else {
            clearsBar = remembered ?? (smoothedP >= (enterHighlight + exitHighlight) / 2.0)
        }
        lastHighlight[block.id] = clearsBar
        highlightLock.unlock()

        // CONFIDENCE GATE: "unknown over false positive". Clearing the user's
        // threshold is necessary but not sufficient to paint. No model in the
        // cascade is trustworthy across the whole range: the small Stage-1
        // detector is reliable only near the extremes, and the Stage-2 model
        // (ModernBERT-large) still scores some formal HUMAN prose high. So ANY
        // verdict, Stage-1 or Stage-2, paints only when it is decisively AI
        // (>= confidentFloor); a lower score that cleared the bar is left UNKNOWN
        // (not painted). Escalating to Stage-2 buys a stronger second opinion
        // inside the ambiguous band, but its score is held to the same floor
        // rather than trusted unconditionally. A wildly dispersed block abstains.
        let confidentFloor = 0.80
        let uncertaintyCeiling = 0.90
        let decisivelyAI = smoothedP >= confidentFloor
        let tooUncertain = finalUnc >= uncertaintyCeiling
        let shouldHighlight = clearsBar && decisivelyAI && !tooUncertain

        let result = FinalDetectionResult(
            p_ai_final: Float(pFinal), invertedConfidence: invertedConfidence,
            uncertainty: Float(finalUnc), stage_used: stageUsed,
            // Calibration now lives entirely in the model (Platt scaling in
            // CoreMLClassifier when model-info carries it, else raw output).
            calibration_source: "model_builtin")

        return BlockVerdict(id: block.id, result: result,
                            shouldHighlight: shouldHighlight, needsRefinement: needsRefinement)
    }

    /// Resolve the borderline blocks held back by `evaluate(deferStage2: true)`.
    /// Runs at most ONE batched Stage-2 call over the cache misses (a persistent
    /// borderline highlight is therefore scored by the slow CPU model only once
    /// per unique text, not every scan), then returns authoritative Stage-2
    /// verdicts. Does NOT prune the stabilizer — the `evaluate` pass that
    /// produced these ids already retained the full on-screen set.
    public func refine(blocks: [BlockInput], domain: String?, source: TextSource = .native) async -> [BlockVerdict] {
        let settings = SettingsSnapshot.current(defaults)
        // Re-check the license here, not just in evaluate(): a license can lapse
        // between the deferred Phase-1 pass and this Phase-2 refine, and Stage-2
        // inference must never run for an unlicensed user.
        guard licenseGate() else {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .unlicensed) }
        }
        guard settings.isEnabled, !blocks.isEmpty, let stage2 = getStage2() else {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .modelUnavailable) }
        }

        var keyByID: [String: String] = [:]
        var scoredByKey: [String: Scored] = [:]
        var missTexts: [String] = []
        var missKeys: [String] = []
        var seenMiss = Set<String>()
        for block in blocks {
            let key = TextMetrics.cacheKey(block.text, detectorID: stage2.id)
            keyByID[block.id] = key
            if let hit = cache.scores(for: key), let p = hit.aiProbability {
                scoredByKey[key] = Scored(p1: p, unc1: hit.uncertainty ?? 0)
            } else if seenMiss.insert(key).inserted {
                missTexts.append(block.text)
                missKeys.append(key)
            }
        }

        if Task.isCancelled {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false) }
        }

        if !missTexts.isEmpty {
            let outputs = (try? await stage2.score(texts: missTexts)) ?? []
            for (i, key) in missKeys.enumerated() where i < outputs.count {
                let out = outputs[i]
                scoredByKey[key] = Scored(p1: out.aiProbability, unc1: out.uncertainty)
                cache.insert(CachedScores(
                    aiProbability: out.aiProbability, uncertainty: out.uncertainty), for: key)
            }
        }

        return blocks.map { block in
            guard let key = keyByID[block.id], let s2 = scoredByKey[key] else {
                return BlockVerdict(id: block.id, result: .insufficientData, shouldHighlight: false, skipReason: .modelUnavailable)
            }
            return makeVerdict(block: block, pBase: s2.p1, finalUnc: s2.unc1,
                               stageUsed: "stage2", needsRefinement: false, settings: settings)
        }
    }

}
