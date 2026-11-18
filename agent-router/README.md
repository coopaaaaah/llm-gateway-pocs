# Agent Router (formerly Envoy AI Gateway)

[Agent Router](https://github.com/theagentrouter/agent-router) adds an AI layer (provider
translation, token accounting, model routing) on top of Envoy Proxy and Envoy Gateway. Configuration
uses Gateway API and custom resources. Here it runs in standalone mode (`aigw run`), which reads the
same resources from a single YAML file without Kubernetes.

```bash
./gateway.sh agent-router up
./gateway.sh agent-router smoke
```

- API: http://localhost:1975/v1 (OpenAI format) and http://localhost:1975/anthropic/v1/messages (Anthropic format)
- Admin: http://localhost:1064/metrics (Prometheus) and `/health`
- Models: send the Bedrock model ID itself (`$SONNET_MODEL_ID`, `$HAIKU_MODEL_ID`) as `model`
- No auth is configured

## How each proof is wired

| Proof | Where |
|---|---|
| Streaming | Native. Route and backend `timeouts.request: 600s` |
| Guardrail | **Not configured yet** |
| Rate limit | **Not configured yet** |
| OTel | `OTEL_*` environment variables in `compose.yaml` with `AI_GATEWAY_TRACING_SEMCONV=gen_ai` |

## Config walkthrough (`config.yaml`)

- `GatewayClass`, `Gateway` and `EnvoyProxy`: the listener on port 1975.
- `AIGatewayRoute`: matches the `x-ai-eg-model` header (set from the request's `model`) against both
  Bedrock IDs, and records input and output token counts as metadata.
- `AIServiceBackend` with schema `AWSBedrock`: translates OpenAI chat completions to Bedrock Converse.
- `Backend` and `BackendTLSPolicy`: the `bedrock-runtime.<region>` endpoint over TLS.
- `BackendSecurityPolicy` and `Secret`: SigV4 signing from an AWS credentials file built from
  environment variables. On EKS, Pod Identity or IRSA replace the secret.
- `ClientTrafficPolicy`: raises Envoy's 32KiB buffer so large prompts fit.

`aigw` substitutes `${VAR}` references from its environment when it loads the file.

## Next steps

- **Guardrail.** The extension point is Envoy External Processing (ExtProc): a gRPC service that sees
  request and response bodies, attached with an `EnvoyExtensionPolicy`. Still to verify: whether
  standalone `aigw run` honors `EnvoyExtensionPolicy`, and whether a small Python or Go ExtProc canary
  service is enough to show it.
- **Rate limit.** Agent Router documents usage-based (token) rate limiting through Envoy Gateway's
  global rate limit, which needs a rate-limit service and Redis (the same reference server the
  agentgateway POC uses). Still to verify: whether standalone mode supports it, or whether this proof
  needs a kind cluster.
- If both need Kubernetes, standalone mode is only enough to prove streaming and OTel, and the rest
  moves to a local kind cluster.

## Notes

- The image is still published as `envoyproxy/ai-gateway-cli`. The tag defaults to `v1.3.0` and can be
  overridden with `AGENT_ROUTER_IMAGE_TAG`.
- Session tokens: the credentials file includes `aws_session_token`, which SSO-derived credentials need.
