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
ss -tlnp | grep -E ":(80|443|8443) " || echo "80/443/8443 free"
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
# Firewall: allow SSH first, then 80/443 (API + certs) and 8443 (chat UI, § J),
# then enable (run one at a time). NOTE: for the Docker-PUBLISHED ports (80/443/8443)
# ufw is defense-in-depth only — Docker's nat rules act before ufw's INPUT chain, so
# what really gates container exposure is compose's `ports:` section. ufw genuinely
# gates host services (22).
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 8443/tcp
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
#    "cost" field — that is what LiteLLM records, on streamed and non-streamed calls alike
#    (verified 2026-08-12 — see "Pricing model" below).
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

- **OpenRouter** returns the real per-call cost; LiteLLM records that directly — **streaming
  included** since the v1.95.0 image (upstream fix PR #32255, stable since v1.94.0; on
  ≤ v1.93 streamed responses dropped the inline cost — BerriAI/litellm#16021 — and fell back to
  the price map, metering **$0** for map-missing models, which is why seven curated aliases
  carried temporary list-price pins from 2026-07-24). **Spot-check PASSED 2026-08-12**: a
  streamed wildcard call to a map-missing model (`openrouter/anthropic/claude-opus-4.8`)
  recorded `spend = 0.00018`, exactly OpenRouter's reported cost — so the alias pins were
  removed. Keep OpenRouter entries pin-free: a pin *overrides* the real per-call cost.
- **Kimi / Moonshot** does not return cost, so spend comes from LiteLLM's price map. The map is
  fetched from GitHub at startup and refreshed daily by the reload cron. A model too new for the
  map (e.g. `kimi-k3`, `kimi-k2.7-code`) needs an explicit pin in `config.yaml` until the map
  catches up. Pins must include `cache_read_input_token_cost`: Moonshot auto-caches context and
  bills cache hits at ~1/5–1/10 of the input price, so an input/output-only pin overcounts
  heavily on agentic workloads. (The ≥ v1.94.0 fix changes nothing here — Moonshot sends no
  cost to report.) **Spot-check PASSED 2026-08-12** (streamed `kimi-k2.7-code`, pinned): a
  cold call recorded `spend = 0.00312015` = 3217 in × $0.95/1M + 16 out × $4.00/1M, and an
  identical repeat with a 100% prompt cache hit recorded `spend = 0.00072323` =
  3217 cached × $0.19/1M + 28 out × $4.00/1M — both exact to the last digit, so the input,
  output, AND cache-read pins all apply. Re-run this two-call check (same ~4k-token prompt
  twice, `stream_options.include_usage` on, compare spend-log rows against the pin
  arithmetic) after an image bump or any pin change.
