-- ============================================================
-- Brizza Postgres — schema bootstrap
--
-- Runs ONCE, on first container init (when the data dir is
-- empty), via /docker-entrypoint-initdb.d. Executed as the
-- POSTGRES_USER (brizza) against the POSTGRES_DB (brizza).
--
-- Two schemas keep LangGraph's checkpointer tables and
-- APScheduler's job-store table tidily separated within the
-- single 'brizza' database (Brizza ADR 0001).
--
-- IF NOT EXISTS keeps this safe to re-run by hand later if the
-- data dir is ever rebuilt.
-- ============================================================
CREATE SCHEMA IF NOT EXISTS checkpoints AUTHORIZATION brizza;
CREATE SCHEMA IF NOT EXISTS scheduler  AUTHORIZATION brizza;
