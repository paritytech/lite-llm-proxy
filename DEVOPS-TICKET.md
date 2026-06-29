# DevOps DNS Ticket — ready to file

**Where to file:** new issue at <https://github.com/paritytech/devops/issues>
(same tracker that handled the preview-net DNS record, devops#4833, and the machine request,
devops#4828).

**Format below mirrors the accepted devops#4833 ("Add an A record …") exactly.** Note from that
ticket: `parity.dev` is NOT an acquired domain, so SRE assigns subdomains under
`substrate.dev` — request accordingly. `Proxied: false` is required so our own Caddy /
Let's Encrypt (HTTP-01) can issue the cert (a Cloudflare-proxied record would intercept the
challenge), exactly as preview-net needed it false for WebSockets.

**Labels (if selectable):** `dns`, `R-blockchain-deployments`, `user-reported` · **Priority:** P2

---

## Title

```
Add DNS records for the Team LLM Proxy server
```

## Body

```markdown
## DNS Record Details
- **Subdomain:** llm.substrate.dev  (open to whatever label/convention you prefer under substrate.dev)
- **Type:** A
- **Value:** 195.154.218.5
- **Also requested — Type:** AAAA
- **Value (AAAA):** 2001:bc8:1201:a2b:7ec2:55ff:fead:a4fe
- **Proxied:** false (required — the server runs its own Let's Encrypt via Caddy HTTP-01)
- **TTL:** 1 (auto)
- **Server:** dedicated Online.net/Scaleway box, Ubuntu 24.04, IPv4 195.154.218.5, managed by me

## Purpose
This server hosts an internal LiteLLM proxy (an LLM API gateway) that gives Parity teammates
rate-limited, budgeted, per-user access to our shared Kimi (Moonshot AI) API subscription.
It serves plain HTTPS (REST/JSON) on 443 behind a Caddy reverse proxy; only ports 80 and 443
are exposed.

## SSL Certificate
I will set up Let's Encrypt via Caddy on the server myself once DNS is live (HTTP-01 challenge,
which is why the record must be DNS-only / not proxied). If there's an existing process you'd
prefer I follow, I'm happy to.

## element user
@utkarsh:parity.io
```

---

## Everything SRE needed last time — already filled in above

From devops#4833 / #4828 the fields they act on are: **subdomain**, **record type**, **value (IP)**,
**proxied flag**, **TTL**, **purpose**, **SSL approach**, and an **element/Matrix handle** for
follow-up. All provided. The only thing SRE chose themselves last time was the actual domain
(`substrate.dev`, since `parity.dev` isn't acquired) — so the subdomain label above is a request,
not a hard requirement.

## After it's granted
1. `dig llm.substrate.dev +short` (and `dig AAAA`) → confirm it resolves to the IPs above.
2. Edit `Caddyfile`: replace the `llm.195-154-218-5.sslip.io` site label with `llm.substrate.dev`.
3. Reload Caddy (`docker compose up -d` / Caddy reload) → it auto-issues the Let's Encrypt cert.
4. Announce the new base URL to teammates (their virtual keys keep working unchanged).
5. Per preview-net precedent: when this box is ever decommissioned, file a follow-up to release
   the subdomain.