- **Self-hosted vLLM pod (the three `deepseek-flash*` `hosted_vllm` entries)** returns no cost,
  and is pinned to an explicit **$0** (since 2026-09-04; before that a throttle pin at
  OpenRouter's rate made pod tokens drain key budgets, which meant refreshing budgets by hand).
  Pod calls therefore land in the spend logs at `spend = 0` — correct, not a missing pin. Keep
  the pin a literal `0` on ALL THREE entries: with no pin LiteLLM looks the served model up in
  the price map, which has no `hosted_vllm/` entry for it, cost calculation fails, and a failed
  cost calc writes NO spend-log row (the request vanishes from /ui Logs and the corpus export).
  A `0` is honored (v1.97.0 source: the router registers a `not None` pin under the deployment
  id; `use_custom_pricing_for_model` checks `is not None` and steers cost calc to that entry;
  the cost calculator treats an explicit 0/0 as "no token pricing" and returns $0 without
  consulting the map or cache-token prices; the spend-log row is written for any non-None
  cost). Side effect: LiteLLM SKIPS key/team/user budget checks for a model group whose
  deployments are all explicitly $0 (`_is_model_cost_zero` in user_api_key_auth), so an
  over-budget key can still call all three pod aliases. For `deepseek-flash` that means an
  over-budget key still reaches the OpenRouter fallback while the pod is down and bills real
  spend — bounded only by per-key rpm and the OpenRouter credit limit. The fallback itself is
  unaffected: cost comes from the deployment that answered, and the `openrouter/*` wildcard it
  lands on is pin-free. **Spot-check after any image bump or pin change:** one
  `deepseek-flash-parity` call → its spend-log row has `spend = 0` and non-zero
  `total_tokens`; one `deepseek-flash-openrouter` call → `spend` equals OpenRouter's reported
  cost; and with a key whose `max_budget` is already exceeded, one `deepseek-flash-parity`
  call succeeds (budget check skipped) while a `kimi-k2` call is rejected.
- **Wildcard caveat — fixed at v1.94.0, verified on this box 2026-08-12:** a model reached via
  `openrouter/*` with no map entry used to meter $0 on *streaming* requests (a wildcard can't
  carry a pin). Our pinned image (v1.95.0 then, v1.97.0 now) includes the upstream fix and the
  spot-check passed (streamed spend == OpenRouter's reported `cost`). Re-run the spot-check
  after any future
  image bump: stream one wildcard-model request (`"stream": true`,
  `"stream_options": {"include_usage": true}`), then confirm the spend-log row's `spend`
  matches the final chunk's `cost`. The OpenRouter key's own **credit limit** stays on as
  defense-in-depth.
- **Comparing dashboards:** expect small residual gaps even when everything above is right —
  the LiteLLM UI buckets days in UTC while provider dashboards may use local time; OpenRouter's
  billed cost includes its BYOK/provider fees which the price map doesn't model; and map-priced
  streamed calls use list prices, not the routed provider's actual price. Large gaps (2×, or
  models showing $0) mean a missing/stale map entry or a missing pin — except the three
  `deepseek-flash*` pod entries, which are deliberately pinned to $0 (see above) — check
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
# 2. [laptop] Edit the repo: change BOTH site labels in Caddyfile
#       llm.substrate.dev       ->  <assigned-host>.substrate.dev
#       llm.substrate.dev:8443  ->  <assigned-host>.substrate.dev:8443
#    (the /chat redirect targets use the {host} placeholder and follow automatically)
#    and the chat UI's WEBUI_URL in docker-compose.yml. Then copy both to the box:
rsync -av <local-repo>/Caddyfile <local-repo>/docker-compose.yml <box>:/opt/team-llm/
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

---

## I. Self-hosted vLLM backend (reverse SSH tunnel)

Design (why a *reverse* tunnel): the vLLM GPU pod (Runpod, image
<https://github.com/paritytech/vllm-parity>) serving `deepseek-flash` has **no stable public
address** — every relaunch gets a new IP/port — and Runpod's network drops bulk parallel inbound
TCP connections (256 direct connections fail; 256 multiplexed through one SSH connection are
fine). So the pod dials **out** to this box (stable at `llm.substrate.dev`) and opens a reverse
tunnel; all LiteLLM→vLLM traffic multiplexes back through that single connection:

```text
pod: vLLM on 127.0.0.1:9001
 └─ autossh -R 172.17.0.1:18000:127.0.0.1:9001 vllm-tunnel@llm.substrate.dev
     └─ box: sshd listens on 172.17.0.1:18000
        (docker0 gateway: containers CAN reach it, the internet canNOT;
         the host's 127.0.0.1 would be invisible to containers)
         └─ litellm container → http://host.docker.internal:18000/v1
            (extra_hosts in docker-compose.yml maps that name to the same gateway IP)
```

A pod relaunch needs **nothing** on our side: the pod re-dials and the same port comes back.
While it's down, `deepseek-flash` transparently falls back to OpenRouter (config.yaml
`fallbacks`), at real OpenRouter cost. Its sibling aliases pin the routing instead:
`deepseek-flash-parity` and its version-pinned twin `deepseek-flash-parity-v4-0731` (both pod
ONLY) deliberately have no fallback — they fail fast while the pod is down, which is the hard
prompts-stay-in-infra guarantee and what to use when testing the pod itself — and
`deepseek-flash-openrouter` never touches the pod at all. The versioned twin hard-codes the
served model's version in its name: redeploying the pod with a new model means adding the
matching new `deepseek-flash-parity-<version>` alias (config.yaml comments have the full rule).

```bash
# 1. One-time: locked-down tunnel account. All this account can EVER do is bind
#    that one port: nologin shell, and "restrict" in authorized_keys kills
#    pty/X11/agent/exec while "port-forwarding" re-allows only forwarding
#    (narrowed further to one listen address by the Match block in step 2).
sudo useradd -r -m -s /usr/sbin/nologin vllm-tunnel
sudo install -d -m 700 -o vllm-tunnel -g vllm-tunnel /home/vllm-tunnel/.ssh
# Paste the POD's public key (from its operator) after the options, ONE line:
echo 'restrict,port-forwarding ssh-ed25519 AAAA_POD_PUBLIC_KEY vllm' \
  | sudo tee /home/vllm-tunnel/.ssh/authorized_keys
sudo chown vllm-tunnel:vllm-tunnel /home/vllm-tunnel/.ssh/authorized_keys
sudo chmod 600 /home/vllm-tunnel/.ssh/authorized_keys
```

```bash
# 2. One-time: sshd policy for that account. APPEND to /etc/ssh/sshd_config itself,
#    NOT a sshd_config.d drop-in: Ubuntu includes drop-ins at the TOP of the main
#    file and a Match block stays open past the end of its own file — it would
#    swallow the main config below the Include. End of the main file is the one
#    spot where "until next Match or EOF" is unambiguous.
sudo tee -a /etc/ssh/sshd_config >/dev/null <<'EOF'

# vllm-tunnel: reverse tunnel for the self-hosted vLLM pod (RUNBOOK § I).
# May ONLY bind 172.17.0.1:18000 (docker0 gateway — container-reachable, not
# internet-reachable). No shell, no local forwards, no pty, no agent/X11.
Match User vllm-tunnel
    AllowTcpForwarding remote
    GatewayPorts clientspecified
    PermitListen 172.17.0.1:18000
    PermitOpen none
    PermitTTY no
    AllowAgentForwarding no
    X11Forwarding no
    ClientAliveInterval 15
    ClientAliveCountMax 4
EOF
```

```bash
# 2b. One-time: firewall. ufw's default-deny also covers CONTAINER -> HOST
#     traffic, and its deny is a silent DROP: without this rule the litellm
#     container's SYNs to 172.17.0.1:18000 just vanish, so connects hang out a
#     long client timeout instead of failing fast — which breaks BOTH the live
#     tunnel path and the instant OpenRouter fallback (hit on the first deploy,
#     2026-08-12: deepseek-flash requests hung instead of falling back).
#     Scoped tight: Docker-network sources only, this one ip:port only —
#     nothing here is reachable from the internet either way.
sudo ufw allow from 172.16.0.0/12 to 172.17.0.1 port 18000 proto tcp comment 'containers -> vllm reverse tunnel (RUNBOOK § I)'
#     Verify from inside the container — expect ConnectionRefusedError in <1s
#     while the tunnel is down (refused = reachable-but-nobody-listening; a
#     timeout means the rule didn't take):
docker compose exec litellm python3 -c "import socket; socket.create_connection(('host.docker.internal', 18000), timeout=5)"
```

```bash
# 3. Validate BEFORE reloading (a broken sshd config = locked out of the box).
#    Keep this SSH session open until a NEW laptop login is proven to work.
sudo sshd -t
#    Expect: no output. Then eyeball the effective policy for the tunnel user:
sudo sshd -T -C user=vllm-tunnel,host=pod,addr=203.0.113.1 \
  | grep -Ei 'allowtcpforwarding|permitlisten|permittty|gatewayports'
sudo systemctl reload ssh
# [laptop, NEW terminal] must still log in fine before you close anything:
ssh <you>@llm.substrate.dev true
```

```bash
# 4. Send the pod operator (a) our host key to pin, (b) the client line to bake
#    into the Runpod template so the pod self-registers on boot:
# [laptop] our host key:
ssh-keyscan -t ed25519 llm.substrate.dev
#    Client line (pod side; -M 0 = rely on ServerAlive keepalives, not a monitor port):
#      autossh -M 0 -N -T \
#        -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
#        -o StrictHostKeyChecking=yes \
#        -R 172.17.0.1:18000:127.0.0.1:9001 vllm-tunnel@llm.substrate.dev
#    ExitOnForwardFailure is load-bearing: without it, a reconnect that fails to
#    re-bind the port looks "connected" while forwarding nothing, and autossh
#    never retries. The -R bind address must be LITERALLY 172.17.0.1 — sshd's
#    PermitListen rejects anything else.
```

```bash
# 5. Verify end-to-end, both directions (tunnel UP, then tunnel DOWN):
ss -tlnp | grep 18000
#    Expect: sshd LISTEN on 172.17.0.1:18000.
curl -s http://172.17.0.1:18000/v1/models
#    Expect: vLLM's model list. The served model id here MUST match the
#    hosted_vllm/<name> in ALL THREE pod-backed config.yaml entries
#    (deepseek-flash, deepseek-flash-parity AND deepseek-flash-parity-<version>
#    — kept in lockstep; updating only some leaves the rest 404-ing). A new
#    served model also means a NEW deepseek-flash-parity-<version> alias.
#    After editing: `grep -c REPLACE_WITH config.yaml` → 0.
docker compose exec litellm python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://host.docker.internal:18000/v1/models', timeout=5).read().decode())"
#    Expect: same JSON — proves the container→host-gateway path.
#    Then one real completion through the proxy with "model": "deepseek-flash"
#    (curl as in § C), and one more with the pod STOPPED — expect a slower,
#    OpenRouter-served success (fallback), NOT an error. In /ui Logs the two rows
#    show provider hosted_vllm vs openrouter respectively.
#    Also while the pod is STOPPED: "model": "deepseek-flash-parity" (and its
#    versioned twin) must FAIL fast (<1s connection error — no fallback by
#    design; a hang means the step-2b ufw rule is missing), and
#    "deepseek-flash-openrouter" must succeed.
```

```bash
# Ops notes:
# - Pod relaunched => nothing to do here (it re-dials; same port comes back).
# - Tunnel health at a glance: the `ss` line above. Dead tunnel is NOT an outage
#   for deepseek-flash (falls back to OpenRouter at real cost until the pod
#   redials) — but deepseek-flash-parity and deepseek-flash-parity-<version>
#   ARE down while it's dead: no fallback, fail-fast, by design.
# - Half-dead session still holding the port (pod reconnects but can't re-bind):
sudo pkill -u vllm-tunnel
#   kills only that account's sshd session; the pod's autossh redials in seconds.
# - Kill switch (pod key compromised / decommissioned): comment out the line in
#   /home/vllm-tunnel/.ssh/authorized_keys, then `sudo pkill -u vllm-tunnel`.
#   deepseek-flash traffic falls back to OpenRouter transparently, but
#   deepseek-flash-parity and its versioned twin go HARD DOWN (no fallback by
#   design) — announce it or repoint those aliases. Delete the account, the
#   sshd_config Match block, and all three pod-backed config.yaml entries at
#   leisure.
# - 172.17.0.1 is Docker's default docker0 gateway. If the daemon's default
#   bridge subnet is ever customised, update sshd's PermitListen, the pod's -R
#   bind address, AND the ufw rule from step 2b (host.docker.internal follows
#   the daemon automatically).
```

---

## J. Hosted chat UI (Open WebUI, https://llm.substrate.dev:8443)

Browser chat over the same proxy: the `openwebui` service in `docker-compose.yml`, served by
Caddy on the **same hostname at alternate TLS port 8443** — deliberately NOT a new subdomain
(DNS records need an external DevOps grant; a port is ours to open) and NOT *served* under a
path (Open WebUI can't run under a subpath — upstream PR #12002 closed unmerged — and `/chat*`
proxying would shadow LiteLLM's root `/chat/completions` route that SDK clients depend on).
The typeable address is the **exact-path redirect** `llm.substrate.dev/chat` → `:8443` in the
Caddyfile, which coexists safely with `/chat/completions`. Access model (README "Chat UI" is
the user-facing doc):

- **Shared pool:** the UI's built-in connection uses ONE budget-capped virtual key
  (`OPENWEBUI_SHARED_KEY` in `.env`) — anyone with an approved account chats without handling
  a key. When its monthly budget is gone, the default models pause for everyone. Deliberate.
- **Personal keys:** users add a Direct Connection (`https://llm.substrate.dev/v1` + own key)
  in their UI settings — spend/budget/attribution behave exactly like API usage. That path is
  **browser → proxy** and never touches the openwebui container.
- **Config-as-code:** `ENABLE_PERSISTENT_CONFIG=false`, so the compose `environment:` block is
  the single source of truth — settings flipped in Open WebUI's admin UI do NOT survive a
  recreate. Change compose, PR, merge.

```bash
# 0. BEFORE merging the PR that adds the service — prep, because MERGE = DEPLOY = the
#    chat UI is on the internet minutes later, and step 1's race starts then:
#    a) Firewall (idempotent; in § A's firewall step for new boxes). NOTE this is
#       defense-in-depth, NOT the exposure gate: Docker routes published-port traffic
#       through its own nat chain BEFORE ufw's INPUT rules, so :8443 answers as soon as
#       caddy is recreated regardless of ufw (docs.docker.com "Packet filtering and
#       firewalls"). What actually governs exposure is which ports compose PUBLISHES.
sudo ufw allow 8443/tcp
#    b) Have step 1's signup command filled in and ready to paste (strong password,
#       your work email), and be watching the deploy in the Actions tab.

# 1. Claim the admin account THE MOMENT the deploy goes green. The FIRST account ever
#    created is the Open WebUI admin — an internet stranger who signs up before you
#    silently owns the chat UI (and, once the shared key is configured, can read it out
#    of the admin settings). ENABLE_SIGNUP=false would NOT prevent this: upstream
#    deliberately exempts the first admin from that gate. So don't leave a gap:
curl -s https://llm.substrate.dev:8443/api/v1/auths/signup \
  -H 'Content-Type: application/json' \
  -d '{"name":"Admin","email":"<you>@parity.io","password":"<STRONG-PASSWORD>"}'
#    Expect: JSON containing "role":"admin". IF IT SAYS "pending" INSTEAD, someone beat
#    you to the account: stop, wipe the UI state and reclaim —
#      docker compose rm -sf openwebui && docker volume rm team-llm_openwebui_data
#      docker compose up -d openwebui   # then sign up again, immediately
#    — and if OPENWEBUI_SHARED_KEY was already set in .env at that point, treat it as
#    exposed: rotate it (mint new per step 2, /key/delete the old).

# 2. Mint the shared key (budget-capped; the alias makes it findable in /ui). Do this
#    AFTER the admin account is confirmed yours — the key is visible to the UI admin.
#    max_budget is the monthly fair-use pool for ALL shared-connection chat; rpm_limit
#    keeps one careless user (or a runaway tab) from draining it in minutes.
curl -s https://llm.substrate.dev/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"key_alias":"openwebui-shared","max_budget":50,"budget_duration":"30d","rpm_limit":30}'
#    Copy "key" from the response into /opt/team-llm/.env:
#      OPENWEBUI_SHARED_KEY=sk-...
#    then recreate the service so it picks the env up:
docker compose up -d --force-recreate openwebui

# 3. Approve users: later signups land as "pending" (DEFAULT_USER_ROLE) — approve them
#    under Admin Panel → Users → role: user. If the login page shows NO sign-up link,
#    signup got turned off — upstream auto-disables it when the first admin is created —
#    and compose's ENABLE_SIGNUP=true pin (plus a recreate) restores it.

# 4. Verify per-user attribution on the shared key: chat once as an approved user, then in
#    https://llm.substrate.dev/ui → Logs open that request. Expect the openwebui user email
#    in the request TAGS (litellm_settings.extra_spend_tag_headers — the reliable signal),
#    and the same email under Usage → Customer (general_settings.user_header_mappings —
#    best-effort: upstream flake BerriAI/litellm#14667; tags alone are acceptable).

# 5. Verify the personal-key path (Direct Connections): in the chat UI as a normal user,
#    Settings → Connections → + Add Connection → URL https://llm.substrate.dev/v1 + a real
#    virtual key → its models appear in the picker and a chat completes. This path runs in
#    the BROWSER, so if models never list, check CORS from the box:
curl -is -X OPTIONS https://llm.substrate.dev/v1/models \
  -H 'Origin: https://llm.substrate.dev:8443' -H 'Access-Control-Request-Method: GET' | head -15
#    (the :8443 origin is DIFFERENT from the API's :443 origin — same-origin rules are
#    scheme+host+port). Expect an Access-Control-Allow-Origin header. If it's missing, add
#    CORS headers for the chat origin to the llm.substrate.dev site block in the Caddyfile
#    (PR it).
```

```bash
# Ops notes:
# - Data: accounts + chat history live in the openwebui_data volume — NOT in the nightly
#   pg_dump (scripts/backup.sh covers Postgres only). Chats are convenience state for now;
#   if that ever changes, add the volume to the backup.
# - Upgrades: bump the PINNED image tag in docker-compose.yml (read the release notes —
#   Open WebUI moves fast), PR, merge; deploy.sh's `docker compose up -d` recreates only
#   this service. Never `latest`.
# - Shared key exhausted mid-month (users report "budget exceeded" on default models):
#   either wait for the window reset, raise max_budget via /key/update, or tell users to
#   add a personal key (README "Chat UI"). Raising the cap is a policy call, not an op.
# - Rotating the shared key: mint a new one (step 2), swap .env, force-recreate openwebui.
#   Old key: /key/delete. Sessions survive the recreate (the UI's signing secret is
#   pinned into the data volume via WEBUI_SECRET_KEY_FILE in docker-compose.yml — without
#   that, every recreate would log everyone out).
# - Prompts from the chat UI hit the proxy like any API call → logged to the training
#   corpus (§ G) under whichever key carried them (shared or personal). The README section
#   tells users this explicitly; the per-request no-log flag is not settable from the UI.
# - Corpus session grouping: Open WebUI sends no litellm_session_id, so each chat turn
#   exports as a standalone one-turn session. Fine for training (the UI resends the full
#   history every turn) — just don't be surprised the corpus doesn't thread them.
# - Attribution headers (x-openwebui-user-*) can be SET BY ANY API KEYHOLDER on direct
#   API calls too — treat the tags/customer fields as informational, not authoritative.
```
