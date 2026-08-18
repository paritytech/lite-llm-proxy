# OpenHands

**Works with the proxy:** ✅ (OpenHands uses LiteLLM internally and documents LiteLLM proxies explicitly)
**Type:** CLI / Docker app · **Install:** see [docs.openhands.dev](https://docs.openhands.dev)
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

GUI: Settings > LLM tab > enable **Advanced**:

```
Custom Model: litellm_proxy/<MODEL_NAME>
Base URL:     https://llm.substrate.dev        (no /v1)
API Key:      <value of $LLM_PROXY_KEY>
```

Docker / headless:

```bash
docker run -it \
  -e LLM_MODEL="litellm_proxy/<MODEL_NAME>" \
  -e LLM_BASE_URL="https://llm.substrate.dev" \
  -e LLM_API_KEY="$LLM_PROXY_KEY" \
  ... openhands/openhands
```

## Switch models

Change the Custom Model field / `LLM_MODEL` var — any model the proxy serves works.

## Gotchas

- The `litellm_proxy/` model prefix is required — it makes OpenHands pass the model name through verbatim so the proxy resolves it. Don't use `openai/`.
- Base URL takes **no** `/v1`.
- The interactive CLI reads `~/.openhands/settings.json` and ignores env vars unless you pass `--override-with-envs`.

---
*Verified against official docs 2026-08-13: [LiteLLM proxy guide](https://docs.openhands.dev/openhands/usage/llms/litellm-proxy), [env vars](https://docs.openhands.dev/openhands/usage/environment-variables).*
