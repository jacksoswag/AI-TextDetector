#!/usr/bin/env python3
r"""
collect-corpus.py — pull real HUMAN text from the open web and generate matched
AI text, into the `text,label` CSV that scripts/calibrate.py and
scripts/measure-gate.py consume (1 = AI, 0 = human).

Why this exists
---------------
calibrate.py / measure-gate.py need labeled data the model never trained on,
heavy on the registers that misfire (encyclopedic / academic / formal human
prose the small detector mistakes for AI). This script supplies it:

  HUMAN (label 0), from sources that give clean full-text passages:
    * Wikipedia  — encyclopedic register (action API, no key)
    * arXiv      — academic abstracts across fields (Atom API, no key)
    * Reddit     — conversational/social register (public .json, no key)
    * Serper     — diverse web/news via Google results, optionally fetching the
                   result pages for full paragraphs (needs your serper.dev key)

  AI (label 1), generated to MATCH the human topics + registers + lengths, so a
  calibration learns provenance, not topic. Styles include a deliberate
  "assistant reply" bucket — the chatty, hedged, list-y output that currently
  evades the detector — generated from a real LLM (Anthropic or OpenAI via
  plain HTTPS; bring your own key, nothing is embedded here).

Keys (env or flags), all optional except the AI provider you choose:
    SERPER_API_KEY        --serper-key       (serper.dev)
    ANTHROPIC_API_KEY     --ai-key           (default AI provider)
    OPENAI_API_KEY        --ai-key           (with --ai-provider openai)

Quick start (no paid keys — human only, to first SEE the gate distribution):
    python3 scripts/collect-corpus.py --wikipedia 150 --arxiv 100 \
        --reddit 100 --subreddits AskHistorians,explainlikeimfive,changemyview \
        --no-ai --out data/corpus/human_only.csv
    python3 scripts/measure-gate.py --data data/corpus/human_only.csv  # all label 0

Full calibration corpus (balanced human + AI):
    export ANTHROPIC_API_KEY=sk-...   SERPER_API_KEY=...
    python3 scripts/collect-corpus.py \
        --wikipedia 200 --arxiv 150 --reddit 150 \
        --subreddits AskHistorians,explainlikeimfive,changemyview,personalfinance,askscience \
        --serper 100 --serper-queries "climate policy 2026;home espresso guide;supreme court ruling analysis" \
        --ai 600 --ai-provider anthropic --ai-model claude-haiku-4-5-20251001 \
        --balance --out data/corpus/calib.csv
    python3 scripts/calibrate.py   --data data/corpus/calib.csv --target-fpr 0.005
    python3 scripts/measure-gate.py --data data/corpus/calib.csv

Output: a `text,label,source,register,words` CSV. calibrate.py / measure-gate.py
read only text+label; the extra columns are for your own inspection/balancing
and are compatible with feeding build-corpus.py later. Be a good web citizen:
this respects per-request delays and a descriptive User-Agent; don't crank the
counts into the thousands against these free endpoints.
"""

import argparse
import csv
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

USER_AGENT = "ai-detector-corpus-builder/1.0 (research use; on-device AI-text-detector calibration)"


def load_dotenv(path=".env"):
    """Minimal .env loader (no dependency): set os.environ for KEY=VALUE lines
    that aren't already in the environment. Lets SERPER_API_KEY / ANTHROPIC_API_KEY
    / OPENAI_API_KEY live in a gitignored .env."""
    if not os.path.exists(path):
        return
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))

# Registers mirror FilterCore TextDomain / build-corpus.py DOMAINS so the corpus
# can also feed the fine-tune pipeline unchanged.
PREAMBLE_RE = re.compile(
    r"^(sure|certainly|of course|absolutely|here(?:'s| is)|i'd be happy to|"
    r"great question|let'?s|below is|here are)\b[^\n.]*[:.]?\s*",
    re.IGNORECASE,
)


# ── HTTP helpers ──────────────────────────────────────────────────────────────

