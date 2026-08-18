# OpenCode

**Works with the proxy:** ✅
**Type:** CLI/TUI · **Install:** `curl -fsSL https://opencode.ai/install | bash` (or npm/brew — see [opencode.ai](https://opencode.ai))
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "parity-proxy": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Parity LLM Proxy",
      "options": {
        "baseURL": "https://llm.substrate.dev/v1",
        "apiKey": "{env:LLM_PROXY_KEY}"
      },
      "models": {
        "<MODEL_NAME>": { "name": "<MODEL_NAME>" }
      }
    }
  },
  "model": "parity-proxy/<MODEL_NAME>"
}
```

## Switch models

Top-level `"model"` sets the default; `/models` in the TUI to switch.

## Gotchas

- `baseURL` must include `/v1` (the AI SDK appends `/chat/completions` to it).
- Model IDs in the `models` map must exactly match what the proxy serves (`curl .../v1/models`).

---
*Verified against official docs 2026-08-12: [opencode.ai/docs/providers](https://opencode.ai/docs/providers/), [config](https://opencode.ai/docs/config/).*
