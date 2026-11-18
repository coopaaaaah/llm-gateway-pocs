# Portkey gateway

[Portkey's open-source gateway](https://github.com/Portkey-AI/gateway) is a small TypeScript service
with an OpenAI-compatible API, routing configs (fallbacks, retries, load balancing) and built-in
guardrail checks.

```bash
./gateway.sh portkey up
./gateway.sh portkey smoke
```

- API: http://localhost:8787/v1 (OpenAI format)
- Console: http://localhost:8787/public/
- Models: send the Bedrock model ID itself

## How each proof is wired

| Proof | Where |
|---|---|
| Streaming | Native |
| Guardrail | `default.contains` check with `operator: none` and `deny: true` on input and output, sent in the `x-portkey-config` header (see `smoke.env`) |
| Rate limit | **Not available** in the open-source 1.x gateway |
| OTel | **To verify** for 1.x and the 2.0 pre-release |

## Why Portkey might not stay in the running

Portkey has no server-side config in this setup. The provider, the AWS credentials and the guardrail
config all arrive as request headers (`x-portkey-provider`, `x-portkey-aws-*`, `x-portkey-config`).
That has two consequences for a central gateway:

- A caller can leave out the guardrail config, so the gateway can't enforce policy by itself.
- Every caller has to hold Bedrock credentials, which defeats one reason to centralize.

Virtual keys, budgets and rate limits are part of Portkey's hosted or Enterprise offering. Portkey's
2.0 pre-release says it's moving some of those into open source. If 2.0 adds server-side configs,
virtual keys and rate limits, re-test with it. Otherwise agentgateway takes the fourth slot.

## Notes

- The image tag defaults to `1.15.2` and can be overridden with `PORTKEY_IMAGE_TAG`.
- The OTel collector is started for parity with the other gateways, but nothing sends to it yet.
