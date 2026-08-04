# Request Logging & Training Corpus — Design

Date: 2026-07-22 · Status: approved, implemented

## Purpose

Capture full prompts/responses flowing through the proxy to build a training corpus for
internal AI models, with an access-gated way to browse recent logs, bounded database growth,
and configurable retention/storage location.

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Primary storage | Postgres (hot, via LiteLLM) **+** nightly gzipped JSONL export to disk (durable corpus) |
| Viewing frontend | Existing LiteLLM Admin UI `/ui` (Logs page); no custom viewer. Login via `UI_USERNAME`/`UI_PASSWORD` |
| Postgres retention | 90 days, auto-deleted by LiteLLM (`maximum_spend_logs_retention_period: "90d"`), configurable in `config.yaml` |
| Corpus retention | Forever by default; optional `LOG_EXPORT_RETENTION_DAYS` in `.env` |
| Corpus location | `LOG_EXPORT_DIR` in `.env` (default `/opt/team-llm/logs`) — retargetable to a mounted datastore |
| Privacy | Announce to team before enabling; per-request opt-out via `"no-log": true`; opt-out behaviour verified on the pinned image before announcing (RUNBOOK § G step 5) |
| Compression | gzip, not zstd — matches `backup.sh`, guaranteed present on the box, no new dependency |

## Architecture

```
request ──> litellm ──> Postgres LiteLLM_SpendLogs     (hot store, 90d auto-prune, /ui Logs)
                              │
                              └── cron 02:50: scripts/export-logs.sh
                                    └──> $LOG_EXPORT_DIR/spendlogs-<UTC day>.jsonl.gz  (corpus, ∞)
```

- **Capture:** `store_prompts_in_spend_logs: true` (`config.yaml` `general_settings`). No new
  services; message bodies land in the same SpendLogs rows LiteLLM already writes for budgets.
- **Export:** `scripts/export-logs.sh` dumps one UTC day of whole rows as JSONL
  (`row_to_json`, schema-agnostic) via `psql COPY`, gzips, verifies (`gzip -t`), atomically
  moves into place — the backup.sh safety pattern. Idempotent per day; takes an optional
  `YYYY-MM-DD` arg for backfill. Logs row count + `df -h` for growth visibility.
- **Durability:** Postgres in the `postgres_data` named volume; corpus is a plain host dir
  outside Docker. Both survive reboots/redeploys/image bumps. `docker compose down -v` is the
  only destroyer (documented warning).
- **CI:** `.github/workflows/validate.yml` — YAML parse, shellcheck, SPDX headers, no tracked
  `.env`/real-looking keys. Automates the repo's manual verification checklist.

## Sizing (450 GB disk, 20 engineers)

| Usage | Raw/day | Postgres @90d | Corpus/yr (gzip ~5×) | Fills ~350 GB usable in |
|---|---|---|---|---|
| Light (100 req/eng, 20 KB) | 40 MB | ~4 GB | ~3 GB | decades |
| Moderate (300 req/eng, 60 KB) | 360 MB | ~32 GB | ~26 GB | ~8–10 years |
| Heavy (1000 req/eng, 150 KB) | 3 GB | ~270 GB ⚠️ | ~220 GB | ~1.5 years |

At heavy usage: drop Postgres retention to `30d` and plan off-box corpus archival after ~1 year.
The nightly `df -h` line in `logs/export.log` is the early-warning signal.

## Out of scope

- Custom log-viewer frontend (revisit only if non-admins need log access).
- Off-box/S3 corpus replication (the `.env` location knob is the extension point).
- Training-data pipeline itself (dedup of redundant agentic contexts, filtering opted-out or
  sensitive content) — happens at training-prep time, not capture time.
