# SyncSystem · LLM Models Host

Spin up your own open-source LLM on a rented GPU with one click in GitHub Actions. Point Claude Code,
OpenClaw or any OpenAI/Anthropic/Ollama-compatible tool at it, and tear it down when you're done.
It also shuts itself down after 6 hours, so a forgotten server can't keep billing you.

```
GitHub Actions ──(RunPod API)──▶ GPU pod ┌ nginx :8080 ── token check ──▶ Ollama (models)
   up / down / status                    │      └─ / dashboard, /status.json
   auto-shutdown (cron)                  └ cloudflared ─▶ https://llm-models-host.mydomain.com
```

## Concepts

- **One server, many models.** Ollama serves every installed model behind one URL. You choose the
  model the standard way, with the `model` field of each request. No per-model URLs needed.
- **Three APIs on one URL:** OpenAI-compatible `/v1/chat/completions`, Anthropic-compatible
  `/v1/messages` (Claude Code), and Ollama native `/api/*`.
- **Static token.** Every API call needs `Authorization: Bearer <token>` or `x-api-key: <token>`.
  The token is a GitHub secret, and you rotate it by changing the secret and redeploying.
- **Friendly hostname** (optional) through a Cloudflare Tunnel running inside the pod. The pod ID
  changes on every deploy, but `llm-models-host.mydomain.com` doesn't.
- **Ephemeral by design.** `down` *terminates* the pod (nothing keeps billing). The expiry time is
  stored in the pod name, so a scheduled job can reap it with no state to manage.
- **Pluggable providers.** RunPod ships first and AWS is stubbed for phase 2. See
  [providers/README.md](providers/README.md).

## Quick start

1. **One-time setup:** follow [docs/SETUP.md](docs/SETUP.md) (≈15 min). You'll create a RunPod API key, an
   API token, and optionally a Cloudflare Tunnel, add them as secrets, build the image, and secure the repo.
2. **Start:** go to Actions → **LLM host** → *Run workflow*, then choose `action: up`, a size, and the models.
3. **Wait.** The first boot downloads the image and the model (~5–15 min for a 27B model). The run
   summary shows the URL, the real hourly rate and the shutdown time.
4. **Check** that it works by opening the URL in a browser. The dashboard shows status, models,
   endpoints and copy-paste snippets, and lets you test your token.
5. **Stop:** run **LLM host** again with `action: down`, or just let auto-shutdown handle it.

### Sizes (RunPod, secure cloud, 1 GPU)

| Size | GPU (first available) | Est. $/h | Default context | Good for |
|---|---|---|---|---|
| small | RTX 4090 → 3090 → A5000 (24 GB) | ~0.69 | 32k | 27B at Q4, single user |
| medium | L40S → RTX 6000 Ada → A6000 (48 GB) | ~0.86 | 64k | agents with long context, 27B at Q8 |
| large | H100 (80 GB) | ~2.69 | 128k | fastest; 70B at Q4; several models |

Prices change. Run the workflow with `action: catalog` to see live prices and availability. Pods are
billed per second while they run, plus a negligible container disk. Edit
[providers/runpod/sizes.json](providers/runpod/sizes.json) to change the GPUs.

## Using it

Replace the URL, token and model with your own. The dashboard renders all of these filled in.

**Claude Code** (talks to Ollama's Anthropic-compatible API; this is what `ollama launch claude` sets up locally):

```bash
export ANTHROPIC_BASE_URL="https://llm-models-host.mydomain.com"
export ANTHROPIC_AUTH_TOKEN="<token>"
export ANTHROPIC_API_KEY=""
claude --model "orcarouter/Qwen3.8-27B-Uncensored:q4_K_M"
```

**OpenClaw, Codex, Continue, Cline, Open WebUI, OpenAI SDKs:** add a custom OpenAI-compatible provider
with base URL `https://llm-models-host.mydomain.com/v1`, API key `<token>`, and the model name as shown on the dashboard.

**Ollama clients:** `Client(host="https://…", headers={"Authorization": "Bearer <token>"})`.
The `ollama` CLI itself can't send a custom token, so use the APIs above with it.

**Speed check:** `LLMHOST_TOKEN=<token> bash scripts/bench.sh https://llm-models-host.mydomain.com`
prints prompt and generation tokens/s, which you can compare with `ollama run <model> --verbose` on an Ollama cloud model.

## Configuration

| Name | Kind | Default | Purpose |
|---|---|---|---|
| `RUNPOD_API_KEY` | secret | — | RunPod API key |
| `LLMHOST_API_TOKEN` | secret | — | token clients send (`openssl rand -hex 32`) |
| `CLOUDFLARE_TUNNEL_TOKEN` | secret | — | optional, enables the friendly hostname |
| `PUBLIC_HOSTNAME` | variable | — | e.g. `llm-models-host.mydomain.com` |
| `DEFAULT_MODELS` | variable | — | e.g. `orcarouter/Qwen3.8-27B-Uncensored:q4_K_M` (comma-separated) |
| `AUTO_SHUTDOWN_HOURS` | variable | `6` | hours until auto-teardown (max 72) |
| `RUNPOD_CLOUD` | variable | `SECURE` | `COMMUNITY` is cheaper but less reliable |
| `RUNPOD_NETWORK_VOLUME_ID` | variable | — | caches models between deploys (faster boots) |
| `RUNPOD_DATA_CENTER_IDS` | variable | — | restrict placement, e.g. `US-TX-3,EU-RO-1` |
| `LLMHOST_IMAGE` | variable | `ghcr.io/<owner>/<repo>:latest` | server image to run |
| `DEPLOYMENT_NAME` | variable | `llmhost` | pod name prefix; only pods matching it are ever touched |
| `READY_TIMEOUT_MINUTES` | variable | `45` | how long `up` waits before giving up (and terminating) |
| `KEEP_ON_FAILURE` | variable | `false` | keep a failed pod for debugging |
| `OLLAMA_KV_CACHE_TYPE` | variable | `q8_0` | `f16` for max quality, `q4_0` for more context |

## Repository layout

```
.github/workflows/  llm-host.yml (up/down/status/catalog) · auto-shutdown.yml · build-image.yml · ci.yml
image/              Dockerfile, entrypoint, nginx auth proxy, dashboard
lib/common.sh       provider-agnostic orchestration
providers/<name>/   provider.sh + sizes.json (runpod, aws stub)
scripts/            llmhost.sh (CLI), test-image.sh (local smoke test), bench.sh
docs/               SETUP.md (step-by-step), ARCHITECTURE.md (decisions)
```

**Run locally without a GPU:** `docker build -t llmhost:dev image && bash scripts/test-image.sh llmhost:dev`.
The CLI also works from your machine with the same environment variables, for example
`PROVIDER=runpod RUNPOD_API_KEY=… bash scripts/llmhost.sh status`.

## Good to know

- Auto-shutdown runs every 15 min from `main` only. GitHub can delay scheduled runs and **disables
  them after 60 days without repo activity**. As a backup, the server stops itself 15 min after its expiry.
- The dashboard and `/status.json` are public (state, model names, expiry). Everything else needs the token.
- Both the Cloudflare hostname and the RunPod proxy drop requests that get no response for 100 s.
  Agents stream tokens as they're generated, so this rarely matters. If a tool doesn't, turn on `stream: true`.
- Community "uncensored" models are third-party uploads. Check the publisher and the license.
