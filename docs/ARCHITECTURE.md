# Pilcrow

A menu bar app for macOS that watches on-screen text, scores how AI-generated it looks, and annotates the suspicious parts: a colored outline and glow around the block, plus a small pixel-art pet that appears beside each flagged block and comments on it. Everything runs on-device. No cloud, no accounts, no telemetry, and no local servers or open ports; nothing the detector reads ever leaves the Mac. (License purchase is handled separately by an external payment processor — see Privacy.)

Nothing is ever hidden. The app never blurs, blocks, or obstructs content; it highlights and it talks. Scoring is probabilistic and the product treats it that way: a small general classifier screens everything, a stronger Stage-2 model arbitrates the uncertain middle, and a minimum-length gate, a confidence/abstain gate, and a user threshold keep false positives down. When the pipeline can't be confident it says `unknown` and flags nothing — unknown is always preferred over a false positive.

## Design principles

- **Calm by default.** The menu shows nothing when healthy. Exactly two conditions surface: "Watching N AI-likely blocks here" while highlights are active, and a single fix-it row when a permission is missing. Telemetry lives in `os_log` (`subsystem dev.aicf`), never in the UI.
- **Annotate, never obstruct.** Highlights are click-through outlines with a faint 10 to 15 percent dim; scrolls and clicks pass straight through to the page. Each pet hugs a corner of its own flagged block and dodges if it would cover more than a quarter of it. The pet's small speech bubble is comment-only and click-through; clicking it fades it (the click still reaches the page below), and it auto-dismisses on a 6 second timer.
- **Nothing on screen unless something is flagged.** Pets are verdict markers, not desktop pets: one instance flies in per flagged block, leaves when its block does, and a clean page shows nothing at all.
- **Stability over immediacy.** Blocks are acted on only once their content is identical across consecutive scans, so streaming text never makes annotations flicker; settled text confirms within about a second. Verdicts are deterministic and cached, so the same text always looks the same.
- **Deterministic personality.** Each pet's reactions and speech are pure functions of (text block, pet, state). No randomness, no runtime LLM, no surprises on rescan.
- **Precision over recall.** The default threshold highlights only what the pipeline is confident about; uncertain blocks are never highlighted, and a score without confidence reports `unknown` instead of flagging. Missing some AI text is a smaller sin than flagging a human's writing.
- **Everything automatic.** No scan buttons, no modes. One master switch, permissions asked in context exactly once, OCR fills Accessibility's gaps on its own. The Stage-2 model loads itself the first time a block needs escalating; until then only the small screening model is resident.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon (the app bundles ~820 MB of models: 64 MB fast screen + 757 MB stage-2)
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

Quickest path (build and run from Xcode):

1. `./scripts/bootstrap.sh` (runs `xcodegen generate` and opens the project)
2. Run the `AIContentFilter` scheme. The text-scan icon appears in the menu bar; there's no Dock icon and no window. No signing team, app group, or entitlements are needed for a local run.
3. Grant the Accessibility permission when the app asks (it asks on first run; scanning is on by default). That single permission covers browsers and native apps alike; the Screen Recording prompt appears later only if the OCR fallback ever fires.

Stable install (recommended, so permission grants survive rebuilds):

macOS ties Accessibility and Screen Recording grants to both the app's code signature and its location, so running repeatedly from DerivedData churns the grants. The project is configured for a stable self-signed identity (`AICF Local Dev Signing`, set in `project.yml`) plus a fixed install path:

1. `./scripts/make-signing-cert.sh` — creates the self-signed identity in your login keychain (run once).
2. `./scripts/install.sh` — builds Release, installs to `/Applications/AIContentFilter.app`, signs in place with that identity, and launches it. From then on a grant, once given, persists across rebuilds.

## Text acquisition

Everything is automatic; there are no manual scan actions anywhere in the product.

