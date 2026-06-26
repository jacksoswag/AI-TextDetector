#!/usr/bin/env python3
"""Harvest casual-conversation + non-native-English HUMAN passages from
OpenAssistant/oasst1 (Apache-2.0 — the one commercially-licensable conversational
corpus; every labeled ESL set on HF is non-commercial or restricted).

Two registers, both real human messages:
  conversation  English from English-only contributors (casual chat / Q&A / the
                assistant-style answers a real person typed).
  esl           English written by a non-native speaker — detected two ways, both
                license-clean and label-free: the author also posted in another
                language, OR the message sits in an otherwise non-English thread.
                This is the single most over-flagged class for AI detectors.

Rate-limit hardened: rows are cached cumulatively to .raw_cache.jsonl, so re-running
after a 429 cooldown keeps accumulating instead of starting over. Sampling pulls
contiguous blocks (whole trees) so per-user / per-tree language profiles fill in.

Outputs (data/corpus_oasst/):
  human_pool.csv   training humans (feed matched AI, then merge into data/corpus)
  full.jsonl       {topic_id, register, text} -> agent-rewrite.workflow.js
  gate_humans.csv  held-out humans (disjoint trees) -> append to ood_human.csv
"""
import csv, json, os, random, sys, time, importlib.util, urllib.parse, urllib.request, urllib.error
from pathlib import Path
from collections import defaultdict

csv.field_size_limit(10 ** 7)
ROOT = Path("/Users/jacksonadams/Code/pilcrow")
spec = importlib.util.spec_from_file_location("bc2", ROOT / "scripts" / "build-corpus-v2.py")
bc2 = importlib.util.module_from_spec(spec); spec.loader.exec_module(bc2)
clean, normalize_format, words, topic_id, Row, write_csv = (
    bc2.clean, bc2.normalize_format, bc2.words, bc2.topic_id, bc2.Row, bc2.write_csv)

UA = "ai-detector-corpus/1.0 (research; on-device detector training)"
DS = "OpenAssistant/oasst1"
TRAIN_SIZE = 84400
LO, HI = 60, 220
OUT = ROOT / "data" / "corpus_oasst"
CACHE = OUT / ".raw_cache.jsonl"


def _get(url, timeout=20, retries=5):
    """GET with explicit 429 backoff — the HF datasets-server free tier rate-limits
    hard, so a flat retry just storms. Back off 4/8/16/32s on 429."""
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:  # noqa: BLE001
            last = e
            time.sleep((4 * 2 ** attempt) if e.code == 429 else 0.7)
        except Exception as e:  # noqa: BLE001 — network is best-effort
            last = e; time.sleep(0.7)
    raise last


