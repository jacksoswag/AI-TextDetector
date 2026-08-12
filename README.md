# Pilcrow

On-device AI-text detection for macOS.

A menu-bar app that watches the text on your screen and outlines the parts that look AI-generated. It runs entirely on your Mac: no cloud, no account, no telemetry, no open ports. When it is not confident it says so and flags nothing, because a wrong accusation is worse than a missed one.

## What it does

- **Two-stage cascade.** A 33M-parameter screener reads every block in about 4 ms. A 396M-parameter ModernBERT-large model gives a second opinion, at about 144 ms, only on borderline blocks of at least 120 words.
- **Abstains instead of guessing.** Anything under a 0.80 confidence floor is reported `unknown` and never highlighted, even when it clears your threshold.
- **Reads everywhere.** Browsers and native apps through the Accessibility API, with an OCR fallback for canvas surfaces like Google Docs.
- **Stays out of the way.** A thin colored bracket on the left edge of a flagged block, click-through, nothing dimmed or hidden. A clean page shows nothing at all.
- **A pet per flagged block.** A pixel-art character beside each flag with a one-line comment on hover. Two are built in, the editor makes more, and a "None" option reports a bare percentage instead.
- **Trusted Sites** to skip domains entirely, a threshold slider from 0.30 to 0.95, and a Check Text panel for pasting a passage on demand.

## Privacy

Nothing leaves the Mac. Both models run locally, on-screen text is processed in memory and never written to disk, and the app runs no local servers and opens no network ports. Stored locally: settings, trusted domains, usage counters, and custom pets. "Erase All Local Data" wipes all of it.

## How it works

A block is screened by the fast model and painted only when the score is decisively AI and clears your threshold. If it lands in the uncertain middle and is long enough to matter, the stronger model takes a second look. If neither is confident, nothing is drawn.

[technical-spec.md](technical-spec.md) has the pipeline, the gates, and the measured numbers.

## Requirements

macOS 14 or later, Apple Silicon. The app bundles about 820 MB of models.

## Build

Needs [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
scripts/make-signing-cert.sh   # once: a stable local signing identity
scripts/install.sh             # build, install to /Applications, launch
```

macOS ties Accessibility grants to both the code signature and the install path, so running repeatedly from DerivedData churns the permission. The stable identity plus the fixed install path is what makes a grant survive rebuilds.

`scripts/bootstrap.sh` regenerates the Xcode project and opens it for an in-Xcode run.

```sh
cd FilterCore && swift test
```

## Limitations

- Recall is weaker on paraphrased or heavily human-edited AI text.
- OCR on canvas surfaces is best-effort and depends on what is on screen.
- Firefox exposes web content to Accessibility only partially.
- It estimates, it does not prove authorship. Treat a flag as a reason to look closer, never as conclusive evidence, and never as the sole basis for an academic-integrity, employment, or disciplinary decision.

## License

See [LICENSE](LICENSE). Bundled third-party models carry their own licenses, listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
