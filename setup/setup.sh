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
#   ./setup.sh --key sk-... --model deepseek/deepseek-chat \
#              --harnesses claude-code,opencode,codex,pi,zed,oh-my-pi,env --yes
# The base URL defaults to https://llm.substrate.dev; pass --url to override.
#
# Supported harnesses: claude-code, opencode, codex, pi, zed, oh-my-pi,
# env (generic OPENAI_* vars — covers Aider, Qwen Code, and most other tools).
# UI-configured harnesses (Cline, Copilot, JetBrains, ...) can't be scripted —
# see harnesses/*.md for those.

set -euo pipefail

# How to invoke this script again (differs when running via a pipe).
RAW_URL='https://raw.githubusercontent.com/paritytech/lite-llm-proxy/main/setup/setup.sh'
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  SELF="${BASH_SOURCE[0]}"
else
  SELF="curl -fsSL $RAW_URL | bash -s --"
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
  # Harmless no-op if write_zed never set it.
  command -v launchctl >/dev/null 2>&1 && launchctl unsetenv PARITY_PROXY_API_KEY 2>/dev/null
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
    if [ "$SEL_ENV" = "1" ]; then
      printf 'export OPENAI_BASE_URL="https://%s/v1"\n' "$BASE"
      printf 'export OPENAI_API_BASE="https://%s/v1"\n' "$BASE"
      printf 'export OPENAI_API_KEY="$LLM_PROXY_KEY"\n'
    fi
    if [ "$SEL_ZED" = "1" ]; then
      # Zed derives the key's env var from the provider id: parity-proxy -> PARITY_PROXY_API_KEY.
      printf 'export PARITY_PROXY_API_KEY="$LLM_PROXY_KEY"\n'
    fi
    if [ "$SEL_OMP" = "1" ]; then
      # oh-my-pi ships a native litellm provider: these two vars are the whole
      # config, and it discovers the proxy's model list at runtime.
      printf 'export LITELLM_API_KEY="$LLM_PROXY_KEY"\n'
      printf 'export LITELLM_BASE_URL="https://%s/v1"\n' "$BASE"
    fi
  } > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  say "wrote     $ENV_FILE"
}

# Claude Code gets a wrapper command instead of global ANTHROPIC_* exports, so
# plain `claude` keeps using the user's own account. Tier pins cover plan mode
# and background tasks; the key is sourced from env.sh at run time.
WRAPPER="$HOME/.local/bin/parity-claude"

write_omp_config() { # uses MODEL — bakes in a default so `omp` alone uses the
  # proxy without --model, matching OpenCode's baked-in default. YAML has no
  # safe stdlib parser the way JSON does, so this only ever appends a new
  # top-level key to an existing file (safe: doesn't touch anything else in
  # it) and backs off entirely, with a warning, if modelRoles already exists
  # rather than risk misreading someone's existing default/other roles.
  local f="$HOME/.omp/agent/config.yml" existed=0
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    existed=1
    if grep -q '^modelRoles:' "$f"; then
      warn "$f already has a modelRoles block — add 'default: litellm/$MODEL' under it yourself (see harnesses/oh-my-pi.md)"
      return 0
    fi
  fi
  backup_file "$f"
  [ "$existed" = "1" ] && printf '\n' >> "$f"
  printf 'modelRoles:\n  default: litellm/%s\n' "$MODEL" >> "$f"
  say "wrote     $f"
  OMP_DEFAULT_SET=1
}