| Tier | Source | Notes |
|---|---|---|
| 1 | Browsers via Accessibility | Safari exposes web content unconditionally; Chromium (Chrome, Edge, Brave, Arc, Vivaldi, Opera) builds its web AX tree after the app sets `AXEnhancedUserInterface`, with a one-shot retry while the tree warms up. Text fragments are clustered into paragraph blocks by geometry, and the page URL from `AXWebArea` supplies the real domain, so Trusted Sites and per-domain learning work on actual hostnames |
| 2 | Native apps via Accessibility | Same walk with a smaller budget; `AXStaticText` is usually already paragraph-grained. Electron apps (Claude, Slack, VS Code) are coaxed with `AXManualAccessibility` |
| 3 | OCR (ScreenCaptureKit + Vision) | Event-gated fallback that fires when an Accessibility scan of the frontmost app comes back without any scoreable text — zero blocks OR nothing at the user's minimum length, so canvas surfaces (Google Docs, PDF viewers, design tools) whose AX tree only carries toolbar chrome still get covered. OCR text keeps the triggering app's identity (so trusted-app and personal-surface decisions still apply to AI-chat desktop apps) and acts on first sight — the streaming stability gate exempts OCR because its 20 s cooldown makes two identical noisy reads impossible. Never concurrent, at most one pass per app per 20 seconds. Screen Recording permission is preflighted silently; the system prompt appears once, the first time OCR is actually needed, and a quiet fix-it row in the menu covers the declined case. Captures are processed in memory and never leave the Mac |

The update loop is event-driven with no per-frame work. These are the triggers, and bursts coalesce into one scan per 250 ms batch window:

- **App activation.** Scan once the switch settles, reattach the app's AX observers, re-pin highlight z-order.
- **Text changed.** After every scan the service subscribes `AXValueChanged` on up to 40 of the scanned blocks' own AX elements, so streaming chat replies and live feeds push their next change to us.
- **Structure changed.** Focused-window, main-window, window-created, focused-element, and title notifications (a browser retitles its window on tab switches and navigation, which is the domain-changed signal).
- **Window moved, resized, minimized, or destroyed.** The affected layer clears immediately and re-places against fresh geometry.
- **Scroll stopped.** A settle scan fires 250 ms after the last wheel event; during the burst, highlights ride their AX anchors live.
- **Wake from sleep.**

The one exception to "events only" is a low-rate safety net: a 5 Hz `cullTimer` in `OverlayManager.cullPass` re-reads one representative anchor per active highlight layer and invalidates plus rescans when the anchor disappears or drifts more than a few points. This is the backstop for text that moves or vanishes *without* emitting an AX, scroll, or activation event (canvas/Metal apps, async-AX surfaces like Google Docs, and tab switches that retitle the window but keep the old elements alive). It only runs while highlights exist. A canvas app that silently repaints brand-new content with no event at all still won't re-trigger OCR until something fires.

## The model layer

The pipeline order is fixed: acquisition → Core ML Stage-1 (general detector, every scoreable block) → Stage-2 cascade (only the blocks the escalation gate selects) → temporal smoothing → threshold hysteresis → confidence/abstain gate. There is no routing, heuristic, or calibration stage between acquisition and the model — those were removed in the 2026-06-22 audit pass. The model-conversion numbers below (size, parity, per-window latency) are recorded in each model's `model-info.json` from the Apple Silicon conversion run.

| Stage | What | Budget | Measured |
|---|---|---|---|
| 1. Core ML general detector | **Always runs.** A fine-tuned e5-small/MiniLM-family encoder (33M params, MIT base) trained on a deconfounded matched-pair corpus, FP16 ML Program at sequence length 256. Screens every scoreable block | <10 ms screen | 4.0 ms single, 5.7 ms/block batched (fast screen) |
| 2. Core ML Stage-2 escalation | **Conditional.** A fine-tuned ModernBERT-large (~396M params, Apache-2.0 base `answerdotai/ModernBERT-large` — see THIRD-PARTY-NOTICES.md) at sequence length 512, FP16 on the **Neural Engine** (757 MB, parity 0.0002 vs PyTorch), taking over the fast model's ambiguous middle for blocks whose Stage-1 score lands in the `[0.40, 0.93]` band (OR with high cross-window dispersion) and that run at least 120 words (the Stage-2 model over-flags short text, so short blocks are never escalated); confident fast verdicts never pay its latency, each unique text escalates at most once (cached), and borderline blocks refine one at a time so each highlight streams in within ~144 ms | — | ~144 ms/window |
| 3. Verdict assembly | Rule-based, no ML, in `DetectionEngine.makeVerdict`: content-keyed exponential smoothing against jitter (`TemporalStabilizer`), threshold hysteresis, and the confidence/abstain gate. `pFinal = pBase` — the only probability calibration is the model's own Platt scaling inside `CoreMLClassifier.calibrated()`, applied when `model-info.json` carries fitted values | ~0 | ~0 |

