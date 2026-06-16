#!/usr/bin/env python3
"""
LoRA fine-tune of the bundled AI-text detector on your own labeled data.
Runs on Apple Silicon (MPS), CUDA, or CPU. Deliberately dependency-light:
torch + transformers + peft, a manual training loop, no Trainer/accelerate.

Data format (CSV, UTF-8, header row):  text,label
  label: 1 = AI-generated, 0 = human-written

Usage (Stage-1, the bundled e5-small detector):
  python3 scripts/finetune-lora.py --train train.csv --eval eval.csv --out out/finetune
  python3 scripts/convert-model.py out/finetune/merged        # re-export to Core ML
  python3 scripts/calibrate.py --model out/finetune/merged --data calib.csv

Usage (Stage-2, RECOMMENDED — harden the SHIPPED detector, which already has a
trained detection head, instead of the raw ModernBERT base):
  python3 scripts/finetune-lora.py --base Donnyed/LLM_Detector_Preview_model \
      --train data/corpus/calib.csv --val-frac 0.12 --seq 512 --batch 4 \
      --out out/stage2
  python3 scripts/convert-stage2-modernbert.py out/stage2/merged   # re-export to Core ML
  # then drop the converted .mlmodelc + jsons into Models/Stage2/

Set PYTORCH_ENABLE_MPS_FALLBACK=1 on Apple Silicon (a few ModernBERT ops fall
back to CPU). On a base M3, keep --batch small (4) at --seq 512 to fit memory.

The script auto-detects the base architecture: ModernBERT gets LoRA on its
Wqkv/Wi/Wo modules (BERT/RoBERTa get query/key/value/dense), and it prints the
matching convert command on completion. Fine-tune Stage-2 at --seq 512 to match
the export window.

Practical recipe for the two weak registers (neutral encyclopedic, casual):
build pairs — for each genuinely human text (pre-2022 Wikipedia paragraphs,
forum/Reddit posts), generate an AI mirror on the same topic in the same
register with several different models, including paraphrased/"humanized"
variants. Keep classes balanced and hold out whole topics, not just rows.
"""

import argparse
import csv
import math
import random
import sys
from pathlib import Path

import torch
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer

try:
    from peft import LoraConfig, get_peft_model
except ImportError:
    sys.exit("peft is required: pip install peft")

BASE = "MayZhou/e5-small-lora-ai-generated-detector"


def device():
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


class CSVTextDataset(Dataset):
    def __init__(self, path, tokenizer, seq_len, rows=None):
        if rows is not None:
            self.rows = rows
        else:
            self.rows = []
            with open(path, newline="", encoding="utf-8") as f:
                for row in csv.DictReader(f):
                    text = (row.get("text") or "").strip()
                    label = int(row.get("label", -1))
                    if text and label in (0, 1):
                        self.rows.append((text, label))
            if not self.rows:
                sys.exit(f"no usable rows in {path} (need columns: text,label)")
        self.tokenizer = tokenizer
        self.seq_len = seq_len

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        text, label = self.rows[i]
        enc = self.tokenizer(
            text, truncation=True, max_length=self.seq_len,
            padding="max_length", return_tensors="pt",
        )
        return {
            "input_ids": enc["input_ids"][0],
            "attention_mask": enc["attention_mask"][0],
            "label": torch.tensor(label),
        }


