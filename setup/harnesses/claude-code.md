# Claude Code

**Works with the proxy:** ✅ (uses the proxy's Anthropic-format `/v1/messages`)
**Type:** CLI · **Install:** `npm install -g @anthropic-ai/claude-code`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

The [setup script](../README.md) installs a `parity-claude` wrapper command: it routes one invocation through the proxy, and plain `claude` keeps using your own Anthropic account. Going back is just running `claude`.

Manual equivalent: save this as `~/.local/bin/parity-claude`, `chmod +x` it, and make sure `~/.local/bin` is on your `PATH`:

```sh
#!/bin/sh
export ANTHROPIC_BASE_URL="https://llm.substrate.dev"     # no /v1 — Claude Code appends /v1/messages itself
export ANTHROPIC_AUTH_TOKEN="$LLM_PROXY_KEY"                # sent as "Authorization: Bearer ..."
export ANTHROPIC_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_OPUS_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_SONNET_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_FABLE_MODEL="<MODEL_NAME>"
export CLAUDE_CONFIG_DIR="$HOME/.llm-proxy/claude"
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="<real context window, e.g. 1048576>"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ATTRIBUTION_HEADER=0
export DISABLE_FEEDBACK_COMMAND=1
export DISABLE_EXTRA_USAGE_COMMAND=1
export DISABLE_ERROR_REPORTING=1
exec claude --model "<MODEL_NAME>" "$@"
```

Every tier is pinned because Claude Code switches tiers on its own (plan mode, background tasks) and would otherwise send `claude-*` names the proxy doesn't serve.

`CLAUDE_CODE_MAX_CONTEXT_TOKENS` matters because every proxy model name is unrecognized to Claude Code, so it otherwise assumes a 200k window and compacts too early. The `DISABLE_*` vars (and `CLAUDE_CODE_ATTRIBUTION_HEADER`) turn off account-tied features — feedback, usage credits, error reports, an attribution block in the system prompt — that don't apply since this isn't a real Anthropic account. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` also breaks Remote Control, an accepted trade here.

## Switch models

`parity-claude --model <MODEL_NAME>` overrides the model for one session — your own `--model` comes after the wrapper's default, so it wins. `/model` inside a `parity-claude` session is safe too, since `CLAUDE_CONFIG_DIR` gives it its own saved-settings directory (below) — a pick there can't leak into your real `claude` sessions, or vice versa.

## Gotchas

- **401?** Use `ANTHROPIC_AUTH_TOKEN` (Bearer header — what the proxy reads), not `ANTHROPIC_API_KEY` (sends `x-api-key` instead).
- Base URL must NOT include `/v1`.
- `ANTHROPIC_SMALL_FAST_MODEL` is deprecated; use `ANTHROPIC_DEFAULT_HAIKU_MODEL`.
- `CLAUDE_CONFIG_DIR` isolates `parity-claude`'s saved settings from plain `claude`'s. Without it, Claude Code's saved `/model` pick lives in one config shared by every session — hit live 2026-09-04: a real-account pick of a newly released model leaked into a `parity-claude` session and 400'd, since a saved literal model ID overrides the `ANTHROPIC_DEFAULT_*` tier pins entirely.
- Isolation also means a fresh `CLAUDE_CONFIG_DIR` starts with none of your real preferences — plugins, theme, effort, voice, permission-prompt skip. The setup script re-syncs `~/.claude/settings.json` into the isolated dir on every run (stripping only `model`), so the scripted install keeps these current automatically; the manual snippet above does not, copy them yourself if you want them.
- `CLAUDE_CONFIG_DIR` only relocates the *user*-level settings file — Claude Code separately reads a *project*-level `$PWD/.claude/settings.json`, which isn't relocated and isn't touched by the isolation above. When `$PWD` is `$HOME`, that project path IS `~/.claude/settings.json` — the real, shared file — so a saved real-account model pick leaks straight back in (hit live 2026-09-04: `parity-claude` launched from `~` picked up the stale real-account model despite isolation). The wrapper's explicit `--model` flag is the actual fix, since a CLI flag outranks every settings.json regardless of which one is stale.

---
*Wrapper verified end-to-end 2026-09-04. Env vars verified against official docs 2026-08-12: [code.claude.com — LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect), [model config](https://code.claude.com/docs/en/model-config), [LiteLLM tutorial](https://docs.litellm.ai/docs/tutorials/claude_responses_api).*
