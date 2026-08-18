# codecompanion.nvim

**Works with the proxy:** ✅ (first-class `openai_compatible` adapter)
**Type:** Neovim plugin
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

```lua
require("codecompanion").setup({
  adapters = {
    http = {
      litellm = function()
        return require("codecompanion.adapters").extend("openai_compatible", {
          env = {
            url = "https://llm.substrate.dev", -- NO /v1 here: the adapter appends chat_url
            api_key = "LLM_PROXY_KEY",           -- env var NAME
            chat_url = "/v1/chat/completions",
            models_endpoint = "/v1/models",
          },
          schema = {
            model = { default = "<MODEL_NAME>" },
          },
        })
      end,
    },
  },
  interactions = {
    chat = { adapter = "litellm" },
    inline = { adapter = "litellm" },
  },
})
```

## Switch models

`ga` in the chat buffer opens the adapter/model picker (models come from the proxy's `/v1/models`). Set `display.chat.show_settings = true` to edit the model inline.

## Gotchas

- Putting `/v1` in `env.url` produces `/v1/v1/` — the #1 mistake.
- The default-adapter key is `interactions` — snippets from pre-2026 blog posts use the deprecated `strategies` key and silently don't apply.
- Plain strings in `env` are resolved as env var names (`cmd:`/`file:` prefixes also work).

---
*Verified against official docs 2026-08-13: [HTTP adapters](https://codecompanion.olimorris.dev/configuration/adapters-http), [chat buffer](https://codecompanion.olimorris.dev/usage/chat-buffer/).*
