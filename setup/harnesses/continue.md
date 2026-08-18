# Continue

**Works with the proxy:** ✅
**Type:** VS Code / JetBrains extension · **Install:** marketplace → "Continue"
**Prereq:** `LLM_PROXY_KEY` exported (or paste the key directly) — see [README](../README.md).

## Configure

`~/.continue/config.yaml` (YAML is current; `config.json` is deprecated):

```yaml
name: Parity LLM Proxy
version: 0.0.1
schema: v1
models:
  - name: <MODEL_NAME> via proxy
    provider: openai
    model: <MODEL_NAME>
    apiBase: https://llm.substrate.dev/v1
    apiKey: ${{ secrets.LLM_PROXY_KEY }}   # resolves from ~/.continue/.env; pasting the sk-... value also works
    roles: [chat, edit, apply]
    capabilities: [tool_use]
```

## Switch models

Models with the `chat` role appear in the model dropdown in the chat input box.

## Gotchas

- `provider: openai` is correct — there is no separate "openai-compatible" provider name.
- `apiBase` must include `/v1`.
- Declare `capabilities: [tool_use]` explicitly — Continue can't auto-detect proxied model capabilities, and agent mode silently degrades without it.

---
*Verified against official docs 2026-08-12: [Continue — OpenAI provider](https://docs.continue.dev/customize/model-providers/top-level/openai), [configuration](https://docs.continue.dev/customize/deep-dives/configuration).*
