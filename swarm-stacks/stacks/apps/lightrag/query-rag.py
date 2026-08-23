#!/usr/bin/env python3
"""
query-rag.py — LightRAG abfragen mit IHL-System-Instruktion (Disclaimer-Glättung).

Statt das LightRAG-Image zu patchen (User-Prinzip: Standard-Software nicht patchen)
nutzt dieses Skript den v1.5.4-nativen QueryParam `user_prompt`: zusätzliche
Instruktionen, die ins Prompt-Template injiziert werden. Damit wird der phi4-
„As a large language model…"-Disclaimer abgestellt und auf Zitat-Disziplin gedrängt.
Dasselbe `user_prompt` lässt sich in der Web-UI (rag.hornung-bn.de) ins Feld
„User Prompt" der Query-Settings eintragen (persistiert pro Browser).

Dient zugleich als End-to-End-Verifikation (Teil E).

Env:
    RAG_URL      (Default https://rag.hornung-bn.de)
    RAG_API_KEY  (Bearer-Token = Docker-Secret lightrag_api_key)

Aufruf:
    RAG_API_KEY=... python3 query-rag.py "Schutz von Sanitätseinheiten, GC I Art. 19" --mode local
    RAG_API_KEY=... python3 query-rag.py "WMA position on physicians and torture" --mode hybrid --raw
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request

RAG_URL = os.environ.get("RAG_URL", "https://rag.hornung-bn.de").rstrip("/")
RAG_API_KEY = os.environ.get("RAG_API_KEY", "")

# Die IHL-Instruktion (hier versioniert — NICHT im Image). Glättet den Disclaimer
# und erzwingt Quellen-/Artikel-Referenzen.
IHL_USER_PROMPT = (
    "You are an IHL and medical-ethics research assistant. Answer ONLY from the provided context. "
    "For every claim, cite the instrument and the article/rule/section it comes from "
    "(e.g. 'GC I, Art. 19'; 'AP I, Art. 12'; 'ICRC Customary IHL, Rule 25'; 'WMA Declaration of Tokyo'). "
    "Do NOT add liability disclaimers, hedging boilerplate, or 'as a large language model' caveats. "
    "If the context is insufficient, say so plainly and name what is missing. "
    "Answer in the language of the question."
)


def query(q: str, mode: str, user_prompt: str, references: bool) -> dict:
    body = json.dumps({
        "query": q, "mode": mode, "user_prompt": user_prompt,
        "include_references": references, "response_type": "Multiple Paragraphs",
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{RAG_URL}/query", data=body, method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": RAG_API_KEY})  # LightRAG REST: APIKeyHeader
    with urllib.request.urlopen(req, timeout=300) as r:  # noqa: S310
        return json.loads(r.read())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("query", help="Frage")
    ap.add_argument("--mode", default="mix",
                    choices=["local", "global", "hybrid", "naive", "mix", "bypass"])
    ap.add_argument("--no-references", action="store_true", help="ohne Referenzen-Liste")
    ap.add_argument("--user-prompt", default=IHL_USER_PROMPT, help="System-/User-Instruktion überschreiben")
    ap.add_argument("--raw", action="store_true", help="rohe JSON-Antwort ausgeben")
    args = ap.parse_args()

    if not RAG_API_KEY:
        print("FEHLER: RAG_API_KEY nicht gesetzt (Docker-Secret lightrag_api_key).", file=sys.stderr)
        return 2
    try:
        res = query(args.query, args.mode, args.user_prompt, not args.no_references)
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if args.raw:
        print(json.dumps(res, ensure_ascii=False, indent=2))
        return 0

    print(f"=== [{args.mode}] {args.query} ===\n")
    print(res.get("response", "(keine Antwort)"))
    refs = res.get("references") or []
    if refs:
        print("\n--- References ---")
        for r in refs:
            if isinstance(r, dict):
                print("  •", r.get("file_source") or r.get("reference_id") or r)
            else:
                print("  •", r)
    return 0


if __name__ == "__main__":
    sys.exit(main())
