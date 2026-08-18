# gptel (Emacs)

**Works with the proxy:** ✅ (`gptel-make-openai` registers any OpenAI-compatible backend)
**Type:** Emacs package
**Prereq:** `LLM_PROXY_KEY` exported — see [README](../README.md).

## Configure

```elisp
(setq gptel-backend
      (gptel-make-openai "Parity-Proxy"
        :host "llm.substrate.dev"          ;; bare host — no https://, no /v1
        :protocol "https"
        :endpoint "/v1/chat/completions"
        :stream t
        :key (lambda () (getenv "LLM_PROXY_KEY"))
        :models '(<MODEL_NAME>))
      gptel-model '<MODEL_NAME>)
```

## Switch models

`M-x gptel-menu` — the transient menu lists every model from every registered backend.

## Gotchas

- `:host` takes the bare host; the scheme goes in `:protocol` and the path in `:endpoint`.
- gptel does **not** auto-query `/v1/models` — only models listed in `:models` appear in the picker, so list every alias you want.
- The `:key` lambda keeps the key out of your config; a plain string also works.

---
*Verified against official manual 2026-08-13: [gptel.org/manual](https://gptel.org/manual.html), [github.com/karthink/gptel](https://github.com/karthink/gptel).*
