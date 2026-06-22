#!/usr/bin/env python3
r"""
audit-confound.py — measure how much a corpus lets a detector CHEAT instead of
learning authorship. It quantifies the "Lincoln/Austen" failure at its root:
when the label is correlated with source / register / length, a model can score
high by memorizing the dataset, then collapses on out-of-distribution humans.

What it reports
---------------
1. METADATA-ONLY CHEAT: the accuracy a classifier reaches using ONLY a metadata
   column (source, register, length-bucket) and ZERO text — i.e. by predicting
   the majority label within each group. If "source-only" is near your real model
   accuracy, your model is probably fingerprinting the dataset, not detecting AI.
2. Per-source / per-register label balance, with a ⚠ on any group that is >LOPSIDED
   (default 0.65) one class — those are the leak channels.
3. LENGTH confound: mean/median words per class.
4. (optional, needs scikit-learn) a TF-IDF + logistic-regression text probe with
   per-source false-positive rate, to see where a real text model over-fires.
5. (optional, needs torch+transformers, --model) the FALSE-POSITIVE RATE of an
   actual detector on an all-human file (use it with --ood data/corpus/ood_human.csv
   to gate releases on the Lincoln/Austen set).

Usage:
    python3 scripts/audit-confound.py --data data/corpus/train.csv
    python3 scripts/audit-confound.py --data data/corpus/train.csv data/corpus/eval.csv
    python3 scripts/audit-confound.py --ood data/corpus/ood_human.csv \
        --model MayZhou/e5-small-lora-ai-generated-detector      # FPR gate

Columns expected: text,label[,source,register,words]. label 1=AI, 0=human.
"""

import argparse
import csv
import re
import statistics
import sys
from collections import defaultdict

csv.field_size_limit(10_000_000)


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            text = (r.get("text") or "").strip()
            try:
                label = int(r.get("label"))
            except (TypeError, ValueError):
                continue
            if not text or label not in (0, 1):
                continue
            words = r.get("words")
            try:
                words = int(words)
            except (TypeError, ValueError):
                words = len(text.split())
            rows.append({
                "text": text, "label": label,
                "source": (r.get("source") or "?").strip() or "?",
                "register": (r.get("register") or "?").strip() or "?",
                "words": words,
            })
    return rows


def length_bucket(w):
    for hi in (75, 125, 175, 225, 300):
        if w <= hi:
            return f"<= {hi}"
    return "> 300"


def cheat_accuracy(rows, key):
    """Max accuracy achievable from this metadata column alone: within each group,
    a cheater predicts the group's majority label. Returns (acc, baseline, table)."""
    groups = defaultdict(lambda: [0, 0])  # value -> [human, ai]
    for r in rows:
        groups[r[key] if isinstance(key, str) else key(r)][r["label"]] += 1
    correct = sum(max(h, a) for h, a in groups.values())
    total = sum(h + a for h, a in groups.values())
    # majority-class baseline (no metadata at all)
    tot_h = sum(h for h, a in groups.values())
    tot_a = sum(a for h, a in groups.values())
    baseline = max(tot_h, tot_a) / total if total else 0
    return correct / total if total else 0, baseline, groups


def print_group_table(name, groups, lopsided):
    print(f"\n  {name:14s} {'human':>7s} {'AI':>7s} {'total':>7s}  {'AI%':>5s}")
    for g in sorted(groups, key=lambda k: -sum(groups[k])):
        h, a = groups[g]
        tot = h + a
        frac = a / tot if tot else 0
        flag = "  ⚠ leak" if tot >= 10 and (frac >= lopsided or frac <= 1 - lopsided) else ""
        print(f"  {str(g)[:14]:14s} {h:7d} {a:7d} {tot:7d}  {frac*100:4.0f}%{flag}")


