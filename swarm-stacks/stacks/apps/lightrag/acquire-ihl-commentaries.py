#!/usr/bin/env python3
"""
acquire-ihl-commentaries.py — ICRC Commentaries (C3) via Drupal JSON:API.

Buchlanger Korpus -> SEPARATER, langer Job (nicht im Haupt-Ingest). Beschafft die
Kommentare zu den 1949er Genfer Konventionen + Zusatzprotokollen:

  Treaty (per field_path.alias) -> field_treaty_content (Artikel, paragraph--treaty_content)
    -> field_treaty_commentary (Kommentar-Absätze)

Je Artikel ein Dokument COMMENTARY_<slug>_<artikel>.txt (+ .json), Artikeltext + Kommentar,
kompatibel zu ingest-ihl.py.

Aufruf:
    python3 acquire-ihl-commentaries.py --out <korpus>/commentaries
    python3 acquire-ihl-commentaries.py --out ./c3 --only gci-1949 --limit 3   # Smoke

Deps: requests, beautifulsoup4 (venv).  ⚠️ Ingest erst NACH dem Haupt-Ingest (eine GPU).
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

BASE = "https://ihl-databases.icrc.org"
H = {"User-Agent": "ihl-corpus-acquire/0.2 (private IHL research RAG; thorsten@hornung-bn.de)",
     "Accept": "application/vnd.api+json"}

TREATY_SLUGS = ["gci-1949", "gcii-1949", "gciii-1949", "gciv-1949", "api-1977", "apii-1977", "apiii-2005"]
_WS_RE = re.compile(r"\n{3,}")


def api(url: str) -> dict:
    last = None
    for attempt in range(4):  # langer Lauf -> transiente Netzfehler abfangen
        try:
            r = requests.get(url, headers=H, timeout=90)
            r.raise_for_status()
            return r.json()
        except Exception as exc:  # noqa: BLE001
            last = exc
            time.sleep(1.5 * (attempt + 1))
    raise last  # nach 4 Versuchen aufgeben (Aufrufer fängt pro Artikel/Vertrag)


def html_text(html) -> str:
    if not isinstance(html, str) or not html:
        return ""
    return _WS_RE.sub("\n\n", BeautifulSoup(html, "html.parser").get_text("\n", strip=True)).strip()


def longest_html_field(attrs: dict) -> str:
    """Robust: das längste HTML-/Text-Feld eines Nodes als Kommentartext nehmen."""
    best = ""
    for v in attrs.values():
        if isinstance(v, str) and len(v) > len(best):
            best = v
        elif isinstance(v, dict) and isinstance(v.get("processed"), str) and len(v["processed"]) > len(best):
            best = v["processed"]
    return best


_TREATY_INDEX: dict[str, dict] = {}


def _alias_slug(node: dict) -> str:
    fp = node.get("attributes", {}).get("field_path") or {}
    alias = fp.get("alias", "") if isinstance(fp, dict) else (fp or "")
    return alias.rstrip("/").rsplit("/", 1)[-1] if alias else ""


def resolve_treaty(slug: str) -> dict | None:
    """field_path.alias ist nicht filterbar -> einmalig alle Treaties indexieren, dann per Slug nachschlagen."""
    if not _TREATY_INDEX:
        url = f"{BASE}/jsonapi/node/treaty?page[limit]=50"
        while url:
            j = api(url)
            for n in j.get("data", []):
                s = _alias_slug(n)
                if s:
                    _TREATY_INDEX[s] = n
            url = j.get("links", {}).get("next", {}).get("href")
        print(f"(treaty-index: {len(_TREATY_INDEX)} Verträge)")
    return _TREATY_INDEX.get(slug)


def fetch_related(node: dict, rel: str) -> list:
    href = node.get("relationships", {}).get(rel, {}).get("links", {}).get("related", {}).get("href")
    if not href:
        return []
    out, url = [], href
    while url:
        j = api(url)
        d = j.get("data")
        out.extend(d if isinstance(d, list) else ([d] if d else []))
        url = j.get("links", {}).get("next", {}).get("href")
    return out


def acquire_treaty(slug: str, out: Path, limit: int) -> int:
    node = resolve_treaty(slug)
    if not node:
        print(f"FAIL treaty {slug}: nicht gefunden")
        return 0
    title = node["attributes"].get("field_short_title", slug)
    arts = fetch_related(node, "field_treaty_content")
    print(f"== {slug} ({title}) — {len(arts)} content items ==")
    ok = 0
    for i, art in enumerate(arts):
        if limit and ok >= limit:
            break
        try:
            a = art["attributes"]
            art_title = (a.get("field_treaty_content_title") or a.get("field_treaty_content_list_title")
                         or f"item{i}")
            art_body = html_text(a.get("field_treaty_content_content"))
            comm = fetch_related(art, "field_treaty_commentary")
            if not comm:
                continue
            ctext = "\n\n".join(html_text(longest_html_field(c.get("attributes", {}))) for c in comm).strip()
            if not ctext:
                continue
            ref = re.sub(r"[^A-Za-z0-9]+", "_", str(art_title))[:50].strip("_")
            cid = f"COMMENTARY_{slug.replace('-', '_')}_{i:03d}_{ref}"  # Index gegen ID-Kollisionen
            text = f"{art_title}\n\n{art_body}\n\n--- Commentary ---\n\n{ctext}" if art_body else \
                   f"{art_title}\n\n--- Commentary ---\n\n{ctext}"
            meta = {
                "id": cid, "instrument": f"ICRC Commentary — {title}, {art_title}",
                "citation": f"ICRC Commentary ({slug})", "type": "commentary",
                "treaty": slug, "article": str(art_title),
                "url": f"{BASE}/en/ihl-treaties/{slug}",
            }
            (out / f"{cid}.txt").write_text(text, encoding="utf-8")
            (out / f"{cid}.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"  OK {cid}: art={len(art_body)} comm={len(ctext)}")
            ok += 1
        except Exception as exc:  # noqa: BLE001 — ein Artikel darf den Lauf nicht abbrechen
            print(f"  FAIL {slug} item{i}: {exc}")
        time.sleep(0.2)
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", help="nur ein Treaty-Slug (z. B. gci-1949)")
    ap.add_argument("--limit", type=int, default=0, help="max. Artikel je Treaty (Smoke)")
    args = ap.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    slugs = [args.only] if args.only else TREATY_SLUGS
    total = 0
    for s in slugs:
        try:
            total += acquire_treaty(s, out, args.limit)
        except Exception as exc:  # noqa: BLE001 — ein Vertrag darf den Lauf nicht abbrechen
            print(f"FAIL treaty {s}: {exc}")
    print(f"\n{total} Commentary-Dokumente -> {out}")
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main())
