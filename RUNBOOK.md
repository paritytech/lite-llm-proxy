# Box Runbook — Team LLM Proxy

You are already SSH'd into the box (`<box>` — your SSH alias for the server). **Run every command
on the box**, top to bottom, unless a block is marked **[laptop]**. See `SPEC.md` for the design
rationale behind each step.

Notes:
- **[laptop]** steps run in a terminal that is *not* inside the box, using your `<box>` SSH alias.
  `<local-repo>` is your local checkout of this repo; the box dir is `/opt/team-llm`.
- Commands assume a **sudo (non-root) user** on the box. Run them one line at a time (a chained
  paste can mangle `>` / `&&` in some terminals).

---

## A. Provision the box (Docker + firewall)

```bash
lsb_release -ds
ss -tlnp | grep -E ":(80|443) " || echo "80/443 free"
command -v docker || echo "docker not installed"
```
```bash
# Install Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sh
```
```bash
# Verify (daemon needs sudo until the docker-group membership below takes effect)
sudo docker run --rm hello-world
docker compose version
```
```bash
# Add yourself to the docker group so docker AND the nightly crons run without sudo.
# Then log out and back in (newgrp only affects the current shell and is lost on exit).
sudo usermod -aG docker "$USER"
exit            # then: ssh <box>   (reconnect so the group is active)
```
```bash
# After reconnecting, confirm no-sudo docker:
docker ps
```
```bash
# Firewall: allow SSH first, then 80/443, then enable (run one at a time)
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```
```bash
# [laptop] Confirm you are NOT locked out — open a NEW laptop terminal:
ssh <box> 'echo SSH_STILL_UP'
```

---

## B. Deploy the stack

```bash
# 0. Create the deploy dir and make it yours (so the laptop rsync + .env writes need no sudo)
sudo mkdir -p /opt/team-llm
sudo chown "$USER":"$USER" /opt/team-llm
```
```bash
# 1. [laptop] Copy the repo to the box (excludes secrets, git history, and box-side data):
rsync -av --exclude=.env --exclude=.git --exclude=backups --exclude=logs \
  <local-repo>/ <box>:/opt/team-llm/
```
```bash
# 2. Generate strong secrets and write .env (one postgres password, reused in DATABASE_URL).
cd /opt/team-llm
MK="sk-$(openssl rand -hex 32)"
SK="sk-$(openssl rand -hex 32)"
PG="$(openssl rand -hex 24)"
printf 'LITELLM_MASTER_KEY=%s\nLITELLM_SALT_KEY=%s\nPOSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://litellm:%s@postgres:5432/litellm\nMOONSHOT_API_KEY=sk-REPLACE_MOONSHOT\nMOONSHOT_API_BASE=https://api.moonshot.ai/v1\nOPENROUTER_API_KEY=sk-or-REPLACE_OPENROUTER\n' "$MK" "$SK" "$PG" "$PG" > .env
chmod 600 .env
```
```bash
# 3. Paste the REAL upstream keys (hidden). Moonshot first:
printf 'Paste Moonshot key then Enter: '
read -r -s MOON
sed -i "s#sk-REPLACE_MOONSHOT#${MOON}#" .env
unset MOON
```
```bash
#    Then OpenRouter (sk-or-v1-...). Set a credit limit on this key in the OR dashboard.
printf 'Paste OpenRouter key then Enter: '
read -r -s ORK
sed -i "s#sk-or-REPLACE_OPENROUTER#${ORK}#" .env
unset ORK
grep -c REPLACE .env
#    Expect: 0   (no placeholders left).
#    Models live in config.yaml (4 Kimi + curated OpenRouter + wildcard). For the China
#    Kimi platform, change MOONSHOT_API_BASE to https://api.moonshot.cn/v1.
```
```bash
# 4. Bring it up
cd /opt/team-llm
docker compose up -d
docker compose ps
```
```bash
# 5. Watch Caddy obtain the Let's Encrypt cert (re-run after ~30s if empty — needs port 80 reachable)
cd /opt/team-llm
docker compose logs caddy | grep -i certificate | tail -5
```
```bash
# 6. Verify HTTPS + liveness (real cert, no -k flag)
curl -sS https://llm.substrate.dev/health/liveliness
#    Expect: "I'm alive!"
```

---

## C. Smoke-test completions (master key)

