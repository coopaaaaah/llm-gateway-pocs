# agentgateway

[agentgateway](https://github.com/agentgateway/agentgateway) is a Rust proxy for LLM, MCP and A2A
traffic, hosted by the Linux Foundation. It runs as a standalone binary or container from one YAML
file, or on Kubernetes through the Gateway API.

```bash
./gateway.sh agentgateway up      # agentgateway + dev JWT issuer + envoy ratelimit + redis + otel-collector
./gateway.sh agentgateway smoke
./gateway.sh agentgateway ratelimit

# Manual requests need a JWT (10-minute lifetime):
TOKEN=$(./gateway.sh token my-service)
curl -N localhost:4001/v1/chat/completions -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"sonnet","stream":true,"messages":[{"role":"user","content":"hi"}]}'
```

- API: http://localhost:4001/v1 (OpenAI format) and `/v1/messages` (Anthropic format)
- Auth: `Authorization: Bearer <JWT>` with `iss=auth-service`, `aud=ai-llm-gateway`, RS256
- Models: `sonnet` and `haiku`
- Host port 4001 maps to the container's 4000, so it can run next to LiteLLM

## How each proof is wired

| Proof | Where |
|---|---|
| Auth | `llm.policies.jwtAuth` in `strict` mode verifies the signature against the issuer's JWKS and checks `iss`, `aud`, `exp` and `sub`. Missing, malformed or wrong-audience tokens get 401. The token is stripped before the request goes to Bedrock |
| Streaming | Native. Bedrock requests are translated to the Converse API |
| Guardrail | `llm.policies.guardrails`: a regex `reject` rule for the canary on requests (400 with a JSON body) and responses |
| Rate limit | `llm.policies.remoteRateLimit` sends descriptors to the Envoy reference rate-limit server. See below |
| OTel | `frontendPolicies.tracing` exports OTLP gRPC to the shared collector, using the GenAI semantic conventions. Logs and spans carry `jwt.sub` |

## Auth: JWTs and the JWKS

Callers send a short-lived RS256 JWT minted by an internal auth service. agentgateway verifies it
by fetching the issuer's JWKS (JSON Web Key Set): a public JSON document listing the issuer's public
keys, each tagged with a `kid`. The token header names its `kid`, the gateway picks that key and
checks the signature. No shared secret is involved and the issuer needs no changes; it only has to
serve `/.well-known/jwks.json`.

Locally, `shared/dev-issuer` plays the auth service: same algorithm, `kid`, issuer and maximum
lifetime, with its key persisted under `shared/dev-issuer/data/` (git-ignored). Instead of
authenticating the caller, it mints a token for whatever `sub` you ask for, so it's for local use
only. To verify against a real auth service, change `jwtAuth.jwks.url` to its JWKS URL and send
tokens it minted with audience `ai-llm-gateway`.

## Rate limits

Four descriptors go to the rate-limit server on every request (limits in `ratelimit/config.yaml`):

| Descriptor | Type | Limit (example staging allocation) |
|---|---|---|
| `limit=model-rpm, model` | requests | 9,000/min per model |
| `limit=model-tpm, model` | tokens | 5.4M/min Sonnet, 4.5M/min Haiku |
| `limit=caller-rpm, caller=jwt.sub` | requests | only the `poc-limited` demo caller (3/min) |
| `limit=caller-tpm, caller=jwt.sub, model` | tokens | half the model budget per caller; `poc-tokens` demo caller gets 100 on Haiku |

The model-wide numbers are 90% of a 10,000 RPM / 6M TPM (Sonnet 5) and 10,000 RPM / 5M TPM
(Haiku 4.5) account quota.

**Token limits are in Bedrock quota units, not raw tokens.** Bedrock's TPM quota charges
`input + cache writes + output × burndown`, where the burndown is 10x for Claude Sonnet 5 and 5x for
Haiku 4.5, and cache reads are free. The `cost` expression on the token descriptors computes the same
thing, so the limits can be set straight from the account quota. The default cost (`llm.totalTokens`)
would undercount Sonnet output by 10x.

How token limits behave:

- At request time the gateway checks whether the bucket is already over the limit (cost 0). The
  actual cost is added once the response finishes, so a burst of concurrent requests can overshoot
  the limit by up to one request each. Bedrock instead reserves `input + max_tokens` up front.
- Over the limit, the caller gets an immediate 429. Callers need to retry with backoff.
- `failureMode: failOpen`: if the rate-limit server is down, requests go through without limits and
  Bedrock's own throttling is the backstop. `failClosed` (the agentgateway default) would turn a
  rate-limit outage into 500s for every caller.
- Callers that still go to Bedrock directly share the same account quota but aren't counted here.

## Gotchas found while wiring this

- A `cost` expression that errors at runtime makes the gateway silently skip that descriptor. The
  request is still counted by the other descriptors, so nothing looks wrong. Check the rate-limit
  server's debug logs for `hits_addend:{value:N}` after a response.
- `llm.outputTokens` is unsigned while `llm.inputTokens` and `llm.totalTokens` are signed. CEL has no
  mixed arithmetic, so cast with `int()`.
- When `cost` runs (after the response), `llm.requestModel` holds the Bedrock model ID, not the alias
  the client sent. Descriptor entries are evaluated at request time and do see the alias.
- `jwtAuth` defaults to `mode: optional`, which lets requests without a token through.

## Notes and open questions

- `config.yaml` uses literal values for the region, model IDs and canary. Keep them in sync with `.env`.
- AWS credentials come from the ambient environment (the `AWS_*` variables passed in `compose.yaml`).
- `config.yaml` validates against the published schema at https://agentgateway.dev/schema/config.
  The schema doesn't check CEL expressions.
- Webhook guardrails (`guardrails.request[].webhook`) are the route to custom checks beyond regex,
  such as an internal DLP service. Bedrock Guardrails are also supported natively.
- Image tags default to `v1.7.0` (agentgateway, `AGENTGATEWAY_IMAGE_TAG`) and `3dfe2f9a` (ratelimit,
  `RATELIMIT_IMAGE_TAG`). The ratelimit project only publishes commit tags.
