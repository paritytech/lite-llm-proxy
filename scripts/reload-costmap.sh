#!/usr/bin/env bash
# Refresh LiteLLM's model price map from the upstream GitHub map (no restart needed).
# Keeps prices current for day-0 / streaming requests, and for providers like
# Moonshot/Kimi that don't return per-call cost (so spend is map-only).
set -euo pipefail
cd /opt/team-llm
MASTER=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2)
curl -fsS -X POST https://llm.195-154-218-5.sslip.io/reload/model_cost_map \
  -H "Authorization: Bearer ${MASTER}"
echo
