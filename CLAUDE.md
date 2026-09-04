# CLAUDE.md

Guidance for Claude Code working in this repository.

**Read [`AGENTS.md`](./AGENTS.md) first** — it is the canonical, tool-agnostic operating guide
(what this repo is, conventions, repo layout, deploy model, and the change checklist). This file
adds Claude-specific notes and repeats the rules that must never be missed.

## The repo in one line

Deployment definition for the **Team LLM Proxy** — a self-hosted LiteLLM gateway (Docker Compose:
Caddy + LiteLLM + Open WebUI + Postgres) giving Parity teammates budgeted access to Kimi and OpenRouter models,
plus `deepseek-flash` served by Parity's own vLLM GPU pod via a reverse SSH tunnel (RUNBOOK § I).
It drives a **live production service** at `https://llm.substrate.dev`. No app source, no build, no
test suite — it's config, scripts, and docs.

## Non-negotiable rules (full detail in AGENTS.md)

1. **Never commit secrets.** Real keys live only in the host's `.env` (git-ignored). Only
   `.env.example` with `REPLACE_*` placeholders is tracked.
2. **Keep image tags pinned** (`litellm`, `openwebui`) in `docker-compose.yml` — never `latest`.
3. **Never rotate `LITELLM_SALT_KEY`** after launch — it invalidates DB-stored provider keys.
   Same for **`LOG_EXPORT_SESSION_SALT`** — rotating it unlinks corpus sessions spanning the
   rotation date.
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
- **"Enable model X"** is usually a no-op: the `openrouter/*` wildcard in `config.yaml` already
  serves any OpenRouter model by full ID with live cost tracking (see AGENTS.md § Conventions).
  Config edits are only needed for a curated alias, or for Kimi/Moonshot models (menu entry +
  possible temporary price pin).
- **Never add price pins to OpenRouter entries** — OpenRouter's real per-call cost is recorded
  directly (streamed included, verified 2026-08-12), and a pin overrides it. Pins are only for
  Kimi models missing from the price map, and the explicit `0` pin on the three self-hosted
  `deepseek-flash*` pod entries (pod tokens are free to teammates; keep it a literal `0`, never
  delete it — an absent price means "unmapped model" to LiteLLM, and unmapped requests are
  dropped from the spend logs). `$0` also makes LiteLLM skip budget checks for those aliases.
- **`deepseek-flash` is self-hosted** (Parity vLLM pod → reverse SSH tunnel into the box, with
  OpenRouter fallback) and ships as **four aliases**: `deepseek-flash` (pod + fallback),
  `deepseek-flash-parity` (pod ONLY — no fallback, the hard prompts-stay-in-infra guarantee),
  `deepseek-flash-parity-v4-0731` (pod ONLY, version pinned in the name), and
  `deepseek-flash-openrouter` (cloud only). Keep the three `hosted_vllm` entries in lockstep;
  their per-entry parallel caps sum to the pod's ~32 knee (20 + 8 + 4). Moving parts span the box
  (tunnel account, sshd, ufw) and `config.yaml` — read RUNBOOK § I before changing any of it.
- **The versioned alias hard-codes the pod's model version.** Whenever the pod is redeployed
  with a new model, the same PR must add the matching `deepseek-flash-parity-<version>` alias
  and update the model tables in `README.md` and the alias lists here and in `AGENTS.md` —
  that name is the user-facing promise of exactly which model the pod serves.
- After changing deploy/ops behavior, update `RUNBOOK.md` (and `README.md` if it's user-facing).
- There is no automated test or lint step. "Verification" here means: YAML still parses, the SPDX
  header is present, no secret leaked, and `RUNBOOK.md`/`README.md` still match reality.
