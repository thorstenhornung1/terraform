-- =============================================================================
-- LightRAG DB-Setup auf postgres-prod (idempotent, als superuser ausführen)
-- =============================================================================
-- Reproduziert das live durchgeführte Setup (2026-06-26). Voraussetzung auf der
-- VM: pgvector (PGDG) + Apache AGE (from-source, PG16) installiert UND
-- `shared_preload_libraries = 'age'` gesetzt + Postgres-Restart — sonst scheitert
-- create_graph mit "function create_graph(unknown) does not exist".
--
-- Ausführen:  sudo -u postgres psql -f setup-db.sql
--             (Passwort separat via ALTER ROLE setzen; Wert muss zum
--              Docker-Secret lightrag_db_password_vN passen.)
-- =============================================================================

-- Rolle + DB (Passwort nachträglich via ALTER ROLE ... PASSWORD '<pw>')
SELECT 'CREATE ROLE lightrag LOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='lightrag')\gexec
SELECT 'CREATE DATABASE lightrag OWNER lightrag'
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='lightrag')\gexec

\connect lightrag

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS age;

-- KRITISCH: LightRAG nutzt eine NICHT-Superuser-Rolle. Ohne USAGE auf
-- ag_catalog sind die AGE-Funktionen für die Rolle unsichtbar
-- ("function create_graph does not exist"). Daher explizite Grants:
GRANT USAGE ON SCHEMA ag_catalog TO lightrag;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ag_catalog TO lightrag;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO lightrag;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ag_catalog TO lightrag;
ALTER DEFAULT PRIVILEGES IN SCHEMA ag_catalog
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lightrag;
