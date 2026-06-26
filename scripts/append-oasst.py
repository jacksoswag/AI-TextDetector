#!/usr/bin/env python3
"""Fold the oasst ESL + casual-conversation top-up into data/corpus, and extend the
OOD gate with the held-out slice so the gate can actually measure the new registers.

Run AFTER agent-rewrite.workflow.js has produced data/corpus_oasst/ai.jsonl.

  data/corpus_oasst/human_pool.csv  (humans, label 0)
  data/corpus_oasst/ai.jsonl        (matched AI, label 1, paired by topic_id)
  data/corpus_oasst/gate_humans.csv (held-out humans -> appended to ood_human.csv)

Reuses the build-corpus-v2 assembly + the hard leakage guard (nothing trained on may
appear in the gate / crossgen file, and the new gate rows may not appear in train).
"""
import csv, sys, random, importlib.util
from pathlib import Path
from collections import defaultdict

csv.field_size_limit(10 ** 7)
ROOT = Path("/Users/jacksonadams/Code/pilcrow")
DATA = ROOT / "data"
spec = importlib.util.spec_from_file_location("bc2", ROOT / "scripts" / "build-corpus-v2.py")
bc2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc2)
Row = bc2.Row
dedup, balance_in_cells, length_match, split_by_topic = (
    bc2.dedup, bc2.balance_in_cells, bc2.length_match, bc2.split_by_topic)
write_csv, cheat_accuracy, words = bc2.write_csv, bc2.cheat_accuracy, bc2.words
load_human_csv, load_ai_jsonl = bc2.load_human_csv, bc2.load_ai_jsonl
random.seed(0)


def load_rows(path):
    rows = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t = (r.get("text") or "").strip()
            if not t:
                continue
            try:
                lab = int(r.get("label", -1))
            except ValueError:
                continue
            if lab not in (0, 1):
                continue
            rows.append(Row(t, lab, r.get("source") or "import", r.get("register") or "unknown",
                            r.get("topic_id") or r.get("source") or "import",
                            generator=r.get("generator") or ("human" if lab == 0 else "ai"),
                            variant=r.get("variant") or "raw", era=r.get("era") or ""))
    return rows


def keys_of(path):
    ks = set()
    if not Path(path).exists():
        return ks
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


def append_gate(gate_csv, ood_path):
    """Append held-out oasst humans to ood_human.csv (schema: text,label,source,
    register,era,words,split). Skips any text already in the gate."""
    existing = keys_of(ood_path)
    add = []
    with open(gate_csv, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            t = (r.get("text") or "").strip()
            if not t or Row(t, 0, "g", "g", "g").key() in existing:
                continue
            add.append(r)
    with open(ood_path, "a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        for r in add:
            w.writerow([r["text"], 0, r.get("source", "oasst"), r.get("register", "esl"),
                        r.get("era", "2023"), words(r["text"]), "oasst_gate"])
    return len(add)


def main():
    oasst = DATA / "corpus_oasst"
    hp, ai, gate = oasst / "human_pool.csv", oasst / "ai.jsonl", oasst / "gate_humans.csv"
    for p in (hp, ai, gate):
        if not p.exists():
            sys.exit(f"missing {p} — run the harvester + agent-rewrite first")

    ood = DATA / "corpus" / "ood_human.csv"
    n_gate = append_gate(gate, ood)
    print(f"gate: appended {n_gate} held-out oasst humans -> {ood}")

    base = load_rows(DATA / "corpus" / "train.csv") + load_rows(DATA / "corpus" / "eval.csv")
    humans = load_human_csv(str(hp))          # label 0
    ai_rows = load_ai_jsonl(str(ai))          # label 1, paired by topic_id
    print(f"base={len(base)}  oasst humans={len(humans)}  oasst AI={len(ai_rows)}")

    forbidden = keys_of(ood) | keys_of(DATA / "corpus" / "crossgen_eval.csv")
    pool = [r for r in base + humans + ai_rows if r.key() not in forbidden]

    core = balance_in_cells(dedup(pool), cap=0.60)
    core = length_match(core)
    train, ev, _ = split_by_topic(core, eval_frac=0.15)
    leaked = sum(1 for r in train + ev if r.key() in forbidden)
    assert leaked == 0, f"LEAKAGE: {leaked} rows match gate/crossgen"

    out = DATA / "corpus"
    write_csv(out / "train.csv", train)
    write_csv(out / "eval.csv", ev)

    def report(tag, rows):
        n = len(rows); a = sum(r.label for r in rows)
        print(f"\n[{tag}] {n} rows  human={n - a}  AI={a}  register cheat "
              f"{cheat_accuracy(rows, 'register') * 100:.1f}%")
        for reg in ("esl", "conversation"):
            h, ai_ = per_register(rows).get(reg, [0, 0])
            print(f"   {reg:14s} H={h:5d} AI={ai_:5d}")

    report("train", train)
    report("eval", ev)
    print(f"\nwrote {out}/train.csv, eval.csv ; gate now {len(keys_of(ood))} rows. leakage=0")


if __name__ == "__main__":
    main()
