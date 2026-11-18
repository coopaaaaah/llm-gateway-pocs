# LiteLLM proxy

[LiteLLM](https://github.com/BerriAI/litellm) is a Python proxy with an OpenAI-compatible API in
front of 100+ providers. It has the most features of the candidates and serves as the baseline the
others are measured against.

```bash
./gateway.sh litellm up      # litellm + postgres + otel-collector, then init.sh creates the limited key
./gateway.sh litellm smoke
./gateway.sh litellm ratelimit
```

- API: http://localhost:4000/v1 (OpenAI format), auth `Authorization: Bearer $LITELLM_MASTER_KEY`
- Admin UI: http://localhost:4000/ui (log in with the master key)
- Models: `sonnet` and `haiku`, mapped to the Bedrock IDs in `.env`

## How each proof is wired

| Proof | Where |
|---|---|
| Streaming | Native. `request_timeout: 600` in `config.yaml` so long generations aren't cut off |
| Guardrail | `canary_guardrail.py`, a `CustomGuardrail` registered under `guardrails:` with `default_on: true`. It checks the request (pre-call), full responses (post-call) and streamed chunks, keeping a rolling tail so a canary split across chunks is still caught |
| Rate limit | `init.sh` creates the virtual key `sk-litellm-poc-limited` with `rpm_limit: 3` (needs Postgres) |
| OTel | `callbacks: ["otel"]` with `OTEL_EXPORTER=otlp_http` pointed at the shared collector |

## Files

- `compose.yaml`: LiteLLM, Postgres (virtual keys and spend), and the shared collector
- `config.yaml`: model list, guardrail registration, master key and DB
- `canary_guardrail.py`: the guardrail hook
- `init.sh`: creates the rate-limited key after startup
- `smoke.env`: what `gateway.sh` sends

## Notes and open questions

- **Supply chain.** This is the main concern with LiteLLM: a large dependency tree and recurring
  advisories. Pin the image by digest before any shared deployment and scan it as part of the evaluation.
- The image tag defaults to `v1.110.0` and can be overridden with `LITELLM_IMAGE_TAG` in `.env`.
- Several features (SSO, some guardrail integrations, audit logs) live under LiteLLM's enterprise
  license. Everything used here is in the MIT core.
- Rate limits are per proxy instance unless Redis is configured. Add Redis before running more than one replica.