```bash
MASTER=$(grep '^LITELLM_MASTER_KEY=' /opt/team-llm/.env | cut -d= -f2)
```
```bash
# Kimi
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: pong"}]}'
```
```bash
# OpenRouter (curated alias + wildcard)
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"Reply with exactly: pong"}]}'
#    Expect: JSON with choices[0].message.content. The OpenRouter response includes a real
#    "cost" field — that is what LiteLLM records on non-streaming calls like this one
#    (streamed calls fall back to the price map / pins — see "Pricing model" below).
```

---

## D. Virtual-key lifecycle (issue → use → track → revoke)

```bash
# 1. Mint a scoped test key
curl -sS https://llm.substrate.dev/key/generate -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"key_alias":"smoke-test","models":["kimi-k2"],"max_budget":1,"budget_duration":"30d","rpm_limit":5,"user_id":"smoke@parity.io"}'
```
```bash
TESTKEY=sk-...    # paste returned key
```
```bash
# 2. It works
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $TESTKEY" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: ok"}]}'
```
```bash
# 3. Spend tracked  (look for "spend" > 0)
curl -sS "https://llm.substrate.dev/key/info?key=$TESTKEY" -H "Authorization: Bearer $MASTER"
```
```bash
# 4. Revoke
curl -sS https://llm.substrate.dev/key/delete -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d "{\"keys\":[\"$TESTKEY\"]}"
```
```bash
# 5. Revoked key is rejected
curl -sS -o /dev/null -w "%{http_code}\n" https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $TESTKEY" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"hi"}]}'
#    Expect: 401
```

---

## E. Cron jobs (backup + price-map refresh)

```bash
# Prove both scripts work first (they were copied in step B1):
chmod +x /opt/team-llm/scripts/backup.sh /opt/team-llm/scripts/reload-costmap.sh
/opt/team-llm/scripts/backup.sh
ls -la /opt/team-llm/backups/
gzip -t /opt/team-llm/backups/litellm-*.sql.gz
zcat /opt/team-llm/backups/litellm-*.sql.gz | grep -c CREATE
/opt/team-llm/scripts/reload-costmap.sh
#    Expect: a litellm-<date>.sql.gz with CREATE count > 0, and a {"status":"success",...} reload.
```
```bash
# Install BOTH cron lines (append-safe — preserves any existing crontab):
crontab -l 2>/dev/null > /tmp/ct.txt || true
echo '30 2 * * * /opt/team-llm/scripts/backup.sh >> /opt/team-llm/backups/backup.log 2>&1' >> /tmp/ct.txt
echo '30 3 * * * /opt/team-llm/scripts/reload-costmap.sh >> /opt/team-llm/backups/costmap.log 2>&1' >> /tmp/ct.txt
crontab /tmp/ct.txt
crontab -l
rm /tmp/ct.txt
#    backup = nightly pg_dump (02:30); reload-costmap = refresh LiteLLM price map from GitHub
#    (03:30) so Kimi/streaming/day-0 models stay priced without a redeploy.
```

---

## Pricing model (how spend stays accurate, and why the UI can disagree with provider dashboards)

