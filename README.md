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
| `kimi-k3` | Kimi K3 (flagship reasoning, 1M context, vision) |
| `claude-sonnet` | Anthropic Claude Sonnet 4.6 |
| `claude-opus` | Anthropic Claude Opus 4.8 |
| `gpt-5` | OpenAI GPT-5.5 |
| `gpt-5-mini` | OpenAI GPT-5.4 mini |
| `gemini-pro` | Google Gemini 2.5 Pro |
| `gemini-flash` | Google Gemini 3.5 Flash |
| `deepseek` | DeepSeek V3.2 |
| `deepseek-r1` | DeepSeek R1 (reasoning) |
| `deepseek-v4-pro` | DeepSeek V4 Pro |
| `minimax-m3` | MiniMax M3 |
| `llama-4-maverick` | Meta Llama 4 Maverick |

An alias and a full model ID are used exactly the same way — they're just the string you put in
the `"model"` field of the request (see the code and curl examples below).

#### Using models beyond the menu

The proxy passes through the **entire OpenRouter catalog** (~400+ models) — you don't need to wait
for a config change. Take the model's ID from <https://openrouter.ai/models> and prefix it with
`openrouter/`:

```jsonc
"model": "openrouter/qwen/qwen3-max"            // any catalog model works immediately
"model": "openrouter/deepseek/deepseek-v4-pro"  // full-ID form of the deepseek-v4-pro alias
```

Notes:

- `GET /v1/models` (with your key) lists the curated aliases from the table above. Wildcard
  models don't appear there but still work.
- **Kimi models are the exception:** the `kimi-*` aliases go directly to Moonshot, not OpenRouter,
  so only the ones in the table are available.
- If a model is rejected with a permissions error, your key may be scoped to specific models —
  ask the admin to widen it.
- Spend tracking on wildcard models is best-effort: a model too new for LiteLLM's pricing map can
  record **$0 for streamed calls** until the map catches up, so your usage dashboard may
  under-report. Budgets still apply to whatever is recorded.

**Using a model regularly?** Ask the admin (or open a PR) to add it as a named alias in
`config.yaml` — that gives it a short name, puts it in the menu above, and pins its price so
spend tracking stays accurate. That's how `deepseek-v4-pro` and `minimax-m3` were added.

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

- **OpenRouter** returns the real per-call cost; LiteLLM records it directly on **non-streaming**
  calls. On **streaming** calls our pinned LiteLLM drops that inline cost
  ([BerriAI/litellm#16021](https://github.com/BerriAI/litellm/issues/16021)) and falls back to its
  price map — so curated aliases missing from the map carry temporary price pins in `config.yaml`.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map, which is
  fetched from upstream at startup and refreshed daily by `scripts/reload-costmap.sh`. A model too
  new for the map needs a temporary price pin in `config.yaml` — including
  `cache_read_input_token_cost`, or cached tokens get metered at the full input price.
- **Wildcard caveat:** an `openrouter/*` model with no map entry meters **$0** on *streaming*
  requests (pins can't cover a wildcard). The OpenRouter key's own credit limit is the backstop.
  See `RUNBOOK.md` § "Pricing model" for the full accuracy story and upgrade path.

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
