# Team LLM Proxy — Design Spec

A self-hosted **LiteLLM proxy** giving 5–20 Parity teammates rate-limited, budgeted,
per-user access to a shared **Kimi (Moonshot AI)** API subscription, fronted by HTTPS.

Status: **shipped & live** at `https://llm.substrate.dev` (Caddy + LiteLLM + Postgres on the
baremetal box). Since launch it has grown beyond this spec: it fronts **OpenRouter** models
alongside Kimi, logs full request/response bodies as a training corpus (see
`docs/specs/2026-07-22-request-logging-design.md`), auto-deploys merged PRs via GitHub Actions
(`RUNBOOK.md` § H), and serves `deepseek-flash` from **Parity's own vLLM GPU pod** through a
reverse SSH tunnel with automatic OpenRouter fallback (`RUNBOOK.md` § I). This document captures
the original design; `README.md` and `RUNBOOK.md` are the current, authoritative references.

---

## 1. Goals & requirements

- Per-user **virtual API keys** (issue / revoke independently).
- Per-user **budgets** and **usage tracking** (spend, request counts, limits).
- **Admin powers** for the operator: add/remove teammates, set/adjust budgets, see usage.
- **Secure**: the upstream Kimi key never leaves the server; teammates only hold their own
  scoped virtual keys; all traffic over TLS.
- Consumers include **teammates' own machines AND CI / shared servers** → a **public HTTPS
  endpoint** (not a private VPN), gated by virtual keys.

Out of scope for v1 (easy to add later): Redis (exact cross-worker rate limiting), SSO admin
login, multi-provider routing/fallbacks.

---

## 2. Host

Dedicated baremetal box (Online.net / Scaleway dedibox), chosen over the shared preview-net
server because it is idle, isolated, and has no chain-redeploy blast radius.

- **OS:** Ubuntu 24.04.4 LTS
- **CPU:** 24 cores (AMD EPYC 7272) · **RAM:** 125 GB (≈121 GB free) · **Disk:** 933 GB (≈539 GB free)
- **Public IPv4:** `<BOX_IPV4>` (bound to the public NIC)
- **Public IPv6:** `<BOX_IPV6>`
- **State at design time:** essentially empty — only sshd (22), systemd-resolve (53, localhost),
  and a Warp remote-server daemon (127.0.0.1:9277). Nothing on 80/443. `ufw` inactive. Docker NOT installed.

Resource footprint of this stack (~1 GB RAM, a few GB disk) is negligible here.

---

## 3. Topology

One `docker compose` stack in `/opt/team-llm/`. Three containers on a private Docker network:

```
internet ──443/80──> caddy ──> litellm:4000 ──> postgres:5432
                     (TLS)      (proxy)          (keys / budgets / usage / logs)
```

- **caddy** — reverse proxy + automatic Let's Encrypt TLS. The ONLY container publishing host
  ports (80, 443). Migrating the hostname later = one-line Caddyfile edit + reload.
- **litellm** — the proxy. **Pinned image tag** (never `latest`/`main-latest` — LiteLLM ships
  breaking changes in releases). Listens on 4000 on the internal network only.
- **postgres** — virtual keys, budgets, per-key spend, request logs. Named volume for persistence.
  Not published to the host interface.

---

## 4. Security model

- **Firewall:** enable `ufw` → allow `22`, `80`, `443` only. LiteLLM (4000) and Postgres (5432)
  stay on the internal Docker network, never bound to the public interface.
- **TLS:** Caddy auto-provisions a real Let's Encrypt cert.
  - **v1 hostname (works today, zero cost):** `llm.<ip-with-dashes>.sslip.io`
    (`sslip.io` resolves `<ip-with-dashes>.sslip.io` → that IP; ACME HTTP-01 over port 80).
  - **Later (done):** swapped to the assigned `*.substrate.dev` subdomain — a one-line Caddyfile
    change + Caddy reload. Virtual keys were unaffected; only the base URL teammates use changed,
    so the cutover was communicated.