@torch.no_grad()
def evaluate(model, loader, dev, ai_index):
    model.eval()
    correct = total = 0
    false_pos = humans = 0
    true_pos = ais = 0
    for batch in loader:
        logits = model(
            input_ids=batch["input_ids"].to(dev),
            attention_mask=batch["attention_mask"].to(dev),
        ).logits
        pred = (torch.softmax(logits, dim=-1)[:, ai_index] >= 0.5).long().cpu()
        labels = batch["label"]
        correct += int((pred == labels).sum())
        total += len(labels)
        humans += int((labels == 0).sum())
        ais += int((labels == 1).sum())
        false_pos += int(((pred == 1) & (labels == 0)).sum())
        true_pos += int(((pred == 1) & (labels == 1)).sum())
    fpr = false_pos / humans if humans else float("nan")
    recall = true_pos / ais if ais else float("nan")
    return correct / total, fpr, recall


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--train", required=True)
    p.add_argument("--eval", default=None)
    p.add_argument("--out", default="out/finetune")
    p.add_argument("--base", default=BASE)
    p.add_argument("--epochs", type=int, default=3)
    p.add_argument("--batch", type=int, default=16)
    p.add_argument("--lr", type=float, default=2e-4)
    p.add_argument("--seq", type=int, default=256)
    p.add_argument("--lora-r", type=int, default=16)
    p.add_argument("--val-frac", type=float, default=0.0,
                   help="if no --eval, carve this fraction of --train for eval")
    p.add_argument("--max-steps", type=int, default=0, help="debug: stop early")
    p.add_argument("--skip-save", action="store_true", help="debug: skip LoRA merge + save")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    random.seed(args.seed)
    torch.manual_seed(args.seed)
    dev = device()
    print(f"device: {dev}")

    tokenizer = AutoTokenizer.from_pretrained(args.base)
    model = AutoModelForSequenceClassification.from_pretrained(args.base)
    ai_index = 1  # binary [human=0, AI=1]; the merged model converts to P(AI)

    # LoRA targets differ by architecture. BERT/RoBERTa/e5 expose
    # query/key/value/dense; ModernBERT fuses QKV into Wqkv and names its
    # projections Wo/Wi (attention output + MLP) with a separate prediction head,
    # so the old target list attaches nothing on it.
    model_type = getattr(model.config, "model_type", "")
    if model_type == "modernbert":
        target_modules = ["Wqkv", "Wi", "Wo"]
        modules_to_save = ["head", "classifier"]
        convert_script = "scripts/convert-stage2-modernbert.py"
    else:
        target_modules = ["query", "key", "value", "dense"]
        modules_to_save = ["classifier"]
        convert_script = "scripts/convert-model.py"
    print(f"base model_type={model_type or '?'}  LoRA targets={target_modules}")

    lora = LoraConfig(
        r=args.lora_r, lora_alpha=2 * args.lora_r, lora_dropout=0.05,
        target_modules=target_modules,
        modules_to_save=modules_to_save,
        task_type="SEQ_CLS",
    )
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()
    model.to(dev)

    full = CSVTextDataset(args.train, tokenizer, args.seq)
    if args.eval:
        train_set = full
        eval_set = CSVTextDataset(args.eval, tokenizer, args.seq)
    elif args.val_frac > 0:
        rows = full.rows[:]
        random.shuffle(rows)
        k = max(1, int(len(rows) * args.val_frac))
        eval_set = CSVTextDataset(None, tokenizer, args.seq, rows=rows[:k])
        train_set = CSVTextDataset(None, tokenizer, args.seq, rows=rows[k:])
        print(f"auto-split: {len(train_set)} train / {len(eval_set)} eval (val-frac {args.val_frac})")
    else:
        train_set, eval_set = full, None
    train_loader = DataLoader(train_set, batch_size=args.batch, shuffle=True)
    eval_loader = DataLoader(eval_set, batch_size=args.batch) if eval_set else None

    steps_per_epoch = math.ceil(len(train_set) / args.batch)
    total_steps = args.max_steps or steps_per_epoch * args.epochs
    optimizer = torch.optim.AdamW(
        (p for p in model.parameters() if p.requires_grad), lr=args.lr)
    scheduler = torch.optim.lr_scheduler.LinearLR(
        optimizer, start_factor=1.0, end_factor=0.1, total_iters=total_steps)
    loss_fn = torch.nn.CrossEntropyLoss()

    step = 0
    for epoch in range(args.epochs):
        model.train()
        for batch in train_loader:
            optimizer.zero_grad()
            logits = model(
                input_ids=batch["input_ids"].to(dev),
                attention_mask=batch["attention_mask"].to(dev),
            ).logits
            loss = loss_fn(logits, batch["label"].to(dev))
            loss.backward()
            optimizer.step()
            scheduler.step()
            step += 1
            if step % 50 == 0 or step == total_steps:
                print(f"epoch {epoch + 1} step {step}/{total_steps} loss {loss.item():.4f}")
            if args.max_steps and step >= args.max_steps:
                break
        if args.max_steps and step >= args.max_steps:
            break
        if eval_loader:
            acc, fpr, recall = evaluate(model, eval_loader, dev, ai_index)
            print(f"epoch {epoch + 1}: eval acc {acc:.4f}  FPR@0.5 {fpr:.4f}  recall {recall:.4f}")

    if args.skip_save:
        print("--skip-save: training wiring verified, not merging/saving.")
        return

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    print("merging LoRA into base weights…")
    merged = model.merge_and_unload()
    merged_dir = out / "merged"
    merged.save_pretrained(merged_dir)
    tokenizer.save_pretrained(merged_dir)
    print(f"saved merged model to {merged_dir}")
    print(f"next: python3 {convert_script} {merged_dir}")


if __name__ == "__main__":
    main()
