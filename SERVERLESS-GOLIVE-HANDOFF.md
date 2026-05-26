# Get the FLUX.2 product-photo pipeline live on RunPod Serverless — agent handoff

**Audience:** a Claude agent running in VS Code on the user's local machine (Windows).
**User:** Docker Hub username `tomn123`. RunPod account owner.
**Goal:** make an existing RunPod Serverless endpoint actually run jobs (today it boots the wrong
thing and jobs queue forever). You will produce ONE small Docker image and configure the endpoint.

---

## 0. READ THIS FIRST — what is and isn't your job

The whole pipeline (ComfyUI + custom nodes + a Python venv + the handler code + the ~27 GB models)
**already lives on a RunPod network volume.** On a serverless worker that volume mounts at
`/runpod-volume`. So:

- ✅ **Your only deliverable is a tiny "wrapper" Docker image** (3 lines) + endpoint configuration.
- ❌ **Do NOT recreate `start.sh`, `handler.py`, `flux2_sets.py`, the workflow, or ComfyUI.** They
  already exist on the volume at `/runpod-volume/pipeline/...` and `/runpod-volume/runpod-slim/ComfyUI/...`.
  Your local machine does NOT have them and does NOT need them.
- ❌ **Do NOT pick a different base image** (see the diagnosis below — it must be `runpod/comfyui:latest`).

If you find yourself writing Python or cloning ComfyUI, stop — that's not this task.

---

## 1. The diagnosis (why this is needed — don't undo it)

The endpoint was failing in two stages, both already root-caused:

1. **A bare `nvidia/cuda` base image does not work.** The volume's venv was created
   `--system-site-packages` and carries **no torch/PIL of its own** — those come from the base
   image's `/usr/local/lib/python3.12/dist-packages`. The environment that produced the good images
   is **`runpod/comfyui:latest`** (Python 3.12 + torch 2.11.0+cu128 + the matching ComfyUI deps).
   Any other base → ComfyUI silently never boots → worker hangs at `waiting for ComfyUI...`.

2. **But `runpod/comfyui:latest` cannot be used directly either.** It is a *pod* image: its default
   `ENTRYPOINT` starts SSH / FileBrowser / Jupyter and keeps the container alive — it **never runs a
   serverless handler**, so jobs sit in the queue forever (the symptom: worker logs show SSH
   host-key generation + "Generated random SSH password" + FileBrowser init, then nothing). RunPod's
   "Container Start Command" does **not** override that `ENTRYPOINT`.

**The fix:** build a thin image `FROM runpod/comfyui:latest` that clears the entrypoint and runs the
volume's boot script. That gives the exact right Python stack AND makes it behave as a serverless
worker. Everything else stays on the volume.

---

## 2. The wrapper image (the only artifact you create)

A single `Dockerfile`, exactly this (no build context, no COPY, nothing else):

```dockerfile
FROM runpod/comfyui:latest

# runpod/comfyui:latest is a POD image: its entrypoint starts SSH/FileBrowser/Jupyter and never runs
# a serverless handler, so jobs queue forever. Clear it and run the volume's boot script, which
# starts ComfyUI from /runpod-volume and then execs handler.py (runpod.serverless.start).
ENTRYPOINT []
CMD ["bash", "/runpod-volume/pipeline/deploy/start.sh"]
```

That referenced `start.sh` and `handler.py` are ALREADY on the volume — do not create them.

---

## 3. Build it — pick ONE route

### Route A (RECOMMENDED if Docker is not already installed locally): RunPod GitHub build
RunPod builds the image for you from a GitHub repo. No local Docker needed.

1. Create a **new public GitHub repo** (e.g. `flux2-serverless`). One file at the repo root named
   `Dockerfile` with the 3-line content above. (You may use the `gh` CLI if installed, or git, or
   the GitHub web "Add file → Create new file" editor.)
2. In **RunPod console → Serverless → New Endpoint → "GitHub Repo"** as the source. Authorize RunPod's
   GitHub app, select the repo/branch. RunPod builds + hosts the image (`linux/amd64`, automatically).
