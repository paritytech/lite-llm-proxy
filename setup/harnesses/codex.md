# Codex CLI

**Works with the proxy:** ✅ (via the proxy's `/v1/responses` bridge)
**Type:** CLI · **Install:** `npm install -g @openai/codex`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.codex/config.toml`:

```toml
model = "<MODEL_NAME>"
model_provider = "parity-proxy"

[model_providers.parity-proxy]
name = "Parity LLM Proxy"
base_url = "https://llm.substrate.dev/v1"
env_key = "LLM_PROXY_KEY"
wire_api = "responses"
```

## Switch models

Top-level `model` in config.toml, or per-run `codex -m <MODEL_NAME>`. The `/model` TUI picker only lists built-in OpenAI models — custom-provider users use config/flag.

## Gotchas

- `wire_api = "responses"` is required — current Codex builds dropped the chat-completions wire (`"chat"` only works on very old pinned versions; don't rely on it).
- `env_key` means the key is read from your shell env — `LLM_PROXY_KEY` must be exported where you run `codex`.
- No ChatGPT login needed with a custom provider.

---
*Verified against official docs 2026-08-12: [Codex config reference](https://developers.openai.com/codex/config-reference), [LiteLLM Codex tutorial](https://docs.litellm.ai/docs/tutorials/openai_codex).*
