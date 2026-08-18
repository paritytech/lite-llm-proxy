# Pi

**Works with the proxy:** ✅
**Type:** CLI · **Install:** `npm install -g @earendil-works/pi-coding-agent` (repo moved from badlogic/pi-mono to earendil-works/pi; old links redirect)
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.pi/agent/models.json`:

```json
{
  "providers": {
    "parity-proxy": {
      "baseUrl": "https://llm.substrate.dev/v1",
      "api": "openai-completions",
      "apiKey": "$LLM_PROXY_KEY",
      "models": [
        {
          "id": "<MODEL_NAME>",
          "name": "<MODEL_NAME>",
          "input": ["text"]
        }
      ]
    }
  }
}
```

## Switch models

`pi --model parity-proxy/<MODEL_NAME>`, or `/model` in the TUI — models.json is re-read every time the picker opens, so edits apply without restart.

## Gotchas

- `"apiKey": "$LLM_PROXY_KEY"` is env-var-reference syntax (not `{env:...}`) — the var must be exported.
- `api` must be `"openai-completions"` for this proxy (`"anthropic-messages"` also works against `/v1/messages` if preferred).
- Old versions had a hang bug with custom providers — `npm update -g` and smoke-test one prompt before relying on it.

---
*Verified against official repo docs 2026-08-12: [models.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/models.md), [custom-provider.md](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/custom-provider.md). Confidence medium — recent repo rename; verify in the Friday dry run.*
