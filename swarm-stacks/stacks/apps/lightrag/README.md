# LightRAG — Graph-RAG (Korpus: IHL Law Core + WMA Policies)

Selbst gehostetes Graph-RAG (Graph + Vektor) auf **postgres-prod** (Apache AGE + pgvector),
Inferenz/Embeddings vom **Mac Studio via Ollama** (192.168.2.236:11434). Zugriff:
**https://rag.hornung-bn.de** (Web-UI + REST + MCP, API-Key-Auth).

## Status / Architektur

| Schicht | Wo | Status |
|---|---|---|
| KV + Vektor + Graph | postgres-prod, DB `lightrag` (AGE 1.6.0 `ag_catalog` + pgvector 0.8.2) | ✅ live |
| AGE | `shared_preload_libraries='age'` (cluster-global) + ag_catalog-Grants für Rolle `lightrag` | ✅ |
| LLM (Extract/Keywords/Query) | Ollama `:11434/v1` `phi4` | ✅ |
| Embeddings | Ollama `:11434/v1` `bge-m3` (DIM 1024) | ✅ |
| Server-Stack | Swarm `node.labels.app==true`, Port 9621, v1.5.4 | ✅ |

**Warum Ollama statt LM Studio:** LightRAG sendet bei der Query-Keyword-Extraktion hart
`response_format=json_object`; LM Studio lehnt das ab (nur `json_schema`/`text`) → local/hybrid
liefen leer. Ollama akzeptiert `json_object` nativ → **kein Patch am Image** nötig.

## Korpus-Beschaffung

Texte liegen NICHT im git (Größe/ICRC-Copyright) — Korpus-Ordner auf CephFS bzw. lokal.
Skripte brauchen ein venv: `pip install requests beautifulsoup4 pypdf`.

```bash
# IHL Law Core: Verträge (PDF) + Customary IHL (JSON:API)
python3 acquire-ihl-corpus.py --out <korpus>/ihl
#   -> GC_I_IV_1949, AP_I_III (ICRC-PDFs) + CIHL_RULE_001..161 + Intro/Annex   (171 Docs)

# WMA Current Policies (Crawler über alle Paginierungs-Seiten)
python3 acquire-wma-corpus.py --out <korpus>/wma          # ~205 Docs (Declarations/Statements/Resolutions)
```

**Quellen-Hinweise:**
- Verträge: autoritative public-domain PDFs (ICRC `icrc-002-0173.pdf` = GC I–IV;
  `icrc_002_0321.pdf` = AP I–III). PDF→Text via pypdf.
- Customary IHL: ICRC IHL-DB ist eine JS-SPA → Inhalte über Drupal **JSON:API**
  (`/jsonapi/node/rule`), nicht über die Landing-Pages (die sind Stubs).
- C3 ICRC **Commentaries**: buchlang + verschachteltes Relationship — separat/skopiert
  zu beschaffen (noch offen).

## Ingestion

```bash
RAG_API_KEY=<lightrag_api_key> python3 ingest-ihl.py --corpus <korpus>/ihl --apply
RAG_API_KEY=<lightrag_api_key> python3 ingest-ihl.py --corpus <korpus>/wma --apply
```
`ingest-ihl.py` ist korpus-agnostisch (postet `<id>.txt`+`<id>.json` an `POST /documents/text`
mit `[Quelle: …]`-Kopf für Provenienz). Default = DRY-RUN; real mit `--apply`.

⚠️ **Index-Reset** vor frischem Korpus: `DELETE /documents` (löscht alle Docs im Workspace).
⚠️ **Durchsatz:** eine GPU serialisiert Ingest+Query → Bulk-Ingest blockiert parallele Queries
(während des Laufs Query-Timeouts sind erwartbar, kein Bug). Ggf. `OLLAMA_NUM_PARALLEL` erhöhen.
Fortschritt: `GET /documents/pipeline_status`.

## Abfrage / Verifikation (Disclaimer-Glättung)

```bash
RAG_API_KEY=<key> python3 query-rag.py "Schutz von Sanitätseinheiten, GC I Art. 19" --mode local
```
`query-rag.py` nutzt den v1.5.4-nativen `user_prompt` (QueryParam), um den phi4-Disclaimer
abzustellen und Quellen-/Artikel-Referenzen zu erzwingen — **kein Image-Patch**. Dieselbe
Instruktion lässt sich in der Web-UI ins Feld „User Prompt" der Query-Settings eintragen.

## Secrets

`bash create-secrets.sh` (auf einem Manager) legt `lightrag_api_key` an; `lightrag_db_password`
existiert bereits (passend zum postgres-User `lightrag`). Der API-Key-Wert steckt im laufenden
Container unter `/run/secrets/lightrag_api_key`.

## MCP (Claude Code) — später
```json
{ "mcpServers": { "rag": { "url": "https://rag.hornung-bn.de/mcp",
    "headers": { "Authorization": "Bearer <lightrag_api_key>" } } } }
```

## Bewusst vertagt
ICRC Commentaries (C3) · Zotero + Vancouver-Zitierung (Mensch-Verifikation Pflicht — RAG =
Auffinde-/Entwurfs-Aid, kein Zitier-Orakel) · Presse-Instanz · Docling-Ingestion-Image ·
IHL-Recherche-Agent (Primärtext-RAG + Web-Agent live).
