#!/usr/bin/env python3
r"""
build-register-humans.py — harvest the common modern HUMAN registers the corpus was
missing, so the detector stops reading them as AI. An earlier model false-flagged Wikipedia
(0.99 AI) because encyclopedic prose was never a HUMAN training example while the AI
class contained encyclopedic-style rewrites: it learned "neutral dense factual = AI".
This pulls clean, pre-AI human text in the registers real users actually paste:

  encyclopedic   Wikipedia article intros (live action API) + 1911 Britannica (Gutenberg)
  business       Enron email bodies (aeslc, ~2001 — pre-AI by construction)
  instructional  public-domain cookbooks / household + trade manuals (Gutenberg)
  fiction_modern early-20c novels (Conrad, Wells, London, Forster, Cather, ...) (Gutenberg)
  reviews        Amazon product reviews (amazon_polarity)

Each passage gets a unique topic_id so the matched AI counterpart (agent-rewrite.workflow.js)
pairs back to it and the corpus stays matched-pair / deconfounded.

Outputs (under --out-dir):
  register_human.csv   build-corpus-v2 columns -> concatenate onto the human pool
  register_full.jsonl  {topic_id, register, text} -> feed to agent-rewrite.workflow.js
"""

import argparse
import csv
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

UA = "ai-detector-register-builder/1.0 (research; on-device detector training; contact via repo)"
CACHE = ".cache/gutenberg"


def _get(url, timeout=15, retries=2):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 — network is best-effort
            last = e
            time.sleep(0.6)
    raise last


def clean(t):
    t = re.sub(r"\s+", " ", (t or "")).strip()
    return t


def email_body(t):
    """snoop2head enron 'text' = RFC-822 headers then the body. Keep the body and
    drop any header-style 'Field: value' lines, so the model never cheats on
    'Date:/From:/To:' artifacts instead of authorship."""
    parts = re.split(r"\bBody:\s*", t, maxsplit=1)
    body = parts[1] if len(parts) > 1 else t
    body = re.sub(r"(?im)^\s*(Date|From|To|Cc|Bcc|Subject|Sent|Message-ID|X-[\w-]+):.*$", " ", body)
    body = re.sub(r"\S+@\S+\.\S+", " ", body)            # stray addresses
    return body


def trim_words(t, hi):
    w = t.split()
    return " ".join(w[:hi]) if len(w) > hi else t


