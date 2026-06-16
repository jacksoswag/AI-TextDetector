#!/usr/bin/env python3
r"""
build-corpus.py — FRAMEWORK for a fresh, labeled AI-vs-human corpus that feeds
scripts/finetune-lora.py (small model) and any Stage-2 retraining.

Why this exists
---------------
Every shipped open detector is trained on <=2024 generations, and the cascade's
stylometry override only reopens the gate for *lightly* disguised text. Catching
2025-26 prose and adversarially "humanized" text needs FRESH labeled data — and
the app cannot collect it itself: by privacy contract it stores no page text.
This script is the supply pipeline that turns models + human sources into the
`text,label` CSV the fine-tuner consumes.

This is a FRAMEWORK, honest about what is wired:
  * REAL, runnable today: human-source reader, the adversarial/humanizer
    transforms, class balancing, topic-held-out splitting, CSV writing.
  * STUBS you wire to your own models/keys (never embedded here): the AI text
    generators. The default runnable path imports AI text you generated
    elsewhere (JSONL); the Anthropic / command generators are examples.

Design that matters
-------------------
  * Cover the 7 routed registers (match FilterCore TextDomain) so the fine-tune
    sees every register the app routes.
  * Generate AI text from SEVERAL models (Claude, GPT, Gemini, local) — breadth
    beats one family. Mix in PARAPHRASED / humanized variants: those disguised
    positives are the whole point.
  * Split by TOPIC, not by row: hold out whole topics so the eval set measures
    generalization, not memorization.
  * Keep classes balanced.

Usage (bring-your-own-data path, no API keys):
  python3 scripts/build-corpus.py \
      --human-dir data/human \            # *.txt|*.jsonl, label 0 (see --help)
      --ai-jsonl data/ai_generated.jsonl \# {"text":..,"domain":..,"topic":..}
      --augment homoglyph,whitespace,casing \
      --out-dir data/corpus               # writes train.csv, eval.csv

Then:
  python3 scripts/finetune-lora.py --train data/corpus/train.csv --eval data/corpus/eval.csv
  python3 scripts/measure-gate.py --data data/corpus/eval.csv   # see the gate distribution

Wiring a generator (example): set ANTHROPIC_API_KEY and `pip install anthropic`,
then `--generate anthropic --per-domain 200`. Implement OpenAI/Gemini the same
way against their SDKs. Always generate from more than one model.
"""

import argparse
import csv
import json
import os
import random
import sys
from collections import defaultdict
from pathlib import Path

# Match FilterCore/Sources/FilterCore/Detection/TextDomain.swift so the corpus
# spans exactly the registers the app routes.
DOMAINS = ["conversation", "academic", "news", "social", "marketing", "technical", "creative"]

# Seed instructions per register, used by model generators. Kept terse on
# purpose — vary them and add topics to avoid a monotone generation style.
DOMAIN_PROMPTS = {
    "conversation": "Reply casually, first person, like a real chat message about: {topic}",
    "academic":     "Write a dense, formal academic paragraph about: {topic}",
    "news":         "Write a neutral news paragraph reporting on: {topic}",
    "social":       "Write a short social-media post (informal, emoji ok) about: {topic}",
    "marketing":    "Write upbeat marketing copy promoting: {topic}",
    "technical":    "Write a precise technical/how-to paragraph about: {topic}",
    "creative":     "Write a short vivid piece of creative prose about: {topic}",
}


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #
class Sample:
    __slots__ = ("text", "label", "domain", "topic", "tag")

    def __init__(self, text, label, domain="", topic="", tag="raw"):
        self.text = " ".join(text.split())   # collapse whitespace; keep it one line for CSV
        self.label = int(label)              # 1 = AI, 0 = human
        self.domain = domain
        self.topic = topic or domain         # topic is the held-out unit
        self.tag = tag                       # provenance of this row (model/source/transform)


# --------------------------------------------------------------------------- #
# Human sources (REAL)
# --------------------------------------------------------------------------- #
def read_human_dir(root: Path):
    """Read human text. Each *.txt is one sample (filename stem = topic, parent
    dir = domain if it is one of DOMAINS). Each *.jsonl row may carry
    {"text","domain","topic"}. Label is always 0."""
    samples = []
    if not root or not root.exists():
        return samples
    for path in sorted(root.rglob("*")):
        if path.suffix == ".txt":
            domain = path.parent.name if path.parent.name in DOMAINS else ""
            text = path.read_text(encoding="utf-8", errors="ignore")
            if len(text.split()) >= 40:
                samples.append(Sample(text, 0, domain, path.stem, tag="human:file"))
        elif path.suffix == ".jsonl":
            for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if not line:
                    continue
                row = json.loads(line)
                t = (row.get("text") or "").strip()
                if len(t.split()) >= 40:
                    samples.append(Sample(t, 0, row.get("domain", ""),
                                          row.get("topic", ""), tag="human:jsonl"))
    return samples


