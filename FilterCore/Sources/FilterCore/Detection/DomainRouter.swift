import Foundation

/// ROUTING — picks the primary expert for a block before scoring.
///
/// Deterministic and ML-free by design (the same rule as Layer 1): a fixed
/// lexicon/structure scan per register plus a fixed web-domain hint table.
/// The same text routes identically across scrolls, rescans, and launches,
/// which keeps the score cache valid and the product's "same text, same
/// verdict" promise intact.
///
/// Routing is intentionally conservative: a register must clear an absolute
/// signal floor AND beat the runner-up by a margin, otherwise the block goes
/// to `general` and only the general detector runs. A wrong expert is worse
/// than no expert.
///
/// Routed results are content-cached (same LRU pattern as `DetectionCache`)
/// so re-encounters cost a dictionary lookup, not a lexicon scan.
public final class DomainRouter: @unchecked Sendable {

    /// A register wins only with at least this much normalized signal…
    static let signalFloor = 0.18
    /// …and at least this much daylight over the second-best register.
    /// 0.10 prevents a tight race between two registers from activating a wrong
    /// expert — a wrong expert is worse than no expert.
    static let margin = 0.10
    /// Web-domain hints add a strong prior; content can still override a hint
    /// only by out-signaling it outright.
    static let hintBoost = 0.50

    public init() {}

    // MARK: - Web-domain hints (deterministic table, subdomain-matched)

