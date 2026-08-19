#!/usr/bin/env bash
# Copyright (C) Parity Technologies (UK) Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# LLM proxy credential setup.
#
#   ./setup.sh              interactive setup (re-run anytime to add harnesses
#                           or change the URL/key/model — existing setup is kept)
#   ./setup.sh status       show what's configured and whether the key works
#   ./setup.sh cleanup      remove everything this script wrote, restore backups
#
# Non-interactive flags (any missing value is prompted for):
#   ./setup.sh --key sk-... --model deepseek-v3 \
#              --harnesses claude-code,opencode,codex,pi,env --yes
# The base URL defaults to https://llm.substrate.dev; pass --url to override.
#
# Supported harnesses: claude-code, opencode, codex, pi,
# env (generic OPENAI_* vars — covers Aider, Qwen Code, and most other tools).
# UI-configured harnesses (Cline, Copilot, JetBrains, ...) can't be scripted —
# see harnesses/*.md for those.

set -euo pipefail

# How to invoke this script again (differs when running via a pipe). Piped re-run
# hints use gh because the repo is private — the raw.githubusercontent.com URL
# 404s unless/until the repo goes public (see setup/README.md).
GH_RAW_CMD='gh api repos/paritytech/lite-llm-proxy/contents/setup/setup.sh -H "Accept: application/vnd.github.raw"'
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SELF="${BASH_SOURCE[0]}"
else
  SELF="$GH_RAW_CMD | bash -s --"
fi

DEFAULT_BASE="llm.substrate.dev"

LLM_DIR="$HOME/.llm-proxy"
MANIFEST="$LLM_DIR/manifest"
BACKUPS="$LLM_DIR/backups"
ENV_FILE="$LLM_DIR/env.sh"
MARKER="llm-proxy setup"

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

sed_inplace() { # <expr> <file>  (portable GNU/BSD in-place sed)
  sed -i.llmbak "$1" "$2" && rm -f "$2.llmbak"
}

record() { printf '%s\n' "$*" >> "$MANIFEST"; }

backup_file() { # <path> — back up if it exists; record either way (once:
  # on re-runs the first record wins, so cleanup restores the true original)
  local f="$1"
  if [ -f "$MANIFEST" ] && awk -F'\t' -v p="$f" '($1=="created" || $1=="backup") && $2==p {found=1} END{exit !found}' "$MANIFEST"; then
    return 0
  fi
  if [ -e "$f" ]; then
    local copy
    copy="$BACKUPS/$(basename "$f").$(date +%s).$$"
    mkdir -p "$BACKUPS"
    cp -p "$f" "$copy"
    printf 'backup\t%s\t%s\n' "$f" "$copy" >> "$MANIFEST"
  else
    printf 'created\t%s\n' "$f" >> "$MANIFEST"
  fi
}

# ---------------------------------------------------------------- prompts ---

prompt() { # <question> <default> -> REPLY
  local q="$1" def="${2:-}"
  if [ -n "$def" ]; then q="$q [$def]"; fi
  printf '%s: ' "$q" > /dev/tty
  IFS= read -r REPLY < /dev/tty || true
  [ -n "$REPLY" ] || REPLY="$def"
}

prompt_secret() { # <question> -> REPLY
  printf '%s: ' "$1" > /dev/tty
  IFS= read -r -s REPLY < /dev/tty || true
  printf '\n' > /dev/tty
}

# ------------------------------------------------------------------ status --

