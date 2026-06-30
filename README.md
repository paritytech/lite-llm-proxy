# Team LLM Proxy

Shared, budgeted access to **Kimi (Moonshot AI)** and **OpenRouter** (Claude, GPT, Gemini,
DeepSeek, Llama, … ~400+ models) for Parity teammates via a self-hosted
[LiteLLM](https://docs.litellm.ai) proxy. One OpenAI-compatible API over HTTPS, gated by
per-user virtual keys with individual budgets and usage tracking.

- **Base URL:** `https://llm.substrate.dev`
- **Auth:** your personal virtual key (`sk-...`), issued by the admin. Keep it secret; it carries your budget.

This repository is the **deployment definition** for that service: the Docker Compose stack,
reverse-proxy and proxy config, operational scripts, and runbook. No application source code and
**no secrets** live here — the real `.env` exists only on the host.

---

## Contents

- [For teammates — using the proxy](#for-teammates--using-the-proxy)
  - [Models](#models)
  - [From code (OpenAI SDK)](#from-code-openai-sdk)
  - [From the shell / CI](#from-the-shell--ci)
  - [Budgets & limits](#budgets--limits)
- [For operators](#for-operators)
  - [Architecture](#architecture)
  - [Repository layout](#repository-layout)
  - [Deploy & operate](#deploy--operate)
  - [Admin tasks](#admin-tasks)
  - [How pricing stays accurate](#how-pricing-stays-accurate)
- [Security model](#security-model)
- [License](#license)

---

## For teammates — using the proxy

### Models

Send one of these as the `"model"` field:

| Alias | Upstream model |
|---|---|
| `kimi-k2` | Kimi K2.6 (general default) |
| `kimi-k2.5` | Kimi K2.5 (cheaper) |
| `kimi-k2.7-code` | Kimi K2.7 Code (strongest coding) |
| `claude-sonnet` | Anthropic Claude Sonnet 4.6 |
| `claude-opus` | Anthropic Claude Opus 4.8 |
| `gpt-5` | OpenAI GPT-5.5 |
| `gpt-5-mini` | OpenAI GPT-5.4 mini |
| `gemini-pro` | Google Gemini 2.5 Pro |
| `gemini-flash` | Google Gemini 3.5 Flash |
| `deepseek` | DeepSeek V3.2 |
| `deepseek-r1` | DeepSeek R1 (reasoning) |
| `llama-4-maverick` | Meta Llama 4 Maverick |

**Any other OpenRouter model** works via its full ID, e.g. `"model": "openrouter/qwen/qwen3-max"`
(browse the catalog at <https://openrouter.ai/models>).

### From code (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(base_url="https://llm.substrate.dev", api_key="sk-YOUR-KEY")
resp = client.chat.completions.create(
    model="claude-sonnet",   # or kimi-k2, gpt-5, gemini-pro, ...
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

### From the shell / CI

```bash
curl https://llm.substrate.dev/v1/chat/completions \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Hello!"}]}'
```

In CI, store your key as a secret named `LLM_KEY` (or similar) — never commit it.

### Budgets & limits

Each key has a monthly `max_budget` and an rpm cap, spanning all models. When you hit your budget,
requests are rejected until the 30-day window resets. Ask the admin to raise it if you need more.

---

## For operators

### Architecture

One `docker compose` stack. Three containers on a private Docker network; only Caddy publishes
host ports.

```
internet ──443/80──> caddy ──> litellm:4000 ──> postgres:5432
                     (TLS)      (proxy)          (keys / budgets / usage / logs)
```

- **caddy** — reverse proxy + automatic Let's Encrypt TLS. The only container exposing ports (80, 443).
- **litellm** — the proxy itself, on a **pinned image tag** (never `latest` — LiteLLM ships breaking
  changes). Listens on 4000 on the internal network only.
- **postgres** — virtual keys, budgets, per-key spend, request logs. Persisted in a named volume,
  never published to the host.

### Repository layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The three-container stack (caddy + litellm + postgres). |
| `Caddyfile` | TLS + reverse-proxy config. The site label is the public hostname. |
| `config.yaml` | LiteLLM model list (Kimi + OpenRouter aliases + wildcard) and settings. |
| `.env.example` | Template for the real `.env` (secrets) that lives only on the host. |
| `scripts/backup.sh` | Nightly `pg_dump` of the LiteLLM database, verified and pruned. |
| `scripts/reload-costmap.sh` | Refresh LiteLLM's price map from upstream (no restart). |
| `RUNBOOK.md` | Step-by-step provisioning, deploy, key lifecycle, and DNS cutover. |
| `SPEC.md` | The original design and rationale (background reference). |

### Deploy & operate

`RUNBOOK.md` is the authoritative, copy-pasteable guide. In short:

1. The host runs the stack from `/opt/team-llm`; the repo is rsync'd there (excluding `.env`).
2. Secrets are generated and written to `/opt/team-llm/.env` (chmod 600) — **never committed**.
3. `docker compose up -d` brings up Caddy (which auto-issues the Let's Encrypt cert), LiteLLM, and Postgres.
4. Nightly crons run the backup and price-map refresh.

To change models or settings: edit `config.yaml`, commit, rsync to the host, then
`docker compose up -d --force-recreate litellm`.

### Admin tasks

- **Admin UI:** `https://llm.substrate.dev/ui` (log in with the master key).
- **Mint a key:** `POST /key/generate` with `models`, `max_budget`, `budget_duration`, `rpm_limit`,
  `user_id`. Omit `models` (or pass `["all-proxy-models"]`) to allow every model above.
- **Revoke a key:** `POST /key/delete`.
- **Usage:** `GET /key/info?key=...` or the UI.

See `RUNBOOK.md` § D for the full mint → use → track → revoke walkthrough.

### How pricing stays accurate

- **OpenRouter** returns the real per-call cost; LiteLLM records it directly — no hardcoded prices.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map, which is
  fetched from upstream at startup and refreshed daily by `scripts/reload-costmap.sh`. A model too
  new for the map needs a temporary `input_/output_cost_per_token` pin in `config.yaml`.
- **Wildcard caveat:** an `openrouter/*` model with no map entry may under-meter on *streaming*
  requests. The OpenRouter key's own credit limit is the backstop. See `RUNBOOK.md` for detail.

---

## Security model

- **No secrets in this repo.** The real `.env` (master key, salt key, Postgres password, upstream
  Moonshot and OpenRouter keys) lives only on the host, chmod 600, and is git-ignored.
- **Upstream keys never leave the server.** Teammates only ever hold their own scoped virtual keys.
- **Network:** only ports 22/80/443 are open (`ufw`). LiteLLM (4000) and Postgres (5432) stay on
  the internal Docker network.
- **TLS everywhere** via Caddy + Let's Encrypt.
- **`LITELLM_SALT_KEY` must not be rotated after launch** — it encrypts provider keys stored in the
  DB, and rotating it invalidates them.

---

## License

Licensed under the [Apache License, Version 2.0](./LICENSE).

`SPDX-License-Identifier: Apache-2.0`
