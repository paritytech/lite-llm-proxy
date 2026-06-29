# Team LLM Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a public HTTPS LiteLLM proxy on the dedicated baremetal box that gives 5–20 Parity teammates per-user virtual keys, budgets, and usage tracking against the shared Kimi (Moonshot AI) subscription.

**Architecture:** One `docker compose` stack in `/opt/team-llm/` with three containers on a private network: **Caddy** (auto Let's Encrypt TLS, the only container publishing host ports 80/443) → **LiteLLM** (proxy on internal port 4000) → **Postgres** (keys/budgets/usage). The deployment repo is authored locally and rsynced to the box; the real `.env` lives only on the box. Hostname starts on free `llm.195-154-218-5.sslip.io` and swaps to a `*.substrate.dev` subdomain (DevOps ticket #5421, already filed) via a one-line Caddyfile edit when DNS is live.

**Tech Stack:** Docker Compose, Caddy 2, LiteLLM (`litellm-database` image, semver-pinned), Postgres 16, Moonshot/Kimi via LiteLLM's native `moonshot/` provider.

## Global Constraints

These apply to **every** task. Values are copied verbatim from `SPEC.md`.

- **Host (the box):** Ubuntu 24.04, IPv4 `195.154.218.5`, IPv6 `2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe`. NOT the shared preview-net server.
- **Firewall:** `ufw` allows **only** `22`, `80`, `443`. LiteLLM (4000) and Postgres (5432) never bind the public interface — internal Docker network only.
- **Pinned image tags only** — never `latest`/`main-latest`/`main-stable`. LiteLLM ships breaking changes; `main-stable` stops publishing 2026-06-30.
- **`LITELLM_SALT_KEY` is set ONCE and never rotated after launch** — rotating it invalidates every provider key encrypted in the DB.
- **Secrets live only in `/opt/team-llm/.env` on the box (chmod 600), NEVER committed.** The repo tracks only `.env.example`.
- **The upstream `MOONSHOT_API_KEY` never leaves the server.** Teammates only ever hold their own scoped virtual keys.
- **v1 hostname:** `llm.195-154-218-5.sslip.io` (sslip.io resolves the dashed-IP host → the IP; enables ACME HTTP-01 today with zero DNS work).
- **Out of scope for v1:** Redis, SSO admin login, multi-provider routing.

## Conventions used in this plan

- **Local repo root:** `/Users/utkarsh/Desktop/Projects/team-llm-proxy` (this folder; becomes the deployment repo).
- **Box deploy dir:** `/opt/team-llm/`.
- **"On the box" commands** run over SSH. This plan writes them as `ssh root@195.154.218.5 '<cmd>'`. If you have a configured SSH alias, substitute it. Set once per shell: `BOX=root@195.154.218.5`.
- **Public base URL (v1):** `https://llm.195-154-218-5.sslip.io`.
- Commits happen in the local repo. The box receives files via `rsync` (it is not a git remote in v1).

## Build-time confirmations (do NOT block the build; defaults are provided)

1. **Exact Kimi model name + region.** Plan defaults to `moonshot/kimi-k2.5` on `https://api.moonshot.ai/v1` (international). If the operator's dashboard shows a different model (e.g. `kimi-k2.6`, `moonshot-v1-128k`) or the China platform (`https://api.moonshot.cn/v1`), change the two values in `config.yaml`/`.env` — Task 4 / Task 7 call this out.
2. **Latest LiteLLM stable semver tag.** Plan pins `v1.85.0`; Task 2 Step 1 confirms/bumps it.
3. **Repo hosting (personal vs `paritytech/...`).** Not needed to build; the repo works locally. Decide before onboarding teammates (Task 10).

---

## Task 1: Scaffold the deployment repo (local)

**Files:**
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/.gitignore`
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/.env.example`

**Interfaces:**
- Produces: the repo skeleton and the canonical list of secret env var names (`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `MOONSHOT_API_KEY`, `MOONSHOT_API_BASE`) consumed by Tasks 2, 4, 6.

- [ ] **Step 1: Initialize git (repo is not yet under version control)**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git init
git branch -M main
```

- [ ] **Step 2: Write `.gitignore`** — the real `.env` and local backup artifacts must never be committed.

```gitignore
# Secrets — real values live only on the box
.env

# Local scratch / backups
backups/
*.sql
*.sql.gz

# OS noise
.DS_Store
```

- [ ] **Step 3: Write `.env.example`** — documents every secret. `POSTGRES_PASSWORD` must equal the password embedded in `DATABASE_URL`.

```bash
# ============================================================================
# Team LLM Proxy — secrets template.
# Copy to .env ON THE BOX, fill every REPLACE_* value, chmod 600. NEVER commit .env.
# ============================================================================

# Admin master key. MUST start with "sk-". Logs into /ui and mints/revokes keys.
LITELLM_MASTER_KEY=sk-REPLACE_WITH_LONG_RANDOM

# Encrypts provider keys stored in Postgres. Set ONCE — never rotate after launch.
LITELLM_SALT_KEY=sk-REPLACE_WITH_LONG_RANDOM

# Postgres password. MUST match the password inside DATABASE_URL below.
POSTGRES_PASSWORD=REPLACE_WITH_LONG_RANDOM

# LiteLLM → Postgres over the internal docker network (host "postgres", db "litellm").
DATABASE_URL=postgresql://litellm:REPLACE_WITH_LONG_RANDOM@postgres:5432/litellm

# Upstream Kimi / Moonshot key. NEVER exposed to teammates.
MOONSHOT_API_KEY=sk-REPLACE_WITH_MOONSHOT_KEY

# International platform. Use https://api.moonshot.cn/v1 for the China platform.
MOONSHOT_API_BASE=https://api.moonshot.ai/v1
```

- [ ] **Step 4: Verify the working tree ignores `.env`**

Run:
```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
printf 'LITELLM_MASTER_KEY=sk-test\n' > .env
git status --porcelain
rm .env
```
Expected: output lists `.gitignore` and `.env.example` as untracked (`??`) but **does NOT** list `.env`.

- [ ] **Step 5: Commit**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git add .gitignore .env.example
git commit -m "chore: scaffold deployment repo with gitignore and env template

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Author `docker-compose.yml`

**Files:**
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/docker-compose.yml`

**Interfaces:**
- Consumes: env var names from Task 1 (`.env` via `env_file`; `POSTGRES_PASSWORD` via interpolation).
- Produces: services `caddy`, `litellm`, `postgres` on network `internal`; named volumes `caddy_data`, `caddy_config`, `postgres_data`. Caddy mounts `./Caddyfile` (Task 3); LiteLLM mounts `./config.yaml` (Task 4).

- [ ] **Step 1: Confirm the LiteLLM pinned tag**

Run:
```bash
curl -sS "https://api.github.com/repos/BerriAI/litellm/releases/latest" | grep -m1 '"tag_name"'
```
Expected: a tag like `"tag_name": "v1.85.0"`. Use that exact value below if it differs from `v1.85.0`. (We pin the `litellm-database` image at this version — it ships pre-generated Prisma binaries so the schema migrates on first boot.)

- [ ] **Step 2: Write `docker-compose.yml`** (replace `v1.85.0` with the tag from Step 1 if different)

```yaml
name: team-llm

services:
  caddy:
    image: caddy:2.8
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - litellm
    networks: [internal]

  litellm:
    image: ghcr.io/berriai/litellm-database:v1.85.0   # PINNED — confirmed in Task 2 Step 1
    restart: unless-stopped
    env_file: [.env]
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    expose:
      - "4000"
    depends_on:
      postgres:
        condition: service_healthy
    networks: [internal]

  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: litellm
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U litellm -d litellm"]
      interval: 5s
      timeout: 5s
      retries: 12
    networks: [internal]

volumes:
  caddy_data:
  caddy_config:
  postgres_data:

networks:
  internal:
    driver: bridge
```

- [ ] **Step 3: Validate the compose file parses** (locally; needs Docker CLI — if absent locally, this is re-run on the box in Task 6)

Run:
```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
printf 'POSTGRES_PASSWORD=x\n' > .env
docker compose config -q && echo "COMPOSE OK"
rm .env
```
Expected: `COMPOSE OK` with no schema errors. (Caddyfile/config.yaml not existing yet is fine — `config` only parses YAML.)

- [ ] **Step 4: Commit**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git add docker-compose.yml
git commit -m "feat: add docker compose stack (caddy + litellm + postgres)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Author the `Caddyfile` (sslip.io host, auto-TLS)

**Files:**
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile`

**Interfaces:**
- Consumes: the `litellm` service name + port 4000 from Task 2 (Caddy proxies to `litellm:4000` over the internal network).
- Produces: a TLS-terminating site on `llm.195-154-218-5.sslip.io`. The site label is the **single line** swapped during the DNS cutover (Task 11).

- [ ] **Step 1: Write `Caddyfile`**

```caddyfile
{
	email utkarsh.bhardwaj@parity.io
}

# v1 hostname — swap this single line to llm.substrate.dev after DNS goes live (Task 11).
llm.195-154-218-5.sslip.io {
	reverse_proxy litellm:4000
	encode zstd gzip
}
```

- [ ] **Step 2: Validate Caddyfile syntax** (re-run on the box in Task 6 if no local Docker)

Run:
```bash
docker run --rm -v /Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2.8 caddy validate --config /etc/caddy/Caddyfile
```
Expected: `Valid configuration` in the output.

- [ ] **Step 3: Commit**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git add Caddyfile
git commit -m "feat: add Caddyfile with sslip.io host and auto Let's Encrypt TLS

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Author `config.yaml` (Moonshot/Kimi wiring)

**Files:**
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/config.yaml`

**Interfaces:**
- Consumes: env vars `MOONSHOT_API_KEY`, `MOONSHOT_API_BASE`, `LITELLM_MASTER_KEY`, `DATABASE_URL` from Task 1's `.env`.
- Produces: a public-facing model alias **`kimi-k2`** that teammates request in their `"model"` field; it maps to upstream `moonshot/kimi-k2.5`. Tasks 7 and 8 use the alias `kimi-k2`.

- [ ] **Step 1: Write `config.yaml`** (default model `moonshot/kimi-k2.5` — see Build-time confirmation #1)

```yaml
model_list:
  # Public alias teammates send as "model": "kimi-k2".
  # Upstream model defaults to kimi-k2.5 — change if the dashboard exposes a different name.
  - model_name: kimi-k2
    litellm_params:
      model: moonshot/kimi-k2.5
      api_key: os.environ/MOONSHOT_API_KEY
      api_base: os.environ/MOONSHOT_API_BASE

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
  # Models are defined here in config, not stored in the DB.
  store_model_in_db: false

litellm_settings:
  # Silently drop unsupported OpenAI params instead of erroring (eases tool compatibility).
  drop_params: true
```

- [ ] **Step 2: Verify it is valid YAML and references the expected env vars**

Run:
```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
python3 -c "import yaml,sys; d=yaml.safe_load(open('config.yaml')); assert d['model_list'][0]['model_name']=='kimi-k2'; assert d['model_list'][0]['litellm_params']['model'].startswith('moonshot/'); print('CONFIG OK:', d['model_list'][0]['litellm_params']['model'])"
```
Expected: `CONFIG OK: moonshot/kimi-k2.5`

- [ ] **Step 3: Commit**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git add config.yaml
git commit -m "feat: add LiteLLM config wiring Moonshot/Kimi via kimi-k2 alias

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Provision the box (Docker + compose plugin + firewall)

**Files:** none committed — this changes box state only. Commands are recorded here as the runbook.

**Interfaces:**
- Produces: a box with Docker Engine + compose plugin installed and `ufw` allowing only 22/80/443. Tasks 6+ assume `docker compose` works on the box.

- [ ] **Step 1: Confirm clean slate and OS**

Run:
```bash
ssh root@195.154.218.5 'lsb_release -d; echo "--- ports ---"; ss -tlnp | grep -E ":(80|443) " || echo "80/443 free"; echo "--- docker ---"; command -v docker || echo "docker not installed"'
```
Expected: Ubuntu 24.04; `80/443 free`; `docker not installed`. If 80/443 are occupied, STOP and resolve before continuing.

- [ ] **Step 2: Install Docker Engine + compose plugin (official convenience script)**

Run:
```bash
ssh root@195.154.218.5 'curl -fsSL https://get.docker.com | sh'
```
Expected: completes with a Docker version banner.

- [ ] **Step 3: Verify Docker works**

Run:
```bash
ssh root@195.154.218.5 'docker run --rm hello-world && docker compose version'
```
Expected: "Hello from Docker!" and a `Docker Compose version v2.x` line.

- [ ] **Step 4: Configure the firewall (allow SSH first, then enable)**

Run:
```bash
ssh root@195.154.218.5 'ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable && ufw status verbose'
```
Expected: `Status: active`; rules listing 22, 80, 443 ALLOW and nothing else.

- [ ] **Step 5: Confirm SSH still works after enabling ufw** (open a NEW connection — do not close the current one until this passes)

Run:
```bash
ssh root@195.154.218.5 'echo SSH_STILL_UP'
```
Expected: `SSH_STILL_UP`.

---

## Task 6: Deploy the stack and verify TLS issuance

**Files:**
- Uses (transfers to box): `docker-compose.yml`, `Caddyfile`, `config.yaml`, `.env.example` from the repo.
- Creates (on box, untracked): `/opt/team-llm/.env`.

**Interfaces:**
- Consumes: the provisioned box (Task 5) and all four config files (Tasks 1–4).
- Produces: a running stack reachable at `https://llm.195-154-218-5.sslip.io` with a real Let's Encrypt cert. Task 7/8 hit this URL.

- [ ] **Step 1: Create the deploy dir and sync repo files (excluding secrets + git)**

Run:
```bash
ssh root@195.154.218.5 'mkdir -p /opt/team-llm'
rsync -av --exclude='.env' --exclude='.git' --exclude='backups' \
  /Users/utkarsh/Desktop/Projects/team-llm-proxy/ root@195.154.218.5:/opt/team-llm/
```
Expected: `docker-compose.yml`, `Caddyfile`, `config.yaml`, `.env.example` listed as transferred.

- [ ] **Step 2: Generate secrets and write the real `.env` on the box**

Run (generates strong secrets, reuses ONE postgres password in both places, then chmods 600):
```bash
ssh root@195.154.218.5 'cd /opt/team-llm && \
  MK="sk-$(openssl rand -hex 32)" && \
  SK="sk-$(openssl rand -hex 32)" && \
  PG="$(openssl rand -hex 24)" && \
  printf "LITELLM_MASTER_KEY=%s\nLITELLM_SALT_KEY=%s\nPOSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://litellm:%s@postgres:5432/litellm\nMOONSHOT_API_KEY=sk-REPLACE_WITH_MOONSHOT_KEY\nMOONSHOT_API_BASE=https://api.moonshot.ai/v1\n" "$MK" "$SK" "$PG" "$PG" > .env && \
  chmod 600 .env && echo "WROTE .env"'
```
Expected: `WROTE .env`.

- [ ] **Step 3: Paste in the real Moonshot key** (interactive — keeps the key out of shell history; replace `PASTE_KEY` then run)

Run:
```bash
ssh root@195.154.218.5 'cd /opt/team-llm && sed -i "s#sk-REPLACE_WITH_MOONSHOT_KEY#PASTE_KEY#" .env && grep -c "REPLACE" .env'
```
Expected: `0` (no REPLACE placeholders remain). Confirm `MOONSHOT_API_BASE` matches the operator's region (Build-time confirmation #1).

- [ ] **Step 4: Bring the stack up**

Run:
```bash
ssh root@195.154.218.5 'cd /opt/team-llm && docker compose up -d'
```
Expected: `caddy`, `litellm`, `postgres` all `Started`/`Healthy`.

- [ ] **Step 5: Watch Caddy issue the certificate**

Run:
```bash
ssh root@195.154.218.5 'cd /opt/team-llm && docker compose logs caddy | grep -iE "certificate obtained|obtained|serving" | tail -5'
```
Expected: a line indicating the certificate for `llm.195-154-218-5.sslip.io` was obtained. (If empty, wait ~30s and re-run — ACME HTTP-01 needs port 80 reachable.)

- [ ] **Step 6: Verify HTTPS + liveness from your laptop (real cert, no `-k`)**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/health/liveliness
```
Expected: `"I'm alive!"` over a valid TLS connection (no cert warning). A `curl` cert error means the cert has not issued yet — re-check Step 5.

---

## Task 7: Smoke-test a completion through the proxy (master key)

**Files:** none — verification only.

**Interfaces:**
- Consumes: running proxy (Task 6) + `kimi-k2` alias (Task 4) + `LITELLM_MASTER_KEY` from the box `.env`.
- Produces: proof the upstream Moonshot wiring works end-to-end. Confirms Build-time confirmation #1.

- [ ] **Step 1: Read the master key from the box into a local shell var**

Run:
```bash
MASTER=$(ssh root@195.154.218.5 'grep ^LITELLM_MASTER_KEY= /opt/team-llm/.env | cut -d= -f2')
echo "${MASTER:0:6}..."   # sanity: prints sk-... prefix only
```
Expected: prints `sk-...` (first 6 chars).

- [ ] **Step 2: Send a chat completion**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: pong"}]}'
```
Expected: a JSON response with `choices[0].message.content` containing the model's reply. If you get `BadRequestError`/`NotFoundError` about the model, the upstream model name is wrong — fix `model: moonshot/<name>` in `/opt/team-llm/config.yaml` (and re-sync from repo), then `docker compose up -d` and retry.

- [ ] **Step 3: Confirm spend was recorded**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/spend/logs \
  -H "Authorization: Bearer $MASTER" | head -c 400; echo
```
Expected: a JSON array containing at least one entry for the request just made.

---

## Task 8: Mint a test virtual key and verify gating, budget, revoke

**Files:** none — verification only. This exercises the full per-teammate lifecycle from SPEC §5.

**Interfaces:**
- Consumes: running proxy + master key (Tasks 6–7).
- Produces: confidence that issue → use → track → revoke works. No persistent artifact (the test key is deleted).

- [ ] **Step 1: Mint a scoped virtual key (small budget + rpm cap, restricted to `kimi-k2`)**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/key/generate \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"smoke-test","models":["kimi-k2"],"max_budget":1,"budget_duration":"30d","rpm_limit":5,"user_id":"smoke@parity.io"}'
```
Expected: JSON containing `"key":"sk-..."`. Capture it:
```bash
TESTKEY=sk-...   # paste the returned key
```

- [ ] **Step 2: The virtual key can call the model**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $TESTKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: ok"}]}'
```
Expected: a normal completion response (HTTP 200).

- [ ] **Step 3: Spend tracking attributes usage to this key**

Run:
```bash
curl -sS "https://llm.195-154-218-5.sslip.io/key/info?key=$TESTKEY" \
  -H "Authorization: Bearer $MASTER"
```
Expected: JSON showing `"spend"` > 0 and `"max_budget": 1` for alias `smoke-test`.

- [ ] **Step 4: Revoke the key**

Run:
```bash
curl -sS https://llm.195-154-218-5.sslip.io/key/delete \
  -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d "{\"keys\":[\"$TESTKEY\"]}"
```
Expected: `{"deleted_keys":["sk-..."]}`.

- [ ] **Step 5: Confirm the revoked key is rejected (gating works)**

Run:
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $TESTKEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"hi"}]}'
```
Expected: `401` (Unauthorized) — the deleted key no longer has access.

---

## Task 9: Nightly Postgres backup cron

**Files:**
- Create: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/scripts/backup.sh`
- Creates (on box): `/opt/team-llm/backups/` and a root crontab entry.

**Interfaces:**
- Consumes: the running `postgres` service (Task 6).
- Produces: a dated `pg_dump` gzip in `/opt/team-llm/backups/` nightly, pruned after 14 days. The key/budget/usage DB is the only irreplaceable state (SPEC §7).

- [ ] **Step 1: Write `scripts/backup.sh`**

```bash
#!/usr/bin/env bash
# Nightly pg_dump of the LiteLLM database to local disk, pruned after 14 days.
set -euo pipefail
cd /opt/team-llm
mkdir -p backups
STAMP=$(date +%F)
docker compose exec -T postgres pg_dump -U litellm litellm | gzip > "backups/litellm-${STAMP}.sql.gz"
find backups -name 'litellm-*.sql.gz' -mtime +14 -delete
```

- [ ] **Step 2: Commit, then sync and install on the box**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
chmod +x scripts/backup.sh
git add scripts/backup.sh
git commit -m "feat: add nightly postgres backup script

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
rsync -av scripts/backup.sh root@195.154.218.5:/opt/team-llm/scripts/
ssh root@195.154.218.5 'chmod +x /opt/team-llm/scripts/backup.sh'
```

- [ ] **Step 3: Install the cron entry (02:30 nightly) and run it once**

Run:
```bash
ssh root@195.154.218.5 '(crontab -l 2>/dev/null | grep -v team-llm/scripts/backup.sh; echo "30 2 * * * /opt/team-llm/scripts/backup.sh >> /opt/team-llm/backups/backup.log 2>&1") | crontab - && /opt/team-llm/scripts/backup.sh && ls -la /opt/team-llm/backups/'
```
Expected: a `litellm-<date>.sql.gz` file (non-zero size) listed in `backups/`.

- [ ] **Step 4: Verify the dump is a real backup (not empty/corrupt)**

Run:
```bash
ssh root@195.154.218.5 'gzip -t /opt/team-llm/backups/litellm-*.sql.gz && zcat /opt/team-llm/backups/litellm-*.sql.gz | grep -c "CREATE TABLE"'
```
Expected: gzip integrity OK (no error) and a `CREATE TABLE` count ≥ 1.

---

## Task 10: Teammate onboarding README

**Files:**
- Create/replace: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/README.md`

**Interfaces:**
- Consumes: the live base URL, the `kimi-k2` model alias, and the key lifecycle verified in Tasks 7–8.
- Produces: copy-paste onboarding for teammates (laptops + CI). No further task depends on it.

- [ ] **Step 1: Write `README.md`**

````markdown
# Team LLM Proxy

Shared, budgeted access to **Kimi (Moonshot AI)** for Parity teammates via a self-hosted
[LiteLLM](https://docs.litellm.ai) proxy. OpenAI-compatible API over HTTPS.

- **Base URL:** `https://llm.195-154-218-5.sslip.io`  *(will move to a `*.substrate.dev` host — see below)*
- **Model:** `kimi-k2`
- **Auth:** your personal virtual key (`sk-...`), issued by the admin. Keep it secret; it carries your budget.

## Use it from code (OpenAI SDK)

```python
from openai import OpenAI
client = OpenAI(base_url="https://llm.195-154-218-5.sslip.io", api_key="sk-YOUR-KEY")
resp = client.chat.completions.create(
    model="kimi-k2",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

## Use it from the shell / CI

```bash
curl https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Hello!"}]}'
```
In CI, store your key as a secret named `LLM_KEY` (or similar) — never commit it.

## Budgets & limits

Each key has a monthly `max_budget` and an rpm cap. When you hit your budget, requests are
rejected until the 30-day window resets. Ask the admin to raise it if you need more.

## Admin (operator only)

- Admin UI: `https://llm.195-154-218-5.sslip.io/ui` (log in with the master key).
- Mint a key: `POST /key/generate` with `models`, `max_budget`, `budget_duration`, `rpm_limit`, `user_id`.
- Revoke a key: `POST /key/delete`.
- Usage: `GET /key/info?key=...` or the UI.

## Hostname migration

The base URL will change from the temporary `sslip.io` host to a `*.substrate.dev` subdomain
(DevOps ticket #5421). **Your key keeps working** — only the base URL changes. The new URL will
be announced before the cutover.
````

- [ ] **Step 2: Commit**

```bash
cd /Users/utkarsh/Desktop/Projects/team-llm-proxy
git add README.md
git commit -m "docs: add teammate onboarding README

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11 (deferred): DNS cutover to `*.substrate.dev`

**Do this only once DevOps ticket #5421 is granted and the subdomain (e.g. `llm.substrate.dev`) is live.** Until then, everything runs on the sslip.io host — no blocker.

**Files:**
- Modify: `/Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile` (one line) and `README.md` (base URL).

- [ ] **Step 1: Confirm DNS resolves to the box**

Run:
```bash
dig +short <assigned-host>.substrate.dev A
dig +short <assigned-host>.substrate.dev AAAA
```
Expected: A → `195.154.218.5`; AAAA → `2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe`.

- [ ] **Step 2: Swap the site label in `Caddyfile`** — change the one line:

```caddyfile
# from:
llm.195-154-218-5.sslip.io {
# to:
<assigned-host>.substrate.dev {
```

- [ ] **Step 3: Sync and reload**

```bash
rsync -av /Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile root@195.154.218.5:/opt/team-llm/Caddyfile
ssh root@195.154.218.5 'cd /opt/team-llm && docker compose up -d && docker compose logs caddy | grep -i "certificate obtained" | tail -2'
```
Expected: Caddy obtains a cert for the new host.

- [ ] **Step 4: Verify and update docs**

```bash
curl -sS https://<assigned-host>.substrate.dev/health/liveliness
```
Expected: `"I'm alive!"`. Then update the base URL in `README.md`, commit, and **announce the new URL to teammates** (their keys are unchanged).

---

## Self-review (spec coverage)

- SPEC §1 goals: virtual keys, budgets, usage, admin, security, public HTTPS → Tasks 4, 6, 7, 8, 10.
- §2 host / §4 firewall → Task 5.
- §3 topology (caddy/litellm/postgres, pinned tag, internal-only ports) → Tasks 2, 3, 6.
- §4 TLS + secrets + access gate → Tasks 3, 6, 8.
- §5 admin/per-teammate control → Tasks 8, 10.
- §6 Moonshot wiring + base URL/model confirmation → Tasks 4, 7.
- §7 ops: repo layout, updates, backups, health → Tasks 1, 6 (health), 9 (backups).
- §8 build order steps 1–9 → Tasks 5, 2–4, 6, 7, 8, 9, 10, 11 respectively.
- §9 open items → tracked as "Build-time confirmations" up top.
