# Providers

A provider is a folder `providers/<name>/` with two files:

| File | Purpose |
|---|---|
| `provider.sh` | Bash functions implementing the contract below (sourced by [`lib/common.sh`](../lib/common.sh)). |
| `sizes.json` | `small` / `medium` / `large` → provider-specific spec. Must include `est_usd_per_hour`, `context_length`, `disk_gb`; anything else is yours. |

Everything else — instance naming, expiry, readiness polling, the auth smoke test, the reaper,
GitHub summaries — is shared, so a new provider is usually ~100 lines.

## Contract

| Function | Must |
|---|---|
| `provider_validate` | Check required secrets/vars; `die` with a clear message if missing. Call `mask` on secrets. |
| `provider_list` | Print **every** instance in the account as TSV: `id  name  status  cost_per_hour`. Return non-zero on API failure (never print an empty list on error — the reaper relies on this). |
| `provider_create NAME SIZE_JSON` | Start the container image `$LLMHOST_IMAGE` on one GPU, expose container port **8080** over HTTPS, pass `$CONTAINER_ENV` (a JSON object) as environment variables, and name the instance exactly `NAME`. Print `id  gpu_name  cost_per_hour`. |
| `provider_url ID` | Print the public HTTPS base URL for port 8080. |
| `provider_status ID` | Print a status word. `ERROR`, `TERMINATED`, `EXITED` or `FAILED` aborts `up`. |
| `provider_terminate ID` | Delete the instance and everything billed with it. Treat "already gone" as success. |
| `provider_catalog` | *Optional.* Print markdown table rows of live prices for the GPUs in `sizes.json`. |

Helpers available from `lib/common.sh`: `log`, `warn`, `die`, `mask`, `SIZE`, `PROVIDER_DIR`.

The instance name is `<DEPLOYMENT_NAME>--exp-<unix-epoch>`. The expiry lives in the name so that
the auto-shutdown job needs no state store and works the same for every provider.

## Adding one

1. `cp -r providers/aws providers/<name>` and implement the functions.
2. Add `<name>` to the `provider` choice in [`.github/workflows/llm-host.yml`](../.github/workflows/llm-host.yml)
   and to the `matrix.provider` list in [`auto-shutdown.yml`](../.github/workflows/auto-shutdown.yml).
3. Add its secrets to the `llm-host` environment and pass them in the workflow `env:` blocks.
