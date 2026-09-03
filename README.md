# Team LLM Proxy

Shared, budgeted access to **Kimi (Moonshot AI)**, **OpenRouter** (Claude, GPT, Gemini,
DeepSeek, Llama, … ~400+ models), and **Parity's own self-hosted GPU serving**
(`deepseek-flash`) for Parity teammates via a self-hosted
[LiteLLM](https://docs.litellm.ai) proxy. One OpenAI-compatible API over HTTPS, gated by
per-user virtual keys with individual budgets and usage tracking.

- **Base URL:** `https://llm.substrate.dev`
- **Auth:** your personal virtual key (`sk-...`), issued by the admin. Keep it secret; it carries your budget.
- **Chat in the browser:** `llm.substrate.dev/chat` — a hosted [chat UI](#chat-ui-open-webui);
  sign up, get approved, chat. No key required to start. (That address is a shortcut that
  redirects to the real home, `https://llm.substrate.dev:8443`.)

> **Connect your coding harness (Claude Code, OpenCode, Codex, Pi, …) in ~5 minutes →
> [`setup/`](setup/README.md)** — a one-command installer plus per-tool guides.

This repository is the **deployment definition** for that service: the Docker Compose stack,
reverse-proxy and proxy config, operational scripts, runbook, and the teammate setup guides in
`setup/`. No application source code and **no secrets** live here — the real `.env` exists only
on the host.

---

## Contents

- [For teammates — using the proxy](#for-teammates--using-the-proxy)
  - [Harness setup guides](setup/README.md) (in `setup/`)
  - [Models](#models)
  - [Chat UI (Open WebUI)](#chat-ui-open-webui)
  - [From code (OpenAI SDK)](#from-code-openai-sdk)
  - [From the shell / CI](#from-the-shell--ci)
  - [Budgets & limits](#budgets--limits)
  - [Logging & privacy](#logging--privacy)
- [For operators](#for-operators)
  - [Architecture](#architecture)
  - [Repository layout](#repository-layout)
  - [Deploy & operate](#deploy--operate)
  - [Admin tasks](#admin-tasks)
  - [Request logging & training corpus](#request-logging--training-corpus)
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
| `deepseek-flash` | DeepSeek V4 Flash — **self-hosted on Parity's own GPU** (testing), cloud fallback |
| `deepseek-flash-parity` | DeepSeek V4 Flash — self-hosted **only**, no cloud fallback (testing; [details](#deepseek-flash-self-hosted-vs-openrouter)) |
| `deepseek-flash-parity-v4-0731` | Same as `deepseek-flash-parity`, with the served model version pinned in the name ([details](#deepseek-flash-self-hosted-vs-openrouter)) |
| `deepseek-flash-openrouter` | DeepSeek V4 Flash — OpenRouter **only**, never our GPU ([details](#deepseek-flash-self-hosted-vs-openrouter)) |
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
- `deepseek-flash` runs on **Parity's own GPU pod** (vLLM), not OpenRouter — and comes in four
  routing flavors; see [`deepseek-flash`: self-hosted vs
  OpenRouter](#deepseek-flash-self-hosted-vs-openrouter) just below.
- Spend tracking on OpenRouter models — aliases and wildcard alike — uses OpenRouter's real
  per-call cost, **streamed calls included** (verified on our deployment 2026-08-12: recorded
  spend matches OpenRouter's reported cost exactly). Budgets enforce on that recorded spend.

**Using a model regularly?** Ask the admin (or open a PR) to add it as a named alias in
`config.yaml` — that gives it a short name and puts it in the menu above. That's how
`deepseek-v4-pro` and `minimax-m3` were added.

#### `deepseek-flash`: self-hosted vs OpenRouter

DeepSeek V4 Flash is the one model we serve from **Parity's own GPU pod** (vLLM), so it comes in
four flavors. Same model, same API — the alias picks *where* the request is allowed to run (and
whether the model version is pinned in the name):

| Alias | Where it runs | When to use it |
|---|---|---|
| `deepseek-flash` | Parity GPU first; falls back to OpenRouter if the pod is down or saturated | Default — always answers |
| `deepseek-flash-parity` | Parity GPU **only** — errors fast if the pod is unavailable | Prompts that must never leave Parity infra; testing the pod itself |
| `deepseek-flash-parity-v4-0731` | Parity GPU **only** — same contract as `deepseek-flash-parity` | You want the name to state exactly which model version answers |
| `deepseek-flash-openrouter` | OpenRouter **only** — never touches the pod | Comparing pod vs cloud; deliberately bypassing the pod |

The unversioned aliases **float**: when the pod is upgraded to a newer DeepSeek Flash, they
silently start serving it. The versioned alias is the opposite — `deepseek-flash-parity-v4-0731`
is a hard-coded promise that you get exactly DeepSeek V4 Flash 0731, and when the pod moves to a
new model a new `deepseek-flash-parity-<version>` alias is added alongside (the old one is
retired once the old model stops being served, so a stale pin fails loudly rather than silently
answering with a different model).

Privacy is the point of the split: requests served by the pod stay entirely on our
infrastructure, while anything served by OpenRouter follows the normal cloud path. That means
the default alias's fallback *can* send your prompt to OpenRouter — if that must never happen,
use `deepseek-flash-parity` and be prepared to handle an error while the pod is down.

### Chat UI (Open WebUI)

Prefer a browser over an SDK or harness? The proxy has a hosted
[Open WebUI](https://github.com/open-webui/open-webui) chat frontend. Just type
**`llm.substrate.dev/chat`** — it redirects to the UI's real home,
`https://llm.substrate.dev:8443` (same host as the API, alternate port; no separate domain to
remember):

- **Sign up** with your work email. New accounts start as *pending* — ping the admin to be
  approved (one-time).
- Once approved, chat away: the default model menu rides a **shared, budget-capped key** — a
  fair-use pool for casual use. If the pool's monthly budget runs dry, the default models pause
  for everyone until it resets.
- **Want your own budget instead?** Add your personal proxy key: **Settings → Connections →
  + Add Connection**, URL `https://llm.substrate.dev/v1`, key `sk-YOUR-KEY`. Its models join
  your model picker, and spend lands on *your* budget exactly like API usage. This "direct
  connection" goes straight from your browser to the proxy — your key stays in your browser,
  never on the chat server.
- **Logging:** chats reach the models through this same proxy, so [Logging &
  privacy](#logging--privacy) applies in full — prompts and responses are logged to the
  training corpus, whether you use the shared pool or your own key. The per-request
  `"no-log"` flag isn't settable from the chat UI; if you need an always-opt-out key, ask
  the admin. (The chat *server's* admin panel cannot read your conversations — admin chat
  access is disabled; the proxy-side logging above is the one visibility surface.)
- **On a strict network?** Some corporate/guest Wi-Fi blocks outbound ports beyond 80/443 —
  if `:8443` won't load there, it's the network, not an outage. Use a different network or
  the API.

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

### Logging & privacy

**Your full prompts and responses are logged.** The proxy stores every request/response body,
which we use to build a training corpus for internal AI models. Concretely:

- Recent requests (≤90 days) are browsable by admins in the proxy UI (per-request drill-down).
  These rows are attributed (your email / key alias) so admins can debug and handle
  erasure requests — and they are auto-deleted after 90 days.
- A nightly job exports the day's requests to a compressed archive kept indefinitely on the
  server, as training data. **The archive is de-identified before it's written:** your email,
  key alias, key hash, and IP are never exported (timestamps are reduced to the day),
  prompt/response text is scrubbed — emails, names, phone numbers, and credential-shaped
  strings are replaced with `<PLACEHOLDER>` tokens — and any images, audio, or files in
  requests or responses are dropped from the archive entirely. Conversations keep their shape: the turns
  of one session stay grouped and ordered under a random-looking session code (a salted
  hash — your raw session id is never exported, and nothing links two of your sessions to
  each other or to you).

**Honesty note:** de-identification is pseudonymization, not anonymity. Free text can still
identify you to a colleague ("my PR on the XCM refactor…" narrows it down fast in a team this
size). Write prompts accordingly, or use the opt-out below.

**Don't paste secrets into prompts.** The scrubber catches common key formats as a backstop,
but it is a backstop — secrets would still sit in the 90-day hot store, and no detector is
perfect. (This is a good rule with any LLM provider, ours included.)

**Opting out per request:** send `"no-log": true` in the request body and that request's message
content is excluded from logging. With the OpenAI SDK:

```python
resp = client.chat.completions.create(
    model="claude-sonnet",
    messages=[{"role": "user", "content": "..."}],
    extra_body={"no-log": True},
)
```

Spend/budget accounting still happens for opted-out requests — only the message content is
excluded. If you want an always-opt-out key instead of per-request flags, ask the admin.

**Grouping your session (optional, helps the corpus):** requests carry no session identity by
default — each one becomes a standalone entry. If you pass a `litellm_session_id` (any opaque
string, same value for every turn of one conversation), the archive keeps those turns grouped
and ordered, which makes much better training data:

```python
resp = client.chat.completions.create(
    model="claude-sonnet",
    messages=[...],
    extra_body={"litellm_session_id": my_conversation_uuid},
)
```

Use a random UUID per conversation — don't put your name or ticket ids in it (the raw value
stays in the 90-day admin store; only a salted hash of it reaches the archive).

---

## For operators

### Architecture

One `docker compose` stack. Four always-on containers on a private Docker network; only Caddy
publishes host ports. (Two more — the Presidio PII-scrub pair — sit behind the `scrub` compose
profile, started by the nightly export for a few minutes and bound to localhost only.)

```
internet ──443/80──> caddy ──┬──> litellm:4000 ──> postgres:5432
         └──8443──── (TLS)   │     (proxy)          (keys / budgets / usage / logs)
                             │        │
                             │        └──> 172.17.0.1:18000 ←─(reverse SSH tunnel)── vLLM GPU pod
                             │             (host, container-reachable only)          (deepseek-flash, -parity)
                             └──> openwebui:8080 ──> litellm:4000
                                   (chat UI, :8443)   (shared budget-capped key)
```

- **caddy** — reverse proxy + automatic Let's Encrypt TLS. The only container exposing ports (80, 443, 8443).
- **litellm** — the proxy itself, on a **pinned image tag** (never `latest` — LiteLLM ships breaking
  changes). Listens on 4000 on the internal network only.
- **openwebui** — the hosted chat frontend at `https://llm.substrate.dev:8443` (pinned image tag,
  like litellm). Same hostname as the API on an alternate TLS port — deliberate: creating a new
  DNS label needs an external grant, a port doesn't (and Open WebUI can't be served under a
  path — see the `Caddyfile` comment). Talks to LiteLLM over the internal network with a shared
  budget-capped virtual key;
  users' personal "direct connections" go browser → `llm.substrate.dev` and never touch this
  container. Accounts and chat history live in its own named volume (`openwebui_data`) — **not**
  covered by the nightly Postgres dump (see `RUNBOOK.md` § J).
- **postgres** — virtual keys, budgets, per-key spend, request logs. Persisted in a named volume,
  never published to the host.
- **vLLM GPU pod** (not part of the compose stack) — Parity's self-hosted backend for
  `deepseek-flash` ([paritytech/vllm-parity](https://github.com/paritytech/vllm-parity), rented
  GPU). It has no stable public address, so it dials **into** the box over a restricted SSH
  account and reverse-binds `172.17.0.1:18000` (docker0 gateway — reachable by containers, not
  the internet). When the pod is down or saturated, LiteLLM falls back to OpenRouter
  automatically for `deepseek-flash` — but not for the `deepseek-flash-parity*` aliases, which
  fail fast by design (see [the models section](#deepseek-flash-self-hosted-vs-openrouter)).
  Topology, setup,
  and ops: `RUNBOOK.md` § I.

### Repository layout

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The four-container stack (caddy + litellm + openwebui + postgres). |
| `Caddyfile` | TLS + reverse-proxy config. Site labels = the public URLs (API + chat UI). |
| `config.yaml` | LiteLLM model list (Kimi + OpenRouter aliases + wildcard) and settings. |
| `.env.example` | Template for the real `.env` (secrets) that lives only on the host. |
| `scripts/backup.sh` | Nightly `pg_dump` of the LiteLLM database, verified and pruned. |
| `scripts/reload-costmap.sh` | Refresh LiteLLM's price map from upstream (no restart). |
| `scripts/export-logs.sh` | Nightly export of request logs (incl. prompts) to gzipped JSONL — the training corpus. De-identifies on the way out: identity-column whitelist + PII scrub. |
| `scripts/scrub-logs.py` | JSONL filter used by the export: replaces PII/credentials in prompt/response text with placeholders via the local Presidio containers. Fail-closed. |
| `scripts/deploy.sh` | Change-aware deploy step CI runs on the box — restarts only what the merge touched. |
| `scripts/deploy-gatekeeper.sh` | SSH forced command pinning the CI deploy key to rsync + deploy only. |
| `.github/workflows/validate.yml` | CI: YAML parses, shellcheck, SPDX headers, no secrets committed. |
| `.github/workflows/deploy.yml` | Auto-deploys every merge to `main` to the box (manual trigger available). |
| `setup/` | Teammate-facing harness setup: one-command installer (`setup.sh`) + per-tool guides (`harnesses/`). |
| `RUNBOOK.md` | Step-by-step provisioning, deploy, key lifecycle, and DNS cutover. |
| `SPEC.md` | The original design and rationale (background reference). |

### Deploy & operate

`RUNBOOK.md` is the authoritative, copy-pasteable guide. In short:

1. The host runs the stack from `/opt/team-llm`; the repo is rsync'd there (excluding `.env`).
2. Secrets are generated and written to `/opt/team-llm/.env` (chmod 600) — **never committed**.
3. `docker compose up -d` brings up Caddy (which auto-issues the Let's Encrypt certs), LiteLLM, Open WebUI, and Postgres.
4. Nightly crons run the backup and price-map refresh.

**Merging a PR to `main` deploys it.** GitHub Actions (`deploy.yml`) rsyncs the repo to the box
and restarts only what the change touched — a `config.yaml` merge recreates LiteLLM, a
`Caddyfile` merge reloads Caddy gracefully, a docs-only merge restarts nothing. Re-deploys can
be triggered manually from the Actions tab. Setup and security model: `RUNBOOK.md` § H.

To change models or settings: edit `config.yaml`, open a PR, merge — CI does the rest.

### Admin tasks

- **Admin UI:** `https://llm.substrate.dev/ui` (log in with `UI_USERNAME`/`UI_PASSWORD` from the
  host `.env`; the master key also works).
- **Mint a key:** `POST /key/generate` with `models`, `max_budget`, `budget_duration`, `rpm_limit`,
  `user_id`. Omit `models` (or pass `["all-proxy-models"]`) to allow every model above.
- **Revoke a key:** `POST /key/delete`.
- **Usage:** `GET /key/info?key=...` or the UI.
- **Request logs:** the UI's **Logs** page shows per-request drill-down, including full
  prompt/response bodies (last ~90 days).
- **Chat UI users:** approve pending signups in Open WebUI's own admin panel
  (`https://llm.substrate.dev:8443` → Admin Panel → Users; the first-ever account is the admin).
  Shared-key minting, budget, and per-user attribution checks: `RUNBOOK.md` § J.

See `RUNBOOK.md` § D for the full mint → use → track → revoke walkthrough.

### Request logging & training corpus

Full request/response bodies are captured to build a training corpus (teammate-facing details
and the opt-out are in [Logging & privacy](#logging--privacy) above). The data flow:

```
request ──> litellm ──> Postgres LiteLLM_SpendLogs   (hot store: ATTRIBUTED rows, auto-pruned
                              │                       after 90d, browsable in /ui Logs)
                              └─ nightly export-logs.sh
                                   ├─ column whitelist  (drops email/key/team/IP ids;
                                   │                     timestamps coarsened to the day;
                                   │                     session id → salted hash + turn no.)
                                   ├─ scrub-logs.py     (PII/credentials in prompt+response text
                                   │                     → <PLACEHOLDER>, via local Presidio)
                                   └──> $LOG_EXPORT_DIR/spendlogs-<date>.jsonl.gz
                                        (durable corpus: DE-IDENTIFIED, kept forever by default)
```

- **Capture** is `store_prompts_in_spend_logs: true` in `config.yaml`.
- **Postgres retention** is `maximum_spend_logs_retention_period: "90d"` in `config.yaml` —
  LiteLLM auto-deletes older rows daily, bounding DB growth. Pruning loses nothing: the export
  runs nightly, long before rows age out. The 90-day attributed hot store is also the safety
  window: if the scrubber ever misbehaves, fix it and re-run `export-logs.sh <date>` for any
  day still inside the window.
- **De-identification happens at export time**, the last point before data becomes permanent.
  The export SELECT is an explicit column *whitelist* (a new LiteLLM column stays out of the
  corpus until consciously added); text scrubbing runs against the Presidio pair in the `scrub`
  compose profile, on-box only, and **fails closed** — a scrub error aborts the export rather
  than writing raw text. Each run logs a `scrub summary:` line with per-entity mask counts to
  the cron log; a sudden spike means detector false positives — investigate while re-export is
  still possible. This yields a *pseudonymized* corpus, not an anonymous one (free text can
  still identify authors in a small team) — README's teammate section says so explicitly.
- **The corpus** is one gzipped JSONL file per UTC day, written by `scripts/export-logs.sh`
  (cron). Location `LOG_EXPORT_DIR` and optional pruning `LOG_EXPORT_RETENTION_DAYS` are set in
  the host `.env` — retarget to a mounted datastore by changing one line. Corpus retention is
  indefinite by design (collecting until a training pipeline exists), with an annual review
  date — see RUNBOOK § G.
- **Durability:** the corpus is a plain host directory (outside Docker) and Postgres lives in the
  `postgres_data` named volume — both survive reboots, `docker compose up -d` redeploys, and
  image bumps. Never run `docker compose down -v` (`-v` deletes the volumes).
- **Sizing** (20 engineers): moderate use ≈ 360 MB/day raw → ~70 MB/day gzipped ≈ 26 GB/year of
  corpus + ~32 GB of Postgres at 90d retention. Heavy agentic use ≈ 3 GB/day raw → ~600 MB/day
  gzipped ≈ 220 GB/year; at that rate drop the Postgres retention to 30d and plan corpus off-box
  archival after ~a year. The export cron logs `df -h` nightly so growth is visible in
  `logs/export.log`.

### How pricing stays accurate

- **OpenRouter** returns the real per-call cost; LiteLLM records it directly — **streaming
  included** since the v1.95.0 image (upstream fix PR #32255 for
  [BerriAI/litellm#16021](https://github.com/BerriAI/litellm/issues/16021); our previous
  v1.90.0 pin dropped inline cost on streamed calls). Verified on this deployment 2026-08-12
  (`RUNBOOK.md` § "Pricing model"), after which the temporary list-price pins on curated
  aliases came off — the real cost wins. OpenRouter aliases must stay **pin-free**: a pin
  overrides the real per-call cost.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map, which is
  fetched from upstream at startup and refreshed daily by `scripts/reload-costmap.sh`. A model too
  new for the map needs a temporary price pin in `config.yaml` — including
  `cache_read_input_token_cost`, or cached tokens get metered at the full input price.
- **Wildcard caveat (fixed at pinned v1.95.0, verified on-box 2026-08-12):** an `openrouter/*`
  model with no map entry used to meter **$0** on *streaming* requests (a wildcard can't carry a
  pin). Upstream fixed this in v1.94.0 (provider-reported stream cost) and our spot-check
  confirmed it — streamed spend equals OpenRouter's reported cost. The OpenRouter key's own
  credit limit stays on as defense-in-depth.

---

## Security model

- **No secrets in this repo.** The real `.env` (master key, salt key, Postgres password, upstream
  Moonshot and OpenRouter keys, the chat UI's shared key) lives only on the host, chmod 600, and
  is git-ignored.
- **Upstream keys never leave the server.** Teammates only ever hold their own scoped virtual keys.
- **The chat UI container is least-privilege.** It receives exactly one secret — the shared,
  budget-capped virtual key — never the master key or upstream provider keys (no `env_file`; an
  explicit allowlist of variables). Personal keys added as "direct connections" stay in the
  user's browser and go straight to the proxy.
- **Network:** the internet reaches exactly ports 22 (host sshd, gated by `ufw`) and 80/443/8443
  (published by the Caddy container; 8443 is the chat UI, TLS like 443). For the published
  ports, what governs exposure is compose's `ports:` section — Docker's nat rules act before
  `ufw`'s INPUT chain, so the matching `ufw allow` rules are defense-in-depth, not the gate.
  LiteLLM (4000), Open WebUI (8080), and Postgres (5432) are *not published* and stay
  unreachable on the internal Docker network. The vLLM tunnel port (18000) binds to the docker0
  gateway address only — an internal ufw rule lets containers reach it; nothing external can.
- **The vLLM pod's SSH access is caged.** The pod logs in as `vllm-tunnel`: no shell (`nologin`),
  `restrict,port-forwarding` in `authorized_keys`, and an sshd `Match` block that allows exactly
  one reverse bind (`172.17.0.1:18000`) — no local forwards, no pty, no agent/X11. Kill switch and
  details: `RUNBOOK.md` § I.
- **TLS everywhere** via Caddy + Let's Encrypt.
- **`LITELLM_SALT_KEY` must not be rotated after launch** — it encrypts provider keys stored in the
  DB, and rotating it invalidates them.
- **Request logs contain teammates' prompts** — treat the Postgres volume and `LOG_EXPORT_DIR`
  as sensitive. Log access = admin access (`/ui` login or shell on the box); the corpus never
  leaves the server unless deliberately copied for training.

---

## License

Licensed under the [Apache License, Version 2.0](./LICENSE).

`SPDX-License-Identifier: Apache-2.0`
