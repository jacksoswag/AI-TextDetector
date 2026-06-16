# Training the detector on your own machine

This is the recipe for lifting the model's two weak registers: neutral
encyclopedic AI text (currently ~0.67) and LLM text imitating casual prose
(~0.60). The pipeline is verified end to end on Apple Silicon: fine-tune,
merge, convert to Core ML, calibrate, drop into the app.

## The pipeline

```
python3 scripts/finetune-lora.py --train train.csv --eval eval.csv --out out/ft
python3 scripts/convert-model.py out/ft/merged          # replaces Models/
python3 scripts/calibrate.py --model out/ft/merged --data calib.csv
# paste the printed calibration JSON into Models/model-info.json, rebuild the app
```

One-time setup: a Python venv with `torch`, `transformers==4.49.0` (5.x breaks
the Core ML trace), `coremltools>=9`, `peft`, `safetensors`.

## Data: what actually moves the needle

The model fails on these registers because its training data (RAID) doesn't
cover them well, so the data you build matters far more than hyperparameters.
Target shape: 30k to 100k rows, balanced classes, in pairs.

**Human side (label 0).** Genuinely human text, which means pre-2022 sources
or text you can vouch for:

- Wikipedia paragraphs from a pre-2022 dump (the encyclopedic register)
- Forum and Reddit posts, old blog comments, mailing lists (casual register)
- Your own writing and any corpora you trust
- Deliberately include formal, dry, non-native-speaker, and technical human
  text. These are the false-positive landmines; the model must see them
  labeled human.

**AI side (label 1).** For each human text, generate a *mirror*: same topic,
same register, same approximate length, written by an LLM. This pairing is
the method with the best published evidence behind it (it is how the one
commercial detector with independently verified near-zero false positives
trains). Generate with several different models, not one, and include:

- plain generations ("write a Wikipedia-style paragraph about X")
- casual-register generations ("reply like a Reddit commenter")
- paraphrased/"humanized" variants of AI text (run generations through a
  paraphraser), since these are the evasions users actually encounter

Generation needs an LLM. API batch jobs are the practical route: ~50k
generations of ~300 tokens is ~15M output tokens, a few dollars to a few tens
of dollars with a small model. A local generator also works if you have one
you trust; quality of the mirror matters more than the generator's size.

**Splits.** Hold out by topic, not by row, or mirrors of training topics leak
into eval and inflate your numbers. Keep a separate `calib.csv` (never
trained on) with at least a few thousand human rows for threshold fitting.

## What to run and what it costs on an M3 Air

Measured anchor from this machine: the LoRA setup trains 1.34M of 34.7M
parameters and runs on MPS out of the box.

| Step | Command | M3 Air expectation |
|---|---|---|
| Fine-tune e5-small, 50k rows × 3 epochs | `finetune-lora.py --batch 16` | Roughly 1 to 3 hours. Fanless throttling under sustained load is the main variable; plug in, expect the second hour to be slower. On an 8GB Air use `--batch 8` |
| Convert to Core ML | `convert-model.py out/ft/merged` | ~3 to 5 minutes |
| Calibrate | `calibrate.py --data calib.csv` | Minutes; inference only |

Memory: e5-small LoRA at batch 16/seq 256 stays under ~2GB of unified memory,
comfortable even on an 8GB Air. The eval pass reports accuracy and FPR at 0.5
each epoch; watch the FPR, not the accuracy.

A ModernBERT-large (~0.4B) fine-tune fills the Stage-2 slot: LoRA is possible
on a 16GB Air but expect most of a day with throttling. Unlike DeBERTa-v3
(whose disentangled attention NaNs in FP16 on the ANE and is stuck CPU-only),
ModernBERT's standard SDPA attention converts cleanly and runs FP16 on the
Neural Engine at ~144ms/window. Fine-tune with
`scripts/finetune-lora.py --base answerdotai/ModernBERT-large --seq 512`, then
export with `scripts/convert-stage2-modernbert.py`. Recommendation: iterate on
e5-small locally; rent a GPU hour if you want the big model.

## Calibration discipline

`calibrate.py` fits temperature + bias by NLL and picks the threshold hitting
your target false-positive rate (default 0.5%) on calibrated human scores.
For the zero-false-positive posture, run with `--target-fpr 0.001` (1 in
1,000 human blocks) — recall at that operating point is what provenance rules
and the heuristic AND-gate exist to compensate for.
Rules that keep the result meaningful:

1. Calibrate on data the model never saw in training.
2. Make the human side diverse; an FPR measured on one register transfers
   poorly to others.
3. Re-run calibration every time you retrain or swap weights. The app picks
   up new values from `model-info.json` without code changes.

## What not to expect

Fine-tuning lifts in-register recall, sometimes dramatically. It does not
solve adversarial paraphrase (published attacks cut every open detector's
recall sharply), and near-ceiling scores on casual AI text aren't achievable
with a 33M model. The app's wrapper (threshold, length gate, trusted sites,
per-domain learning) is the standing mitigation for everything the model
misses.
