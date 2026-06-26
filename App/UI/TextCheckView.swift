import SwiftUI
import FilterCore

/// The manual check window: paste any text, get a human-vs-AI verdict with a
/// confidence percentage. Deliberately spare — one input, one button, one
/// verdict — and deliberately ungated (see `DetectionEngine.analyze`), because
/// here the user asked for a call and always gets one. The active pet reacts
/// beside the result so it appears without taking the surface over.
struct TextCheckView: View {
    let engine: DetectionEngine
    @ObservedObject var registry: PetRegistry

    @State private var text = ""
    @State private var verdict: CheckVerdict?
    @State private var blocks: [AIBlockScore]?
    @State private var analyzedText = ""
    @State private var hoveredBlock: Double?
    @State private var analyzing = false
    @State private var modelUnavailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeatTextEditor(text: $text, blocks: blocks, analyzedText: analyzedText,
                           onHoverBlock: { hoveredBlock = $0 })
                .frame(minHeight: 200)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste or type text to check…")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { verdict = nil; blocks = nil; hoveredBlock = nil; modelUnavailable = false }

            HStack {
                Text("\(TextMetrics.wordCount(text)) words")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer()
                if let hoveredBlock {
                    Text("Block: \(Int((hoveredBlock * 100).rounded()))% AI")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(hoveredBlock >= 0.5 ? Color.orange : Color.green)
                }
                Button(action: check) {
                    if analyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || analyzing)
            }

            if modelUnavailable {
                Label("Detection model isn't installed — can't check text.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let verdict {
                Divider()
                ResultRow(verdict: verdict, pet: registry.activePet ?? PetRegistry.nonePet)
            }
        }
        .padding(16)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    private func check() {
        let snapshot = text
        analyzing = true
        verdict = nil
        blocks = nil
        hoveredBlock = nil
        modelUnavailable = false
        Task {
            // Score paragraph blocks once; the headline is their length-weighted
            // mean, so it can't land outside the blocks. analyze() is only a
            // fallback for text too short to yield a scorable block.
            let heat = await engine.scoreBlocks(text: snapshot)
            let p: Double?
            if let heat, let documentScore = AIBlockScore.documentScore(heat) {
                p = documentScore
            } else {
                p = await engine.analyze(text: snapshot)   // short text with no scorable block
            }
            await MainActor.run {
                analyzing = false
                guard let p else { modelUnavailable = true; return }
                let pet = registry.activePet ?? PetRegistry.nonePet
                // The "none" pet's line is just the AI percentage, already shown in
                // the verdict row above — skip it so it isn't printed twice.
                let line: String? = pet.id == "none"
                    ? nil
                    : PetSpeechEngine.line(
                        blockID: String(PetSpeechEngine.stableHash(snapshot)),
                        petID: pet.id,
                        stateKey: DetectionState(score: p).rawValue,
                        templates: pet.speechTemplates)
                verdict = CheckVerdict(aiProbability: p, petLine: line)
                analyzedText = snapshot
                blocks = heat
            }
        }
    }
}

/// One resolved verdict. `aiProbability` is the raw 0...1 model output; the
/// human-facing label and certainty are framed around whichever side wins, so
/// "human" and "AI" both read as a positive call rather than a probability.
private struct CheckVerdict {
    let aiProbability: Double
    let petLine: String?

    var isAI: Bool { aiProbability >= 0.5 }
    var certainty: Int { Int(((isAI ? aiProbability : 1 - aiProbability) * 100).rounded()) }
    var label: String { isAI ? "Likely AI-generated" : "Likely human-written" }
    var tint: Color { isAI ? .orange : .green }
}

private struct ResultRow: View {
    let verdict: CheckVerdict
    let pet: PetDefinition

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // "none" carries a 1×1 transparent placeholder — skip it so an absent
            // pet stays truly absent rather than a blank square.
            if pet.id != "none",
               let data = pet.assets.basePNGData(), let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(verdict.label)
                        .font(.headline)
                        .foregroundStyle(verdict.tint)
                    Spacer()
                    Text("\(verdict.certainty)%")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(verdict.tint)
                }
                ProgressView(value: Double(verdict.certainty), total: 100)
                    .tint(verdict.tint)
                if let line = verdict.petLine {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
