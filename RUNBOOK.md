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
#    Models live in config.yaml (3 Kimi + curated OpenRouter + wildcard). For the China
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
#    "cost" field — that is what LiteLLM records (no hardcoded prices needed for OpenRouter).
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

## Pricing model (how spend stays accurate without hardcoding)

- **OpenRouter** returns the real per-call cost; LiteLLM records that directly. No pins needed.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map. The map is
  fetched from GitHub at startup and refreshed daily by the reload cron. A model too new for the
  map (e.g. `kimi-k2.7-code` at launch) needs an explicit `input_/output_cost_per_token` pin in
  `config.yaml` until the map catches up — then the pin can be removed.
- **Wildcard caveat:** a model reached via `openrouter/*` that LiteLLM has no price for may
  under-meter on *streaming* requests (OpenRouter's inline cost is dropped when streaming, and
  there's no map entry to fall back to). The OpenRouter key's own **credit limit is the backstop**
  for this. Curated aliases and all non-streaming calls are unaffected.

## To change models / prices later

Edit `config.yaml` locally → commit → rsync to the box (step B1) →
`cd /opt/team-llm && docker compose up -d --force-recreate litellm`.

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
by default — the training corpus). Full design in `README.md` § "Request logging & training
corpus".

> **Before enabling:** announce to the team that prompts/responses will be logged for model
> training, and point them at README § "Logging & privacy" (includes the per-request opt-out).

```bash
# 1. [laptop] Ship the updated config + script to the box (same as B1):
rsync -av --exclude=.env --exclude=.git --exclude=backups --exclude=logs \
  <local-repo>/ <box>:/opt/team-llm/
```
```bash
# 2. Add the new .env values (UI login + export config). Password is hidden while pasting:
cd /opt/team-llm
printf 'Choose a UI admin password then Enter: '
read -r -s UIPW
printf 'UI_USERNAME=admin\nUI_PASSWORD=%s\nLOG_EXPORT_DIR=/opt/team-llm/logs\nLOG_EXPORT_RETENTION_DAYS=\n' "$UIPW" >> .env
unset UIPW
grep -E '^(UI_USERNAME|LOG_EXPORT)' .env
```
```bash
# 3. Apply (recreates only litellm; Postgres data + keys untouched):
cd /opt/team-llm
docker compose up -d --force-recreate litellm
docker compose ps
```
```bash
# 4. Verify capture: send one request, then check the newest log row has the message body.
MASTER=$(grep '^LITELLM_MASTER_KEY=' /opt/team-llm/.env | cut -d= -f2)
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"log-capture-test"}]}' > /dev/null
docker compose exec -T postgres psql -U litellm -d litellm -c "SELECT \"startTime\", model, left(messages::text, 60) AS messages FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 3;"
#    Expect: newest row's messages column contains "log-capture-test".
```
```bash
# 5. Verify the opt-out actually works on our pinned image (v1.90.0) before announcing it:
curl -sS https://llm.substrate.dev/v1/chat/completions -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"model":"kimi-k2","messages":[{"role":"user","content":"no-log-test"}],"no-log":true}' > /dev/null
docker compose exec -T postgres psql -U litellm -d litellm -c "SELECT \"startTime\", left(coalesce(messages::text,'<empty>'), 60) AS messages FROM \"LiteLLM_SpendLogs\" ORDER BY \"startTime\" DESC LIMIT 1;"
#    Expect: NO "no-log-test" in the messages column. If the text DOES appear, the pinned
#    LiteLLM version doesn't honor no-log for spend logs — remove the opt-out promise from
#    README § "Logging & privacy" (or bump the pinned image) BEFORE announcing.
```
```bash
# 6. Verify the export script, then install its cron (02:50 — after midnight UTC, before the
#    03:30 costmap reload; exports *yesterday*, so today's test may legitimately say 0 rows —
#    run it for today's date to see the rows from step 4/5):
chmod +x /opt/team-llm/scripts/export-logs.sh
/opt/team-llm/scripts/export-logs.sh "$(date -u +%F)"
zcat /opt/team-llm/logs/spendlogs-$(date -u +%F).jsonl.gz | head -1
crontab -l 2>/dev/null > /tmp/ct.txt || true
echo '50 2 * * * /opt/team-llm/scripts/export-logs.sh >> /opt/team-llm/logs/export.log 2>&1' >> /tmp/ct.txt
crontab /tmp/ct.txt
crontab -l
rm /tmp/ct.txt
```
```bash
# 7. Verify UI login with username/password (not the master key): open
#    https://llm.substrate.dev/ui and log in as admin / <UI_PASSWORD>. The Logs page
#    shows per-request drill-down incl. message bodies.
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
- **Retention knobs:** Postgres = `maximum_spend_logs_retention_period` in `config.yaml`
  (redeploy litellm to apply); corpus = `LOG_EXPORT_RETENTION_DAYS` in `.env` (empty = forever).
  At heavy usage (~3 GB/day raw) drop Postgres to `30d` — see README sizing table.
