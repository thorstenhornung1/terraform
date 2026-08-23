#!/usr/bin/env python3
"""
ingest-ihl.py — IHL-Korpus in LightRAG einspeisen.

Liest <id>.txt + <id>.json (von acquire-ihl-corpus.py) und postet jeden Text an
die LightRAG-REST-API (POST /documents/text) mit Quellen-Metadaten, damit
abgerufene Chunks auf Instrument/Artikel rueckfuehrbar bleiben.

Default = DRY-RUN (zeigt nur, was es taete). Mit --apply wird real eingespeist.

Env:
    RAG_URL      (Default https://rag.hornung-bn.de)
    RAG_API_KEY  (Bearer-Token = Docker-Secret lightrag_api_key)

Aufruf:
    RAG_API_KEY=... python3 ingest-ihl.py --corpus /mnt/cephfs/.../inputs --apply
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

RAG_URL = os.environ.get("RAG_URL", "https://rag.hornung-bn.de").rstrip("/")
RAG_API_KEY = os.environ.get("RAG_API_KEY", "")


def post_text(text: str, file_source: str) -> int:
    # LightRAG: POST /documents/text  body {text, file_source}; Bearer-Auth.
    body = json.dumps({"text": text, "file_source": file_source}).encode("utf-8")
    req = urllib.request.Request(
        f"{RAG_URL}/documents/text", data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "X-API-Key": RAG_API_KEY})  # LightRAG REST: APIKeyHeader (NICHT Bearer=JWT)
    with urllib.request.urlopen(req, timeout=120) as r:  # noqa: S310
        return r.status


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, help="Ordner mit <id>.txt + <id>.json")
    ap.add_argument("--apply", action="store_true", help="real einspeisen (sonst dry-run)")
    args = ap.parse_args()

    corpus = Path(args.corpus)
    txts = sorted(corpus.glob("*.txt"))
    if not txts:
        print(f"Keine *.txt in {corpus} — erst acquire-ihl-corpus.py laufen lassen.")
        return 1
    if args.apply and not RAG_API_KEY:
        print("FEHLER: RAG_API_KEY nicht gesetzt (Docker-Secret lightrag_api_key).")
        return 2

    for txt in txts:
        meta_path = txt.with_suffix(".json")
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        instrument = meta.get("instrument", txt.stem)
        citation = meta.get("citation", "")
        text = txt.read_text(encoding="utf-8")
        # Kopf mit Quellenangabe vor den Text — bleibt im Chunk auffindbar.
        header = f"[Quelle: {instrument}{(' — ' + citation) if citation else ''}]\n\n"
        payload = header + text
        file_source = meta.get("id", txt.stem)
        if not args.apply:
            print(f"DRY-RUN  {file_source}: {len(payload)} Zeichen -> POST {RAG_URL}/documents/text")
            continue
        try:
            status = post_text(payload, file_source)
            print(f"OK   {file_source}: HTTP {status}")
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {file_source}: {exc}")
    if not args.apply:
        print("\n(DRY-RUN — mit --apply real einspeisen.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
