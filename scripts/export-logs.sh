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
# Same safety pattern as backup.sh: dump to a temp file, verify gzip integrity,
# then atomically move into place — a failed/partial export never lands as a
# corpus file, and the optional prune only runs after a verified-good export.
#
# Usage: export-logs.sh [YYYY-MM-DD]   (defaults to yesterday, UTC)
# Idempotent: re-running for the same day atomically replaces that day's file,
# so backfilling or re-exporting after a partial day is safe.
set -euo pipefail
cd /opt/team-llm

# Config from .env (kept out of git). LOG_EXPORT_DIR is a plain host directory —
# outside Docker volumes, so it survives restarts/redeploys; swap it for a mounted
# datastore later by changing one line in .env.
EXPORT_DIR=$(grep '^LOG_EXPORT_DIR=' .env | cut -d= -f2- || true)
EXPORT_DIR=${EXPORT_DIR:-/opt/team-llm/logs}
RETENTION_DAYS=$(grep '^LOG_EXPORT_RETENTION_DAYS=' .env | cut -d= -f2- || true)

# Day to export: yesterday UTC by default (GNU date — the box is Ubuntu).
DAY=${1:-$(date -u -d yesterday +%F)}
[[ "$DAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "bad date: $DAY" >&2; exit 1; }

mkdir -p "$EXPORT_DIR"
TMP="${EXPORT_DIR}/.spendlogs-${DAY}.jsonl.gz.tmp"
OUT="${EXPORT_DIR}/spendlogs-${DAY}.jsonl.gz"

# One JSON object per line, whole row (schema-agnostic: survives LiteLLM adding
# columns). UTC day window on startTime.
SQL="COPY (SELECT row_to_json(t) FROM (SELECT * FROM \"LiteLLM_SpendLogs\" WHERE \"startTime\" >= '${DAY} 00:00:00+00'::timestamptz AND \"startTime\" < '${DAY} 00:00:00+00'::timestamptz + interval '1 day' ORDER BY \"startTime\") t) TO STDOUT"

docker compose exec -T postgres psql -U litellm -d litellm -v ON_ERROR_STOP=1 -q -c "$SQL" | gzip > "$TMP"
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
