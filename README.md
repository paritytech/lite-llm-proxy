# Team LLM Proxy

Shared, budgeted access to **Kimi (Moonshot AI)**, **OpenRouter** (Claude, GPT, Gemini,
DeepSeek, Llama, … ~400+ models), and **Parity's own self-hosted GPU serving**
(`auto/deepseek-v4.1-flash`) for Parity teammates via a self-hosted
[LiteLLM](https://docs.litellm.ai) proxy. One OpenAI-compatible API over HTTPS, gated by
per-user virtual keys with individual budgets and usage tracking.

- **Base URL:** `https://ai.labs.paritytech.io`
- **Auth:** your personal virtual key (`sk-...`), issued by the admin. Keep it secret; it carries your budget.

This repository is the **deployment definition** for that service: the Ansible playbooks that
build the machine, the Docker Compose stack, the proxy config, and the runbook. No application
source code and **no plaintext secrets** live here — the real `.env` is rendered on the host
from an encrypted vault.

---

## Contents

- [For teammates — using the proxy](#for-teammates--using-the-proxy)
  - [Models](#models)
  - [From code (OpenAI SDK)](#from-code-openai-sdk)
  - [From the shell / CI](#from-the-shell--ci)
  - [Budgets & limits](#budgets--limits)
  - [Logging & privacy](#logging--privacy)
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

Any OpenRouter model can be served: send `openrouter/<its id>`
([details](#using-models-beyond-the-menu)).

Models we self-host on Parity's GPU pod:

| Model | Status | Alias |
|---|---|---|
| DeepSeek V4.1 Flash | Serving | `auto/deepseek-v4.1-flash`, `parity/deepseek-v4.1-flash` |
| DeepSeek V4 Flash 0731 | Retired 2026-09-16 | none |

Curated aliases (send one of these as the `"model"` field):

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
| `auto/deepseek-v4.1-flash` | DeepSeek V4.1 Flash — **self-hosted on Parity's own GPU**, cloud fallback once configured. **Free** when the pod answers ([details](#self-hosted-deepseek-vs-openrouter)) |
| `parity/deepseek-v4.1-flash` | DeepSeek V4.1 Flash — self-hosted **only**, no cloud fallback. **Free** ([details](#self-hosted-deepseek-vs-openrouter)) |
| `openrouter/deepseek-v4.1-flash` | DeepSeek V4.1 Flash — OpenRouter **only**, never our GPU ([details](#self-hosted-deepseek-vs-openrouter)) |
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

- `GET /v1/models` (with your key) lists the curated aliases and every OpenRouter model.
- **Kimi models are the exception:** the `kimi-*` aliases go directly to Moonshot, not OpenRouter,
  so only the ones in the table are available.
- If a model is rejected with a permissions error, your key may be scoped to specific models —
  ask the admin to widen it.
- DeepSeek V4.1 Flash runs on **Parity's own GPU pod** (vLLM), not OpenRouter — and comes in
  three routing flavors; see [Self-hosted DeepSeek vs
  OpenRouter](#self-hosted-deepseek-vs-openrouter) just below. Requests the pod answers
  are **free**: they record $0 spend and don't count against your key's budget.
- Spend tracking on OpenRouter models — aliases and wildcard alike — uses OpenRouter's real
  per-call cost, **streamed calls included** (verified 2026-08-12: recorded spend matches
  OpenRouter's reported cost exactly). Budgets enforce on that recorded spend.

**Using a model regularly?** Ask the admin to add it as a named alias — that gives it a short
name and puts it in the menu above. That's how `deepseek-v4-pro` and `minimax-m3` were added.
It is a one-minute change in the admin UI, not a code change.

#### Self-hosted DeepSeek vs OpenRouter

DeepSeek V4.1 Flash is the one model we serve from **Parity's own GPU pod** (vLLM), so it comes
in three flavors, named `<routing>/<model-id>` — same model, same API, the prefix picks *where*
the request is allowed to run:

| Alias | Where it runs | When to use it |
|---|---|---|
| `auto/deepseek-v4.1-flash` | Parity GPU, with an OpenRouter fallback for when the pod is down or saturated | Default — the one that keeps answering |
| `parity/deepseek-v4.1-flash` | Parity GPU **only** — errors fast if the pod is unavailable | Prompts that must never leave Parity infra; testing the pod itself |
| `openrouter/deepseek-v4.1-flash` | OpenRouter **only** — never touches the pod | Comparing pod vs cloud; deliberately bypassing the pod |

> **Current state:** the fallback on `auto/` is **not configured yet** — it is set up in the
> admin UI as a rollout step. Until it is, `auto/deepseek-v4.1-flash` behaves exactly like
> `parity/`: it errors instead of falling back when the pod is unavailable. Use it when you
> want the fallback behaviour to apply automatically once it is switched on.

The model id is part of the name on purpose: when the pod moves to a new model version, a new
set of three aliases is added for it and this set is retired, so a stale alias fails loudly
rather than silently answering with a different model.

Privacy is the point of the split: requests served by the pod stay entirely on our
infrastructure, while anything served by OpenRouter follows the normal cloud path. Once the
fallback is enabled, `auto/` *can* send your prompt to OpenRouter — if that must never happen,
use `parity/deepseek-v4.1-flash` and be prepared to handle an error while the pod is down.
`parity/` carries the hard guarantee; `auto/`'s is a soft one by design.

Cost follows the same line. Anything the pod answers is **free** — it is logged at $0 and does
not count against your key's budget (the GPU is already paid for), so `parity/deepseek-v4.1-flash`
never touches your quota. Anything OpenRouter answers bills at OpenRouter's real cost as usual,
which will include `auto/`'s fallback once it exists — so `auto/` is free *most* of the time,
not always. Because $0 models skip the budget check, that fallback will bill you even if your
key is already over budget. The pod's capacity, not your budget, is the limit: it serves a
bounded number of requests at once, so under heavy use expect slower answers rather than
budget errors.

### From code (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(base_url="https://ai.labs.paritytech.io", api_key="sk-YOUR-KEY")
resp = client.chat.completions.create(
    model="claude-sonnet",   # or kimi-k2, gpt-5, gemini-pro, ...
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

Any OpenAI-compatible tool works the same way: point its base URL at
`https://ai.labs.paritytech.io/v1`, give it your key, and use one of the model names above.

### From the shell / CI

```bash
curl https://ai.labs.paritytech.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Hello!"}]}'
```

In CI, store your key as a secret named `LLM_KEY` (or similar) — never commit it.

### Budgets & limits

Each key has a monthly `max_budget` and an rpm cap, spanning all models. When you hit your budget,
requests are rejected until the 30-day window resets. Ask the admin to raise it if you need more.
The exception is our own GPU: requests the self-hosted pod answers (`auto/deepseek-v4.1-flash`
when the pod serves it, and `parity/deepseek-v4.1-flash` always) are metered at **$0**, so they
never consume your budget — only the rpm cap applies to them. They also keep working after you
have hit your budget, because LiteLLM skips the budget check for $0 models. One catch, once the
fallback on `auto/deepseek-v4.1-flash` is enabled: it routes to OpenRouter while the pod is
down, and that fallback is billed to your key even when it is already over budget — use
`parity/deepseek-v4.1-flash` if that matters to you.

### Logging & privacy

**Prompts and responses are not stored.** The proxy records only what it needs to meter and
operate the service: which model you called, token counts, spend, duration, and whether the
call succeeded. Message content is never written to disk.

Concretely, per request the proxy keeps the model name, prompt/completion/total token counts,
computed cost, latency, status, and the key that made the call. Those rows are visible to
admins in the proxy UI and are auto-deleted after 90 days.

Two things this does *not* protect you from, and they are worth saying plainly:

- **Upstream providers still see your prompts.** Moonshot and OpenRouter receive the full
  request and apply their own retention policies. The one exception is the self-hosted pod:
  `parity/deepseek-v4.1-flash` never leaves Parity infrastructure (see
  [above](#self-hosted-deepseek-vs-openrouter)).
- **Don't paste secrets into prompts.** Good practice with any LLM provider, ours included.

---

## For operators

### Architecture

nginx terminates TLS on the host and proxies to a two-container compose stack. Nothing in the
stack is reachable from the internet; LiteLLM is published on loopback only.

```
internet ──80/443──> nginx (host, certbot) ──> 127.0.0.1:4000 ──> litellm ──> postgres
                                                                    │        (keys / budgets /
                                                                    │         spend / models)
                                                                    └──> 172.17.0.1:18000
                                                                         ↑ reverse SSH tunnel
                                                                         └── vLLM GPU pod
```

- **nginx** — a host service, not a container. Terminates TLS with a Let's Encrypt certificate
  obtained and renewed by certbot, and proxies everything to LiteLLM. Configured for streaming:
  response buffering off and a 15-minute read timeout, because LLM responses are server-sent
  events that can run for minutes.
- **litellm** — the proxy itself, on a **pinned image tag** (never `latest` — LiteLLM ships
  breaking changes). Published on `127.0.0.1:4000` so only nginx can reach it.
- **postgres** — virtual keys, budgets, per-key spend, request metadata, **and the model menu**
  (see [Deploy & operate](#deploy--operate)). Persisted in a named volume, never published.
- **vLLM GPU pod** (not part of the compose stack) — Parity's self-hosted backend for the
  DeepSeek Flash aliases ([paritytech/vllm-parity](https://github.com/paritytech/vllm-parity),
  rented GPU). It has no stable public address, so it dials **into** the box over a restricted
  SSH account and reverse-binds `172.17.0.1:18000` (docker0 gateway — reachable by containers,
  not the internet). `auto/deepseek-v4.1-flash` is the alias that carries an OpenRouter
  fallback for when the pod is down or saturated — configured in the admin UI, and not yet
  switched on; `parity/deepseek-v4.1-flash` never gets one, and fails fast by design.
  Topology, setup, and ops: `RUNBOOK.md`.

### Repository layout

| Path | Purpose |
|---|---|
| `ansible/00-bootstrap.yml` | One-shot, connects as root: creates the admin account. |
| `ansible/01-box.yml` | Packages, Docker, SSH hardening, firewall. |
| `ansible/02-nginx.yml` | nginx, the site config, Let's Encrypt and auto-renewal. |
| `ansible/03-stack.yml` | `/opt/team-llm`, the rendered `.env`, compose up, health gate. |
| `ansible/04-tunnel.yml` | The vLLM pod's restricted SSH account and firewall rule. |
| `ansible/site.yml` | Phases 01–04 in order. |
| `ansible/group_vars/all/vars.yml` | Public hostname, admin user, pod key — all non-secret config. |
| `ansible/group_vars/all/vault.yml` | Encrypted secrets (`ansible-vault`). `.example` alongside lists them. |
| `docker-compose.yml` | The two-container stack (litellm + postgres). |
| `config.yaml` | The LiteLLM settings that cannot live in the admin UI. Deliberately small. |
| `scripts/reload-costmap.sh` | Nightly price-map refresh, run by a systemd timer. |
| `.github/workflows/validate.yml` | CI: YAML parses, playbooks lint, shellcheck, SPDX, no secrets. |
| `RUNBOOK.md` | Rebuild from zero, the model menu, key lifecycle, pod ops. |

### Deploy & operate

`RUNBOOK.md` is the authoritative, copy-pasteable guide. In short:

1. **The machine is Ansible's.** `ansible-playbook site.yml` takes a bootstrapped Ubuntu host to
   a serving proxy, and is safe to re-run — a second run should report no changes.
2. **Merging a PR deploys nothing.** There is no CI deploy path and no deploy credentials in
   this repo. A merged change reaches the box when an operator runs the relevant playbook.
3. **The model menu lives in the admin UI**, stored in Postgres (`store_model_in_db: true`), not
   in `config.yaml`. Adding a model is a UI action. `RUNBOOK.md` § "Model menu" is the written
   record of what the UI should contain, and the thing to replay if the database is ever lost.
4. **Secrets live in `ansible/group_vars/all/vault.yml`**, encrypted with `ansible-vault`. The
   host's `.env` is rendered from it; editing `.env` on the box is pointless, because the next
   playbook run overwrites it.

### Admin tasks

- **Admin UI:** `https://ai.labs.paritytech.io/ui` (log in with `UI_USERNAME`/`UI_PASSWORD` from
  the vault; the master key also works).
- **Add or change a model:** Models → Add Model in the UI. Enter the provider key as
  `os.environ/OPENROUTER_API_KEY` (or the Moonshot/vLLM equivalent) rather than pasting the
  secret, so credentials stay in `.env` and never land in a database row.
- **Mint a key:** `POST /key/generate` with `models`, `max_budget`, `budget_duration`, `rpm_limit`,
  `user_id`. Omit `models` (or pass `["all-proxy-models"]`) to allow every model above.
- **Revoke a key:** `POST /key/delete`.
- **Usage:** `GET /key/info?key=...` or the UI.
- **Request logs:** the UI's **Logs** page shows per-request metadata for the last ~90 days.
  There are no prompt or response bodies to show — see
  [Logging & privacy](#logging--privacy).

See `RUNBOOK.md` for the full mint → use → track → revoke walkthrough.

### How pricing stays accurate

- **OpenRouter** returns the real per-call cost and LiteLLM records it directly — **streaming
  included** since the v1.95.0 image (upstream fix PR #32255 for
  [BerriAI/litellm#16021](https://github.com/BerriAI/litellm/issues/16021)). Verified on this
  deployment 2026-08-12, after which the temporary list-price pins came off. OpenRouter entries
  must stay **pin-free**: a pin overrides the real per-call cost.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map, fetched
  from upstream at startup and refreshed daily by `scripts/reload-costmap.sh`. A model too new
  for the map needs a temporary price pin on its UI entry — including
  `cache_read_input_token_cost`, or cached tokens get metered at the full input price.
- **Self-hosted pod (the `auto/` and `parity/` entries)** returns no cost either and is pinned
  to an explicit **$0** — pod tokens are free to teammates and don't touch key budgets. The pin
  must be a literal `0` rather than absent: to LiteLLM an absent price means "look up the price
  map", which has no entry for the pod's served model, and a request whose cost can't be
  computed is dropped from the spend logs entirely. A side effect of $0 pricing is that LiteLLM
  skips the budget check for these aliases, so over-budget keys can still use them. A fallback
  on `auto/deepseek-v4.1-flash` would be unaffected by the $0 pin — cost is computed from the
  deployment that actually answered, so fallback calls bill OpenRouter's real cost even for a
  key that is already over budget.

---

## Security model

- **No plaintext secrets in this repo.** They live in `ansible/group_vars/all/vault.yml`,
  encrypted with `ansible-vault`; the vault password is in the team password manager. CI
  rejects a vault file that isn't encrypted. The host's `.env` is rendered from it at 0600.
- **Upstream keys never leave the server.** Teammates only ever hold their own scoped virtual
  keys. In the admin UI, provider keys are entered as `os.environ/…` references, so the
  credentials are not in the database either.
- **No deploy credentials anywhere.** There is no CI key with access to the box; deployment is
  an operator running a playbook over their own SSH access.
- **SSH:** key authentication only. Root login and password authentication are disabled by
  `01-box.yml`, which can only run as the admin account — so the account that replaces root is
  proven working before root is taken away.
- **Network:** the internet reaches exactly ports 22, 80 and 443, all host services gated by
  `ufw`. LiteLLM is published on `127.0.0.1` only and Postgres is not published at all, so
  neither is reachable from outside regardless of the firewall. The vLLM tunnel port (18000)
  binds to the docker0 gateway address only — an internal ufw rule lets containers reach it;
  nothing external can.
- **The vLLM pod's SSH access is caged.** The pod logs in as `vllm-tunnel`: no shell
  (`nologin`), `restrict,port-forwarding,permitlisten=…` in `authorized_keys`, and an sshd
  `Match` block allowing exactly one reverse bind (`172.17.0.1:18000`) — no local forwards, no
  pty, no agent/X11. Kill switch and details: `RUNBOOK.md`.
- **TLS** via nginx + Let's Encrypt, renewed automatically by `certbot.timer` with a deploy
  hook that reloads nginx.
- **`LITELLM_SALT_KEY` must not be rotated on a live deployment** — it encrypts what the admin
  UI writes to Postgres, so rotating it destroys the model menu along with any stored
  credentials.
- **Request logs contain no prompt or response text**, so the Postgres volume is sensitive as
  key and budget material rather than as conversation data.

---

## License

Licensed under the [Apache License, Version 2.0](./LICENSE).

`SPDX-License-Identifier: Apache-2.0`
