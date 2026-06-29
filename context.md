# Context — Team LLM Proxy (handoff)

This file lets a fresh Claude Code session pick up where the brainstorming left off.
Read this, then `SPEC.md` (approved design) and `DEVOPS-TICKET.md` (ready-to-file DNS ticket).

## What the user wants

Set up a **LiteLLM proxy** so the user (admin) can give **5–20 (max 20) Parity teammates**
access to a shared **Kimi (Moonshot AI) API subscription**, with:
- per-user **virtual API keys** (issue / revoke independently),
- per-user **budgets** + **usage tracking**,
- **admin powers** to add/remove teammates and control budgets,
- **security** (upstream Kimi key stays server-side; TLS everywhere),
- consumers include **teammates' laptops AND CI / shared servers** → public HTTPS endpoint.

The user explicitly does NOT want this on the shared preview-net server.

## Decisions made (and why)

1. **Host = the dedicated baremetal box, not preview-net.** The box is idle, isolated, huge
   (24 cores / 125 GB RAM / 539 GB free), Ubuntu 24.04. Preview-net is a shared chain-testnet
   that gets redeployed/wiped via CI — wrong place for a stateful, secret-holding service.
   - Public IPv4: `195.154.218.5` · Public IPv6: `2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe`
   - Clean slate: nothing on 80/443, ufw inactive, **Docker not installed yet**.
2. **Stack = Docker Compose: Caddy + LiteLLM + Postgres.** Caddy does auto Let's Encrypt TLS and
   is the only container exposing host ports (80/443). LiteLLM pinned tag (never `latest`).
   Postgres holds keys/budgets/usage.
3. **Access = public endpoint gated by virtual keys** (NOT a private VPN). Tailscale was
   considered and rejected because CI / shared servers need to call it.
4. **Hostname:** start with free `llm.195-154-218-5.sslip.io` (works immediately, real Let's
   Encrypt cert). In parallel, request a `*.substrate.dev` subdomain from SRE (see ticket); swap
   later via a one-line Caddyfile change.
5. **Out of scope for v1:** Redis, SSO admin login, multi-provider routing. Master-key admin
   login + single instance is enough for this scale.

## Current state of this folder

- `SPEC.md` — approved design + build order (sections 1–9). Source of truth.
- `DEVOPS-TICKET.md` — complete, ready-to-file DNS ticket (all our-side info filled in,
  matching the format SRE accepted for preview-net's devops#4833). **Not yet filed.**
- `context.md` — this file.
- No implementation files yet (no docker-compose.yml / Caddyfile / config.yaml).

## Standing constraint to respect

- **Do not file or post to GitHub on the user's behalf.** The DNS ticket is drafted in
  `DEVOPS-TICKET.md` for the user to file themselves. (Reference tickets read during
  brainstorming: paritytech/devops#4833 = preview-net DNS, #4828 = machine request.)

## Open items / what to confirm before/while building

1. **Kimi/Moonshot base URL + exact model name** from the user's dashboard (region-dependent,
   e.g. `https://api.moonshot.ai/v1` + `kimi-k2-...`). Needed for `config.yaml`.
2. Where the deployment repo should be hosted (personal vs `paritytech/...`).
3. Desired `substrate.dev` subdomain label (SRE assigns the convention).

## Suggested next steps for the new session

The design is approved. The natural next move is to turn `SPEC.md` section 8 ("Build order")
into an implementation plan (via the `writing-plans` skill) and then build:
1. Install Docker + enable ufw (22/80/443) on the box `195.154.218.5`.
2. Scaffold `/opt/team-llm/` (docker-compose.yml, Caddyfile→sslip.io host, config.yaml→Moonshot,
   .env + .env.example).
3. Bring up; verify TLS issuance; smoke-test a completion via master key.
4. Mint a test virtual key (small budget + rpm cap); verify gating, spend tracking, revoke.
5. Nightly `pg_dump` backup cron.
6. Teammate onboarding README.
7. (Parallel) user files `DEVOPS-TICKET.md`; on DNS live, swap Caddy hostname + announce.

Note: SSH access to the box is via the user's machine (they ran the diagnostics during
brainstorming). The new session will likely need the user to run commands on the box, or to
provide SSH access.
