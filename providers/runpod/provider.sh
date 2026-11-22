# shellcheck shell=bash
# RunPod provider (GPU Pods via the RunPod REST API v2: https://api.runpod.io/v2).
#
# Why Pods and not Serverless: see docs/ARCHITECTURE.md. In short, an interactive coding agent
# keeps a model busy for hours; a pod has no cold starts, a stable HTTP port, can run the
# Cloudflare tunnel for the friendly hostname, and is cheaper per active hour.
#
# Inputs (env):
#   RUNPOD_API_KEY            required  account API key (read/write)
#   RUNPOD_CLOUD              optional  SECURE (default) or COMMUNITY (cheaper, less reliable)
#   RUNPOD_NETWORK_VOLUME_ID  optional  network volume to cache models across deployments
#   RUNPOD_DATA_CENTER_IDS    optional  comma-separated data center ids to restrict placement
#   RUNPOD_REGISTRY_AUTH_ID   optional  registry credential id if the image is private
#   RUNPOD_MIN_CUDA_VERSION   optional  e.g. 12.4
#   LLMHOST_IMAGE             required  container image (set by the workflow)

RUNPOD_API="${RUNPOD_API_BASE:-https://api.runpod.io}"
RUNPOD_PORT=8080

provider_validate() {
  [[ -n "${RUNPOD_API_KEY:-}" ]] || die "secret RUNPOD_API_KEY is not set"
  mask "$RUNPOD_API_KEY"
  RUNPOD_CLOUD="${RUNPOD_CLOUD:-SECURE}"
  [[ "$RUNPOD_CLOUD" =~ ^(SECURE|COMMUNITY)$ ]] || die "RUNPOD_CLOUD must be SECURE or COMMUNITY"
}

# rp METHOD PATH [JSON_BODY]  -> sets RP_CODE and RP_BODY. Retries on 429/5xx/network errors.
rp() {
  local method=$1 path=$2 body=${3:-} attempt out body_file=""
  local -a args=(-sS -m 60 -X "$method" -H "Accept: application/json" -w $'\n%{http_code}' -K -)
  if [[ -n "$body" ]]; then
    # Body via a private temp file (it contains the API token), never via argv.
    body_file=$(mktemp); chmod 600 "$body_file"; printf '%s' "$body" >"$body_file"
    args+=(-H "Content-Type: application/json" --data-binary "@$body_file")
  fi
  for attempt in 1 2 3 4 5; do
    # API key via curl config on stdin so it never appears in the process list.
    if out=$(curl "${args[@]}" "$RUNPOD_API$path" <<<"header = \"Authorization: Bearer ${RUNPOD_API_KEY}\""); then
      RP_CODE=${out##*$'\n'}; RP_BODY=${out%$'\n'*}
    else
      RP_CODE=000; RP_BODY=""
    fi
    case "$RP_CODE" in
      429|5??|000) log "RunPod API $method $path -> HTTP $RP_CODE, retrying"; sleep $(( attempt * 5 )) ;;
      *) break ;;
    esac
  done
  [[ -n "$body_file" ]] && rm -f "$body_file"
  return 0
}

rp_detail() {
  jq -r '.detail // .title // .message // .error // tostring' <<<"$RP_BODY" 2>/dev/null || printf '%s' "${RP_BODY:-no response body}"
}

# TSV: id, name, status, cost/hr — for every pod in the account (common.sh filters by name).
provider_list() {
  local cursor="" path page
  while :; do
    path="/v2/pods?limit=1000${cursor:+&cursor=$(jq -rn --arg c "$cursor" '$c|@uri')}"
    rp GET "$path"
    [[ "$RP_CODE" == 200 ]] || { log "list pods failed: HTTP $RP_CODE $(rp_detail)"; return 1; }
    page=$RP_BODY
    jq -r '.pods[] | [.id, .name, .status, (.cost // 0)] | @tsv' <<<"$page"
    [[ "$(jq -r '.pagination.hasNextPage // false' <<<"$page")" == true ]] || break
    cursor=$(jq -r '.pagination.nextCursor // empty' <<<"$page")
    [[ -n "$cursor" ]] || break
  done
}

