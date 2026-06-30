#!/usr/bin/env bash
# Nightly pg_dump of the LiteLLM database to local disk, pruned after 14 days.
# Dumps to a temp file and verifies gzip integrity before atomically moving it into
# place, so a failed/partial dump never lands as a "backup" — and the prune only runs
# after a verified-good new dump exists (it can't delete the last good backup on a failure).
set -euo pipefail
cd /opt/team-llm
mkdir -p backups
STAMP=$(date +%F)
TMP="backups/.litellm-${STAMP}.sql.gz.tmp"
docker compose exec -T postgres pg_dump -U litellm litellm | gzip > "$TMP"
gzip -t "$TMP"
mv -f "$TMP" "backups/litellm-${STAMP}.sql.gz"
find backups -name 'litellm-*.sql.gz' -mtime +14 -delete
