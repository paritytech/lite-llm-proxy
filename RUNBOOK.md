# Box Runbook — Team LLM Proxy

Operating guide for `https://ai.labs.paritytech.io`. Everything the machine needs is in
`ansible/`; this document covers what a playbook cannot do for you — the one-time setup, the
model menu, the key lifecycle, and what to do when something breaks.

**Nothing here is triggered by merging a PR.** There is no CI deploy path. Changes reach the
box when an operator runs a playbook.

---

## Contents

- [Prerequisites](#prerequisites)
- [Rebuild from zero](#rebuild-from-zero)
- [Model menu](#model-menu)
- [Virtual keys](#virtual-keys)
- [Smoke tests](#smoke-tests)
- [vLLM pod](#vllm-pod)
- [Routine operations](#routine-operations)
- [Pricing model](#pricing-model)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

On your laptop:

```bash
uv tool install ansible-core --with ansible --with ansible-lint
```

Both packages, and in that order, for a reason worth knowing: `ansible-core` provides the
executables (`ansible-playbook`, `ansible-vault`, `ansible-galaxy`), while the `ansible`
package provides the bundled collections — the playbooks use `community.general.ufw`, which
only ships with the latter. Installing `ansible` as the *primary* package exposes only its own
entry point, `ansible-community`, and leaves you without `ansible-playbook`.

Check it worked:

```bash
ansible-playbook --version && ansible-lint --version
```

`shellcheck` is optional locally (CI runs it over `scripts/*.sh`): `brew install shellcheck`.

**The vault.** Secrets live in `ansible/group_vars/all/vault.yml`, encrypted. Create it once:

```bash
cd ansible/group_vars/all
cp vault.yml.example vault.yml       # fill in real values; openssl rand -hex 32 for the randoms
ansible-vault encrypt vault.yml
ansible-vault edit vault.yml         # to change it later
```

The vault password belongs in the team password manager. CI refuses a `vault.yml` that does not
begin with `$ANSIBLE_VAULT`, so an accidental plaintext commit fails the build rather than
leaking.

**Inventory.** `ansible/inventory.ini` holds the box's IP and the admin username. The IP rather
than the hostname is deliberate — phase 02 has to be runnable before DNS exists.

**SSH access.** Ansible connects to the bare IP, which skips any `~/.ssh/config` block keyed on
a hostname or alias. So "I can `ssh` to the box" is not sufficient — the key has to be usable
for `ssh root@<ip>` (bootstrap) and `ssh llmops@<ip>` (everything after) specifically. Either
load it into your agent in the shell you run from:

```bash
ssh-add --apple-load-keychain    # macOS; or: ssh-add ~/.ssh/<key>
ssh-add -l                       # it must be listed
```

or pin it per-run so nothing depends on ambient state:

```bash
ansible-playbook 00-bootstrap.yml --ask-vault-pass \
  --private-key ~/.ssh/<key>
```

The private key path is deliberately not committed to `inventory.ini`: it differs per operator,
and hardcoding one person's path is how a playbook quietly becomes single-owner.

**DNS.** `ai.labs.paritytech.io` must resolve to the box before phase 02 can obtain a
certificate. Publish the record early; everything up to that point works without it.

---

## Rebuild from zero

Five steps, each independently re-runnable except the first. Run them from `ansible/`.

```bash
cd ansible
```

### 0. Bootstrap the admin account — runs as root, once

```bash
ssh-keyscan -H <box-ip> >> ~/.ssh/known_hosts    # verify the fingerprint in the provider console
ansible-playbook 00-bootstrap.yml --ask-vault-pass
```

Creates `llmops` with your SSH key, a locked password, and passwordless sudo. Prove it works
before going further — the next phase disables root:

```bash
ssh llmops@<box-ip> sudo -n true     # must succeed silently
```

### 1. The machine

```bash
ansible-playbook 01-box.yml --ask-vault-pass --check --diff    # dry run first
ansible-playbook 01-box.yml --ask-vault-pass
```

Base packages, Docker from Docker's apt repository, SSH hardening (no root login, no
passwords), and `ufw` allowing 22/80/443 only.

This is where root SSH is switched off, and it can only run as `llmops` — so the account that
replaces root has already proven itself by the time root goes away. The playbook refuses to
proceed if `llmops` has no authorised key.

### 2. The front door

```bash
ansible-playbook 02-nginx.yml --ask-vault-pass
```

nginx, the site config, and a Let's Encrypt certificate via certbot's webroot plugin. Renewal
is the packaged `certbot.timer` plus a deploy hook that reloads nginx.

Runnable before DNS exists: the certificate step is allowed to fail, says exactly why, and
leaves an HTTP-only site behind. Re-run once the record is published and it completes.

### 3. The stack

```bash
ansible-playbook 03-stack.yml --ask-vault-pass
```

Renders `/opt/team-llm/.env` from the vault, ships `docker-compose.yml` and `config.yaml`,
brings up LiteLLM and Postgres, installs the nightly price-map timer, and waits for
`/health/liveliness` on both the loopback port and the public URL.

Then **populate the model menu** — see the next section. A fresh database has none.

### 4. The vLLM tunnel — optional

```bash
ansible-playbook 04-tunnel.yml --ask-vault-pass
```

Needs the pod's SSH public key in `vars.yml` first. Skip it and the pod-backed aliases simply
have no backend — both `auto/` and `parity/` error until the tunnel exists (and will keep
doing so until `auto/`'s fallback is configured in the UI).

### Verify the whole thing is idempotent

```bash
ansible-playbook site.yml --ask-vault-pass
```

A second run must report **zero changed tasks**. Anything that reports changed on every run is
a bug in the playbook, not a quirk — it means a task is a disguised shell command.

---

## Model menu

Models live in Postgres, added through the admin UI (`config.yaml` sets
`store_model_in_db: true`). This table is the written record of what the UI should contain —
**replay it after any database loss.**

Two rules apply to every row and are easy to get wrong in a form field:

- **Pick an existing credential; never paste a key.** `config.yaml` defines three named
  credentials — `openrouter`, `moonshot`, `vllm-pod` — whose values are `os.environ/…`
  references resolved from the container environment at call time. Selecting one in the UI
  stores a *reference* in the database, so real credentials stay in `.env` and never land in a
  row. A key typed directly into the form would be stored (encrypted) in Postgres instead.
- **OpenRouter rows carry no price pin.** OpenRouter reports its real per-call cost and LiteLLM
  records it; a pin would override the truth with a guess.

### Kimi / Moonshot

Credential `moonshot` on every row (it carries both the key and the API base). Moonshot returns
no per-call cost, so spend is price-map-only and a model too new for the map meters at $0 until
pinned.

| Public name | LiteLLM model | Price pins |
|---|---|---|
| `kimi-k2` | `moonshot/kimi-k2.6` | none |
| `kimi-k2.5` | `moonshot/kimi-k2.5` | none |
| `kimi-k2.7-code` | `moonshot/kimi-k2.7-code` | in `0.00000095`, out `0.000004`, cache read `0.00000019` |
| `kimi-k3` | `moonshot/kimi-k3` | in `0.000003`, out `0.000015`, cache read `0.0000003` |

The cache-read pin is not optional on the pinned rows: Moonshot auto-caches context, and
without it every cached token meters at the full input price — roughly a 5× overcount on
agentic workloads. Remove each pin once LiteLLM's price map includes the model.

### OpenRouter

Credential `openrouter` on every row. No pins, ever.

| Public name | LiteLLM model |
|---|---|
| `claude-sonnet` | `openrouter/anthropic/claude-sonnet-4.6` |
| `claude-opus` | `openrouter/anthropic/claude-opus-4.8` |
| `gpt-5` | `openrouter/openai/gpt-5.5` |
| `gpt-5-mini` | `openrouter/openai/gpt-5.4-mini` |
| `gemini-pro` | `openrouter/google/gemini-2.5-pro` |
| `gemini-flash` | `openrouter/google/gemini-3.5-flash` |
| `deepseek` | `openrouter/deepseek/deepseek-v3.2` |
| `deepseek-r1` | `openrouter/deepseek/deepseek-r1` |
| `deepseek-v4-pro` | `openrouter/deepseek/deepseek-v4-pro` |
| `minimax-m3` | `openrouter/minimax/minimax-m3` |
| `llama-4-maverick` | `openrouter/meta-llama/llama-4-maverick` |
| `openrouter/deepseek-v4.1-flash` | `openrouter/deepseek/deepseek-v4.1-flash` |
| **`openrouter/*`** | **`openrouter/*`** — the wildcard catch-all |

The wildcard serves the whole OpenRouter catalogue by full ID, which is why "please enable
model X" is almost always already done. LiteLLM resolves an exact name before a wildcard
pattern, so the curated `openrouter/deepseek-v4.1-flash` row wins for that one id without
affecting any other `openrouter/*` request.

### Self-hosted vLLM pod

Credential `vllm-pod` on both rows — it carries the key *and* the tunnel address
(`http://host.docker.internal:18000/v1`), so there is no API base to type. Plus an explicit
**`0`** for both input and output cost.

| Public name | LiteLLM model | Max parallel | Fallback |
|---|---|---|---|
| `auto/deepseek-v4.1-flash` | `hosted_vllm/deepseek-v4.1-flash` | 20 | `openrouter/deepseek/deepseek-v4.1-flash` — **not configured yet** |
| `parity/deepseek-v4.1-flash` | `hosted_vllm/deepseek-v4.1-flash` | 12 | **none — by design** |

- **The `0` must be a literal zero, not an empty field.** Absent means "look up the price map",
  which has no entry for the pod's served model; cost calculation then fails, and a request
  whose cost cannot be computed is dropped from the spend logs entirely — it vanishes from the
  UI. A literal `0` is honoured and the row is written at $0.
- **The parallel caps are per row and sum to the pod's limit.** The pod's throughput holds to
  about 32 concurrent requests (benchmarked on 1×B300, 2026-08-08); 20 + 12 sits at that knee.
  Over-cap traffic on `auto/` spills to OpenRouter, over-cap traffic on `parity/` hard-429s —
  which is why the larger share belongs to the alias that degrades softly.
- **Keep both rows' parameters in lockstep** (served model name, API base, cost pins). Only the
  caps and the fallback differ. Updating one and not the other leaves the other 404-ing.
- The served model name must match what the pod reports: `curl 127.0.0.1:9001/v1/models` on the
  pod. A new served model means a **new set of three aliases** named for it — see below.

**The fallback is a rollout step, not yet done.** `config.yaml` deliberately configures no
fallbacks; `auto/`'s is to be set explicitly in the admin UI (Router Settings → fallbacks for
the `auto/deepseek-v4.1-flash` model group, targeting
`openrouter/deepseek/deepseek-v4.1-flash`). Until then `auto/` behaves exactly like `parity/`
— it errors rather than falling back — and `README.md` says so to teammates. After
configuring it, verify it survives a `litellm` restart, then update that note and this table.

### When the pod is redeployed with a new model

The model id is part of every alias name on purpose: it lets teammates pin and verify exactly
which model answers, and makes a stale alias fail loudly instead of quietly serving something
else. So a version bump is not an edit — it is a new set of three aliases
(`auto/…`, `parity/…`, `openrouter/…`) named for the new id, with the old set retired once the
old model stops being served. Update this table, `README.md`'s model tables, and the alias
lists in `AGENTS.md` and `CLAUDE.md` in the same change.

---

## Virtual keys

Export the master key once per session:

```bash
export MASTER=$(ssh llmops@<box-ip> "grep '^LITELLM_MASTER_KEY=' /opt/team-llm/.env | cut -d= -f2-")
export BASE=https://ai.labs.paritytech.io
```

**Mint** — scoped, budgeted, rate-limited:

```bash
curl -fsS -X POST $BASE/key/generate \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_alias":"alice","user_id":"alice@parity.io",
       "max_budget":20,"budget_duration":"30d","rpm_limit":60}'
```

Omit `models` to allow the whole menu, or pass a list to scope it. `budget_duration` makes the
budget roll automatically.

**Inspect** spend: `curl -fsS "$BASE/key/info?key=sk-..." -H "Authorization: Bearer $MASTER"`

**Revoke:** `curl -fsS -X POST $BASE/key/delete -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d '{"keys":["sk-..."]}'`

A revoked key 401s on its next request. There is no grace period.

---

## Smoke tests

After a rebuild, in this order — each one isolates a different layer.

```bash
# 1. Containers are healthy (on the box)
curl -fsS http://127.0.0.1:4000/health/liveliness

# 2. nginx, TLS and DNS in front of them (from anywhere, no -k)
curl -fsS https://ai.labs.paritytech.io/health/liveliness

# 3. A model actually answers
curl -fsS $BASE/v1/chat/completions -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"say hi"}]}'

# 4. Streaming survives the proxy — the test most likely to fail after the move to nginx
curl -N $BASE/v1/chat/completions -H "Authorization: Bearer $MASTER" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","stream":true,
       "messages":[{"role":"user","content":"Count slowly from 1 to 200, one line each."}]}'
```

Step 4 must print chunks **incrementally** and run past 60 seconds without truncating. If the
whole answer arrives at once, `proxy_buffering` is on; if it cuts off around a minute,
`proxy_read_timeout` is at its default. Both live in the nginx site template.

**Prompt storage is off** — confirm after any request:

```bash
docker compose exec -T postgres psql -U litellm -d litellm -tAc \
  'select messages, response from "LiteLLM_SpendLogs" order by "startTime" desc limit 1'
```

Expect no prompt or response text, while the same row's `spend` and token counts are
populated. Text appearing here means `store_prompts_in_spend_logs` got switched on and the
privacy statement in `README.md` is no longer true.

---

## vLLM pod

The pod dials in; the box never dials out.

```
pod:127.0.0.1:9001  --ssh -R-->  box:172.17.0.1:18000  <--http--  litellm container
                                 (docker0 gateway)                (host.docker.internal)
```

**What the pod operator needs from us**, after phase 04:

1. This box's SSH host key, to pin: `ssh-keyscan -t ed25519 ai.labs.paritytech.io`
2. The client command to bake into the Runpod template so the pod self-registers on boot:

```bash
autossh -M 0 -N -T \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=yes \
  -R 172.17.0.1:18000:127.0.0.1:9001 vllm-tunnel@ai.labs.paritytech.io
```

`ExitOnForwardFailure` is load-bearing: without it, a reconnect that fails to re-bind the port
looks connected while forwarding nothing, and autossh never retries. The `-R` bind address must
be literally `172.17.0.1` — sshd's `PermitListen` rejects anything else.

**Verify both directions:**

```bash
ss -lntp | grep 18000                                   # sshd listening on 172.17.0.1:18000
curl -fsS http://172.17.0.1:18000/v1/models             # the pod's model list
docker compose exec -T litellm curl -fsS http://host.docker.internal:18000/v1/models
```

Then one completion against `auto/deepseek-v4.1-flash`. With the pod **stopped**, `parity/`
must fail in **under a second** and `openrouter/deepseek-v4.1-flash` must succeed. A `parity/`
request that *hangs* instead of failing fast means the ufw rule from phase 04 is missing —
ufw's default-deny silently drops container→host traffic rather than rejecting it, so the
connection waits out a long client timeout instead of being refused.

`auto/` currently fails the same way as `parity/` with the pod down, because its fallback is
not configured yet. Once it is (see [Model menu](#model-menu)), re-run this with the pod
stopped: `auto/` must succeed — slower, and with provider `openrouter` on the row in the UI
Logs rather than `hosted_vllm`.

**Ops notes:**

- Pod relaunched → nothing to do. It re-dials and the same port comes back.
- A dead tunnel is currently an outage for **both** pod aliases. Once `auto/`'s fallback is
  configured it stops being one for `auto/` (which then answers via OpenRouter at real cost),
  and remains one for `parity/` by design.
- Half-dead session holding the port (pod reconnects but can't re-bind): `sudo pkill -u
  vllm-tunnel` kills only that account's sessions; autossh redials in seconds.
- Kill switch (pod key compromised): clear `vllm_pod_pubkey` in `vars.yml`, re-run
  `04-tunnel.yml`, then `sudo pkill -u vllm-tunnel`. Both pod aliases go down until `auto/`'s
  fallback exists — announce it, or repoint users at `openrouter/deepseek-v4.1-flash`.
- `172.17.0.1` is Docker's default docker0 gateway. If the daemon's default bridge subnet is
  ever customised, `vllm_tunnel_bind` in `vars.yml` covers sshd's `PermitListen`, the ufw rule
  and the operator instructions together; the container side follows the daemon automatically.

---

## Routine operations

**Change any config.** Edit the repo, then run the phase that owns it:
`docker-compose.yml` or `config.yaml` → `03-stack.yml`; the nginx site → `02-nginx.yml`;
firewall or Docker → `01-box.yml`. Handlers restart only what changed.

**Rotate a provider key.** `ansible-vault edit group_vars/all/vault.yml`, then
`ansible-playbook 03-stack.yml`. The `.env` template change force-recreates LiteLLM. Nothing in
Postgres needs touching, because model rows reference a named credential rather than holding
the secret.

**Never rotate `LITELLM_SALT_KEY` on a live deployment.** It encrypts what the admin UI writes,
so rotating it destroys the model menu as well as any stored credentials.

**Bump the LiteLLM image.** Change the pinned tag in `docker-compose.yml` — never `latest` —
confirm it is a real stable release, run `03-stack.yml`, then re-run the streaming and pricing
smoke tests. LiteLLM ships breaking changes in point releases.

**Change the public hostname.** Edit `public_hostname` in `group_vars/all/vars.yml`, publish
the DNS record, run `02-nginx.yml` (which obtains a certificate for the new name), then
announce. Nothing else in the repo hardcodes the URL. Virtual keys are unaffected.

**Database backups** are Scaleway volume snapshots, configured outside this repo. Confirm they
cover the volume holding `/var/lib/docker/volumes` — that is where the keys, budgets and model
menu live, and it is the only thing standing between you and another rebuild. A snapshot of a
running Postgres is crash-consistent, which Postgres recovers from by WAL replay. Before
anything risky, take a real dump as well:

```bash
docker compose exec -T postgres pg_dump -U litellm litellm | gzip > ~/litellm-$(date +%F).sql.gz
```

**Never `docker compose down -v`.** The `-v` deletes the volume holding all of the above.

---

## Pricing model

Spend enforcement is only as good as the recorded cost, and the three providers behave
differently:

| Provider | Cost source | What to do |
|---|---|---|
| OpenRouter | real per-call cost, reported per response, streamed included | nothing — never pin |
| Kimi / Moonshot | LiteLLM's price map only | pin models the map doesn't know yet, including cache-read |
| Self-hosted pod | nothing | explicit literal `0` |

The price map is fetched from GitHub at startup and refreshed nightly by
`litellm-costmap.timer` (03:30), so day-0 models stay priced without a redeploy. Check it:

```bash
systemctl list-timers | grep costmap
sudo systemctl start litellm-costmap.service && journalctl -u litellm-costmap -n 20
```

Expect `{"status":"success",...}`.

The UI's totals can legitimately differ from a provider dashboard: the proxy meters what it
observes per call, while a provider bills on its own schedule and rounding.

---

## Troubleshooting

**502 from the public URL.** nginx is up, LiteLLM is not. `docker compose ps` and
`docker compose logs --tail=100 litellm`. A cold start runs Prisma migrations and can take ~30s.

**Certificate not issued.** `certbot` needs port 80 reachable and DNS resolving to the box.
`sudo certbot certificates` shows what exists; re-running `02-nginx.yml` retries.

**Streamed responses arrive all at once, or cut off at ~60s.** The nginx proxy settings — see
[Smoke tests](#smoke-tests) step 4.

**A model 404s.** It is not in the menu, or its served name drifted. Check
`GET /v1/models` with the master key, then the [model menu](#model-menu) table.

**Pod requests hang instead of failing fast.** The phase-04 ufw rule is missing. Re-run
`04-tunnel.yml` and verify from inside the container — a connection refused in under a second
is correct; a timeout means the rule did not apply.

**Requests missing from the UI Logs.** A model whose cost cannot be computed is dropped from
the spend logs entirely. Almost always a pod row whose `0` pin was removed.

**Locked out after SSH hardening.** Root login and password auth are off. Recover through the
provider's console, restore a key into `/home/llmops/.ssh/authorized_keys`, and check
`/etc/ssh/sshd_config.d/10-hardening.conf`.
