#!/usr/bin/env bash
# Creates the rate-limited virtual key (3 requests/minute) used by `./gateway.sh litellm ratelimit`.
set -euo pipefail

for _ in $(seq 1 60); do
  curl -fs http://localhost:4000/health/liveliness >/dev/null && break
  sleep 2
done

curl -fsS http://localhost:4000/key/generate \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"key_alias": "poc-limited", "key": "sk-litellm-poc-limited", "rpm_limit": 3}' \
  >/dev/null 2>&1 || echo "poc-limited key already exists (or creation failed; check logs)"
