#!/usr/bin/env python3
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# PII scrub filter for the nightly corpus export: JSONL in on stdin, JSONL out
# on stdout. Sits between psql and gzip in export-logs.sh, so scrubbing happens
# BEFORE anything lands in the durable corpus — the kept-forever files never
# contain raw PII. Detection runs against the local Presidio containers (see
# docker-compose.yml `scrub` profile); nothing leaves the box.
#
# What it scrubs, inside the `messages` and `response` fields:
#   - string values under prompt/response text keys (content, text,
#     reasoning_content, tool-call arguments) AND bare strings in lists
#     (embedding/legacy-completion input shapes) — masked to `<ENTITY_TYPE>`;
#   - multimodal payloads (image_url/input_audio/file/b64_json) — dropped to
#     `<MEDIA_REMOVED>` (unscannable, high-density PII, poor text-corpus data);
#   - the per-message participant `name` on user/system/assistant messages —
#     removed (it's attribution; tool messages keep their tool name).
# Structure, roles, and everything non-sensitive stay intact, so the corpus
# keeps its training value.
#
# Fail-closed by design: any error (Presidio down, malformed line) exits
# non-zero, which aborts the export pipeline (`set -o pipefail` upstream) —
# a scrub failure can never silently produce a raw-text corpus file.
#
# This is pseudonymization, not anonymization: free text can still identify
# its author to a colleague (writing style, project context). The structural
# de-attribution (dropped identity columns) lives in export-logs.sh.
#
# Stdlib only — no pip installs on the box. Requires python3 (Ubuntu default).

import json
import os
import sys
import urllib.error
import urllib.request
from collections import Counter

ANALYZER_URL = os.environ.get("PRESIDIO_ANALYZER_URL", "http://127.0.0.1:5002")
ANONYMIZER_URL = os.environ.get("PRESIDIO_ANONYMIZER_URL", "http://127.0.0.1:5001")

# Entity types we act on. Note on PERSON: spaCy NER assigns a FLAT 0.85 score
# to every hit (presidio spacy_recognizer ner_strength default), so the 0.85
# bar below does not filter spaCy detections — all NER person hits are masked
# (privacy-first for a kept-forever corpus). What the bar does exclude is
# lower-confidence heuristic sources. The safety net for false positives
# (e.g. code identifiers masked as names) is the nightly mask-count summary
# plus the 90-day re-export window, not this threshold.
ENTITIES = [
    "PERSON",
    "EMAIL_ADDRESS",
    "PHONE_NUMBER",
    "CREDIT_CARD",
    "IBAN_CODE",
    "IP_ADDRESS",
    "CRYPTO",
    "CREDENTIAL",
]
SCORE_THRESHOLDS = {"PERSON": 0.85, "DEFAULT": 0.50}