write_claude_wrapper() { # uses BASE MODEL
  backup_file "$WRAPPER"
  mkdir -p "$(dirname "$WRAPPER")"
  # shellcheck disable=SC2016  # $LLM_PROXY_KEY / $@ are written literally on purpose
  {
    printf '#!/bin/sh\n'
    printf '# Generated by llm-proxy setup.sh; re-run setup.sh to change key/model.\n'
    printf '. "%s"\n' "$ENV_FILE"
    printf 'export ANTHROPIC_BASE_URL="https://%s"\n' "$BASE"
    printf 'export ANTHROPIC_AUTH_TOKEN="$LLM_PROXY_KEY"\n'
    printf 'export ANTHROPIC_MODEL="%s"\n' "$MODEL"
    printf 'export ANTHROPIC_DEFAULT_OPUS_MODEL="%s"\n' "$MODEL"
    printf 'export ANTHROPIC_DEFAULT_SONNET_MODEL="%s"\n' "$MODEL"
    printf 'export ANTHROPIC_DEFAULT_HAIKU_MODEL="%s"\n' "$MODEL"
    printf 'export ANTHROPIC_DEFAULT_FABLE_MODEL="%s"\n' "$MODEL"
    printf 'command -v claude >/dev/null || { echo "claude not installed: npm install -g @anthropic-ai/claude-code" >&2; exit 127; }\n'
    printf 'exec claude "$@"\n'
  } > "$WRAPPER"
  chmod 755 "$WRAPPER"
  say "wrote     $WRAPPER"
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
      # Already hooked; rewrite only if the block lacks a PATH guard the wrapper needs.
      if [ "$SEL_CLAUDE" != "1" ] || grep -q '\.local/bin' "$rc"; then
        continue
      fi
      sed_inplace "/# >>> $MARKER >>>/,/# <<< $MARKER <<</d" "$rc"
    fi
    # shellcheck disable=SC2016  # the PATH guard is written literally on purpose
    {
      printf '# >>> %s >>>\n' "$MARKER"
      printf '[ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE"
      if [ "$SEL_CLAUDE" = "1" ]; then
        printf 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac\n'
      fi
      printf '# <<< %s <<<\n' "$MARKER"
    } >> "$rc"
    if ! awk -F'\t' -v r="$rc" '$1=="rcline" && $2==r {found=1} END{exit !found}' "$MANIFEST" 2>/dev/null; then
      printf 'rcline\t%s\n' "$rc" >> "$MANIFEST"
    fi
    say "hooked    $rc"
  done
}

# ------------------------------------------------------- harness writers ----

py_merge() { # <file> <python-code> — merge JSON via python3; caller checked existence
  LLM_FILE="$1" LLM_BASE="$BASE" LLM_KEY="$KEY" LLM_MODEL="$MODEL" python3 -c "$2"
}

