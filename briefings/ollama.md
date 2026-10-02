# Ollama — maintainer briefing

**What it is.** The Ollama model server with Open WebUI as a sidecar — a self-hosted chat UI over local
open-weight models, with GPU support where the location offers it.

**Common use cases.** Private inference on the user's own infrastructure, teams that cannot send prompts to a
hosted provider, and low-latency serving by deploying the same template to several regions.

## Architecture

| Resource | Notes |
|---|---|
| workload (stateful) | two containers — Open WebUI on `8080` (exposed) and Ollama on `11434` (internal) |
| volumeset | pulled models; these are large |
| secret | startup script that starts `ollama serve` (its model-pull block never fires — see trap below) |
| identity + policy | `reveal` on the startup secret |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `defaultModel` | `llama3` | the model Open WebUI preselects; NOT downloaded — the user pulls it once by hand |
| UI image | `ghcr.io/open-webui/open-webui:v0.11.0` | pinned in 1.1.2; was the moving `main` branch build |
| API image | `ollama/ollama:0.32.15` | pinned in 1.1.2; was **untagged**, so it resolved to `latest` |
| `volumeset` | — | size it for the models you intend to run |
| `firewall` / `internal_access` | — | the UI is the exposed surface |

## Troubleshooting traps

- **Quotas are the usual first blocker.** CPU and memory beyond org defaults need an increase, and GPU access
  must be enabled explicitly by Control Plane support.
- **`defaultModel` is never pulled automatically (open chart item; read from the chart, not observed live).** The script lives in `entrypoint.payload` and reads `$DEFAULT_MODELS`, but `workload.yaml` sets `DEFAULT_MODELS` only on the Open WebUI container — the `ollama` container has `inheritEnv: false` and no env; the pull body is also single-quoted, so `$DEFAULT_MODELS` would be sent literally; and the `MODEL_DIR` check matches untagged names only. The README and docs page say plainly that the model is not downloaded and give the manual `ollama pull` (maintainer ruling 2026-10-02: do not claim an auto-download while it is broken). Fixing it changes the render → needs a new version; tracked as a GitLab issue.
- **Never expose `11434`.** The Ollama API has no authentication; the WebUI on `8080` is the intended surface.
  Exposing the API directly hands anyone an unauthenticated model server.
- **Models live on the volumeset, and uninstall deletes it** — every model is re-downloaded on the next
  install. A default-sized volume fills quickly once a second model is pulled.
- **Both images floated until 1.1.2.** `open-webui:main` is a branch build, and the Ollama image carried no
  tag at all. An install from before 1.1.2 is not reproducible.