cmd_status() {
  [ -f "$MANIFEST" ] || { say "Nothing configured (no $MANIFEST)."; exit 0; }
  local base=""
  base=$(awk -F'\t' '$1=="base_url"{print $2}' "$MANIFEST")
  say "Base URL:  https://$base"
  say "Model:     $(awk -F'\t' '$1=="model"{print $2}' "$MANIFEST")"
  say "Harnesses: $(awk -F'\t' '$1=="harness"{printf "%s ", $2}' "$MANIFEST")"
  say "Files written or modified:"
  awk -F'\t' '$1=="created"{print "  created   " $2} $1=="backup"{print "  modified  " $2} $1=="rcline"{print "  rc line   " $2}' "$MANIFEST"
  if [ -f "$ENV_FILE" ]; then
    local key
    key=$(sed -n "s/^ *export LLM_PROXY_KEY='\(.*\)'$/\1/p" "$ENV_FILE")
    if [ -n "$key" ] && command -v curl >/dev/null 2>&1; then
      if curl -sf --max-time 10 "https://$base/v1/models" -H "Authorization: Bearer $key" >/dev/null 2>&1; then
        say "Key check: OK (proxy reachable, key accepted)"
      else
        say "Key check: FAILED (proxy unreachable or key rejected/expired)"
      fi
    fi
  fi
}

# ----------------------------------------------------------------- cleanup --

cmd_cleanup() {
  [ -f "$MANIFEST" ] || { say "Nothing to clean up (no $MANIFEST)."; exit 0; }
  if [ "$ASSUME_YES" != "1" ]; then
    prompt "Remove all llm-proxy config written by this script and restore backups? (y/N)" "n"
    case "$REPLY" in y|Y|yes) ;; *) say "Aborted."; exit 1;; esac
  fi
  # Restore backups and delete created files.
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      created)
        if [ -e "$a" ]; then rm -f "$a"; say "removed   $a"; fi ;;
      backup)
        if [ -f "$b" ]; then cp -p "$b" "$a"; say "restored  $a"; fi ;;
      rcline)
        if [ -f "$a" ]; then
          sed_inplace "/# >>> $MARKER >>>/,/# <<< $MARKER <<</d" "$a"
          say "cleaned   $a"
        fi ;;
    esac
  done < "$MANIFEST"
  rm -rf "$LLM_DIR"
  say "Done. Open a new shell for env changes to take effect."
}

# ------------------------------------------------------------ env snippet ---

write_env_file() { # uses BASE KEY MODEL SEL_*
  backup_file "$ENV_FILE"
  mkdir -p "$LLM_DIR"
  # shellcheck disable=SC2016  # $LLM_PROXY_KEY below is written literally on purpose
  {
    printf '# Generated by llm-proxy setup.sh — do not edit; run setup.sh again instead.\n'
    printf "export LLM_PROXY_KEY='%s'\n" "$KEY"
    if [ "$SEL_CLAUDE" = "1" ]; then
      printf 'export ANTHROPIC_BASE_URL="https://%s"\n' "$BASE"
      printf 'export ANTHROPIC_AUTH_TOKEN="$LLM_PROXY_KEY"\n'
      printf 'export ANTHROPIC_MODEL="%s"\n' "$MODEL"
      # Pin every tier: a saved /model default (Opus/Sonnet) would otherwise
      # send claude-* names the proxy doesn't serve.
      printf 'export ANTHROPIC_DEFAULT_OPUS_MODEL="%s"\n' "$MODEL"
      printf 'export ANTHROPIC_DEFAULT_SONNET_MODEL="%s"\n' "$MODEL"
      printf 'export ANTHROPIC_DEFAULT_HAIKU_MODEL="%s"\n' "$MODEL"
    fi
    if [ "$SEL_ENV" = "1" ]; then
      printf 'export OPENAI_BASE_URL="https://%s/v1"\n' "$BASE"
      printf 'export OPENAI_API_BASE="https://%s/v1"\n' "$BASE"
      printf 'export OPENAI_API_KEY="$LLM_PROXY_KEY"\n'
    fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "wrote     $ENV_FILE"
}

hook_rc_files() {
  local rcs="" rc
  [ -f "$HOME/.zshrc" ]  && rcs="$rcs $HOME/.zshrc"
  [ -f "$HOME/.bashrc" ] && rcs="$rcs $HOME/.bashrc"
  if [ -z "$rcs" ]; then
    case "$(uname -s)" in
      Darwin) rcs="$HOME/.zshrc" ;;
      *)      rcs="$HOME/.bashrc" ;;
    esac
  fi
  for rc in $rcs; do
    if [ -f "$rc" ] && grep -q ">>> $MARKER >>>" "$rc"; then
      continue # already hooked
    fi
    {
      printf '# >>> %s >>>\n' "$MARKER"
      printf '[ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE"
      printf '# <<< %s <<<\n' "$MARKER"
    } >> "$rc"
    printf 'rcline\t%s\n' "$rc" >> "$MANIFEST"
    say "hooked    $rc"
  done
}

