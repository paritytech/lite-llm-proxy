# Box Runbook — Team LLM Proxy

Copy-paste, top to bottom, to stand up the proxy on the box. Everything here needs your
smartcard-authenticated SSH. Full rationale per step lives in
`docs/superpowers/plans/2026-06-29-team-llm-proxy.md` (Tasks 5–9, 11).

Run on your **laptop** unless a block is marked **[on box]**. Set once per shell:

```bash
export BOX=root@195.154.218.5
```

---

## A. Provision the box (Docker + firewall)

```bash
# 1. Sanity: OS, free ports, no docker yet
ssh $BOX 'lsb_release -ds; ss -tlnp | grep -E ":(80|443) " || echo "80/443 free"; command -v docker || echo "docker not installed"'

# 2. Install Docker Engine + compose plugin
ssh $BOX 'curl -fsSL https://get.docker.com | sh'

# 3. Verify
ssh $BOX 'docker run --rm hello-world >/dev/null && echo DOCKER_OK && docker compose version'

# 4. Firewall: allow SSH first, then 80/443, then enable
ssh $BOX 'ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw --force enable && ufw status verbose'

# 5. CONFIRM SSH STILL WORKS in a NEW connection before closing your current one
ssh $BOX 'echo SSH_STILL_UP'
```

---

## B. Deploy the stack

```bash
# 1. Sync the repo to /opt/team-llm (excludes secrets + git history)
ssh $BOX 'mkdir -p /opt/team-llm'
rsync -av --exclude='.env' --exclude='.git' --exclude='backups' \
  /Users/utkarsh/Desktop/Projects/team-llm-proxy/ $BOX:/opt/team-llm/

# 2. Generate strong secrets and write .env on the box (one postgres password, reused in DATABASE_URL)
ssh $BOX 'cd /opt/team-llm && \
  MK="sk-$(openssl rand -hex 32)"; SK="sk-$(openssl rand -hex 32)"; PG="$(openssl rand -hex 24)"; \
  printf "LITELLM_MASTER_KEY=%s\nLITELLM_SALT_KEY=%s\nPOSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://litellm:%s@postgres:5432/litellm\nMOONSHOT_API_KEY=sk-REPLACE_WITH_MOONSHOT_KEY\nMOONSHOT_API_BASE=https://api.moonshot.ai/v1\n" \
  "$MK" "$SK" "$PG" "$PG" > .env && chmod 600 .env && echo WROTE_ENV'
```

```bash
# 3. Paste the REAL Moonshot key (replace PASTE_KEY). Confirm the model + region too:
#    - default model is moonshot/kimi-k2.5 in config.yaml  (edit there if your dashboard differs)
#    - default base is https://api.moonshot.ai/v1          (use .cn/v1 for the China platform)
ssh $BOX 'cd /opt/team-llm && sed -i "s#sk-REPLACE_WITH_MOONSHOT_KEY#PASTE_KEY#" .env && grep -c REPLACE .env'
#    Expect: 0   (no placeholders left)
```

```bash
# 4. Bring it up
ssh $BOX 'cd /opt/team-llm && docker compose up -d'

# 5. Watch Caddy obtain the Let's Encrypt cert (re-run after ~30s if empty — needs port 80 reachable)
ssh $BOX 'cd /opt/team-llm && docker compose logs caddy | grep -iE "certificate obtained|serving" | tail -5'
```

```bash
# 6. From your laptop — real cert, no -k flag
curl -sS https://llm.195-154-218-5.sslip.io/health/liveliness
#    Expect: "I'm alive!"
```

---

## C. Smoke-test a completion (master key)

```bash
MASTER=$(ssh $BOX 'grep ^LITELLM_MASTER_KEY= /opt/team-llm/.env | cut -d= -f2')

curl -sS https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: pong"}]}'
#    Expect: JSON with choices[0].message.content.
#    If model error: fix `model: moonshot/<name>` in config.yaml, re-rsync, `docker compose up -d`, retry.
```

---

## D. Virtual-key lifecycle (issue → use → track → revoke)

```bash
# 1. Mint a scoped test key
curl -sS https://llm.195-154-218-5.sslip.io/key/generate \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_alias":"smoke-test","models":["kimi-k2"],"max_budget":1,"budget_duration":"30d","rpm_limit":5,"user_id":"smoke@parity.io"}'
TESTKEY=sk-...    # paste returned key

# 2. It works
curl -sS https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $TESTKEY" -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: ok"}]}'

# 3. Spend tracked
curl -sS "https://llm.195-154-218-5.sslip.io/key/info?key=$TESTKEY" -H "Authorization: Bearer $MASTER"

# 4. Revoke
curl -sS https://llm.195-154-218-5.sslip.io/key/delete \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d "{\"keys\":[\"$TESTKEY\"]}"

# 5. Revoked key is rejected
curl -sS -o /dev/null -w "%{http_code}\n" https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $TESTKEY" -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"hi"}]}'
#    Expect: 401
```

---

## E. Nightly backup cron

```bash
# backup.sh was rsynced in step B1; make it executable, install cron (02:30), run once
ssh $BOX 'chmod +x /opt/team-llm/scripts/backup.sh && \
  (crontab -l 2>/dev/null | grep -v team-llm/scripts/backup.sh; echo "30 2 * * * /opt/team-llm/scripts/backup.sh >> /opt/team-llm/backups/backup.log 2>&1") | crontab - && \
  /opt/team-llm/scripts/backup.sh && ls -la /opt/team-llm/backups/'

# Verify the dump is real
ssh $BOX 'gzip -t /opt/team-llm/backups/litellm-*.sql.gz && zcat /opt/team-llm/backups/litellm-*.sql.gz | grep -c "CREATE TABLE"'
#    Expect: integrity OK and CREATE TABLE count >= 1
```

---

## F. Later — DNS cutover to *.substrate.dev (after DevOps #5421 is granted)

```bash
# 1. Confirm DNS resolves to the box
dig +short <assigned-host>.substrate.dev A      # -> 195.154.218.5
dig +short <assigned-host>.substrate.dev AAAA   # -> 2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe

# 2. Edit Caddyfile locally: change the one site-label line
#       llm.195-154-218-5.sslip.io  ->  <assigned-host>.substrate.dev

# 3. Sync + reload
rsync -av /Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile $BOX:/opt/team-llm/Caddyfile
ssh $BOX 'cd /opt/team-llm && docker compose up -d && docker compose logs caddy | grep -i "certificate obtained" | tail -2'

# 4. Verify, update README base URL, announce to teammates (keys unchanged)
curl -sS https://<assigned-host>.substrate.dev/health/liveliness
```