Each classifier is compiled to `.mlmodelc`; compute units come from its `model-info.json` (`compute_units`). The general detector uses `.all` (Neural Engine first, then GPU, then CPU); Stage-2 declares `cpu_and_ne` and is pinned to the Neural Engine (its `.all` path otherwise leaks work onto the slower GPU). The scoring head is deterministic: softmax over the encoder's logits plus optional Platt scaling from `model-info.json`. Inference is batched (one Core ML batch per detector per evaluation pass) and scores are cached by content hash so re-encounters skip inference. There is no Python anywhere in the runtime.

### The score and the decision

The shipped scoring is deliberately thin. Stage-1 returns a calibrated AI probability for every block; for the borderline blocks the gate escalates, Stage-2's probability replaces it. That probability *is* the final score — `pFinal = pBase`. There is no stylometric fusion, no expert blend, and no provenance boost; the only probability calibration is the model's own Platt scaling, applied inside `CoreMLClassifier.calibrated()` when `model-info.json` carries fitted `temperature`/`bias` values (identity otherwise). From there each block passes three deterministic, no-ML steps in `DetectionEngine.makeVerdict` before it can paint:

1. **Temporal smoothing.** `TemporalStabilizer` keeps a content-keyed exponential moving average (α = 0.35) so a settling block's score can't flicker scan to scan.
2. **Threshold hysteresis.** Enter at the user threshold, exit 12% below it; inside that dead band a block keeps its remembered decision instead of recomputing a midpoint. This decides only whether the smoothed score *clears the bar*.
3. **Confidence/abstain gate.** Clearing the bar is necessary but not sufficient. A block paints only when its smoothed score is *decisively* AI (≥ 0.80) and not wildly dispersed (uncertainty < 0.90). A score that clears the user threshold but lands under 0.80 — the band where the small Stage-1 model reads formal human prose as AI — is left `unknown` and never highlighted. Stage-2 verdicts are held to that same 0.80 floor, not trusted unconditionally. `unknown` is always preferred over a false positive. (`FinalDetectionResult.invertedConfidence` is recorded for telemetry only and is inverted by construction — highest at p = 0.5 — so the gate uses the explicit `≥ 0.80` test, never that field.)

> **Design vs shipped.** Earlier drafts of this engine routed each block to a per-register expert, fused it with the general detector (`0.70·expert + 0.30·general`), adjusted the result with stylometric features and a damping term, and boosted scores from AI-chat provenance markers. None of that ships. The 2026-06-22 audit pass removed the dead and inert scaffolding behind it — the domain router, the engine-level calibration layer, the heuristic feature struct, the provenance booster, and the per-domain temperature shift — so the general → Stage-2 cascade plus the three gates above is the entire decision. Per-register experts and the Correct/Wrong/Ignore feedback loop remain design intent only (see Feedback below).

Trusted domains never reach the model at all: `isTrusted` returns every block as skipped before scoring. Mail and messaging surfaces are suppressed the same way by the `personalSurface` skip, and blocks under your minimum-length setting (`settings.minWords`, default 30) are never scored. Shorter blocks that *are* scored are never escalated to the length-sensitive Stage-2 model and are highlighted only when the fast model is already decisively confident (the confidence gate above).

The final score maps onto five states, which drive the highlight styling and the pets:

