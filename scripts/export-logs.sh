#!/usr/bin/env bash
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# Nightly export of LiteLLM request logs (incl. prompts/responses once
# store_prompts_in_spend_logs is on) from Postgres to gzipped JSONL on the host —
# the durable training-data corpus. Postgres itself only keeps ~90d of rows
# (maximum_spend_logs_retention_period in config.yaml); this export is what makes
# the data permanent, so it must run well inside that window (it runs nightly).
#
# Privacy model (the corpus is kept indefinitely, so it is de-identified here,
# at the last point before it becomes permanent; raw attributed rows exist only
# in the 90d Postgres hot store):
#   1. De-attribution — the SELECT below is an explicit column WHITELIST. The
#      identity columns (user email, key hash/alias, team, IP, session, request
#      headers) never leave Postgres. A whitelist fails safe: a new LiteLLM
#      column is *excluded* until someone consciously adds it here.
#   2. Content scrub — scrub-logs.py replaces PII/credentials in prompt and
#      response text with <ENTITY_TYPE> placeholders via the local Presidio
#      containers (compose `scrub` profile, started/stopped around the export).
#      Fail-closed: if the scrub errors, pipefail aborts and no file lands.
# Result is pseudonymized, NOT anonymous — free text can still identify its
# author to a colleague. README § "Logging & privacy" says so to the team.
#
# Same safety pattern as backup.sh: dump to a temp file, verify gzip integrity,
# then atomically move into place — a failed/partial export never lands as a
# corpus file, and the optional prune only runs after a verified-good export.
#
# Usage: export-logs.sh [YYYY-MM-DD]   (defaults to yesterday, UTC)
# Idempotent: re-running for the same day atomically replaces that day's file,
# so backfilling or re-exporting after a partial day is safe.
# Requires: python3 (stdlib only) on the host, for scrub-logs.py.
set -euo pipefail
cd /opt/team-llm

# Config from .env (kept out of git). LOG_EXPORT_DIR is a plain host directory —
# outside Docker volumes, so it survives restarts/redeploys; swap it for a mounted
# datastore later by changing one line in .env.
EXPORT_DIR=$(grep '^LOG_EXPORT_DIR=' .env | cut -d= -f2- || true)
EXPORT_DIR=${EXPORT_DIR:-/opt/team-llm/logs}
RETENTION_DAYS=$(grep '^LOG_EXPORT_RETENTION_DAYS=' .env | cut -d= -f2- || true)

# Secret salt for the session pseudonym (see SQL below). Required: without it
# we'd either export raw session ids (identity risk — clients choose them) or
# unsalted hashes (dictionary-reversible). Generate once, never rotate — a
# rotation unlinks sessions that span the rotation date.
SESSION_SALT=$(grep '^LOG_EXPORT_SESSION_SALT=' .env | cut -d= -f2- || true)
[[ "$SESSION_SALT" =~ ^[A-Za-z0-9]{32,}$ ]] || {
  echo "LOG_EXPORT_SESSION_SALT missing/weak in .env (need >=32 alnum chars; openssl rand -hex 32)" >&2
  exit 1
}

# Day to export: yesterday UTC by default (GNU date — the box is Ubuntu).
DAY=${1:-$(date -u -d yesterday +%F)}
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $DAY" >&2; exit 1; }

mkdir -p "$EXPORT_DIR"
TMP="${EXPORT_DIR}/.spendlogs-${DAY}.jsonl.gz.tmp"
OUT="${EXPORT_DIR}/spendlogs-${DAY}.jsonl.gz"

# Bring up the Presidio pair just for this run (the analyzer's NLP model holds
# ~1.5 GB RAM — not worth keeping resident for a once-nightly job), and stop it
# again on ANY exit path so a failed export doesn't leave it running.
# Trap installed BEFORE `up` so a partially-started pair still gets stopped.
# Cleanup must never mask the export's own exit code (|| true), and a failed
# run must not leave a stale .tmp behind (harmless content — post-scrub only —
# but it would accumulate).
trap 'docker compose --profile scrub stop presidio-analyzer presidio-anonymizer >/dev/null 2>&1 || true; rm -f "$TMP"' EXIT
docker compose --profile scrub up -d presidio-analyzer presidio-anonymizer
for i in $(seq 1 60); do
  curl -fsS http://127.0.0.1:5002/health >/dev/null 2>&1 \
    && curl -fsS http://127.0.0.1:5001/health >/dev/null 2>&1 && break
  [[ $i -eq 60 ]] && { echo "presidio not healthy after 120s" >&2; exit 1; }
  sleep 2
