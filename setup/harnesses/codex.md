# Codex CLI

**Works with the proxy:** ✅ (via the proxy's `/v1/responses` bridge)
**Type:** CLI · **Install:** `npm install -g @openai/codex`
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

`~/.codex/config.toml`:

```toml
model = "<MODEL_NAME>"
model_provider = "parity-proxy"
model_context_window = 1048576              # real window; see the compaction gotcha
model_auto_compact_token_limit = 943718     # 90% of it — compact as late as allowed

[model_providers.parity-proxy]
name = "Parity LLM Proxy"
base_url = "https://llm.substrate.dev/v1"
env_key = "LLM_PROXY_KEY"
wire_api = "responses"
```

## Switch models

Top-level `model` in config.toml, or per-run `codex -m <MODEL_NAME>`. The `/model` TUI picker only lists built-in OpenAI models — custom-provider users use config/flag.

## Gotchas

- **400 mid-session, right after "Context automatically compacted"?** That is Codex calling OpenAI's `/responses/compact`, which LiteLLM doesn't implement (it 500s; Codex surfaces a 400 and the session dies). There is no switch to disable remote compaction ([openai/codex#24418](https://github.com/openai/codex/issues/24418)), so the mitigation is to compact as rarely as possible: set `model_context_window` to the model's real window and `model_auto_compact_token_limit` to 90% of it (higher is reported to be ignored, [openai/codex#11716](https://github.com/openai/codex/issues/11716)). Without these Codex assumes a small default window and compacts within minutes. The setup script writes both automatically. This delays the failure rather than removing it — a session long enough to actually hit the threshold still breaks.
- **These two keys are global.** Codex 0.157.0 removed both ways to scope them (`profile = "name"` is rejected; profiles now need a separate file and `--profile` on every run), so they apply to whatever model Codex is pointed at. `setup.sh cleanup` restores your original config, but if you instead switch `model`/`model_provider` back by hand, update or delete these too — a 1M window left on a 272k model means Codex compacts far too late. Both lines carry an `# llm-proxy setup:` comment so they're easy to spot.
- `wire_api = "responses"` is required — current Codex builds dropped the chat-completions wire (`"chat"` only works on very old pinned versions; don't rely on it).
- `env_key` means the key is read from your shell env — `LLM_PROXY_KEY` must be exported where you run `codex`.
- No ChatGPT login needed with a custom provider.

---
*Verified against official docs 2026-09-25: [Codex config reference](https://learn.chatgpt.com/docs/config-file/config-reference), [LiteLLM Codex tutorial](https://docs.litellm.ai/docs/tutorials/openai_codex).*
