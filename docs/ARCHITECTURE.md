# Architecture & decisions

## Components

| Piece | Where | Role |
|---|---|---|
| Server image | `image/` | `ollama/ollama` (pinned) + nginx + cloudflared. Runs anywhere with a GPU and Docker. |
| Orchestrator | `scripts/llmhost.sh`, `lib/common.sh` | `up / down / status / reap / catalog`, provider-agnostic. |
| Providers | `providers/<name>/` | 6 small functions per cloud (see `providers/README.md`). |
| Workflows | `.github/workflows/` | Manual control panel, 15-min reaper, image build, CI. |

### Boot sequence (container)
1. Validate env, render nginx config with the token, start nginx on `:8080`, and publish `status.json` (`starting`).
2. Start cloudflared if a tunnel token is set.
3. Start Ollama on `127.0.0.1:11434`, which can't be reached from outside except through nginx.
4. Pull each model (`pulling`), load the first one into VRAM (`loading`), then `ready` (or `degraded` if a model failed).
5. A watchdog stops serving 15 min after expiry and asks RunPod to delete the pod (backup for the reaper).

The workflow polls `status.json` until `ready`. It then checks that an unauthenticated request gets 401 and
an authenticated one gets 200, and terminates the pod if either check fails or the run is cancelled.

## Decisions

**RunPod Pods, not Serverless.** Serverless bills only while a request runs, but:
- cold starts load 15–20 GB of weights (tens of seconds, or minutes without a network volume) after every idle period;
- the serverless per-second rate is roughly 1.5–2× the pod rate for the same GPU;
- an agent session sends requests continuously for hours, so the workers would rarely scale to zero anyway;
- a serverless worker can't run the tunnel for a fixed hostname, and its HTTP surface is RunPod's job API
  (or load-balancer endpoints), not a plain long-lived server.

For bursty, occasional API use, serverless could win. It fits the provider contract as a future
`runpod-serverless` provider without changes elsewhere.

**Ollama as the engine.** It serves OpenAI, Anthropic and native APIs from one process, hot-swaps
models, and pulls community models (`user/model:tag`, `hf.co/...` GGUF). This matches the
"any model, mostly one, sometimes several" requirement. vLLM/SGLang give higher throughput for many
concurrent users. For one user the gap is small and model management is harder, so they could be a
later image variant.

**Model selection by request body.** OpenAI, Anthropic and Ollama all put the model name in the `model`
field. One base URL serves every model, so clients only need a different `model` value. No path-per-model routing.

**Auth at nginx with a static bearer token.** It's simple and works with every client: OpenAI SDKs send `Authorization:
Bearer`, Claude Code sends `ANTHROPIC_AUTH_TOKEN` as Bearer or `ANTHROPIC_API_KEY` as `x-api-key`. Both
are accepted, compared case-sensitively, and stripped before reaching Ollama. Headers are never logged.

**Expiry encoded in the instance name** (`llmhost--exp-<epoch>`). The reaper needs no database, no
tags API and no provider-specific metadata, and the same logic works for every provider. The fixed
prefix also guarantees the tooling never touches pods it didn't create.

**Terminate, not stop.** A stopped RunPod pod still bills for its disk and may not get its GPU back.
Models persist only through the optional network volume.

**Friendly hostname through a Cloudflare Tunnel.** It's stable across deploys, needs no DNS API calls
from the workflow, includes TLS, and needs no inbound ports. Other providers get it for free because it runs in the image.

## Performance notes (27B dense model, Q4_K_M ≈ 18 GB)

Rough single-user generation speeds. Measure with `scripts/bench.sh`:
- RTX 4090: ~35–45 tok/s. L40S / RTX 6000 Ada: ~30–40 tok/s with much more context room. H100: ~50–70 tok/s.
- The defaults favor agent use: flash attention on, `q8_0` KV cache (about half the VRAM of f16 at
  near-identical quality), one parallel slot, model kept in VRAM.
- Context is the main VRAM lever. Coding agents send large system prompts, so 32k is the minimum and 64k+ is comfortable.

## Adding AWS (phase 2) — sketch

EC2 `g6e.xlarge` (L40S 48 GB) or `g6.xlarge` (L4), Deep Learning Base AMI with Docker + NVIDIA runtime, launched with
user-data `docker run --gpus all -p 8080:8080 --env-file …` of the same image; `Name` tag = instance name;
public URL through the tunnel, or the instance's public DNS behind a security group open on 8080 only.
Credentials through GitHub OIDC → IAM role (no long-lived keys). Only `providers/aws/provider.sh` changes.