| Final score | State | Highlight | Pet |
|---|---|---|---|
| 0.00–0.30 | safe | none | none |
| 0.30–0.60 | uncertain | none, by design | none |
| 0.60–0.80 | suspicious | yellow outline + glow, 10% dim | appears at the block, comments |
| 0.80–0.95 | high | orange outline + glow, 12% dim | alert posture |
| 0.95–1.00 | very_high | red outline + glow, 15% dim | alert posture |

The state is a pure function of the final score, but it only describes the styling a block *would* get; the confidence gate sits on top and decides whether it paints at all. The gate is stage-independent — any score ≥ 0.80 (`high` or `very_high`) that clears the user threshold paints, whether Stage-1 or Stage-2 produced it. A score that clears the threshold but sits under the 0.80 floor is left `unknown`, so the `suspicious` band (0.60–0.80) never highlights under the shipped floor even though it has a tint defined. Trusted and personal surfaces never reach this table at all. The per-register feedback shift that would nudge these bands is design intent, not wired (see Feedback below).

### Feedback (planned, not yet wired)

The design calls for each pet bubble to carry three buttons — **✓ Correct** (this really is AI text), **✗ Wrong** (this is human, flag less like this), **Ignore** — feeding saturating per-domain and per-register counters that a calibration layer would consume to shift decision thresholds, with no text ever stored and no model ever retrained on-device. None of this ships today: the speech bubble is comment-only and click-through (`SpeechBubblePanel`), there is no feedback store, and the engine-level calibration layer that would consume such counters was removed in the audit pass. The local data that does persist (settings, trusted domains, usage counters, custom pets) is wiped by "Erase All Local Data". **No model is ever retrained or modified on-device.**

### Calibration notes, honestly

Reference scores (default threshold 0.85, Stage-2 cascade active). Each `score` is the final calibrated model probability the engine acts on:

| Sample | score | state | label | highlighted |
|---|---|---|---|---|
| Lexicon-stuffed AI essay | 0.96 | very_high | ai | **yes** |
| Neutral encyclopedic AI text | 1.00 | very_high | ai | **yes** |
| LLM imitating casual prose | 0.06 | safe | human | no |
| LLM imitating formal minutes | 0.36 | uncertain | human | no (below the escalation band; Stage-1 only) |
| Twain, 1883 (genuinely human) | 0.004 | safe | human | no (Stage-2 verdict) |

The Stage-2 cascade exists to drain the ambiguous middle. The small 33M screening model is weakest on register-shifted text — formal, encyclopedic, or minutes-style prose it can misread as AI — so any block whose Stage-1 score lands in `[0.40, 0.93]` (and runs ≥120 words) is re-scored by the ModernBERT-large model, and that verdict wins. Register-shifted AI text reaches very_high on the model score alone, genuinely human formal prose drops back toward safe, and the LLM-disguised samples resolve to whichever side the stronger model calls. The cost is ~144 ms on the Neural Engine per unique borderline block, off the hot path; the screening path is unchanged at ~4 ms.

Independent studies put open-source detector false-positive rates far above vendor claims. Treat every score as an indicator; the wrapper (threshold, confidence gate, length gate, trust list, personal-surface suppression) exists because the score alone can't be trusted. The Stage-2 cascade exists for the same reason: the general 33M model is weakest on register-shifted text, and the ModernBERT-large escalation catches what the screening model can't.

## The pet

A 96-pixel verdict marker in a small floating window — one **instance per flagged block**, up to 12 at once (highest scores win, deterministically). Pets exist only while their block is flagged: they fly in beside it when the highlight appears, hold its corner while you scroll, and fly out the moment the block clears or leaves the screen. Nothing is flagged → nothing is on screen. There is no idle dock and no permanent companion; it's a pet for the detection, not a pet.

| Behavior | When | Looks like |
|---|---|---|
| fly in / fly out | block flagged / unflagged | one fixed 1.2 s transition at the block's corner |
| tracking | marking a suspicious block | corner-hugging, lean/squint animation |
| alert | marking a high or very_high block | persistent alert animation |
| comment | its block's state was first seen or changed | one speech bubble with a one-line comment |

