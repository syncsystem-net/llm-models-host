#!/usr/bin/env bash
# Container entrypoint: renders nginx config, starts Ollama, optional Cloudflare Tunnel,
# pulls the requested models, publishes /status.json for the dashboard, and enforces expiry.
set -Eeuo pipefail

log() { printf '[llmhost] %s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { log "FATAL: $*"; write_status error "$*" || true; sleep 30; exit 1; }

STATUS_FILE=/srv/www/status.json
STARTED_AT=$(date -u +%s)

# ---------- configuration ----------
API_TOKEN="${API_TOKEN:-}"
MODELS="${MODELS:-}"
EXPIRES_AT="${EXPIRES_AT:-0}"                 # unix epoch; 0 = no in-container expiry
PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"        # e.g. llm-models-host.mydomain.com
CLOUDFLARE_TUNNEL_TOKEN="${CLOUDFLARE_TUNNEL_TOKEN:-}"
SELF_TERMINATE_GRACE_SECONDS="${SELF_TERMINATE_GRACE_SECONDS:-900}"

export OLLAMA_HOST=127.0.0.1:11434            # only reachable through nginx
export OLLAMA_MODELS="${OLLAMA_MODELS:-/root/.ollama/models}"
export OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"   # keep models in VRAM while the server lives
export OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
export OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"
export OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-q8_0}"
export OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"

# Public base URLs this instance can be reached at (shown on the dashboard).
PUBLIC_URLS=()
[[ -n "$PUBLIC_HOSTNAME" ]] && PUBLIC_URLS+=("https://${PUBLIC_HOSTNAME}")
[[ -n "${RUNPOD_POD_ID:-}" ]] && PUBLIC_URLS+=("https://${RUNPOD_POD_ID}-8080.proxy.runpod.net")
[[ -n "${LLMHOST_EXTRA_URL:-}" ]] && PUBLIC_URLS+=("$LLMHOST_EXTRA_URL")

declare -A MODEL_STATE=()
MODEL_LIST=()
for m in ${MODELS//,/ }; do MODEL_LIST+=("$m"); MODEL_STATE["$m"]=queued; done

GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -n1 || true)
OLLAMA_VERSION=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)

