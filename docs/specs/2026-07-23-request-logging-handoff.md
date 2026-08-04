# Request Logging — Handoff / Next Steps

Status as of 2026-07-27: **implemented (incl. de-identification pipeline), NOT deployed.
Blocked on security review approval.** Nothing has been shipped to the box; the live proxy is
unchanged.

> 2026-07-27 update: the corpus is now **de-identified at export time** — identity-column
> whitelist + Presidio PII scrub (see "Key facts" below). This answers the pseudonymization
> open question from the 07-23 revision. The security team's Google-DLP MCP server was
> evaluated and not adopted: an MCP server is an agent-facing interface, wrong shape for an
> unattended cron pipeline, and calling the DLP API directly would ship prompts to Google —
> the on-box Presidio pair does the same class of detection with no new data flow.

Design + rationale: [`2026-07-22-request-logging-design.md`](./2026-07-22-request-logging-design.md).
Privacy data flow (what's logged, where scrubbed, why pseudonymous):
[`2026-07-28-request-logging-privacy-dataflow.md`](./2026-07-28-request-logging-privacy-dataflow.md).
Deploy procedure: `RUNBOOK.md` § G. Teammate-facing docs: `README.md` § "Logging & privacy".

## What this branch contains

- `config.yaml` — `store_prompts_in_spend_logs: true` + rolling 90-day auto-prune of Postgres
  spend logs (`maximum_spend_logs_retention_period: "90d"`, checked daily).
- `scripts/export-logs.sh` — nightly cron: exports each UTC day's rows (prompts + responses,
  **no user attribution**) to `$LOG_EXPORT_DIR/spendlogs-<date>.jsonl.gz`. Explicit column
  whitelist (drops email/key hash/key alias/team/IP/headers; timestamps coarsened to the
  day). Session structure exported pseudonymously for training (2026-08-04): `session` =
  salted hash of `session_id` (salt = `LOG_EXPORT_SESSION_SALT` in `.env`, never rotated) +
  `turn` rank; rows ordered `(session, turn)` — conversations group in order, but nothing
  links two sessions of one person or reconstructs the day's timeline. Verify + atomic move;
  idempotent; optional `YYYY-MM-DD` arg for backfill.
- `scripts/scrub-logs.py` — stdlib-only JSONL filter between psql and gzip: replaces PII
  (emails, detected person names, phones, cards, IPs) and credential-shaped strings (API
  keys, tokens, whole private-key blocks) in prompt/response text — including bare-string
  list shapes (embeddings/legacy completions) — with `<ENTITY_TYPE>` placeholders; drops
  multimodal payloads (`<MEDIA_REMOVED>`) and per-message participant `name` fields, via
  the on-box Presidio analyzer/anonymizer (compose `scrub` profile, localhost-only,
  started/stopped around the export). **Fails closed** — scrub error ⇒ no corpus file. Logs
  per-entity mask counts each run.
- `docker-compose.yml` — Presidio pair pinned at 2.2.364 behind the `scrub` profile; LiteLLM
  pin bumped v1.90.0 → v1.95.0 (SpendLogs schema verified identical across the range; release
  notes checked, no breaking changes; retention + prompt-store config keys and the session_id
  derivation verified unchanged in v1.95.0 source). v1.94.0 also brings two fixes we wanted:
  provider-reported usage cost for OpenRouter *streams* (closes the wildcard under-metering
  caveat) and tool-call-argument redaction for `no-log`/redacted requests.
- `.env.example` — `UI_USERNAME`/`UI_PASSWORD` (admin UI login), `LOG_EXPORT_DIR`
  (default `/opt/team-llm/logs`), `LOG_EXPORT_RETENTION_DAYS` (empty = keep forever),
  `LOG_EXPORT_SESSION_SALT` (session-pseudonym secret; export refuses to run without it).
- `.github/workflows/validate.yml` — CI: YAML parse, shellcheck, SPDX headers, secret scan.
- README / RUNBOOK / SPEC updates to match.

## Key facts for the security review

- **Two tiers now.** Hot store (Postgres, rolling 90 days): fully attributed rows — email,
  key alias, key hash, timestamps, full prompt/response — admin-only, for debugging and
  erasure requests. Durable corpus (gzipped JSONL, kept indefinitely): **de-identified at
  export time** — identity columns never exported, timestamps day-only, prompt/response text
  PII/credential-scrubbed on-box. No client IPs anywhere.
- This is **pseudonymization, not anonymization** (and docs say so to teammates): free text
  can still identify an author in a small group — the security engineer's caveat about the
  DLP approach applies equally here and is documented rather than hidden.
- Access to logs = `/ui` admin login (`UI_USERNAME`/`UI_PASSWORD` or master key) or shell on
  the box. Virtual keys cannot read logs.
- Scrub failure mode is fail-closed (no file written), and per-entity mask counts are logged
  nightly so false-positive storms are caught inside the 90d re-export window.
- Opt-out: per-request `"no-log": true`. **Must be verified on the pinned image (now v1.95.0)
  before being promised to teammates** — RUNBOOK § G step 5 is the test; if it fails, pull the
  opt-out paragraph from README or bump the image.
- GDPR angle (partially addressed): corpus is de-identified and retention has an annual review
  date (RUNBOOK § G, next 2027-07); attributed data is bounded at 90d. Still open: short DPIA,
  the **training purpose statement** security asked for, always-opt-out keys if requested.

## Next steps, in order

1. [ ] **Security review approves** (current blocker). Give them the review package
       ([`2026-07-29-request-logging-security-review.md`](./2026-07-29-request-logging-security-review.md))
       plus the training purpose statement it calls out.
2. [ ] Address whatever conditions they attach (likely candidates: retention cap on the corpus,
       pseudonymized export, DPIA sign-off).
3. [ ] **Announce to the team** — before deploying, not after. Draft one-liner is at the end of
       the "privacy implications" discussion; link README § "Logging & privacy".
4. [ ] Merge this branch to `main`.
5. [ ] Deploy: rsync to box, add `.env` values, `docker compose up -d --force-recreate litellm`
       — exactly RUNBOOK § G steps 1–3.
6. [ ] Verify capture AND the no-log opt-out on the box (RUNBOOK § G steps 4–5, hard gate).
7. [ ] Test-run `export-logs.sh`, install the 02:50 cron (§ G step 6).
8. [ ] Check UI login with `UI_USERNAME`/`UI_PASSWORD`; confirm Logs drill-down (§ G step 7).
9. [ ] Disk watch after first week: `df -h /`, `du -sh /opt/team-llm/logs`, DB size (§ G step 8).
       Sizing table in README — if growth is in "heavy" territory, drop Postgres retention to 30d.

## Open questions

- ~~Does security want the corpus pseudonymized at export time?~~ **Resolved 2026-07-27: yes,
  implemented.** Erasure requests are handled via the attributed 90d hot store; the corpus
  itself carries no identity to erase. Per-team corpus splits are forgone deliberately.
- ~~"Keep forever" vs. a retention review date?~~ **Resolved 2026-07-27: keep indefinitely
  (no training pipeline yet; the corpus accumulates until one exists), with a yearly retention
  review — next 2027-07, noted in RUNBOOK § G.**
- **Training purpose statement** — security's remaining question ("what will this train?").
  Needs a written answer before/with the review; it scopes what capture is justified.
- Always-opt-out keys: mint mechanism + docs, if the team asks for it.
