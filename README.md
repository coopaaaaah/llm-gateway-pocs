# LLM gateway POCs

Side-by-side, self-hosted proofs of concept for open-source LLM gateways in front of AWS Bedrock.
The goal is to pick **one** central gateway that every service calls, and to show with running
code, not just docs, which candidates meet the requirements below.

## What each gateway has to prove

| Proof | What "pass" means | How it's checked |
|---|---|---|
| Streaming | OpenAI-style `stream: true` returns SSE chunks from Bedrock | `./gateway.sh <gw> smoke` |
| Guardrail hook | A request containing the canary string is rejected; a response containing it is blocked | `./gateway.sh <gw> smoke` |
| Rate limits | A key limited to 3 requests/minute gets `429` on the 4th request | `./gateway.sh <gw> ratelimit` |
| Telemetry | GenAI spans reach the OTel collector (and Honeycomb if configured) | `./gateway.sh <gw> logs` and the collector's `debug` output |
| Runs in our network | Self-hosted container, no SaaS control plane | By construction |

Supply-chain review (image provenance, CVE scanning, dependency footprint) is tracked separately.

## The gateways

| Directory | Gateway | Language | License | Local URL |
|---|---|---|---|---|
| [`litellm/`](litellm/README.md) | [LiteLLM proxy](https://github.com/BerriAI/litellm) | Python | MIT (core) | http://localhost:4000 |
| [`bifrost/`](bifrost/README.md) | [Bifrost](https://github.com/maximhq/bifrost) | Go | Apache-2.0 | http://localhost:8080 |
| [`agent-router/`](agent-router/README.md) | [Agent Router](https://github.com/theagentrouter/agent-router) (formerly Envoy AI Gateway) | Go + Envoy | Apache-2.0 | http://localhost:1975 |
| [`portkey/`](portkey/README.md) | [Portkey gateway](https://github.com/Portkey-AI/gateway) | TypeScript | MIT | http://localhost:8787 |
| [`agentgateway/`](agentgateway/README.md) | [agentgateway](https://github.com/agentgateway/agentgateway) (Linux Foundation) | Rust | Apache-2.0 | http://localhost:4001 |

- **LiteLLM** is the baseline: the most features and the widest provider coverage, but a large Python
  dependency tree and a history of CVEs.
- **Bifrost** is a small Go binary with virtual keys, rate limits and OTel in open source. Its packaged
  guardrails are Enterprise-only, so the open-source guardrail is a custom Go plugin.
- **Agent Router** puts an AI layer on Envoy and the Gateway API. It's the most "infrastructure-native"
  option, and guardrails and rate limits go through Envoy extension points.
- **Portkey** and **agentgateway** compete for the fourth slot. Portkey's open-source gateway is
  lightweight, but takes provider credentials and guardrail config from request headers and lacks
  open-source rate limits. agentgateway covers every proof in open source. Whichever does better on the
  smoke tests stays in the comparison.

## Prerequisites

- Docker with Compose v2.20+ (the compose files use `include:`)
- AWS CLI v2 and a profile that can call `bedrock:InvokeModel*` on the models in `.env`
- Bedrock model access to Claude Sonnet 5 and Claude Haiku 4.5 in `AWS_REGION`
- Optional: a Honeycomb ingest key for trace export

## Quick start

```bash
cp .env.example .env                  # region, model IDs, canary, keys
./gateway.sh creds my-aws-profile     # writes short-lived credentials to .env.aws (git-ignored)

./gateway.sh litellm up               # start one gateway, its dependencies and an OTel collector
./gateway.sh litellm smoke            # streaming + input canary + output canary
./gateway.sh litellm ratelimit        # 4 requests on the 3 rpm key, expect 429 on the 4th
./gateway.sh litellm down
```

Every gateway uses different host ports, so several can run at once. Credentials from `creds` expire;
re-run it and restart the gateway (`down`, then `up`) when Bedrock starts returning 403s.

## `gateway.sh` reference

```text
./gateway.sh creds [aws-profile]     Write short-lived AWS credentials to .env.aws
./gateway.sh list                    List gateways and their local URLs
./gateway.sh <gateway> up            Start the gateway, the OTel collector and dependencies
./gateway.sh <gateway> down          Stop and remove containers and volumes
./gateway.sh <gateway> logs          Follow logs
./gateway.sh <gateway> ps            Container status
./gateway.sh <gateway> config        Render the resolved compose file (no containers started)
./gateway.sh <gateway> smoke         Streaming, input canary and output canary checks
./gateway.sh <gateway> ratelimit     Rate-limit check (skipped where no limited key exists yet)
```

`smoke` prints one `PASS`/`FAIL` line per check and exits non-zero on any failure. For the output
canary it asks the model to join two halves of the canary, so the request itself passes the input
guardrail. If the model refuses to echo it, the script says so instead of reporting a false pass.

## Layout

```text
gateway.sh                    start/stop/smoke-test script
.env.example                  settings shared by every gateway
shared/otel-collector/        OTLP collector (gRPC 4317, HTTP 4318) that logs spans and forwards to Honeycomb
<gateway>/
  README.md                   what's configured, how each proof is wired, known gaps
  compose.yaml                the gateway plus its dependencies; includes the shared collector
  smoke.env                   URL, model name and auth headers used by gateway.sh
  ...                         gateway config files
```

## Status

| | Streaming | Guardrail | Rate limit | OTel |
|---|---|---|---|---|
| LiteLLM | configured | configured (custom guardrail class) | configured (virtual key, `rpm_limit`) | configured |
| Bifrost | configured | plugin written, not built yet | configured (virtual key + `rate_limits`) | configured |
| Agent Router | configured | not configured yet (ExtProc) | not configured yet | configured |
| Portkey | configured | per-request header config | not available in OSS 1.x | to verify |
| agentgateway | configured | configured (regex guard) | configured (remote rate-limit server) | configured |

"Configured" means the config is written and passes validation (compose rendering, plus the published
JSON schema for Bifrost and agentgateway). It has not been run against Bedrock yet. Each gateway's
README lists its open questions.

## Out of scope here

- Long-running stream tests (more than 55 seconds of streaming), load tests and the full proof harness
- Deploying to a shared environment
- Wiring any application to these gateways