def _feature_values(text):
    """Surface features a detector could exploit instead of authorship. Regex proxies,
    no NER dependency. Numeric density is the v1 confound; the rest are the usual
    suspects (entity density, length, sentence-length burstiness, formatting, contractions)."""
    w = max(1, len(text.split()))
    digits = len(re.findall(r"\d", text))
    money = len(re.findall(r"[$%]", text))
    caps = len(re.findall(r"\b[A-Z][a-z]{2,}", text))            # proper-noun proxy
    sents = [len(s.split()) for s in re.split(r"[.!?]+", text) if s.split()]
    burst = (statistics.pstdev(sents) / (sum(sents) / len(sents))) if len(sents) > 1 and sum(sents) else 0.0
    fmt = len(re.findall(r"[*_`#>•–—]", text))         # markdown / bullets / dashes
    contr = len(re.findall(r"\b\w+['’](?:t|re|ll|ve|s|d|m)\b", text, re.I))
    return {"num_density": (digits + money) / w * 100, "entity_density": caps / w * 100,
            "length": float(w), "burstiness": burst,
            "format_density": fmt / w * 100, "contraction": contr / w * 100}


def _best_threshold_acc(pairs):
    """Max accuracy a 1-feature classifier reaches from this scalar alone (best split,
    either direction). The gap above baseline is free 'cheat' from that surface feature."""
    pairs = sorted(pairs, key=lambda x: x[0])
    n = len(pairs)
    if n == 0:
        return 0.0
    ai = sum(l for _, l in pairs)
    best = max(ai, n - ai) / n
    a_below = h_below = 0
    for i, (v, lab) in enumerate(pairs):
        a_below += (lab == 1)
        h_below += (lab == 0)
        # only a valid threshold at a real value boundary — never split between ties,
        # or a mostly-constant feature (e.g. sparse dashes) falsely reads ~100%
        if i + 1 < n and pairs[i + 1][0] == v:
            continue
        a_above, h_above = ai - a_below, (n - ai) - h_below
        best = max(best, (h_below + a_above) / n, (a_below + h_above) / n)
    return best


def feature_probes(rows):
    """Per-feature one-classifier cheat: train a trivial threshold on each surface feature
    alone. Anything far above the majority baseline is a confound to neutralize (the v2
    deconfound gate), not just register/source."""
    feats = ["num_density", "entity_density", "length", "burstiness", "format_density", "contraction"]
    fv = [(_feature_values(r["text"]), r["label"]) for r in rows]
    base = max(sum(1 for _, l in fv if l == 0), sum(1 for _, l in fv if l == 1)) / max(1, len(fv))
    print(f"\n  SURFACE-FEATURE cheat (1-feature best-threshold classifier; baseline {base*100:.1f}%):")
    for f in feats:
        acc = _best_threshold_acc([(d[f], l) for d, l in fv])
        flag = "  ⚠ confound" if acc - base > 0.05 else ""
        print(f"    {f:16s} {acc*100:5.1f}%{flag}")
    print("    (a feature far above baseline is a shortcut the model can learn instead of authorship)")


def text_probe(rows, eval_rows=None):
    """TF-IDF + logistic regression. In-sample if no eval_rows; reports overall
    acc and per-source FPR. Optional (needs scikit-learn)."""
    try:
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.linear_model import LogisticRegression
    except ImportError:
        print("\n[text-probe] scikit-learn not installed — skipping "
              "(pip install scikit-learn to enable).", file=sys.stderr)
        return
    tr = rows
    ev = eval_rows or rows
    vec = TfidfVectorizer(max_features=40000, ngram_range=(1, 2), min_df=2)
    Xtr = vec.fit_transform([r["text"] for r in tr])
    ytr = [r["label"] for r in tr]
    clf = LogisticRegression(max_iter=1000, C=4.0)
    clf.fit(Xtr, ytr)
    Xev = vec.transform([r["text"] for r in ev])
    pred = clf.predict(Xev)
    tag = "in-sample (overfit upper bound)" if eval_rows is None else "held-out"
    acc = sum(int(p == r["label"]) for p, r in zip(pred, ev)) / len(ev)
    fp = defaultdict(lambda: [0, 0])  # source -> [false_pos, humans]
    for p, r in zip(pred, ev):
        if r["label"] == 0:
            fp[r["source"]][1] += 1
            if p == 1:
                fp[r["source"]][0] += 1
    print(f"\n[text-probe] TF-IDF+LogReg accuracy ({tag}): {acc:.3f}")
    print("  per-source FALSE-POSITIVE rate (human flagged AI):")
    for s in sorted(fp):
        f, h = fp[s]
        if h:
            print(f"    {s[:16]:16s} {f}/{h}  = {f/h*100:4.0f}%")


