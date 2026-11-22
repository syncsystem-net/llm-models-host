# shellcheck shell=bash
# Provider-agnostic orchestration. Providers implement a small contract (see providers/README.md);
# everything else — naming, expiry, readiness checks, summaries — lives here.

log()  { printf '[llmhost] %s\n' "$*" >&2; }
warn() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::warning::%s\n' "$*" >&2; else log "WARNING: $*"; fi; }
die()  { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then printf '::error::%s\n' "$*" >&2; else log "ERROR: $*"; fi; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; else printf '%s\n' "$*"; fi; }
gh_output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; fi; }
mask() { if [[ -n "${GITHUB_ACTIONS:-}" && -n "${1:-}" ]]; then printf '::add-mask::%s\n' "$1"; fi; }

# jq on Windows (Git Bash) writes CRLF; strip it so local runs behave like the Linux runners.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  jq() { command jq "$@" | tr -d '\r'; }
fi

now() { date -u +%s; }
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------- configuration ----------
load_config() {
  PROVIDER="${PROVIDER:-runpod}"
  DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-llmhost}"
  SIZE="${SIZE:-small}"
  SIZE="${SIZE%% *}"                          # workflow choice labels look like "small · 24 GB ..."
  AUTO_SHUTDOWN_HOURS="${AUTO_SHUTDOWN_HOURS:-6}"
  READY_TIMEOUT_MINUTES="${READY_TIMEOUT_MINUTES:-45}"
  KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-false}"
  RECREATE="${RECREATE:-false}"
  MODELS="${MODELS:-}"
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME:-}"
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME#https://}"; PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME%/}"

  [[ "$PROVIDER" =~ ^[a-z0-9_-]+$ ]] || die "invalid provider name: $PROVIDER"
  [[ "$DEPLOYMENT_NAME" =~ ^[a-z0-9][a-z0-9-]{0,29}$ ]] || die "DEPLOYMENT_NAME must match ^[a-z0-9][a-z0-9-]{0,29}$"

  PROVIDER_DIR="$ROOT_DIR/providers/$PROVIDER"
  [[ -f "$PROVIDER_DIR/provider.sh" ]] || die "unknown provider '$PROVIDER' (no $PROVIDER_DIR/provider.sh)"
  # shellcheck source=/dev/null
  source "$PROVIDER_DIR/provider.sh"
  provider_validate
}

size_json() {
  local f="$PROVIDER_DIR/sizes.json"
  jq -e --arg s "$SIZE" '.[$s]' "$f" 2>/dev/null \
    || die "size '$SIZE' not defined for provider '$PROVIDER' (available: $(jq -r 'keys|join(", ")' "$f"))"
}

instance_name() { printf '%s--exp-%s' "$DEPLOYMENT_NAME" "$1"; }

