#!/usr/bin/env python3
r"""
build-corpus-v2.py — a DECONFOUNDED AI-vs-human corpus builder.

The problem this fixes
----------------------
The previous corpus let the model cheat: its human rows (arXiv, Wikipedia, pile)
and AI rows (RAID, Haiku) differed by SOURCE, ERA, and FORMATTING, not just
authorship. scripts/audit-confound.py shows a model can reach ~72% accuracy from
the `source` column ALONE, with no text. So it learned "looks like my human
sources = human, else = AI", and false-flagged out-of-distribution humans
(Lincoln, Austen) as AI.

The fix (what this script does differently)
-------------------------------------------
1. MATCHED PAIRS, not matched categories. For each real human passage we generate
   an AI counterpart on the SAME topic, in the SAME register, at the SAME length,
   from SEVERAL model families. Within every (register, topic) cell both labels
   appear, so the only systematic difference left is authorship.
2. MULTI-FAMILY generation: Anthropic + Gemini live (bring keys via .env), plus
   optional external multi-generator datasets folded in as HELD-OUT eval only.
3. DISGUISE variants: paraphrase + back-translation of AI text (label stays 1) so
   the detector sees humanized positives, not just raw model output.
4. PRE-2022 human sources to avoid AI-contaminated "human" labels (Wikipedia
   as-of-2021 revisions; arXiv pre-2022 abstracts; Guardian bodyText; your own
   pre-2022 dumps via --human-jsonl).
5. NORMALIZE formatting + length on BOTH sides so markdown/length isn't a tell.
6. GROUP-STRATIFIED split: whole topics held out for eval; external-dataset rows
   never enter train; label balanced within each source x register cell.
7. SELF-AUDIT: prints the metadata cheat-accuracy of the corpus it just wrote.
   Aim for source/register cheat ≈ the majority baseline (≈50%).

Keys (.env or env; all optional except a generation provider):
    ANTHROPIC_API_KEY        Claude generation (haiku/sonnet/opus)
    GEMINI_API_KEY           Gemini generation (flash/flash-lite; free tier)
    OPENAI_API_KEY           optional GPT generation
    GUARDIAN_API_KEY         optional human news bodies (open-platform.theguardian.com)

Quick start (Claude + Gemini matched pairs over wiki/arxiv/news humans):
    python3 scripts/build-corpus-v2.py \
        --wikipedia 200 --arxiv 200 --guardian 200 \
        --human-jsonl data/human_dumps/*.jsonl \
        --families anthropic,gemini \
        --anthropic-models claude-haiku-4-5,claude-sonnet-4-6 \
        --gemini-models gemini-2.5-flash-lite \
        --disguise 0.25 --pairs-per-human 1 \
        --out-dir data/corpus

Then:
    python3 scripts/audit-confound.py --data data/corpus/train.csv data/corpus/eval.csv
    python3 scripts/audit-confound.py --ood data/corpus/ood_human.csv --model <model>
    python3 scripts/finetune-lora.py --train data/corpus/train.csv --eval data/corpus/eval.csv ...

Output: data/corpus/{train,eval}.csv with columns
    text,label,source,register,generator,variant,era,topic_id,words
"""

import argparse
import csv
import difflib
import glob
import hashlib
import html
import json
import os
import random
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

csv.field_size_limit(10_000_000)
UA = "ai-detector-corpus-builder/2.0 (research; on-device AI-text detector)"


# ── env / http ───────────────────────────────────────────────────────────────

def load_dotenv(path=".env"):
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def _request(url, *, method="GET", headers=None, data=None, timeout=40, retries=3):
    h = {"User-Agent": UA}
    if headers:
        h.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        h.setdefault("Content-Type", "application/json")
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, data=body, headers=h, method=method)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise last


def _get_json(url, **kw):
    return json.loads(_request(url, **kw))


# ── text cleaning / normalization ─────────────────────────────────────────────

PREAMBLE_RE = re.compile(
    r"^(sure|certainly|of course|absolutely|here(?:'s| is)|i'd be happy to|"
    r"great question|let'?s|below is|here are|as an ai|i'm happy to)\b[^\n.]*[:.]?\s*",
    re.IGNORECASE)