def model_fpr(path, model_name, seq=256, batch=16):
    """False-positive rate of a real HF detector on an all-human file. Handles
    binary (human/AI) and multi-class (e.g. human/mixed/ai) heads: a false
    positive = the model predicts ANYTHING other than 'human'."""
    try:
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError:
        sys.exit("--model needs torch+transformers (pip install torch transformers).")
    rows = load(path)
    humans = [r for r in rows if r["label"] == 0]
    if not humans:
        sys.exit(f"{path} has no human (label 0) rows.")
    dev = ("mps" if torch.backends.mps.is_available()
           else "cuda" if torch.cuda.is_available() else "cpu")
    tok = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForSequenceClassification.from_pretrained(model_name).to(dev).eval()
    # locate the 'human' class index from the label map (default 0)
    id2label = {int(k): str(v) for k, v in (model.config.id2label or {}).items()}
    human_idx = next((i for i, name in id2label.items() if "human" in name.lower()), 0)
    classes = ", ".join(f"{i}={id2label.get(i, i)}" for i in sorted(id2label)) or "0=human,1=ai"
    fp = defaultdict(lambda: [0, 0])  # register -> [false_pos, total]
    flagged = 0
    pred_breakdown = defaultdict(int)
    with torch.no_grad():
        for i in range(0, len(humans), batch):
            chunk = humans[i:i + batch]
            enc = tok([r["text"] for r in chunk], truncation=True, max_length=seq,
                      padding=True, return_tensors="pt").to(dev)
            preds = torch.softmax(model(**enc).logits, dim=-1).argmax(dim=-1).cpu().tolist()
            for r, pred in zip(chunk, preds):
                is_fp = pred != human_idx
                flagged += int(is_fp)
                if is_fp:
                    pred_breakdown[id2label.get(pred, str(pred))] += 1
                fp[r["register"]][1] += 1
                fp[r["register"]][0] += int(is_fp)
    print(f"\n[model-FPR] {model_name}   (classes: {classes}; 'human'=idx {human_idx})")
    print(f"  overall false-positive rate on {len(humans)} human rows "
          f"(predicted NOT human): {flagged}/{len(humans)} = {flagged/len(humans)*100:.1f}%")
    if pred_breakdown:
        print("  what it called them instead: "
              + ", ".join(f"{k}={v}" for k, v in sorted(pred_breakdown.items())))
    print("  by register (these are the failures to fix):")
    for reg in sorted(fp, key=lambda k: -fp[k][0] / max(1, fp[k][1])):
        f, t = fp[reg]
        print(f"    {reg[:18]:18s} {f}/{t}  = {f/t*100:4.0f}%")