# provider_create NAME SIZE_JSON -> prints "id<TAB>gpu<TAB>cost"
provider_create() {
  local name=$1 size=$2 image="${LLMHOST_IMAGE:?LLMHOST_IMAGE not set}" env mounts='null' dcs='[]' gpu body last=""
  env=$CONTAINER_ENV

  if [[ -n "${RUNPOD_DATA_CENTER_IDS:-}" ]]; then
    dcs=$(jq -c -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))' <<<"$RUNPOD_DATA_CENTER_IDS")
  fi

  if [[ -n "${RUNPOD_NETWORK_VOLUME_ID:-}" ]]; then
    rp GET "/v2/network-volumes/${RUNPOD_NETWORK_VOLUME_ID}"
    [[ "$RP_CODE" == 200 ]] || die "network volume ${RUNPOD_NETWORK_VOLUME_ID}: HTTP $RP_CODE $(rp_detail)"
    local vol_dc; vol_dc=$(jq -r '.dataCenter // empty' <<<"$RP_BODY")
    [[ -n "$vol_dc" ]] && dcs=$(jq -nc --arg d "$vol_dc" '[$d]')
    mounts=$(jq -nc --arg v "$RUNPOD_NETWORK_VOLUME_ID" '{network:[{volumeId:$v, path:"/workspace"}]}')
    env=$(jq -c '. + {OLLAMA_MODELS:"/workspace/ollama/models"}' <<<"$env")
    log "using network volume $RUNPOD_NETWORK_VOLUME_ID (data center: ${vol_dc:-unknown}) for model cache"
  fi

  while read -r gpu; do
    [[ -n "$gpu" ]] || continue
    body=$(jq -nc \
      --arg name "$name" --arg image "$image" --arg gpu "$gpu" --arg cloud "$RUNPOD_CLOUD" \
      --argjson disk "$(jq -r '.disk_gb // 80' <<<"$size")" \
      --argjson env "$env" --argjson mounts "$mounts" --argjson dcs "$dcs" \
      --arg port "${RUNPOD_PORT}/http" \
      --arg registry "${RUNPOD_REGISTRY_AUTH_ID:-}" --arg mincuda "${RUNPOD_MIN_CUDA_VERSION:-}" \
      '{name:$name, image:$image, cloud:$cloud, disk:$disk, ports:[$port], env:$env,
        gpu:({id:$gpu, count:1} + (if $mincuda != "" then {minCudaVersion:$mincuda} else {} end))}
       + (if $mounts != null then {mounts:$mounts} else {} end)
       + (if ($dcs|length) > 0 then {dataCenterIds:$dcs} else {} end)
       + (if $registry != "" then {registry:$registry} else {} end)')
    log "requesting $gpu ($RUNPOD_CLOUD cloud)"
    rp POST /v2/pods "$body"
    case "$RP_CODE" in
      200|201)
        jq -r --arg g "$gpu" '[.id, $g, (.cost // "?")] | @tsv' <<<"$RP_BODY"
        return 0 ;;
      400)
        # RunPod returns 400 for both "no capacity" and rule violations (see API docs).
        last=$(rp_detail); log "  not placed: $last" ;;
      401|403) die "RunPod rejected the API key (HTTP $RP_CODE): $(rp_detail)" ;;
      *) die "RunPod create failed (HTTP $RP_CODE): $(rp_detail)" ;;
    esac
  done < <(jq -r '.gpus[]' <<<"$size")

  die "no capacity for size '$SIZE' on any of: $(jq -r '.gpus|join(", ")' <<<"$size"). Last error: $last. Try another size, RUNPOD_CLOUD=COMMUNITY, or retry later."
}

# RUNPOD_PROXY_URL_TEMPLATE exists for tests against a mock API (POD_ID is replaced).
provider_url() {
  local t="${RUNPOD_PROXY_URL_TEMPLATE:-}"
  [[ -n "$t" ]] || t="https://POD_ID-${RUNPOD_PORT}.proxy.runpod.net"
  printf '%s' "${t//POD_ID/$1}"
}

provider_status() {
  rp GET "/v2/pods/$1"
  case "$RP_CODE" in
    200) jq -r '.status // "UNKNOWN"' <<<"$RP_BODY" ;;
    404) echo TERMINATED ;;
    *) echo UNKNOWN ;;
  esac
}

# Optional: live list price + availability for every GPU referenced in sizes.json.
provider_catalog() {
  rp GET "/v2/catalog/gpus?include=AVAILABILITY&product=POD"
  [[ "$RP_CODE" == 200 ]] || die "catalog request failed: HTTP $RP_CODE $(rp_detail)"
  jq -r --slurpfile sizes "$PROVIDER_DIR/sizes.json" '
    .gpus as $gpus
    | $sizes[0] | to_entries[] | .key as $size | .value.gpus[] as $id
    | ($gpus | map(select(.id == $id)) | first) as $g
    | "| \($size) | \($id) | \($g.memory // "?") GB | $\($g.price.secure // "?") | $\($g.price.community // "?") | \($g.availability // "?") |"
  ' <<<"$RP_BODY"
}

provider_terminate() {
  rp DELETE "/v2/pods/$1"
  case "$RP_CODE" in
    200|202|204) log "terminated pod $1" ;;
    404) log "pod $1 already gone" ;;
    *) die "failed to terminate pod $1 (HTTP $RP_CODE): $(rp_detail) — terminate it manually in the RunPod console!" ;;
  esac
}
