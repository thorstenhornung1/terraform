#!/usr/bin/env python3
"""
acquire-wma-corpus.py — WMA „Current Policies" als Korpus beschaffen.

Crawlt https://www.wma.net/policy/current-policies/ (alle Paginierungs-Seiten),
holt jede Policy-Seite (/policies-post/<slug>/) und extrahiert den reinen
Policy-Text. Legt je Dokument <id>.txt + <id>.json (Metadaten) ab — kompatibel
zu ingest-ihl.py.

Warum BeautifulSoup statt simplem HTML->Regex (wie acquire-ihl-corpus.py):
Die WMA-Seiten sind WordPress mit viel Chrome (Menü, Sidebar „Related WMA
Policies", Tags, Footer). Über ~210 Seiten würde dieser Chrome Embeddings und
Graph vergiften. Der Policy-Text steht in `div.main-content-area > div.col-md-8`
(Hauptspalte; beginnt mit der Adoptions-/Aenderungshistorie). Die Sidebar
`div.col-md-4` und Trailing-Bloecke (Archived versions / Related / Tags) werden
verworfen.

Es gibt KEINE saubere WP-REST-API fuer den Custom-Post-Type -> daher Scrape.

Aufruf:
    python3 acquire-wma-corpus.py --out /mnt/cephfs/swarm-state/stack-lightrag/inputs/wma
    python3 acquire-wma-corpus.py --out ./wma --limit 3   # Smoke-Test

Deps: requests, beautifulsoup4 (venv).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup

BASE = "https://www.wma.net"
INDEX = BASE + "/policy/current-policies/"
HDRS = {"User-Agent": "wma-corpus-acquire/0.1 (private IHL research RAG; thorsten@hornung-bn.de)"}

_LINK_RE = re.compile(r'href="(https://www\.wma\.net/policies-post/[^"#?]+/)"')
_PAGE_RE = re.compile(r"/policy/current-policies/page/(\d+)/")
# Trailing-Bloecke, ab denen abgeschnitten wird (kommen NIE im Policy-Body vor).
_CUT_RE = re.compile(r"\n\s*(Archived versions|Older versions|Related WMA Policies|Download this policy)\b", re.I)
_WS_RE = re.compile(r"\n{3,}")
_YEAR_RE = re.compile(r"\b(?:19|20)\d{2}\b")
_ADOPT_RE = re.compile(r"\b(Adopted|amended|revised|reaffirmed|Assembly|Council Session)\b", re.I)


def get(url: str, timeout: int = 30) -> str:
    r = requests.get(url, headers=HDRS, timeout=timeout)
    r.raise_for_status()
    return r.text


def discover_policy_urls() -> tuple[list[str], int]:
    """Alle Policy-URLs ueber alle Paginierungs-Seiten einsammeln."""
    html = get(INDEX)
    pages = {int(n) for n in _PAGE_RE.findall(html)}
    last = max(pages) if pages else 1
    urls = set(_LINK_RE.findall(html))
    for p in range(2, last + 1):
        try:
            urls.update(_LINK_RE.findall(get(f"{INDEX}page/{p}/")))
        except Exception as exc:  # noqa: BLE001
            print(f"WARN index page {p}: {exc}")
        time.sleep(0.4)
    return sorted(urls), last


def classify(title: str) -> str:
    t = title.lower()
    # Reihenfolge: spezifischer vor generisch (Council Resolution vor Resolution).
    for label in ("Declaration", "Regulations", "Statement", "Council Resolution", "Resolution"):
        if label.lower() in t:
            return label
    return "Policy"


def slug_from_url(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1]


def extract(url: str) -> tuple[str, dict]:
    soup = BeautifulSoup(get(url), "html.parser")
    h1 = soup.find("h1")
    title = (h1.get_text(strip=True) if h1 else
             (soup.title.string.split("–")[0].strip() if soup.title and soup.title.string else slug_from_url(url)))

    mca = soup.select_one("div.main-content-area")
    node = (mca.select_one("div.col-md-8") if mca else None) or mca or soup
    for bad in node.select("script, style, nav, .share, .social, .other-post-excerpt, form"):
        bad.decompose()

    text = node.get_text("\n", strip=True)
    cut = _CUT_RE.search(text)
    if cut:
        text = text[: cut.start()]
    # Hochgestellte Ordinalzahlen kleben wieder zusammen: "2\nnd" -> "2nd".
    text = re.sub(r"(\d)\n(st|nd|rd|th)\b", r"\1\2", text)
    text = _WS_RE.sub("\n\n", text).strip()

    ptype = classify(title)
    # Jahre NUR aus den Adoptions-/Revisions-Zeilen (sonst faengt man Body-Jahre wie "by 2050").
    hist_years = [m.group(0) for ln in text.splitlines()
                  if _ADOPT_RE.search(ln) for m in _YEAR_RE.finditer(ln)]
    adopted = min(hist_years) if hist_years else None
    latest = max(hist_years) if hist_years else None
    meta = {
        "id": "WMA_" + slug_from_url(url).replace("-", "_"),
        "instrument": title,
        "citation": f"WMA {ptype}" + (f", {latest}" if latest else "") + f" — {url}",
        "type": ptype,
        "source": "WMA",
        "adopted_year": adopted,
        "latest_year": latest,
        "url": url,
    }
    return text, meta


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="Ausgabeordner (z. B. .../inputs/wma)")
    ap.add_argument("--limit", type=int, default=0, help="nur die ersten N Policies (Smoke-Test)")
    ap.add_argument("--sleep", type=float, default=0.4, help="Pause zwischen Policy-Requests (s)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print("Discovering policy URLs ...")
    urls, last = discover_policy_urls()
    if args.limit:
        urls = urls[: args.limit]
    print(f"{len(urls)} Policies (Paginierung 1..{last}). Schreibe nach {out}")

    ok = short = fail = 0
    for i, url in enumerate(urls, 1):
        try:
            text, meta = extract(url)
            if len(text) < 300:
                short += 1
                print(f"WARN {meta['id']}: nur {len(text)} Zeichen — pruefen ({url})")
            (out / f"{meta['id']}.txt").write_text(text, encoding="utf-8")
            (out / f"{meta['id']}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"OK   [{i}/{len(urls)}] {meta['id']}: {len(text)} Zeichen ({meta['type']})")
            ok += 1
        except Exception as exc:  # noqa: BLE001
            fail += 1
            print(f"FAIL [{i}/{len(urls)}] {url}: {exc}")
        time.sleep(args.sleep)

    print(f"\n{ok} ok, {short} kurz/verdaechtig, {fail} fehlgeschlagen -> {out}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