- **OpenRouter** returns the real per-call cost; LiteLLM records that directly. Historically
  that was **non-streaming only**: pins ≤ v1.93 dropped the inline cost on **streaming**
  responses (BerriAI/litellm#16021) and fell back to the price map, so curated aliases missing
  from the map (`claude-opus`, `gpt-5`, `gpt-5-mini`, `gemini-flash`, `llama-4-maverick`,
  `deepseek-v4-pro`, `minimax-m3` as of 2026-07-24) metered **$0 on streamed calls** until they
  were pinned in `config.yaml` at OpenRouter list prices. The upstream fix (PR #32255) landed in
  stable v1.94.0, and `docker-compose.yml` now pins **v1.95.0** — after the next deploy, run the
  streaming spot-check below, and once it passes **remove those alias pins** so the real
  per-call cost wins again.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map. The map is
  fetched from GitHub at startup and refreshed daily by the reload cron. A model too new for the
  map (e.g. `kimi-k3`, `kimi-k2.7-code`) needs an explicit pin in `config.yaml` until the map
  catches up. Pins must include `cache_read_input_token_cost`: Moonshot auto-caches context and
  bills cache hits at ~1/5–1/10 of the input price, so an input/output-only pin overcounts
  heavily on agentic workloads. (The ≥ v1.94.0 fix changes nothing here — Moonshot sends no
  cost to report.)
- **Wildcard caveat — fixed at v1.94.0, verify on deploy:** a model reached via `openrouter/*`
  with no map entry used to meter $0 on *streaming* requests (a wildcard can't carry a pin).
  Our pinned image (v1.95.0) includes the upstream fix. **Spot-check after deploying:** stream
  one wildcard-model request, then confirm nonzero `spend` on its spend-log row. Until that
  check passes, treat the OpenRouter key's own **credit limit as the backstop** (it remains
  sensible defense-in-depth regardless).
- **Comparing dashboards:** expect small residual gaps even when everything above is right —
  the LiteLLM UI buckets days in UTC while provider dashboards may use local time; OpenRouter's
  billed cost includes its BYOK/provider fees which the price map doesn't model; and map-priced
  streamed calls use list prices, not the routed provider's actual price. Large gaps (2×, or
  models showing $0) mean a missing/stale map entry or a missing pin — check
  `SELECT model, SUM(spend) FROM "LiteLLM_SpendLogs" GROUP BY 1` against the provider's own
  per-model breakdown to find which model is drifting.

## To change models / prices later

Edit `config.yaml` locally → PR → merge. CI deploys it (see § H): the merge rsyncs the repo to
the box and force-recreates litellm automatically. Break-glass (GitHub down): edit on the box as
the deploy user (`sudo -iu deploy`) → `cd /opt/team-llm && docker compose up -d --force-recreate litellm`.

---

## F. Later — DNS cutover to *.substrate.dev (after DevOps #5421 is granted)

```bash
# 1. Confirm DNS resolves to the box (run anywhere)
dig +short <assigned-host>.substrate.dev A      # -> <BOX_IPV4>
dig +short <assigned-host>.substrate.dev AAAA   # -> <BOX_IPV6>
```
```bash
# 2. [laptop] Edit Caddyfile in the repo: change the one site-label line
#       llm.substrate.dev  ->  <assigned-host>.substrate.dev
#    then copy it to the box:
rsync -av <local-repo>/Caddyfile <box>:/opt/team-llm/Caddyfile
```
```bash
# 3. Reload (on box)
cd /opt/team-llm
docker compose up -d
docker compose logs caddy | grep -i certificate | tail -2
```
```bash
# 4. Verify, then update README base URL and announce to teammates (keys unchanged)
curl -sS https://<assigned-host>.substrate.dev/health/liveliness
```

---

## G. Request logging (prompts + responses → training corpus)

Captures every request/response body to Postgres (browsable in `/ui` Logs, auto-pruned after
90 days by LiteLLM) and exports each day to gzipped JSONL under `LOG_EXPORT_DIR` (kept forever
by default — the training corpus). The export **de-identifies**: identity columns are
whitelisted out and prompt/response text is PII-scrubbed via the on-box Presidio pair (compose
`scrub` profile). Full design in `README.md` § "Request logging & training corpus".

> **Before enabling:** announce to the team that prompts/responses will be logged for model
> training, and point them at README § "Logging & privacy" (includes the per-request opt-out
> and the honest pseudonymized-not-anonymous caveat).

> **Retention review (yearly):** the corpus is kept indefinitely on purpose (no training
> pipeline exists yet — data accumulates until one does). Each July, re-confirm that stance:
> is the corpus still needed, has a training run consumed it, can old days be pruned via
> `LOG_EXPORT_RETENTION_DAYS`? Next review: **2027-07**.

```bash
# 1. [laptop] Ship the updated config + script to the box (same as B1):
rsync -av --exclude=.env --exclude=.git --exclude=backups --exclude=logs \
  <local-repo>/ <box>:/opt/team-llm/
```
```bash
# 1b. Pre-pull the images the export needs, and confirm python3 exists (scrub-logs.py is
#     stdlib-only; Ubuntu ships python3). The Presidio pair is behind the `scrub` profile,
#     so a plain `docker compose up -d` never starts it — the export script does, for the
#     few minutes it runs (the analyzer holds ~1.5 GB RAM while up).
cd /opt/team-llm
docker compose --profile scrub pull presidio-analyzer presidio-anonymizer
python3 --version
```
```bash
# 2. Add the new .env values (UI login + export config). Password is hidden while pasting:
cd /opt/team-llm
printf 'Choose a UI admin password then Enter: '
read -r -s UIPW
printf 'UI_USERNAME=admin\nUI_PASSWORD=%s\nLOG_EXPORT_DIR=/opt/team-llm/logs\nLOG_EXPORT_RETENTION_DAYS=\nLOG_EXPORT_SESSION_SALT=%s\n' "$UIPW" "$(openssl rand -hex 32)" >> .env
unset UIPW
grep -E '^(UI_USERNAME|LOG_EXPORT)' .env
# The salt drives the corpus session pseudonym — generated once here, NEVER rotate it
# (rotation unlinks sessions across the rotation date; see .env.example).
```
```bash
# 3. Apply (recreates only litellm; Postgres data + keys untouched). This also picks up the
#    pinned-image bump (v1.90.0 → v1.95.0; SpendLogs schema-identical, prisma migrations run
#    automatically at startup):
cd /opt/team-llm
docker compose pull litellm
docker compose up -d --force-recreate litellm
docker compose ps
```
```bash
# 4. Verify capture: send one request, then check the newest log row has the message body.
#    KNOWN QUIRK on the pinned image (v1.95.0, BerriAI/litellm#23636): the prompt lands in
#    proxy_server_request (alongside raw headers), NOT the messages column (stays '{}');
#    response is stored correctly. The export script compensates (see the CASE in
#    scripts/export-logs.sh) — after a future image bump, re-run this and if messages is
#    populated again, remove that workaround.
MASTER=$(grep '^LITELLM_MASTER_KEY=' /opt/team-llm/.env | cut -d= -f2)
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"log-capture-test"}]}' > /dev/null
docker compose exec -T postgres psql -U litellm -d litellm -c "SELECT \"startTime\", model, left(messages::text, 30) AS messages, left(proxy_server_request::text, 60) AS proxy_server_request FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 3;"
#    Expect: newest row contains "log-capture-test" in proxy_server_request (v1.95.0) or
#    in messages (fixed versions). If it's in NEITHER, capture is broken — stop and debug.
```
```bash
# 5. Verify the opt-out actually works on our pinned image (v1.95.0) before announcing it:
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"no-log-test"}],"no-log":true}' > /dev/null
docker compose exec -T postgres psql -U litellm -d litellm -c "SELECT \"startTime\", left(coalesce(messages::text,'<empty>'), 30) AS messages, left(coalesce(proxy_server_request::text,'<empty>'), 60) AS proxy_server_request FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 1;"
#    Expect: NO "no-log-test" anywhere — on v1.95.0 the opt-out request writes no spend-log
#    row at all (verified 2026-08-05), so the newest row is still the step-4 one. If the
#    text DOES appear (messages OR proxy_server_request), the pinned LiteLLM version doesn't
#    honor no-log for spend logs — remove the opt-out promise from README § "Logging &
#    privacy" (or bump the pinned image) BEFORE announcing.
```
```bash
# 6. Verify the export script END TO END (starts the Presidio pair, scrubs, stops it), then
#    install its cron (02:50 — after midnight UTC, before the 03:30 costmap reload; exports
#    *yesterday*, so run it for today's date to see the rows from step 4/5).
#    First run is slow: the analyzer loads its NLP model (~1 min).
chmod +x /opt/team-llm/scripts/export-logs.sh
/opt/team-llm/scripts/export-logs.sh "$(date -u +%F)"
#    Expect on stderr: a "scrub summary: rows=N masked={...}" line (per-entity mask counts —
#    watch this in the cron log; a sudden spike = detector false positives, investigate while
#    re-export inside the 90d window is still possible).
zcat /opt/team-llm/logs/spendlogs-$(date -u +%F).jsonl.gz | head -1
#    De-identification check — expect the two OK lines:
zcat /opt/team-llm/logs/spendlogs-$(date -u +%F).jsonl.gz | head -1 | python3 -c "import json,sys; row=json.load(sys.stdin); bad={'user','api_key','end_user','team_id','organization_id','session_id','requester_ip_address','request_tags','metadata','proxy_server_request','api_base','cache_key','agent_id','startTime','endTime'} & row.keys(); missing={'session','turn'} - row.keys(); print(f'BAD identity columns: {bad}' if bad else f'MISSING session grouping: {missing}' if missing else 'OK: no identity columns; session+turn present')"
zcat /opt/team-llm/logs/spendlogs-$(date -u +%F).jsonl.gz | grep -F '@parity.io' || echo "OK: no emails in text"
docker compose ps   # presidio containers must NOT be listed (the script stops them)
crontab -l 2>/dev/null > /tmp/ct.txt || true
echo '50 2 * * * /opt/team-llm/scripts/export-logs.sh >> /opt/team-llm/logs/export.log 2>&1' >> /tmp/ct.txt
crontab /tmp/ct.txt
crontab -l
rm /tmp/ct.txt
```
```bash
# 7. Verify UI login with username/password (not the master key): open
#    https://llm.substrate.dev/ui and log in as admin / <UI_PASSWORD>. The Logs page
#    shows per-request drill-down. On v1.95.0 the request side may show "Request/Response
#    Data Not Available" (same #23636 quirk — the UI reads the messages column); the
#    response side renders, and the raw request is in the row's proxy_server_request via
#    psql if needed for debugging.
```
```bash
# 8. Disk watch (any time): corpus + DB growth vs free space.
df -h /
du -sh /opt/team-llm/logs /opt/team-llm/backups
docker compose exec -T postgres psql -U litellm -d litellm -c "SELECT pg_size_pretty(pg_database_size('litellm'));"
docker system df
```

**Durability notes**
- Postgres rows live in the `postgres_data` named volume; the corpus is a plain host dir
  (`/opt/team-llm/logs`). Both survive reboots, `docker compose up -d` redeploys, and litellm
  image bumps.
- **Never run `docker compose down -v`** — `-v` deletes the volumes (keys, budgets, logs).
  Plain `docker compose down` is safe.
- The nightly `backup.sh` pg_dump includes the last 90 days of spend logs as a side effect;
  the JSONL corpus is the long-term record.
- **Triage export errors within 90 days.** The scrub is fail-closed: any error (Presidio
  down, oversized row timing out the analyzer) means that day exports NO file until re-run.
  A day that never exports successfully ages out of Postgres after 90 days and is then
  unrecoverable — check `logs/export.log` when in doubt, re-run `export-logs.sh <date>`.
- **Retention knobs:** Postgres = `maximum_spend_logs_retention_period` in `config.yaml`
  (redeploy litellm to apply); corpus = `LOG_EXPORT_RETENTION_DAYS` in `.env` (empty = forever).
  At heavy usage (~3 GB/day raw) drop Postgres to `30d` — see README sizing table.

---

## H. CI auto-deploy (GitHub Actions → box)

Every PR merged to `main` deploys itself: `.github/workflows/deploy.yml` re-runs the validate
checks, rsyncs the repo to `/opt/team-llm`, and runs `scripts/deploy.sh` on the box, which
restarts **only what the change touched**:

| Changed file | Action on the box |
|---|---|
| `docker-compose.yml` | `docker compose up -d` |
| `config.yaml` | `docker compose up -d --force-recreate litellm` |
| `Caddyfile` | graceful `caddy reload` (zero downtime) |
| anything else (docs, scripts) | rsync only — **no restart** |

Manual runs: **Actions → deploy → Run workflow** (or `gh workflow run deploy`). Deploys queue —
two merges never interleave. A deploy is only green after the on-box health gate **and** an
outside-in `curl /health/liveliness` from the runner both pass. Rollback = revert the PR (the
revert deploys itself). Break-glass if GitHub is down: `sudo -iu deploy` on the box, edit
files, `docker compose up -d --force-recreate litellm`.

**What CI can never touch:** the rsync excludes `.env`, `logs/` (the training corpus —
`spendlogs-YYYY-MM-DD.jsonl.gz`, kept forever), `backups/`, and `.deploy-state`; rsync's
`--delete` never removes excluded paths, and `--delete-excluded` is never used. Postgres data
and Caddy certs live in named Docker volumes, invisible to rsync entirely.

**Security model:** the CI key is pinned in `authorized_keys` to a forced command
(`/usr/local/bin/deploy-gatekeeper`, root-owned, outside the rsync'd tree) that allows exactly
two operations — rsync confined to `/opt/team-llm` (via `rrsync`) and running
`scripts/deploy.sh`. No shell, no pty, no forwarding. Eyes open: a leaked key can still upload
files the deploy then executes (config, compose, scripts) — inherent to any push-based
auto-deploy — so the private key exists **only** as an Actions secret of this private repo;
keep no local copy.

### H1. One-time setup

```bash
# 1. Create the deploy user (docker group => can run compose without sudo) and hand it the tree.
sudo adduser --disabled-password --gecos 'CI deploy' deploy
sudo usermod -aG docker deploy
sudo chown -R deploy:deploy /opt/team-llm
```
```bash
# 2. [laptop] Ship the current repo (brings scripts/deploy-gatekeeper.sh + scripts/deploy.sh):
rsync -av --exclude=.env --exclude=.git --exclude=backups --exclude=logs \
  <local-repo>/ <box>:/opt/team-llm/
# If this rsync now fails with permission errors, your admin user lost write access in step 1
# (expected) — re-run it as:  rsync ... --rsync-path='sudo -u deploy rsync' ...
```
```bash
# 3. Install the gatekeeper OUTSIDE the tree (root-owned so the CI key can't rewrite it),
#    and confirm rrsync is available (rsync ships it; path varies by release):
sudo install -m 755 -o root -g root /opt/team-llm/scripts/deploy-gatekeeper.sh /usr/local/bin/deploy-gatekeeper
command -v rrsync || ls /usr/share/rsync/scripts/rrsync
#    If BOTH missing: sudo apt-get install -y rsync  (recent Ubuntu packages /usr/bin/rrsync)
```
```bash
# 4. [laptop] Generate the CI keypair. NO passphrase (CI can't type one); never reused elsewhere.
ssh-keygen -t ed25519 -f ./deploy_key -N '' -C 'gha-deploy lite-llm-proxy'
cat deploy_key.pub    # -> paste into step 5
```
```bash
# 5. Pin the pubkey to the gatekeeper. Paste the deploy_key.pub line where indicated:
sudo install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
echo 'command="/usr/local/bin/deploy-gatekeeper",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty PASTE_DEPLOY_KEY_PUB_LINE_HERE' | sudo tee /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```
```bash
# 6. [laptop] Prove the lockdown works BEFORE giving the key to GitHub:
ssh -i deploy_key deploy@<box-host> echo pwned      # EXPECT: "refused: echo pwned", exit 255
ssh -i deploy_key deploy@<box-host>                  # EXPECT: refused (no interactive shell)
rsync -avn -e 'ssh -i deploy_key' --exclude=.env --exclude=.git <local-repo>/ deploy@<box-host>:/
#    EXPECT: a dry-run file list (rrsync roots the path at /opt/team-llm, hence dest ":/").
#    Do NOT run `ssh ... deploy` yet — that's a real deploy; let CI do it (step H2).
```
```bash
# 7. [laptop] Load the GitHub Actions secrets, then destroy the local private key:
gh secret set DEPLOY_SSH_KEY --repo paritytech/lite-llm-proxy < deploy_key
gh secret set DEPLOY_HOST --repo paritytech/lite-llm-proxy --body '<box-host-or-ip>'
gh secret set DEPLOY_USER --repo paritytech/lite-llm-proxy --body 'deploy'
ssh-keyscan -t ed25519 <box-host> | gh secret set DEPLOY_KNOWN_HOSTS --repo paritytech/lite-llm-proxy
rm -P deploy_key deploy_key.pub    # gone everywhere except GitHub's secret store
```
```bash
# 8. Move the three nightly crons to the deploy user (they write into dirs deploy now owns):
crontab -l | grep '/opt/team-llm/scripts/' | sudo crontab -u deploy -
crontab -l | grep -v '/opt/team-llm/scripts/' | crontab -
sudo crontab -l -u deploy    # EXPECT: backup 02:30, export-logs 02:50, reload-costmap 03:30
crontab -l                   # EXPECT: no /opt/team-llm lines left
```

### H2. First deploy + verify

```bash
# [laptop] Trigger a deploy of current main and watch it:
gh workflow run deploy --repo paritytech/lite-llm-proxy
gh run watch --repo paritytech/lite-llm-proxy --exit-status
```
```bash
# On the box afterwards: state file exists, corpus/backups untouched, stack healthy.
ls -la /opt/team-llm/.deploy-state /opt/team-llm/logs /opt/team-llm/backups
cd /opt/team-llm && docker compose ps
curl -sS https://llm.substrate.dev/health/liveliness
```

From then on, merging a PR **is** the deploy. On-box manual edits should be rare and are made
as the deploy user (`sudo -iu deploy`) — the next CI rsync (`--delete`) overwrites any drift
from the repo, except inside the excluded paths listed above.