- **Secrets** in `/opt/team-llm/.env` (chmod 600, NEVER committed):
  - `LITELLM_MASTER_KEY` — admin key (`sk-...`). Admin-only; mints/revokes virtual keys.
  - `LITELLM_SALT_KEY` — encrypts provider keys stored in the DB. **Do not rotate after launch**
    (invalidates stored encrypted keys).
  - `DATABASE_URL` / Postgres password.
  - `MOONSHOT_API_KEY` — the upstream Kimi key. Never exposed to teammates.
- **Access gate:** every request requires a scoped virtual key. No key → no access.

---

## 5. Admin & per-teammate control (LiteLLM native)

- **Admin UI** at `https://<host>/ui`, login with the master key.
- **Add a teammate** → mint a virtual key with: `max_budget` (e.g. $20), `budget_duration`
  (e.g. `30d`, auto-resets), `rpm`/`tpm` rate limits, allowed-models list, `user_id`/team tag.
  Via UI or scripted `POST /key/generate`.
- **Remove a teammate** → revoke/delete the key (UI or `POST /key/delete`). Instant.
- **Usage tracking** → per-key and per-user spend, request counts, logs in the UI; optional alerts.
- **Teams** (optional) → shared budget pools / grouping.

---

## 6. Kimi / Moonshot wiring

LiteLLM has a native `moonshot/` provider (Kimi = Moonshot AI). Configured in `config.yaml`
`model_list`, reading `MOONSHOT_API_KEY` from env.

**Needs confirmation at build time** (varies by subscription region): the **base URL** and an
exact **model name** from the operator's Kimi dashboard — e.g. `https://api.moonshot.ai/v1`
(international) with a model like `kimi-k2-...` / `moonshot-v1-128k`. Set
`MOONSHOT_API_BASE` if it differs from LiteLLM's default.

---

## 7. Operations

- **Repo layout** (this folder, to become the deployment repo):
  - `docker-compose.yml`, `Caddyfile`, `config.yaml`, `.env.example`, `README.md`.
  - The real `.env` lives only on the box, untracked.
- **Updates:** bump the pinned LiteLLM tag → `docker compose pull && docker compose up -d`.
  `restart: unless-stopped` survives reboots.
- **Backups:** nightly `pg_dump` cron to local disk (the key/budget/usage state is the only
  irreplaceable data). Optional offsite copy.
- **Health:** LiteLLM `/health`; Caddy access logs.

---

## 8. Build order (for the implementation plan)

1. Install Docker Engine + compose plugin (official convenience script) on the box.
2. Enable `ufw` (22/80/443).
3. Scaffold `/opt/team-llm/` repo: `docker-compose.yml` (caddy + litellm + postgres),
   `Caddyfile` (sslip.io host), `config.yaml` (Moonshot model), `.env` (secrets), `.env.example`.
4. Bring up the stack; verify TLS cert issuance against the sslip.io hostname.
5. Confirm Kimi base URL/model; smoke-test a completion through the proxy with the master key.
6. Mint a test virtual key with a small budget + rpm cap; verify gating, spend tracking, revoke.
7. Add nightly `pg_dump` backup cron.
8. Write teammate onboarding README (base URL, how to use their key with common tools).
9. (Parallel) File the DNS request with SRE; once DNS is live, swap Caddy hostname to the
   substrate.dev subdomain and announce the new base URL.

---

## 9. Open items (all resolved at launch)

- ~~Confirm Kimi/Moonshot **base URL + model name** from the operator's dashboard.~~ → `api.moonshot.ai/v1`.
- ~~Decide where the deployment repo is hosted.~~ → `paritytech/lite-llm-proxy`.
- ~~Confirm the desired `substrate.dev` subdomain label with SRE.~~ → `llm.substrate.dev`.
