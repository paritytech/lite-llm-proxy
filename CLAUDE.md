# CLAUDE.md

Guidance for Claude Code working in this repository.

**Read [`AGENTS.md`](./AGENTS.md) first** — it is the canonical, tool-agnostic operating guide
(what this repo is, conventions, repo layout, deploy model, and the change checklist). This file
adds Claude-specific notes and repeats the rules that must never be missed.

## The repo in one line

Deployment definition for the **Team LLM Proxy** — a self-hosted LiteLLM gateway (Docker Compose:
Caddy + LiteLLM + Postgres) giving Parity teammates budgeted access to Kimi and OpenRouter models.
It drives a **live production service** at `https://llm.substrate.dev`. No app source, no build, no
test suite — it's config, scripts, and docs.

## Non-negotiable rules (full detail in AGENTS.md)

1. **Never commit secrets.** Real keys live only in the host's `.env` (git-ignored). Only
   `.env.example` with `REPLACE_*` placeholders is tracked.
2. **Keep the LiteLLM image tag pinned** in `docker-compose.yml` — never `latest`.
3. **Never rotate `LITELLM_SALT_KEY`** after launch — it invalidates DB-stored provider keys.
4. **Don't deploy, reload the live host, mint/revoke keys, push to GitHub, or file tickets** unless
   the user asks in this session. Editing files is safe; real-world actions need explicit go-ahead.
5. **SPDX header on every new code/config file:**
   ```
   # Copyright (C) Parity Technologies (UK) Ltd.
   # SPDX-License-Identifier: Apache-2.0
   ```
   (after the shebang in shell scripts; not on Markdown or `LICENSE`).

## Working here

- Prefer small, well-commented edits — the existing files explain *why*, not just *what*; preserve
  that rationale.
- When asked about LLM models, pricing, or limits, don't answer from memory — `config.yaml` and the
  `claude-api` skill are the sources of truth for this repo's model menu.
- After changing deploy/ops behavior, update `RUNBOOK.md` (and `README.md` if it's user-facing).
- There is no automated test or lint step. "Verification" here means: YAML still parses, the SPDX
  header is present, no secret leaked, and `RUNBOOK.md`/`README.md` still match reality.
