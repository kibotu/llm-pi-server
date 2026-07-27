#!/usr/bin/env bash
#
# pi-llama — one-shot setup & run for llama.cpp on Raspberry Pi 5
#
# Usage:
#   ./run.sh              install deps, download model, start server
#   ./run.sh down         stop and clean up containers
#   ./run.sh -v           verbose (show raw docker/hf output)
#   ./run.sh --force      re-download model even if present
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
MODELS_DIR="$ROOT_DIR/models"
LOCK_FILE="/tmp/pi-llama.lock"
CONTAINER_NAME="pi-llama"

VERBOSE=0
FORCE_DOWNLOAD=0
ACTION="up"

for arg in "$@"; do
  case "$arg" in
    -v|--verbose)  VERBOSE=1 ;;
    --force)       FORCE_DOWNLOAD=1 ;;
    down|stop)     ACTION="down" ;;
    *)             echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ── TUI ──────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RST=$'\e[0m'; DIM=$'\e[2m'; BOLD=$'\e[1m'
  GRN=$'\e[32m'; YLW=$'\e[33m'; RED=$'\e[31m'; BLU=$'\e[34m'; CYN=$'\e[36m'
else
  RST=""; DIM=""; BOLD=""; GRN=""; YLW=""; RED=""; BLU=""; CYN=""
fi

ok()   { printf "  ${GRN}✔${RST} %s\n" "$1"; }
skip() { printf "  ${DIM}· %s (already done)${RST}\n" "$1"; }
warn() { printf "  ${YLW}! %s${RST}\n" "$1"; }
fail() { printf "  ${RED}✘ %s${RST}\n" "$1"; }
step() { printf "\n${BOLD}${BLU}▸ %s${RST}\n" "$1"; }
die()  { fail "$1"; exit 1; }
hint() { printf "       ${DIM}→ %s${RST}\n" "$1"; }

need() {
  local cmd="$1" pkg="${2:-$1}" install_cmd="$3"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "$cmd not found"
    hint "$install_cmd"
    exit 1
  fi
}

run_quiet() {
  local desc="$1"; shift
  if (( VERBOSE )); then
    "$@"
  else
    if ! out=$("$@" 2>&1); then
      printf "%s\n" "$out" >&2
      die "$desc"
    fi
  fi
}

banner() {
  printf "\n${BOLD}${CYN}  🦙 pi-llama${RST}${DIM}  —  llama.cpp for Raspberry Pi 5${RST}\n"
  printf "${DIM}  ─────────────────────────────────────────────${RST}\n"
}

# ── Cleanup ──────────────────────────────────────────────────────────

cleanup() {
  trap - INT TERM EXIT
  step "Shutting down"
  docker compose -f "$ROOT_DIR/docker-compose.yml" down --remove-orphans >/dev/null 2>&1 || true
  rm -f "$LOCK_FILE"
  ok "Container stopped. Model kept on disk."
}

if [[ "$ACTION" == "down" ]]; then
  cleanup
  exit 0
fi

trap cleanup INT TERM EXIT

# ── Single-instance lock ─────────────────────────────────────────────

if [[ -f "$LOCK_FILE" ]]; then
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "Already running (pid $old_pid). Run './run.sh down' first."
  fi
fi
echo $$ > "$LOCK_FILE"

banner

# ── 1. Configuration ─────────────────────────────────────────────────

step "Configuration"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env not found"
  hint "cp env.example .env && nano .env"
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${hf:-}" ]]; then
  fail "hf= (Hugging Face token) not set in .env"
  hint "echo 'hf=hf_YOUR_TOKEN' >> .env"
  exit 1
fi
export HF_TOKEN="$hf"

MODEL_REPO="${MODEL_REPO:-bartowski/Qwen_Qwen3.5-4B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen_Qwen3.5-4B-Q4_K_M.gguf}"
LLAMA_PORT="${LLAMA_PORT:-5370}"
CTX_SIZE="${CTX_SIZE:-4096}"
LLAMA_THREADS="${LLAMA_THREADS:-4}"

ok "model  ${DIM}${MODEL_FILE}${RST}"
ok "port   ${DIM}${LLAMA_PORT}${RST}"
ok "ctx    ${DIM}${CTX_SIZE}${RST}"

