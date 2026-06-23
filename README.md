# Pilcrow

On-device AI-text detection for macOS.

Pilcrow is a menu-bar app that watches the text on your screen and flags the
parts that look AI-generated. It runs entirely on your Mac: no cloud, no account,
no telemetry. When it is not confident, it says so and flags nothing, because a
wrong accusation is worse than a missed one.

## Screenshots

![Pilcrow highlighting a flagged paragraph in a browser](docs/assets/screenshot-overlay.png)
*A flagged block gets a colored outline; the pet comments only on hover.*

![The Pilcrow menu-bar menu](docs/assets/screenshot-menu.png)
*One master switch, a threshold slider, and a trusted-sites list. No scan button.*

> Screenshots are placeholders until the release build is captured. See
> `LAUNCH-CHECKLIST.md`.

## Why Pilcrow

- **Private by construction.** Everything runs on-device with Core ML. Your
  reading never leaves the Mac. No accounts, no tracking, no ads.
- **Honest about uncertainty.** Borderline text is reported as "unknown" and
  never highlighted. Pilcrow would rather miss some AI text than wrongly flag a
  human.
- **Works everywhere you read.** Browsers and native macOS apps, with no per-app
  setup, through the Accessibility API. An OCR fallback covers canvas surfaces
  like Google Docs.
- **Out of your way.** Highlights are click-through outlines with a faint dim.
  Nothing is blurred, blocked, or hidden. A clean page shows nothing at all.
- **One-time price.** $4.99, perpetual license for the current major version. No
  subscription.

## Features

**Detection**
- Two-stage on-device cascade: a fast 33M-parameter screener (~4 ms per block)
  handles everything; a 396M-parameter ModernBERT-large model gives a second
  opinion (~144 ms) only on borderline, long-enough blocks.
- A confidence gate that abstains ("unknown") rather than forcing a verdict.
- Calibration tuned to reduce false positives on formal and academic prose.
- A detection threshold slider (0.30 to 0.95, default 0.85).
- Deterministic, content-cached verdicts: the same text always scores the same
  and never flickers on rescan.

**Display**
- Colored outline overlays with a faint dim: orange for a high-confidence
  flag and red for very-high. The styling palette also defines a yellow
  tint for the suspicious band, which the shipped confidence gate (0.80
  floor) holds back as `unknown`.
- A pixel-art pet beside each flagged block, with a one-line comment on
  hover. Two built-in pets (Mochi the blob and Brill the cat), plus a
  custom pet editor; pet definitions live as JSON files in the user pets
  folder (Open Folder). A "None" picker (the fresh-install default) drops
  the character and reports the block's AI probability as a bare percentage.
- Debug Mode makes the pet speak each block's raw score and state.

**Coverage and control**
- Works across browsers and native apps via the Accessibility API.
- OCR fallback (ScreenCaptureKit + Vision) for canvas surfaces.
- A Trusted Sites list to skip domains you trust entirely.
- A **Check Text** panel for pasting a passage and getting a verdict on demand.
- "Erase All Local Data" wipes every local setting in one click.

## Privacy

Pilcrow collects nothing and sends nothing off your Mac. Both models run locally.
On-screen text is processed in memory and never written to disk or transmitted.
The app runs no local servers and opens no network ports. Full details are in
[PRIVACY.md](PRIVACY.md).

## How it works

Pilcrow reads a block of text, screens it with the fast Stage-1 model, and paints
a highlight only when the score is decisively AI and clears your threshold. If the
score lands in the uncertain middle and the block is long enough to matter, the
stronger Stage-2 model takes a second look. If neither stage is confident, the
block is left as "unknown" and nothing is drawn. The deeper architecture is
documented in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M-series)

## Install

1. Download Pilcrow from [DOWNLOAD_URL] and drag it to Applications.
2. Launch it from the menu bar and grant **Accessibility** once when asked.
3. Optionally grant **Screen Recording** if you want the OCR fallback for canvas
   surfaces like Google Docs.

## Pricing

Pilcrow is a one-time $4.99 purchase, for use on your own Macs, refundable
within 14 days. Buy it and your license key arrives by email; paste it into the
menu (Enter License) to unlock detection, both watching as you read and the
manual Check Text. Buy at [CHECKOUT_URL].

## Limitations

- Recall is weaker on paraphrased or heavily human-edited AI text.
- OCR on canvas surfaces is best-effort and depends on what is on screen.
- Pilcrow estimates; it does not prove authorship. Treat a flag as a reason to
  look closer, never as conclusive evidence. Do not use a verdict as the sole
  basis for an academic-integrity, employment, or disciplinary decision.

## FAQ

**Is my text sent anywhere?** No. Both models run on your Mac. Nothing is
uploaded.

**Does it work in Google Docs?** Yes — its accessibility layer is read directly,
with the OCR fallback (needs Screen Recording) as a backstop.

**Why didn't it flag something?** When the score is ambiguous, Pilcrow reports
"unknown" and flags nothing rather than guess.

**Can I use it to catch students?** It is not built for that. Pilcrow produces an
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

Pilcrow is proprietary software. See [LICENSE](LICENSE) and [EULA.md](EULA.md).
It bundles third-party models under their own licenses; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
