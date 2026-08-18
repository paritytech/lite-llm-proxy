# Factory Droid

**Works with the proxy:** ✅ (official BYOK "Custom Models")
**Type:** CLI · **Install:** `curl -fsSL https://app.factory.ai/cli | sh`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.factory/settings.json`:

```json
{
  "customModels": [
    {
      "model": "<MODEL_NAME>",
      "displayName": "<MODEL_NAME>",
      "baseUrl": "https://llm.substrate.dev/v1",
      "apiKey": "${LLM_PROXY_KEY}",
      "provider": "generic-chat-completion-api"
    }
  ]
}
```

## Switch models

`/model` inside droid — custom models appear in their own "Custom models" section below the Factory-provided ones.

## Gotchas

- Use `provider: "generic-chat-completion-api"` (the `openai`/`anthropic` values are meant for those official APIs).
- Use `settings.json` (camelCase, env-var expansion) — the legacy `config.json` (snake_case) lacks env expansion and is overridden by settings.json.
- Custom models are CLI-only; they won't appear in Factory's web/mobile apps.

---
*Verified against official docs 2026-08-13: [Factory BYOK overview](https://docs.factory.ai/cli/byok/overview).*
