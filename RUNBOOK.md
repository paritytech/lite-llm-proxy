# Box Runbook — Team LLM Proxy

You are already SSH'd into the box (`cargo-remote`). **Run every command on the box**, top to
bottom, unless a block is marked **[laptop]**. Full rationale per step lives in
`docs/superpowers/plans/2026-06-29-team-llm-proxy.md` (Tasks 5–9, 11).

Notes:
- The only **[laptop]** step is copying the repo to the box (B1) — run it in a terminal that is
  *not* inside the box, using your `cargo-remote` SSH alias.
- Commands assume you are **root** on the box. If your shell is not root, prefix the privileged
  ones with `sudo` (or run `sudo -i` once at the start).

---

## A. Provision the box (Docker + firewall)

```bash
# 1. Sanity: OS, free ports, no docker yet
lsb_release -ds; ss -tlnp | grep -E ":(80|443) " || echo "80/443 free"; command -v docker || echo "docker not installed"

# 2. Install Docker Engine + compose plugin
curl -fsSL https://get.docker.com | sh

# 3. Verify (daemon needs sudo until your group membership below takes effect)
sudo docker run --rm hello-world >/dev/null && echo DOCKER_OK && docker compose version

# 3b. Add yourself to the docker group so docker AND the nightly cron run without sudo.
#     newgrp activates it in THIS shell; new terminals get it after re-login.
sudo usermod -aG docker "$USER" && newgrp docker
docker ps >/dev/null && echo DOCKER_NO_SUDO_OK   # confirm no-sudo docker works now

# 4. Firewall: allow SSH first, then 80/443, then enable
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp && sudo ufw --force enable && sudo ufw status verbose
```

```bash
# 5. [laptop] Before relying on the firewall, confirm you are NOT locked out:
#    open a NEW laptop terminal and run —
ssh cargo-remote 'echo SSH_STILL_UP'
#    Expect: SSH_STILL_UP
```

---

## B. Deploy the stack

```bash
# 0. Create the deploy dir and make it yours (so the laptop rsync + .env writes need no sudo)
sudo mkdir -p /opt/team-llm && sudo chown "$USER":"$USER" /opt/team-llm
```

```bash
# 1. [laptop] Copy the repo to the box (excludes secrets + git history).
#    Run in a laptop terminal (NOT inside the box):
rsync -av --exclude='.env' --exclude='.git' --exclude='backups' \
  /Users/utkarsh/Desktop/Projects/team-llm-proxy/ cargo-remote:/opt/team-llm/
```

```bash
# 2. Generate strong secrets and write .env (one postgres password, reused in DATABASE_URL)
cd /opt/team-llm && \
  MK="sk-$(openssl rand -hex 32)"; SK="sk-$(openssl rand -hex 32)"; PG="$(openssl rand -hex 24)"; \
  printf "LITELLM_MASTER_KEY=%s\nLITELLM_SALT_KEY=%s\nPOSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://litellm:%s@postgres:5432/litellm\nMOONSHOT_API_KEY=sk-REPLACE_WITH_MOONSHOT_KEY\nMOONSHOT_API_BASE=https://api.moonshot.ai/v1\n" \
  "$MK" "$SK" "$PG" "$PG" > .env && chmod 600 .env && echo WROTE_ENV
```

```bash
# 3. Paste the REAL Moonshot key (replace PASTE_KEY). Confirm the model + region too:
#    - default model is moonshot/kimi-k2.5 in config.yaml  (edit there if your dashboard differs)
#    - default base is https://api.moonshot.ai/v1          (use .cn/v1 for the China platform)
cd /opt/team-llm && sed -i "s#sk-REPLACE_WITH_MOONSHOT_KEY#PASTE_KEY#" .env && grep -c REPLACE .env
#    Expect: 0   (no placeholders left)
```

```bash
# 4. Bring it up
cd /opt/team-llm && docker compose up -d

# 5. Watch Caddy obtain the Let's Encrypt cert (re-run after ~30s if empty — needs port 80 reachable)
cd /opt/team-llm && docker compose logs caddy | grep -iE "certificate obtained|serving" | tail -5
```

```bash
# 6. Verify HTTPS + liveness (works from the box or your laptop — real cert, no -k flag)
curl -sS https://llm.195-154-218-5.sslip.io/health/liveliness
#    Expect: "I'm alive!"
```

---

## C. Smoke-test a completion (master key)

```bash
MASTER=$(grep ^LITELLM_MASTER_KEY= /opt/team-llm/.env | cut -d= -f2)

curl -sS https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Reply with exactly: pong"}]}'
#    Expect: JSON with choices[0].message.content.
#    If model error: fix `model: moonshot/<name>` in /opt/team-llm/config.yaml, then
#    `cd /opt/team-llm && docker compose up -d` and retry.
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
# backup.sh was copied in step B1. Make it executable and prove it works first:
chmod +x /opt/team-llm/scripts/backup.sh
/opt/team-llm/scripts/backup.sh
ls -la /opt/team-llm/backups/
gzip -t /opt/team-llm/backups/litellm-*.sql.gz
zcat /opt/team-llm/backups/litellm-*.sql.gz | grep -c CREATE
#    Expect: a litellm-<date>.sql.gz of non-trivial size, gzip -t silent, CREATE count > 0.

# Install the nightly cron (02:30). This REPLACES the crontab — fine on a box with no other
# cron jobs (confirm with `crontab -l` first if unsure; if you have other entries, append instead).
echo '30 2 * * * /opt/team-llm/scripts/backup.sh >> /opt/team-llm/backups/backup.log 2>&1' | crontab -
crontab -l
#    Expect: the schedule line echoed back. Runs as your user; docker-group membership makes
#    `docker compose` work unattended.
```

---

## F. Later — DNS cutover to *.substrate.dev (after DevOps #5421 is granted)

```bash
# 1. Confirm DNS resolves to the box (run anywhere)
dig +short <assigned-host>.substrate.dev A      # -> 195.154.218.5
dig +short <assigned-host>.substrate.dev AAAA   # -> 2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe
```

```bash
# 2. [laptop] Edit Caddyfile in the repo: change the one site-label line
#       llm.195-154-218-5.sslip.io  ->  <assigned-host>.substrate.dev
#    then copy it to the box:
rsync -av /Users/utkarsh/Desktop/Projects/team-llm-proxy/Caddyfile cargo-remote:/opt/team-llm/Caddyfile
```

```bash
# 3. Reload (on box)
cd /opt/team-llm && docker compose up -d && docker compose logs caddy | grep -i "certificate obtained" | tail -2

# 4. Verify, then update README base URL and announce to teammates (keys unchanged)
curl -sS https://<assigned-host>.substrate.dev/health/liveliness
```