# ── 2. Preflight ─────────────────────────────────────────────────────

step "Preflight"

need docker docker "curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker \$USER"
if ! docker info >/dev/null 2>&1; then
  fail "docker daemon not reachable"
  hint "sudo systemctl start docker"
  hint "sudo usermod -aG docker \$USER && newgrp docker"
  exit 1
fi
ok "docker"

if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose v2 plugin not found"
  hint "sudo apt-get install docker-compose-plugin"
  exit 1
fi
ok "docker compose"

if [[ -f /proc/meminfo ]]; then
  mem_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if (( mem_mb < 2500 )); then
    warn "Low memory (${mem_mb}MB free). 4B Q4_K_M needs ~3.3GB with context."
  else
    ok "memory ${DIM}${mem_mb}MB available${RST}"
  fi
fi

mkdir -p "$MODELS_DIR"

# ── 3. Hugging Face CLI ──────────────────────────────────────────────

step "Hugging Face CLI"

if command -v hf >/dev/null 2>&1; then
  skip "hf CLI"
else
  if ! command -v pip3 >/dev/null 2>&1; then
    fail "pip3 not found (needed to install hf CLI)"
    hint "sudo apt-get install python3-pip"
    exit 1
  fi
  run_quiet "installing huggingface_hub[cli]" pip3 install --user -q "huggingface_hub[cli]"
  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v hf >/dev/null 2>&1; then
    fail "hf CLI not on PATH after install"
    hint "pip3 install -U 'huggingface_hub[cli]'"
    hint "export PATH=\"\$HOME/.local/bin:\$PATH\""
    exit 1
  fi
  ok "installed hf CLI"
fi

# ── 4. Model download ────────────────────────────────────────────────

step "Model"

MODEL_PATH="$MODELS_DIR/$MODEL_FILE"

if [[ "$FORCE_DOWNLOAD" == "0" ]] && [[ -f "$MODEL_PATH" ]] \
   && (( $(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0) > 1000000 )); then
  skip "$MODEL_FILE ($(du -h "$MODEL_PATH" | cut -f1))"
else
  printf "  ${DIM}downloading %s …${RST}\n" "$MODEL_FILE"
  if (( VERBOSE )); then
    hf download "$MODEL_REPO" --include "$MODEL_FILE" --local-dir "$MODELS_DIR" --token "$HF_TOKEN"
  else
    hf download "$MODEL_REPO" --include "$MODEL_FILE" --local-dir "$MODELS_DIR" --token "$HF_TOKEN" \
      2>&1 | grep -iE 'error|fail|%' || true
  fi
  [[ -f "$MODEL_PATH" ]] || die "download finished but $MODEL_FILE not found"
  ok "downloaded $MODEL_FILE ($(du -h "$MODEL_PATH" | cut -f1))"
fi

# ── 5. Start server ──────────────────────────────────────────────────

step "Starting pi-llama"

export MODEL_FILE LLAMA_PORT CTX_SIZE LLAMA_THREADS

run_quiet "pulling/starting container" docker compose -f "$ROOT_DIR/docker-compose.yml" up -d

ok "container started"

# ── 6. Health check ──────────────────────────────────────────────────

step "Health check"

healthy=0
for i in $(seq 1 40); do
  if curl -fs "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if (( healthy )); then
  ok "server is healthy"
else
  warn "server not yet healthy after 80s — check: docker logs $CONTAINER_NAME"
fi

# ── 7. Running ────────────────────────────────────────────────────────

step "Ready"

printf "\n"
printf "  ${BOLD}OpenAI-compatible API${RST}\n"
printf "  ${CYN}http://localhost:${LLAMA_PORT}/v1${RST}\n"
printf "\n"
printf "  ${DIM}model   ${RST}%s\n" "$MODEL_FILE"
printf "  ${DIM}ctx     ${RST}%s tokens\n" "$CTX_SIZE"
printf "  ${DIM}threads ${RST}%s\n" "$LLAMA_THREADS"
printf "\n"
printf "  ${DIM}Ctrl-C to stop.${RST}\n\n"

while true; do
  sleep 30
  if ! curl -fs "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
    warn "health check failed — docker logs $CONTAINER_NAME"
  fi
done