# ------------------------------------------------------- harness writers ----

py_merge() { # <file> <python-code> — merge JSON via python3; caller checked existence
  LLM_FILE="$1" LLM_BASE="$BASE" LLM_KEY="$KEY" LLM_MODEL="$MODEL" python3 -c "$2"
}

write_opencode() {
  local f="$HOME/.config/opencode/opencode.json"
  backup_file "$f"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    command -v python3 >/dev/null 2>&1 || { warn "opencode.json exists and python3 is missing — merge manually (see harnesses/opencode.md)"; return 0; }
    py_merge "$f" '
import json, os
p = os.environ["LLM_FILE"]
cfg = json.load(open(p))
cfg.setdefault("provider", {})["parity-proxy"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "LLM Proxy",
    "options": {"baseURL": "https://%s/v1" % os.environ["LLM_BASE"], "apiKey": os.environ["LLM_KEY"]},
    "models": {os.environ["LLM_MODEL"]: {"name": os.environ["LLM_MODEL"]}},
}
cfg["model"] = "parity-proxy/" + os.environ["LLM_MODEL"]
json.dump(cfg, open(p, "w"), indent=2)
'
  else
    cat > "$f" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "parity-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LLM Proxy",
      "options": {
        "baseURL": "https://$BASE/v1",
        "apiKey": "$KEY"
      },
      "models": {
        "$MODEL": { "name": "$MODEL" }
      }
    }
  },
  "model": "parity-proxy/$MODEL"
}
EOF
  fi
  chmod 600 "$f"
  say "wrote     $f"
}

write_codex() {
  local f="$HOME/.codex/config.toml"
  backup_file "$f"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    # drop any previous block we wrote, then re-add
    sed_inplace "/# >>> $MARKER >>>/,/# <<< $MARKER <<</d" "$f"
    if grep -q '^model *=' "$f"; then
      sed_inplace "s|^model *=.*|model = \"$MODEL\"|" "$f"
    else
      printf 'model = "%s"\n%s' "$MODEL" "$(cat "$f")" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
    if grep -q '^model_provider *=' "$f"; then
      sed_inplace "s|^model_provider *=.*|model_provider = \"parity-proxy\"|" "$f"
    else
      printf 'model_provider = "parity-proxy"\n%s' "$(cat "$f")" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  else
    printf 'model = "%s"\nmodel_provider = "parity-proxy"\n' "$MODEL" > "$f"
  fi
  cat >> "$f" <<EOF

# >>> $MARKER >>>
[model_providers.parity-proxy]
name = "LLM Proxy"
base_url = "https://$BASE/v1"
env_key = "LLM_PROXY_KEY"
wire_api = "responses"
# <<< $MARKER <<<
EOF
  say "wrote     $f"
}

