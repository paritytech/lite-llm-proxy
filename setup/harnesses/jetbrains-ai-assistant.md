# JetBrains AI Assistant

**Works with the proxy:** ✅ (official "OpenAI-compatible endpoints" provider — LiteLLM is named in their docs)
**Type:** IDE plugin (IntelliJ, PyCharm, etc.)

## Configure

1. **Settings | Tools | AI Assistant | Providers & API keys**
2. Under **Third-party AI providers**, enable **OpenAI-compatible**
3. URL: `https://llm.substrate.dev/v1` · API Key: paste your key
4. Toggle **Tool calling** on (needed for MCP tools through the proxy)
5. Click **Test Connection**, then Apply

## Switch models

AI Chat → model selector — the proxy's models appear (served from `/v1/models`). Under **Models Assignment** you can pin custom models to "core", "lightweight", and "code completion" roles.

## Gotchas

- With an active JetBrains AI subscription, features the custom model can't serve **silently fall back to JetBrains-hosted models** — check proxy logs if strict routing matters.
- Junie (the coding agent) and next-edit suggestions still require JetBrains' cloud models.
- Code completion via a custom endpoint needs its own Models Assignment entry and isn't guaranteed for all models.

---
*Verified against official docs 2026-08-12: [JetBrains — custom models](https://www.jetbrains.com/help/ai-assistant/use-custom-models.html), [supported LLMs](https://www.jetbrains.com/help/ai-assistant/supported-llms.html).*
