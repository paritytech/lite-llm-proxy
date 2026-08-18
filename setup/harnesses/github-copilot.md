# GitHub Copilot (BYOK)

**Works with the proxy:** ✅ chat only — inline completions and embeddings stay on Copilot's own models
**Type:** VS Code (built-in Copilot Chat) · **Prereq:** signed-in GitHub account; on Business/Enterprise the org admin must leave the BYOK policy enabled

## Configure

1. Command Palette → `Chat: Manage Language Models`
2. **Add Models** → choose the **Custom Endpoint** provider
3. Endpoint URL: `https://llm.substrate.dev/v1` · API type: `Chat Completions` (or `Anthropic Messages API` to use the proxy's `/v1/messages`)
4. API key: paste your key; add model ID `<MODEL_NAME>` and a group name
5. Fine-tune capabilities per model in `chatLanguageModels.json` if agent features are missing

## Switch models

The model appears in the Chat view's model picker under its group name.

## Gotchas

- BYOK covers **chat/agent only** — never Tab completions or codebase indexing.
- The Custom Endpoint provider shipped mid-2026 — update VS Code if you don't see it.
- Declare tool-calling capability per model or agent mode features get disabled.
- Usage bills to the proxy, not your Copilot quota.

---
*Verified against official docs 2026-08-12: [VS Code — language models](https://code.visualstudio.com/docs/copilot/customization/language-models), [GitHub changelog — BYOK](https://github.blog/changelog/2026-04-22-bring-your-own-language-model-key-in-vs-code-now-available/).*
