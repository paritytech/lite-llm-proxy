#!/usr/bin/env bash
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# Refresh LiteLLM's model price map from the upstream GitHub map (no restart needed).
# Keeps prices current for day-0 / streaming requests, and for providers like
# Moonshot/Kimi that don't return per-call cost (so spend is map-only).
#
# Run nightly by the litellm-costmap.timer systemd unit (ansible/roles/stack).
# Talks to the container's published loopback port rather than the public URL, so
# the job does not depend on DNS, TLS or nginx being healthy.
set -euo pipefail
cd /opt/team-llm
MASTER=$(grep '^LITELLM_MASTER_KEY=' .env | cut -d= -f2-)
curl -fsS -X POST http://127.0.0.1:4000/reload/model_cost_map \
  -H "Authorization: Bearer ${MASTER}"
echo