# ── encyclopedic: live Wikipedia action API (random article intros) ───────────
def fetch_wikipedia(n, lo, hi, delay):
    """Random article intros via the MediaWiki action API: dense, neutral, present-
    tense encyclopedic prose — the exact register the model over-flags. Wikipedia bans
    undisclosed AI and article bodies are overwhelmingly pre-2022 human text."""
    out = []
    base = ("https://en.wikipedia.org/w/api.php?action=query&format=json"
            "&generator=random&grnnamespace=0&grnlimit=16"
            "&prop=extracts&exintro=1&explaintext=1")
    tries = 0
    while len(out) < n and tries < n // 3 + 150:
        tries += 1
        try:
            data = json.loads(_get(base).decode("utf-8", "replace"))
        except Exception as e:  # noqa: BLE001
            print(f"  [wiki] page failed: {e}", file=sys.stderr); time.sleep(delay); continue
        for page in (data.get("query", {}).get("pages", {}) or {}).values():
            txt = trim_words(clean(page.get("extract", "")), hi)
            if lo <= len(txt.split()) <= hi and not txt.lower().startswith("redirect"):
                out.append(("encyclopedic", txt))
        print(f"  [wiki] {len(out)}/{n}", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


# ── HF datasets-server rows (business email, reviews) ─────────────────────────
def fetch_hf(dataset, config, split, field, register, n, lo, hi, delay, size=15000, transform=None):
    """Page random offsets from the HF datasets-server. Fail-fast: bail after 3
    consecutive failed/empty pages so a missing dataset can't storm for minutes."""
    import random
    out, tries, misses = [], 0, 0
    while len(out) < n and tries < n // 12 + 12 and misses < 3:
        tries += 1
        off = random.randint(0, max(0, size - 100))
        url = (f"https://datasets-server.huggingface.co/rows?dataset={urllib.parse.quote(dataset)}"
               f"&config={config}&split={split}&offset={off}&length=100")
        try:
            d = json.loads(_get(url).decode("utf-8", "replace"))
        except Exception as e:  # noqa: BLE001
            misses += 1
            print(f"  [hf:{dataset}] page failed ({misses}/3): {str(e)[:50]}", file=sys.stderr)
            continue
        before = len(out)
        for item in d.get("rows", []):
            raw = item.get("row", {}).get(field, "")
            if transform:
                raw = transform(raw)
            txt = trim_words(clean(raw), hi)
            if lo <= len(txt.split()) <= hi:
                out.append((register, txt))
        misses = 0 if len(out) > before else misses + 1
        print(f"  [hf:{dataset}] {len(out)}/{n}", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


# ── Gutenberg (instructional manuals, early-20c fiction, 1911 Britannica) ─────
def gutendex_text_url(query):
    url = "https://gutendex.com/books?" + urllib.parse.urlencode(
        {"search": query, "languages": "en", "mime_type": "text/plain"})
    try:
        data = json.loads(_get(url).decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return None
    for book in data.get("results", []):
        for mime, link in book.get("formats", {}).items():
            if mime.startswith("text/plain") and not link.endswith(".zip"):
                return link
    return None


def fetch_gutenberg_work(query):
    os.makedirs(CACHE, exist_ok=True)
    key = "reg_" + re.sub(r"[^a-z0-9]+", "_", query.lower())[:50]
    path = os.path.join(CACHE, key + ".txt")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return open(path, encoding="utf-8", errors="replace").read()
    link = gutendex_text_url(query)
    if not link:
        return ""
    try:
        raw = _get(link, timeout=60).decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return ""
    open(path, "w", encoding="utf-8").write(raw)
    time.sleep(0.8)
    return raw


def chunk(text, lo, hi):
    s = re.search(r"\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\*\*\*", text)
    e = re.search(r"\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\*\*\*", text)
    if s:
        text = text[s.end():]
    if e and e.start() > 0:
        text = text[:e.start()]
    out, buf, n = [], [], 0
    for para in re.split(r"\n\s*\n", text):
        p = clean(para)
        if len(p) < 25 or re.match(r"^(chapter|book|volume|part|section|contents|index)\b", p, re.I):
            continue
        if re.search(r"produced by|distributed proofread|project gutenberg|transcrib|\[illustration", p, re.I):
            continue
        if sum(c.isupper() for c in p) > len(p) * 0.4:   # all-caps headers/plates
            continue
        buf.append(p); n += len(p.split())
        if n >= lo:
            passage = trim_words(" ".join(buf), hi)
            if lo <= len(passage.split()) <= hi:
                out.append(passage)
            buf, n = [], 0
    return out


INSTRUCTIONAL = [
    "Mrs Beeton's Book of Household Management",
    "The Boston Cooking-School Cook Book Farmer",
    "The Art of Cookery Made Plain and Easy",
    "Handicraft for Boys carpentry",
    "The American Frugal Housewife",
    "Inquiries into Household Science manual",
]
FICTION_MODERN = [
    "Heart of Darkness Conrad", "The Secret Agent Conrad",
    "The War of the Worlds Wells", "The Time Machine Wells",
    "The Call of the Wild London", "Martin Eden London",
    "A Room with a View Forster", "Howards End Forster",
    "My Antonia Cather", "O Pioneers Cather",
    "The Man Who Was Thursday Chesterton", "Kim Kipling",
    "The Age of Innocence Wharton",
]
BRITANNICA = [
    "Encyclopaedia Britannica 1911 Volume",
    "Encyclopaedia Britannica eleventh edition",
]
# Held-out eval: DIFFERENT works/authors than training, so fiction/instructional
# results measure generalization, not memorization of the training books.
HELD_FICTION = [
    "The Man of Property Galsworthy", "Of Human Bondage Maugham",
    "The Old Wives' Tale Bennett", "Sons and Lovers Lawrence",
    "Right Ho Jeeves Wodehouse", "Winesburg Ohio Anderson",
    "The Rainbow Lawrence", "Tono-Bungay Wells second",
]
HELD_INSTRUCTIONAL = [
    "The Gardening Beginner manual", "The Etiquette of To-day",
    "First Aid to the Injured manual", "The Boy Mechanic things to do",
    "Canning and Preserving manual", "Practical Sewing and Dressmaking",
]


def from_gutenberg(queries, register, per_work, lo, hi, stride):
    out = []
    for q in queries:
        text = fetch_gutenberg_work(q)
        if not text:
            print(f"  [gutenberg] miss: {q}", file=sys.stderr); continue
        chunks = chunk(text, lo, hi)
        picked = chunks[::max(1, stride)][:per_work] or chunks[:per_work]
        for p in picked:
            out.append((register, p))
        print(f"  [gutenberg:{register}] +{len(picked)} from {q[:40]}", file=sys.stderr)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wiki", type=int, default=1000)
    ap.add_argument("--business", type=int, default=420)
    ap.add_argument("--per-work", type=int, default=34, help="Gutenberg passages per work")
    ap.add_argument("--min-words", type=int, default=90)
    ap.add_argument("--max-words", type=int, default=260)
    ap.add_argument("--stride", type=int, default=6)
    ap.add_argument("--delay", type=float, default=0.8)
    ap.add_argument("--out-dir", default="data/corpus_reg")
    ap.add_argument("--held", action="store_true",
                    help="held-out EVAL harvest: different Gutenberg works + dedup vs the training file")
    ap.add_argument("--dedup-against", default="data/corpus_reg/register_human.csv",
                    help="(held mode) drop any passage whose text appears in this training CSV")
    args = ap.parse_args()
    lo, hi = args.min_words, args.max_words
    os.makedirs(args.out_dir, exist_ok=True)
    fiction = HELD_FICTION if args.held else FICTION_MODERN
    instructional = HELD_INSTRUCTIONAL if args.held else INSTRUCTIONAL
    stem = "held" if args.held else "register"

    rows = []  # (register, text)
    print("[encyclopedic] Wikipedia API …", file=sys.stderr)
    rows += fetch_wikipedia(args.wiki, lo, hi, args.delay)
    if not args.held:
        print("[encyclopedic] 1911 Britannica …", file=sys.stderr)
        rows += from_gutenberg(BRITANNICA, "encyclopedic", 120, lo, hi, args.stride)
    print("[business] Enron email …", file=sys.stderr)
    rows += fetch_hf("snoop2head/enron_aeslc_emails", "default", "train", "text", "business",
                     args.business, lo, hi, args.delay, size=18000, transform=email_body)
    print("[instructional] Gutenberg manuals …", file=sys.stderr)
    rows += from_gutenberg(instructional, "instructional", args.per_work, lo, hi, args.stride)
    print("[fiction_modern] Gutenberg early-20c …", file=sys.stderr)
    rows += from_gutenberg(fiction, "fiction_modern", args.per_work, lo, hi, args.stride)

    # dedup on a text fingerprint
    seen, dedup = set(), []
    for reg, t in rows:
        k = t[:160].lower()
        if k and k not in seen:
            seen.add(k); dedup.append((reg, t))
    rows = dedup

    # held mode: drop anything that overlaps the TRAINING harvest (no leakage)
    if args.held and os.path.exists(args.dedup_against):
        train_keys = {r["text"][:160].lower() for r in csv.DictReader(open(args.dedup_against))}
        before = len(rows)
        rows = [(reg, t) for reg, t in rows if t[:160].lower() not in train_keys]
        print(f"  [held] dropped {before - len(rows)} rows overlapping training", file=sys.stderr)

    by_reg = {}
    for reg, _ in rows:
        by_reg[reg] = by_reg.get(reg, 0) + 1

    tid_pre = "held" if args.held else "reg"
    csv_path = os.path.join(args.out_dir, f"{stem}_human.csv")
    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["text", "label", "source", "register", "generator", "variant", "era", "topic_id", "words"])
        for i, (reg, t) in enumerate(rows):
            tid = f"{tid_pre}-{reg}-{i:05d}"
            era = "pre2022" if reg in ("encyclopedic", "business", "reviews") else "pre1929"
            w.writerow([t, 0, f"reg_{reg}", reg, "human", "raw", era, tid, len(t.split())])

    jsonl_path = os.path.join(args.out_dir, f"{stem}_full.jsonl")
    with open(jsonl_path, "w", encoding="utf-8") as f:
        for i, (reg, t) in enumerate(rows):
            f.write(json.dumps({"topic_id": f"{tid_pre}-{reg}-{i:05d}", "register": reg, "text": t}) + "\n")

    print(f"\nwrote {len(rows)} human passages")
    print(f"  -> {csv_path}\n  -> {jsonl_path}  (feed to agent-rewrite.workflow.js)")
    for reg in sorted(by_reg):
        print(f"  {reg:16s} {by_reg[reg]:4d}")


if __name__ == "__main__":
    main()
