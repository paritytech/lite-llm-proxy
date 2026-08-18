# Cursor — partial support, read the caveats

**Works with the proxy:** ⚠️ chat/agent requests only, with real limitations
**Type:** Editor

## Configure

1. Cursor Settings > **Models** → scroll to **API Keys**
2. Paste your key into the **OpenAI API Key** field
3. Enable **Override OpenAI Base URL** → `https://llm.substrate.dev/v1`
4. Click **Verify** (sends a test completion through the proxy)
5. **Add model** → `<MODEL_NAME>`, enable it

## Switch models

Model dropdown in the chat/agent panel — custom-added names route to the overridden base URL.

## Caveats — know before relying on it

- **Only chat models use the proxy.** Tab completion, Apply, codebase indexing/embeddings, Bugbot, and background agents stay on Cursor's backend regardless.
- **Requests still route through Cursor's servers** for prompt building — the proxy must be reachable from the public internet.
- **The override is global, not per-model:** with it on, built-in Anthropic/other models can fail with 422s. Toggle it off to use them.
- Known open bug: image/vision attachments fail through a custom endpoint; text works.
- Cursor's Zero Data Retention policy does not apply when using your own keys.
- The override toggle has been removed from Cursor's official docs (it still exists in the app) — treat it as unofficial and subject to removal.

---
*Verified 2026-08-12: [cursor.com — API keys](https://cursor.com/docs/settings/api-keys) (official, BYOK limits), base-URL override confirmed via Cursor's official forum. Confidence medium.*
