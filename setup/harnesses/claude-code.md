# Claude Code

**Works with the proxy:** ✅ (uses the proxy's Anthropic-format `/v1/messages`)
**Type:** CLI · **Install:** `npm install -g @anthropic-ai/claude-code`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

```bash
export ANTHROPIC_BASE_URL="https://llm.substrate.dev"     # no /v1 — Claude Code appends /v1/messages itself
export ANTHROPIC_AUTH_TOKEN="$LLM_PROXY_KEY"                # sent as "Authorization: Bearer ..."
export ANTHROPIC_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_OPUS_MODEL="<MODEL_NAME>"          # pin all tiers: a saved /model default would otherwise send a claude-* name the proxy may not serve
export ANTHROPIC_DEFAULT_SONNET_MODEL="<MODEL_NAME>"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="<MODEL_NAME>"         # background tasks would otherwise call a claude-haiku-* the proxy may not serve
claude
```

Add the exports to `~/.zshrc` to make it permanent. Optional: `export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` keeps version checks/telemetry off the network entirely.

## Switch models

`ANTHROPIC_MODEL` sets the session default; `claude --model <MODEL_NAME>` per launch; `/model` in-session.

## Gotchas

- **401?** Use `ANTHROPIC_AUTH_TOKEN` (Bearer header — what the proxy reads), not `ANTHROPIC_API_KEY` (sends `x-api-key` instead).
- Base URL must NOT include `/v1`.
- Env vars are read at startup — export before launching `claude`.
- `ANTHROPIC_SMALL_FAST_MODEL` is deprecated; use `ANTHROPIC_DEFAULT_HAIKU_MODEL`.

---
*Verified against official docs 2026-08-12: [code.claude.com — LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect), [model config](https://code.claude.com/docs/en/model-config), [LiteLLM tutorial](https://docs.litellm.ai/docs/tutorials/claude_responses_api).*
