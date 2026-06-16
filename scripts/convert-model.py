#!/usr/bin/env python3
"""
Convert MayZhou/e5-small-lora-ai-generated-detector (HF) to Core ML for macOS.

Usage:
    python3.11 -m venv /tmp/aicf-convert-venv
    /tmp/aicf-convert-venv/bin/pip install "torch==2.7.0" "transformers==4.49.0" \
        "coremltools>=8" numpy safetensors
    /tmp/aicf-convert-venv/bin/python scripts/convert-model.py

Version pins matter: transformers 5.x BERT traces an aten::Int op that
coremltools 9.0 cannot convert; torch 2.7.0 is the newest release tested
against coremltools 9.0.

Produces in Models/:
    AITextClassifier.mlpackage        (ML Program, FP16, fixed seq len 256, macOS 14+)
    AITextClassifier-int8.mlpackage   (per-channel INT8 weight-quantized variant)
    AITextClassifier.mlmodelc, AITextClassifier-int8.mlmodelc (compiled via xcrun coremlcompiler)
    vocab.txt                         (WordPiece vocab for the tokenizer)
    model-info.json                   (metadata, parity diffs, latency, sample scores)

Inputs:  input_ids [1,256] int32, attention_mask [1,256] int32
Output:  probabilities [1,2] float32 (softmax; index 1 = AI-generated, verified empirically below)
"""

import json
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
from transformers import AutoModelForSequenceClassification, AutoTokenizer

import sys

# Usage: convert-model.py [model_dir_or_hf_repo] [output_subdir]
#   convert-model.py                                  # original checkpoint → Models/
#   convert-model.py out/merged-finetune              # your fine-tune → Models/
# The Stage-2 ModernBERT cascade model is built separately by
# scripts/convert-stage2-modernbert.py (BPE tokenizer, → Models/Stage2/).
REPO = sys.argv[1] if len(sys.argv) > 1 else "MayZhou/e5-small-lora-ai-generated-detector"
LICENSE = "mit"  # from HF repo metadata (license:mit tag)
SEQ_LEN = 256
ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = (ROOT / "Models" / sys.argv[2]) if len(sys.argv) > 2 else (ROOT / "Models")
MODELS_DIR.mkdir(exist_ok=True)

