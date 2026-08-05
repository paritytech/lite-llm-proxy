#!/usr/bin/env bash
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# Forced command for the CI deploy key (RUNBOOK.md § H). The deploy user's
# authorized_keys pins the GitHub Actions key to this script, so the key can never open a
# shell — it gets exactly two operations:
#
#   1. rsync into /opt/team-llm (and nowhere else), via rrsync — rsync's official
#      restricted-server wrapper, which re-parses SSH_ORIGINAL_COMMAND itself and confines
#      all reads/writes to the given subtree;
#   2. the literal command "deploy", which runs the repo's deploy script.
#
# This file is version-controlled here, but the live copy is installed root-owned at
# /usr/local/bin/deploy-gatekeeper — deliberately OUTSIDE the rsync'd tree, so the key it
# confines can't overwrite it. Changing it means re-running the install line in RUNBOOK § H.
#
# Residual risk, eyes open: the key can still upload files the deploy later executes
# (deploy.sh, config.yaml, docker-compose.yml), so a leaked key ultimately means code
# execution on the box — that's inherent to any push-based auto-deploy. This gate exists to
# block interactive misuse and to keep the key single-purpose; the real containment is that
# the private key lives only in the private repo's Actions secrets.
set -euo pipefail

case "${SSH_ORIGINAL_COMMAND:-}" in
  "rsync --server"*)
    # Debian/Ubuntu ship rrsync in the rsync package; the path moved across releases.
    RRSYNC=$(command -v rrsync || echo /usr/share/rsync/scripts/rrsync)
    exec "$RRSYNC" /opt/team-llm
    ;;
  deploy)
    exec /opt/team-llm/scripts/deploy.sh
    ;;
  *)
    echo "deploy-gatekeeper: refused: ${SSH_ORIGINAL_COMMAND:-<no command>}" >&2
    exit 255
    ;;
esac
