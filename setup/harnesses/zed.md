# Zed

**Works with the proxy:** ✅ (first-class `openai_compatible` provider)
**Type:** Editor · **Install:** [zed.dev](https://zed.dev)

## Configure

`settings.json` (`zed: open settings`):

```json
{
  "language_models": {
    "openai_compatible": {
      "parity_proxy": {
        "api_url": "https://llm.substrate.dev/v1",
        "available_models": [
          {
            "name": "<MODEL_NAME>",
            "display_name": "<MODEL_NAME> (proxy)",
            "max_tokens": 128000
          }
        ]
      }
    }
  }
}
```

Supply the key via the env var named after the provider ID — `export PARITY_PROXY_API_KEY="$LLM_PROXY_KEY"` — or paste it in the provider's settings UI. **Never put the key in settings.json.**

## Switch models

Agent Panel model dropdown, under the `parity_proxy` provider section.

## Gotchas

- Models default to `tools: true, images: false`; add a `capabilities` object per model to adjust.
- Zed's Edit Prediction (Zeta) and hosted "Zed AI" plans don't use custom providers — only the Agent Panel and inline assist do.

---
*Verified against official docs 2026-08-12: [zed.dev — API access](https://zed.dev/docs/ai/use-api-access), [agent settings](https://zed.dev/docs/ai/agent-settings).*