write_pi() {
  local f="$HOME/.pi/agent/models.json"
  backup_file "$f"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    command -v python3 >/dev/null 2>&1 || { warn "pi models.json exists and python3 is missing — merge manually (see harnesses/pi.md)"; return 0; }
    py_merge "$f" '
import json, os
p = os.environ["LLM_FILE"]
cfg = json.load(open(p))
cfg.setdefault("providers", {})["parity-proxy"] = {
    "baseUrl": "https://%s/v1" % os.environ["LLM_BASE"],
    "api": "openai-completions",
    "apiKey": os.environ["LLM_KEY"],
    "models": [{"id": os.environ["LLM_MODEL"], "name": os.environ["LLM_MODEL"],
                "input": ["text"]}],
}
json.dump(cfg, open(p, "w"), indent=2)
'
  else
    cat > "$f" <<EOF
{
  "providers": {
    "parity-proxy": {
      "baseUrl": "https://$BASE/v1",
      "api": "openai-completions",
      "apiKey": "$KEY",
      "models": [
        {
          "id": "$MODEL",
          "name": "$MODEL",
          "input": ["text"]
        }
      ]
    }
  }
}
EOF
  fi
  chmod 600 "$f"
  say "wrote     $f"
}

# -------------------------------------------------------------------- main --

ASSUME_YES=0
URL="" KEY="" MODEL="" HARNESSES=""

CMD="setup"
while [ $# -gt 0 ]; do
  case "$1" in
    status)      CMD="status" ;;
    cleanup)     CMD="cleanup" ;;
    --url)       URL="$2"; shift ;;
    --key)       KEY="$2"; shift ;;
    --model)     MODEL="$2"; shift ;;
    --harnesses) HARNESSES="$2"; shift ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)
      cat <<EOF
LLM proxy credential setup.

  setup.sh              interactive setup
  setup.sh status       show what's configured and whether the key works
  setup.sh cleanup      remove everything this script wrote, restore backups

Non-interactive flags (any missing value is prompted for):
  --key sk-...  --model deepseek-v3
  --harnesses claude-code,opencode,codex,pi,env  --yes
Base URL defaults to https://llm.substrate.dev — pass --url to override.

Works piped (no checkout) too:  $GH_RAW_CMD | bash -s -- status
EOF
      exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$CMD" in
  status)  cmd_status;  exit 0 ;;
  cleanup) cmd_cleanup; exit 0 ;;
esac

# Re-running is fine: it adds harnesses and updates values, keeping what's there
PREV_URL="" PREV_MODEL="" PREV_KEY=""
if [ -f "$MANIFEST" ]; then
  say "Existing setup found — updating it (already-configured harnesses are kept)."
  PREV_URL=$(awk -F'\t' '$1=="base_url"{print $2}' "$MANIFEST")
  PREV_MODEL=$(awk -F'\t' '$1=="model"{print $2}' "$MANIFEST")
  [ -f "$ENV_FILE" ] && PREV_KEY=$(sed -n "s/^export LLM_PROXY_KEY='\(.*\)'$/\1/p" "$ENV_FILE")
fi

# 1. Base URL — the team proxy by default; --url overrides (e.g. if it moves)
URL="${URL:-${PREV_URL:-$DEFAULT_BASE}}"
BASE="${URL#https://}"; BASE="${BASE#http://}"; BASE="${BASE%/}"
say "Proxy: https://$BASE"

# 2. API key
if [ -z "$KEY" ]; then
  if [ -n "$PREV_KEY" ]; then
    prompt_secret "API key (enter to keep existing)"
    KEY="${REPLY:-$PREV_KEY}"
  else
    prompt_secret "API key (input hidden)"
    KEY="$REPLY"
  fi
fi
[ -n "$KEY" ] || die "an API key is required"
case "$KEY" in *"'"*) die "API key must not contain single quotes" ;; esac

# 3. Model — pick any model on https://openrouter.ai/models and paste its id
if [ -z "$MODEL" ]; then
  say "Find a model at https://openrouter.ai/models and paste its id."
  prompt "Model (e.g. deepseek/deepseek-chat)" "$PREV_MODEL"
  MODEL="$REPLY"
