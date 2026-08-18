# Aider

**Works with the proxy:** ✅
**Type:** CLI · **Install:** `python -m pip install aider-install && aider-install`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

```bash
export OPENAI_API_BASE=https://llm.substrate.dev/v1
export OPENAI_API_KEY=$LLM_PROXY_KEY
aider --model openai/<MODEL_NAME>
```

## Switch models

`--model openai/<MODEL_NAME>` at launch, or `/model openai/<MODEL_NAME>` in the chat.

## Gotchas

- The `openai/` prefix on the model name is **mandatory** (routes through Aider's LiteLLM client).
- Include `/v1` in the base URL.
- A "model warnings" notice about unknown context window/cost is cosmetic; silence it by adding an entry to `.aider.model.metadata.json` if it bothers you.

---
*Verified against official docs 2026-08-13: [aider.chat — OpenAI-compatible APIs](https://aider.chat/docs/llms/openai-compat.html).*