def read_ai_jsonl(path: Path):
    """Import AI text generated elsewhere. Rows: {"text","domain","topic","model"}."""
    samples = []
    if not path or not path.exists():
        return samples
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        t = (row.get("text") or "").strip()
        if len(t.split()) >= 40:
            samples.append(Sample(t, 1, row.get("domain", ""), row.get("topic", ""),
                                  tag="ai:" + row.get("model", "import")))
    return samples


# --------------------------------------------------------------------------- #
# AI generators (STUBS / examples — wire your own; keys come from the env)
# --------------------------------------------------------------------------- #
def topics_for(domain, n):
    """Stand-in topic list. Replace with a real topic bank (e.g. fresh news
    headlines, Wikipedia titles, product names) so generations are diverse and
    genuinely 2025-26."""
    return [f"{domain} subject {i}" for i in range(n)]


def generate_anthropic(per_domain, model="claude-sonnet-4-6"):
    """EXAMPLE generator. Requires `pip install anthropic` and ANTHROPIC_API_KEY.
    Generate from MORE THAN ONE model in practice — breadth is the point."""
    try:
        import anthropic
    except ImportError:
        sys.exit("`pip install anthropic` to use --generate anthropic")
    if not os.environ.get("ANTHROPIC_API_KEY"):
        sys.exit("set ANTHROPIC_API_KEY in your environment (never hard-code keys)")
    client = anthropic.Anthropic()
    out = []
    for domain in DOMAINS:
        for topic in topics_for(domain, per_domain):
            prompt = DOMAIN_PROMPTS[domain].format(topic=topic)
            msg = client.messages.create(
                model=model, max_tokens=400,
                messages=[{"role": "user", "content": prompt}])
            text = "".join(b.text for b in msg.content if getattr(b, "type", "") == "text")
            if text.strip():
                out.append(Sample(text, 1, domain, topic, tag=f"ai:{model}"))
    return out


def generate_command(per_domain, command):
    """Generic generator: pipe each prompt to an external command's stdin and
    read its stdout (e.g. a local llama.cpp / ollama wrapper). Model-agnostic."""
    import subprocess
    out = []
    for domain in DOMAINS:
        for topic in topics_for(domain, per_domain):
            prompt = DOMAIN_PROMPTS[domain].format(topic=topic)
            res = subprocess.run(command, input=prompt, capture_output=True,
                                 text=True, shell=True)
            text = res.stdout.strip()
            if text:
                out.append(Sample(text, 1, domain, topic, tag="ai:command"))
    return out


# --------------------------------------------------------------------------- #
# Adversarial / humanizer transforms (REAL, except paraphrase)
# --------------------------------------------------------------------------- #
# These run on AI text (label stays 1) to mint *disguised* positives — the
# exact distribution the detector is currently blind to. Mirrors RAID-style
# attacks (homoglyph, whitespace) plus light register noise.

_HOMOGLYPHS = {  # Latin -> confusable Cyrillic/Greek
    "a": "а", "e": "е", "o": "о", "p": "р",
    "c": "с", "x": "х", "y": "у", "i": "і",
}


def t_homoglyph(text, rng, rate=0.08):
    return "".join(_HOMOGLYPHS[ch] if (ch in _HOMOGLYPHS and rng.random() < rate) else ch
                   for ch in text)


def t_whitespace(text, rng, rate=0.05):
    """Insert zero-width spaces between words — the same trick the Swift
    HiddenCharacterScanner flags. Teaches the model these are AI-adjacent."""
    words = text.split(" ")
    return " ".join(w + ("​" if rng.random() < rate else "") for w in words)


def t_casing(text, rng, rate=0.03):
    return "".join(ch.upper() if (ch.islower() and rng.random() < rate) else ch for ch in text)


def t_paraphrase(text, rng, rate=0.0):
    """STUB. The strongest humanizer attack — rewrite while preserving meaning —
    needs a model. Wire a paraphrase model (or a humanizer API) here; it is the
    single most valuable transform to make real, because it defeats stylometry.
    Returns text unchanged so the pipeline still runs without it."""
    return text


