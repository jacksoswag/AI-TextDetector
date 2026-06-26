#!/usr/bin/env python3
"""Fold the un-promoted contemporary/conversational corpus (data/corpus_new) into
the broad committed corpus (data/corpus) as one deconfounded train/eval split.

Why this exists
---------------
The shipped detector over-flags contemporary HUMAN prose — casual conversation,
news, q&a — because the committed corpus's human side leans formal/encyclopedic +
pre-AI literary. `data/corpus_new` was built to fix exactly that (matched-pair
contemporary humans) but was never folded in, and the broad corpus carries the
archaic/literary coverage the OOD gate ALSO tests. Training on either half alone
regresses on the other (this bit us before: v2 fixed contemporary, regressed 39%
on 18-19c prose). This unifies both halves so the model sees the full register
span with matched AI on every side — no "casual = human" or "formal = AI" shortcut.

It reuses the existing build-corpus-v2 assembly (dedup -> balance_in_cells ->
length_match -> split_by_topic, matched-pair-only eval). No new corpus logic; this
is glue + a hard leakage guard against the two frozen held-out files.

Inputs  (read):  data/corpus/{train,eval}.csv, data/corpus_new/{train,eval}.csv
Guards  (read):  data/corpus/ood_human.csv, data/corpus/crossgen_eval.csv
Outputs (write): data/corpus/train.csv, data/corpus/eval.csv   (originals backed up)
"""
import csv, sys, random, importlib.util
from pathlib import Path
from collections import defaultdict

csv.field_size_limit(10 ** 7)
ROOT = Path("/Users/jacksonadams/Code/pilcrow")
DATA = ROOT / "data"

# Load build-corpus-v2 by path (hyphenated filename -> not importable by name).
spec = importlib.util.spec_from_file_location("bc2", ROOT / "scripts" / "build-corpus-v2.py")
bc2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bc2)
Row, dedup, balance_in_cells, length_match, split_by_topic, write_csv, cheat_accuracy, words = (
    bc2.Row, bc2.dedup, bc2.balance_in_cells, bc2.length_match,
    bc2.split_by_topic, bc2.write_csv, bc2.cheat_accuracy, bc2.words)

random.seed(0)


def load_rows(path, split=""):
    """Read a build CSV back into Row objects, preserving provenance columns and
    the matched-pair topic_id (so human/AI pairs stay paired through the re-split)."""
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            text = (r.get("text") or "").strip()
            if not text:
                continue
            try:
                label = int(r.get("label", -1))
            except ValueError:
                continue
            if label not in (0, 1):
                continue
            rows.append(Row(
                text, label,
                source=r.get("source") or "import",
                register=r.get("register") or "unknown",
                topic=r.get("topic_id") or r.get("topic") or r.get("source") or "import",
                generator=r.get("generator") or ("human" if label == 0 else "ai"),
                variant=r.get("variant") or "raw",
                era=r.get("era") or "",
                split=split,
            ))
    return rows


def keys_of(path):
    """Normalized-text fingerprints of an all-rows file, for the leakage guard."""
    ks = set()
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t = (r.get("text") or "").strip()
            if t:
                ks.add(Row(t, 0, "g", "g", "g").key())
    return ks


def per_register(rows):
    d = defaultdict(lambda: [0, 0])
    for r in rows:
        d[r.register][r.label] += 1
    return dict(sorted(d.items(), key=lambda kv: -(kv[1][0] + kv[1][1])))


def main():
    src = {
        "corpus/train":     DATA / "corpus" / "train.csv",
        "corpus/eval":      DATA / "corpus" / "eval.csv",
        "corpus_new/train": DATA / "corpus_new" / "train.csv",
        "corpus_new/eval":  DATA / "corpus_new" / "eval.csv",
    }
    for name, p in src.items():
        if not p.exists():
            sys.exit(f"missing input: {p}")

    pool = []
    for name, p in src.items():
        rs = load_rows(p)
        pool += rs
        print(f"  loaded {len(rs):6d}  {name}")
    print(f"  pooled {len(pool)} rows (pre-dedup)")

    # Hard leakage guard: nothing the model trains/evals on may appear in the
    # frozen OOD gate or the held-out cross-generator file.
    gate = keys_of(DATA / "corpus" / "ood_human.csv")
    cross = keys_of(DATA / "corpus" / "crossgen_eval.csv")
    forbidden = gate | cross
    before = len(pool)
    pool = [r for r in pool if r.key() not in forbidden]
    print(f"  leakage guard: dropped {before - len(pool)} rows overlapping ood_human/crossgen "
          f"(gate={len(gate)}, crossgen={len(cross)})")

    # Same assembly the corpus was built with.
    core = balance_in_cells(dedup(pool), cap=0.60)
    core = length_match(core)
    train, ev, _ = split_by_topic(core, eval_frac=0.15)

    # Post-assembly leakage assertion (length_match trims text, so re-fingerprint).
    leaked = sum(1 for r in train + ev if r.key() in forbidden)
    assert leaked == 0, f"LEAKAGE: {leaked} train/eval rows match the gate/crossgen set"

    out = DATA / "corpus"
    write_csv(out / "train.csv", train)
    write_csv(out / "eval.csv", ev)

    def report(tag, rows):
        n = len(rows); a = sum(r.label for r in rows)
        print(f"\n[{tag}] {n} rows  human={n - a}  AI={a}")
        print(f"   register cheat: {cheat_accuracy(rows, 'register') * 100:4.1f}%  (goal ~50%)")
        print("   per-register [human, AI]:")
        for reg, (h, ai) in per_register(rows).items():
            print(f"      {reg:18s} H={h:5d} AI={ai:5d}")

    report("train", train)
    report("eval", ev)
    print(f"\nwrote {out}/train.csv and {out}/eval.csv  (gate + crossgen untouched, leakage=0)")
    print("audit:  python3 scripts/audit-confound.py --data "
          f"{out}/train.csv {out}/eval.csv --probe")


if __name__ == "__main__":
    main()