fi
[ -n "$MODEL" ] || die "a model name is required"
# Ids pasted from openrouter.ai need the openrouter/ prefix to route through the proxy
case "$MODEL" in
  openrouter/*) ;;                  # already prefixed
  */*) MODEL="openrouter/$MODEL" ;; # pasted from openrouter.ai
esac                                # no slash = proxy alias, leave as-is
# A pasted API key would end up in env vars, the model picker, and server logs.
case "$MODEL" in sk-*) die "'sk-...' looks like an API key, not a model id" ;; esac
[ "$MODEL" != "$KEY" ] || die "the model equals the API key, paste a model id instead"

# 4. Harnesses
if [ -z "$HARNESSES" ]; then
  say "Which harnesses should be configured?"
  say "  1. Claude Code   (env vars)"
  say "  2. OpenCode      (~/.config/opencode/opencode.json)"
  say "  3. Codex CLI     (~/.codex/config.toml)"
  say "  4. Pi            (~/.pi/agent/models.json)"
  say "  5. Generic env   (OPENAI_* vars — Aider, Qwen Code, most others)"
  prompt "Comma-separated numbers, or 'all'" "all"
  HARNESSES="$REPLY"
fi
SEL_CLAUDE=0 SEL_OPENCODE=0 SEL_CODEX=0 SEL_PI=0 SEL_ENV=0
if [ "$HARNESSES" = "all" ]; then
  SEL_CLAUDE=1 SEL_OPENCODE=1 SEL_CODEX=1 SEL_PI=1 SEL_ENV=1
else
  OLDIFS=$IFS; IFS=','
  for h in $HARNESSES; do
    h=$(printf '%s' "$h" | tr -d ' ')
    case "$h" in
      1|claude-code) SEL_CLAUDE=1 ;;
      2|opencode)    SEL_OPENCODE=1 ;;
      3|codex)       SEL_CODEX=1 ;;
      4|pi)          SEL_PI=1 ;;
      5|env)         SEL_ENV=1 ;;
      "") ;;
      *) die "unknown harness: $h" ;;
    esac
  done
  IFS=$OLDIFS
fi

# Keep harnesses configured by previous runs — they get updated, not dropped
if [ -f "$MANIFEST" ]; then
  while IFS=$'\t' read -r kind name; do
    [ "$kind" = "harness" ] || continue
    case "$name" in
      claude-code) SEL_CLAUDE=1 ;;
      opencode)    SEL_OPENCODE=1 ;;
      codex)       SEL_CODEX=1 ;;
      pi)          SEL_PI=1 ;;
      env)         SEL_ENV=1 ;;
    esac
  done < "$MANIFEST"
fi

# 5. Write everything, tracked in the manifest (refresh meta, keep file records)
mkdir -p "$LLM_DIR"
chmod 700 "$LLM_DIR"
touch "$MANIFEST"
awk -F'\t' '$1!="base_url" && $1!="model" && $1!="harness"' "$MANIFEST" > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
{
  printf 'base_url\t%s\n' "$BASE"
  printf 'model\t%s\n' "$MODEL"
  if [ "$SEL_CLAUDE" = "1" ];   then printf 'harness\tclaude-code\n'; fi
  if [ "$SEL_OPENCODE" = "1" ]; then printf 'harness\topencode\n'; fi
  if [ "$SEL_CODEX" = "1" ];    then printf 'harness\tcodex\n'; fi
  if [ "$SEL_PI" = "1" ];       then printf 'harness\tpi\n'; fi
  if [ "$SEL_ENV" = "1" ];      then printf 'harness\tenv\n'; fi
} >> "$MANIFEST"

write_env_file
hook_rc_files
[ "$SEL_OPENCODE" = "1" ] && write_opencode
[ "$SEL_CODEX" = "1" ]    && write_codex
[ "$SEL_PI" = "1" ]       && write_pi

say ""
say "Done. Now run:  source $ENV_FILE   (or open a new terminal)"
say "Undo anytime with: $SELF cleanup"