# Instances managed by this deployment, as TSV: id, name, status, cost/hr, expires_at.
# The expiry is encoded in the instance name so the reaper needs no external state.
managed_instances() {
  local id name status cost all
  all=$(provider_list) || die "could not list instances on $PROVIDER"
  while IFS=$'\t' read -r id name status cost; do
    [[ -n "$id" ]] || continue
    case "$status" in TERMINATED) continue ;; esac
    if [[ "$name" =~ ^${DEPLOYMENT_NAME}--exp-([0-9]+)$ ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$name" "$status" "$cost" "${BASH_REMATCH[1]}"
    fi
  done <<<"$all"
}

fetch_status() { curl -fsS -m 10 "$1/status.json" 2>/dev/null; }

# ---------- commands ----------
cmd_up() {
  local api_token="${API_TOKEN:-}" size hours_s expires_at name created id gpu cost url
  [[ "$api_token" =~ ^[A-Za-z0-9_-]{32,128}$ ]] \
    || die "API_TOKEN secret missing or invalid: use 32-128 chars of [A-Za-z0-9_-] (openssl rand -hex 32)"
  mask "$api_token"
  [[ -n "${MODELS// /}" ]] || die "no models given (input 'models' or variable DEFAULT_MODELS)"
  hours_s=$(awk -v h="$AUTO_SHUTDOWN_HOURS" 'BEGIN { if (h ~ /^[0-9]+(\.[0-9]+)?$/ && h > 0 && h <= 72) printf "%d", h*3600; else print "bad" }')
  [[ "$hours_s" != bad ]] || die "AUTO_SHUTDOWN_HOURS must be a number between 0 and 72 (got '$AUTO_SHUTDOWN_HOURS')"
  size=$(size_json)

  local existing; existing=$(managed_instances)
  if [[ -n "$existing" ]]; then
    if [[ "$RECREATE" == true ]]; then
      log "recreate requested: terminating existing instance(s)"
      cut -f1 <<<"$existing" | while read -r id; do provider_terminate "$id"; done
    else
      log "existing instance(s):"; printf '%s\n' "$existing" >&2
      die "deployment '$DEPLOYMENT_NAME' is already running on $PROVIDER. Run 'down' first or set recreate=true."
    fi
  fi

  expires_at=$(( $(now) + hours_s ))
  name=$(instance_name "$expires_at")
  CONTEXT_LENGTH="${CONTEXT_LENGTH:-$(jq -r '.context_length // 32768' <<<"$size")}"
  [[ "$CONTEXT_LENGTH" =~ ^[0-9]+$ ]] || die "context length must be an integer"

  # Environment handed to the container (image/entrypoint.sh documents each variable).
  CONTAINER_ENV=$(jq -nc \
    --arg API_TOKEN "$api_token" \
    --arg MODELS "$MODELS" \
    --arg EXPIRES_AT "$expires_at" \
    --arg PUBLIC_HOSTNAME "$PUBLIC_HOSTNAME" \
    --arg CLOUDFLARE_TUNNEL_TOKEN "${CLOUDFLARE_TUNNEL_TOKEN:-}" \
    --arg OLLAMA_CONTEXT_LENGTH "$CONTEXT_LENGTH" \
    --arg OLLAMA_KV_CACHE_TYPE "${OLLAMA_KV_CACHE_TYPE:-q8_0}" \
    --arg LLMHOST_PROVIDER "$PROVIDER" \
    --arg LLMHOST_SIZE "$SIZE" \
    '$ARGS.named | with_entries(select(.value != ""))')
  export CONTAINER_ENV

  log "creating '$name' on $PROVIDER (size: $SIZE, models: $MODELS, ctx: $CONTEXT_LENGTH, expires: $(iso "$expires_at"))"
  created=$(provider_create "$name" "$size")
  IFS=$'\t' read -r id gpu cost <<<"$created"
  [[ -n "$id" ]] || die "provider did not return an instance id"
  url=$(provider_url "$id")
  log "created $id on $gpu (\$${cost}/hr) -> $url"

  # From here on, any failure or a cancelled workflow run must not leave a billed instance behind.
  trap 'abort_up "$id" "workflow cancelled"' INT TERM
  wait_ready "$id" "$url" || abort_up "$id" "instance did not become ready"
  smoke_test "$url" "$api_token" || abort_up "$id" "auth check failed"
  trap - INT TERM
  check_public_hostname

  gh_output instance_id "$id"; gh_output url "$url"
  local status; status=$(fetch_status "$url" || echo '{}')
  summary "## ✅ LLM host is up"
  summary ""
  summary "| | |"
  summary "|---|---|"
  summary "| Provider / size | \`$PROVIDER\` / \`$SIZE\` on **$gpu** |"
  summary "| Cost | ~\$${cost}/hr (provider rate) |"
  summary "| Auto-shutdown | $(iso "$expires_at") (in ${AUTO_SHUTDOWN_HOURS}h) |"
  summary "| Provider URL | $url |"
  [[ -n "$PUBLIC_HOSTNAME" ]] && summary "| Friendly URL | https://$PUBLIC_HOSTNAME |"
  summary "| Models | $(jq -r '[.models[]? | "`\(.name)` (\(.status))"] | join(", ")' <<<"$status") |"
  summary ""
  summary "Open the URL in a browser for the dashboard and copy-paste usage snippets."
}

wait_ready() {
  local id=$1 url=$2 deadline last="" st body i=0 pstatus
  deadline=$(( $(now) + READY_TIMEOUT_MINUTES * 60 ))
  log "waiting up to ${READY_TIMEOUT_MINUTES}m for $url (first boot pulls the image and the models)"
  while [[ $(now) -lt $deadline ]]; do
    if body=$(fetch_status "$url"); then
      st=$(jq -r '.state // "unknown"' <<<"$body")
      local msg; msg="$st: $(jq -r '.message // ""' <<<"$body")"
      [[ "$msg" != "$last" ]] && { log "$msg"; last=$msg; }
      case "$st" in
        ready) return 0 ;;
        degraded) warn "some models failed: $(jq -c '.models' <<<"$body")"; return 0 ;;
        error) warn "server reported error: $msg"; return 1 ;;
      esac
    fi
    if (( i++ % 4 == 0 )); then
      pstatus=$(provider_status "$id")
      case "$pstatus" in
        ERROR|TERMINATED|EXITED|FAILED) warn "instance $id is $pstatus"; return 1 ;;
      esac
      [[ -z "$last" ]] && log "instance $id: $pstatus (container not serving yet)"
    fi
    sleep 15
  done
  warn "timed out after ${READY_TIMEOUT_MINUTES} minutes"
  return 1
}

