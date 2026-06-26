#!/usr/bin/env python3
"""CPU-only: merge a LoRA training checkpoint into a full model for conversion.
Use when a GPU run is interrupted (e.g. Colab quota) — the merge is pure weight
arithmetic and needs no GPU.

  python3 scripts/merge-checkpoint.py [ckpt] [out] [--base REPO]

Defaults: ckpt=out/stage2-ft/ckpt  out=out/stage2-ft/merged  base=answerdotai/ModernBERT-large

NOTE: finetune-lora.py's --save-steps overwrites ONE checkpoint dir, so out/stage2-ft/ckpt
is the LATEST step reached, not necessarily an epoch boundary.
"""
import argparse
import torch
from peft import PeftModel
from transformers import AutoModelForSequenceClassification, AutoTokenizer

p = argparse.ArgumentParser()
p.add_argument("ckpt", nargs="?", default="out/stage2-ft/ckpt")
p.add_argument("out", nargs="?", default="out/stage2-ft/merged")
p.add_argument("--base", default="answerdotai/ModernBERT-large")
a = p.parse_args()

print(f"base={a.base}  ckpt={a.ckpt}  ->  {a.out}   (CPU, fp32)")
base = AutoModelForSequenceClassification.from_pretrained(a.base, num_labels=2, torch_dtype=torch.float32)
model = PeftModel.from_pretrained(base, a.ckpt).merge_and_unload()   # LoRA + trained head -> full model
model.save_pretrained(a.out)
try:
    AutoTokenizer.from_pretrained(a.ckpt).save_pretrained(a.out)
except Exception:  # noqa: BLE001 — ckpt may not carry the tokenizer
    AutoTokenizer.from_pretrained(a.base).save_pretrained(a.out)
print(f"merged -> {a.out} | num_labels={model.config.num_labels} | id2label={model.config.id2label}")
