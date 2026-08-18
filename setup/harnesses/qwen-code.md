# Qwen Code

**Works with the proxy:** ✅ (this is the Gemini CLI fork with OpenAI-compat support — use it where Gemini CLI can't)
**Type:** CLI · **Install:** `npm install -g @qwen-code/qwen-code`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.qwen/.env`:

```bash
OPENAI_API_KEY=$LLM_PROXY_KEY
OPENAI_BASE_URL=https://llm.substrate.dev/v1
OPENAI_MODEL=<MODEL_NAME>
```

On first run choose the **OpenAI** auth type (or `/auth`), not Qwen OAuth.

## Switch models

`OPENAI_MODEL` sets the default; `/model` in-session. Optionally register models under `modelProviders` in `~/.qwen/settings.json` to populate the picker.

## Gotchas

- `/v1` must be appended to the base URL.
- Qwen Code walks up from the cwd looking for `.env` files — a project `.env` with its own `OPENAI_*` values silently overrides your setup.
- Keep the key in `~/.qwen/.env`, not `settings.json`.

---
*Verified against official docs 2026-08-13: [model providers](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/model-providers/), [auth](https://qwenlm.github.io/qwen-code-docs/en/users/configuration/auth/).*
