#!/usr/bin/env python3
"""
acquire-ihl-corpus.py — IHL Law Core Korpus beschaffen (Verträge + Customary IHL).

Legt je Dokument <id>.txt + <id>.json (Metadaten) ab — kompatibel zu ingest-ihl.py.
Texte werden NICHT ins git committet (Größe / ICRC-Copyright); der Korpus liegt auf
CephFS bzw. einem lokalen Arbeitsordner.

Quellen-Strategie (frühere ICRC-/en/ihl-treaties/-Landing-Pages waren JS-Stubs):
  C1 Verträge  : autoritative public-domain PDFs (ICRC) -> pypdf-Textextraktion.
                 GC I–IV + AP I–III liegen je in EINEM Sammel-PDF.
  C2 Customary : ICRC IHL-DB ist eine JS-SPA; Inhalte aber über Drupal JSON:API
                 erreichbar -> /jsonapi/node/rule (Regel-Statement + Practice-Summary).
  C3 Commentaries: buchlang + verschachteltes Relationship (treaty -> field_treaty_content);
                 separat/skopiert (NICHT in diesem Lauf; siehe acquire_commentaries TODO).

Aufruf:
    python3 acquire-ihl-corpus.py --out /mnt/cephfs/swarm-state/stack-lightrag/inputs/ihl
    python3 acquire-ihl-corpus.py --out ./ihl --smoke           # nur 1 Vertrag + 3 Regeln
    python3 acquire-ihl-corpus.py --out ./ihl --skip-customary  # nur Verträge (2 Mega-Docs)
    python3 acquire-ihl-corpus.py --out ./ihl --per-article --skip-customary  # P1: Verträge PRO ARTIKEL

P1 (--per-article): die 2 Vertrags-Mega-Docs (GC_I_IV / AP_I_III) werden über PyMuPDF (fitz,
saubere Lese-Reihenfolge) in ~576 diskrete Per-Artikel-Docs (`GC_I_ART_015` …) mit Instrument+
Artikel-Metadaten zerlegt → nach `<out>/treaties/`. Fix für die falsch-geratenen Artikel-Zitate.
Detektion: Instrument-Start je gemeinsamem Art-1-Marker + Monoton-Guard (filtert Querverweise) +
harte Per-Instrument-Count-Assertion (64/63/143/159 · 102/28/17).

Deps: requests, beautifulsoup4, pypdf, pymupdf (venv).
"""
from __future__ import annotations

import argparse
import io
import json
import re
import sys
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup
from pypdf import PdfReader
import fitz  # PyMuPDF — saubere Text-Reihenfolge für den Per-Artikel-Split

HDRS = {"User-Agent": "ihl-corpus-acquire/0.2 (private IHL research RAG; thorsten@hornung-bn.de)"}

# -----------------------------------------------------------------------------
# C1 — Verträge (public-domain Volltexte als PDF). Beide URLs 2026-06 verifiziert.
# -----------------------------------------------------------------------------
TREATIES = [
    {"id": "GC_I_IV_1949", "instrument": "Geneva Conventions I–IV (1949)",
     "citation": "75 UNTS 31/85/135/287", "type": "treaty",
     "url": "https://www.icrc.org/sites/default/files/external/doc/en/assets/files/publications/icrc-002-0173.pdf"},
    {"id": "AP_I_III", "instrument": "Additional Protocols I–III (1977/2005)",
     "citation": "1125 UNTS 3/609; 2404 UNTS 261", "type": "treaty",
     "url": "https://www.icrc.org/sites/default/files/external/doc/en/assets/files/other/icrc_002_0321.pdf"},
]

# C2 — Customary IHL via Drupal JSON:API
CIHL_API = "https://ihl-databases.icrc.org/jsonapi/node/rule"
JSONAPI_HDRS = {**HDRS, "Accept": "application/vnd.api+json"}

_TAG_RE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.S | re.I)
_HTML_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\n{3,}")


