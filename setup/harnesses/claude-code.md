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
exec claude "$@"
```

Every tier is pinned because Claude Code switches tiers on its own (plan mode, background tasks) and would otherwise send `claude-*` names the proxy doesn't serve.

## Switch models

`parity-claude --model <MODEL_NAME>` overrides the model for one session. Prefer it over `/model` for switching: `/model` saves the pick as your default in the shared `~/.claude.json`, and your next plain `claude` session would then send a proxy model name to the real Anthropic API.

## Gotchas

- **401?** Use `ANTHROPIC_AUTH_TOKEN` (Bearer header — what the proxy reads), not `ANTHROPIC_API_KEY` (sends `x-api-key` instead).
- Base URL must NOT include `/v1`.
- `ANTHROPIC_SMALL_FAST_MODEL` is deprecated; use `ANTHROPIC_DEFAULT_HAIKU_MODEL`.
- Hard isolation, if the shared `~/.claude.json` ever bites: add `export CLAUDE_CONFIG_DIR="$HOME/.llm-proxy/claude"` to the wrapper. Proxy sessions then keep their own saved defaults and settings.

---
*Wrapper verified end-to-end 2026-08-20. Env vars verified against official docs 2026-08-12: [code.claude.com — LLM gateway](https://code.claude.com/docs/en/llm-gateway-connect), [model config](https://code.claude.com/docs/en/model-config), [LiteLLM tutorial](https://docs.litellm.ai/docs/tutorials/claude_responses_api).*
