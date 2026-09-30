# AGENTS.md

Operating guide for AI coding agents (Claude Code, Codex, Copilot, Cursor, etc.) working in this
repository. Human contributors should read it too — it documents the non-obvious rules.

## What this repo is

The **deployment definition** for the Team LLM Proxy: a self-hosted [LiteLLM](https://docs.litellm.ai)
gateway giving Parity teammates budgeted, per-user access to Kimi (Moonshot AI) and OpenRouter
models — plus DeepSeek Flash served by **Parity's own vLLM GPU pod** over a reverse SSH tunnel —
behind one OpenAI-compatible HTTPS API at `https://ai.labs.paritytech.io`.

It is a small ops repo: Ansible playbooks, a Docker Compose file, a deliberately tiny LiteLLM
config, one script, and docs. **There is no application source code to build or test.** See
`README.md` for the overview and `RUNBOOK.md` for operations.

This config drives a **live, shared production service**. Treat changes accordingly.

## Golden rules

1. **Never commit plaintext secrets.** They live in `ansible/group_vars/all/vault.yml`,
   encrypted with `ansible-vault`. `vault.yml.example` is the tracked plaintext template and
   must only ever contain `REPLACE_*` placeholders. CI fails if `vault.yml` does not begin with
   `$ANSIBLE_VAULT`.
2. **Keep the image tag pinned.** `docker-compose.yml` pins LiteLLM to a version (e.g.
   `:v1.97.0`), never `latest`/`main-latest` — it ships breaking changes in point releases. To
   upgrade, bump deliberately, note the date, and re-run the streaming and pricing spot-checks
   in `RUNBOOK.md`.
3. **Never rotate `LITELLM_SALT_KEY` on a live deployment.** With `store_model_in_db: true` it
   encrypts the model menu as well as stored credentials, so rotating it destroys both.
4. **Don't run playbooks, touch the live host, mint or revoke keys, push to GitHub, or file
   tickets** unless the user asks in this session. Editing files here is safe; those are
   real-world actions — propose them, don't perform them unasked.
5. **SPDX headers on every new code/config file.** See [License headers](#license-headers).

## Conventions

- **The machine is Ansible's.** Anything about how the box is configured — packages, Docker,
  nginx, TLS, users, firewall, systemd units — belongs in `ansible/`, not in a shell script and
  not in a runbook step. If you find yourself writing "then run this command on the box", it
  probably belongs in a role.
- **Merging a PR deploys nothing.** There is no CI deploy path and no deploy credentials in this
  repo. Changes reach the box when an operator runs a playbook. Never suggest "merge and it'll
  go live".
- **Public URLs live in exactly one place:** `public_hostname` in
  `ansible/group_vars/all/vars.yml`. Changing the service's URL is that line, a DNS record, and
  a re-run of `02-nginx.yml`. Nothing else hardcodes it — keep it that way.
- **The model menu lives in the admin UI, not in `config.yaml`.** `store_model_in_db: true`
  means models are rows in Postgres, added through `/ui`. `config.yaml` holds only the settings
  that are read before any database is consulted, and should stay small. `RUNBOOK.md`
  § "Model menu" is the written record of what the UI contains and what to replay after a
  database loss — **when the menu changes, that table changes in the same PR.**
- **Provider credentials are named in `config.yaml`'s `credential_list`, and selected by name
  in the UI** — never pasted into a model form. Their values are `os.environ/…` references, so
  a model row in Postgres holds a credential name and the secret stays in the vault-rendered
  `.env`. This is the one part of provider configuration that deliberately stays in the file:
  it is what lets the model menu live in the database without the credentials following it.
- **"Enable model X" requests are usually a no-op.** The `openrouter/*` wildcard already serves
  every OpenRouter model by its full ID (`openrouter/<org>/<model>`), with spend metered from
  OpenRouter's real per-call cost. A change is only needed for (a) a short curated alias or
  (b) a **Kimi/Moonshot** model, which needs its own row and possibly a temporary price pin.
  Either way it is a UI action, not a code change. Point teammates at README § "Models".
- **Pricing pins, in exactly two cases.** OpenRouter reports its real per-call cost and LiteLLM
  records it, streamed calls included (verified 2026-08-12) — so **OpenRouter rows must stay
  pin-free**: a pin *overrides* the real cost. Pins belong on Kimi models too new for LiteLLM's
  price map (Moonshot returns no per-call cost; remove the pin once the map catches up), and as
  the explicit **`0`** on the pod-backed `auto/` and `parity/` rows. That zero must be a literal
  `0`, never absent — absent means "look up the price map", which has no entry for the pod's
  served model, so cost calculation fails and the request is dropped from the spend logs
  entirely. `$0` also makes LiteLLM skip budget checks for those aliases.
- **Prompt bodies are not stored, and that is a promise.** `store_prompts_in_spend_logs` is
  deliberately absent from `config.yaml` (it defaults off). README § "Logging & privacy" tells
  teammates their message content is never written to disk. Do not add that setting without the
  user explicitly deciding to change the promise.
- **DeepSeek Flash is special:** served by Parity's own vLLM pod through a reverse SSH tunnel.
  Three aliases named `<routing>/<model-id>`: `auto/deepseek-v4.1-flash` (pod, and the alias
  that carries the OpenRouter fallback), `parity/deepseek-v4.1-flash` (pod ONLY — never gets a
  fallback, the hard prompts-stay-in-infra guarantee, fails fast when the pod is down), and
  `openrouter/deepseek-v4.1-flash` (cloud only). Keep the two pod rows' parameters in lockstep,
  and mind the parallel caps: they are per row and sum to the pod's ~32 knee (20 + 12).
  Read `RUNBOOK.md` § "vLLM pod" before touching any of it.
- **Fallbacks are configured in the admin UI, and `config.yaml` has none on purpose.** The
  `auto/` fallback is a deliberate, explicit rollout step rather than something that ships in a
  file — so until an operator sets it, `auto/` behaves exactly like `parity/`. Don't "restore"
  a `litellm_settings.fallbacks` block; if asked to enable the fallback, that is a UI action.
- **The model id is a hard-coded promise.** Baking it into every alias name lets users pin and
  verify exactly which model the pod serves. When the pod is redeployed with a new model, the
  same change adds a matching new set of three `<routing>/<model-id>` aliases (retiring the old
  set once the old model stops being served) and updates the model tables in `RUNBOOK.md` and
  `README.md` and the alias lists here and in `CLAUDE.md`.
- **Comments explain *why*.** The existing files are heavily and deliberately commented —
  why a price is pinned, why a port isn't published, why an sshd `Match` block cannot live in a
  drop-in. Match that density, and keep the rationale when you edit a line it explains.

## Repository layout

| Path | Purpose |
|---|---|
| `ansible/00-bootstrap.yml` | One-shot, connects as root: creates the admin account. |
| `ansible/01-box.yml` | Packages, Docker, SSH hardening, firewall. |
| `ansible/02-nginx.yml` | nginx, site config, Let's Encrypt, auto-renewal. |
| `ansible/03-stack.yml` | `/opt/team-llm`, rendered `.env`, compose up, health gate. |
| `ansible/04-tunnel.yml` | vLLM pod SSH account, sshd policy, container→host ufw rule. |
| `ansible/site.yml` | Phases 01–04 in order (bootstrap deliberately excluded). |
| `ansible/group_vars/all/vars.yml` | Non-secret config. `public_hostname` lives here. |
| `ansible/group_vars/all/vault.yml` | Encrypted secrets. `.example` alongside lists them. |
| `docker-compose.yml` | litellm + postgres. LiteLLM published on loopback only. |
| `config.yaml` | Only the LiteLLM settings the admin UI cannot express. |
| `scripts/reload-costmap.sh` | Nightly price-map refresh, run by a systemd timer. |
| `.github/workflows/validate.yml` | CI: YAML, ansible-lint, shellcheck, SPDX, no secrets. |
| `RUNBOOK.md` | Rebuild from zero, the model menu, key lifecycle, pod ops. |

## Deploy model (so you don't suggest the wrong thing)

- The host runs the stack from `/opt/team-llm`, but **nothing gets there by merging.** An
  operator runs `ansible-playbook 03-stack.yml` (or whichever phase owns the change) from their
  own machine, over their own SSH access.
- Phases are independently re-runnable and ordered by dependency. `00-bootstrap.yml` is the
  exception: it connects as root, runs once, and `01-box.yml` disables root login afterwards —
  which is the mechanism that proves the replacement account works before root goes away.
- **A second run of any playbook must report zero changed tasks.** If a task reports changed
  every time, it is a bug: something is a disguised shell command rather than declared state.
- `RUNBOOK.md` marks what runs where. Respect that split.

## Making changes — checklist

- [ ] Touching the box's configuration? It belongs in a role, not a runbook step.
- [ ] Added a secret? Add a `REPLACE_*` placeholder to `vault.yml.example` — never a real value.
- [ ] Changed the model menu? Update `RUNBOOK.md` § "Model menu" and `README.md`'s tables.
- [ ] New file? Add the SPDX header.
- [ ] Changed deploy/ops behavior? Update `RUNBOOK.md` (and `README.md` if user-facing).
- [ ] Bumped the LiteLLM tag? Confirm it is a real stable release, note the date, re-run the
      streaming and pricing checks.
- [ ] Is the change idempotent? Re-running must report no changes.

## License headers

Apache-2.0. Start each new code/config file with the comment syntax for that file type:

```
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
```

For shell scripts, place it immediately **after** the `#!/usr/bin/env bash` shebang — the same
applies to templates that render a script. Jinja templates use a plain `#` comment so the header
survives into the rendered file. Markdown files and `LICENSE` do not get a header.
