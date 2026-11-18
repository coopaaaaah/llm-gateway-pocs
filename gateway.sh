#!/usr/bin/env bash
# Start, stop and smoke-test the LLM gateway POCs. Run with no arguments for usage.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAYS=(litellm bifrost agent-router portkey agentgateway)

usage() {
  cat <<EOF
Usage:
  ./gateway.sh creds [aws-profile]        Write short-lived AWS credentials to .env.aws
  ./gateway.sh list                       List gateways and their local URLs
  ./gateway.sh <gateway> <command>

Gateways: ${GATEWAYS[*]}

Commands:
  up          Start the gateway, the shared OTel collector and any dependencies
  down        Stop and remove the containers
  logs        Follow the gateway logs
  ps          Show container status
  config      Render the resolved docker compose config (no containers started)
  smoke       Streaming request, input canary and output canary checks
  ratelimit   Send 4 requests with the 3-requests-per-minute key; expect the 4th to get 429
EOF
}

die() { echo "error: $*" >&2; exit 1; }

load_env() {
  [[ -f "$ROOT/.env" ]] || die ".env not found. Run: cp .env.example .env"
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  # shellcheck disable=SC1091
  [[ -f "$ROOT/.env.aws" ]] && source "$ROOT/.env.aws"
  set +a
}

compose() {
  local gw=$1
  shift
  docker compose -p "gw-$gw" -f "$ROOT/$gw/compose.yaml" "$@"
}

load_smoke_env() {
  # shellcheck disable=SC1090
  source "$ROOT/$1/smoke.env"
}

# post <header-array-name> <json-body> [curl args...]; sets BODY and CODE.
post() {
  local name=$1 body=$2
  shift 2
  eval "local -a hdrs=(\"\${${name}[@]}\")"
  local out
  out=$(curl -sS --max-time 600 "$@" -w $'\n%{http_code}' "$SMOKE_URL" \
    -H "Content-Type: application/json" "${hdrs[@]}" -d "$body") || true
  CODE=${out##*$'\n'}
  BODY=${out%$'\n'*}
}

result() {
  local ok=$1 label=$2 detail=$3
  if [[ $ok == 1 ]]; then echo "PASS  $label ($detail)"; else echo "FAIL  $label ($detail)"; FAILED=1; fi
}

chat_body() {
  local content=$1 stream=$2 max_tokens=$3
  printf '{"model":"%s","stream":%s,"max_tokens":%s,"messages":[{"role":"user","content":"%s"}]}' \
    "$SMOKE_MODEL" "$stream" "$max_tokens" "$content"
}

smoke() {
  local gw=$1
  load_smoke_env "$gw"
  FAILED=0
  echo "Smoke testing $gw at $SMOKE_URL with model $SMOKE_MODEL"

  post SMOKE_HEADERS "$(chat_body "Count from 1 to 5, one number per line." true 64)" -N
  local chunks
  chunks=$(grep -c '^data:' <<<"$BODY" || true)
  result "$([[ $CODE == 200 && $chunks -gt 1 ]] && echo 1)" "streaming" "HTTP $CODE, $chunks SSE chunks"

  post SMOKE_HEADERS "$(chat_body "Please repeat this: $GUARDRAIL_CANARY" false 32)"
  result "$([[ $CODE == 4* ]] && echo 1)" "input canary blocked" "HTTP $CODE"

  # Split the canary so the request itself passes the input guardrail.
  local half=$((${#GUARDRAIL_CANARY} / 2))
  local a=${GUARDRAIL_CANARY:0:half} b=${GUARDRAIL_CANARY:half}
  post SMOKE_HEADERS "$(chat_body "Join these two strings with nothing between them and reply with only the result: '$a' and '$b'" false 32)"
  local leaked=0
  [[ $CODE == 2* && $BODY == *"$GUARDRAIL_CANARY"* ]] && leaked=1
  result "$([[ $leaked == 0 && $CODE != 5* ]] && echo 1)" "output canary blocked" "HTTP $CODE"
  [[ $CODE == 2* && $leaked == 0 ]] && echo "      note: model did not echo the canary, so the output guardrail was not exercised"

  return "$FAILED"
}

ratelimit() {
  local gw=$1
  load_smoke_env "$gw"
  if [[ ${#RATELIMIT_HEADERS[@]} -eq 0 ]]; then
    echo "No rate-limited key is configured for $gw yet. See $gw/README.md."
    return 0
  fi
  FAILED=0
  local codes=()
  for _ in 1 2 3 4; do
    post RATELIMIT_HEADERS "$(chat_body "Say ok." false 1)"
    codes+=("$CODE")
  done
  result "$([[ ${codes[3]} == 429 ]] && echo 1)" "4th request rate limited" "HTTP ${codes[*]}"
  return "$FAILED"
}

creds() {
  local profile=${1:-$AWS_PROFILE}
  [[ -n $profile ]] || die "pass an AWS profile or set AWS_PROFILE"
  aws configure export-credentials --profile "$profile" --format env-no-export >"$ROOT/.env.aws"
  chmod 600 "$ROOT/.env.aws"
  echo "Wrote $ROOT/.env.aws ($(grep -o 'AWS_CREDENTIAL_EXPIRATION=.*' "$ROOT/.env.aws" || echo 'no expiry reported'))"
}

list() {
  local gw
  for gw in "${GATEWAYS[@]}"; do
    printf '%-14s %s\n' "$gw" "$(grep -o 'http://localhost:[0-9]*' "$ROOT/$gw/smoke.env" | head -1)"
  done
}

main() {
  case "${1:-}" in
    "" | -h | --help | help) usage; return ;;
    creds) shift; creds "$@"; return ;;
    list) list; return ;;
  esac

  local gw=$1 cmd=${2:-}
  [[ " ${GATEWAYS[*]} " == *" $gw "* ]] || die "unknown gateway '$gw' (choose: ${GATEWAYS[*]})"
  load_env

  case "$cmd" in
    up)
      compose "$gw" up -d
      if [[ -x "$ROOT/$gw/init.sh" ]]; then "$ROOT/$gw/init.sh"; fi
      load_smoke_env "$gw"
      echo "$gw is up: $SMOKE_URL"
      ;;
    down) compose "$gw" down -v ;;
    logs) compose "$gw" logs -f ;;
    ps) compose "$gw" ps ;;
    config) compose "$gw" config ;;
    smoke) smoke "$gw" ;;
    ratelimit) ratelimit "$gw" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