py_merge_safe() { # <file> <python-code> — merge JSON into <file> via python3.
  # backup_file only runs, and <file> only changes, once the merge has
  # actually succeeded: merges into a scratch copy first, so a parse/read
  # failure of any kind (bad JSON, unreadable, wrong encoding — the caller's
  # python catches broadly and exits nonzero) leaves <file> byte-for-byte
  # untouched and takes no backup. Writes through `cat >`, not `mv`, so a
  # <file> that's a symlink (e.g. dotfiles-managed) keeps pointing at its
  # real target instead of being replaced by a plain file. (A RETURN trap
  # was tried here for scratch-file cleanup on interrupt; bash tears down
  # `local tmp` before that trap fires, and RETURN doesn't fire on a real
  # signal anyway — explicit rm -f at each exit is what actually works.)
  local f="$1" tmp
  tmp="$(mktemp "$f.XXXXXX")"
  cp "$f" "$tmp" || { rm -f "$tmp"; return 1; }
  if ! py_merge "$tmp" "$2"; then
    rm -f "$tmp"
    return 1
  fi
  backup_file "$f"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

write_opencode() {
  local f="$HOME/.config/opencode/opencode.json"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    command -v python3 >/dev/null 2>&1 || { warn "opencode.json exists and python3 is missing — merge manually (see harnesses/opencode.md)"; return 0; }
    py_merge_safe "$f" '
import json, os, sys
p = os.environ["LLM_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    sys.exit(3)
cfg.setdefault("provider", {})["parity-proxy"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Parity LLM Proxy",
    # {env:...} is opencode env-var syntax — a key rotation needs no re-run.
    "options": {"baseURL": "https://%s/v1" % os.environ["LLM_BASE"], "apiKey": "{env:LLM_PROXY_KEY}"},
    "models": {os.environ["LLM_MODEL"]: {"name": os.environ["LLM_MODEL"]}},
}
cfg["model"] = "parity-proxy/" + os.environ["LLM_MODEL"]
json.dump(cfg, open(p, "w"), indent=2)
' || { warn "could not parse $f — merge manually (see harnesses/opencode.md)"; return 0; }
  else
    backup_file "$f"
    cat > "$f" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "parity-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Parity LLM Proxy",
      "options": {
        "baseURL": "https://$BASE/v1",
        "apiKey": "{env:LLM_PROXY_KEY}"
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

write_zed() { # sets ZED_WRITTEN=1 on success; always returns 0, matching the other write_* functions
  local f="$HOME/.config/zed/settings.json"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    command -v python3 >/dev/null 2>&1 || { warn "zed settings.json exists and python3 is missing — merge manually (see harnesses/zed.md)"; return 0; }
    # Zed's own generated file always opens with a "// Zed settings" comment
    # header, and its settings UI writes trailing commas — so plain
    # json.loads fails on nearly every real install. Both are safe to strip
    # here: a JSON string can never contain a literal newline, so a physical
    # line whose first non-whitespace chars are "//" can only be a line
    # comment, never string content; trailing-comma removal below tracks
    # string state so it can't touch a comma inside a quoted value either.
    # Anything left unparseable (block comments, same-line trailing
    # comments) still bails out untouched rather than risking a bad rewrite.
    # A successful merge does re-serialize the file, so any comments —
    # including Zed's own default header — don't survive; see zed.md.
    py_merge_safe "$f" '
import json, os, sys
p = os.environ["LLM_FILE"]
try:
    raw = open(p).read()
    no_comments = "\n".join(
        line for line in raw.split("\n") if not line.strip().startswith("//")
    )
    def strip_trailing_commas(text):
        out, in_str, i, n = [], False, 0, len(text)
        while i < n:
            c = text[i]
            if in_str:
                out.append(c)
                if c == "\\" and i + 1 < n:
                    out.append(text[i + 1]); i += 2; continue
                if c == "\"":
                    in_str = False
                i += 1; continue
            if c == "\"":
                in_str = True; out.append(c); i += 1; continue
            if c == ",":
                j = i + 1
                while j < n and text[j] in " \t\r\n":
                    j += 1
                if j < n and text[j] in "}]":
                    i += 1; continue
            out.append(c); i += 1
        return "".join(out)
    cleaned = strip_trailing_commas(no_comments)
    cfg = json.loads(cleaned) if cleaned.strip() else {}
except Exception:
    sys.exit(3)
lm = cfg.setdefault("language_models", {}).setdefault("openai_compatible", {})
lm.pop("parity_proxy", None)  # migrate a legacy hand-configured underscore id away
lm["parity-proxy"] = {
    "api_url": "https://%s/v1" % os.environ["LLM_BASE"],
    "available_models": [
        {
            "name": os.environ["LLM_MODEL"],
            "display_name": "%s (proxy)" % os.environ["LLM_MODEL"],
            "max_tokens": 128000,
        }
    ],
}
json.dump(cfg, open(p, "w"), indent=2)
' || { warn "could not parse $f (comments or trailing commas?) — add the provider manually (see harnesses/zed.md)"; return 0; }
  else
    backup_file "$f"
    cat > "$f" <<EOF
{
  "language_models": {
    "openai_compatible": {
      "parity-proxy": {
        "api_url": "https://$BASE/v1",
        "available_models": [
          {
            "name": "$MODEL",
            "display_name": "$MODEL (proxy)",
            "max_tokens": 128000
          }
        ]
      }
    }
  }
}
EOF
  fi
  chmod 600 "$f"
  say "wrote     $f"
  # Zed is normally launched from the Dock/Spotlight/Finder, not a shell, so
  # it never sees a plain `export` from .zshrc — only launchd's own
  # per-login-session environment reaches GUI apps launched that way.
  # launchctl setenv covers that path too; a terminal-launched Zed already
  # gets the var from env.sh regardless.
  command -v launchctl >/dev/null 2>&1 && launchctl setenv PARITY_PROXY_API_KEY "$KEY" 2>/dev/null
  ZED_WRITTEN=1
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
name = "Parity LLM Proxy"
base_url = "https://$BASE/v1"
env_key = "LLM_PROXY_KEY"
wire_api = "responses"
# <<< $MARKER <<<
EOF
  say "wrote     $f"
}

write_pi() {
  local f="$HOME/.pi/agent/models.json"
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    command -v python3 >/dev/null 2>&1 || { warn "pi models.json exists and python3 is missing — merge manually (see harnesses/pi.md)"; return 0; }
    # shellcheck disable=SC2016  # $LLM_PROXY_KEY below is written literally on purpose
    py_merge_safe "$f" '
import json, os, sys
p = os.environ["LLM_FILE"]
try:
    cfg = json.load(open(p))
except Exception:
    sys.exit(3)
cfg.setdefault("providers", {})["parity-proxy"] = {
    "baseUrl": "https://%s/v1" % os.environ["LLM_BASE"],
    "api": "openai-completions",
    # $LLM_PROXY_KEY is pi env-var reference syntax — a key rotation needs no re-run.
    "apiKey": "$LLM_PROXY_KEY",
    "models": [{"id": os.environ["LLM_MODEL"], "name": os.environ["LLM_MODEL"],
                "input": ["text"]}],
}
json.dump(cfg, open(p, "w"), indent=2)
' || { warn "could not parse $f — merge manually (see harnesses/pi.md)"; return 0; }
  else
    backup_file "$f"
    cat > "$f" <<EOF
{
  "providers": {
    "parity-proxy": {
      "baseUrl": "https://$BASE/v1",
      "api": "openai-completions",
      "apiKey": "\$LLM_PROXY_KEY",
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
  --key sk-...  --model deepseek/deepseek-chat
  --harnesses claude-code,opencode,codex,pi,zed,oh-my-pi,env  --yes
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
  say "  1. Claude Code   (parity-claude wrapper)"
  say "  2. OpenCode      (~/.config/opencode/opencode.json)"
  say "  3. Codex CLI     (~/.codex/config.toml)"
  say "  4. Pi            (~/.pi/agent/models.json)"
  say "  5. Generic env   (OPENAI_* vars — Aider, Qwen Code, most others)"
  say "  6. Zed           (~/.config/zed/settings.json)"
  say "  7. oh-my-pi      (LITELLM_* vars — models are discovered)"
  prompt "Comma-separated numbers, or 'all'" "all"
  HARNESSES="$REPLY"
fi
SEL_CLAUDE=0 SEL_OPENCODE=0 SEL_CODEX=0 SEL_PI=0 SEL_ENV=0 SEL_ZED=0 SEL_OMP=0
if [ "$HARNESSES" = "all" ]; then
  SEL_CLAUDE=1 SEL_OPENCODE=1 SEL_CODEX=1 SEL_PI=1 SEL_ENV=1 SEL_ZED=1 SEL_OMP=1
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
      6|zed)         SEL_ZED=1 ;;
      7|oh-my-pi|ohmypi|omp) SEL_OMP=1 ;;
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
      zed)         SEL_ZED=1 ;;
      oh-my-pi)    SEL_OMP=1 ;;
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
  if [ "$SEL_ZED" = "1" ];      then printf 'harness\tzed\n'; fi
  if [ "$SEL_OMP" = "1" ];      then printf 'harness\toh-my-pi\n'; fi
} >> "$MANIFEST"

write_env_file
hook_rc_files
[ "$SEL_CLAUDE" = "1" ]   && write_claude_wrapper
[ "$SEL_OPENCODE" = "1" ] && write_opencode
[ "$SEL_CODEX" = "1" ]    && write_codex
[ "$SEL_PI" = "1" ]       && write_pi
ZED_WRITTEN=0
OMP_DEFAULT_SET=0
[ "$SEL_ZED" = "1" ]      && write_zed
[ "$SEL_OMP" = "1" ]      && write_omp_config

say ""
say "Done. Now run:  source $ENV_FILE   (or open a new terminal)"
if [ "$SEL_CLAUDE" = "1" ]; then
  say "Claude Code: run parity-claude (plain claude is untouched; parity-claude --model <alias> for one session)"
fi
if [ "$ZED_WRITTEN" = "1" ]; then
  say "Zed: quit it if it's running, then reopen and pick the model under the parity-proxy provider in the Agent Panel"
fi
if [ "$SEL_OMP" = "1" ]; then
  if [ "$OMP_DEFAULT_SET" = "1" ]; then
    say "oh-my-pi: run omp — $MODEL is now the default (every proxy model is discovered, see /models)"
  else
    say "oh-my-pi: run omp --model litellm/$MODEL (every proxy model is discovered, see /models)"
  fi
fi
say "Undo anytime with: $SELF cleanup"
