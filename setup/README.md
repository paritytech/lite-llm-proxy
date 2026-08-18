# LLM Proxy — Setup Guides

Connect your coding harness to the LLM proxy in ~5 minutes.

The proxy lives at `https://llm.substrate.dev`. Snippets use one placeholder: `<MODEL_NAME>` — browse [openrouter.ai/models](https://openrouter.ai/models) and use the id with an `openrouter/` prefix, e.g. `openrouter/deepseek/deepseek-chat`.

Don't set temperature/reasoning options in your harness config: the self-hosted models (`*-parity`) are preconfigured server-side for agentic workloads with max thinking. The `*-openrouter` variants don't carry those defaults, so the same model can behave slightly differently there.

## 1. Get an API key

To get your API key, ping [**Utkarsh Bhardwaj**](https://matrix.to/#/@utkarsh:parity.io) on Element — he'll issue you a personal key.

Export the key once (add to `~/.zshrc` or `~/.bashrc`) — every guide below assumes this:

```bash
export LLM_PROXY_KEY="sk-..."
```

The proxy speaks both OpenAI format (`/v1/chat/completions`) and Anthropic format (`/v1/messages`). Sanity-check your key and see the available model names:

```bash
curl https://llm.substrate.dev/v1/models -H "Authorization: Bearer $LLM_PROXY_KEY"
```

## 2. Configure your harness

One command — asks for your key and model, then configures Claude Code, OpenCode, Codex, Pi, and generic `OPENAI_*` env vars. Run it whichever way you prefer:

**curl** (needs the repo to be public or a token — while it's private, use one of the other two):

```bash
curl -fsSL https://raw.githubusercontent.com/paritytech/lite-llm-proxy/main/setup/setup.sh | bash
```

**GitHub CLI** (works today for anyone with access to this repo):

```bash
gh api repos/paritytech/lite-llm-proxy/contents/setup/setup.sh -H "Accept: application/vnd.github.raw" | bash
```

**From a clone:**

```bash
git clone git@github.com:paritytech/lite-llm-proxy.git && ./lite-llm-proxy/setup/setup.sh
```

Re-run the same command anytime to add more harnesses or change the model. To undo everything it wrote, append `-s -- cleanup` to a piped variant, or run `./lite-llm-proxy/setup/setup.sh cleanup` from a clone.

Or set up manually — primary four:

| Harness | Guide |
|---|---|
| Claude Code | [harnesses/claude-code.md](harnesses/claude-code.md) |
| OpenCode | [harnesses/opencode.md](harnesses/opencode.md) |
| Codex CLI | [harnesses/codex.md](harnesses/codex.md) |
| Pi | [harnesses/pi.md](harnesses/pi.md) |

All others:

| Harness | Type | Proxy support | Guide |
|---|---|---|---|
| Aider | CLI | ✅ | [aider.md](harnesses/aider.md) |
| Goose | CLI | ✅ | [goose.md](harnesses/goose.md) |
| Crush | CLI | ✅ | [crush.md](harnesses/crush.md) |
| Qwen Code | CLI | ✅ | [qwen-code.md](harnesses/qwen-code.md) |
| Factory Droid | CLI | ✅ | [factory-droid.md](harnesses/factory-droid.md) |
| OpenHands | CLI/Docker | ✅ | [openhands.md](harnesses/openhands.md) |
| Cline | VS Code | ✅ | [cline.md](harnesses/cline.md) |
| Roo Code | VS Code | ✅ | [roo-code.md](harnesses/roo-code.md) |
| Kilo Code | VS Code | ✅ | [kilo-code.md](harnesses/kilo-code.md) |
| Continue | VS Code/JetBrains | ✅ | [continue.md](harnesses/continue.md) |
| GitHub Copilot | VS Code | ✅ chat only | [github-copilot.md](harnesses/github-copilot.md) |
| Zed | Editor | ✅ | [zed.md](harnesses/zed.md) |
| JetBrains AI Assistant | IDE | ✅ | [jetbrains-ai-assistant.md](harnesses/jetbrains-ai-assistant.md) |
| Cursor | Editor | ⚠️ chat only, caveats | [cursor.md](harnesses/cursor.md) |
| avante.nvim | Neovim | ✅ | [avante-nvim.md](harnesses/avante-nvim.md) |
| codecompanion.nvim | Neovim | ✅ | [codecompanion-nvim.md](harnesses/codecompanion-nvim.md) |
| gptel | Emacs | ✅ | [gptel.md](harnesses/gptel.md) |
| Gemini CLI, Amp, Windsurf, Void | — | ❌ | [not-supported.md](harnesses/not-supported.md) |

Using something not listed? Most tools accept the generic OpenAI convention:

```bash
export OPENAI_BASE_URL=https://llm.substrate.dev/v1   # some tools call it OPENAI_API_BASE
export OPENAI_API_KEY=$LLM_PROXY_KEY
```

## Usage policy

No heavy unattended loops, please — capacity is shared, and we rely on policy rather than rate limits.

## Feedback

After each real session, fill in [the feedback form](https://forms.gle/GJJaC8AmZE4D9Px86).

## Troubleshooting

- `401` → key not exported or mistyped: `echo $LLM_PROXY_KEY` should print your key. Claude Code specifically: use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`.
- Tool-calling errors in agent modes → the model must support native function calling; report it, that's a proxy-side setting.
- Timeouts or anything else → contact the proxy admin.
