#!/usr/bin/env bash
# Measures generation speed (tokens/sec) of a deployed server, using Ollama's own timings.
# Usage: LLMHOST_TOKEN=... scripts/bench.sh https://llm-models-host.mydomain.com [model] [runs]
# Compare against the same prompt on an Ollama cloud model: `ollama run <model>:cloud --verbose`.
set -Eeuo pipefail

BASE="${1:?usage: scripts/bench.sh <base-url> [model] [runs]}"; BASE="${BASE%/}"
TOKEN="${LLMHOST_TOKEN:?set LLMHOST_TOKEN}"
MODEL="${2:-}"
RUNS="${3:-3}"
PROMPT="Write a Python function that parses an ISO-8601 duration like P3DT4H5M into seconds, with tests."

auth=(-K -)
hdr() { printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"; }

if [[ -z "$MODEL" ]]; then
  MODEL=$(hdr | curl -fsS "${auth[@]}" "$BASE/api/tags" | jq -r '.models[0].name')
fi
echo "model: $MODEL  runs: $RUNS  url: $BASE"
printf '%-5s %12s %14s %12s\n' run prompt_tok/s generate_tok/s ttft_s

for i in $(seq 1 "$RUNS"); do
  start=$(date +%s.%N)
  out=$(hdr | curl -fsS "${auth[@]}" -m 600 "$BASE/api/generate" \
    -d "$(jq -nc --arg m "$MODEL" --arg p "$PROMPT" '{model:$m,prompt:$p,stream:false,options:{num_predict:400}}')")
  end=$(date +%s.%N)
  jq -r --arg i "$i" --arg wall "$(awk -v a="$start" -v b="$end" 'BEGIN{print b-a}')" '
    def rate(n; d): if (d // 0) > 0 then (n / (d / 1e9) * 10 | round / 10) else 0 end;
    [$i, rate(.prompt_eval_count; .prompt_eval_duration), rate(.eval_count; .eval_duration),
     (((.load_duration // 0) + (.prompt_eval_duration // 0)) / 1e9 * 100 | round / 100)]
    | @tsv' <<<"$out" | awk -F'\t' '{printf "%-5s %12s %14s %12s\n", $1, $2, $3, $4}'
done
