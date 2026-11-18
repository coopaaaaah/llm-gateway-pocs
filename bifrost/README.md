# Bifrost

[Bifrost](https://github.com/maximhq/bifrost) is a Go gateway from Maxim with an OpenAI-compatible
API, governance (virtual keys, budgets, rate limits) and an OTel plugin in open source.

```bash
./gateway.sh bifrost up
./gateway.sh bifrost smoke
./gateway.sh bifrost ratelimit
```

- API: http://localhost:8080/v1 (OpenAI format), auth header `x-bf-vk: $BIFROST_VIRTUAL_KEY`
- Web UI: http://localhost:8080
- Models: `bedrock/sonnet` and `bedrock/haiku` (aliases in `config.json`)

## How each proof is wired

| Proof | Where |
|---|---|
| Streaming | Native |
| Guardrail | `plugins/canary/main.go`, a custom Go plugin. **Not built or loaded yet**; see below |
| Rate limit | `governance.rate_limits` `rl-poc-limited` (3 requests/minute) attached to the `sk-bf-poc-limited-3rpm` virtual key. `client.enforce_auth_on_inference` makes a virtual key mandatory |
| OTel | `plugins[].otel` with `trace_type: genai_extension`, sent to the shared collector over HTTP |

## Guardrail

Bifrost's packaged guardrails (Bedrock Guardrails, Azure Content Safety and others) are Enterprise
features. In open source, the hook is a native Go plugin (`.so`) loaded at startup.
`plugins/canary/main.go` implements the hooks:

- `HTTPTransportPreHook` short-circuits with a 400 when the request body contains the canary.
- `HTTPTransportPostHook` replaces a non-streamed response that contains it.
- `HTTPTransportStreamChunkHook` errors the stream when a chunk contains it. This works per chunk
  only: a canary split across two chunks gets through, which is good enough to prove the hook exists.

Go plugins must be built with the same Go version and the same `bifrost/core` version as the Bifrost
binary that loads them. `go.mod` pins Go 1.27.3 and `core v1.15.2`, copied from Bifrost's hello-world
plugin at `transports/v2.5.1`. To try it:

1. Build the plugin for Linux with the same toolchain as the image (`go build -buildmode=plugin`, see
   Bifrost's [Writing Go plugins](https://docs.getbifrost.ai/plugins/writing-go-plugin) guide).
2. Check whether the official image can load plugins. Go plugins need a dynamically linked binary;
   if the image is static, build Bifrost from source in a multi-stage Dockerfile next to the plugin.
3. Mount the `.so` and register it in `config.json` (see Bifrost's plugin config docs for the field names).

This plugin is a real cost of choosing Bifrost: every Bifrost upgrade means rebuilding it.

## Notes and open questions

- `config.json` hard-codes the model IDs in `aliases`. Keep them in sync with `.env`.
- Credentials come from `env.` references, so the static keys from `./gateway.sh creds` are read at
  startup. On ECS or EKS, leave only `region` set and Bifrost uses the AWS SDK default chain.
- The image tag defaults to `v2.5.1` and can be overridden with `BIFROST_IMAGE_TAG`.
