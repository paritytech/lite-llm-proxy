# Goose

**Works with the proxy:** ✅ (has a dedicated LiteLLM provider)
**Type:** CLI · **Install:** see [goose-docs.ai](https://goose-docs.ai) (project moved from block/goose to aaif-goose/goose)
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

Use the dedicated LiteLLM provider:

```bash
export GOOSE_PROVIDER=litellm
export GOOSE_MODEL=<MODEL_NAME>
export LITELLM_HOST=https://llm.substrate.dev    # root URL, no /v1
export LITELLM_API_KEY=$LLM_PROXY_KEY
goose
```

Alternative via the generic OpenAI provider: `GOOSE_PROVIDER=openai`, `OPENAI_HOST=https://llm.substrate.dev` (root, no `/v1` — the path comes from `OPENAI_BASE_PATH`, default `v1/chat/completions`), `OPENAI_API_KEY=$LLM_PROXY_KEY`. Pick one set of vars, don't mix.

## Switch models

`GOOSE_MODEL` env var, or the `providers:` block in `~/.config/goose/config.yaml`. The `goose configure` picker doesn't accept arbitrary custom model names — set the env var directly.

## Gotchas

- **Do not put the API key in `config.yaml`** — it's ignored there and you get `401 No api key passed in`. Keys must come from env vars or the keychain.
- `LITELLM_HOST`/`OPENAI_HOST` take the root URL; a 404 usually means `/v1` was wrongly appended.

---
*Verified against official docs 2026-08-13: [providers](https://goose-docs.ai/docs/getting-started/providers/), [config files guide](https://github.com/aaif-goose/goose/blob/main/documentation/docs/guides/config-files.md).*