abort_up() {
  local id=$1 reason=$2
  trap - INT TERM
  if [[ "$KEEP_ON_FAILURE" == true ]]; then
    warn "instance $id left running for debugging (KEEP_ON_FAILURE=true). Run 'down' when done."
  else
    log "terminating $id to avoid charges"; provider_terminate "$id"
  fi
  die "$reason"
}

smoke_test() {
  local url=$1 token=$2 code
  code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "$url/v1/models" || true)
  [[ "$code" == 401 ]] || { warn "SECURITY: unauthenticated request returned HTTP $code (expected 401)"; return 1; }
  code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -K - "$url/v1/models" <<<"header = \"Authorization: Bearer $token\"" || true)
  [[ "$code" == 200 ]] || { warn "authenticated request to /v1/models returned HTTP $code (expected 200)"; return 1; }
  log "auth check passed (401 without token, 200 with token)"
}

check_public_hostname() {
  [[ -n "$PUBLIC_HOSTNAME" ]] || return 0
  if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    warn "PUBLIC_HOSTNAME is set but CLOUDFLARE_TUNNEL_TOKEN is not; the friendly URL will not route to the server"
    return 0
  fi
  local i
  for i in 1 2 3 4 5 6; do
    if [[ "$(fetch_status "https://$PUBLIC_HOSTNAME" | jq -r '.state // empty' 2>/dev/null)" =~ ^(ready|degraded)$ ]]; then
      log "friendly URL https://$PUBLIC_HOSTNAME is serving"; return 0
    fi
    sleep 10
  done
  warn "https://$PUBLIC_HOSTNAME is not serving yet — check the tunnel's public hostname in Cloudflare (service: http://localhost:8080)"
}

cmd_down() {
  local rows id name
  rows=$(managed_instances)
  if [[ -z "$rows" ]]; then
    log "no running instances for '$DEPLOYMENT_NAME' on $PROVIDER"
    summary "Nothing to tear down: no instances for \`$DEPLOYMENT_NAME\` on \`$PROVIDER\`."
    return 0
  fi
  summary "## 🧹 Teardown ($PROVIDER)"
  while IFS=$'\t' read -r id name _; do
    provider_terminate "$id"
    summary "- terminated \`$id\` ($name)"
  done <<<"$rows"
}

cmd_reap() {
  local rows id name status cost exp t reaped=0
  rows=$(managed_instances)
  t=$(now)
  while IFS=$'\t' read -r id name status cost exp; do
    [[ -n "$id" ]] || continue
    if (( exp <= t )); then
      log "instance $id expired at $(iso "$exp"); terminating"
      provider_terminate "$id"
      summary "- ⏱️ terminated \`$id\` on \`$PROVIDER\` (expired $(iso "$exp"))"
      reaped=$((reaped + 1))
    else
      log "instance $id ok, expires $(iso "$exp") (in $(( (exp - t) / 60 )) min, \$${cost}/hr, $status)"
    fi
  done <<<"$rows"
  log "reaped $reaped instance(s) on $PROVIDER"
}

cmd_catalog() {
  declare -F provider_catalog >/dev/null || die "provider '$PROVIDER' has no catalog support"
  local rows; rows=$(provider_catalog)
  summary "## 💲 $PROVIDER GPU catalog (live list prices per hour, 1 GPU)"
  summary ""
  summary "| size | gpu id | vram | secure | community | availability |"
  summary "|---|---|---|---|---|---|"
  summary "$rows"
}

cmd_status() {
  local rows id name status cost exp url body
  rows=$(managed_instances)
  if [[ -z "$rows" ]]; then
    summary "No instances for \`$DEPLOYMENT_NAME\` on \`$PROVIDER\`."
    return 0
  fi
  summary "## 📋 Instances on $PROVIDER"
  summary ""
  summary "| id | status | cost/hr | expires | server | models | url |"
  summary "|---|---|---|---|---|---|---|"
  while IFS=$'\t' read -r id name status cost exp; do
    url=$(provider_url "$id")
    body=$(fetch_status "$url" || echo '{}')
    summary "| \`$id\` | $status | \$$cost | $(iso "$exp") | $(jq -r '.state // "unreachable"' <<<"$body") | $(jq -r '[.models[]?.name] | join(", ")' <<<"$body") | $url |"
  done <<<"$rows"
}
