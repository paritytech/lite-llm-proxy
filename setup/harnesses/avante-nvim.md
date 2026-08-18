# avante.nvim

**Works with the proxy:** ✅ (custom provider inheriting from `openai`)
**Type:** Neovim plugin
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

```lua
require("avante").setup({
  provider = "litellm",
  providers = {
    litellm = {
      __inherited_from = "openai",
      endpoint = "https://llm.substrate.dev/v1",
      model = "<MODEL_NAME>",
      api_key_name = "LLM_PROXY_KEY", -- env var NAME, not the key itself
      -- no temperature/max_tokens: the proxy's models are pretuned server-side
    },
  },
})
```

## Switch models

`:AvanteSwitchProvider` to switch providers, `:AvanteModels` to list/pick models.

## Gotchas

- Provider settings must live under the `providers` table — the old top-level `openai = {...}` style is deprecated, and `temperature`/`max_tokens` must go inside `extra_request_body`.
- Include `/v1` in the endpoint.
- Add `disable_tools = true` if the model lacks function calling, otherwise requests can fail.

---
*Verified against official wiki 2026-08-13: [custom providers](https://github.com/yetone/avante.nvim/wiki/Custom-providers), [migration guide](https://github.com/yetone/avante.nvim/wiki/Provider-configuration-migration-guide).*