# ---------------------------------------------------------------- test texts
AI_TEXTS = [
    # 1: corporate AI boilerplate
    "In today's fast-paced world, it is important to note that leveraging cutting-edge solutions "
    "can seamlessly elevate your workflow and unlock unprecedented levels of productivity. Furthermore, "
    "by harnessing the power of innovative technologies, organizations can streamline their operations "
    "and foster a culture of continuous improvement. It is worth mentioning that these transformative "
    "approaches not only enhance efficiency but also empower teams to achieve their full potential. "
    "Moreover, embracing digital transformation is essential for staying competitive in an ever-evolving "
    "landscape. In conclusion, the integration of robust, scalable, and dynamic solutions paves the way "
    "for sustainable growth and long-term success. Additionally, stakeholders should prioritize "
    "data-driven decision-making processes to optimize outcomes and mitigate potential risks. "
    "By adopting a holistic approach, businesses can navigate the complexities of the modern marketplace "
    "with confidence and agility. Ultimately, the key takeaway is that proactive adaptation and strategic "
    "foresight are paramount to thriving in this dynamic environment. It is also crucial to recognize "
    "that collaboration and communication serve as the cornerstones of organizational excellence, "
    "enabling seamless synergy across departments and driving meaningful, measurable results that "
    "align with overarching strategic objectives and deliver exceptional value to all stakeholders involved.",
    # 2: generic AI essay
    "Artificial intelligence has emerged as a transformative force across numerous industries, "
    "fundamentally reshaping how we approach complex challenges. First and foremost, machine learning "
    "algorithms enable systems to identify patterns within vast datasets, thereby facilitating more "
    "informed decision-making processes. Moreover, the integration of natural language processing "
    "technologies has revolutionized human-computer interaction, allowing for more intuitive and "
    "seamless communication. It is essential to acknowledge that these advancements come with both "
    "opportunities and challenges. On one hand, automation can significantly enhance productivity and "
    "reduce operational costs. On the other hand, concerns regarding job displacement and ethical "
    "considerations must be carefully addressed. Furthermore, the responsible development of AI systems "
    "requires robust governance frameworks and transparent accountability mechanisms. Stakeholders "
    "across the public and private sectors must collaborate to establish comprehensive guidelines that "
    "balance innovation with societal wellbeing. In addition, ongoing research into explainable AI "
    "promises to enhance trust and understanding among end users. As we look toward the future, it is "
    "clear that artificial intelligence will continue to play an increasingly pivotal role in shaping "
    "our collective destiny. In conclusion, embracing these technologies thoughtfully and proactively "
    "will be essential for harnessing their full potential while mitigating associated risks and "
    "ensuring equitable outcomes for all members of society.",
    # 3: AI-style how-to listicle
    "Maintaining a healthy lifestyle is crucial for overall wellbeing, and there are several key "
    "strategies that can help you achieve this goal. Firstly, it is important to prioritize a balanced "
    "diet rich in fruits, vegetables, whole grains, and lean proteins. These nutrient-dense foods "
    "provide the essential vitamins and minerals your body needs to function optimally. Secondly, "
    "regular physical activity plays a vital role in maintaining cardiovascular health and managing "
    "stress levels. Experts recommend at least 150 minutes of moderate exercise per week, which can "
    "include activities such as brisk walking, swimming, or cycling. Additionally, adequate sleep is "
    "fundamental to physical and mental recovery; adults should aim for seven to nine hours of quality "
    "sleep each night. Furthermore, staying hydrated throughout the day supports digestion, circulation, "
    "and cognitive function. It is also worth noting that managing stress through mindfulness practices, "
    "such as meditation or deep breathing exercises, can significantly improve your quality of life. "
    "Moreover, building strong social connections and maintaining meaningful relationships contributes "
    "to emotional resilience and longevity. Finally, scheduling regular checkups with healthcare "
    "professionals ensures that potential health issues are identified and addressed early. By "
    "incorporating these evidence-based strategies into your daily routine, you can establish a solid "
    "foundation for long-term health and vitality, ultimately enhancing both the quality and duration "
    "of your life.",
]

HUMAN_TEXTS = [
    # 1: grocery store anecdote
    "So I was at the grocery store yesterday and you won't believe what happened. This guy in front "
    "of me had like forty cans of cat food and nothing else. Forty! I counted while waiting because the "
    "line wasn't moving at all. The cashier, she's this older lady who's always there on Tuesdays, just "
    "looked at him and goes \"rough week?\" and he didn't even crack a smile. Anyway, my card got declined "
    "the first time which was embarrassing, but it worked when she ran it again. Don't know what that was "
    "about. Oh and they were out of the bread I like, again. Third week in a row. I'm starting to think "
    "they just don't stock it anymore but the shelf tag is still there, which is annoying. Maybe I'll ask "
    "next time. Or not, I always feel weird bugging the staff about stuff like that. My sister says I "
    "should just order groceries online but honestly the delivery fees are a ripoff and half the time "
    "they substitute things with stuff you'd never buy. Last time they swapped almond milk for oat milk. "
    "Who does that? Not the same thing at all. Whatever, at least the cat's fed I guess.",
    # 2: car trouble rant
    "Ugh, my car's making that noise again. You know the one, kind of a grindy squeal when I brake "
    "downhill? Took it to Mike's shop back in March and he swore it was just dust on the rotors. Two "
    "hundred bucks to blow dust off, apparently. Now it's back and worse. My dad keeps saying I should've "
    "bought a Toyota instead but he's been saying that about every car I've owned since 2011 so whatever. "
    "The thing is, I actually need the car next weekend because Jess's wedding is out in Petaluma and "
    "there's no train that goes anywhere near it. I checked. Closest stop is like 25 minutes away and "
    "then what, a fifty dollar Uber? Each way? No thanks. So either I gamble on the brakes holding out, "
    "which, knowing my luck, no. Or I cough up for the repair now and eat ramen for two weeks. Honestly "
    "leaning toward the ramen option. Oh, and get this, when I called the shop this morning the guy who "
    "answered wasn't even Mike, it was some new kid who put me on hold for ten minutes and then hung up "
    "on me. Accidentally, he says. Called back and he did it AGAIN. I'm not even mad anymore, I'm "
    "impressed. Anyway if you know a decent mechanic around here, text me. Seriously.",
    # 3: childhood memory
    "We used to spend summers at my grandma's place out past the county line, and honestly half of what "
    "I remember is the smell. Cut grass and motor oil, because grandpa was always tinkering with that "
    "ancient tractor that never ran more than a week at a stretch. My cousin Danny and me would ride "
    "bikes down to the creek, the one behind the Hendersons' field, and catch crawdads in a coffee can. "
    "Got chased by their goose once. Twice, actually, but the second time barely counts because Danny "
    "claims he wasn't scared, he just happened to be running in the same direction as me. Sure, Danny. "
    "Grandma made this peach cobbler that I've tried to recreate maybe a dozen times and I can't get it "
    "right. I even called my aunt for the recipe and she sent me a photo of an index card that literally "
    "says \"peaches, sugar, the usual\" on it. Thanks a lot. The house got sold back in 2009 after grandpa "
    "passed. New owners tore out the porch swing, which kind of broke my heart when I drove by a few "
    "years ago. I get it, it was rickety and probably a lawsuit waiting to happen, but still. Some "
    "things you figure will just always be there, you know? Anyway, peach season's coming and I'm gonna "
    "try that cobbler again. Attempt thirteen. Lucky number, right?",
]


