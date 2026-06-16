#!/usr/bin/env python3
"""
measure-gate.py — the gate-distribution measurement.

Answers the one question that decides whether fine-tuning is even the right
lever: when the FAST model scores your texts, where do the probabilities land
relative to the cascade's escalation band [0.40, 0.93]?

  * Mass BELOW 0.40  -> "confident human": the one-way-door zone. Disguised text
                        landing here never reaches the deep model. If your
                        humanized samples pile up here, the GATE is the barrier
                        (the stylometry override + a better gate model), not the
                        deep model's accuracy.
  * Mass IN 0.40-0.93 -> escalates today; if the deep model still calls these
                        human, THAT is the fine-tune target.
  * Mass ABOVE 0.93  -> already caught.

Run it on a labeled set (e.g. data/corpus/eval.csv, or a folder of humanized
samples). This uses the BASE small model — the same family the app screens with
(MayZhou/e5-small-lora-ai-generated-detector). It measures the gate's screening
behavior, not the app's full calibrated cascade; for the faithful in-app number
read CascadeClassifier.escalationStats from a live scan.

Usage:
  python3 scripts/measure-gate.py --data data/corpus/eval.csv
  python3 scripts/measure-gate.py --data humanized.csv --band 0.40 0.93
"""

import argparse
import csv
import sys
from pathlib import Path

try:
    import torch
    from transformers import AutoModelForSequenceClassification, AutoTokenizer
except ImportError:
    sys.exit("needs torch + transformers (same deps as finetune-lora.py)")

BASE = "MayZhou/e5-small-lora-ai-generated-detector"


def device():
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def load_rows(path: Path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            text = (r.get("text") or "").strip()
            label = r.get("label")
            if text:
                rows.append((text, int(label) if label in ("0", "1") else None))
    if not rows:
        sys.exit(f"no usable rows in {path}")
    return rows


@torch.no_grad()
def ai_prob(model, tok, dev, text, ai_index):
    enc = tok(text, truncation=True, max_length=512, padding="max_length",
              return_tensors="pt").to(dev)
    logits = model(**enc).logits[0]
    return torch.softmax(logits, dim=-1)[ai_index].item()


def bucket(p, lo, hi):
    if p < lo:
        return "below"
    if p > hi:
        return "above"
    return "in"


def summarize(name, probs, lo, hi):
    n = len(probs)
    if not n:
        return
    counts = {"below": 0, "in": 0, "above": 0}
    for p in probs:
        counts[bucket(p, lo, hi)] += 1
    print(f"\n[{name}]  n={n}")
    print(f"  below {lo:.2f} (confident human, NEVER escalates) : {counts['below']:5d}  ({100*counts['below']/n:5.1f}%)")
    print(f"  in   [{lo:.2f},{hi:.2f}] (escalates to deep model)  : {counts['in']:5d}  ({100*counts['in']/n:5.1f}%)")
    print(f"  above {hi:.2f} (confident AI, already caught)      : {counts['above']:5d}  ({100*counts['above']/n:5.1f}%)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", type=Path, required=True, help="CSV with column text (label optional)")
    ap.add_argument("--model", default=BASE, help="model id or path (e.g. a fine-tuned dir)")
    ap.add_argument("--band", type=float, nargs=2, default=(0.40, 0.93),
                    metavar=("LO", "HI"), help="escalation band (matches CascadeClassifier)")
    args = ap.parse_args()
    lo, hi = args.band

    dev = device()
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model).to(dev).eval()
    # The AI class index varies by checkpoint; trust id2label, else assume 1.
    ai_index = 1
    id2label = getattr(model.config, "id2label", {}) or {}
    for i, lab in id2label.items():
        if "ai" in str(lab).lower() or "fake" in str(lab).lower() or "generated" in str(lab).lower():
            ai_index = int(i)

    rows = load_rows(args.data)
    by_label = {0: [], 1: [], None: []}
    for text, label in rows:
        by_label[label].append(ai_prob(model, tok, dev, text, ai_index))

    summarize("ALL", [p for ps in by_label.values() for p in ps], lo, hi)
    if by_label[1]:
        summarize("AI-labeled (label=1) — watch 'below': that's the blind spot", by_label[1], lo, hi)
    if by_label[0]:
        summarize("human-labeled (label=0)", by_label[0], lo, hi)

    blind = sum(1 for p in by_label[1] if p < lo)
    if by_label[1]:
        print(f"\nverdict: {100*blind/len(by_label[1]):.1f}% of AI-labeled text scores below the band "
              f"(invisible to the deep model). High here => the GATE is the barrier.")


if __name__ == "__main__":
    main()