def _request(url, *, method="GET", headers=None, data=None, timeout=30, retries=3):
    h = {"User-Agent": USER_AGENT}
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
                return resp.read().decode("utf-8", errors="replace")
        except Exception as e:  # noqa: BLE001 — network is best-effort, keep going
            last = e
            time.sleep(1.5 * (attempt + 1))
    raise last


def _get_json(url, **kw):
    return json.loads(_request(url, **kw))


# ── Cleaning ─────────────────────────────────────────────────────────────────

def clean(text):
    if not text:
        return ""
    text = html.unescape(text)
    text = re.sub(r"https?://\S+", " ", text)            # strip URLs
    text = re.sub(r"\[[^\]]*\]\([^)]*\)", " ", text)      # markdown links
    text = re.sub(r"[*_`>#]+", " ", text)                # md emphasis/quote/heading marks
    text = re.sub(r"&[a-z]+;", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def words(text):
    return len(text.split())


def in_range(text, lo, hi):
    n = words(text)
    return lo <= n <= hi


def trim_words(text, hi):
    parts = text.split()
    return " ".join(parts[:hi]) if len(parts) > hi else text


def strip_preamble(text):
    prev = None
    while text != prev:
        prev = text
        text = PREAMBLE_RE.sub("", text).strip()
    return text


# ── Human sources ────────────────────────────────────────────────────────────

def fetch_wikipedia(n, lo, hi, delay):
    """Random article intros via the action API (encyclopedic register)."""
    out = []
    base = "https://en.wikipedia.org/w/api.php"
    while len(out) < n:
        params = {
            "format": "json", "action": "query", "generator": "random",
            "grnnamespace": "0", "grnlimit": "10",
            "prop": "extracts", "exintro": "1", "explaintext": "1", "exlimit": "20",
        }
        try:
            data = _get_json(base + "?" + urllib.parse.urlencode(params))
        except Exception as e:  # noqa: BLE001
            print(f"  [wikipedia] request failed: {e}", file=sys.stderr)
            break
        pages = (data.get("query") or {}).get("pages") or {}
        for page in pages.values():
            text = clean(page.get("extract", ""))
            text = trim_words(text, hi)
            if in_range(text, lo, hi):
                out.append(("wikipedia", "academic", page.get("title", ""), text))
        print(f"  [wikipedia] {len(out)}/{n}", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


def fetch_arxiv(n, lo, hi, delay):
    """Recent abstracts across fields (academic/technical register)."""
    cats = ["cs.LG", "cs.CL", "math.PR", "physics.gen-ph", "q-bio.NC",
            "econ.GN", "stat.ME", "astro-ph.GA", "cond-mat.soft"]
    ns = {"a": "http://www.w3.org/2005/Atom"}
    out = []
    per = max(20, (n // len(cats)) + 10)
    for cat in cats:
        if len(out) >= n:
            break
        q = urllib.parse.urlencode({
            "search_query": f"cat:{cat}", "start": "0", "max_results": str(per),
            "sortBy": "submittedDate", "sortOrder": "descending",
        })
        try:
            xml = _request(f"http://export.arxiv.org/api/query?{q}")
            root = ET.fromstring(xml)
        except Exception as e:  # noqa: BLE001
            print(f"  [arxiv:{cat}] failed: {e}", file=sys.stderr)
            continue
        for entry in root.findall("a:entry", ns):
            summ = entry.find("a:summary", ns)
            title = entry.find("a:title", ns)
            text = trim_words(clean(summ.text if summ is not None else ""), hi)
            if in_range(text, lo, hi):
                out.append(("arxiv", "academic",
                            clean(title.text if title is not None else ""), text))
        print(f"  [arxiv] {len(out)}/{n} (through {cat})", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


def fetch_reddit(n, subs, lo, hi, delay):
    """Self-text posts from text-heavy subs (conversation/social register)."""
    out = []
    for sub in subs:
        if len(out) >= n:
            break
        url = f"https://www.reddit.com/r/{sub}/top.json?t=year&limit=100"
        try:
            data = _get_json(url)
        except Exception as e:  # noqa: BLE001
            print(f"  [reddit:{sub}] failed ({e}); Reddit may block datacenter IPs "
                  f"— try --serper with site:reddit.com instead", file=sys.stderr)
            continue
        for child in (data.get("data") or {}).get("children", []):
            d = child.get("data") or {}
            body = d.get("selftext") or ""
            if body in ("", "[removed]", "[deleted]"):
                continue
            text = trim_words(clean(body), hi)
            if in_range(text, lo, hi):
                out.append(("reddit", "conversation", d.get("title", ""), text))
        print(f"  [reddit] {len(out)}/{n} (through r/{sub})", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


def _extract_paragraphs(htmltext):
    try:
        from bs4 import BeautifulSoup  # optional, far cleaner if present
        soup = BeautifulSoup(htmltext, "html.parser")
        for tag in soup(["script", "style", "nav", "header", "footer", "aside"]):
            tag.decompose()
        return " ".join(p.get_text(" ", strip=True) for p in soup.find_all("p"))
    except ImportError:
        paras = re.findall(r"<p[^>]*>(.*?)</p>", htmltext, re.DOTALL | re.IGNORECASE)
        return " ".join(re.sub(r"<[^>]+>", " ", p) for p in paras)


def fetch_serper(n, queries, key, lo, hi, delay, fetch_pages):
    """Discover diverse human web/news text via Google (serper.dev). Uses result
    snippets, and (with --serper-fetch-pages) fetches the linked pages for full
    paragraphs."""
    if not key:
        print("  [serper] no key (SERPER_API_KEY / --serper-key); skipping", file=sys.stderr)
        return []
    out = []
    for q in queries:
        if len(out) >= n:
            break
        try:
            res = _get_json("https://google.serper.dev/search",
                            method="POST", headers={"X-API-KEY": key},
                            data={"q": q, "num": 10})
        except Exception as e:  # noqa: BLE001
            print(f"  [serper] '{q}' failed: {e}", file=sys.stderr)
            continue
        for item in res.get("organic", []):
            register = "news" if "news" in (item.get("link", "")) else "social"
            text = ""
            if fetch_pages and item.get("link"):
                try:
                    page = _request(item["link"], timeout=20, retries=1)
                    text = trim_words(clean(_extract_paragraphs(page)), hi)
                    time.sleep(delay)
                except Exception:  # noqa: BLE001
                    text = ""
            if not in_range(text, lo, hi):
                text = clean(item.get("snippet", ""))   # snippet fallback (short)
            if in_range(text, lo, hi):
                out.append(("serper", register, item.get("title", q), text))
        print(f"  [serper] {len(out)}/{n} (through '{q[:40]}')", file=sys.stderr)
        time.sleep(delay)
    return out[:n]


# ── AI generation ────────────────────────────────────────────────────────────

# Register → instruction that produces text of that register on a given topic.
STYLE_PROMPTS = {
    "academic": "Write a single neutral, encyclopedic paragraph (~{w} words) about: {t}. "
                "Prose only, no title, no lists, no preamble.",
    "abstract": "Write an academic paper abstract (~{w} words) on the topic: {t}. "
                "Just the abstract text, no 'Abstract:' label, no preamble.",
    "conversation": "Write a ~{w}-word Reddit comment replying to a post titled: \"{t}\". "
                    "Casual, first person, opinionated. Comment text only, no preamble.",
    "assistant": "You are a helpful AI assistant. In ~{w} words, helpfully answer or "
                 "explain: {t}. Use your normal assistant style. Answer only, no preamble.",
    "news": "Write a ~{w}-word news-style passage reporting on: {t}. "
            "Body text only, no headline, no byline, no preamble.",
}
# Weight which AI styles to generate. "assistant" is over-weighted on purpose:
# it is the chatty/hedged register the detector currently lets through.
STYLE_WEIGHTS = [("assistant", 0.35), ("academic", 0.2), ("abstract", 0.15),
                 ("conversation", 0.2), ("news", 0.1)]


def _gen_anthropic(prompt, model, key, max_tokens):
    res = _get_json(
        "https://api.anthropic.com/v1/messages", method="POST",
        headers={"x-api-key": key, "anthropic-version": "2023-06-01"},
        data={"model": model, "max_tokens": max_tokens,
              "messages": [{"role": "user", "content": prompt}]})
    return "".join(b.get("text", "") for b in res.get("content", []))


def _gen_openai(prompt, model, key, max_tokens):
    res = _get_json(
        "https://api.openai.com/v1/chat/completions", method="POST",
        headers={"Authorization": f"Bearer {key}"},
        data={"model": model, "max_tokens": max_tokens,
              "messages": [{"role": "user", "content": prompt}]})
    return res["choices"][0]["message"]["content"]


def pick_style():
    r, acc = random.random(), 0.0
    for name, wgt in STYLE_WEIGHTS:
        acc += wgt
        if r <= acc:
            return name
    return STYLE_WEIGHTS[-1][0]


def generate_ai(n, topics, provider, model, key, lo, hi, delay):
    """Generate n AI passages, matching topics/registers/lengths drawn from the
    collected human pool so the AI-vs-human task is provenance, not topic."""
    gen = _gen_anthropic if provider == "anthropic" else _gen_openai
    pool = topics or [("general knowledge", "academic")]
    out, attempts = [], 0
    while len(out) < n and attempts < n * 3:
        attempts += 1
        style = pick_style()
        topic, _ = random.choice(pool)
        target = random.randint(max(lo, 60), min(hi, 260))
        # academic/abstract styles map onto the same instruction family
        key_style = "academic" if style == "academic" else style
        prompt = STYLE_PROMPTS[key_style].format(w=target, t=topic[:200])
        try:
            raw = gen(prompt, model, key, max_tokens=int(target * 2.0) + 64)
        except Exception as e:  # noqa: BLE001
            print(f"  [ai] generation failed: {e}", file=sys.stderr)
            time.sleep(2.0)
            continue
        text = trim_words(strip_preamble(clean(raw)), hi)
        reg = "academic" if style in ("academic", "abstract") else (
            "conversation" if style in ("assistant", "conversation") else style)
        if in_range(text, lo, hi):
            out.append(("ai_" + provider, reg, topic, text))
        if len(out) % 25 == 0 and out:
            print(f"  [ai] {len(out)}/{n}", file=sys.stderr)
        time.sleep(delay)
    print(f"  [ai] {len(out)}/{n} generated", file=sys.stderr)
    return out


# ── Assembly ─────────────────────────────────────────────────────────────────

def dedup(rows):
    seen, out = set(), []
    for r in rows:
        key = hashlib.sha256(r[3].lower().encode("utf-8")).hexdigest()[:16]
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def balance(human, ai):
    k = min(len(human), len(ai))
    if k == 0:
        return human, ai
    random.shuffle(human)
    random.shuffle(ai)
    return human[:k], ai[:k]


def write_csv(path, human, ai):
    os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
    rows = [(src, reg, topic, text, 0) for (src, reg, topic, text) in human] + \
           [(src, reg, topic, text, 1) for (src, reg, topic, text) in ai]
    random.shuffle(rows)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["text", "label", "source", "register", "words"])
        for src, reg, topic, text, label in rows:
            w.writerow([text, label, src, reg, words(text)])
    return len(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--wikipedia", type=int, default=0)
    p.add_argument("--arxiv", type=int, default=0)
    p.add_argument("--reddit", type=int, default=0)
    p.add_argument("--subreddits", default="AskHistorians,explainlikeimfive,changemyview,askscience,personalfinance")
    p.add_argument("--serper", type=int, default=0)
    p.add_argument("--serper-queries", default="")
    p.add_argument("--serper-key", default=os.environ.get("SERPER_API_KEY"))
    p.add_argument("--serper-fetch-pages", action="store_true",
                   help="fetch each result page for full paragraphs (slower; needs bs4 ideally)")
    p.add_argument("--ai", type=int, default=0, help="how many AI passages to generate")
    p.add_argument("--no-ai", action="store_true", help="skip AI generation entirely")
    p.add_argument("--ai-provider", choices=["anthropic", "openai"], default="anthropic")
    p.add_argument("--ai-model", default="claude-haiku-4-5-20251001")
    p.add_argument("--ai-key", default=None,
                   help="defaults to ANTHROPIC_API_KEY or OPENAI_API_KEY by provider")
    p.add_argument("--min-words", type=int, default=50)
    p.add_argument("--max-words", type=int, default=300)
    p.add_argument("--delay", type=float, default=0.7, help="seconds between requests")
    p.add_argument("--balance", action="store_true", help="trim to equal AI/human counts")
    p.add_argument("--seed", type=int, default=0)
    p.add_argument("--out", default="data/corpus/calib.csv")
    args = p.parse_args()

    load_dotenv()
    if args.serper_key is None:
        args.serper_key = os.environ.get("SERPER_API_KEY")
    random.seed(args.seed)
    lo, hi, delay = args.min_words, args.max_words, args.delay

    print("collecting HUMAN text…", file=sys.stderr)
    human = []
    if args.wikipedia:
        human += fetch_wikipedia(args.wikipedia, lo, hi, delay)
    if args.arxiv:
        human += fetch_arxiv(args.arxiv, lo, hi, delay)
    if args.reddit:
        subs = [s.strip() for s in args.subreddits.split(",") if s.strip()]
        human += fetch_reddit(args.reddit, subs, lo, hi, delay)
    if args.serper:
        queries = [q.strip() for q in args.serper_queries.split(";") if q.strip()]
        if not queries:
            print("  [serper] --serper set but no --serper-queries; skipping", file=sys.stderr)
        else:
            human += fetch_serper(args.serper, queries, args.serper_key, lo, hi,
                                  delay, args.serper_fetch_pages)
    human = dedup(human)
    print(f"HUMAN total: {len(human)}", file=sys.stderr)

    ai = []
    want_ai = 0 if args.no_ai else (args.ai or len(human))
    if want_ai and not args.no_ai:
        key = args.ai_key or os.environ.get(
            "ANTHROPIC_API_KEY" if args.ai_provider == "anthropic" else "OPENAI_API_KEY")
        if not key:
            print(f"\nNo API key for --ai-provider {args.ai_provider}; writing HUMAN-only "
                  f"corpus. Set the key (or pass --no-ai) to generate AI rows.", file=sys.stderr)
        else:
            print(f"generating {want_ai} AI passages via {args.ai_provider}/{args.ai_model}…",
                  file=sys.stderr)
            topics = [(topic, reg) for (_s, reg, topic, _t) in human if topic] or None
            ai = dedup(generate_ai(want_ai, topics, args.ai_provider, args.ai_model,
                                   key, lo, hi, delay))

    if args.balance:
        human, ai = balance(human, ai)

    total = write_csv(args.out, human, ai)

    # Report
    by = {}
    for src, reg, _t, _x in human:
        by[("human", src, reg)] = by.get(("human", src, reg), 0) + 1
    for src, reg, _t, _x in ai:
        by[("ai", src, reg)] = by.get(("ai", src, reg), 0) + 1
    print(f"\nwrote {total} rows → {args.out}  (human={len(human)}, ai={len(ai)})")
    for k in sorted(by):
        print(f"  {k[0]:5s} {k[1]:14s} {k[2]:12s} {by[k]:5d}")
    if len(human) and len(ai) >= 25 and total >= 50:
        print("\nnext:")
        print(f"  python3 scripts/calibrate.py   --data {args.out} --target-fpr 0.005")
        print(f"  python3 scripts/measure-gate.py --data {args.out}")
    elif total < 50:
        print("\n⚠ calibrate.py needs ≥50 labeled rows; collect more before fitting.")


if __name__ == "__main__":
    main()
