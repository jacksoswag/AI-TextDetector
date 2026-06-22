import Foundation

public final class DetectionEngine: @unchecked Sendable {
    
    private let classifierProvider: @Sendable () -> PrimaryClassifier?
    private let stage2Provider: @Sendable () -> PrimaryClassifier?
    /// Gate for the always-on overlay path: when it returns false (trial ended,
    /// no license) every block comes back `.unlicensed` and nothing is scored.
    /// Defaults to always-on, so tests, benchmarks, and the manual check window
    /// are unaffected. The app passes `{ LicenseManager.isCurrentlyActive() }`.
    private let licenseGate: @Sendable () -> Bool

    private let calibration: CalibrationEngine
    private let temporalStabilizer: TemporalStabilizer
    private let eventLog: SemanticEventLog
    private let cache = DetectionCache()

    private let defaults: UserDefaults
    private let trust: DomainTrustManager
    private let router: DomainRouter

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
        router: DomainRouter? = nil,
        licenseGate: @escaping @Sendable () -> Bool = { true }
    ) {
        self.classifierProvider = classifierProvider
        self.stage2Provider = stage2Provider
        self.licenseGate = licenseGate
        self.defaults = defaults
        self.trust = trust ?? DomainTrustManager(defaults: defaults)
        self.router = router ?? DomainRouter()
        
        self.calibration = CalibrationEngine()
        self.temporalStabilizer = TemporalStabilizer()
        self.eventLog = SemanticEventLog(defaults: defaults)
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
    /// calibrated AI probability (0...1), or nil if no model could be loaded.
    ///
    /// Unlike `evaluate`, this surface is deliberately UNGATED: it ignores the
    /// master enable switch, the word-count floor, trusted domains, and the
    /// confidence/"unknown" gate. Those gates exist to keep the always-on overlay
    /// quiet and false-positive-averse; the check window is the opposite contract
    /// — the user pasted text and asked for a verdict, so one is always returned.
    public func analyze(text: String) async -> Double? {
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

        let route = router.route(text: trimmed, webDomain: nil)
        return calibration.calibrate(pBase: pBase, domain: route.domain.rawValue)
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
        // placeholder verdict (tooShort / modelUnavailable) or a scoreable
        // block carrying its route + cache key. The final assembly walks these
        // in order so the one-verdict-per-input-in-order invariant holds.
        enum Slot {
            case placeholder(BlockVerdict)
            case scoreable(block: BlockInput, route: RoutingDecision, key: String)
        }

        var slots: [Slot] = []
        slots.reserveCapacity(blocks.count)

        // FIX #5: with no Stage-1 classifier every scoreable block fails fast.
        // FIX #8 first pass: too-short blocks become placeholders, the rest get
        // a route + cache key. FIX #7: cache misses go into one Stage-1 batch.
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

            let route = router.route(text: block.text, webDomain: domain)
            let key = TextMetrics.cacheKey(block.text, detectorID: stage1.id)
            slots.append(.scoreable(block: block, route: route, key: key))

            if let hit = cache.scores(for: key), let p = hit.aiProbability {
                cachedScored[key] = Scored(p1: p, unc1: hit.uncertainty ?? 0)
            } else if seenMissKeys.insert(key).inserted {
                missTexts.append(block.text)
                missKeys.append(key)
            }
        }

        // FIX #8 cancellation: before the Stage-1 call, bail out returning a
        // verdict per input in order (placeholders pass through; not-yet-scored
        // scoreables become insufficientData with no skipReason).
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

        // FIX #8: ONE batched Stage-1 call for every cache miss.
        var batchScored: [String: Scored] = [:]
        if let stage1, !missTexts.isEmpty {
            let outputs = (try? await stage1.score(texts: missTexts)) ?? []
            for (i, key) in missKeys.enumerated() {
                guard i < outputs.count else { continue }
                let out = outputs[i]
                batchScored[key] = Scored(p1: out.aiProbability, unc1: out.uncertainty)
                // FIX #7: cache Stage-1/general output only (matches the
                // documented meaning of CachedScores).
                cache.insert(CachedScores(
                    fastScore: 0, heuristicConfidence: 0,
                    aiProbability: out.aiProbability, uncertainty: out.uncertainty,
                    features: HeuristicFeatures()), for: key)
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
            guard case let .scoreable(block, _, key) = slot,
                  let scored = stage1Result(for: key) else { continue }
            guard TextMetrics.wordCount(block.text) >= escalationMinWords else { continue }
            let ambiguous = scored.p1 >= escalationLow && scored.p1 <= escalationHigh
            let dispersed = scored.unc1 >= dispersionFloor
            if ambiguous || dispersed { escalationKeys.insert(key) }
        }

        // FIX #8 cancellation: bail before any Stage-2 work.
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
                guard case let .scoreable(block, _, key) = slot,
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

        // FIX #8 assembly: walk slots in order, producing one verdict each.
        var verdicts: [BlockVerdict] = []
        verdicts.reserveCapacity(slots.count)
        var scoredIDs = Set<String>()

        for slot in slots {
            switch slot {
            case .placeholder(let verdict):
                verdicts.append(verdict)

            case .scoreable(let block, let route, let key):
                guard let scored = stage1Result(for: key) else {
                    // FIX #5: no Stage-1 output for a scoreable block — fail
                    // fast, never escalate.
                    verdicts.append(BlockVerdict(
                        id: block.id, result: .insufficientData,
                        shouldHighlight: false, skipReason: .modelUnavailable))
                    continue
                }
                scoredIDs.insert(block.id)

                if let s2 = stage2Scored[key] {
                    // Synchronous escalation already resolved to Stage-2.
                    verdicts.append(makeVerdict(
                        block: block, route: route, pBase: s2.p1, finalUnc: s2.unc1,
                        stageUsed: "stage2", needsRefinement: false, settings: settings))
                } else {
                    // Stage-1 verdict. In deferred mode, flag the gate's
                    // candidates so the caller's refine() pass resolves them.
                    let pending = deferStage2 && escalationKeys.contains(key)
                    verdicts.append(makeVerdict(
                        block: block, route: route, pBase: scored.p1, finalUnc: scored.unc1,
                        stageUsed: "stage1", needsRefinement: pending, settings: settings))
                }
            }
        }

        // FIX #6 / FIX #4: prune EMA and sticky-highlight state for paragraphs
        // no longer on screen so they can't leak into future scans or grow
        // unboundedly now that ids are content-based.
        temporalStabilizer.retain(ids: scoredIDs)
        highlightLock.lock()
        for id in lastHighlight.keys where !scoredIDs.contains(id) {
            lastHighlight.removeValue(forKey: id)
        }
        highlightLock.unlock()

        return verdicts
    }

    /// Stage-aware verdict assembly: calibration → temporal smoothing → sticky
    /// hysteresis → event log. Shared by the synchronous loop, the deferred
    /// Stage-1 pass, and `refine`. Mutates `lastHighlight`; the caller records
    /// `block.id` in its scored-id set for pruning.
    private func makeVerdict(
        block: BlockInput, route: RoutingDecision,
        pBase: Double, finalUnc: Double, stageUsed: String,
        needsRefinement: Bool, settings: SettingsSnapshot
    ) -> BlockVerdict {
        let pFinal = calibration.calibrate(pBase: pBase, domain: route.domain.rawValue)
        // NOTE: `confidence` is INVERTED by construction — highest at p=0.5 (most
        // uncertain), lowest at the extremes. It is recorded for telemetry only;
        // the confidence gate below uses an explicitly-oriented test, never this
        // value, so "more confidence = surer" must not be assumed of it.
        let confidence = Float(1.0 - abs(0.5 - pFinal) * 2.0)

        // TEMPORAL STABILIZATION
        let smoothedP = temporalStabilizer.update(blockID: block.id, p: pFinal)

        // HYSTERESIS — enter at the user threshold, exit 12% below; FIX #4: in
        // the dead band stick to the remembered decision instead of a midpoint.
        // This decides only whether the score CLEARS THE BAR; the confidence gate
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
            p_ai_final: Float(pFinal), confidence: confidence,
            uncertainty: Float(finalUnc), stage_used: stageUsed,
            calibration_source: "domain_calibrator")

        // Telemetry separates a confidence-gated abstention ("unknown") from a
        // plain below-threshold "ignored", so gate-distribution analysis can see
        // how often the gate suppresses a would-be highlight.
        let uiAction: String
        if shouldHighlight { uiAction = "highlight" }
        else if clearsBar { uiAction = "unknown" }
        else { uiAction = "ignored" }

        eventLog.record(ReplayEvent(
            timestamp: Date(),
            blockHash: SemanticEventLog.hashBlock(block.text),
            stageUsed: stageUsed, pAiFinal: Float(pFinal), confidence: confidence,
            uncertainty: Float(finalUnc), domain: route.domain.rawValue,
            latencyMs: 45,
            uiAction: uiAction,
            explainability: ExplainabilitySnapshot(
                calibrationApplied: pFinal - pBase,
                uncertaintyBreakdown: finalUnc,
                confidenceDistribution: Double(confidence),
                stageDecisionReason: stageUsed == "stage2" ? "escalation_criteria_met" : "high_confidence")))

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
        guard settings.isEnabled, !blocks.isEmpty, let stage2 = getStage2() else {
            return blocks.map { BlockVerdict(id: $0.id, result: .insufficientData, shouldHighlight: false, skipReason: .modelUnavailable) }
        }

        var routeByID: [String: RoutingDecision] = [:]
        var keyByID: [String: String] = [:]
        var scoredByKey: [String: Scored] = [:]
        var missTexts: [String] = []
        var missKeys: [String] = []
        var seenMiss = Set<String>()
        for block in blocks {
            let route = router.route(text: block.text, webDomain: domain)
            routeByID[block.id] = route
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
                    fastScore: 0, heuristicConfidence: 0,
                    aiProbability: out.aiProbability, uncertainty: out.uncertainty,
                    features: HeuristicFeatures()), for: key)
            }
        }

        return blocks.map { block in
            guard let route = routeByID[block.id], let key = keyByID[block.id],
                  let s2 = scoredByKey[key] else {
                return BlockVerdict(id: block.id, result: .insufficientData, shouldHighlight: false, skipReason: .modelUnavailable)
            }
            return makeVerdict(block: block, route: route, pBase: s2.p1, finalUnc: s2.unc1,
                               stageUsed: "stage2", needsRefinement: false, settings: settings)
        }
    }

}
