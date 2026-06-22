#!/usr/bin/env python3
"""
Convert a ModernBERT-large sequence-classification model to Core ML as the
Stage-2 cascade model.

ModernBERT (Answer.AI / LightOn, Dec 2024) uses RoPE + alternating local/global
attention. Unlike DeBERTa-v3's disentangled relative-position embeddings — which
produce FP16 NaNs on GPU and crash MPSGraph in FP32 — ModernBERT's standard
SDPA-based attention traces cleanly and runs in FP16 on the Neural Engine/GPU.

Usage:
    /tmp/aicf-convert-venv/bin/python scripts/convert-stage2-modernbert.py [MODEL]

MODEL: HuggingFace repo or local path to a sequence-classification fine-tune of
       ModernBERT-large (num_labels=2, AI vs human). Defaults to the base model
       with a randomly-initialized head (useful to validate the conversion
       pipeline; swap in your fine-tuned model for production accuracy).

       Fine-tune first with:
           python3 scripts/finetune-lora.py --base answerdotai/ModernBERT-large \\
               --train corpus.csv --eval eval.csv --out out/modernbert-stage2

Same venv as convert-model.py (torch 2.7+ / transformers 4.50+ / coremltools 9).
Produces (same directory layout as the DeBERTa Stage-2):

    Models/Stage2-build/AITextClassifier.mlpackage   (FP16 ML Program, seq 512)
    Models/Stage2/AITextClassifier.mlmodelc          (compiled; the app loads this)
    Models/Stage2/bpe-vocab.json                     (token → id, BPETokenizer)
    Models/Stage2/bpe-merges.json                    (priority-ordered merge pairs)
    Models/Stage2/tokenizer-test-vectors.json         (HF-reference encodings)
    Models/Stage2/model-info.json                    (metadata, tokenizer spec)

The tokenizer spec ("type": "bpe") tells CoreMLClassifier to instantiate
BPETokenizer instead of the WordPiece path the general detector uses.
"""

import json
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
from transformers import AutoConfig, AutoTokenizer, AutoModelForSequenceClassification

# ---------------------------------------------------------------------------
# Architecture patches for clean CoreML tracing
# ---------------------------------------------------------------------------

# ModernBERT's eager SDPA path is already clean for tracing EXCEPT that the
# sliding-window local-attention mask is constructed with torch.full() +
# scatter/fill operations that coremltools can't always fold. Precomputing it
# per (seq_len, window_size) pair and caching avoids repeated dynamic creation.
_sw_mask_cache: dict = {}

