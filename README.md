# pi-llama

OpenAI-compatible LLM server for Raspberry Pi 5, powered by llama.cpp.

Runs **Qwen 3.5 4B** (Q4\_K\_M, 3 GB) on port `5370`. Designed to sit alongside a Hermes agent and Firecrawl container on a shared Pi — the defaults are tuned for that (~3.3 GB RAM including KV cache, leaving room for the rest of the stack).

Context is set to 4096 tokens by default — enough for ComfyUI workflow prompts and typical agent conversations.

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
http://<pi-ip>:5370/v1/chat/completions
http://<pi-ip>:5370/v1/completions
http://<pi-ip>:5370/health
```

Point Hermes, Open WebUI, or any OpenAI-compatible client at `http://<pi-ip>:5370/v1`.

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

## Performance

Expect ~4-6 tokens/sec decode with Qwen 3.5 4B Q4\_K\_M on Pi 5 8 GB. Prompt evaluation runs faster (~30 tok/s). If you need more speed and less quality, swap to a 1.5B model in `.env`.

## License

Apache-2.0