The pet panel itself never intercepts clicks or scrolls and never covers the text it marks (it dodges if the corner anchor would overlap more than a quarter of the block). The speech bubble is comment-only and click-through: it parks its dismiss timer while the pointer is over it and dismisses itself 6 seconds after it last mattered; a click fades it (the click still reaches the page below). An escalating dismissal is the only pet interaction today — one click soft-dismisses the comment (it returns on the next state change), a second click hard-dismisses it. The Correct/Wrong/Ignore feedback buttons are planned, not wired (see Feedback above).

Movement is interpolated by Core Animation (one 0.35 s glide per event), GIF playback is driven by AppKit, and the only high-frequency code path in the app is the scroll tracker that rides highlights on their AX anchors at 30 Hz while you scroll — pets reposition on that same tick, self-terminating 0.45 s after the last wheel.

Speech is fully deterministic: `index = fnv1a(block_id + pet_id + state) % templates[state].count`. The same block, pet, and state always produce the same line, across launches. With Debug Mode on, each line carries the block's score and state.

### Built-in pets

| Pet | Personality | Voice |
|---|---|---|
| Mochi the blob | companion | soft, friendly, reassuring |
| Brill the cat | skeptical | dry, doubting, a little smug |

### Custom pets

Pet Library (in the menu) lists every pet with live animation previews and sets the active one. New Pet opens an editor with three sections: a name, per-state speech templates (one tab per detection state — safe, uncertain, suspicious, high, very_high), and asset wells for a required base PNG plus optional idle/track/alert/fly_in/fly_out GIFs. Built-ins are read-only; Duplicate & Edit copies one into an editable custom pet.

Pets are single JSON files with all assets embedded as base64, so import/export is one file with full round-trip fidelity:

```json
{
  "id": "builtin.companion",
  "name": "Mochi",
  "speech_templates": { "safe": ["…"], "uncertain": ["…"], "suspicious": ["…"], "high": ["…"], "very_high": ["…"] },
  "animation_profile": { "idle": "idle", "track": "track", "alert": "alert" },
  "assets": { "base_png": "<base64>", "gifs": { "idle": "…", "track": "…", "alert": "…", "fly_in": "…", "fly_out": "…" } }
}
```

Built-ins live in the app bundle (`Resources/Pets/`); custom and imported pets live in `~/Library/Application Support/AIContentFilter/Pets/`. The two built-in JSONs are generated by `scripts/generate-pets.py` (Pillow), which also writes inspectable frames to `Assets/PetPreviews/`. (Directory and type names keep the historical `Pet` spelling; the product surface says pet.)

## The menu

The menu bar icon is a text-scan glyph (`text.viewfinder`) — dimmed when the master switch is off.

- Master switch
- Pet Library (active-pet picker, plus New Pet / Duplicate & Edit / import / export, all inside the Library window)
- Detection Threshold slider (minimum final score that highlights, 0.30 to 0.95)
- Pet size slider (live: resizes every on-screen marker)
- Trusted Sites
- Statistics (words/blocks flagged)
- Privacy summary and "Erase All Local Data"
- Debug Mode toggle (scores in speech bubbles, verbose scan logging)
- Quit

Minimum text length (`settings.minWords`, default 30) is a stored setting with no slider in the current menu. Launch at login is registered automatically on first run from `/Applications` (no menu toggle).

## Performance and battery design

- Model scores are deterministic and cached by content hash (LRU, 1024 entries; the cache key carries which detector scored the text): scrolling and rescans cost a dictionary lookup, and identical text always scores identically.
- Classifier calls are batched: one Core ML batch per detector per evaluation pass, not one call per block.
- The Stage-2 model loads lazily — only the first time the escalation gate selects a block, never on a confident-only scan — and `DetectionEngine.preload()` can warm both models at launch to keep that cost off the first detection. On a machine that never reaches the escalation band the small screening model is the only one resident.
- Event-driven scans. Scans happen when an AX notification, scroll settle, app switch, or wake event says something changed; bursts coalesce into one scan per 250 ms window. The only periodic work is the 5 Hz anchor-drift cull, and it runs only while highlights are on screen.
- The pointer-follow ring and the scroll tracker install their event monitors only while highlights exist, and tear them down with the last panel.
- Highlights diff per block across rescans: panels reposition and restyle in place, so unchanged blocks cost nothing. Pets ride the same diff and the same 30 Hz scroll tick — no separate update path.
- Pet animation is decoded GIF playback plus one Core Animation glide per event. The app draws no frames of its own, and with nothing flagged there are no pet windows at all.

