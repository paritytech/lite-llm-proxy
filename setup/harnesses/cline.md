# Cline

**Works with the proxy:** ✅ (dedicated "OpenAI Compatible" provider)
**Type:** VS Code extension · **Install:** VS Code marketplace → "Cline"

## Configure

1. Cline sidebar → ⚙️ (or the model name under the chat box) → API Configuration
2. **API Provider:** `OpenAI Compatible`
3. **Base URL:** `https://llm.substrate.dev/v1` — never the full `/chat/completions` path
4. **API Key:** paste your key (the UI stores it; it doesn't read env vars)
5. **Model:** `<MODEL_NAME>`, then expand **Model Configuration** and set Context Window (128000) and Max Output Tokens (16384) manually — defaults may silently truncate context

## Switch models

Save multiple provider profiles and switch via the selector under the chat input. Plan/Act modes can use different models (settings).

## Gotchas

- Verification failures are almost always Base URL first, then key, then Model ID — check in that order.
- Leave "Use Azure Identity Authentication" off.

---
*Verified against official docs 2026-08-12: [docs.cline.bot — OpenAI Compatible](https://docs.cline.bot/provider-config/openai-compatible).*
