# Roo Code

**Works with the proxy:** ✅ — but the model **must support native function calling** (see gotchas)
**Type:** VS Code extension · **Install:** VS Code marketplace → "Roo Code"

## Configure

1. Roo Code sidebar → ⚙️ Settings → Providers
2. **API Provider:** `OpenAI Compatible`
3. **Base URL:** `https://llm.substrate.dev/v1`
4. **API Key:** paste your key
5. **Model:** `<MODEL_NAME>`, then set Context Window and Max Output Tokens manually under Model Configuration

## Switch models

Create one Configuration Profile per model and switch via the dropdown at the bottom of the chat input. Roo can populate the model list from the proxy's `/v1/models`.

## Gotchas

- **Current Roo Code requires native OpenAI-style tool calling — there is no XML fallback.** If the model behind the proxy doesn't serve function calls, every task fails. This is the most common failure mode; report it if you hit it (it's a proxy-side vLLM setting, not your config).
- Wrong context window causes silent truncation — set it manually.

---
*Verified against official docs 2026-08-12: [Roo Code — OpenAI Compatible](https://docs.roocode.com/providers/openai-compatible).*