## Swapping and extending the models

`PrimaryClassifier` is the seam:

```swift
public protocol PrimaryClassifier: Sendable {
    var id: String { get }            // new weights => new id => cache invalidates
    var displayName: String { get }
    func score(texts: [String]) async throws -> [ClassifierOutput]
}
```

`DetectionEngine` takes any `PrimaryClassifier` for the general and Stage-2 slots. The bundled general detector is `CoreMLClassifier.loadDefault()`, which loads `AITextClassifier.mlmodelc` + `vocab.txt` + `model-info.json` from the app bundle, the repo's `Models/` directory, or `~/Library/Application Support/AIContentFilter/Models/` (Stage-2 loads from `Models/Stage2/` via `loadStage2()`). Without artifacts the engine reports every block as model-unavailable (no highlights) and says so in the menu.

Three upgrade hooks are wired:

- **Stage-2 cascade.** SHIPPED: `Models/Stage2/` carries an in-house ModernBERT-large fine-tune from the Apache-2.0 base `answerdotai/ModernBERT-large` (see THIRD-PARTY-NOTICES.md), converted by `scripts/convert-stage2-modernbert.py`. The general detector screens everything; only blocks whose Stage-1 score lands in the `[0.40, 0.93]` band (or with high cross-window dispersion) and that run ≥120 words escalate to Stage-2 via `DetectionEngine.evaluate(deferStage2:)` + `refine(...)`, and the Stage-2 verdict wins. Stage-2 uses a byte-level BPE tokenizer (`bpe-vocab.json` + `bpe-merges.json` + `BPETokenizer`, pinned to the HF reference by generated test vectors); swap in any stronger ModernBERT fine-tune with the same artifact layout.
- **Per-register experts.** PLANNED (never wired): training one detector per register and routing blocks to it remains a design idea. There is no router in the shipped engine — the general detector + Stage-2 cascade scores every block, and the routing scaffolding was removed in the 2026-06-22 audit pass.
- **Platt calibration.** Add `"calibration": {"temperature": T, "bias": B}` to `model-info.json` and every window probability is recalibrated in logit space. `scripts/calibrate.py` fits both values on your own labeled CSV.

Training your own weights end to end:

```
python3 scripts/finetune-lora.py --train train.csv --eval eval.csv --out out/ft
python3 scripts/convert-model.py out/ft/merged            # general detector → Models/
python3 scripts/calibrate.py --model out/ft/merged --data calib.csv

# Stage-2 (ModernBERT, runs on the Neural Engine):
python3 scripts/finetune-lora.py --base answerdotai/ModernBERT-large --seq 512 \
    --train train.csv --eval eval.csv --out out/stage2
python3 scripts/convert-stage2-modernbert.py out/stage2/merged   # → Models/Stage2/
```

CSV format is two columns, `text,label` (1 = AI, 0 = human). The data recipe for the hard registers is in [docs/TRAINING.md](docs/TRAINING.md).

## Project layout

