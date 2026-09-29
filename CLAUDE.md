# CLAUDE.md

Guidance for Claude Code working in this repository.

**Read [`AGENTS.md`](./AGENTS.md) first** — it is the canonical, tool-agnostic operating guide
(what this repo is, conventions, repo layout, deploy model, and the change checklist). This file
adds Claude-specific notes and repeats the rules that must never be missed.

## The repo in one line

Deployment definition for the **Team LLM Proxy** — Ansible playbooks that build the box (Docker,
host nginx + certbot, firewall) plus a two-container Compose stack (LiteLLM + Postgres), giving
Parity teammates budgeted access to Kimi and OpenRouter models, plus DeepSeek Flash served by
Parity's own vLLM GPU pod over a reverse SSH tunnel. It drives a **live production service** at
`https://ai.labs.paritytech.io`. No app source, no build, no test suite.

## Non-negotiable rules (full detail in AGENTS.md)

1. **Never commit plaintext secrets.** They live encrypted in
   `ansible/group_vars/all/vault.yml`. Only `vault.yml.example`, with `REPLACE_*` placeholders,
   is plaintext.
2. **Keep the LiteLLM image tag pinned** in `docker-compose.yml` — never `latest`.
3. **Never rotate `LITELLM_SALT_KEY`** on a live deployment. With `store_model_in_db: true` it
   encrypts the model menu, not just stored credentials.
4. **Don't run playbooks, touch the live host, mint/revoke keys, push to GitHub, or file
   tickets** unless the user asks in this session. Editing files is safe; real-world actions
   need explicit go-ahead.
5. **SPDX header on every new code/config file:**
   ```
   # Copyright (C) Parity Technologies (UK) Ltd.
   # SPDX-License-Identifier: Apache-2.0
   ```
   (after the shebang in shell scripts; Jinja templates use plain `#` so it renders into the
   output file; not on Markdown or `LICENSE`).

## Working here

- **Merging a PR deploys nothing.** There is no CI deploy path. Never tell the user a change
  will "go live on merge" — an operator runs the relevant playbook.
- **Box configuration belongs in a role.** If the answer to a request is "then run this on the
  box", it belongs in `ansible/`, not in `RUNBOOK.md`. Playbooks must be idempotent: a second
  run reports zero changed tasks.
- **The model menu is in the admin UI, not `config.yaml`.** Adding or changing a model is a UI
  action; `config.yaml` holds only what is read before the database is consulted, and should
  stay small. `RUNBOOK.md` § "Model menu" is its written record — when the menu changes, that
  table changes in the same PR.
- When asked about LLM models, pricing, or limits, don't answer from memory — `RUNBOOK.md`
  § "Model menu" and the `claude-api` skill are the sources of truth for this repo's menu.
- **"Enable model X" is usually a no-op:** the `openrouter/*` wildcard already serves any
  OpenRouter model by full ID with live cost tracking. Only a curated alias or a Kimi/Moonshot
  model needs an actual change — and that change is made in the UI.
- **Never add price pins to OpenRouter entries** — OpenRouter's real per-call cost is recorded
  directly (streamed included, verified 2026-08-12), and a pin overrides it. Pins are only for
  Kimi models missing from the price map, and the explicit `0` on the pod-backed `auto/` and
  `parity/` entries (pod tokens are free to teammates; keep it a literal `0`, never absent — an
  absent price means "unmapped model" to LiteLLM, and unmapped requests are dropped from the
  spend logs). `$0` also makes LiteLLM skip budget checks for those aliases.
- **Prompt bodies are not stored, and README promises that.**
  `store_prompts_in_spend_logs` is deliberately absent from `config.yaml`. Don't add it without
  the user explicitly deciding to change the promise made to teammates.
- **DeepSeek Flash is self-hosted** (Parity vLLM pod → reverse SSH tunnel into the box) and
  ships as **three aliases named `<routing>/<model-id>`**: `auto/deepseek-v4.1-flash` (pod, and
  the alias that carries the OpenRouter fallback), `parity/deepseek-v4.1-flash` (pod ONLY —
  never gets a fallback, the hard prompts-stay-in-infra guarantee), and
  `openrouter/deepseek-v4.1-flash` (cloud only). Keep the two pod rows in lockstep; their
  per-row parallel caps sum to the pod's ~32 knee (20 + 12). Moving parts span
  `ansible/roles/vllm_tunnel` and the UI model menu — read `RUNBOOK.md` § "vLLM pod" first.
- **`config.yaml` configures no fallbacks, deliberately.** `auto/`'s is set explicitly in the
  admin UI as a rollout step, so until an operator does it, `auto/` behaves like `parity/` and
  README says so. Don't reinstate a `litellm_settings.fallbacks` block — enabling the fallback
  is a UI action, not a file edit.
- **The model id is part of every alias's name on purpose.** Whenever the pod is redeployed
  with a new model, the same PR must add a matching new set of three `<routing>/<model-id>`
  aliases and update the model tables in `RUNBOOK.md` and `README.md` and the alias lists here
  and in `AGENTS.md` — the name is the user-facing promise of exactly which model answers.
- **Two sshd gotchas worth not re-learning.** A `Match` block must be appended to the end of
  `/etc/ssh/sshd_config` itself, never a `sshd_config.d` drop-in (Ubuntu includes drop-ins at
  the *top*, and a `Match` stays in force to end of file — it would swallow the main config).
  Plain directives are the opposite: a drop-in wins, because OpenSSH honours the first value it
  reads. Both cases are commented in the roles that rely on them.
- After changing deploy/ops behavior, update `RUNBOOK.md` (and `README.md` if user-facing).
- There is no automated test suite. "Verification" here means: YAML parses, `ansible-lint` is
  clean, `ansible-playbook --syntax-check` passes, the SPDX header is present, no secret leaked,
  and `RUNBOOK.md`/`README.md` still match reality.