def html_to_text(html: str) -> str:
    return BeautifulSoup(html, "html.parser").get_text("\n", strip=True)


def fetch(url: str, timeout: int = 60) -> str:
    """HTML- oder PDF-Quelle -> Text (PDF via pypdf)."""
    r = requests.get(url, headers=HDRS, timeout=timeout)
    r.raise_for_status()
    ctype = r.headers.get("Content-Type", "").lower()
    if "pdf" in ctype or url.lower().endswith(".pdf"):
        reader = PdfReader(io.BytesIO(r.content))
        return "\n".join((p.extract_text() or "") for p in reader.pages).strip()
    if "html" in ctype or url.lower().endswith((".htm", ".html")):
        return _WS_RE.sub("\n\n", html_to_text(r.text)).strip()
    return r.text


def write_doc(out: Path, doc_id: str, text: str, meta: dict) -> bool:
    (out / f"{doc_id}.txt").write_text(text, encoding="utf-8")
    (out / f"{doc_id}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    return True


# -----------------------------------------------------------------------------
# P1 — Verträge PRO ARTIKEL (--per-article). Zerlegt die 2 Mega-PDFs über PyMuPDF
# (saubere Lese-Reihenfolge; pypdf verwürfelt TOC/Running-Header) in ~576 diskrete
# Artikel-Docs mit Instrument+Artikel-Metadaten -> jeder Chunk trägt seine Artikel-
# Quell-ID (fixt die geratenen Zitate). Verifiziert gegen die bekannten Counts.
#   - Instrument-Start = gemeinsamer Art-1-Marker (GC: "The High Contracting Parties
#     undertake to respect…"; AP: die 3 Art-1-Marginaltitel); Art-1-Header davor gesucht.
#   - Monoton-Guard: nur Header mit N == expected → filtert Querverweise
#     ("Article 44, the wording of…") + Annex-Resets automatisch raus.
#   - Header-Lookahead (— | : | Newline) trennt echte Header von Inline-Verweisen.
#   - Harte Per-Instrument-Count-Assertion (64/63/143/159 · 102/28/17) → kein Emit bei Mismatch.
# -----------------------------------------------------------------------------
# (instrument_short, Klartext-Name, Artikelzahl, URL-Slug)
GC_INSTRUMENTS = [
    ("GC_I", "Geneva Convention I (1949)", 64, "gci-1949"),
    ("GC_II", "Geneva Convention II (1949)", 63, "gcii-1949"),
    ("GC_III", "Geneva Convention III (1949)", 143, "gciii-1949"),
    ("GC_IV", "Geneva Convention IV (1949)", 159, "gciv-1949"),
]
AP_INSTRUMENTS = [
    ("AP_I", "Additional Protocol I (1977)", 102, "api-1977"),
    ("AP_II", "Additional Protocol II (1977)", 28, "apii-1977"),
    ("AP_III", "Additional Protocol III (2005)", 17, "apiii-2005"),
]
GC_MARKER = r"The High Contracting Parties undertake to respect and to ensure respect"
AP_TITLES = ["General principles and scope of application",
             "Material field of application",
             "Respect for and scope of application of this Protocol"]

_DEHYPH_ALLOW = {"self", "ill", "non", "inter", "sub", "re", "co", "ex", "semi", "anti",
                 "well", "pre", "post", "counter", "long", "short", "war"}
_HYPHEN_RE = re.compile(r"([A-Za-zÄÖÜäöüß]+)-\n([a-zäöüß])")
_ART_RE = re.compile(r"(?m)^[ \t\xa0]*Article\s+(\d+)\s*(bis|ter|quater)?(?=[ \t\xa0]*(?:[—–-]|:|\n|$))")
_ART1_RE = re.compile(r"(?m)^[ \t\xa0]*Article\s+1\b")


def fitz_text(url: str, timeout: int = 90) -> str:
    """PDF -> Text via PyMuPDF (saubere Reihenfolge; pypdf verwürfelt TOC/Header)."""
    pdf = requests.get(url, headers=HDRS, timeout=timeout).content
    return "\n".join(p.get_text("text") for p in fitz.open(stream=pdf, filetype="pdf"))


def dehyphenate(t: str) -> str:
    """PDF-Zeilenumbruch-Trennstriche joinen; echte Bindestrich-Wörter (self-defence) schützen."""
    return _HYPHEN_RE.sub(
        lambda m: (f"{m.group(1)}-\n{m.group(2)}" if m.group(1).lower() in _DEHYPH_ALLOW
                   else f"{m.group(1)}{m.group(2)}"), t)


def _conv_start(text: str, marker_pos: int) -> int:
    """'Article 1'-Header direkt vor einem Art-1-Body-Marker (max. 220 Zeichen davor)."""
    lo = max(0, marker_pos - 220)
    ms = list(_ART1_RE.finditer(text[lo:marker_pos]))
    return lo + ms[-1].start() if ms else marker_pos


def _split_span(text: str, start: int, end: int, count: int):
    """Monoton-Walk der Article-Header in text[start:end] → [(n, body)] bis count."""
    heads = [(int(m.group(1)), m.start(), m.end()) for m in _ART_RE.finditer(text[start:end])]
    out, expected = [], 1
    for i, (n, off, hend) in enumerate(heads):
        if n != expected:
            continue
        nxt = end - start
        for (n2, off2, _e2) in heads[i + 1:]:
            if off2 > off and n2 == expected + 1:
                nxt = off2
                break
        out.append((expected, text[start + hend:start + nxt].strip()))
        expected += 1
        if expected > count:
            break
    return out


def _marginal_title(body: str) -> str:
    """Best-effort Artikel-Titel: die kurze Zeile direkt nach dem Header (— Titel)."""
    for line in body.splitlines():
        s = line.strip().lstrip("—–- \t")
        if not s:
            continue
        return s if (len(s) <= 70 and s[:1].isupper() and not s.endswith((".", ":", ";"))) else ""
    return ""


def _instrument_starts(text: str, blob_id: str):
    if blob_id == "GC_I_IV_1949":
        return [_conv_start(text, m.start()) for m in re.finditer(GC_MARKER, text)]
    starts = []
    for p in AP_TITLES:  # AP-Titel am BODY-Vorkommen (Titel gefolgt von " 1." = Absatz 1)
        m = re.search(re.escape(p) + r"\s*\n?\s*1\.", text)
        if m:
            starts.append(_conv_start(text, m.start()))
    return starts


def acquire_treaties_per_article(out: Path, smoke: bool) -> int:
    """P1: die 2 Vertrags-Mega-PDFs pro Artikel zerlegen -> <out>/treaties/<id>.txt+.json."""
    tdir = out / "treaties"
    tdir.mkdir(parents=True, exist_ok=True)
    blobs = [(TREATIES[0]["url"], "GC_I_IV_1949", GC_INSTRUMENTS)]
    if not smoke:
        blobs.append((TREATIES[1]["url"], "AP_I_III", AP_INSTRUMENTS))
    ok = 0
    for url, blob_id, instruments in blobs:
        try:
            text = dehyphenate(fitz_text(url))
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {blob_id}: PDF/Extraktion — {exc} ({url})")
            continue
        starts = _instrument_starts(text, blob_id)
        if len(starts) != len(instruments):
            print(f"FAIL {blob_id}: {len(starts)} Instrument-Starts != {len(instruments)} — SKIP")
            continue
        starts_ext = starts + [len(text)]
        for i, (short, name, count, slug) in enumerate(instruments):
            arts = _split_span(text, starts[i], starts_ext[i + 1], count)
            if len(arts) != count:
                print(f"FAIL {short}: {len(arts)}/{count} — Count-Assertion verletzt, KEIN Emit")
                continue
            for n, body in arts:
                title = _marginal_title(body)
                did = f"{short}_ART_{n:03d}"
                meta = {
                    "id": did,
                    "instrument": f"{name}, Article {n}" + (f" — {title}" if title else ""),
                    "citation": "ICRC IHL Treaties Database", "type": "treaty_article",
                    "instrument_short": short, "article": str(n), "title": title,
                    "url": f"https://ihl-databases.icrc.org/en/ihl-treaties/{slug}/article-{n}",
                }
                write_doc(tdir, did, body, meta)
                ok += 1
            print(f"OK   {short}: {len(arts)}/{count} Artikel")
        time.sleep(0.5)
    return ok


def acquire_treaties(out: Path, smoke: bool) -> int:
    sources = TREATIES[:1] if smoke else TREATIES
    ok = 0
    for s in sources:
        try:
            text = fetch(s["url"])
            if len(text) < 2000:
                print(f"WARN {s['id']}: nur {len(text)} Zeichen — Quelle prüfen ({s['url']})")
            write_doc(out, s["id"], text, s)
            print(f"OK   treaty {s['id']}: {len(text)} Zeichen")
            ok += 1
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL treaty {s['id']}: {exc} ({s['url']})")
        time.sleep(0.5)
    return ok


def acquire_customary(out: Path, smoke: bool) -> int:
    """ICRC Customary IHL Rules über JSON:API (Regel-Statement + Practice-Summary)."""
    ok = 0
    url = CIHL_API + "?page[limit]=" + ("3" if smoke else "50") + "&sort=field_cihl_order"
    while url:
        try:
            j = requests.get(url, headers=JSONAPI_HDRS, timeout=60).json()
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL customary page: {exc}")
            break
        for node in j.get("data", []):
            a = node.get("attributes", {})
            num = a.get("field_rule_number")
            title = a.get("title", "").strip()
            body = a.get("body")
            html = body if isinstance(body, str) else (body or {}).get("processed", "") if body else ""
            text = _WS_RE.sub("\n\n", html_to_text(html)).strip() if html else ""
            if not text:
                print(f"SKIP CIHL rule {num}: leerer Body")
                continue
            rid = f"CIHL_RULE_{int(num):03d}" if str(num).isdigit() else f"CIHL_{node.get('id','x')[:8]}"
            meta = {
                "id": rid, "instrument": f"ICRC Customary IHL Study — Rule {num}: {title}",
                "citation": "ICRC Customary IHL Database (Vol. I, Rules)", "type": "customary",
                "rule_number": num, "title": title,
                "url": f"https://ihl-databases.icrc.org/en/customary-ihl/v1/rule{num}",
            }
            write_doc(out, rid, text, meta)
            print(f"OK   {rid}: {len(text)} Zeichen — {title[:60]}")
            ok += 1
        url = None if smoke else j.get("links", {}).get("next", {}).get("href")
        time.sleep(0.3)
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="Korpus-Ausgabeordner (z. B. .../inputs/ihl)")
    ap.add_argument("--smoke", action="store_true", help="nur 1 Vertrag + 3 Regeln (Quell-Test)")
    ap.add_argument("--per-article", action="store_true",
                    help="P1: Verträge PRO ARTIKEL zerlegen (PyMuPDF) -> <out>/treaties/")
    ap.add_argument("--skip-treaties", action="store_true")
    ap.add_argument("--skip-customary", action="store_true")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    total = 0
    if not args.skip_treaties:
        if args.per_article:
            print("== C1 Verträge PRO ARTIKEL (PyMuPDF, P1) ==")
            total += acquire_treaties_per_article(out, args.smoke)
        else:
            print("== C1 Verträge (PDF, Mega-Doc) ==")
            total += acquire_treaties(out, args.smoke)
    if not args.skip_customary:
        print("\n== C2 Customary IHL (JSON:API) ==")
        total += acquire_customary(out, args.smoke)

    print(f"\n{total} Dokumente -> {out}")
    print("Hinweis: C3 (ICRC Commentaries) ist buchlang + separat zu skopieren — nicht in diesem Lauf.")
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main())