def model_crossgen(path, model_name, seq=256, batch=16):
    """Per-GENERATOR recall (+ human FPR) of a detector on a held-out labeled file.
    Measures whether the detector catches AI from generators it never trained on
    (GPT-4o, Llama, Mixtral, ...). AI hit = predicted anything other than 'human'."""
    try:
        import torch
        from transformers import AutoModelForSequenceClassification, AutoTokenizer
    except ImportError:
        sys.exit("--model needs torch+transformers (pip install torch transformers).")
    rows = load(path)
    dev = ("mps" if torch.backends.mps.is_available()
           else "cuda" if torch.cuda.is_available() else "cpu")
    tok = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForSequenceClassification.from_pretrained(model_name).to(dev).eval()
    id2label = {int(k): str(v) for k, v in (model.config.id2label or {}).items()}
    human_idx = next((i for i, name in id2label.items() if "human" in name.lower()), 0)
    preds = []
    with torch.no_grad():
        for i in range(0, len(rows), batch):
            chunk = rows[i:i + batch]
            enc = tok([r["text"] for r in chunk], truncation=True, max_length=seq,
                      padding=True, return_tensors="pt").to(dev)
            p = torch.softmax(model(**enc).logits, dim=-1).argmax(dim=-1).cpu().tolist()
            preds.extend(p)
    gen = defaultdict(lambda: [0, 0])      # generator -> [caught_AI, total_AI]
    fp = [0, 0]                            # [human_false_pos, total_human]
    for r, pred in zip(rows, preds):
        if r["label"] == 1:
            g = r.get("generator", "?") or "?"
            gen[g][1] += 1
            gen[g][0] += int(pred != human_idx)
        else:
            fp[1] += 1
            fp[0] += int(pred != human_idx)
    caught = sum(c for c, _ in gen.values()); total = sum(t for _, t in gen.values())
    print(f"\n[cross-gen] {model_name}   (held-out file: {path})")
    print(f"  overall AI recall: {caught}/{total} = {caught/max(1,total)*100:.1f}%")
    if fp[1]:
        print(f"  human FPR on this file: {fp[0]}/{fp[1]} = {fp[0]/fp[1]*100:.1f}%")
    print("  recall by generator (the unseen-generator generalization test):")
    for g in sorted(gen, key=lambda k: gen[k][0] / max(1, gen[k][1])):
        c, t = gen[g]
        print(f"    {g[:28]:28s} {c}/{t}  = {c/max(1,t)*100:4.0f}%")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", nargs="*", default=[],
                    help="corpus CSV(s) to audit for the source/register/length confound")
    ap.add_argument("--ood", default=None,
                    help="all-human OOD file for the model false-positive gate")
    ap.add_argument("--model", default=None,
                    help="HF detector id/path to measure FPR on --ood (or --data)")
    ap.add_argument("--lopsided", type=float, default=0.65,
                    help="flag a group as a leak if its AI fraction is >= this or <= 1-this")
    ap.add_argument("--probe", action="store_true",
                    help="also run the TF-IDF text probe (needs scikit-learn)")
    ap.add_argument("--crossgen", default=None,
                    help="held-out labeled CSV: report per-generator recall + human FPR (needs --model)")
    args = ap.parse_args()

    for path in args.data:
        rows = load(path)
        if not rows:
            print(f"\n===== {path}: no usable rows =====")
            continue
        n = len(rows)
        ai = sum(r["label"] for r in rows)
        print(f"\n{'='*64}\n{path}\n{'='*64}")
        print(f"rows={n}  human={n-ai}  AI={ai}  (AI {ai/n*100:.0f}%)")

        src_acc, base, src_groups = cheat_accuracy(rows, "source")
        reg_acc, _, reg_groups = cheat_accuracy(rows, "register")
        len_acc, _, len_groups = cheat_accuracy(rows, lambda r: length_bucket(r["words"]))
        print(f"\n  CHEAT ACCURACY (no text, metadata column only):")
        print(f"    majority-class baseline : {base*100:5.1f}%   (always guess the bigger class)")
        print(f"    source  alone           : {src_acc*100:5.1f}%   "
              f"{'  ← shortcut!' if src_acc - base > 0.10 else ''}")
        print(f"    register alone          : {reg_acc*100:5.1f}%   "
              f"{'  ← shortcut!' if reg_acc - base > 0.10 else ''}")
        print(f"    length-bucket alone     : {len_acc*100:5.1f}%   "
              f"{'  ← shortcut!' if len_acc - base > 0.10 else ''}")
        print("    (the gap above baseline is free accuracy a model gets WITHOUT reading the text)")
        # Honesty note: source-cheat only signals a real confound when sources are
        # MIXED-label (the old corpus). In a matched-pair corpus where AI rows carry
        # their own source name, source is single-label and source-cheat is ~100% BY
        # CONSTRUCTION — the model never sees that column. Judge deconfounding by the
        # REGISTER cheat and the --probe text classifier, not by source/generator.
        single = all(min(h, a) == 0 for h, a in src_groups.values())
        if single and src_acc > 0.95:
            print("    NOTE: every source is single-label (matched-pair style) → source-cheat is "
                  "structural, not a leak. Judge by REGISTER cheat + --probe.")

        print_group_table("source", src_groups, args.lopsided)
        print_group_table("register", reg_groups, args.lopsided)

        wh = [r["words"] for r in rows if r["label"] == 0]
        wa = [r["words"] for r in rows if r["label"] == 1]
        if wh and wa:
            print(f"\n  LENGTH: human median={statistics.median(wh):.0f} mean={statistics.mean(wh):.0f}"
                  f" | AI median={statistics.median(wa):.0f} mean={statistics.mean(wa):.0f}"
                  f"{'   ⚠ length confound' if abs(statistics.median(wh)-statistics.median(wa)) > 40 else ''}")

        feature_probes(rows)
        if args.probe:
            text_probe(rows)

    if args.model and args.crossgen:
        model_crossgen(args.crossgen, args.model)
    elif args.model:
        model_fpr(args.ood or (args.data[0] if args.data else None), args.model)


if __name__ == "__main__":
    main()