done

# One JSON object per line. Explicit column whitelist (see privacy model above):
# kept columns are the corpus payload (messages/response, scrubbed downstream)
# plus non-identifying context (model, token/spend accounting, status).
# Deliberately dropped: api_key (key hash), "user" (teammate email), metadata
# (key alias + user ids), team_id, organization_id, end_user,
# requester_ip_address, session_id, request_tags, proxy_server_request (raw
# headers), cache_key, api_base, agent_id, and the fine-grained timestamps
# (endTime/completionStartTime) — startTime is coarsened to the UTC day.
# Session structure IS exported (needed for training on whole conversations),
# but pseudonymously: "session" = md5(secret salt || session_id) — raw ids are
# client-chosen strings that can embed identity and appear in other systems'
# logs, so they never leave Postgres; the salted hash links turns of ONE
# conversation without linking a person's different conversations. "turn" is
# the request's rank within its session for this day (sessions rarely span
# midnight; chat requests re-send full history anyway, so a split session
# still reconstructs). Rows are ordered by (session, turn): deterministic for
# idempotent re-exports, groups conversations for training, and — being hash
# ordering across sessions — still uncorrelated with wall-clock sequence.
# Note: clients that don't pass litellm_session_id get a random session_id per
# request (LiteLLM default), i.e. singleton sessions with turn=1. NULL and
# empty-string session_id fall back to request_id (also singletons) — without
# that, md5(salt||NULL)=NULL / the constant md5(salt||'') would lump those rows
# into one fake time-ordered mega-session, resurrecting the day timeline we
# scrambled. (Both unreachable on the pinned image — LiteLLM always stamps a
# non-empty id — this guards upstream drift.)
# LiteLLM stores startTime naive-UTC, so the day window and the "day" cast use
# naive timestamps directly — no dependence on the Postgres session TimeZone.
SQL="COPY (SELECT row_to_json(t) FROM (
  SELECT \"request_id\", \"call_type\", \"model\", \"model_group\",
         \"custom_llm_provider\", \"spend\", \"prompt_tokens\",
         \"completion_tokens\", \"total_tokens\", \"request_duration_ms\",
         \"cache_hit\", \"status\", \"mcp_namespaced_tool_name\",
         \"startTime\"::date AS \"day\",
         md5('${SESSION_SALT}' || COALESCE(NULLIF(\"session_id\", ''), \"request_id\")) AS \"session\",
         row_number() OVER (PARTITION BY COALESCE(NULLIF(\"session_id\", ''), \"request_id\")
                            ORDER BY \"startTime\", \"request_id\") AS \"turn\",
         \"messages\", \"response\"
  FROM \"LiteLLM_SpendLogs\"
  WHERE \"startTime\" >= '${DAY}'::timestamp
    AND \"startTime\" < '${DAY}'::timestamp + interval '1 day'
  ORDER BY \"session\", \"turn\") t) TO STDOUT"

# SQL goes in via stdin (-f -), NOT argv: the query embeds the session salt,
# and argv is world-readable in `ps`/proc for the duration of the dump.
printf '%s\n' "$SQL" \
  | docker compose exec -T postgres psql -U litellm -d litellm -v ON_ERROR_STOP=1 -q -f - \
  | python3 /opt/team-llm/scripts/scrub-logs.py \
  | gzip > "$TMP"
gzip -t "$TMP"
ROWS=$(zcat "$TMP" | wc -l | tr -d ' ')
mv -f "$TMP" "$OUT"
echo "$(date -u +%FT%TZ) exported ${ROWS} rows for ${DAY} -> ${OUT}"

# Optional prune — only when LOG_EXPORT_RETENTION_DAYS is set to a number.
# Default (empty) keeps everything: the corpus is the point.
if [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
  find "$EXPORT_DIR" -name 'spendlogs-*.jsonl.gz' -mtime +"${RETENTION_DAYS}" -delete
fi

# Growth visibility in the cron log (RUNBOOK has the sizing math).
df -h "$EXPORT_DIR" | tail -1
