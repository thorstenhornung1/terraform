# LightRAG — Korpus- & Tagging-Konventionen (operativ)

Operative Referenz für Ingest/Betrieb. Die **volle Arbeitsanleitung** (Query-Disziplin,
Zitier-Regeln, wo die Unterscheidung wichtig ist) liegt im Artikel-Arbeitsverzeichnis:
`~/Documents/ihl_drones/CORPUS-TAGGING-GUIDE.md`.

## Workspaces (1 LightRAG-Prozess = 1 Workspace)
| Workspace | Service | Endpoint | Inhalt |
|---|---|---|---|
| `ihl_core` | `lightrag` | rag.hornung-bn.de | Verträge (per-Artikel), ICRC-Commentaries (per-Artikel), Customary Rules, WMA — **reiner Rechts-Korpus** |
| `ihl_empirical` | `lightrag-empirical` | rag-empirical.hornung-bn.de | (optional) Paper/Reports/Presse — getaggt |

**Offene Design-Entscheidung:** Empirie separat (`ihl_empirical`) ODER vereint in `ihl_core`
mit Präfix-Tagging. Beide Wege sind gültig; das Tagging hält sie offen (späterer Umzug ohne
Neu-Ingest). Trennung physisch nur an der Grenze Recht↔Empirie; Paper↔Presse via Metadaten.

## Kern-Prinzip
Die Quellen-Unterscheidung lebt im `[Quelle: …]`-Header jedes Docs (steht in jedem Chunk →
das Modell liest ihn, siehe P1). Nicht die Architektur macht die Unterscheidung, sondern das Tagging.

## Doc-ID-Präfixe (harter Filter on-demand)
- Recht: `GC_I_ART_015`, `GC_I_ART_015_COMM` (Commentary), `AP_I_ART_057`, `CIHL_RULE_109`, `WMA_…` — alle zitierfähig
- Empirie: `PAPER_<slug>` / `REPORT_<slug>` (zitierfähig) · `PRESS_<slug>` (NICHT zitierfähig, nur Kontext)

## `[Quelle:]`-Header (setzt `ingest-ihl.py` aus der `.json`-Meta)
```
Recht:      [Quelle: <instrument> — <citation>]                (instrument = "Geneva Convention I (1949), Article 15 — <title>")
Commentary: [Quelle: ICRC Commentary on <instrument> (<year>), Article <n> — <title> — <citation>]
Empirie:    [Quelle: <Titel> — <Peer-reviewed|Report|Presse>, <Quelle Jahr>, <DOI/URL> — <CITABLE|CONTEXT>]
```
Empirie-Meta zusätzlich: `source_type` (paper/report/press), `citable` (true/false), `author`, `year`, `doi_or_url`.

## Ingest-Werkzeuge
- Recht: `acquire-ihl-corpus.py --per-article` (Verträge) · Commentary-Logik (`acquire_comm.py`, zu portieren) · `ingest-ihl.py --apply`
- Bulk: `/documents/texts` (batched, ~30/Request bei großen Docs) — Einzel-`/documents/text` blockiert pro Doc.
- Extraktion: gpt-4.1-mini + `ENTITY_EXTRACTION_USE_JSON=true`; Ingest-Parallelität via `MAX_PARALLEL_INSERT`/`MAX_ASYNC` (Cloud-LLM → hochdrehbar, danach zurück).

## Verifikation
`ihl_drones/tools/fetch_verbatim.py` liefert Quelltext ohne LLM (zitierfähig). Der Mensch verifiziert jede Zitation vor Publikation.
