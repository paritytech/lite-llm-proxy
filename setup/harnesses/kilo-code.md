# Kilo Code

**Works with the proxy:** ✅ (Custom provider with "OpenAI Compatible" API)
**Type:** VS Code extension · **Install:** VS Code marketplace → "Kilo Code"

## Configure

1. ⚙️ Settings → **Providers** tab → scroll to bottom → **Custom provider**
2. Provider ID: `parity-proxy` · Display name: `Parity LLM Proxy`
3. **Provider API:** `OpenAI Compatible`
4. **Base URL:** `https://llm.substrate.dev/v1` · **API key:** paste your key
5. **Models:** pick `<MODEL_NAME>` from the auto-fetched list (Kilo queries `/v1/models`)

## Switch models

Model selector in the chat UI (searchable). If auto-detection fails, enter the model ID manually.

## Gotchas

- Docs/product moved from kilocode.ai to kilo.ai — old links redirect.
- Context window and token limits are edited in `kilo.jsonc`, not the UI.
- The optional custom Headers field is handy if we later add LiteLLM tags.

---
*Verified against official docs 2026-08-12: [kilo.ai — OpenAI Compatible](https://kilo.ai/docs/providers/openai-compatible).*