    /// Suffix-matched like the trust list: "old.reddit.com" hits "reddit.com".
    static let hostHints: [(hosts: [String], domain: TextDomain)] = [
        (["reddit.com", "twitter.com", "x.com", "facebook.com", "instagram.com",
          "tiktok.com", "linkedin.com", "threads.net", "bsky.app", "mastodon.social",
          "tumblr.com", "pinterest.com"], .social),
        (["github.com", "gitlab.com", "stackoverflow.com", "stackexchange.com",
          "npmjs.com", "pypi.org", "developer.apple.com", "developer.mozilla.org",
          "readthedocs.io", "docs.rs", "kernel.org"], .technical),
        (["arxiv.org", "scholar.google.com", "pubmed.ncbi.nlm.nih.gov", "jstor.org",
          "springer.com", "sciencedirect.com", "nature.com", "ieee.org", "acm.org",
          "biorxiv.org", "ssrn.com"], .academic),
        (["reuters.com", "apnews.com", "bbc.com", "bbc.co.uk", "nytimes.com",
          "theguardian.com", "washingtonpost.com", "cnn.com", "bloomberg.com",
          "ft.com", "wsj.com", "npr.org", "aljazeera.com"], .news),
        (["discord.com", "forum.", "community.", "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "poe.com", "perplexity.ai"], .conversation),
        (["archiveofourown.org", "wattpad.com", "fanfiction.net", "royalroad.com"],
         .creative),
    ]

    static func hint(for webDomain: String?) -> TextDomain? {
        guard let normalized = DomainTrustManager.normalize(webDomain ?? "") else { return nil }
        for (hosts, domain) in hostHints {
            for host in hosts {
                if host.hasSuffix(".") {   // prefix-style hint ("forum.")
                    if normalized.hasPrefix(host) || normalized.contains("." + host) { return domain }
                } else if normalized == host || normalized.hasSuffix("." + host) {
                    return domain
                }
            }
        }
        return nil
    }

    // MARK: - Register lexicons
    //
    // Matching rule (see `matches`): entries containing a space or
    // punctuation are literal substring searches ("et al", "error:",
    // "\" she"); single-word entries match whole TOKENS only — "ngl" must
    // never fire inside "accordingly", "doi" inside "doing", "hello" inside
    // "othello". Token matching is what keeps the router honest on prose.

    /// Candidate registers in canonical order. Ties break toward the earlier
    /// entry, so the order is part of the deterministic contract.
    static let candidates: [TextDomain] = [
        .conversation, .academic, .news, .social, .marketing, .technical, .creative,
    ]

    static let lexicons: [TextDomain: [String]] = [
        .conversation: [
            "thanks", "thank you", "you're", "you are", "let me know", "i think",
            "i'm not sure", "sounds good", "hi", "hey", "hello", "sorry",
            "no problem", "got it", "makes sense", "btw", "fyi", "good question",
            "you could", "you can try", "hope this helps", "feel free",
            "sure,", "certainly,", "here is", "as an ai", "let's", "here are", "i can help",
        ],
        .academic: [
            "et al", "abstract", "introduction", "methodology", "hypothesis",
            "in this paper", "we propose", "we present", "the results", "findings",
            "statistically significant", "literature", "prior work", "experiments",
            "dataset", "baseline", "figure 1", "table 1", "doi", "citation",
            "peer-reviewed", "study", "studies", "researchers", "analysis",
        ],
        .news: [
            "according to", "said in a statement", "told reporters", "reported",
            "officials", "spokesperson", "(reuters)", "(ap)", "associated press",
            "on monday", "on tuesday", "on wednesday", "on thursday", "on friday",
            "on saturday", "on sunday", "sources said", "announced", "press briefing",
            "the government", "authorities", "investigation",
        ],
        .social: [
            "lol", "omg", "tbh", "imo", "imho", "ngl", "fr fr", "lmao", "smh",
            "retweet", "upvote", "downvote", "subreddit", "follow me", "dm me",
            "like and subscribe", "link in bio", "thread:", "edit:", "tl;dr",
            "hot take", "the op", "quote tweet",
        ],
        .marketing: [
            "buy now", "sign up", "free trial", "limited time", "% off", "discount",
            "best-in-class", "boost your", "supercharge", "pricing", "get started",
            "no credit card", "join thousands", "trusted by", "money-back",
            "exclusive offer", "subscribe to our", "newsletter", "order now",
            "shop now", "upgrade today", "our customers", "testimonial",
            "book a demo", "request a quote",
        ],
        .technical: [
            "function", "const", "import", "install", "npm", "pip install",
            "api", "endpoint", "server", "database", "config", "error:", "exception",
            "stack trace", "compile", "runtime", "git", "repository", "documentation",
            "parameter", "return value", "deprecated", "the following code",
            "command line", "terminal", "debug", "null", "boolean",
        ],
        .creative: [
            " said.", "whispered", "stared", "grinned", "sighed", "shrugged",
            "\" she", "\" he", "” she", "” he", "chapter", "once upon",
            "the door", "her eyes", "his eyes", "she felt", "he felt", "she knew",
            "he knew", "the night", "silence", "breath",
        ],
    ]

    /// True when the entry should be searched as a literal substring (it
    /// carries its own boundaries) rather than matched as a whole token.
    static func isPhrase(_ entry: String) -> Bool {
        entry.contains(" ") || entry.contains(":") || entry.contains(";")
            || entry.contains(".") || entry.contains("\"") || entry.contains("”")
            || entry.contains("(") || entry.contains("%")
    }

    /// Structural counters that lexicons can't express, normalized per 100
    /// words and folded into the same 0...1 signal scale.
    private static func structuralSignal(domain: TextDomain, sample: NSString, words: Int) -> Double {
        let per100 = 100.0 / Double(max(1, words))
        func density(of characters: [unichar]) -> Double {
            var count = 0
            for i in 0..<sample.length where characters.contains(sample.character(at: i)) {
                count += 1
            }
            return Double(count) * per100
        }
        switch domain {
        case .social:
            // Hashtags and mentions are near-definitive for social text.
            return clamp(density(of: [35, 64]) / 2.0, 0, 1)            // '#', '@'
        case .technical:
            // Braces and backticks barely occur in prose. Semicolons are
            // deliberately NOT counted — 19th-century literary prose is
            // semicolon-rich and must not read as code.
            return clamp(density(of: [123, 125, 96]) / 3.0, 0, 1)      // '{','}','`'
        case .conversation:
            return clamp(density(of: [63]) / 3.0, 0, 1)                // '?'
        case .creative:
            // Dialogue quotes ("straight" + “curly”).
            return clamp(density(of: [34, 0x201C, 0x201D]) / 5.0, 0, 1)
        default:
            return 0
        }
    }

    // MARK: - Routing

    public func route(text: String, webDomain: String? = nil) -> RoutingDecision {
        let key = TextMetrics.cacheKey(text, detectorID: "route:\(Self.hint(for: webDomain)?.rawValue ?? "-")")
        if let cached = cached(key) { return cached }

        let decision = Self.classify(text: text, webDomain: webDomain)
        insert(decision, for: key)
        return decision
    }

    /// The pure classification rule, cache-free (tests call this directly).
    static func classify(text: String, webDomain: String? = nil) -> RoutingDecision {
        let sample = String(text.prefix(6000)).lowercased()
        let words = TextMetrics.wordCount(sample)
        guard words >= 20 else { return .general }

        let haystack = sample as NSString
        let hinted = hint(for: webDomain)

        // One tokenization for every token-matched lexicon entry — the same
        // edge-trimming the heuristic engine uses, so "lol." and "(lol)"
        // count but "trolley" never does.
        var tokens = Set<String>()
        for raw in sample.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            var s = raw
            while let f = s.first, !f.isLetter, !f.isNumber { s = s.dropFirst() }
            while let l = s.last, !l.isLetter, !l.isNumber { s = s.dropLast() }
            if !s.isEmpty { tokens.insert(String(s)) }
        }

        var scores: [(domain: TextDomain, score: Double)] = []
        scores.reserveCapacity(candidates.count)
        let per100 = 100.0 / Double(words)

        for domain in candidates {
            var hits = 0
            for entry in lexicons[domain] ?? [] {
                if isPhrase(entry) {
                    if haystack.range(of: entry, options: .literal).location != NSNotFound { hits += 1 }
                } else if tokens.contains(entry) {
                    hits += 1
                }
            }
            // 2.5 lexicon hits per 100 words ≈ full signal; structure tops up.
            var score = clamp(Double(hits) * per100 / 2.5, 0, 1)
            score = min(1.0, score + 0.5 * structuralSignal(domain: domain, sample: haystack, words: words))
            if domain == hinted { score += hintBoost }
            scores.append((domain, score))
        }

        // Deterministic argmax: strict greater-than keeps the canonical-order
        // earlier register on ties.
        var best = scores[0]
        var second = 0.0
        for entry in scores.dropFirst() {
            if entry.score > best.score {
                second = best.score
                best = entry
            } else if entry.score > second {
                second = entry.score
            }
        }

        guard best.score >= signalFloor, best.score - second >= margin else {
            return RoutingDecision(domain: .general, confidence: clamp(1 - best.score, 0, 1))
        }
        return RoutingDecision(domain: best.domain,
                               confidence: clamp(best.score - second, 0, 1))
    }

    // MARK: - Route cache (same shape as DetectionCache, decision-sized)

    private let lock = NSLock()
    private var store: [String: RoutingDecision] = [:]
    private var order: [String] = []
    private static let capacity = 1024

    private func cached(_ key: String) -> RoutingDecision? {
        lock.lock(); defer { lock.unlock() }
        let value = store[key]
        return value
    }

    private func insert(_ decision: RoutingDecision, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if store[key] == nil, store.count >= Self.capacity, let oldest = order.first {
            store.removeValue(forKey: oldest)
            order.removeFirst()
        }
        if store[key] == nil { order.append(key) }
        store[key] = decision
    }
}
