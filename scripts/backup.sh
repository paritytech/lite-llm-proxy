#!/usr/bin/env bash
# Nightly pg_dump of the LiteLLM database to local disk, pruned after 14 days.
set -euo pipefail
cd /opt/team-llm
mkdir -p backups
STAMP=$(date +%F)
docker compose exec -T postgres pg_dump -U litellm litellm | gzip > "backups/litellm-${STAMP}.sql.gz"
find backups -name 'litellm-*.sql.gz' -mtime +14 -delete
