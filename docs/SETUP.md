# Setup (one time)

Steps 1–5 are required. Step 3 (friendly hostname) is optional; without it you use the
`https://<pod-id>-8080.proxy.runpod.net` URL, which changes on every deploy.

## 1. RunPod API key

1. Go to [console.runpod.io](https://console.runpod.io) → **Settings → API Keys → Create API Key**.
2. Name it `github-llm-models-host` and give it **Read/Write** access. If restricted keys are
   offered, Pods read/write, network volumes read and catalog read are enough.
3. Copy the key now; you can't view it again.
4. Add credit under **Billing**. Pods won't start with a zero balance.
   Optionally enable auto-pay with a **spending limit** as a second safety net.

**Optional: model cache volume.** Without one, each deploy downloads the model again. Datacenter
bandwidth is fast, and an 18 GB model takes ~2–5 min. To skip that: **Storage → New Network Volume**, pick a
data center that has your preferred GPUs, size ≈ models + 20%, e.g. 50 GB at ~$0.07/GB/month,
then set the `RUNPOD_NETWORK_VOLUME_ID` variable. This pins pods to that data center, which can limit GPU availability.

**Ollama account:** not needed. Public models (including community ones like
`orcarouter/Qwen3.8-27B-Uncensored`) pull without a key. Your paid Ollama plan only covers Ollama's
own cloud models, which are useful as the speed baseline (see `scripts/bench.sh`).

## 2. API token for your endpoint

Generate a random token (Git Bash, macOS or Linux):

```bash
openssl rand -hex 32
```

Keep it in your password manager. You'll paste it into your agents. Allowed: 32–128 characters of `A–Z a–z 0–9 _ -`.

## 3. Friendly hostname: Cloudflare Tunnel (optional)

Requires `mydomain.com` to use Cloudflare DNS (free plan is fine). A plain CNAME to RunPod doesn't
work, because the pod ID changes on every deploy and RunPod's proxy doesn't serve custom domains.
The tunnel runs inside the pod and dials out to Cloudflare, so the hostname stays fixed and gets a valid TLS certificate.

1. Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel** → **Cloudflared**.
2. Name: `llm-models-host`. On the install screen, copy the long token after `--token` (starts with `eyJ`).
   You don't need to install anything; the pod runs cloudflared.
3. **Public hostname** tab → *Add*: subdomain `llm-models-host`, domain `mydomain.com`,
   service **HTTP** → `localhost:8080`. Save. Cloudflare creates the DNS record.
4. The tunnel shows *Inactive* until a server is up. That's expected.

## 4. GitHub secrets and variables

Repo → **Settings → Secrets and variables → Actions**.

**Secrets** tab → *New repository secret*:

| Name | Value |
|---|---|
| `RUNPOD_API_KEY` | from step 1 |
| `LLMHOST_API_TOKEN` | from step 2 |
| `CLOUDFLARE_TUNNEL_TOKEN` | from step 3 (optional) |

**Variables** tab → *New repository variable*:

| Name | Value |
|---|---|
| `DEFAULT_MODELS` | `orcarouter/Qwen3.8-27B-Uncensored:q4_K_M` |
| `PUBLIC_HOSTNAME` | `llm-models-host.mydomain.com` (only with step 3) |
| `AUTO_SHUTDOWN_HOURS` | `6` |

The other variables are optional; see the table in the [README](../README.md#configuration).
To rotate the token: update `LLMHOST_API_TOKEN`, run `up` with `recreate: true`, and update your agents.

## 5. Build the server image

1. Actions → **Build image** → *Run workflow* (it also runs automatically when `image/` changes on `main`).
2. After the first run, open your profile → **Packages** → this repo's package → **Package settings** →
   **Change visibility → Public**. RunPod can then pull it without credentials. The image holds no secrets;
   they're passed at runtime.

   To keep the image private, create a registry credential in RunPod (**Settings → Container Registry
   Auth**, using a GitHub PAT with `read:packages`) and set its id as the `RUNPOD_REGISTRY_AUTH_ID` variable.

## 6. Secure the repository (public repo)

Secrets are never given to workflows triggered from forks. The real risks are someone changing the
workflows on `main` and mistakes such as leaked keys. Settings:

**Settings → Actions → General**
- *Fork pull request workflows from outside collaborators* → **Require approval for all external contributors**.
- *Workflow permissions* → **Read repository contents and packages permissions**; leave
  *Allow GitHub Actions to create and approve pull requests* **unchecked**.
- Optional: *Actions permissions* → **Allow \<owner\>, and select non-\<owner\>, actions** and allow
  `actions/*` and `docker/*` only.

**Settings → Rules → Rulesets → New branch ruleset**
- Name `protect-main`, Enforcement **Active**, Target **Include default branch**.
- Enable **Restrict deletions** and **Block force pushes**.
- Enable **Require a pull request before merging** with *Required approvals* = 0 (you're the only
  maintainer; the PR still gives CI a gate and a reviewable diff).
- Enable **Require status checks to pass** → add `checks` (from the CI workflow; it appears after its first run).
- *Bypass list*: add **Repository admin** only if you want to push straight to `main` in an emergency.

**Settings → Code security**
- Enable **Secret scanning** and **Push protection** (free for public repos), so an accidentally
  committed key gets blocked.
- Enable **Dependabot alerts** and **Dependabot security updates**. `.github/dependabot.yml` keeps
  the pinned action SHAs and the Ollama base image current through PRs.

**Settings → Collaborators:** keep it at just you. Anyone with write access can run the workflows,
and therefore spend your RunPod credit.

**Stricter, optional:** move the three secrets into an environment (**Settings → Environments →
New environment** `llm-host`, *Deployment branches* = `main`), add `environment: llm-host` to the jobs in
`llm-host.yml` and `auto-shutdown.yml`, and delete the repository-level secrets. Then only workflows
running from `main` can read them. The downside is a deployment entry in the environment's history every 15 min from the cron.

## 7. First deploy and manual validation

1. Actions → **LLM host** → *Run workflow*: `action: catalog`. Confirms the RunPod key works and shows live prices.
2. `action: up`, `size: small` (or `medium` for agent work with long context). Wait for the green run.
3. Open the URL from the run summary, or `https://llm-models-host.mydomain.com`. The dashboard shows **ready**.
   Paste your token into *Check your token*.
4. Run `LLMHOST_TOKEN=… bash scripts/bench.sh https://llm-models-host.mydomain.com`.
5. Point Claude Code at it (README → *Using it*) and try a small task.
6. `action: down`. Check that the pod is gone at [console.runpod.io/pods](https://console.runpod.io/pods).
7. Test auto-shutdown once: `up` with `auto_shutdown_hours: 0.25`, then confirm the **Auto-shutdown** run
   terminates it within ~30 min.
