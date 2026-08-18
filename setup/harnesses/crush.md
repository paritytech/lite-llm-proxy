# Crush

**Works with the proxy:** ✅
**Type:** CLI/TUI · **Install:** `brew install charmbracelet/tap/crush` (or npm/go — see [github.com/charmbracelet/crush](https://github.com/charmbracelet/crush))
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

Add to `~/.config/crush/crushrc` (current Bash-based format; the older `crush.json` still works but is deprecated):

```bash
provider add litellm --type openai-compat \
  --base-url "https://llm.substrate.dev/v1" \
  --api-key "$LLM_PROXY_KEY"

model add litellm/<MODEL_NAME> \
  --name "<MODEL_NAME>" \
  --context-window 128000 \
  --default-max-tokens 8192
```

## Switch models

`ctrl+l` in the TUI opens the model picker.

## Gotchas

- Type must be `openai-compat`, not `openai` (that's only for actual OpenAI routing).
- Models must be registered explicitly with context-window metadata — no auto-discovery from `/v1/models` yet.
- `crushrc` is executed as real shell code, and project-local `./.crushrc` files are picked up — review them before launching in unfamiliar repos.

---
*Verified against official README 2026-08-13: [github.com/charmbracelet/crush](https://github.com/charmbracelet/crush).*