3. Continue to **§4** for the endpoint settings (volume, env, GPU).
   - Future changes: edit the `Dockerfile` in GitHub → RunPod rebuilds. No re-push dance.

### Route B (use only if Docker is already installed & working locally): Docker Hub
The user's Docker Hub username is `tomn123`. In a folder containing the `Dockerfile` above:

```bash
docker login                 # username: tomn123
docker build --platform linux/amd64 -t tomn123/flux2-serverless:latest .
docker push tomn123/flux2-serverless:latest
```
- `--platform linux/amd64` is required if building on Apple Silicon; harmless elsewhere.
- The push auto-creates the public repo `tomn123/flux2-serverless`. Keep it public so RunPod pulls it
  without credentials (nothing secret is in it — it's a 3-line layer over a public base).
- Then set the endpoint's **Container Image** = `tomn123/flux2-serverless:latest` and continue to §4.

---

## 4. Configure the Serverless endpoint

In RunPod console → Serverless → the endpoint → Edit (or its Template):

| Setting | Value |
|---|---|
| **Container Image** | Route A: the GitHub-built image (RunPod fills this). Route B: `tomn123/flux2-serverless:latest` |
| **Container Start Command** | leave **empty** (the image `CMD` already runs `start.sh`). Or set `bash /runpod-volume/pipeline/deploy/start.sh` — identical. |
| **Environment Variables** | `COMFYUI_DIR=/runpod-volume/runpod-slim/ComfyUI` (exact case — capital C, capital UI). No R2 creds (the worker uses presigned URLs only). |
| **Network Volume** | Attach the existing volume (the one holding `/runpod-slim/ComfyUI` and `/pipeline`; volume id `1ba6wonu62`, datacenter **EU-RO-1**). |
| **GPU** | **≥ 32 GB** VRAM (FLUX.2 bf16 ~18 GB + Qwen3 fp8 ~9 GB + activations). 48 GB (L40S / A6000) gives headroom. Must be a GPU available in EU-RO-1 (workers lock to the volume's datacenter). |
| **Execution timeout** | Generous (first cold job pulls the image + loads the 18 GB model). |
| **Workers** | min 0 (scale to zero), max as needed. Enable **FlashBoot**. |

---

## 5. Verify (a smoke test that needs NO R2 / no presigning)

The original bug was "jobs queue forever because the handler never runs." The fastest proof that the
handler now runs is to send a deliberately-empty job and expect a *fast structured error* back:

- RunPod console → the endpoint → **Requests / Test** → send:
  ```json
  { "input": {} }
  ```
- **Expected:** within a short time (after the first cold boot) the job returns:
  ```json
  { "status": "error", "error": "missing 'sku'" }
  ```
  Getting that JSON back **proves the worker booted ComfyUI and ran `handler.py`** — the plumbing is
  fixed. (A real job with `sku`/`ref_sets`/`sets` + presigned URLs is built by the webUI; contract in
  `docs/SERVERLESS-API.md` on the volume.)

### Healthy worker log signature (in order)
```
using python: /runpod-volume/runpod-slim/ComfyUI/.venv-cu128/bin/python (Python 3.12.x)
torch 2.11.0+cu128 cuda_avail True
waiting for ComfyUI (pid ...)...
ComfyUI up.
```
(For a real job you then also see `##### set001  ref_set=...  scene=...  seed=...`.)

### If it fails, the hardened `start.sh` now tells you why (read the worker log):
- `!!! FATAL: ... cannot import torch` → wrong base image (must be `runpod/comfyui:latest`).
- `!!! ComfyUI exited during startup` + a log tail → the actual ComfyUI error is printed.
- Still SSH/FileBrowser/Jupyter spam and no `using python:` → the entrypoint wasn't overridden; the
  endpoint is still pointing at raw `runpod/comfyui:latest` instead of the wrapper image.

---

## 6. Report back to the user
State plainly: which route you used, the final image reference, whether the `{ "input": {} }` test
returned `missing 'sku'`, and paste the worker log signature. If anything failed, paste the exact
`!!!` line from the log.
