#!/usr/bin/env bash
# Fine-tune the ModernBERT-large Stage-2 detector on a rented CUDA GPU.
# The M3 can't do this (MPS falls ModernBERT's ops back to CPU → ~160s/step);
# a real GPU does the whole 2-epoch run in ~20-40 min for ~$1-2 (A100), or free
# on a Colab T4/L4. finetune-lora.py auto-detects CUDA, no code changes needed.
#
# ── On the GPU box (Ubuntu + CUDA), upload these 3 files next to this script ──
#     scripts/finetune-lora.py
#     data/corpus/train.csv
#     data/corpus/eval.csv
#   then:  bash cloud-finetune.sh
#   then download  out/stage2-ft/merged/  back to your Mac and run
#     python3 scripts/convert-stage2-modernbert.py out/stage2-ft/merged
#   and drop the converted .mlmodelc + jsons into Models/Stage2/.
set -euo pipefail

pip install -q "torch" "transformers>=4.48" "peft" "accelerate"

python finetune-lora.py \
  --base Donnyed/LLM_Detector_Preview_model \
  --train train.csv --eval eval.csv \
  --seq 512 --batch 16 --epochs 2 --lr 2e-4 --save-steps 200 \
  --out out/stage2-ft

echo
echo "DONE. Download out/stage2-ft/merged/ to your Mac, then:"
echo "  python3 scripts/convert-stage2-modernbert.py out/stage2-ft/merged"
echo "  cp -r <converted .mlmodelc + jsons> Models/Stage2/"
