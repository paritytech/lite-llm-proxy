# Request Logging — Handoff / Next Steps

Status as of 2026-07-23: **implemented, NOT deployed. Blocked on security review approval.**
Nothing has been shipped to the box; the live proxy is unchanged.

Design + rationale: [`2026-07-22-request-logging-design.md`](./2026-07-22-request-logging-design.md).
Deploy procedure: `RUNBOOK.md` § G. Teammate-facing docs: `README.md` § "Logging & privacy".

## What this branch contains

- `config.yaml` — `store_prompts_in_spend_logs: true` + rolling 90-day auto-prune of Postgres
  spend logs (`maximum_spend_logs_retention_period: "90d"`, checked daily).
- `scripts/export-logs.sh` — nightly cron: exports each UTC day's full request rows (prompts +
  responses + user attribution) to `$LOG_EXPORT_DIR/spendlogs-<date>.jsonl.gz`. Verify + atomic
  move; idempotent; optional `YYYY-MM-DD` arg for backfill.
- `.env.example` — `UI_USERNAME`/`UI_PASSWORD` (admin UI login), `LOG_EXPORT_DIR`
  (default `/opt/team-llm/logs`), `LOG_EXPORT_RETENTION_DAYS` (empty = keep forever).
- `.github/workflows/validate.yml` — CI: YAML parse, shellcheck, SPDX headers, secret scan.
- README / RUNBOOK / SPEC updates to match.

## Key facts for the security review

- Logs are **fully attributed**: each row carries `user_id` (= teammate email), `key_alias`,
  hashed key, timestamps — alongside the complete prompt and response. No client IPs.
- Access to logs = `/ui` admin login (`UI_USERNAME`/`UI_PASSWORD` or master key) or shell on
  the box. Virtual keys cannot read logs.
- Hot store: Postgres, rolling 90 days. Durable corpus: gzipped JSONL on the host, kept
  indefinitely by default (purpose: internal model training).
- Opt-out: per-request `"no-log": true`. **Must be verified on the pinned image (v1.90.0)
  before being promised to teammates** — RUNBOOK § G step 5 is the test; if it fails, pull the
  opt-out paragraph from README or bump the image.
- GDPR angle (raised, unresolved): employee personal data, indefinite retention, erasure
  requests easy for JSONL / impossible post-training. Suggested: short DPIA, retention review
  date, scrub identities + credential patterns at training-prep time, offer always-opt-out keys.

## Next steps, in order

1. [ ] **Security review approves** (current blocker). Give them this file + the design doc.
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

- Does security want the corpus pseudonymized at export time (strip `user_id`/`key_alias`)?
  Trade-off: loses per-user filtering for erasure requests and per-team corpus splits.
- "Keep forever" vs. a retention review date for the corpus.
- Always-opt-out keys: mint mechanism + docs, if the team asks for it.