def clean(text):
    if not text:
        return ""
    text = html.unescape(text)
    text = re.sub(r"https?://\S+", " ", text)
    text = re.sub(r"\[[^\]]*\]\([^)]*\)", " ", text)     # md links
    text = re.sub(r"&[a-z]+;", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def normalize_format(text):
    """Strip the FORMATTING tells (markdown, bullets, emoji, em/en-dashes) so the model
    can't learn 'has markdown / em-dash => AI'. Applied to BOTH classes equally. The dash
    normalization closes the 99% em-dash shortcut the v1 corpus left open; a regular
    hyphen in compound words (real-estate) is preserved."""
    text = re.sub(r"[*_`>#]+", " ", text)                  # md emphasis/quote/heading
    text = re.sub(r"^\s*[-•·]\s+", " ", text, flags=re.M)  # bullets
    text = re.sub(r"^\s*\d+[.)]\s+", " ", text, flags=re.M)  # numbered lists
    text = re.sub(r"\s*[—–―]\s*", ", ", text)              # em/en/bar dash -> comma (glyph tell)
    text = re.sub(r"\s*--+\s*", ", ", text)                # ASCII double-hyphen em-dash -> comma
    text = re.sub(r"[\U0001F000-\U0001FAFF☀-➿]", "", text)  # emoji
    text = re.sub(r"\s*,(\s*,)+", ", ", text)              # collapse doubled commas
    text = re.sub(r"^\s*,\s*", "", text)                   # drop a leading comma artifact
    text = re.sub(r"\s+", " ", text).strip()
    return text


def strip_preamble(text):
    prev = None
    while text != prev:
        prev = text
        text = PREAMBLE_RE.sub("", text).strip()
    return text


def words(t):
    return len(t.split())


def trim_words(t, hi):
    p = t.split()
    return " ".join(p[:hi]) if len(p) > hi else t


def topic_id(s):
    return hashlib.sha256(s.lower().strip().encode("utf-8")).hexdigest()[:12]


# ── a passage record ──────────────────────────────────────────────────────────

class Row:
    __slots__ = ("text", "label", "source", "register", "generator",
                 "variant", "era", "topic", "split")

    def __init__(self, text, label, source, register, topic,
                 generator="human", variant="raw", era="", split=""):
        self.text = normalize_format(clean(text))
        self.label = int(label)
        self.source = source
        self.register = register
        self.generator = generator
        self.variant = variant
        self.era = era
        self.topic = topic or source
        self.split = split

    def key(self):
        return hashlib.sha256(self.text.lower().encode("utf-8")).hexdigest()[:16]


# ── HUMAN sources (pre-2022 where possible) ───────────────────────────────────

WIKITEXT_TEMPLATE = re.compile(r"\{\{[^{}]*\}\}")


def strip_wikitext(wt):
    """Rough wikitext -> prose for a 2021 revision (no key needed)."""
    wt = re.sub(r"<ref[^>]*?/>", "", wt)
    wt = re.sub(r"<ref[^>]*?>.*?</ref>", "", wt, flags=re.S)
    wt = re.sub(r"<!--.*?-->", "", wt, flags=re.S)
    wt = re.sub(r"\{\|.*?\|\}", "", wt, flags=re.S)               # tables
    prev = None
    while wt != prev:                                            # nested templates
        prev = wt
        wt = WIKITEXT_TEMPLATE.sub("", wt)
    wt = re.sub(r"\[\[(?:File|Image|Category):[^\]]*\]\]", "", wt, flags=re.I)
    wt = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", wt)          # [[a|b]] -> b
    wt = re.sub(r"\[\[([^\]]*)\]\]", r"\1", wt)                   # [[a]] -> a
    wt = re.sub(r"'{2,}", "", wt)                                # bold/italic
    wt = re.sub(r"^\s*==+.*?==+\s*$", "", wt, flags=re.M)        # headings
    wt = re.sub(r"<[^>]+>", " ", wt)
    # keep only the lead (before the first remaining section break) if present
    return clean(wt)


def fetch_wikipedia_2021(n, lo, hi, delay):
    """Random article CONTENT as it existed on 2021-12-31 (pre-ChatGPT, by
    construction). Two-step: random titles, then revision-as-of."""
    out, base = [], "https://en.wikipedia.org/w/api.php"
    while len(out) < n:
        rnd = {"format": "json", "action": "query", "generator": "random",
               "grnnamespace": "0", "grnlimit": "8", "prop": "info"}
        try:
            data = _get_json(base + "?" + urllib.parse.urlencode(rnd))
        except Exception as e:  # noqa: BLE001
            print(f"  [wiki] random failed: {e}", file=sys.stderr)
            break
        for page in (data.get("query") or {}).get("pages", {}).values():
            title = page.get("title", "")
            rev = {"format": "json", "action": "query", "prop": "revisions",
                   "titles": title, "rvprop": "content|timestamp", "rvslots": "main",
                   "rvlimit": "1", "rvstart": "2021-12-31T23:59:59Z"}
            try:
                rd = _get_json(base + "?" + urllib.parse.urlencode(rev))
            except Exception:  # noqa: BLE001
                continue
            for p in (rd.get("query") or {}).get("pages", {}).values():
                revs = p.get("revisions") or []
                if not revs:
                    continue
                slot = (revs[0].get("slots") or {}).get("main") or {}
                ts = revs[0].get("timestamp", "")
                if ts and ts >= "2022":          # provenance assert
                    continue
                prose = trim_words(strip_wikitext(slot.get("*", "")), hi)
                if lo <= words(prose) <= hi:
                    out.append(Row(prose, 0, "wikipedia", "encyclopedic", title,
                                   era="pre2022"))
            time.sleep(delay)
        print(f"  [wiki] {len(out)}/{n}", file=sys.stderr)
    return out[:n]


def fetch_arxiv_pre2022(n, lo, hi, delay):
    """Pre-2022 abstracts across fields (academic register, guaranteed human)."""
    cats = ["cs.LG", "cs.CL", "math.PR", "physics.gen-ph", "q-bio.NC",
            "econ.GN", "stat.ME", "astro-ph.GA", "cond-mat.soft"]
    ns = {"a": "http://www.w3.org/2005/Atom"}
    out, per = [], max(30, n // len(cats) + 15)
    for cat in cats:
        if len(out) >= n:
            break
        start = random.randint(0, 400)
        q = urllib.parse.urlencode({
            "search_query": f"cat:{cat} AND submittedDate:[20120101 TO 20211231]",
            "start": str(start), "max_results": str(per),
            "sortBy": "submittedDate", "sortOrder": "ascending"})
        try:
            root = ET.fromstring(_request(f"http://export.arxiv.org/api/query?{q}"))
        except Exception as e:  # noqa: BLE001
            print(f"  [arxiv:{cat}] failed: {e}", file=sys.stderr)
            continue
        for e in root.findall("a:entry", ns):
            pub = (e.find("a:published", ns).text or "")[:4] if e.find("a:published", ns) is not None else ""
            if pub and pub >= "2022":
                continue
            summ = e.find("a:summary", ns)
            title = e.find("a:title", ns)
            text = trim_words(clean(summ.text if summ is not None else ""), hi)
            if lo <= words(text) <= hi:
                out.append(Row(text, 0, "arxiv", "academic",
                               clean(title.text if title is not None else cat),
                               era="pre2022"))
        print(f"  [arxiv] {len(out)}/{n} (through {cat})", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


def fetch_guardian(n, key, lo, hi, delay, to_date="2021-12-31"):
    """Human news article BODIES via the Guardian Content API (bodyText = clean
    plain text, no extraction). Pre-2022 by default for clean labels."""
    if not key:
        print("  [guardian] no GUARDIAN_API_KEY; skipping", file=sys.stderr)
        return []
    out, page = [], 1
    sections = ["world", "politics", "environment", "science", "society", "books"]
    while len(out) < n and page <= 40:
        q = urllib.parse.urlencode({
            "api-key": key, "show-fields": "bodyText", "page-size": "50",
            "page": str(page), "to-date": to_date, "from-date": "2015-01-01",
            "section": sections[page % len(sections)], "order-by": "newest"})
        try:
            res = _get_json("https://content.guardianapis.com/search?" + q)
        except Exception as e:  # noqa: BLE001
            print(f"  [guardian] page {page} failed: {e}", file=sys.stderr)
            break
        for item in (res.get("response") or {}).get("results", []):
            body = ((item.get("fields") or {}).get("bodyText") or "")
            text = trim_words(clean(body), hi)
            if lo <= words(text) <= hi:
                out.append(Row(text, 0, "guardian", "news",
                               item.get("webTitle", "news"), era="pre2022"))
        print(f"  [guardian] {len(out)}/{n}", file=sys.stderr)
        page += 1
        time.sleep(delay)
    return out[:n]


# Free labeled human+AI HF datasets, sampled via datasets-server /rows. We use the
# HUMAN side of clean conversational sets as real human chatty; the AI side and
# multi-generator sets are routed to the HELD-OUT eval pool (see --external).
def _adapt_tldr(row):
    # topic must be CONTENT-specific (not the subreddit, which collides) so each
    # human post seeds a distinct matched pair. Use the TL;DR summary if present.
    t = row.get("normalizedBody") or row.get("content") or row.get("body")
    if not t:
        return []
    topic = (row.get("summary") or " ".join(t.split()[:14])).strip()
    return [(0, "conversation", topic, t)]


def _adapt_arxivsum(row):
    """ccdv/arxiv-summarization: the ABSTRACT is the formal academic human text;
    seed the matched AI abstract from the abstract's opening (its subject)."""
    a = (row.get("abstract") or "").strip()
    if not a:
        return []
    return [(0, "academic", " ".join(a.split()[:18]), a)]


def _adapt_xsum(row):
    """EdinburghNLP/xsum: document = BBC news article (formal human); summary is a
    clean one-sentence topic seed for the matched AI report."""
    doc = (row.get("document") or "").strip()
    if not doc:
        return []
    topic = (row.get("summary") or " ".join(doc.split()[:15])).strip()
    return [(0, "news", topic, doc)]


def _adapt_cnndm(row):
    art = (row.get("article") or "").strip()
    if not art:
        return []
    topic = (row.get("highlights") or " ".join(art.split()[:15])).replace("\n", " ").strip()
    return [(0, "news", topic, art)]


def _adapt_hc3(row):
    out, q = [], row.get("question", "")
    for h in (row.get("human_answers") or [])[:1]:
        if h:
            out.append((0, "qa", q, h))
    for a in (row.get("chatgpt_answers") or [])[:1]:
        if a:
            out.append((1, "qa", q, a))
    return out


# Multi-generator dataset adapters. Each returns 5-tuples
# (label, register, topic, text, generator) so the imported AI carries its REAL
# generator name — essential for the leave-one-generator-out cross-gen eval.
def _adapt_raid(row):
    g = row.get("generation")
    if not g:
        return []
    model = row.get("model", "")
    label = 0 if model == "human" else 1
    dom = row.get("domain", "web")
    return [(label, dom, " ".join(g.split()[:12]), g,
             "human" if label == 0 else f"raid:{model}")]


def _adapt_mage(row):
    """MAGE labels are INVERTED vs ours: label 1 = HUMAN, 0 = machine. src encodes
    domain_generator (cmv_human, xsum_gpt-3.5...), so derive label/generator from src."""
    t = row.get("text")
    src = row.get("src") or "mage"
    if not t:
        return []
    is_human = src.endswith("_human") or str(row.get("label")) == "1"
    label = 0 if is_human else 1
    dom = src.split("_")[0] if "_" in src else "web"
    gen = "human" if label == 0 else ("mage:" + (src.split("_", 1)[1] if "_" in src else "unknown"))
    return [(label, dom, " ".join(t.split()[:12]), t, gen)]


def _adapt_coling(row):
    """COLING_2025_MGT_en: label 1 = AI (matches ours); `model` names the generator
    (gpt4, gpt4o, llama3-8b, human...), `sub_source` the domain."""
    t = row.get("text")
    if not t:
        return []
    try:
        label = int(row.get("label"))
    except (TypeError, ValueError):
        return []
    model = row.get("model", "?")
    dom = row.get("sub_source", "web")
    return [(label, dom, " ".join(t.split()[:12]), t,
             "human" if label == 0 else f"coling:{model}")]


# preset -> dict(ds, cfg, split, adapt, role, license). roles: human (human side ->
# train), both (human -> train, AI -> eval), train (human -> train AND AI -> train),
# external (everything -> held-out eval). license: commercial | research | copyleft;
# --hf-commercial-only keeps only commercial-safe sets for a shipped model.
HF = {
    "tldr":      dict(ds="webis/tldr-17", cfg="default", split="train", adapt=_adapt_tldr, role="human", license="commercial"),
    "hc3":       dict(ds="Hello-SimpleAI/HC3", cfg="all", split="train", adapt=_adapt_hc3, role="both", license="copyleft"),
    "sciarxiv":  dict(ds="ccdv/arxiv-summarization", cfg="document", split="train", adapt=_adapt_arxivsum, role="human", license="commercial"),
    "xsum":      dict(ds="EdinburghNLP/xsum", cfg="default", split="train", adapt=_adapt_xsum, role="human", license="commercial"),
    "cnndm":     dict(ds="abisee/cnn_dailymail", cfg="3.0.0", split="train", adapt=_adapt_cnndm, role="human", license="commercial"),
    # multi-generator AI for TRAINING (GPT-4/4o/Llama/etc. breadth)
    "raid":      dict(ds="liamdugan/raid", cfg="raid", split="train", adapt=_adapt_raid, role="train", license="commercial"),
    "mage":      dict(ds="yaful/MAGE", cfg="default", split="train", adapt=_adapt_mage, role="train", license="commercial"),
    "coling":    dict(ds="Jinyan1/COLING_2025_MGT_en", cfg="default", split="train", adapt=_adapt_coling, role="train", license="research"),
    # held-out EVAL breadth (never trained on)
    "raid_test": dict(ds="liamdugan/raid", cfg="raid_test", split="test", adapt=_adapt_raid, role="external", license="commercial"),
    "mage_test": dict(ds="yaful/MAGE", cfg="default", split="test", adapt=_adapt_mage, role="external", license="commercial"),
}


def _hf_size(ds):
    try:
        d = _get_json("https://datasets-server.huggingface.co/size?dataset="
                      + urllib.parse.quote(ds))
        for s in d.get("size", {}).get("splits", []):
            return int(s.get("num_rows", 100000))
    except Exception:  # noqa: BLE001
        pass
    return 100000


def fetch_hf(preset, n, lo, hi, delay):
    meta = HF[preset]
    ds, cfg, sp, adapt = meta["ds"], meta["cfg"], meta["split"], meta["adapt"]
    size = _hf_size(ds)
    out, tries = [], 0
    while len(out) < n and tries < n // 8 + 60:
        tries += 1
        off = random.randint(0, max(0, size - 100))
        url = (f"https://datasets-server.huggingface.co/rows?dataset={urllib.parse.quote(ds)}"
               f"&config={cfg}&split={sp}&offset={off}&length=100")
        try:
            d = _get_json(url)
        except Exception as e:  # noqa: BLE001
            print(f"  [hf:{preset}] page failed: {e}", file=sys.stderr)
            time.sleep(delay)
            continue
        for item in d.get("rows", []):
            for tup in adapt(item.get("row", {})):
                label, reg, topic, text = tup[0], tup[1], tup[2], tup[3]
                gen = tup[4] if len(tup) > 4 else ("human" if label == 0 else f"hf_{preset}")
                text = trim_words(clean(text), hi)
                if lo <= words(text) <= hi:
                    out.append(Row(text, label, f"hf_{preset}", reg, topic,
                                   generator=gen,
                                   era=("pre2022" if preset == "tldr" else "")))
        print(f"  [hf:{preset}] {len(out)}/{n}", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


def import_human_jsonl(globs, lo, hi):
    """Import your own pre-2022 human dumps (pushshift, stackexchange, books).
    Rows: {"text","register"?,"source"?,"topic"?}. Label always 0."""
    out = []
    for pattern in globs:
        for path in glob.glob(pattern):
            for line in open(path, encoding="utf-8", errors="ignore"):
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:  # noqa: BLE001
                    continue
                t = trim_words(clean(r.get("text", "")), hi)
                if lo <= words(t) <= hi:
                    out.append(Row(t, 0, r.get("source", "import"),
                                   r.get("register", "conversation"),
                                   r.get("topic", ""), era=r.get("era", "pre2022")))
            print(f"  [import] {len(out)} from {path}", file=sys.stderr)
    return out


# ── AI generation (matched to a human passage) ────────────────────────────────

REGISTER_PROMPT = {
    "encyclopedic": "Write a neutral encyclopedic passage (~{w} words) about: {t}. Prose only, no title, no lists.",
    "academic":     "Write an academic abstract (~{w} words) on: {t}. Just the abstract text, no 'Abstract:' label.",
    "news":         "Write a ~{w}-word news report on: {t}. Body text only, no headline or byline.",
    "conversation": "Write a ~{w}-word casual forum comment about: {t}. First person, opinionated, plain text.",
    "qa":           "In ~{w} words, helpfully answer: {t}. Answer only, no preamble.",
    # Added for contemporary-register diversity (the model over-flagged these as
    # human). In --rewrite-mode only the key membership matters (the passage is
    # rewritten); these template values are the topic-mode fallback.
    "business":      "Write a ~{w}-word work email body about: {t}. Plain prose, no headers, no signature.",
    "instructional": "Write ~{w} words of plain how-to instructions for: {t}. Prose steps, no numbered list.",
    "fiction_modern": "Write a ~{w}-word passage of literary fiction about: {t}. Narrative prose only.",
    "reviews":       "Write a ~{w}-word first-person product review of: {t}. Casual, plain text.",
}


def _gen_anthropic(prompt, model, key, max_tokens, temperature=0.8):
    res = _get_json("https://api.anthropic.com/v1/messages", method="POST",
                    headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
                    data={"model": model, "max_tokens": max_tokens, "temperature": temperature,
                          "messages": [{"role": "user", "content": prompt}]})
    return "".join(b.get("text", "") for b in res.get("content", []))


def _gen_gemini(prompt, model, key, max_tokens, temperature=0.8):
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    res = _get_json(url, method="POST", headers={"x-goog-api-key": key},
                    data={"contents": [{"parts": [{"text": prompt}]}],
                          "generationConfig": {"maxOutputTokens": max_tokens,
                                               "temperature": temperature}})
    cand = (res.get("candidates") or [{}])[0]
    return "".join(p.get("text", "") for p in (cand.get("content") or {}).get("parts", []))


_BROWSER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")


def _gen_chat(base_url, prompt, model, key, max_tokens, temperature=0.8):
    """Any OpenAI-compatible /chat/completions endpoint: OpenAI, Cerebras, Groq,
    OpenRouter, GitHub Models. Cerebras sits behind Cloudflare (1010-blocks the urllib
    default UA), so send a browser UA. gpt-oss / o-series are REASONING models that burn
    the budget on hidden reasoning before emitting content, so give headroom and keep
    reasoning short or `content` comes back empty."""
    reasoning = ("oss" in model) or bool(re.search(r"(^|/)o[134]", model)) or ("reason" in model.lower())
    body = {"model": model, "temperature": temperature,
            "max_tokens": max_tokens + (2048 if reasoning else 0),
            "messages": [{"role": "user", "content": prompt}]}
    if reasoning:
        body["reasoning_effort"] = "low"
    res = _get_json(base_url, method="POST",
                    headers={"Authorization": f"Bearer {key}", "User-Agent": _BROWSER_UA},
                    data=body)
    return ((res.get("choices") or [{}])[0].get("message") or {}).get("content") or ""


# Provider registry. `kind` selects the caller; `env` is the .env key; `models` are the
# defaults used when --<family>-models isn't passed. gpt-oss via cerebras/groq/openrouter
# is Apache-2.0 (clean to TRAIN on); `github` reaches true GPT-4.1/5 but under OpenAI terms
# (~50 req/day) so use it for an EVAL slice only, never the training set.
PROVIDERS = {
    "anthropic":  dict(kind="anthropic", env="ANTHROPIC_API_KEY", models=["claude-haiku-4-5"]),
    "gemini":     dict(kind="gemini", env="GEMINI_API_KEY", models=["gemini-2.5-flash-lite"]),
    "openai":     dict(kind="chat", env="OPENAI_API_KEY",
                       base="https://api.openai.com/v1/chat/completions", models=["gpt-5.4-mini"]),
    "cerebras":   dict(kind="chat", env="CEREBRAS_API_KEY",
                       base="https://api.cerebras.ai/v1/chat/completions", models=["gpt-oss-120b"]),
    "groq":       dict(kind="chat", env="GROQ_API_KEY",
                       base="https://api.groq.com/openai/v1/chat/completions",
                       models=["openai/gpt-oss-120b", "llama-3.3-70b-versatile"]),
    "openrouter": dict(kind="chat", env="OPENROUTER_API_KEY",
                       base="https://openrouter.ai/api/v1/chat/completions",
                       models=["openai/gpt-oss-120b:free"]),
    "github":     dict(kind="chat", env="GITHUB_TOKEN",
                       base="https://models.github.ai/inference/chat/completions",
                       models=["openai/gpt-4.1"]),
}


def generate(family, prompt, model, key, max_tokens, temperature=0.8):
    p = PROVIDERS[family]
    if p["kind"] == "anthropic":
        return _gen_anthropic(prompt, model, key, max_tokens, temperature)
    if p["kind"] == "gemini":
        return _gen_gemini(prompt, model, key, max_tokens, temperature)
    return _gen_chat(p["base"], prompt, model, key, max_tokens, temperature)


# Content-matched rewrite instructions (the density fix). Varied so the AI side doesn't
# bake in one rewrite template; all hard-constrain numeric/entity fidelity.
REWRITE_INSTRUCTIONS = [
    "Rewrite the passage below in your own words. Preserve every number, dollar amount, "
    "percentage, date, and proper noun EXACTLY as written; add no new figures; round nothing. "
    "Change only wording and sentence structure. Keep the length similar. Output only the rewrite.",
    "Restructure and re-express the passage below. Keep all figures, dates, and names verbatim; "
    "introduce no new facts. Aim for the same length. Output only the rewritten passage.",
    "Produce a polished rewrite of the following. Every statistic, dollar figure, percentage, "
    "date, and proper noun must appear exactly as given; invent nothing. Keep length similar. "
    "Output only the rewrite.",
    "Express the same information as the passage below in different words and a different "
    "structure. All numbers, %, $, dates, and names stay identical; no added facts. Similar "
    "length. Output only the result.",
]


def _too_similar(a, b, thresh=0.92):
    """Near-verbatim echo guard for rewrites: a good rewrite keeps the figures but rewords."""
    return difflib.SequenceMatcher(None, a, b).ratio() >= thresh


def generate_matched(humans, families, models_by_family, keys, lo, hi, delay,
                     pairs_per_human, disguise_frac, rewrite_mode=False):
    """For each human passage, generate AI counterpart(s). Topic mode writes on the same
    topic/register/length; --rewrite-mode (content-matched) rewrites the human passage
    preserving every figure/entity, so numeric density is SHARED and only authorship
    differs (the density-confound fix). Family + temperature are varied per row to avoid
    a single paraphraser becoming the spurious signal (DIPPER)."""
    ai = []
    pool = [h for h in humans if h.register in REGISTER_PROMPT]
    random.shuffle(pool)
    for h in pool:
        for _ in range(pairs_per_human):
            fam = random.choice(families)
            model = random.choice(models_by_family[fam])
            temperature = random.choice([0.6, 0.8, 1.0])
            target = max(lo, min(hi, words(h.text)))
            if rewrite_mode:
                prompt = random.choice(REWRITE_INSTRUCTIONS) + "\n\nPASSAGE:\n" + h.text
                variant, budget = "rewrite", int(words(h.text) * 2) + 96
            else:
                prompt = REGISTER_PROMPT[h.register].format(w=target, t=(h.topic or "the subject")[:200])
                variant, budget = "clean", int(target * 2) + 64
            try:
                raw = generate(fam, prompt, model, keys[fam], budget, temperature)
            except Exception as e:  # noqa: BLE001
                print(f"  [gen:{fam}] failed: {e}", file=sys.stderr)
                time.sleep(1.5)
                continue
            text = trim_words(strip_preamble(clean(raw)), hi)
            if not (lo <= words(text) <= hi):
                time.sleep(delay)
                continue
            if rewrite_mode and _too_similar(text, clean(h.text)):
                time.sleep(delay)        # near-verbatim echo deflates the signal; drop it
                continue
            ai.append(Row(text, 1, f"ai_{fam}", h.register, h.topic,
                          generator=model, variant=variant, era="2026"))
            # disguise: a fraction get a humanized counterpart (label stays 1)
            if random.random() < disguise_frac:
                dv = make_disguise(text, fam, model, keys[fam], lo, hi)
                if dv:
                    ai.append(Row(dv[1], 1, f"ai_{fam}", h.register, h.topic,
                                  generator=model, variant=dv[0], era="2026"))
            if len(ai) % 25 == 0:
                print(f"  [gen] {len(ai)} AI rows", file=sys.stderr)
            time.sleep(delay)
    print(f"  [gen] {len(ai)} AI rows total", file=sys.stderr)
    return ai


def make_disguise(text, fam, model, key, lo, hi):
    """Round-trip humanize: the cheap technique that actually defeats detectors."""
    kind = random.choice(["paraphrased", "backtranslated"])
    if kind == "paraphrased":
        prompt = ("Rewrite the following so it reads like a real person wrote it: vary "
                  "sentence length, use plain wording, allow a small imperfection. Keep "
                  "the meaning and length. Output only the rewrite.\n\n" + text)
    else:
        prompt = ("Translate the following to German, then translate your German back to "
                  "natural English. Output only the final English.\n\n" + text)
    try:
        raw = generate(fam, prompt, model, key, int(words(text) * 2) + 64)
    except Exception:  # noqa: BLE001
        return None
    out = trim_words(strip_preamble(clean(raw)), hi)
    return (kind, out) if lo <= words(out) <= hi else None


# ── assembly: dedup, balance-in-cell, topic split, write, self-audit ──────────

def dedup(rows):
    seen, out = set(), []
    for r in rows:
        k = r.key()
        if k not in seen:
            seen.add(k)
            out.append(r)
    return out


def balance_in_cells(rows, cap=0.60):
    """Within each (source, register) cell, trim the majority label so no cell is
    more than `cap` one class. Decorrelates label from source x register."""
    from collections import defaultdict
    cells = defaultdict(lambda: {0: [], 1: []})
    for r in rows:
        cells[(r.source, r.register)][r.label].append(r)
    out = []
    for cell in cells.values():
        h, a = cell[0], cell[1]
        if not h or not a:                    # single-label cell: keep as-is
            out += h + a
            continue
        m = min(len(h), len(a))
        hi_allowed = int(m / (1 - cap)) if cap < 1 else max(len(h), len(a))
        random.shuffle(h); random.shuffle(a)
        out += h[:min(len(h), hi_allowed)] + a[:min(len(a), hi_allowed)]
    return out


def length_match(rows, width=30, cap=0.60, floor=4):
    """Decorrelate passage LENGTH from label so the model can't shortcut on
    short->AI / long->human. Bin rows by word count (width-word bins): in two-label
    bins trim the majority to <= cap; in one-label bins (a pure length signal, e.g.
    the long human-only tail) keep only a small `floor` so no length band is owned by
    one class. The matched-pair core (topics carrying BOTH labels) is PROTECTED and
    untouched — it is already length-matched pair-by-pair — so only unpaired dataset
    rows are dropped."""
    from collections import defaultdict
    labels_by_topic = defaultdict(set)
    for r in rows:
        labels_by_topic[r.topic].add(r.label)
    paired = {t for t, ls in labels_by_topic.items() if {0, 1} <= ls}
    protected = [r for r in rows if r.topic in paired]
    # Equalize length WITHIN each matched pair: the Claude rewrites run ~0.75x their
    # source human's length, which would leak a short->AI signal. Trim every row in a
    # paired topic to that topic's shortest member (content-preserving truncation, the
    # label stays valid), so length carries zero signal inside the matched core.
    by_topic = defaultdict(list)
    for r in protected:
        by_topic[r.topic].append(r)
    for group in by_topic.values():
        tgt = min(words(r.text) for r in group)
        for r in group:
            if words(r.text) > tgt:
                r.text = trim_words(r.text, tgt)
    bins = defaultdict(lambda: {0: [], 1: []})
    for r in rows:
        if r.topic not in paired:
            bins[words(r.text) // width][r.label].append(r)
    kept = []
    for cell in bins.values():
        h, a = cell[0], cell[1]
        random.shuffle(h); random.shuffle(a)
        if not h or not a:                         # one-sided length band -> pure signal
            band = h + a
            kept += band if len(band) <= floor else band[:floor]
            continue
        m = min(len(h), len(a))
        hi = int(m / (1 - cap)) if cap < 1 else max(len(h), len(a))
        kept += h[:hi] + a[:hi]
    return protected + kept


def split_by_topic(rows, eval_frac):
    """Eval = MATCHED-PAIR CORE only. Only whole topics that carry BOTH a human and an
    AI row (the content-matched rewrites share topic_id with their human source) are
    eligible for eval, so eval is balanced and content-matched by construction -> no
    source/register split can inflate it. Everything unpaired (dataset humans without an
    AI partner, dataset AI without a human partner) stays in TRAIN for generator breadth.
    Cross-gen rows (split=='crossgen', e.g. held-out mage_test/raid_test) are pulled out
    to their own file and never touch train or the primary eval.
    Returns (train, eval, crossgen)."""
    from collections import defaultdict
    crossgen = [r for r in rows if r.split == "crossgen"]
    pool = [r for r in rows if r.split != "crossgen"]
    labels_by_topic = defaultdict(set)
    for r in pool:
        labels_by_topic[r.topic].add(r.label)
    paired = sorted(t for t, ls in labels_by_topic.items() if {0, 1} <= ls)
    random.shuffle(paired)
    k = max(1, int(len(paired) * eval_frac)) if paired else 0
    eval_topics = set(paired[:k])
    train = [r for r in pool if r.topic not in eval_topics]
    ev = [r for r in pool if r.topic in eval_topics]
    return train, ev, crossgen


def cheat_accuracy(rows, key):
    from collections import defaultdict
    g = defaultdict(lambda: [0, 0])
    for r in rows:
        g[getattr(r, key)][r.label] += 1
    tot = sum(h + a for h, a in g.values())
    return (sum(max(h, a) for h, a in g.values()) / tot) if tot else 0


def write_csv(path, rows):
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["text", "label", "source", "register", "generator",
                    "variant", "era", "topic_id", "words"])
        for r in rows:
            w.writerow([r.text, r.label, r.source, r.register, r.generator,
                        r.variant, r.era, topic_id(r.topic), words(r.text)])


def load_human_csv(path):
    """Assembly mode: load human rows from a prior build CSV. topic_id is the
    grouping key for the topic-held-out split."""
    out = []
    with open(path, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                label = int(r.get("label", 0))
            except ValueError:
                continue
            if label != 0 or not (r.get("text") or "").strip():
                continue
            out.append(Row(r["text"], 0, r.get("source", "import"),
                           r.get("register", "?"),
                           r.get("topic_id") or r.get("topic") or "import",
                           generator="human", variant=r.get("variant", "raw"),
                           era=r.get("era", "")))
    return out


def load_ai_jsonl(path):
    """Assembly mode: load AI rows generated outside this script (e.g. by Claude Code
    agents under your subscription). One JSON object per line:
      {"text","topic_id"|"topic","register","generator"?,"variant"?}
    Label is forced to 1; topic_id pairs each AI row back to its human."""
    out = []
    for line in open(path, encoding="utf-8", errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        t = (r.get("text") or "").strip()
        if not t:
            continue
        gen = r.get("generator", "agent")
        out.append(Row(t, 1, r.get("source", f"ai_{gen}"), r.get("register", "?"),
                       r.get("topic_id") or r.get("topic") or "",
                       generator=gen, variant=r.get("variant", "clean"), era="2026"))
    return out


def write_specs(humans, path):
    """Emit generation specs for agent/external matched generation: one line per
    generatable human passage, carrying topic_id so AI rows pair back to it."""
    n = 0
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for h in humans:
            if h.register not in REGISTER_PROMPT:
                continue
            f.write(json.dumps({"topic_id": topic_id(h.topic),
                                "topic": (h.topic or "the subject")[:300],
                                "register": h.register,
                                "words": words(h.text)}) + "\n")
            n += 1
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    # human sources
    ap.add_argument("--wikipedia", type=int, default=0)
    ap.add_argument("--arxiv", type=int, default=0)
    ap.add_argument("--guardian", type=int, default=0)
    ap.add_argument("--hf", default="", help="comma presets: " + ",".join(HF))
    ap.add_argument("--hf-n", type=int, default=300)
    ap.add_argument("--human-jsonl", nargs="*", default=[],
                    help="your pre-2022 human dumps (jsonl with a 'text' field)")
    # assembly mode (agent/subscription generation: collect humans here, generate
    # AI with Claude Code agents, then merge the agent output back in)
    ap.add_argument("--human-csv", default=None,
                    help="assembly: load humans from a prior build CSV (e.g. human_pool.csv)")
    ap.add_argument("--ai-jsonl", default=None,
                    help="assembly: load AI rows from agent/external JSONL; skips API generation")
    ap.add_argument("--emit-specs", default=None,
                    help="write generation-spec JSONL (topic/register/words/topic_id) for agents")
    ap.add_argument("--collect-only", action="store_true",
                    help="collect humans (+ emit specs) then stop, before any generation/split")
    # generation
    ap.add_argument("--families", default="anthropic,gemini",
                    help="comma list from: anthropic,gemini,openai,cerebras,groq,openrouter,github "
                         "(repeat a name to weight it, e.g. anthropic,anthropic,gemini)")
    ap.add_argument("--anthropic-models", default="claude-haiku-4-5")
    ap.add_argument("--gemini-models", default="gemini-2.5-flash-lite")
    ap.add_argument("--openai-models", default="gpt-5.4-mini")
    ap.add_argument("--cerebras-models", default="gpt-oss-120b")
    ap.add_argument("--groq-models", default="openai/gpt-oss-120b,llama-3.3-70b-versatile")
    ap.add_argument("--openrouter-models", default="openai/gpt-oss-120b:free")
    ap.add_argument("--github-models", default="openai/gpt-4.1")
    ap.add_argument("--rewrite-mode", action="store_true",
                    help="content-matched generation: rewrite each human passage preserving every "
                         "figure/entity (shares numeric density; the density-confound fix)")
    ap.add_argument("--pairs-per-human", type=int, default=1)
    ap.add_argument("--disguise", type=float, default=0.25,
                    help="fraction of AI rows that also get a humanized variant")
    ap.add_argument("--max-humans-for-gen", type=int, default=2000,
                    help="cap how many human passages drive generation (cost control)")
    # shaping
    ap.add_argument("--min-words", type=int, default=60)
    ap.add_argument("--max-words", type=int, default=300)
    ap.add_argument("--delay", type=float, default=0.6)
    ap.add_argument("--eval-frac", type=float, default=0.15)
    ap.add_argument("--cell-cap", type=float, default=0.60)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out-dir", default="data/corpus")
    ap.add_argument("--hf-commercial-only", action="store_true",
                    help="drop HF presets whose license isn't commercial-safe "
                         "(hc3 copyleft, coling research) — for a shipped model")
    args = ap.parse_args()

    load_dotenv()
    random.seed(args.seed)
    lo, hi, delay = args.min_words, args.max_words, args.delay

    # 1) HUMAN
    print("collecting HUMAN (pre-2022 where possible)…", file=sys.stderr)
    humans, externals, dataset_ai = [], [], []
    if args.human_csv:
        humans += load_human_csv(args.human_csv)
        print(f"  [human-csv] {len(humans)} from {args.human_csv}", file=sys.stderr)
    if args.wikipedia:
        humans += fetch_wikipedia_2021(args.wikipedia, lo, hi, delay)
    if args.arxiv:
        humans += fetch_arxiv_pre2022(args.arxiv, lo, hi, delay)
    if args.guardian:
        humans += fetch_guardian(args.guardian, os.environ.get("GUARDIAN_API_KEY"),
                                 lo, hi, delay)
    if args.human_jsonl:
        humans += import_human_jsonl(args.human_jsonl, lo, hi)
    for preset in [p.strip() for p in args.hf.split(",") if p.strip()]:
        if preset not in HF:
            print(f"  [hf] unknown preset {preset}; have {list(HF)}", file=sys.stderr); continue
        meta = HF[preset]
        if args.hf_commercial_only and meta["license"] != "commercial":
            print(f"  [hf] skip {preset} (license={meta['license']}; --hf-commercial-only)", file=sys.stderr)
            continue
        role = meta["role"]
        for r in fetch_hf(preset, args.hf_n, lo, hi, delay):
            if role == "external" or (role == "both" and r.label == 1):
                r.split = "crossgen"; externals.append(r)  # separate cross-gen probe file
            elif r.label == 0:
                humans.append(r)
            else:
                dataset_ai.append(r)                       # role 'train' AI -> training
    humans = dedup(humans)
    dataset_ai = dedup(dataset_ai)
    print(f"HUMAN: {len(humans)} | dataset AI (train): {len(dataset_ai)} | "
          f"external (held-out eval): {len(externals)}", file=sys.stderr)

    if args.emit_specs:
        k = write_specs(humans, args.emit_specs)
        write_csv(os.path.join(args.out_dir, "human_pool.csv"), humans)
        print(f"  wrote {k} specs → {args.emit_specs}; humans → "
              f"{args.out_dir}/human_pool.csv", file=sys.stderr)
    if args.collect_only:
        print("--collect-only: stopping before generation.", file=sys.stderr)
        return

    # 2) AI: import agent/external rows, OR matched API generation
    if args.ai_jsonl:
        ai = load_ai_jsonl(args.ai_jsonl)
        print(f"loaded {len(ai)} AI rows from {args.ai_jsonl} (skipping API generation)",
              file=sys.stderr)
    else:
        families = [f.strip() for f in args.families.split(",") if f.strip()]
        unknown = [f for f in families if f not in PROVIDERS]
        if unknown:
            print(f"  [gen] unknown families {unknown}; valid: {list(PROVIDERS)}", file=sys.stderr)
        keys = {f: os.environ.get(PROVIDERS[f]["env"]) for f in PROVIDERS}
        families = [f for f in families if f in PROVIDERS and keys.get(f)]
        if not families:
            print("\nNo generation key found in .env for the requested --families "
                  "(need the matching provider key, e.g. CEREBRAS_API_KEY / GROQ_API_KEY / "
                  "GEMINI_API_KEY). Writing HUMAN-only corpus.", file=sys.stderr)
            ai = []
        else:
            overrides = {"anthropic": args.anthropic_models, "gemini": args.gemini_models,
                         "openai": args.openai_models, "cerebras": args.cerebras_models,
                         "groq": args.groq_models, "openrouter": args.openrouter_models,
                         "github": args.github_models}
            models_by_family = {
                f: ([m.strip() for m in (overrides.get(f) or "").split(",") if m.strip()]
                    or PROVIDERS[f]["models"]) for f in families}
            drivers = humans[:]
            random.shuffle(drivers)
            drivers = drivers[:args.max_humans_for_gen]
            mode = "rewrite/content-matched" if args.rewrite_mode else "topic-matched"
            print(f"generating {mode} AI from {len(drivers)} human passages × "
                  f"{families} …", file=sys.stderr)
            ai = generate_matched(drivers, families, models_by_family, keys, lo, hi,
                                  delay, args.pairs_per_human, args.disguise,
                                  rewrite_mode=args.rewrite_mode)

    # 3) ASSEMBLE  (matched core + dataset breadth in train; externals -> cross-gen file)
    core = balance_in_cells(dedup(humans + ai + dataset_ai), cap=args.cell_cap)
    core = length_match(core)                    # kill the short->AI / long->human signal
    allrows = core + dedup(externals)            # externals carry split=='crossgen'
    train, ev, crossgen = split_by_topic(allrows, args.eval_frac)

    write_csv(os.path.join(args.out_dir, "train.csv"), train)
    write_csv(os.path.join(args.out_dir, "eval.csv"), ev)
    if crossgen:
        write_csv(os.path.join(args.out_dir, "crossgen_eval.csv"), crossgen)

    # 4) SELF-AUDIT
    def report(name, rows):
        n = len(rows); a = sum(r.label for r in rows)
        print(f"\n[{name}] {n} rows  human={n-a} AI={a}")
        if n:
            print(f"   register cheat : {cheat_accuracy(rows,'register')*100:4.1f}%"
                  "   <- TEXT-VISIBLE: THIS is the one that matters (goal ≈50%)")
            print(f"   source cheat   : {cheat_accuracy(rows,'source')*100:4.1f}%"
                  "   (provenance label; ~100% by construction — the model never sees it)")
            print(f"   generator cheat: {cheat_accuracy(rows,'generator')*100:4.1f}%"
                  "   (provenance label; ~100% by construction — the model never sees it)")
    report("train", train)
    report("eval", ev)
    if crossgen:
        report("crossgen", crossgen)
    print(f"\nwrote {args.out_dir}/train.csv and eval.csv"
          + (f" and crossgen_eval.csv ({len(crossgen)} held-out cross-gen rows)" if crossgen else ""))
    print("GOAL: EVAL register cheat ≈ 50% — eval is matched-pair-only, so it MUST be near "
          "baseline; if not, the pairing broke. TRAIN register cheat runs higher because the "
          "dataset-breadth rows (raid/mage/coling, for GPT/Llama/Mixtral coverage) are unpaired "
          "— that is fine: the model never sees register, and the surface-feature probe (--probe) "
          "is what proves no TEXT-VISIBLE shortcut leaked in. crossgen = cross-generator recall "
          "probe, never trained on.")
    print("\nnext:")
    print("  python3 scripts/audit-confound.py --data "
          f"{args.out_dir}/train.csv {args.out_dir}/eval.csv --probe")
    print("  python3 scripts/audit-confound.py --ood data/corpus/ood_human.csv --model <model>")


if __name__ == "__main__":
    main()
