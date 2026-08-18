# Not supported

These tools cannot use the proxy. Verified against official docs, August 2026.

## Gemini CLI ❌

Speaks only the Gemini-native API format (`generateContent`). `GOOGLE_GEMINI_BASE_URL` exists but does not translate protocols, so pointing it at an OpenAI-compatible endpoint fails. OpenAI-compat support is an unimplemented community proposal.

**Use instead:** [Qwen Code](qwen-code.md) — the Gemini CLI fork that adds exactly this.

## Amp (Sourcegraph) ❌

Removed BYOK entirely in May 2025 ("No More BYOK"), explicitly citing custom LLM proxies as a reason. Amp auto-routes among models it manages; there is no base-URL or API-key configuration. No workaround.

## Windsurf / Devin Desktop ❌

No custom endpoint or base-URL option anywhere in the product (rebranded from Windsurf to Devin Desktop, June 2026). The only BYOK is a personal Anthropic key sent directly to Anthropic — it cannot point at a proxy. Community reverse-proxy hacks exist but are unofficial and ToS-risky.

## Void ⚠️ works, but avoid

The final release supports OpenAI-compatible providers (Settings → Providers → OpenAI-Compatible → base URL `https://llm.substrate.dev/v1`), but the project was archived in June 2026 — no fixes or security updates. Prefer [Zed](zed.md).

---
*Sources: [gemini-cli config reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/configuration.md) · [ampcode.com/news/no-more-byok](https://ampcode.com/news/no-more-byok) · [docs.devin.ai/desktop/models](https://docs.devin.ai/desktop/models) · [github.com/voideditor/void](https://github.com/voideditor/void) (archived).*