def existing_keys():
    """Text fingerprints already in the corpus + frozen gate, so we never dup or leak."""
    ks = set()
    for rel in ("data/corpus/train.csv", "data/corpus/eval.csv", "data/corpus/ood_human.csv"):
        p = ROOT / rel
        if not p.exists():
            continue
        with open(p, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                t = (r.get("text") or "").strip()
                if t:
                    ks.add(Row(t, 0, "x", "x", "x").key())
    return ks


def load_cache():
    rows = []
    if CACHE.exists():
        with open(CACHE, encoding="utf-8") as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except Exception:  # noqa: BLE001
                    pass
    return rows


def page_more(seen_msg, fh, max_pages, block, delay):
    """Pull contiguous BLOCK-page runs from random starts (captures whole trees ->
    richer per-user/per-tree language profiles). Append new minimal rows to the cache."""
    added = misses = pages = 0
    while pages < max_pages and misses < 8:
        start = random.randint(0, max(0, TRAIN_SIZE - block * 100))
        for b in range(block):
            if pages >= max_pages:
                break
            pages += 1
            off = start + b * 100
            url = (f"https://datasets-server.huggingface.co/rows?dataset={urllib.parse.quote(DS)}"
                   f"&config=default&split=train&offset={off}&length=100")
            try:
                d = json.loads(_get(url).decode("utf-8", "replace"))
            except Exception as e:  # noqa: BLE001
                misses += 1; print(f"  page {pages} off {off} failed ({misses}/8): {str(e)[:50]}", file=sys.stderr)
                break
            rows = d.get("rows", [])
            if not rows:
                misses += 1; break
            misses = 0; new = 0
            for it in rows:
                row = it.get("row", {})
                mid = row.get("message_id")
                if not mid or mid in seen_msg:
                    continue
                seen_msg.add(mid)
                rec = {"id": mid, "u": row.get("user_id"), "lang": (row.get("lang") or "").lower(),
                       "role": row.get("role"), "del": bool(row.get("deleted")),
                       "syn": bool(row.get("synthetic")), "rev": row.get("review_result"),
                       "tox": (row.get("detoxify") or {}).get("toxicity"),
                       "tree": row.get("message_tree_id") or mid, "text": row.get("text") or ""}
                fh.write(json.dumps(rec) + "\n"); added += 1; new += 1
            print(f"  page {pages} off {off}: +{new} (seen {len(seen_msg)})", file=sys.stderr)
            time.sleep(delay)
    return added


def main():
    random.seed()  # vary offsets each run so re-runs sample fresh regions
    OUT.mkdir(parents=True, exist_ok=True)
    ESL_T, CONV_T = 300, 360

    cached = load_cache()
    seen_msg = {r["id"] for r in cached}
    print(f"cache: {len(cached)} rows", file=sys.stderr)
    with open(CACHE, "a", encoding="utf-8") as fh:
        page_more(seen_msg, fh, max_pages=160, block=8, delay=0.8)
    cached = load_cache()

    # language profiles from EVERY cached message (any lang)
    user_langs, tree_langs = defaultdict(set), defaultdict(set)
    for r in cached:
        if r.get("lang"):
            if r.get("u"):
                user_langs[r["u"]].add(r["lang"])
            tree_langs[r["tree"]].add(r["lang"])

    cands = [r for r in cached
             if r.get("lang") == "en" and r.get("role") in ("prompter", "assistant")
             and not r.get("del") and not r.get("syn") and r.get("rev") is not False
             and not (r.get("tox") and r["tox"] > 0.5)]
    random.shuffle(cands)

    have = existing_keys()
    seen = set(have)
    esl, conv, gate_esl, gate_conv = [], [], [], []
    for r in cands:
        txt = normalize_format(clean(r["text"]))
        if not (LO <= words(txt) <= HI):
            continue
        k = Row(txt, 0, "x", "x", "x").key()
        if k in seen:
            continue
        seen.add(k)
        nonnative = bool((r.get("u") and (user_langs.get(r["u"], set()) - {"en"}))
                         or (tree_langs.get(r["tree"], set()) - {"en"}))
        reg = "esl" if nonnative else "conversation"
        gate = (int(topic_id(r["tree"])[:4], 16) % 100) < 12   # ~12% of trees held out
        bucket = (gate_esl if reg == "esl" else gate_conv) if gate else (esl if reg == "esl" else conv)
        bucket.append((reg, txt))

    esl, conv = esl[:ESL_T], conv[:CONV_T]
    gate_esl, gate_conv = gate_esl[:60], gate_conv[:60]
    print(f"\nTRAIN humans: esl={len(esl)} conversation={len(conv)}", file=sys.stderr)
    print(f"GATE  humans: esl={len(gate_esl)} conversation={len(gate_conv)}", file=sys.stderr)
    if len(esl) < 120:
        print("NOTE: esl yield still under 120 — re-run to accumulate more (cache is cumulative).",
              file=sys.stderr)

    def to_rows(pairs):
        return [Row(t, 0, f"oasst_{reg}", reg, f"oasst-{reg}-{i:05d}",
                    generator="human", variant="raw", era="2023")
                for i, (reg, t) in enumerate(pairs)]

    train_rows = to_rows(esl + conv)
    write_csv(OUT / "human_pool.csv", train_rows)
    with open(OUT / "full.jsonl", "w", encoding="utf-8") as f:
        for r in train_rows:
            f.write(json.dumps({"topic_id": topic_id(r.topic), "register": r.register,
                                "text": r.text}) + "\n")
    write_csv(OUT / "gate_humans.csv", to_rows(gate_esl + gate_conv))
    print(f"\nwrote {OUT}/human_pool.csv ({len(train_rows)}), full.jsonl, "
          f"gate_humans.csv ({len(gate_esl) + len(gate_conv)})")


if __name__ == "__main__":
    main()
