# AGENTS.md

Operating guide for AI coding agents (Claude Code, Codex, Copilot, Cursor, etc.) working in this
repository. Human contributors should read it too — it documents the non-obvious rules.

## What this repo is

The **deployment definition** for the Team LLM Proxy: a self-hosted [LiteLLM](https://docs.litellm.ai)
gateway that gives Parity teammates budgeted, per-user access to Kimi (Moonshot AI) and OpenRouter
models — plus `deepseek-flash`, served by **Parity's own vLLM GPU pod** over a reverse SSH tunnel
(`RUNBOOK.md` § I) — behind one OpenAI-compatible HTTPS API, with a hosted **Open WebUI chat
frontend** on top (`RUNBOOK.md` § J). It is a small ops repo — Docker Compose, a Caddyfile, a
LiteLLM `config.yaml`, a handful of scripts, and docs. **There is no application source code to
build or test.** See `README.md` for the overview and `RUNBOOK.md` for operations.

This config drives a **live, shared production service** at `https://llm.substrate.dev` (chat UI:
`https://llm.substrate.dev:8443`). Treat changes accordingly.

## Golden rules

1. **Never commit secrets.** No real keys, passwords, or tokens in any tracked file. The real `.env`
   lives only on the host (chmod 600) and is git-ignored. Only `.env.example` (placeholders) is
   tracked. If you add a new secret, add it to `.env.example` with a `REPLACE_*` placeholder — never
   a real value. (Exception: a secret the stack must deploy WITHOUT may be a deliberately empty
   value instead of `REPLACE_*`, so provisioning's "no placeholders left" check stays meaningful —
   see `OPENWEBUI_SHARED_KEY`.)
2. **Keep image tags pinned.** In `docker-compose.yml` the `litellm` and `openwebui` images are
   pinned versions (e.g. `:v1.95.0`), never `latest`/`main-latest` — both ship breaking changes.
   To upgrade LiteLLM, bump the tag deliberately, note it, and re-run the streaming-cost
   spot-check (`RUNBOOK.md` § "Pricing model"); for Open WebUI, read the release notes
   (`RUNBOOK.md` § J ops notes).
3. **Never rotate `LITELLM_SALT_KEY` after launch.** It encrypts provider keys stored in Postgres;
   rotating it invalidates them.
4. **Don't run commands against the live host or push to GitHub on the user's behalf** unless they
   explicitly ask in this session. Editing files here is safe; deploying, reloading Caddy, minting/
   revoking keys, or filing tickets are real-world actions — propose them, don't perform them unasked.
5. **SPDX headers on every new file.** See [License headers](#license-headers).

## Conventions

- **License headers:** every code/config file starts with the two-line SPDX header (below). Markdown
  docs and `LICENSE` are exempt.
- **Comments:** the existing files are heavily and deliberately commented — comments explain *why*
  (e.g. why a price is pinned, why a port isn't published). Match that density; keep the rationale
  when you edit a line it explains.
- **Public URLs** live in exactly one place: the site labels in `Caddyfile` (`llm.substrate.dev`
  = API, `llm.substrate.dev:8443` = Open WebUI chat — same hostname on purpose: new DNS labels
  need an external grant, ports don't; the typeable `llm.substrate.dev/chat` is an exact-path
  redirect to `:8443`, safely distinct from the API's `/chat/completions`). Changing a public
  URL is a one-line edit there plus a Caddy reload (see `RUNBOOK.md` § F) — plus, for the chat
  UI, the matching `WEBUI_URL` in `docker-compose.yml` (and ufw if the port changes).
- **Models & pricing** live in `config.yaml`. OpenRouter returns the real per-call cost and
  LiteLLM records it directly, streamed calls included (verified on-box 2026-08-12) — so
  **OpenRouter entries must stay pin-free**: a hardcoded `input_/output_cost_per_token` pin
  *overrides* the real cost. Pins belong in exactly two cases: a provider that returns no
  per-call cost (Kimi/Moonshot — pin models too new for LiteLLM's auto-fetched price map, and
  remove the pin once the map catches up), and the explicit **$0** pin on the three self-hosted
  `deepseek-flash*` pod entries — pod tokens are free to teammates and must not drain key
  budgets, and the pin has to be a literal `0` rather than absent (absent = "look up the price
  map", which has no entry for the pod's served model, so cost calc fails and the request is
  dropped from the spend logs). Note that LiteLLM skips budget checks entirely for $0 model
  groups, so over-budget keys can still use the pod aliases. See the comments there.
- **"Enable model X" requests are usually a no-op.** The `openrouter/*` wildcard in `config.yaml`
  already serves every OpenRouter model by its full ID (`openrouter/<org>/<model>`), with spend
  metered from OpenRouter's real per-call cost — no config change, no price pin, no deploy. Only
  edit `config.yaml` if (a) the requester wants a short curated alias, or (b) it's a **Kimi/
  Moonshot** model — those need a `model_list` entry and, if too new for LiteLLM's price map, a
  temporary cost pin (Moonshot returns no per-call cost). Point teammates at README § "Models".
- **`deepseek-flash` is special:** it's served by Parity's own vLLM GPU pod through a reverse SSH
  tunnel into the box, with automatic fallback to OpenRouter when the pod is down or saturated.
  It ships as **four aliases** with different routing contracts: `deepseek-flash` (pod first,
  OpenRouter fallback), `deepseek-flash-parity` (pod ONLY — no fallback, the hard
  prompts-stay-in-infra guarantee; fails fast when the pod is down),
  `deepseek-flash-parity-v4-0731` (pod ONLY like `-parity`, but the name pins exactly which
  model version the pod serves), and `deepseek-flash-openrouter` (OpenRouter only). Keep the
  three `hosted_vllm` entries' `litellm_params` in lockstep, and mind the parallel caps:
  they're per entry and sum to the pod's ~32-parallel knee (20 + 8 + 4). Changes can involve
  the box (tunnel account, ufw) as well as `config.yaml` — read `RUNBOOK.md` § I before
  touching any of it.
- **The versioned parity alias is a hard-coded promise.** `deepseek-flash-parity-<version>`
  exists so users can pin (and verify) exactly which model the pod serves, while the unversioned
  aliases float. Whenever the pod is redeployed with a new model version, the same PR must add
  the matching new `deepseek-flash-parity-<version>` alias (retiring the old one once the old
  model stops being served) and update the model tables in `README.md` and the alias lists in
  `CLAUDE.md` and here.

## Repository layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | caddy + litellm + openwebui + postgres stack. Only caddy publishes host ports. |
| `Caddyfile` | TLS + reverse proxy. Site labels = public hostnames (API + chat UI). |
| `config.yaml` | LiteLLM model list (Kimi + OpenRouter aliases + `openrouter/*` wildcard) + settings. |
| `.env.example` | Secrets template. Real `.env` is host-only, git-ignored. |
| `scripts/backup.sh` | Nightly verified `pg_dump`, pruned after 14 days. |
| `scripts/reload-costmap.sh` | Refresh LiteLLM price map from upstream (no restart). |
| `scripts/export-logs.sh` | Nightly de-identified JSONL export of request logs (training corpus). |
| `scripts/scrub-logs.py` | PII/credential scrub filter used by the export (local Presidio). |
| `scripts/deploy.sh` | Change-aware deploy step CI runs on the box (restarts only what changed). |
| `scripts/deploy-gatekeeper.sh` | Forced command pinning the CI SSH key to rsync + deploy only. |
| `.github/workflows/validate.yml` | CI checks: YAML parses, shellcheck, SPDX, no secrets. |
| `.github/workflows/deploy.yml` | Auto-deploy on merge to `main` (+ manual dispatch). |
| `setup/` | Teammate-facing harness setup: one-command installer (`setup.sh`) + per-tool guides (`harnesses/`). |
| `docs/specs/` | Dated design/review docs (request logging, privacy data flow, security review). |
| `RUNBOOK.md` | Authoritative step-by-step: provision → deploy → key lifecycle → DNS cutover. |
| `SPEC.md` | Original design and rationale (background). |

## Deploy model (so you don't suggest the wrong thing)

- The host runs the stack from `/opt/team-llm`. **Merging a PR to `main` deploys it**:
  `.github/workflows/deploy.yml` rsyncs the repo there (excluding `.env`, `.git`, `backups/`,
  `logs/`, `.deploy-state`) as a locked-down `deploy` user and runs `scripts/deploy.sh`, which
  restarts only what the change touched (config.yaml → force-recreate litellm; Caddyfile →
  graceful reload; docs/scripts → no restart). Setup and details: `RUNBOOK.md` § H.
- Therefore: **a merged PR is a production deploy.** Config edits land on the live service
  minutes after merge — there is no separate "apply" step to gate them.
- Manual/break-glass paths still exist (`workflow_dispatch` re-deploy; on-box edits as the
  deploy user) — see `RUNBOOK.md` § H. The original laptop-rsync flow remains only for
  provisioning a new box (§ A–B).
- `RUNBOOK.md` marks each step as run on the **box** or on the **[laptop]**. Respect that split.

## Making changes — checklist

- [ ] Editing `config.yaml`? Keep YAML valid; preserve `os.environ/...` references (never inline a key).
- [ ] Added a setting that needs a secret? Add a placeholder to `.env.example`.
- [ ] New file? Add the SPDX header.
- [ ] Changed deploy/ops behavior? Update `RUNBOOK.md` (and `README.md` if user-facing).
- [ ] Bumped the LiteLLM or Open WebUI tag? Confirm it's a real, stable release and note the date.

## License headers

Apache-2.0. Start each new code/config file with the comment syntax for that file type:

```
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
```

For shell scripts, place it immediately **after** the `#!/usr/bin/env bash` shebang. Markdown files
and `LICENSE` do not get a header.
