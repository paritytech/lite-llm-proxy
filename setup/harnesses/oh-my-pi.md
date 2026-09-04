# oh-my-pi

**Works with the proxy:** ✅ (native `litellm` provider — models are discovered, not listed by hand)
**Type:** CLI · **Install:** see [omp.sh](https://omp.sh) ([can1357/oh-my-pi](https://github.com/can1357/oh-my-pi))
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

Not the same tool as [Pi](pi.md) (`earendil-works/pi`), and it does not read Pi's `~/.pi/agent/models.json`.

## Configure

Two env vars are the whole configuration:

```bash
export LITELLM_API_KEY="$LLM_PROXY_KEY"
export LITELLM_BASE_URL="https://llm.substrate.dev/v1"
omp
```

oh-my-pi then queries the proxy for its model list at startup, so every alias the proxy serves shows up with its real context window — no per-model config.

Prefer a config file, or need a second gateway alongside the default one? `~/.omp/agent/models.yml`:

```yaml
providers:
  parity-proxy:
    baseUrl: https://llm.substrate.dev/v1
    apiKey: LITELLM_API_KEY
    api: openai-completions
    discovery:
      type: litellm
```

## Switch models

The [setup script](../README.md) writes your chosen model as the default (below), so plain `omp` already uses it — `--model litellm/<MODEL_NAME>` per launch overrides it for one session, or `/models` in the TUI. To set the default yourself, in `~/.omp/agent/config.yml`:

```yaml
modelRoles:
  default: litellm/<MODEL_NAME>
```

## Gotchas

- `LITELLM_BASE_URL` must include `/v1`; without it oh-my-pi falls back to `http://localhost:4000/v1`.
- Discovery needs the key to read one of LiteLLM's model-info routes. Ours may (verified 2026-09-03); if a future key policy blocks them, discovery still falls back to `/v1/models`, just without context/pricing metadata.
- `LITELLM_*` is a generic name: if you also run another LiteLLM gateway, configure both through `models.yml` instead of env vars.

---
*Verified against the proxy and upstream docs 2026-09-03: [providers.md](https://github.com/can1357/oh-my-pi/blob/main/docs/providers.md), [models.md](https://github.com/can1357/oh-my-pi/blob/main/docs/models.md), [environment-variables.md](https://github.com/can1357/oh-my-pi/blob/main/docs/environment-variables.md).*
