#!/usr/bin/env bash
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# Change-aware deploy step, run ON THE BOX by CI (deploy.yml → gatekeeper → here) right
# after the repo has been rsync'd to /opt/team-llm. Restarts only what the change touched —
# a docs-only merge must not drop in-flight LLM requests:
#
#   docker-compose.yml changed → docker compose up -d          (recreates changed services)
#   config.yaml changed        → up -d --force-recreate litellm (bind-mounted file; compose
#                                can't see it change, so recreate explicitly)
#   Caddyfile changed          → graceful caddy reload, zero downtime (also bind-mounted)
#   none of the above          → no restarts at all
#
# "Changed" = sha256 differs from .deploy-state, written only after the LAST SUCCESSFUL
# deploy — so a failed deploy leaves stale state behind and the next run retries the
# restart instead of silently skipping it. No state file (first run) = everything changed.
#
# Never uses `docker compose down` (RUNBOOK: `down -v` would destroy keys/budgets/logs),
# never starts the scrub-profile Presidio pair, never writes inside logs/ or backups/
# (the training corpus and DB dumps — CI's rsync excludes them too).
set -euo pipefail
cd /opt/team-llm

STATE_FILE=.deploy-state
TRACKED=(docker-compose.yml config.yaml Caddyfile)

changed() {  # changed <file> — true if <file>'s hash differs from the recorded one
  local old new
  old=$(grep -s "  $1\$" "$STATE_FILE" || true)
  new=$(sha256sum "$1")
  [[ "$old" != "$new" ]]
}

echo "deploy: starting at $(date -u +%FT%TZ) on $(hostname)"

# rsync -az preserves the exec bit from git, but keep this belt-and-braces line so a
# clone/copy that lost the bit can't break the nightly crons.
chmod +x scripts/*.sh

if changed docker-compose.yml; then
  echo "deploy: docker-compose.yml changed -> docker compose up -d"
  docker compose up -d
fi

if changed config.yaml; then
  echo "deploy: config.yaml changed -> force-recreate litellm"
  docker compose up -d --force-recreate litellm
fi

if changed Caddyfile; then
  if docker compose ps --status running --services | grep -qx caddy; then
    echo "deploy: Caddyfile changed -> graceful caddy reload"
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  else
    # Caddy isn't running (fresh box, or it crashed) — reload has nothing to signal.
    echo "deploy: Caddyfile changed but caddy not running -> docker compose up -d"
    docker compose up -d
  fi
fi

# Health gate, restart or not: a deploy only "succeeds" if the service answers afterwards.
# Hits the public URL from the box, so it exercises Caddy + TLS + LiteLLM, not a loopback
# shortcut. LiteLLM cold-starts (prisma migrations) can take ~30 s after a recreate.
echo "deploy: waiting for https://llm.substrate.dev/health/liveliness"
for i in $(seq 1 12); do
  if curl -fsS --max-time 10 https://llm.substrate.dev/health/liveliness > /dev/null; then
    echo "deploy: healthy (attempt $i)"
    sha256sum "${TRACKED[@]}" > "$STATE_FILE"
    echo "deploy: done at $(date -u +%FT%TZ)"
    exit 0
  fi
  sleep 5
done

echo "deploy: FAILED — service not healthy after 60s; state file NOT updated" >&2
echo "deploy: inspect with: docker compose ps; docker compose logs --tail=100 litellm caddy" >&2
exit 1