# Custom recognizer for secrets Presidio's built-ins don't know: API keys,
# tokens, private key material. Patterns are deliberately provider-shaped
# (prefixes/structure) rather than generic entropy checks, to keep false
# positives near zero on code-heavy prompts.
CREDENTIAL_PATTERNS = [
    ("openai-style key", r"\bsk-[A-Za-z0-9_-]{16,}\b"),
    ("aws access key id", r"\bAKIA[0-9A-Z]{16}\b"),
    ("github token", r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b"),
    ("github fine-grained pat", r"\bgithub_pat_[A-Za-z0-9_]{22,}\b"),
    ("slack token", r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    ("google api key", r"\bAIza[0-9A-Za-z_-]{35}\b"),
    ("bearer token", r"(?i)\bbearer\s+[a-z0-9._~+/-]{20,}=*"),
    ("jwt", r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"),
    # Whole block first (non-greedy, spans newlines) so the key MATERIAL is
    # masked, not just the header; header-only fallback catches truncated pastes.
    ("private key block", r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]+?-----END [A-Z ]*PRIVATE KEY-----"),
    ("private key header", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]
AD_HOC_RECOGNIZERS = [
    {
        "name": "credential_patterns",
        "supported_language": "en",
        "supported_entity": "CREDENTIAL",
        "patterns": [
            {"name": name, "regex": regex, "score": 1.0}
            for name, regex in CREDENTIAL_PATTERNS
        ],
    }
]

# Keys whose string values are free text worth scrubbing. Everything else in
# the row (roles, model names, finish reasons, token counts) is structural.
# "thinking" = reasoning text inside thinking_blocks; "refusal" = OpenAI-compat
# refusal message — both are model-generated free text like content.
SCRUB_KEYS = {"content", "text", "reasoning_content", "arguments", "thinking", "refusal"}

# Multimodal payloads (screenshots, audio, files) are dropped outright: base64
# media is a high-density PII vector we can't scrub and poor text-corpus data.
# "input_audio" is the request-side key; "audio" is the response-side object
# (base64 data + transcript). Base64 embedding VECTORS (key "embedding") are
# deliberately left alone: derived numeric data, not media.
MEDIA_KEYS = {"image_url", "input_audio", "audio", "file", "b64_json"}
MEDIA_PLACEHOLDER = "<MEDIA_REMOVED>"

# The OpenAI chat schema allows a participant "name" on user/system/assistant/
# developer messages (often a username or email local-part — exactly the
# attribution this export removes). Dropped, not scrubbed: tool/function
# messages keep their name (it's the tool's name, useful and non-personal).
NAMED_ROLES = {"user", "system", "assistant", "developer"}

# Skip trivial strings — nothing sensitive fits in a few chars, and it halves
# the HTTP round-trips on chat-shaped payloads.
MIN_LEN = 4


def _post(url: str, payload: dict):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def scrub_text(text: str, stats: Counter) -> str:
    findings = _post(
        f"{ANALYZER_URL}/analyze",
        {
            "text": text,
            "language": "en",
            "entities": ENTITIES,
            "ad_hoc_recognizers": AD_HOC_RECOGNIZERS,
        },
    )
    kept = [
        f
        for f in findings
        if f["score"]
        >= SCORE_THRESHOLDS.get(f["entity_type"], SCORE_THRESHOLDS["DEFAULT"])
    ]
    if not kept:
        return text
    result = _post(
        f"{ANONYMIZER_URL}/anonymize",
        {
            "text": text,
            "analyzer_results": kept,
            # Default operator: replace with "<ENTITY_TYPE>".
            "anonymizers": {"DEFAULT": {"type": "replace"}},
        },
    )
    for f in kept:
        stats[f["entity_type"]] += 1
    return result["text"]


def walk(node, stats: Counter):
    """Recursively scrub SCRUB_KEYS string values in-place; return the node."""
    if isinstance(node, dict):
        if node.get("role") in NAMED_ROLES:
            node.pop("name", None)
        for key, value in node.items():
            if key in MEDIA_KEYS:
                node[key] = MEDIA_PLACEHOLDER
            elif key in SCRUB_KEYS and isinstance(value, str) and len(value) >= MIN_LEN:
                node[key] = scrub_text(value, stats)
            else:
                walk(value, stats)
    elif isinstance(node, list):
        # Scrub bare strings too: embedding/legacy-completion rows carry input
        # as a list of strings, not chat dicts — those must not pass raw.
        for i, item in enumerate(node):
            if isinstance(item, str):
                if len(item) >= MIN_LEN:
                    node[i] = scrub_text(item, stats)
            else:
                walk(item, stats)
    return node


def main() -> int:
    stats: Counter = Counter()
    rows = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)  # malformed line -> raise -> abort export
        for field in ("messages", "response"):
            value = row.get(field)
            if isinstance(value, str) and len(value) >= MIN_LEN:
                row[field] = scrub_text(value, stats)
            else:
                walk(value, stats)
        # ensure_ascii=False keeps non-English prompts byte-faithful in the corpus.
        sys.stdout.write(json.dumps(row, ensure_ascii=False) + "\n")
        rows += 1
    # One machine-greppable summary line per export, for the cron log. A sudden
    # spike in a mask count = detector false-positive storm; investigate within
    # the 90d window while a re-export is still possible.
    print(
        f"scrub summary: rows={rows} masked={json.dumps(dict(sorted(stats.items())))}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (urllib.error.URLError, OSError) as exc:
        print(f"scrub FAILED (presidio unreachable?): {exc}", file=sys.stderr)
        sys.exit(1)
