# Request Logging — Security Review Package

Audience: security engineering. This is the review-ready summary of the request-logging /
training-corpus feature on branch `feat/request-logging` (not deployed; deployment is gated on
this review). Mechanical detail lives in the companion docs — this file is the assessment
surface: what we collect, the controls, the residual risks we are consciously accepting, and
what we're asking you to approve.

Companion docs (same directory): capture design
([`2026-07-22-request-logging-design.md`](./2026-07-22-request-logging-design.md)), privacy
data flow with diagrams and column-level detail
([`2026-07-28-request-logging-privacy-dataflow.md`](./2026-07-28-request-logging-privacy-dataflow.md)),
status/handoff ([`2026-07-23-request-logging-handoff.md`](./2026-07-23-request-logging-handoff.md)).
Operational procedure: `RUNBOOK.md` § G. Teammate-facing disclosure: `README.md` § "Logging &
privacy".

## What we're asking you to review

1. Is the two-tier design (attributed 90-day hot store / de-identified indefinite corpus) an
   acceptable posture for employee prompt data?
2. Are the export-time controls (column whitelist + on-box Presidio scrub, both described
   below) sufficient given the residual risks we document — or do you require additional
   conditions before deploy?
3. The one open input we owe you: a written **training purpose statement** (your team asked
   "what is the training for?"). That accompanies this package; it is not in the repo yet.

## System summary

Self-hosted LiteLLM gateway (`llm.substrate.dev`; Caddy + LiteLLM + Postgres via Docker
Compose on one box) giving ~20 teammates budgeted access to LLM providers. The feature under
review turns on storage of full request/response bodies to build a corpus for future internal
model training. No training pipeline exists yet; the corpus accumulates until one does — which
is why retention is deliberately indefinite, with a yearly review (next 2027-07).

## Data inventory — the three copies

| Copy | Content | Identity attached | Lifetime | Access |
|---|---|---|---|---|
| In-flight request | raw prompt/response | virtual-key auth | seconds | LLM provider (existing flow, unchanged by this feature) |
| Postgres hot store (`LiteLLM_SpendLogs`) | raw prompt/response | full: teammate email, key hash, key alias, team, exact timestamps. No client IPs. | 90 days, auto-pruned daily by LiteLLM | admin UI login or shell on the box; virtual keys cannot read logs |
| JSONL corpus (`/opt/team-llm/logs/`, gzip per UTC day) | scrubbed prompt/response | none exported | indefinite + yearly review | shell on the box only |

The attributed hot store is deliberate: it is what makes per-person budgets, debugging, and
GDPR erasure requests possible. Attribution is structural to LiteLLM's spend tracking (the
row builder stamps key hash/user/team unconditionally; verified in v1.95.0 source) — the
control applied to it is bounded lifetime + restricted access, not removal.

## Controls at the hot-store → corpus boundary (export time)

De-identification runs nightly in `scripts/export-logs.sh`, at the last point before data
becomes permanent:

1. **Column whitelist (SQL).** The export SELECT enumerates kept columns; identity columns
   (`user` = email, `api_key` hash, `metadata` incl. key alias, `team_id`, `organization_id`,
   `end_user`, `requester_ip_address`, `request_tags`, `proxy_server_request` raw headers,
   `cache_key`, `api_base`, `agent_id`) are never selected. Whitelists fail safe: a column
   LiteLLM adds in a future version stays out until consciously added. Timestamps are reduced
   to the UTC day. Session structure is exported pseudonymously (training requirement,
   2026-08-04): `session` = `md5(secret_salt || session_id)` plus a `turn` rank — raw
   `session_id` values are client-chosen (can embed identity, may appear in client-side logs)
   and never leave Postgres; the salt lives only in the host `.env` (min 32 chars, generated
   by `openssl rand`, never rotated). Rows are ordered by `(session, turn)`: one
   conversation's turns group in order, cross-session ordering is hash-scrambled, and no
   linkage exists between two sessions of the same person.
2. **Content scrub (`scripts/scrub-logs.py`).** Prompt/response text (including bare-string
   list shapes used by embeddings/legacy completions) is scrubbed via a Presidio
   analyzer/anonymizer pair running on-box (pinned images, compose profile, localhost-only,
   up only for the minutes the export runs). Masked to `<ENTITY_TYPE>` placeholders: emails,
   detected person names, phone numbers, payment cards, IBANs, IPs, crypto addresses, and
   credential-shaped strings via custom recognizers (OpenAI/AWS/GitHub/Slack/Google key
   formats, bearer tokens, JWTs, whole private-key blocks). Additionally: multimodal payloads
   (images/audio/files) are dropped to `<MEDIA_REMOVED>` (unscannable, high-density PII), and
   the OpenAI per-message participant `name` field is removed on user/system/assistant
   messages.
3. **Fail-closed plumbing.** Scrub or dump errors abort the pipeline (`set -euo pipefail`);
   output goes to a temp file, is gzip-verified, then atomically moved — a failure produces
   *no* corpus file, never a raw or partial one. Nothing in this path leaves the box (the
   scrubber calls localhost; no third-party processing).
