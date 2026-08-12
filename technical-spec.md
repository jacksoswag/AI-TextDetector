# Pilcrow technical specification

Pilcrow is a macOS menu-bar app that reads the text on screen, scores how AI-generated each block looks, and outlines the ones it is confident about. Everything runs on-device through Core ML.

This is the surface-level account. The code is the specification, and where the two disagree the code is right.

## Design invariants

- **Abstain beats guess.** A block that clears the user's threshold but scores under 0.80 is reported `unknown` and never painted. Missing AI text is a smaller error than accusing a person.
- **Annotate, never obstruct.** Highlights are click-through. Nothing is blurred, blocked, or hidden.
- **Deterministic.** Verdicts are pure functions of the text and are cached by content hash, so the same block always scores the same and never flickers on rescan.
- **No network, ever.** Inference is local, no servers run, no ports open.
- **Event-driven.** There is no per-frame work. Scans fire on accessibility and window events, coalesced into one pass per 250 ms.

## The pipeline

```
acquisition → Stage-1 (every block) → Stage-2 (borderline only) → smoothing → hysteresis → confidence gate
```

| Stage | What | Measured |
|---|---|---|
| 1 | Fine-tuned e5-small/MiniLM encoder, 33M params, FP16, sequence length 256. Screens every scoreable block | 4.0 ms single, 5.7 ms/block batched |
| 2 | Fine-tuned ModernBERT-large, ~396M params, FP16, pinned to the Neural Engine. Re-scores only blocks whose Stage-1 score lands in `[0.40, 0.93]` and run at least 120 words | ~144 ms/block |
| 3 | Verdict assembly. No ML: smoothing, hysteresis, then the confidence gate | ~0 |

Stage-2 exists because the small screening model misreads register-shifted prose (formal, encyclopedic, minutes-style) as AI. It is skipped for short blocks, which it over-flags, and each unique text escalates at most once.

The final score is the model probability. There is no stylometric fusion, no expert blend, and no provenance boost; the only calibration is the model's own Platt scaling from `model-info.json`. Earlier drafts had all of that and none of it ships.

## Three gates before anything paints

1. **Temporal smoothing.** A content-keyed exponential moving average, α = 0.35, so a settling block cannot flicker.
2. **Threshold hysteresis.** Enter at the user threshold, exit 12% below it. Inside the dead band a block keeps its remembered decision.
3. **Confidence and abstain.** Paint only when the smoothed score is at least 0.80 and dispersion is under 0.90. Stage-2 verdicts are held to the same floor rather than trusted outright.

Trusted domains, messaging surfaces, and blocks under the minimum length never reach the model at all.

## Text acquisition

| Tier | Source | Notes |
|---|---|---|
| 1 | Browsers, via Accessibility | Safari exposes content directly; Chromium needs `AXEnhancedUserInterface` set first. Fragments are clustered into paragraphs by geometry |
| 2 | Native apps, via Accessibility | Same walk, smaller budget. Electron apps need `AXManualAccessibility` |
| 3 | OCR, ScreenCaptureKit and Vision | Fires only when an Accessibility scan returns nothing scoreable, so canvas surfaces are still covered. At most one pass per app per 20 seconds |

A 5 Hz cull pass re-reads one anchor per active highlight and invalidates on drift. That is the backstop for text that moves without emitting any event, and it runs only while highlights exist.

## Layout

| Path | Holds |
|---|---|
| `FilterCore/` | Swift package, UI-free: detection, tokenizers, pets, settings, trust, privacy |
| `App/` | Menu-bar app: AX walk, OCR fallback, overlay panels, pet coordinator |
| `Models/` | Converted Core ML artifacts and their `model-info.json` |
| `Assets/Pets/` | Built-in pet definitions as JSON |
| `scripts/` | Bootstrap, install, model conversion, LoRA fine-tune, calibration |

## Tests

```bash
cd FilterCore && swift test
```

46 tests over the state bands, threshold clamping, trust tiers, cache eviction, block clustering, the escalation gate, the deferred Stage-2 refine path, and tokenizer encoding checked bit-exact against stored vectors. When `Models/` is present, integration tests load the real models and check class separation and latency.

The live AX walk, highlight placement, and pet motion are not covered and need a manual pass.

## Limits

- A 33M screening model has weak recall on paraphrased or heavily edited AI text. Calibrate before trusting any specific threshold.
- Firefox exposes web content to Accessibility only partially.
- Setting `AXEnhancedUserInterface` is the same switch screen readers use, and some window managers interact poorly with it.
- The output is an estimate, not proof of authorship.