write_status() {
  local state=$1 message=${2:-} models_json='[]' m tmp
  for m in "${MODEL_LIST[@]}"; do
    models_json=$(jq -c --arg n "$m" --arg s "${MODEL_STATE[$m]}" '. + [{name:$n,status:$s}]' <<<"$models_json")
  done
  tmp=$(mktemp "${STATUS_FILE}.XXXX")
  jq -n \
    --arg state "$state" --arg message "$message" \
    --argjson models "$models_json" \
    --argjson started_at "$STARTED_AT" --argjson expires_at "${EXPIRES_AT:-0}" \
    --argjson updated_at "$(date -u +%s)" \
    --arg provider "${LLMHOST_PROVIDER:-unknown}" --arg size "${LLMHOST_SIZE:-}" \
    --arg gpu "$GPU_INFO" --arg ollama_version "$OLLAMA_VERSION" \
    --arg context_length "$OLLAMA_CONTEXT_LENGTH" \
    --argjson public_urls "$(printf '%s\n' "${PUBLIC_URLS[@]}" | jq -R . | jq -sc 'map(select(length>0))')" \
    '{state:$state,message:$message,models:$models,started_at:$started_at,expires_at:$expires_at,
      updated_at:$updated_at,provider:$provider,size:$size,gpu:$gpu,ollama_version:$ollama_version,
      context_length:($context_length|tonumber? // $context_length),public_urls:$public_urls}' >"$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

# ---------- validation ----------
mkdir -p "$(dirname "$STATUS_FILE")" "$OLLAMA_MODELS"
write_status starting "Container starting"
[[ "$API_TOKEN" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
  || die "API_TOKEN must be 32-128 chars of [A-Za-z0-9_-] (generate one with: openssl rand -hex 32)"
[[ ${#MODEL_LIST[@]} -gt 0 ]] || die "MODELS is empty (comma-separated Ollama model names)"
[[ "$EXPIRES_AT" =~ ^[0-9]+$ ]] || die "EXPIRES_AT must be a unix timestamp"

# ---------- nginx ----------
API_TOKEN="$API_TOKEN" envsubst '${API_TOKEN}' </etc/llmhost/nginx.conf.template >/etc/nginx/nginx.conf
nginx -t -q || die "nginx config invalid"
nginx -g 'daemon off;' &
NGINX_PID=$!
unset API_TOKEN   # nginx has it; nothing else in this container needs it
log "nginx listening on :8080"

# ---------- cloudflare tunnel (optional) ----------
if [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]]; then
  (
    export TUNNEL_TOKEN="$CLOUDFLARE_TUNNEL_TOKEN"   # env, not argv, so it isn't visible in ps
    while true; do
      cloudflared tunnel --no-autoupdate run || true
      log "cloudflared exited; restarting in 5s"
      sleep 5
    done
  ) &
  log "cloudflared tunnel started for ${PUBLIC_HOSTNAME:-<hostname configured in Cloudflare>}"
fi
unset CLOUDFLARE_TUNNEL_TOKEN

# ---------- ollama ----------
ollama serve &
OLLAMA_PID=$!
for _ in $(seq 1 120); do
  curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS -m 2 http://127.0.0.1:11434/api/version >/dev/null 2>&1 || die "ollama did not start"
log "ollama ${OLLAMA_VERSION} up (models dir: ${OLLAMA_MODELS}, ctx: ${OLLAMA_CONTEXT_LENGTH})"

# ---------- expiry watchdog ----------
# Primary shutdown is the GitHub "auto-shutdown" workflow. This is a backup that runs after a
# grace period, in case scheduled workflows are delayed or disabled.
if [[ "$EXPIRES_AT" -gt 0 ]]; then
  (
    deadline=$((EXPIRES_AT + SELF_TERMINATE_GRACE_SECONDS))
    while [[ $(date -u +%s) -lt $deadline ]]; do sleep 60; done
    log "expired at $(date -u -d "@$EXPIRES_AT" +%FT%TZ); self-terminating"
    if [[ -n "${RUNPOD_POD_ID:-}" && -n "${RUNPOD_API_KEY:-}" ]]; then
      # RunPod injects a pod-scoped RUNPOD_API_KEY into pods. Best effort.
      curl -sS -m 30 -X DELETE -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
        "https://api.runpod.io/v2/pods/${RUNPOD_POD_ID}" -o /dev/null -w '[llmhost] self-terminate HTTP %{http_code}\n' || true
    fi
    # If we are still alive, stop serving so an orphaned server is at least useless.
    kill "$OLLAMA_PID" 2>/dev/null || true
  ) &
fi

# ---------- pull + warm models ----------
pull_model() {
  local m=$1 attempt
  for attempt in 1 2 3; do
    log "pulling $m (attempt $attempt)"
    if ollama pull "$m"; then return 0; fi
    sleep $((attempt * 10))
  done
  return 1
}

ok=0
for m in "${MODEL_LIST[@]}"; do
  MODEL_STATE["$m"]=pulling
  write_status pulling "Pulling $m"
  if pull_model "$m"; then
    MODEL_STATE["$m"]=available
    ok=$((ok + 1))
  else
    MODEL_STATE["$m"]=failed
    log "failed to pull $m"
  fi
done

if [[ $ok -eq 0 ]]; then
  die "no model could be pulled; check model names"
fi

# Load the first available model into VRAM so the first request is fast.
for m in "${MODEL_LIST[@]}"; do
  [[ "${MODEL_STATE[$m]}" == available ]] || continue
  MODEL_STATE["$m"]=loading
  write_status loading "Loading $m into GPU memory"
  if curl -fsS -m 900 http://127.0.0.1:11434/api/generate \
       -d "$(jq -nc --arg m "$m" '{model:$m,prompt:"",keep_alive:-1}')" >/dev/null; then
    MODEL_STATE["$m"]=loaded
  else
    MODEL_STATE["$m"]=available
    log "warm-up of $m failed (it will load on first request)"
  fi
  break
done

if [[ $ok -lt ${#MODEL_LIST[@]} ]]; then
  write_status degraded "Some models failed to pull"
else
  write_status ready "Ready"
fi
log "ready: ${MODEL_LIST[*]}"

# ---------- supervise ----------
set +e
wait -n "$NGINX_PID" "$OLLAMA_PID"
code=$?
log "a core process exited (code $code); stopping container"
write_status error "Server process exited" || true
exit "$code"
