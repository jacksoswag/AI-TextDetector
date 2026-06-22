#!/usr/bin/env python3
r"""
build-ood-regression.py — assemble the permanent OUT-OF-DISTRIBUTION human
regression set: real human text the detector must NEVER flag as AI, and which is
NEVER used for training. This is the release gate that catches the "Lincoln /
Austen" failure (formal, historical, literary, or atypical human prose that a
typicality-trained detector mistakes for AI).

Why fetch instead of hardcode
-----------------------------
The text is pulled live from Project Gutenberg (public domain) via the gutendex
JSON API, then chunked into passages. Nothing large is embedded in this file —
the script downloads canonical human works (18th–19th c. literature, oratory,
scripture, science, poetry) and slices them into eval passages. A small inline
seed of SHORT modern hard-cases (terse/plain/ESL/casual human) rounds out the
registers small detectors also misfire on.

Output: data/corpus/ood_human.csv  with columns
    text,label,source,register,era,split
All rows are label=0 (human) and split="ood". Feed it to scripts/audit-confound.py
(--ood) and to any eval as a FROZEN false-positive gate. Do not train on it.

Usage:
    python3 scripts/build-ood-regression.py                 # ~default sizes
    python3 scripts/build-ood-regression.py --per-work 12 --min-words 60 --max-words 240
    python3 scripts/build-ood-regression.py --out data/corpus/ood_human.csv

No API key needed. Be a good citizen: it caches downloads under .cache/gutenberg
and sleeps between requests.
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

UA = "ai-detector-ood-builder/1.0 (research; on-device detector eval; contact via repo)"
CACHE = ".cache/gutenberg"

# Canonical public-domain works to pull, by search query. Each entry:
#   (gutendex_query, source_label, register, era)
# These are exactly the registers a typicality-trained detector false-flags:
# historical oratory, 18–19c literary prose, scripture, early science/philosophy,
# and verse. Searched via gutendex; the top English text match is downloaded.
WORKS = [
    ("Pride and Prejudice Austen",                 "austen_pp",      "literary_19c",    "pre1900"),
    ("Emma Austen",                                "austen_emma",    "literary_19c",    "pre1900"),
    ("A Tale of Two Cities Dickens",               "dickens_tale",   "literary_19c",    "pre1900"),
    ("Great Expectations Dickens",                 "dickens_ge",     "literary_19c",    "pre1900"),
    ("Jane Eyre Bronte",                           "bronte_je",      "literary_19c",    "pre1900"),
    ("Moby Dick Melville",                         "melville_md",    "literary_19c",    "pre1900"),
    ("Adventures of Huckleberry Finn Twain",       "twain_hf",       "literary_19c",    "pre1900"),
    ("Frankenstein Shelley",                       "shelley_frank",  "literary_19c",    "pre1900"),
    ("Walden Thoreau",                             "thoreau_walden", "philosophy_19c",  "pre1900"),
    ("On the Origin of Species Darwin",            "darwin_origin",  "science_19c",     "pre1900"),
    ("Narrative of the Life of Frederick Douglass","douglass_narr",  "historical_19c",  "pre1900"),
    ("The Federalist Papers",                      "federalist",     "political_18c",   "pre1900"),
    ("Second Treatise of Government Locke",        "locke_treatise", "political_18c",   "pre1900"),
    ("Autobiography of Benjamin Franklin",         "franklin_auto",  "historical_18c",  "pre1900"),
    ("Leaves of Grass Whitman",                    "whitman_leaves", "poetry",          "pre1900"),
    ("The Adventures of Sherlock Holmes Doyle",    "doyle_holmes",   "literary_19c",    "pre1900"),
]

# SHORT modern human hard-cases (self-authored, benign). These are the *plain*,
# *atypical*, or *non-native* human registers small detectors also misfire on.
# Replace/extend with your own real samples (e.g. a few ESL paragraphs, terse
# work notes, casual chat) — more is better for the gate.
MODERN_SEED = [
    ("terse_factual", "modern_plain", "ood_seed",
     "Meeting moved to 3pm. Bring the printed budget. Parking is in lot C this week "
     "because B is closed for paving. Ping me if the room is locked again."),
    ("terse_factual", "modern_plain", "ood_seed",
     "Replaced the cabin air filter and topped off the coolant. The squeak is the "
     "left front brake, not the belt. Needs new pads soon, rotors are still fine."),
    ("esl_human", "modern_esl", "ood_seed",
     "I am study English since two years. My country is have many mountain and the "
     "winter is very cold. I like very much to cook the food from my home, but here "
     "the ingredient is difficult to find, so I make the substitute."),
    ("esl_human", "modern_esl", "ood_seed",
     "Thank you for your email. I am sorry for the late reply because I was travel "
     "last week. The document you sended is received well. I will to check it and "
     "give you the feedback before Friday, if there is no problem."),
    ("casual_chat", "modern_casual", "ood_seed",
     "honestly idk why the bus was so late today, waited like 25 min in the cold lol. "
     "anyway u still coming over later? got snacks and the new episode queued up. "
     "lmk if ur bringing the dog this time hahaha"),
    ("casual_chat", "modern_casual", "ood_seed",
     "ok so the recipe was a disaster lmaooo. burnt the garlic in like 10 seconds and "
     "the whole kitchen smelled. ended up just ordering pizza. 0/10 would not cook "
     "again, sticking to cereal honestly"),
]


def _request(url, timeout=30, retries=3):
    headers = {"User-Agent": UA}
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as e:  # noqa: BLE001 — network is best-effort
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise last


def gutendex_text_url(query):
    """Search gutendex for the work; return the best plain-text download URL."""
    url = "https://gutendex.com/books?" + urllib.parse.urlencode(
        {"search": query, "languages": "en", "mime_type": "text/plain"})
    try:
        data = json.loads(_request(url).decode("utf-8", "replace"))
    except Exception as e:  # noqa: BLE001
        print(f"  [gutendex] '{query}' search failed: {e}", file=sys.stderr)
        return None, None
    for book in data.get("results", []):
        fmts = book.get("formats", {})
        # prefer utf-8 plain text, fall back to any text/plain
        for mime, link in fmts.items():
            if mime.startswith("text/plain") and not link.endswith(".zip"):
                return link, book.get("id")
    print(f"  [gutendex] '{query}': no plain-text format", file=sys.stderr)
    return None, None


def fetch_book_text(query):
    """Download (and cache) the plain text of a work."""
    os.makedirs(CACHE, exist_ok=True)
    key = re.sub(r"[^a-z0-9]+", "_", query.lower())[:50]
    path = os.path.join(CACHE, key + ".txt")
    if os.path.exists(path) and os.path.getsize(path) > 1000:
        return open(path, encoding="utf-8", errors="replace").read()
    link, _id = gutendex_text_url(query)
    if not link:
        return ""
    try:
        raw = _request(link, timeout=60).decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        print(f"  [gutenberg] download failed for '{query}': {e}", file=sys.stderr)
        return ""
    with open(path, "w", encoding="utf-8") as f:
        f.write(raw)
    time.sleep(0.8)
    return raw


def strip_boilerplate(text):
    """Remove the Project Gutenberg header/footer license wrapper."""
    start = re.search(r"\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\*\*\*", text)
    end = re.search(r"\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG[^\n]*\*\*\*", text)
    if start:
        text = text[start.end():]
    if end:
        text = text[:end.start()] if end.start() > 0 else text
    # drop any "Produced by ..." transcriber lines near the top
    text = re.sub(r"(?im)^\s*produced by .*$", "", text)
    return text


def chunk_passages(text, lo, hi):
    """Split into paragraph-aligned passages of lo..hi words."""
    text = strip_boilerplate(text)
    paras = re.split(r"\n\s*\n", text)
    out, buf, n = [], [], 0
    for para in paras:
        p = " ".join(para.split())
        if not p:
            continue
        # skip chapter headers / all-caps lines / page artifacts
        if len(p) < 25 or re.match(r"^(chapter|book|volume|part|canto)\b", p, re.I):
            continue
        wc = len(p.split())
        buf.append(p)
        n += wc
        if n >= lo:
            passage = " ".join(buf)
            words = passage.split()
            if len(words) > hi:
                passage = " ".join(words[:hi])
            if lo <= len(passage.split()) <= hi:
                out.append(passage)
            buf, n = [], 0
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--per-work", type=int, default=10,
                    help="passages to keep per Gutenberg work")
    ap.add_argument("--min-words", type=int, default=60)
    ap.add_argument("--max-words", type=int, default=260)
    ap.add_argument("--stride", type=int, default=7,
                    help="sample every Nth chunk so passages span the whole work, not just the opening")
    ap.add_argument("--no-fetch", action="store_true",
                    help="skip Gutenberg; write only the modern inline seed (offline)")
    ap.add_argument("--out", default="data/corpus/ood_human.csv")
    args = ap.parse_args()

    rows = []  # (text, source, register, era)

    if not args.no_fetch:
        for query, source, register, era in WORKS:
            text = fetch_book_text(query)
            if not text:
                continue
            chunks = chunk_passages(text, args.min_words, args.max_words)
            # stride-sample across the whole book for register diversity
            picked = chunks[::max(1, args.stride)][:args.per_work]
            if len(picked) < args.per_work:           # top up if the book was short
                picked = chunks[:args.per_work]
            for passage in picked:
                rows.append((passage, source, register, era))
            print(f"  [{source}] kept {len(picked)} passages "
                  f"(of {len(chunks)} chunks)", file=sys.stderr)

    for register, era, source, passage in (
            (r, e, s, t) for (r, e, s, t) in MODERN_SEED):
        rows.append((" ".join(passage.split()), source, register, era))

    # dedup on a text fingerprint
    seen, dedup = set(), []
    for r in rows:
        k = r[0][:160].lower()
        if k not in seen:
            seen.add(k)
            dedup.append(r)
    rows = dedup

    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["text", "label", "source", "register", "era", "split"])
        for text, source, register, era in rows:
            w.writerow([text, 0, source, register, era, "ood"])

    # report
    by_reg = {}
    for _t, _s, register, _e in rows:
        by_reg[register] = by_reg.get(register, 0) + 1
    print(f"\nwrote {len(rows)} OOD human rows → {args.out}")
    for reg in sorted(by_reg):
        print(f"  {reg:18s} {by_reg[reg]:4d}")
    if len(rows) < 50:
        print("\n⚠ small set — pass --per-work higher, or add more WORKS / MODERN_SEED, "
              "and check network access to gutendex.com.", file=sys.stderr)
    print("\nnext: python3 scripts/audit-confound.py --ood", args.out,
          "--model <your detector>   # measures false-positive rate on this gate")


if __name__ == "__main__":
    main()
