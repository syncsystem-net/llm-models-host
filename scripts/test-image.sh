#!/usr/bin/env bash
# Smoke-tests the server image on any machine with Docker (no GPU needed; Ollama falls back to CPU).
# Usage: scripts/test-image.sh [image] [tiny-model]
#   docker build -t llmhost:dev image && bash scripts/test-image.sh llmhost:dev
set -Eeuo pipefail

IMAGE="${1:-llmhost:dev}"
MODEL="${2:-smollm2:135m}"
PORT="${PORT:-18080}"
NAME="llmhost-test-$$"
TOKEN="test$(date +%s)abcdefghijklmnopqrstuvwxyz0123"
BASE="http://127.0.0.1:${PORT}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; docker logs "$NAME" 2>&1 | tail -n 40; exit 1; }
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "starting $IMAGE with $MODEL on :$PORT"
docker run -d --name "$NAME" -p "127.0.0.1:${PORT}:8080" \
  -e API_TOKEN="$TOKEN" -e MODELS="$MODEL" -e OLLAMA_CONTEXT_LENGTH=2048 \
  -e EXPIRES_AT="$(( $(date +%s) + 3600 ))" -e LLMHOST_PROVIDER=local -e LLMHOST_SIZE=test \
  "$IMAGE" >/dev/null

state=""
for _ in $(seq 1 120); do
  state=$(curl -fsS -m 5 "$BASE/status.json" 2>/dev/null | jq -r .state 2>/dev/null || true)
  [[ "$state" == ready || "$state" == degraded || "$state" == error ]] && break
  sleep 5
done
[[ "$state" == ready ]] && pass "server ready" || fail "server state: ${state:-unreachable}"

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")
[[ "$code" == 200 ]] && pass "dashboard is public (200)" || fail "dashboard returned $code"

for path in /v1/models /api/tags; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$path")
  [[ "$code" == 401 ]] && pass "$path without token -> 401" || fail "$path without token -> $code"
done

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong$TOKEN" "$BASE/v1/models")
[[ "$code" == 401 ]] && pass "wrong token -> 401" || fail "wrong token -> $code"

code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: bearer $TOKEN" "$BASE/v1/models")
[[ "$code" == 401 ]] && pass "auth scheme is matched exactly" || fail "lowercase scheme -> $code"

models=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/v1/models" | jq -r '[.data[].id]|join(",")')
[[ "$models" == *"${MODEL%%:*}"* ]] && pass "Bearer token -> /v1/models lists $models" || fail "models: $models"

curl -fsS -H "x-api-key: $TOKEN" "$BASE/api/tags" >/dev/null && pass "x-api-key header accepted" || fail "x-api-key rejected"

out=$(curl -fsS -m 120 -H "Authorization: Bearer $TOKEN" "$BASE/v1/chat/completions" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}],\"max_tokens\":16}" | jq -r '.choices[0].message.content')
[[ -n "$out" && "$out" != null ]] && pass "OpenAI chat completion: ${out:0:60}" || fail "chat completion empty"

out=$(curl -fsS -m 120 -H "x-api-key: $TOKEN" -H "anthropic-version: 2023-06-01" "$BASE/v1/messages" \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say hi\"}]}" | jq -r '.content[0].text // .content[0].thinking // empty')
[[ -n "$out" ]] && pass "Anthropic messages: ${out:0:60}" || fail "anthropic messages empty"

n=$(curl -fsS -N -m 120 -H "Authorization: Bearer $TOKEN" "$BASE/v1/chat/completions" \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count to 5\"}],\"max_tokens\":24}" | grep -c '^data:' || true)
[[ "$n" -gt 1 ]] && pass "streaming works ($n SSE events)" || fail "streaming returned $n events"

if docker logs "$NAME" 2>&1 | grep -q "$TOKEN"; then fail "token appears in container logs"; else pass "token not in logs"; fi

echo "all checks passed"