```
ai-detector/
├── project.yml              XcodeGen definition (menu-bar app)
├── Models/                  Converted Core ML artifacts (fp16 + int8, vocab, info)
│   └── Stage2/              Bundled stage-2 cascade model (ModernBERT-large,
│                            bpe-vocab.json + bpe-merges.json + model-info + mlmodelc)
├── Assets/
│   ├── Pets/                Built-in pet JSONs (bundled into the app)
│   └── PetPreviews/         Raw frames for inspection (not bundled)
├── FilterCore/              Swift package: detection + pet logic, UI-free
│   └── Sources/FilterCore/
│       ├── Detection/       PersonalSurfaces, CoreMLClassifier +
│       │                    PrimaryClassifier (general + ModernBERT Stage-2,
│       │                    BPE/WordPiece tokenizers), TemporalStabilizer,
│       │                    DetectionCache, DetectionResult,
│       │                    DetectionEngine (cascade + smooth + hysteresis + gate)
│       ├── Pets/            PetDefinition (incl. state machine), PetRegistry,
│       │                    PetSpeechEngine
│       ├── Support/         WordPieceTokenizer, BPETokenizer, TextMetrics,
│       │                    BlockClustering
│       └── Settings/ Trust/ Stats/ Privacy/ Licensing/   (Feedback/ is an empty placeholder)
├── App/                     Menu bar app
│   ├── Acquisition/         AX walk, AX event observers, OCR fallback
│   ├── Overlay/             HighlightPanel, OverlayManager, pointer ring
│   ├── Pet/                 PetCoordinator (per-block instances), panels,
│   │                        Library + Editor windows
│   ├── Managers/            MenuBarManager (orchestration), BrowserIntegrationService
│   └── UI/                  Menu panel
├── scripts/                 bootstrap.sh, convert-model.py,
│                            convert-stage2-modernbert.py, generate-pets.py,
│                            finetune-lora.py, calibrate.py, …
└── Vendor/                  reserved (empty)
```

## Tests

```
cd FilterCore && swift test        # 46 tests
```

The suite covers the state-band boundaries, threshold defaults/clamping (and that the legacy threshold key is ignored), trust-score tiers and domain normalization, the detection cache's LRU eviction and cache-hit-skips-inference behavior, "Erase All Local Data" key removal, the privacy copy's no-blur/no-hide guarantee, the window/sampling logic, block clustering (column merges, paragraph separation, fragment drops), lone-spike damping, single-batch Stage-1 dispatch, fail-fast when Stage-1 is unavailable, the escalation gate (no escalation when confident, only borderline blocks escalate, too-short blocks preserve order), the deferred Stage-2 + `refine` path and its caching, stabilizer retention, pet speech-template keys, and WordPiece/BPE encoding (the BPE tokenizer is checked bit-exact against `tokenizer-test-vectors.json`). When `Models/` is present, additional integration tests load the real general detector and Stage-2 ModernBERT to check class separation, buried-AI catch, and latency. The Stage-2 conversion numbers in this README come from each model's `model-info.json`.

## Privacy

- No outbound network. Model inference is Core ML on-device. The app runs no local servers and opens no network ports; nothing the detector reads ever leaves the Mac.
- Stored locally: settings, trusted domains, usage counters, and your custom pets. If a license is activated, the license key (which encodes the buyer name + email) sits in `UserDefaults`. Page text is processed in memory and never written to disk.
- The only probability calibration is the model's own Platt scaling, baked into `model-info.json` (optionally fitted offline via `scripts/calibrate.py`) and applied at scoring time; models are never retrained or modified on-device. (The Correct/Wrong/Ignore feedback loop described above is planned, not yet shipped, so no feedback counters are stored today.)
- "Erase All Local Data" wipes the stored data above, including custom pets. Built-in pets live in the app bundle and survive. The license key is intentionally preserved (`PrivacyManager.eraseAllLocalData`) so a reset never drops a paid key.

## Known limitations

- The general classifier is a 33M-parameter model; expect weak recall on paraphrased or edited AI text and on registers far from its training data. The Stage-2 cascade is the shipped mitigation; per-register experts are a planned further fix (train one on the register you care about). Calibrate before trusting any specific threshold.
- Highlights clear on window moves and reattach after a rescan; OCR highlights clear on scroll and re-place on settle.
- Firefox exposes web content to Accessibility only partially; coverage there is best-effort.
- Setting `AXEnhancedUserInterface` on Chromium is the same switch screen readers use; some window managers are known to interact poorly with it.
- `swift test` covers the model and pet layers; the live AX walk, highlight placement, and pet motion need a manual smoke test (grant Accessibility, open a long article, wait a few seconds).
