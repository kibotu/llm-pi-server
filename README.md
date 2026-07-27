# pi-llama

OpenAI-compatible LLM server for Raspberry Pi 5, powered by llama.cpp.

Runs **Qwen 3.5 4B** (Q4\_K\_M, 3 GB) on port `5370`. Designed to sit alongside a Hermes agent and Firecrawl container on a shared Pi — the defaults are tuned for that (~3.3 GB RAM including KV cache, leaving room for the rest of the stack).

Context is set to 16384 tokens by default — enough for ComfyUI workflow prompts and typical agent conversations. KV cache is quantized to `q8_0` (halves memory vs the default `f16` with negligible quality loss), and model weights are locked in RAM (`--mlock` + `--no-mmap`) to prevent page-cache eviction under memory pressure from other containers.

## Quick start

```bash
git clone <repo-url> && cd llm-pi-server
cp env.example .env
# edit .env — set hf= to your Hugging Face token
./run.sh
```

The script will:
1. Install the `hf` CLI if missing
2. Download the model (~3 GB, skipped if already present)
3. Pull and start the llama.cpp Docker container
4. Wait for the health check, then keep running until you hit Ctrl-C
5. Clean up the container on exit

## API

```
http://localhost:5370/v1/chat/completions
http://localhost:5370/v1/completions
http://localhost:5370/health
```

The container exposes port 5370 on all host interfaces, so services on the same Pi (Hermes, Open WebUI, etc.) reach it at `http://localhost:5370/v1`. From other machines on your network, use `http://<pi-ip>:5370/v1`.

## Configuration

All settings live in `.env`:

| Variable | Default | Notes |
|---|---|---|
| `hf` | — | Hugging Face token (required) |
| `MODEL_REPO` | `bartowski/Qwen_Qwen3.5-4B-GGUF` | HF repo |
| `MODEL_FILE` | [`Qwen_Qwen3.5-4B-Q4_K_M.gguf`](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF?show_file_info=Qwen_Qwen3.5-4B-Q4_K_M.gguf) | GGUF filename |
| `LLAMA_PORT` | `5370` | Host port |
| `CTX_SIZE` | `16384` | Context window (tokens) |
| `LLAMA_THREADS` | `4` | CPU threads (Pi 5 has 4 cores) |

### Tuning flags (set in `docker-compose.yml`)

| Flag | Value | Why |
|------|-------|-----|
| `-ctk` / `-ctv` | `q8_0` | KV cache quantization — halves memory vs `f16` with negligible quality loss. Use `q4_0` to push context higher. |
| `--flash-attn` | `on` | Fused attention kernels — reduces memory overhead and speeds up longer-context prefill on ARM NEON. |
| `--jinja` | on | Use the model's built-in Jinja chat template. Required for correct Qwen3.x prompting and tool calling. |
| `--mlock` | on | Lock model weights in RAM so the OS never pages them under pressure from Hermes / Firecrawl. |
| `--no-mmap` | on | Read weights into RAM upfront instead of lazy mmap. Slower cold start, but avoids page-cache eviction stalls on a multi-service Pi. |
| `--metrics` | on | Expose Prometheus-style metrics at `/metrics` for monitoring tok/s. |
| `--cont-batching` | on | Continuous batching for concurrent requests. |

## Requirements

- Raspberry Pi 5 (8 GB recommended)
- Raspberry Pi OS 64-bit or Ubuntu 24.04 ARM64
- Docker + Docker Compose v2
- Active cooling (all 4 cores run at high utilization during inference)

## Commands

```bash
./run.sh              # start (idempotent, safe to re-run)
./run.sh down         # stop and remove container
./run.sh --force      # re-download model
./run.sh -v           # verbose output
```

## Hermes integration

Add the Pi server as a **custom provider**, a **model alias**, and optionally as the **fallback model** so Hermes falls back to your local hardware when all cloud providers fail.

### 1. Custom provider

```yaml
custom_providers:
  - name: pi
    base_url: http://localhost:5370/v1
    api_key: sk-no-key-required
    api_mode: chat_completions
    models:
      /models/Qwen_Qwen3.5-4B-Q4_K_M.gguf:
        context_length: 65536
```

> **Important:**
> - The model ID must match exactly what the server reports at `/v1/models`.
>   llama.cpp uses the full path passed to `-m` (e.g. `/models/Qwen_Qwen3.5-4B-Q4_K_M.gguf`).
> - Hermes requires at least 64K context. The server runs with 16K for memory reasons,
>   but you must advertise `context_length: 65536` (or higher) so Hermes doesn't reject
>   the model at init. Conversations exceeding the actual server limit will be truncated.
> - If Hermes runs on a different machine, replace `localhost` with the Pi's IP.

### 2. Model alias (quick switch with `/pi`)

```yaml
model_aliases:
  pi:
    provider: custom:pi
    model: /models/Qwen_Qwen3.5-4B-Q4_K_M.gguf
    base_url: http://localhost:5370/v1
    api_key: sk-no-key-required
```

Then switch at any time:

```
/model pi
```

Or add a quick command:

```yaml
quick_commands:
  pi:
    type: alias
    target: /model pi
```

### 3. Fallback model (last resort when everything else is down)

```yaml
fallback_model:
  provider: custom:pi
  model: /models/Qwen_Qwen3.5-4B-Q4_K_M.gguf
  base_url: http://localhost:5370/v1
  api_key: sk-no-key-required
```

When the default model and all other configured providers return errors, Hermes automatically routes to the Pi. This keeps you operational even during cloud outages — responses will be slower but you stay unblocked.

## Performance

Measured with Qwen 3.5 4B Q4\_K\_M on Pi 5 8 GB:

- **Prompt eval:** ~7.7 tok/s
- **Decode:** ~2.8 tok/s

Slower than GPU-backed servers, but sufficient as a fallback or for short completions. If you need more speed and less quality, swap to a 1.5B model in `.env`.

## License

Apache-2.0