4. **Detection monitoring.** Every export logs per-entity mask counts (`scrub summary:` line).
   A spike flags detector false positives; the 90-day hot store is the re-export window for
   fixing scrub defects (also the recovery bound: export failures must be triaged within 90
   days or that day's data ages out — documented in RUNBOOK).
5. **User-facing controls.** Logging is disclosed to teammates (README) before enablement;
   per-request `"no-log": true` opt-out exists (verification of it on the pinned image is a
   hard RUNBOOK gate before it is promised); always-opt-out keys can be minted on request.

## Residual risks (accepted, not hidden)

- **The corpus is pseudonymous, NOT anonymous — the caveat you raised about the DLP approach
  applies to any detector, including ours.** Scrubbing removes token-shaped identity; it
  cannot remove contextual identity. A prompt like "rewrite my standup notes on the XCM
  refactor PR" contains nothing maskable yet identifies its author to any colleague in a
  ~20-person group. Teammate docs state this explicitly rather than claiming anonymity.
- **Detector recall is imperfect.** Unusual name formats and non-English names will sometimes
  survive; conversely spaCy NER assigns a flat 0.85 confidence, so all detected person names
  are masked including false positives on code identifiers (monitoring + re-export window is
  the mitigation, there is no meaningful confidence dial).
- **GDPR posture:** we treat the corpus as pseudonymized personal data, not anonymized
  (Recital 26). Safeguards: bounded attributed store (90d), de-identified permanent store,
  yearly retention review, disclosure + opt-out. Outstanding: short DPIA and the training
  purpose statement; erasure requests are honored against the hot store (the corpus carries
  no identity to erase against).
- **Within-session linkage is deliberate.** The corpus groups and orders the turns of one
  conversation (pseudonymous `session`/`turn`, above) because whole conversations are the
  training unit. This adds little re-identification surface over the raw content: chat
  requests re-send full history each turn, so a session's final request already contained the
  entire conversation. The boundary we preserve is *cross-session* unlinkability — no key,
  hash, or ordering connects two conversations of the same person. Salt compromise: for the
  ids LiteLLM auto-generates (random UUIDs) the hashes stay irreversible; but session ids are
  client-chosen, and a low-entropy id that embeds identity (e.g. `utkarsh-xcm-3`) would be
  dictionary-checkable by anyone holding the salt alone. Mitigations: teammate docs instruct
  random UUIDs for session ids, and the salt is held to the same standard as the other host
  secrets. Salt + hot-store access adds nothing beyond hot-store access alone, which is
  already fully attributed. Turn numbering is scoped to the export day — a session spanning
  midnight restarts at turn 1 in the next day's file (linkable via the stable session hash).
- **Insider access:** anyone with shell on the box can read the corpus (and the hot store).
  No new exposure relative to the existing deployment (same people already hold the master
  key), but worth stating.
- **Indefinite retention** is a deliberate product decision (collect until a training
  pipeline exists), softened by the yearly review — flagging since retention caps are a
  common review condition.

## Why not the Google DLP MCP server you offered

Evaluated (2026-07-27) and not adopted, for shape and data-flow reasons, not capability ones:
an MCP server is an interface for an interactive AI agent, and this pipeline is an unattended
nightly cron — there is no agent in the loop. Using the underlying DLP API directly would work
technically but ships every prompt to Google Cloud, creating a new third-party processing
relationship for a corpus that otherwise never leaves the box. On-box Presidio provides the
same detector classes (built-in infoTypes + custom regex/dictionary recognizers) with no new
data flow. Your caveat — that neither approach anonymizes free text — is documented above and
in the teammate docs. If security prefers Google's detector stack anyway, the integration
point would be a DLP `content.deidentify` call inside `export-logs.sh` in place of the
Presidio call — the architecture doesn't change.

## Verification evidence

- **Adversarial code review** (independent reviewer pass, 2026-07-29) specifically hunted
  identity leaks into the corpus. Findings — bare-string list shapes bypassing the scrubber,
  per-message `name` leaking usernames, private-key regex masking only the header, multimodal
  payloads unscrubbed — were all reproduced with proof, fixed, and re-proven (details in the
  handoff doc history / branch diff).
- **Fail-closed proven:** scrubber run with Presidio down exits non-zero and writes zero rows.
- **End-to-end scrub tested** against stub Presidio services: chat, embedding, tool-call,
  multimodal, and string-typed row shapes all produce correctly masked output; participant
  names dropped; tool names retained.
- **Presidio API usage verified against upstream source** (2.2.364): `/analyze` ad-hoc
  recognizer payloads, `/anonymize` default-replace semantics (`<ENTITY_TYPE>`), `/health`
  endpoints.
- **Deploy-time gates** (RUNBOOK § G): end-to-end export on the box with an identity-column
  absence check on the real output, scrub-summary presence, `no-log` opt-out verification on
  the pinned image (v1.95.0), and confirmation the scrub containers stop after the run.

## Requested outcome

Approval to deploy as designed, or a concrete list of conditions (e.g. corpus retention cap,
DPIA before enablement, always-opt-out keys at launch). Owner: Utkarsh
(utkarsh.bhardwaj@parity.io).