def _precompute_sliding_window_mask(seq_len: int, window_size: int,
                                    dtype=torch.float32, device="cpu"):
    key = (seq_len, window_size, dtype, device)
    if key not in _sw_mask_cache:
        mask = torch.full((seq_len, seq_len), float("-inf"), dtype=dtype, device=device)
        for i in range(seq_len):
            lo = max(0, i - window_size // 2)
            hi = min(seq_len, i + window_size // 2 + 1)
            mask[i, lo:hi] = 0.0
        _sw_mask_cache[key] = mask.detach().clone()
    return _sw_mask_cache[key]


def _patch_modernbert_attention(model, seq_len: int):
    """
    Replace the forward method of every ModernBertSdpaAttention with one that:
      1. Uses a precomputed sliding-window mask (constant for fixed seq_len).
      2. Converts the caller-supplied boolean attention_mask to an additive float
         mask (CoreML's SDPA kernel expects float bias, not bool).
    Global attention layers are left unchanged (they use the caller-supplied mask).
    """
    from transformers.models.modernbert import modeling_modernbert as mb

    # transformers >= ~4.48 uses a unified `ModernBertAttention` that dispatches
    # to module-level sdpa/eager functions; there is no `ModernBertSdpaAttention`
    # subclass to patch. The stock SDPA path (F.scaled_dot_product_attention with
    # a precomputed additive mask passed down from the model forward) traces
    # cleanly on coremltools 9, so skip the legacy monkeypatch when the old class
    # is absent.
    if not hasattr(mb, "ModernBertSdpaAttention"):
        print("   ModernBertSdpaAttention absent — relying on stock SDPA path")
        return

    original_forward = mb.ModernBertSdpaAttention.forward

    def patched_forward(self, hidden_states, attention_mask=None,
                        sliding_window_mask=None, position_ids=None,
                        output_attentions=False, **kwargs):
        B, L, _ = hidden_states.shape
        qkv = self.Wqkv(hidden_states)
        # [B, L, 3, nheads, head_dim] → split to Q/K/V
        qkv = qkv.view(B, L, 3, self.num_attention_heads, self.attention_head_size)
        q = qkv[:, :, 0].transpose(1, 2)   # [B, H, L, d]
        k = qkv[:, :, 1].transpose(1, 2)
        v = qkv[:, :, 2].transpose(1, 2)

        # Apply RoPE
        cos, sin = self.rotary_emb(hidden_states, position_ids=position_ids)
        q, k = mb.apply_rotary_pos_emb(q, k, cos, sin)

        if self.is_sliding:
            # Precomputed constant for this seq_len / window_size combination.
            sw_mask = _precompute_sliding_window_mask(
                L, self.config.sliding_window, dtype=hidden_states.dtype,
                device=hidden_states.device)
            # Merge with the caller's padding mask if present.
            if attention_mask is not None:
                float_mask = attention_mask.to(hidden_states.dtype)
                sw_mask = sw_mask.unsqueeze(0).unsqueeze(0) + float_mask
            else:
                sw_mask = sw_mask.unsqueeze(0).unsqueeze(0).expand(B, 1, -1, -1)
        else:
            # Global attention: use caller's mask, converted to float additive.
            if attention_mask is not None:
                sw_mask = attention_mask.to(hidden_states.dtype)
            else:
                sw_mask = None

        attn_out = F.scaled_dot_product_attention(
            q, k, v, attn_mask=sw_mask, scale=self.attention_head_size ** -0.5)
        attn_out = attn_out.transpose(1, 2).contiguous().view(B, L, -1)
        return (self.out_proj(attn_out),)

    mb.ModernBertSdpaAttention.forward = patched_forward
    print(f"   patched ModernBertSdpaAttention.forward for seq_len={seq_len}")


# coremltools occasionally trips on aten::Int/aten::bool with numpy size-1
# arrays — same patch as the DeBERTa converter.
try:
    from coremltools.converters.mil.frontend.torch import ops as _ctops

    _orig_ct_cast = _ctops._cast

    def _patched_ct_cast(context, node, dtype, dtype_name):
        inputs = _ctops._get_inputs(context, node, expected=1)
        x = inputs[0]
        if x.can_be_folded_to_const():
            val = np.asarray(x.val)
            if val.ndim > 0 and val.size == 1:
                context.add(_ctops.mb.const(val=dtype(val.item()), name=node.name), node.name)
                return
        _orig_ct_cast(context, node, dtype, dtype_name)

    _ctops._cast = _patched_ct_cast
except Exception:
    pass

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

DEFAULT_REPO = "answerdotai/ModernBERT-large"
REPO = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_REPO
LICENSE = "apache-2.0"
SEQ_LEN = 512      # ModernBERT supports up to 8192 but 512 covers the cascade band
ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = ROOT / "Models" / "Stage2-build"
SHIP_DIR = ROOT / "Models" / "Stage2"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
SHIP_DIR.mkdir(parents=True, exist_ok=True)

# Reuse the probe texts from the primary converter for comparable sanity numbers.
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "convert_model", ROOT / "scripts" / "convert-model.py")
_cm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_cm)
AI_TEXTS, HUMAN_TEXTS = _cm.AI_TEXTS, _cm.HUMAN_TEXTS


def dir_size_mb(path):
    return round(sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file()) / 1024 / 1024, 2)


# ---------------------------------------------------------------------------
# Model wrapper for tracing
# ---------------------------------------------------------------------------

class TraceWrapper(torch.nn.Module):
    """Wraps the HF classification model: long→int32 inputs, and ALWAYS emits a
    binary [P(not-AI), P(AI)] output regardless of the head's class count, so the
    CoreMLClassifier probability() path (ai_label_index = 1) is identical for
    1-label sigmoid, 2-label softmax, and multi-class (human/mixed/ai) heads."""
    def __init__(self, model, human_index=0):
        super().__init__()
        self.model = model
        self.human_index = human_index

    def forward(self, input_ids, attention_mask):
        out = self.model(
            input_ids=input_ids.to(torch.long),
            attention_mask=attention_mask.to(torch.long),
        )
        logits = out.logits
        if logits.shape[-1] == 1:
            p_ai = torch.sigmoid(logits)
        else:
            probs = torch.softmax(logits, dim=-1)
            # P(AI) = 1 - P(human). For a 3-class human/mixed/ai head this counts
            # "mixed" (AI-assisted) as AI-positive — both the product intent and a
            # far cleaner split than the bare "ai" class (which leaves generic AI
            # prose the model labels "mixed" below 0.5). For a binary [non-AI, AI]
            # head it reduces to softmax[1], unchanged.
            p_ai = 1.0 - probs[:, self.human_index:self.human_index + 1]
        return torch.cat([1 - p_ai, p_ai], dim=-1)


