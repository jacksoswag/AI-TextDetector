#!/usr/bin/env python3
"""
Fit Platt scaling (temperature + bias) and a precision-first threshold for the
detector on YOUR data distribution, then print the JSON to paste into
Models/model-info.json. Inference-only; minutes on Apple Silicon.

Data format (CSV, header row):  text,label   (1 = AI, 0 = human)
Use held-out data the model never trained on, with plenty of genuinely human
text from the registers you care about (encyclopedic, casual, non-native).

Usage:
  python3 scripts/calibrate.py --data calib.csv [--model <dir-or-repo>] [--target-fpr 0.005]
"""

import argparse
import csv
import json
import sys

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

DEFAULT_MODEL = "MayZhou/e5-small-lora-ai-generated-detector"


def device():
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


@torch.no_grad()
def collect_logits(model, tokenizer, rows, dev, seq, ai_index, batch=32):
    logits_out, labels_out = [], []
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        enc = tokenizer(
            [r[0] for r in chunk], truncation=True, max_length=seq,
            padding="max_length", return_tensors="pt",
        )
        logits = model(
            input_ids=enc["input_ids"].to(dev),
            attention_mask=enc["attention_mask"].to(dev),
        ).logits.float().cpu()
        # Two-class head → single AI-vs-rest logit.
        ai_logit = logits[:, ai_index] - logits[:, 1 - ai_index]
        logits_out.append(ai_logit)
        labels_out.extend(r[1] for r in chunk)
    return torch.cat(logits_out), torch.tensor(labels_out, dtype=torch.float32)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", required=True)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--target-fpr", type=float, default=0.005)
    p.add_argument("--seq", type=int, default=256)
    p.add_argument("--ai-index", type=int, default=1)
    args = p.parse_args()

    rows = []
    with open(args.data, newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            text = (row.get("text") or "").strip()
            label = int(row.get("label", -1))
            if text and label in (0, 1):
                rows.append((text, label))
    if len(rows) < 50:
        sys.exit(f"need ≥50 labeled rows for a meaningful fit, got {len(rows)}")

    dev = device()
    tokenizer = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForSequenceClassification.from_pretrained(args.model).to(dev).eval()

    print(f"scoring {len(rows)} rows on {dev}…")
    logits, labels = collect_logits(model, tokenizer, rows, dev, args.seq, args.ai_index)

    # Platt scaling: minimize NLL of sigmoid((logit + bias) / temperature).
    temperature = torch.nn.Parameter(torch.ones(1))
    bias = torch.nn.Parameter(torch.zeros(1))
    optimizer = torch.optim.LBFGS([temperature, bias], lr=0.05, max_iter=200)
    bce = torch.nn.BCEWithLogitsLoss()

    def closure():
        optimizer.zero_grad()
        loss = bce((logits + bias) / temperature.clamp(min=0.05), labels)
        loss.backward()
        return loss

    optimizer.step(closure)
    t, b = float(temperature.clamp(min=0.05)), float(bias)

    calibrated = torch.sigmoid((logits + b) / t)
    human = calibrated[labels == 0].sort().values
    ai = calibrated[labels == 1]

    # Threshold achieving the target FPR on calibrated human scores.
    rank = min(int((1 - args.target_fpr) * len(human)), len(human) - 1)
    threshold = float(human[rank])
    recall = float((ai >= threshold).float().mean()) if len(ai) else float("nan")
    fpr = float((human >= threshold).float().mean())

    print(f"\ntemperature={t:.4f}  bias={b:.4f}")
    print(f"threshold {threshold:.3f} → FPR {fpr:.4f} (target {args.target_fpr}), recall {recall:.3f}")
    print("\nPaste into Models/model-info.json:")
    print(json.dumps({"calibration": {"temperature": round(t, 4), "bias": round(b, 4)}}, indent=2))
    print(f"\nand set the in-app threshold slider near {round(threshold * 100)}%.")


if __name__ == "__main__":
    main()