TRANSFORMS = {
    "homoglyph": t_homoglyph,
    "whitespace": t_whitespace,
    "casing": t_casing,
    "paraphrase": t_paraphrase,   # stub until you wire a model
}


def augment(samples, names, rng):
    """Append a transformed copy of each AI sample for every requested transform.
    Human samples are never transformed (they are already real)."""
    if not names:
        return samples
    extra = []
    for s in samples:
        if s.label != 1:
            continue
        for name in names:
            fn = TRANSFORMS[name]
            extra.append(Sample(fn(s.text, rng), 1, s.domain, s.topic, tag=f"{s.tag}+{name}"))
    return samples + extra


# --------------------------------------------------------------------------- #
# Balance + topic-held-out split
# --------------------------------------------------------------------------- #
def balance(samples, rng):
    ai = [s for s in samples if s.label == 1]
    hu = [s for s in samples if s.label == 0]
    n = min(len(ai), len(hu))
    if n == 0:
        sys.exit(f"need both classes: have {len(ai)} AI, {len(hu)} human")
    rng.shuffle(ai); rng.shuffle(hu)
    dropped = abs(len(ai) - len(hu))
    if dropped:
        print(f"[balance] trimming {dropped} from the majority class to {n}/{n}")
    return ai[:n] + hu[:n]


def split_by_topic(samples, eval_frac, rng):
    """Hold out WHOLE topics for eval so no topic leaks across the split."""
    topics = sorted({s.topic for s in samples})
    rng.shuffle(topics)
    n_eval = max(1, int(len(topics) * eval_frac))
    eval_topics = set(topics[:n_eval])
    train = [s for s in samples if s.topic not in eval_topics]
    ev = [s for s in samples if s.topic in eval_topics]
    return train, ev


def write_csv(path: Path, samples):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["text", "label"])
        for s in samples:
            w.writerow([s.text, s.label])


def report(name, samples):
    by_domain = defaultdict(lambda: [0, 0])
    for s in samples:
        by_domain[s.domain or "?"][s.label] += 1
    ai = sum(1 for s in samples if s.label == 1)
    print(f"[{name}] {len(samples)} rows  AI={ai} human={len(samples)-ai}")
    for d in sorted(by_domain):
        h, a = by_domain[d]
        print(f"        {d:13s} AI={a:5d} human={h:5d}")


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Build a labeled AI-vs-human corpus.")
    ap.add_argument("--human-dir", type=Path, help="dir of *.txt / *.jsonl human text (label 0)")
    ap.add_argument("--ai-jsonl", type=Path, help="pre-generated AI text JSONL (label 1)")
    ap.add_argument("--generate", choices=["anthropic", "command"], help="generate AI text live")
    ap.add_argument("--per-domain", type=int, default=100, help="generations per domain")
    ap.add_argument("--gen-command", help="shell command for --generate command")
    ap.add_argument("--model", default="claude-sonnet-4-6", help="model id for --generate anthropic")
    ap.add_argument("--augment", default="", help="comma list: " + ",".join(TRANSFORMS))
    ap.add_argument("--eval-frac", type=float, default=0.15)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out-dir", type=Path, default=Path("data/corpus"))
    args = ap.parse_args()
    rng = random.Random(args.seed)

    samples = []
    samples += read_human_dir(args.human_dir)
    samples += read_ai_jsonl(args.ai_jsonl)
    if args.generate == "anthropic":
        samples += generate_anthropic(args.per_domain, args.model)
    elif args.generate == "command":
        if not args.gen_command:
            sys.exit("--generate command needs --gen-command")
        samples += generate_command(args.per_domain, args.gen_command)

    if not samples:
        sys.exit("no input — pass --human-dir and (--ai-jsonl or --generate). See --help.")

    names = [n.strip() for n in args.augment.split(",") if n.strip()]
    for n in names:
        if n not in TRANSFORMS:
            sys.exit(f"unknown transform {n!r}; choices: {', '.join(TRANSFORMS)}")
    samples = augment(samples, names, rng)

    samples = balance(samples, rng)
    train, ev = split_by_topic(samples, args.eval_frac, rng)
    write_csv(args.out_dir / "train.csv", train)
    write_csv(args.out_dir / "eval.csv", ev)

    report("train", train)
    report("eval", ev)
    print(f"\nwrote {args.out_dir}/train.csv and {args.out_dir}/eval.csv")
    if "paraphrase" not in names:
        print("note: the paraphrase transform is a stub — wire a model to mint the "
              "hardest disguised positives (it defeats stylometry).")


if __name__ == "__main__":
    main()