# ---------------------------------------------------------------------------
# Parity helpers
# ---------------------------------------------------------------------------

def tokenize_hf(tok, text):
    enc = tok(text, return_tensors="np", truncation=True,
              max_length=SEQ_LEN, padding="max_length")
    return enc["input_ids"].astype(np.int32), enc["attention_mask"].astype(np.int32)


def pytorch_prob(wrapper, ids, mask):
    with torch.no_grad():
        out = wrapper(torch.from_numpy(ids).int(), torch.from_numpy(mask).int())
    return float(out[0, 1])


def parity_check(pkg_path, label, wrapper, tok):
    cm = ct.models.MLModel(str(pkg_path), compute_units=ct.ComputeUnit.ALL)
    diffs, samples = [], []
    for kind, text in [("ai", t) for t in AI_TEXTS] + [("human", t) for t in HUMAN_TEXTS]:
        ids, mask = tokenize_hf(tok, text)
        pt = pytorch_prob(wrapper, ids, mask)
        pred = cm.predict({"input_ids": ids, "attention_mask": mask})
        # Output name varies; grab the first value.
        out_val = next(iter(pred.values()))
        cp = float(np.asarray(out_val).ravel()[1])   # index 1 = AI
        diffs.append(abs(pt - cp))
        samples.append({"text_kind": kind,
                        "pytorch_prob_ai": round(pt, 6),
                        "coreml_prob_ai": round(cp, 6)})
        print(f"   {kind:6s}  pt={pt:.4f}  coreml={cp:.4f}")
    worst = max(diffs)
    ok = (not np.isnan(worst)) and worst < 0.05
    print(f"   [{label}] max abs diff: {worst:.6f}  {'OK' if ok else 'FAIL'}")
    return ok, round(float(worst), 6), samples


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print(f"== Loading {REPO}")
    tok = AutoTokenizer.from_pretrained(REPO)

    config = AutoConfig.from_pretrained(REPO)
    config._attn_implementation = "sdpa"    # clean F.scaled_dot_product_attention path, no flash
    # Load the model's OWN classification head — do NOT force num_labels (that
    # would discard a trained head). Works for binary fine-tunes and multi-class
    # heads (e.g. human/mixed/ai). The TraceWrapper projects any head to binary.

    model = AutoModelForSequenceClassification.from_pretrained(
        REPO,
        config=config,
        ignore_mismatched_sizes=True,
    )
    model.eval()
    param_count = sum(p.numel() for p in model.parameters())
    n_labels = model.config.num_labels
    # P(AI) = 1 - P(human/negative class). Find the human class by name; label 0
    # is the negative class by convention when labels are unnamed (LABEL_0/1).
    id2label = {int(k): str(v).lower() for k, v in (model.config.id2label or {}).items()}
    human_index = next((i for i, lab in id2label.items() if "human" in lab or "real" in lab), 0)
    print(f"   params={param_count:,}  seq_len={SEQ_LEN}  num_labels={n_labels}  human_index={human_index}")

    _patch_modernbert_attention(model, SEQ_LEN)

    wrapper = TraceWrapper(model, human_index=human_index).eval()

    # Sanity: AI score should exceed human score.
    ids_ai, mask_ai = tokenize_hf(tok, AI_TEXTS[0])
    ids_hu, mask_hu = tokenize_hf(tok, HUMAN_TEXTS[0])
    p_ai = pytorch_prob(wrapper, ids_ai, mask_ai)
    p_hu = pytorch_prob(wrapper, ids_hu, mask_hu)
    print(f"   probe: ai={p_ai:.4f}  human={p_hu:.4f}")
    if not (p_ai > p_hu):
        print("   WARNING: probe direction unexpected — model may need fine-tuning")

    # ------------------------------------------------------------------
    # Trace + Convert (FP16 — runs on ANE / GPU, unlike DeBERTa's CPU-only)
    # ------------------------------------------------------------------
    ex_ids  = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
    ex_mask = torch.ones((1, SEQ_LEN), dtype=torch.int32)
    ex_ids[0, 0] = 1   # put a non-zero token so the model doesn't see all-padding

    print("== Tracing")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ex_ids, ex_mask), strict=False)

    pkg_path = BUILD_DIR / "AITextClassifier.mlpackage"

    convert_kwargs = dict(
        inputs=[
            ct.TensorType(name="input_ids",    shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="probabilities", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
    )

    print("== Converting (FP16 weights + FP16 compute — ANE/GPU eligible)")
    mlmodel = ct.convert(traced, compute_precision=ct.precision.FLOAT16, **convert_kwargs)

    description = (
        f"Stage-2 AI-text detector ({REPO}, ModernBERT). "
        f"probabilities[1] = P(AI-generated). seq_len={SEQ_LEN}."
    )
    mlmodel.short_description = description
    if pkg_path.exists():
        shutil.rmtree(pkg_path)
    mlmodel.save(str(pkg_path))
    print(f"   saved {pkg_path} ({dir_size_mb(pkg_path)} MB)")

    print("== Parity (compute_units=ALL — tests ANE + GPU path)")
    ok, parity, sample_scores = parity_check(pkg_path, "fp16 ALL", wrapper, tok)
    if not ok:
        print("   Parity failed. Retrying with FP32 compute (fallback — CPU only)…")
        mlmodel_fp32 = ct.convert(traced, compute_precision=ct.precision.FLOAT32,
                                  **convert_kwargs)
        mlmodel_fp32.short_description = description + " (fp32 compute fallback)"
        if pkg_path.exists():
            shutil.rmtree(pkg_path)
        mlmodel_fp32.save(str(pkg_path))
        ok, parity, sample_scores = parity_check(pkg_path, "fp32 CPU_ONLY",
                                                  wrapper, tok)
        assert ok, f"parity failed (worst={parity}) — check model and conversion"
        compute_units_note = "cpu_only (fp16 NaN fallback)"
        precision_note = "fp32 compute"
    else:
        # Pin the Neural Engine: measured on the compiled model, CPU_AND_NE
        # (~144ms/window) beats ALL (~186ms, which splits work to the GPU) and
        # pure GPU (~558ms). The app maps "cpu_and_ne" to .cpuAndNeuralEngine.
        compute_units_note = "cpu_and_ne"
        precision_note = "fp16"

    # ------------------------------------------------------------------
    # Latency
    # ------------------------------------------------------------------
    print(f"== Latency (compute_units={compute_units_note.upper()}, 3 warmups, 12 runs)")
    cu = ct.ComputeUnit.CPU_ONLY if "cpu_only" in compute_units_note else ct.ComputeUnit.CPU_AND_NE
    m_bench = ct.models.MLModel(str(pkg_path), compute_units=cu)
    feed = {"input_ids": ids_ai, "attention_mask": mask_ai}
    for _ in range(3):
        m_bench.predict(feed)
    times = []
    for _ in range(12):
        t0 = time.perf_counter()
        m_bench.predict(feed)
        times.append((time.perf_counter() - t0) * 1000.0)
    latency = {"median": round(statistics.median(times), 2),
               "p90": round(float(np.percentile(times, 90)), 2)}
    print(f"   {latency}")

    # ------------------------------------------------------------------
    # Compile to .mlmodelc
    # ------------------------------------------------------------------
    print("== Compiling with coremlcompiler")
    out = SHIP_DIR / "AITextClassifier.mlmodelc"
    if out.exists():
        shutil.rmtree(out)
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(pkg_path), str(SHIP_DIR)],
        check=True)
    cmc = ct.models.CompiledMLModel(str(out), compute_units=cu)
    p_compiled = float(np.asarray(cmc.predict(feed)["probabilities"]).ravel()[1])
    print(f"   {out.name} loads OK  sample P(AI)={p_compiled:.4f}  ({dir_size_mb(out)} MB)")

    # ------------------------------------------------------------------
    # Tokenizer export: BPE vocab + merges for Swift BPETokenizer
    # ------------------------------------------------------------------
    print("== Exporting BPE vocabulary + merges")

    # Load raw tokenizer.json from HF (the source of truth for vocab and merges).
    try:
        tok_json_path = Path(tok.vocab_file).parent / "tokenizer.json"
        if not tok_json_path.exists():
            raise FileNotFoundError
        tok_json = json.loads(tok_json_path.read_text())
    except (AttributeError, FileNotFoundError, TypeError):
        # Local model dir (e.g. a fine-tune at Models/merged) has tokenizer.json
        # right there; only hit the hub when REPO is an actual repo id.
        local_tok = Path(REPO) / "tokenizer.json"
        if local_tok.exists():
            tok_json = json.loads(local_tok.read_text())
        else:
            from huggingface_hub import hf_hub_download
            tok_json = json.loads(
                Path(hf_hub_download(REPO, "tokenizer.json")).read_text())

    model_section = tok_json["model"]
    assert model_section["type"] == "BPE", f"Expected BPE tokenizer, got {model_section['type']}"

    # vocab.json — token → id
    vocab: dict = model_section["vocab"]
    (SHIP_DIR / "bpe-vocab.json").write_text(json.dumps(vocab, ensure_ascii=False))
    print(f"   bpe-vocab.json  ({len(vocab):,} tokens, "
          f"{(SHIP_DIR / 'bpe-vocab.json').stat().st_size // 1024} KB)")

    # merges.json — [[a, b], ...] in priority order. The tokenizers library
    # stores merges as either "a b" strings (older format) or ["a", "b"] lists
    # (newer format, e.g. ModernBERT); handle both so neither yields empty merges.
    raw_merges = model_section["merges"]
    merges_pairs = []
    for m in raw_merges:
        if isinstance(m, (list, tuple)) and len(m) == 2:
            merges_pairs.append([m[0], m[1]])
        elif isinstance(m, str) and " " in m:
            merges_pairs.append(m.split(" ", 1))
    (SHIP_DIR / "bpe-merges.json").write_text(json.dumps(merges_pairs))
    print(f"   bpe-merges.json ({len(merges_pairs):,} merges, "
          f"{(SHIP_DIR / 'bpe-merges.json').stat().st_size // 1024} KB)")

    # ------------------------------------------------------------------
    # Tokenizer test vectors: pin Swift BPETokenizer to HF reference
    # ------------------------------------------------------------------
    vector_texts = [
        AI_TEXTS[0][:400], HUMAN_TEXTS[0][:400], HUMAN_TEXTS[2][:400],
        "AI Overview\nPhotosynthesis converts light energy into chemical energy.",
        "It's a test — with em-dashes, \"curly quotes\", and    multiple   spaces.",
        "naïve café résumé über 東京 emoji 🙂 done",
        "def main():\n    return {'key': [1, 2, 3]}  # code-ish",
        "Tabs\tand\nnewlines and trailing space ",
        "single",
        "Numbers 12,345.67 and 99% and $40 and v2.0.1",
        "can't won't shouldn't it's I've they'll I'd",
    ]
    vectors = []
    for text in vector_texts:
        enc = tok(text, add_special_tokens=False)
        vectors.append({"text": text, "ids": enc["input_ids"]})
    (SHIP_DIR / "tokenizer-test-vectors.json").write_text(
        json.dumps(vectors, ensure_ascii=False, indent=1))
    print(f"   tokenizer-test-vectors.json ({len(vectors)} cases)")

    # ------------------------------------------------------------------
    # Special tokens (CLS/SEP/PAD/UNK for model-info.json)
    # ------------------------------------------------------------------
    def tok_ref(token, fallback_id):
        tid = tok.convert_tokens_to_ids(token)
        if tid == tok.unk_token_id and token != tok.unk_token:
            tid = fallback_id
        return {"token": token, "id": tid}

    special_tokens = {
        "cls": tok_ref(tok.cls_token or "[CLS]", 1),
        "sep": tok_ref(tok.sep_token or "[SEP]", 2),
        "pad": tok_ref(tok.pad_token or "[PAD]", 0),
        "unk": tok_ref(tok.unk_token or "[UNK]", 3),
    }

    # ------------------------------------------------------------------
    # model-info.json
    # ------------------------------------------------------------------
    info = {
        "source_repo": REPO,
        "license": LICENSE,
        "architecture": f"{config.model_type} + sequence classification head",
        "param_count_estimate": param_count,
        "seq_len": SEQ_LEN,
        "ai_label_index": 1,   # index 1 of the [human, AI] softmax output
        "num_labels": 2,
        "do_lower_case": False,
        "compute_units": compute_units_note,
        "compute_units_note": (
            "ModernBERT uses RoPE + standard SDPA — runs in FP16 on ANE/GPU "
            "unlike DeBERTa whose disentangled attention produces NaN in FP16 "
            "on Apple Silicon. compute_units=all unless FP16 parity fails."
        ),
        "tokenizer": {
            "type": "bpe",
            "vocab_file": "bpe-vocab.json",
        },
        "special_token_ids": special_tokens,
        "package_size_mb": dir_size_mb(pkg_path),
        "precision": precision_note,
        "compiled_size_mb": dir_size_mb(out),
        "parity_max_abs_diff": parity,
        "latency_ms": latency,
        "sample_scores": sample_scores,
        "role": "stage2 cascade model — escalation target for the 0.40–0.93 uncertain band",
    }
    (SHIP_DIR / "model-info.json").write_text(json.dumps(info, indent=2) + "\n")
    print("== Wrote", SHIP_DIR / "model-info.json")
    print(json.dumps({k: v for k, v in info.items() if k != "sample_scores"}, indent=2))


if __name__ == "__main__":
    main()
