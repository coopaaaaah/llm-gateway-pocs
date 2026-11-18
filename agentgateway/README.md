# agentgateway

[agentgateway](https://github.com/agentgateway/agentgateway) is a Rust proxy for LLM, MCP and A2A
traffic, hosted by the Linux Foundation. It runs as a standalone binary or container from one YAML
file, or on Kubernetes through the Gateway API.

```bash
./gateway.sh agentgateway up      # agentgateway + envoy ratelimit server + redis + otel-collector
./gateway.sh agentgateway smoke
./gateway.sh agentgateway ratelimit
```

- API: http://localhost:4001/v1 (OpenAI format) and `/v1/messages` (Anthropic format), auth `Authorization: Bearer sk-agw-poc`
- Models: `sonnet` and `haiku`
- Host port 4001 maps to the container's 4000, so it can run next to LiteLLM

## How each proof is wired

| Proof | Where |
|---|---|
| Streaming | Native. Bedrock requests are translated to the Converse API |
| Guardrail | `llm.policies.guardrails`: a regex `reject` rule for the canary on requests (400 with a JSON body) and responses |
| Rate limit | `llm.policies.apiKey` gives each key a `user` in its metadata. `remoteRateLimit` sends `user_id=apiKey.user` to the Envoy reference rate-limit server, and `ratelimit/config.yaml` limits `user_id=limited` to 3 requests/minute |
| OTel | `frontendPolicies.tracing` exports OTLP gRPC to the shared collector, using the GenAI semantic conventions |

## Why the remote rate-limit server

agentgateway's `localRateLimit` works without extra services, but it's gateway-wide (one bucket for
everyone) and per replica. Limits per key across replicas need a rate-limit server, which is how a
central gateway would run anyway. The server here is the Envoy reference implementation, backed by Redis.

## Notes and open questions

- `config.yaml` uses literal values for the region, model IDs, API keys and canary. Keep them in sync with `.env`.
- AWS credentials come from the ambient environment (the `AWS_*` variables passed in `compose.yaml`).
- `config.yaml` validates against the published schema at https://agentgateway.dev/schema/config.
- Webhook guardrails (`guardrails.request[].webhook`) are the route to custom checks beyond regex,
  such as an internal DLP service. Bedrock Guardrails are also supported natively.
- Image tags default to `v1.7.0` (agentgateway, `AGENTGATEWAY_IMAGE_TAG`) and `3dfe2f9a` (ratelimit,
  `RATELIMIT_IMAGE_TAG`). The ratelimit project only publishes commit tags.