def tokenize(tok, text):
    enc = tok(text, return_tensors="np", truncation=True,
              max_length=SEQ_LEN, padding="max_length")
    return (enc["input_ids"].astype(np.int32),
            enc["attention_mask"].astype(np.int32))


def pytorch_probs(model, ids, mask):
    with torch.no_grad():
        logits = model(input_ids=torch.from_numpy(ids).long(),
                       attention_mask=torch.from_numpy(mask).long()).logits
    return torch.softmax(logits, dim=-1)[0].numpy()


def dir_size_mb(path):
    return round(sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file()) / (1024 * 1024), 2)


def main():
    print(f"== Loading {REPO}")
    tok = AutoTokenizer.from_pretrained(REPO)
    # eager attention: most robust path for torch.jit.trace -> Core ML conversion
    model = AutoModelForSequenceClassification.from_pretrained(REPO, attn_implementation="eager")
    model.eval()
    num_labels = model.config.num_labels
    param_count = sum(p.numel() for p in model.parameters())
    print(f"   num_labels={num_labels} id2label={model.config.id2label} params={param_count:,}")

    # FP16-safe additive attention mask. Stock BERT uses torch.finfo(fp32).min
    # (-3.4e38), which overflows to -inf under Core ML FP16 compute and turns
    # every prediction into NaN. -1e4 is representable in fp16 and numerically
    # identical after softmax (exp(-1e4) underflows to 0 either way).
    def _fp16_safe_extended_attention_mask(attention_mask, input_shape=None,
                                           device=None, dtype=None):
        ext = attention_mask[:, None, None, :].to(torch.float32)
        return (1.0 - ext) * -1e4

    model.bert.get_extended_attention_mask = _fp16_safe_extended_attention_mask

    # ---------------- determine which logit index means "AI-generated" -----
    ai_probe = pytorch_probs(model, *tokenize(tok, AI_TEXTS[0]))
    human_probe = pytorch_probs(model, *tokenize(tok, HUMAN_TEXTS[0]))
    ai_label_index = int(np.argmax(ai_probe))
    assert int(np.argmax(human_probe)) != ai_label_index, (
        f"Probe texts disagree: ai={ai_probe}, human={human_probe}")
    print(f"   ai_label_index={ai_label_index} (AI probe={ai_probe}, human probe={human_probe})")

    # ---------------- wrap + trace at fixed seq len 256 --------------------
    # NOTE: position_ids / token_type_ids are passed explicitly as constant
    # buffers. Letting BertEmbeddings derive them internally traces an
    # aten::Int op on a non-scalar that coremltools cannot convert
    # ("only 0-dimensional arrays can be converted to Python scalars").
    class Wrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
            self.register_buffer("position_ids",
                                 torch.arange(SEQ_LEN, dtype=torch.long).unsqueeze(0))
            self.register_buffer("token_type_ids",
                                 torch.zeros((1, SEQ_LEN), dtype=torch.long))

        def forward(self, input_ids, attention_mask):
            logits = self.m(input_ids=input_ids.to(torch.long),
                            attention_mask=attention_mask.to(torch.long),
                            token_type_ids=self.token_type_ids,
                            position_ids=self.position_ids).logits
            return torch.softmax(logits, dim=-1)

    wrapper = Wrapper(model).eval()
    ex_ids = torch.zeros((1, SEQ_LEN), dtype=torch.int32)
    ex_mask = torch.ones((1, SEQ_LEN), dtype=torch.int32)
    print("== Tracing")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ex_ids, ex_mask), strict=False)

    # ---------------- convert to Core ML (ML Program, FP16) ----------------
    print("== Converting to Core ML (FP16 ML Program, macOS 14)")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="probabilities", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = (
        f"AI-generated-text detector ({REPO}). "
        f"probabilities[{ai_label_index}] = P(AI-generated). seq_len={SEQ_LEN}.")
    fp16_path = MODELS_DIR / "AITextClassifier.mlpackage"
    if fp16_path.exists():
        shutil.rmtree(fp16_path)
    mlmodel.save(str(fp16_path))
    fp16_size = dir_size_mb(fp16_path)
    print(f"   saved {fp16_path} ({fp16_size} MB)")

    # ---------------- INT8 weight quantization ------------------------------
    print("== Quantizing weights to INT8 (per-channel)")
    opt_config = OptimizationConfig(global_config=OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    mlmodel_int8 = linear_quantize_weights(mlmodel, config=opt_config)
    int8_path = MODELS_DIR / "AITextClassifier-int8.mlpackage"
    if int8_path.exists():
        shutil.rmtree(int8_path)
    mlmodel_int8.save(str(int8_path))
    int8_size = dir_size_mb(int8_path)
    print(f"   saved {int8_path} ({int8_size} MB)")

    # ---------------- parity check (CPU_ONLY for determinism) --------------
    print("== Parity check (PyTorch vs Core ML, CPU_ONLY)")
    cm_fp16 = ct.models.MLModel(str(fp16_path), compute_units=ct.ComputeUnit.CPU_ONLY)
    cm_int8 = ct.models.MLModel(str(int8_path), compute_units=ct.ComputeUnit.CPU_ONLY)
    sample_scores = []
    diffs_fp16, diffs_int8 = [], []
    cases = [("ai", t) for t in AI_TEXTS] + [("human", t) for t in HUMAN_TEXTS]
    for kind, text in cases:
        ids, mask = tokenize(tok, text)
        pt = pytorch_probs(model, ids, mask)
        feed = {"input_ids": ids, "attention_mask": mask}
        cm_p = cm_fp16.predict(feed)["probabilities"][0]
        cm8_p = cm_int8.predict(feed)["probabilities"][0]
        diffs_fp16.append(float(np.max(np.abs(pt - cm_p))))
        diffs_int8.append(float(np.max(np.abs(pt - cm8_p))))
        sample_scores.append({
            "text_kind": kind,
            "pytorch_prob_ai": round(float(pt[ai_label_index]), 6),
            "coreml_prob_ai": round(float(cm_p[ai_label_index]), 6),
        })
        print(f"   {kind:6s} pt={pt[ai_label_index]:.4f} fp16={cm_p[ai_label_index]:.4f} "
              f"int8={cm8_p[ai_label_index]:.4f}")
    parity_fp16 = round(max(diffs_fp16), 6)
    parity_int8 = round(max(diffs_int8), 6)
    print(f"   max abs diff: fp16={parity_fp16} int8={parity_int8}")

    # ---------------- latency (compute_units=ALL) ---------------------------
    def benchmark(path):
        m = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
        ids, mask = tokenize(tok, AI_TEXTS[0])
        feed = {"input_ids": ids, "attention_mask": mask}
        for _ in range(5):
            m.predict(feed)
        times = []
        for _ in range(30):
            t0 = time.perf_counter()
            m.predict(feed)
            times.append((time.perf_counter() - t0) * 1000.0)
        return {"median": round(statistics.median(times), 2),
                "p90": round(float(np.percentile(times, 90)), 2)}

    print("== Latency (compute_units=ALL, 5 warmups, 30 runs)")
    lat_fp16 = benchmark(fp16_path)
    lat_int8 = benchmark(int8_path)
    print(f"   fp16: {lat_fp16}  int8: {lat_int8}")

    # ---------------- compile to .mlmodelc ----------------------------------
    print("== Compiling with coremlcompiler")
    for pkg in (fp16_path, int8_path):
        out = MODELS_DIR / (pkg.stem + ".mlmodelc")
        if out.exists():
            shutil.rmtree(out)
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(MODELS_DIR)],
                       check=True)
        # verify the compiled model loads and predicts
        cm = ct.models.CompiledMLModel(str(out), compute_units=ct.ComputeUnit.CPU_ONLY)
        ids, mask = tokenize(tok, HUMAN_TEXTS[0])
        p = cm.predict({"input_ids": ids, "attention_mask": mask})["probabilities"]
        print(f"   {out.name} loads OK, sample P(AI)={p[0][ai_label_index]:.4f}")

    # ---------------- tokenizer artifacts -----------------------------------
    with tempfile.TemporaryDirectory() as td:
        tok.save_pretrained(td)
        shutil.copy(Path(td) / "vocab.txt", MODELS_DIR / "vocab.txt")
    print(f"   copied vocab.txt ({(MODELS_DIR / 'vocab.txt').stat().st_size} bytes)")

    # ---------------- model-info.json ---------------------------------------
    info = {
        "source_repo": REPO,
        "license": LICENSE,
        "architecture": model.config.model_type + " (e5-small, BERT encoder, 12 layers, hidden 384)",
        "param_count_estimate": param_count,
        "seq_len": SEQ_LEN,
        "ai_label_index": ai_label_index,
        "num_labels": num_labels,
        "do_lower_case": bool(getattr(tok, "do_lower_case", True)),
        "special_token_ids": {
            "cls": {"token": tok.cls_token, "id": tok.cls_token_id},
            "sep": {"token": tok.sep_token, "id": tok.sep_token_id},
            "pad": {"token": tok.pad_token, "id": tok.pad_token_id},
            "unk": {"token": tok.unk_token, "id": tok.unk_token_id},
        },
        # tokenizer_config.json ships the "unset" sentinel (~1e30) for
        # model_max_length; the real positional limit is the encoder's
        # max_position_embeddings (512). Record both honestly.
        "model_max_length": (tok.model_max_length
                             if tok.model_max_length < 10**12
                             else None),
        "model_max_length_note": ("tokenizer_config.json has the unset sentinel (1e30); "
                                  "effective limit is max_position_embeddings="
                                  f"{model.config.max_position_embeddings}, "
                                  f"this export uses fixed seq_len={SEQ_LEN}"),
        "fp16_size_mb": fp16_size,
        "int8_size_mb": int8_size,
        "parity_max_abs_diff_fp16": parity_fp16,
        "parity_max_abs_diff_int8": parity_int8,
        "latency_ms_fp16": lat_fp16,
        "latency_ms_int8": lat_int8,
        "sample_scores": sample_scores,
    }
    info_path = MODELS_DIR / "model-info.json"
    info_path.write_text(json.dumps(info, indent=2) + "\n")
    print(f"== Wrote {info_path}")
    print(json.dumps(info, indent=2))


if __name__ == "__main__":
    main()
