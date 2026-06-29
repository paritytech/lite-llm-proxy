# Team LLM Proxy

Shared, budgeted access to **Kimi (Moonshot AI)** for Parity teammates via a self-hosted
[LiteLLM](https://docs.litellm.ai) proxy. OpenAI-compatible API over HTTPS.

- **Base URL:** `https://llm.195-154-218-5.sslip.io`  *(will move to a `*.substrate.dev` host — see below)*
- **Model:** `kimi-k2`
- **Auth:** your personal virtual key (`sk-...`), issued by the admin. Keep it secret; it carries your budget.

## Use it from code (OpenAI SDK)

```python
from openai import OpenAI
client = OpenAI(base_url="https://llm.195-154-218-5.sslip.io", api_key="sk-YOUR-KEY")
resp = client.chat.completions.create(
    model="kimi-k2",
    messages=[{"role": "user", "content": "Hello!"}],
)
print(resp.choices[0].message.content)
```

## Use it from the shell / CI

```bash
curl https://llm.195-154-218-5.sslip.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"kimi-k2","messages":[{"role":"user","content":"Hello!"}]}'
```
In CI, store your key as a secret named `LLM_KEY` (or similar) — never commit it.

## Budgets & limits

Each key has a monthly `max_budget` and an rpm cap. When you hit your budget, requests are
rejected until the 30-day window resets. Ask the admin to raise it if you need more.

## Admin (operator only)

- Admin UI: `https://llm.195-154-218-5.sslip.io/ui` (log in with the master key).
- Mint a key: `POST /key/generate` with `models`, `max_budget`, `budget_duration`, `rpm_limit`, `user_id`.
- Revoke a key: `POST /key/delete`.
- Usage: `GET /key/info?key=...` or the UI.

## Hostname migration

The base URL will change from the temporary `sslip.io` host to a `*.substrate.dev` subdomain
(DevOps ticket #5421). **Your key keeps working** — only the base URL changes. The new URL will
be announced before the cutover.
