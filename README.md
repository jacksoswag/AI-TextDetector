# Veritas

On-device AI-text detection for macOS.

Veritas is a menu-bar app that watches the text on your screen and flags the
parts that look AI-generated. It runs entirely on your Mac: no cloud, no account,
no telemetry. When it is not confident, it says so and flags nothing, because a
wrong accusation is worse than a missed one.

## Screenshots

![Veritas highlighting a flagged paragraph in a browser](docs/assets/screenshot-overlay.png)
*A flagged block gets a colored outline; the pet comments only on hover.*

![The Veritas menu-bar menu](docs/assets/screenshot-menu.png)
*One master switch, a threshold slider, and a trusted-sites list. No scan button.*

> Screenshots are placeholders until the release build is captured. See
> `LAUNCH-CHECKLIST.md`.

## Why Veritas

- **Private by construction.** Everything runs on-device with Core ML. Your
  reading never leaves the Mac. No accounts, no tracking, no ads.
- **Honest about uncertainty.** Borderline text is reported as "unknown" and
  never highlighted. Veritas would rather miss some AI text than wrongly flag a
  human.
- **Works everywhere you read.** Browsers and native macOS apps, with no per-app
  setup, through the Accessibility API. An OCR fallback covers canvas surfaces
  like Google Docs.
- **Out of your way.** Highlights are click-through outlines with a faint dim.
  Nothing is blurred, blocked, or hidden. A clean page shows nothing at all.
- **One-time price.** $7.99, perpetual license for the current major version. No
  subscription.

## Features

**Detection**
- Two-stage on-device cascade: a fast 33M-parameter screener (~4 ms per block)
  handles everything; a 396M-parameter ModernBERT-large model gives a second
  opinion (~144 ms) only on borderline, long-enough blocks.
- A confidence gate that abstains ("unknown") rather than forcing a verdict.
- Calibration tuned to reduce false positives on formal and academic prose.
- A detection threshold slider (0.30 to 0.95, default 0.60).
- Deterministic, content-cached verdicts: the same text always scores the same
  and never flickers on rescan.

**Display**
- Colored highlight overlays (yellow, orange, red) by confidence.
- A pixel-art pet beside each flagged block, with a one-line comment on hover.
  Two built-in pets (Mochi and Brill), plus a custom pet editor that exports to
  JSON. You can also turn pets off entirely.
- Debug Mode shows each block's raw score.

**Coverage and control**
- Works across browsers and native apps via the Accessibility API.
- OCR fallback (ScreenCaptureKit + Vision) for canvas surfaces.
- A Domain Trust List to skip sites you trust entirely.
- An optional Chrome/Chromium companion extension for faster in-browser reads.
- "Erase All Local Data" wipes every local setting in one click.

## Privacy

Veritas collects nothing and sends nothing off your Mac. Both models run locally.
On-screen text is processed in memory and never written to disk or transmitted.
The only network surface is an optional loopback server on `127.0.0.1:31337` for
the browser extension; it is token-gated and never touches the internet. With the
extension off, there is no network surface at all. Full details are in
[PRIVACY.md](PRIVACY.md).

## How it works

Veritas reads a block of text, screens it with the fast Stage-1 model, and paints
a highlight only when the score is decisively AI and clears your threshold. If the
score lands in the uncertain middle and the block is long enough to matter, the
stronger Stage-2 model takes a second look. If neither stage is confident, the
block is left as "unknown" and nothing is drawn. The deeper architecture is
documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M-series)

## Install

1. Download Veritas from [DOWNLOAD_URL] and drag it to Applications.
2. Launch it from the menu bar and grant **Accessibility** once when asked.
3. Optionally grant **Screen Recording** if you want the OCR fallback for canvas
   surfaces like Google Docs.

## Pricing

A 7-day free trial, then $7.99 one time, for use on your own Macs. After buying,
paste your license key into the menu (Enter License) to unlock. Buy at
[CHECKOUT_URL].

## Browser extension

The optional companion extension (Chrome and Chromium browsers, Manifest V3)
reads the visible page text directly and hands it to the app over loopback,
skipping the short Accessibility warm-up. It never modifies or draws on the page.
The extension lives in [Extension/](Extension/).

## Limitations

- Recall is weaker on paraphrased or heavily human-edited AI text.
- OCR on canvas surfaces is best-effort and depends on what is on screen.
- Veritas estimates; it does not prove authorship. Treat a flag as a reason to
  look closer, never as conclusive evidence. Do not use a verdict as the sole
  basis for an academic-integrity, employment, or disciplinary decision.

## FAQ

**Is my text sent anywhere?** No. Both models run on your Mac. Nothing is
uploaded.

**Does it work in Google Docs?** Yes, through the OCR fallback (needs Screen
Recording) or the browser extension.

**Why didn't it flag something?** When the score is ambiguous, Veritas reports
"unknown" and flags nothing rather than guess.

**Can I use it to catch students?** It is not built for that. Veritas produces an
estimate, not proof, and should never be the sole basis for an accusation.

**Does it need internet?** No. Detection is fully local.

**What about false positives?** The pipeline is tuned to abstain on borderline
text precisely to avoid them, but no detector is perfect. Treat flags as signals.

## For developers

Build from source with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
scripts/make-signing-cert.sh   # once: a stable local signing identity
scripts/install.sh             # build, install to /Applications, launch
```

`scripts/release.sh` produces a signed, notarized DMG for distribution (see
[docs/RELEASE.md](docs/RELEASE.md)). The detection architecture is in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and the model-training pipeline is
in [docs/TRAINING.md](docs/TRAINING.md).

## License

Veritas is proprietary software. See [LICENSE](LICENSE) and [EULA.md](EULA.md).
It bundles third-party models under their own licenses; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
