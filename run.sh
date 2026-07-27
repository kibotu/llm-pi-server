#!/usr/bin/env bash
#
# run.sh - Hermes fallback stack for Raspberry Pi 5
#   llama.cpp OpenAI-compatible server + Hermes agent + Firecrawl
#
# Usage:
#   ./run.sh              start (or reattach to) the stack, foreground
#   ./run.sh down         stop and clean up everything
#   ./run.sh -v           verbose (show raw docker/hf output)
#   ./run.sh --force      re-download the model even if it already exists
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths / constants
# ---------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

ENV_FILE="$ROOT_DIR/.env"
MODELS_DIR="$ROOT_DIR/models"
VENDOR_DIR="$ROOT_DIR/vendor"
FIRECRAWL_DIR="$VENDOR_DIR/firecrawl"
FIRECRAWL_REPO_URL="https://github.com/mendableai/firecrawl.git"
LOCK_FILE="/tmp/hermes-stack.lock"
NETWORK="hermes-net"

VERBOSE=0
FORCE_DOWNLOAD=0
ACTION="up"

for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    --force) FORCE_DOWNLOAD=1 ;;
    down|stop) ACTION="down" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# TUI helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

ok()    { printf "  %s✔%s %s\n" "$C_GREEN" "$C_RESET" "$1"; }
skip()  { printf "  %s·%s %s %s(already done)%s\n" "$C_DIM" "$C_RESET" "$1" "$C_DIM" "$C_RESET"; }
warn()  { printf "  %s!%s %s\n" "$C_YELLOW" "$C_RESET" "$1"; }
fail()  { printf "  %s✘%s %s\n" "$C_RED" "$C_RESET" "$1"; }
step()  { printf "\n%s%s%s\n" "$C_BOLD$C_BLUE" "$1" "$C_RESET"; }
die()   { fail "$1"; exit 1; }

run_quiet() {
  # run_quiet "description" cmd args...
  local desc="$1"; shift
  if [[ "$VERBOSE" == "1" ]]; then
    "$@"
  else
    if ! out=$("$@" 2>&1); then
      printf "%s\n" "$out" >&2
      die "$desc"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Cleanup / signal handling
# ---------------------------------------------------------------------------
cleanup() {
  trap - INT TERM EXIT
  step "Shutting down"
  docker compose -f "$ROOT_DIR/docker-compose.yml" --profile hermes down --remove-orphans >/dev/null 2>&1 || true
  if [[ -f "$FIRECRAWL_DIR/docker-compose.yml" ]]; then
    docker compose -f "$FIRECRAWL_DIR/docker-compose.yml" --env-file "$FIRECRAWL_DIR/.env" down --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f "$LOCK_FILE"
  ok "Containers stopped, models and caches kept on disk"
}

if [[ "$ACTION" == "down" ]]; then
  cleanup
  exit 0
fi

trap cleanup INT TERM EXIT

# ---------------------------------------------------------------------------
# Single-instance lock (safe to re-run; recovers from stale locks)
# ---------------------------------------------------------------------------
if [[ -f "$LOCK_FILE" ]]; then
  old_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "Already running (pid $old_pid). Use './run.sh down' first, or wait for it to exit."
  fi
fi
echo $$ > "$LOCK_FILE"

echo "${C_BOLD}Hermes fallback stack — Raspberry Pi 5${C_RESET}"

# ---------------------------------------------------------------------------
# 1. .env
# ---------------------------------------------------------------------------
step "Configuration"
if [[ ! -f "$ENV_FILE" ]]; then
  die ".env not found. Copy .env.example to .env and set your hf= token first."
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ -n "${hf:-}" ]] || die "hf= (Hugging Face token) is not set in .env"
export HF_TOKEN="$hf"

MODEL_REPO="${MODEL_REPO:-bartowski/Qwen_Qwen3.5-4B-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen_Qwen3.5-4B-Q4_0.gguf}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
CTX_SIZE="${CTX_SIZE:-4096}"
LLAMA_THREADS="${LLAMA_THREADS:-$(nproc)}"
FIRECRAWL_PORT="${FIRECRAWL_PORT:-3002}"
HERMES_DIR="${HERMES_DIR:-./hermes-agent}"
HERMES_PORT="${HERMES_PORT:-8000}"
ok "Loaded .env (model: $MODEL_FILE, llama port: $LLAMA_PORT, firecrawl port: $FIRECRAWL_PORT)"

# ---------------------------------------------------------------------------
# 2. Preflight
# ---------------------------------------------------------------------------
step "Preflight checks"

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
docker info >/dev/null 2>&1 || die "docker daemon not reachable (is it running? are you in the docker group?)"
ok "docker daemon reachable"

docker compose version >/dev/null 2>&1 || die "docker compose (v2 plugin) not found"
ok "docker compose available"

command -v curl >/dev/null 2>&1 || die "curl not found (needed for health checks)"
command -v git  >/dev/null 2>&1 || die "git not found (needed to vendor firecrawl)"

mem_avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if (( mem_avail_mb < 3000 )); then
  warn "Only ${mem_avail_mb}MB RAM available. llama-server + Firecrawl's stack is tight on 8GB Pis."
  warn "Consider closing other services, or using firecrawl-simple instead of full firecrawl."
else
  ok "Memory check ok (${mem_avail_mb}MB available)"
fi

mkdir -p "$MODELS_DIR" "$VENDOR_DIR"

# ---------------------------------------------------------------------------
# 3. hf CLI (idempotent install/upgrade)
# ---------------------------------------------------------------------------
step "Hugging Face CLI"
if command -v hf >/dev/null 2>&1; then
  skip "hf CLI installed ($(hf version 2>/dev/null | head -1))"
else
  command -v pip3 >/dev/null 2>&1 || die "pip3 not found, cannot install hf CLI"
  run_quiet "installing huggingface_hub[cli]" pip3 install --user -U "huggingface_hub[cli]"
  export PATH="$HOME/.local/bin:$PATH"
  command -v hf >/dev/null 2>&1 || die "hf CLI still not on PATH after install (check ~/.local/bin is in PATH)"
  ok "hf CLI installed"
fi

# ---------------------------------------------------------------------------
# 4. Model download (idempotent - skips if file already present & non-trivial size)
# ---------------------------------------------------------------------------
step "Model: $MODEL_REPO"
MODEL_PATH="$MODELS_DIR/$MODEL_FILE"
if [[ "$FORCE_DOWNLOAD" == "0" && -f "$MODEL_PATH" && $(stat -c%s "$MODEL_PATH" 2>/dev/null || echo 0) -gt 1000000 ]]; then
  skip "$MODEL_FILE ($(du -h "$MODEL_PATH" | cut -f1))"
else
  echo "  downloading (this can take a while on Pi's network)..."
  if [[ "$VERBOSE" == "1" ]]; then
    hf download "$MODEL_REPO" --include "$MODEL_FILE" --local-dir "$MODELS_DIR"
  else
    hf download "$MODEL_REPO" --include "$MODEL_FILE" --local-dir "$MODELS_DIR" \
      | grep -i 'error\|fail' || true
  fi
  [[ -f "$MODEL_PATH" ]] || die "download finished but $MODEL_FILE not found in $MODELS_DIR"
  ok "downloaded $MODEL_FILE ($(du -h "$MODEL_PATH" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# 5. Shared docker network
# ---------------------------------------------------------------------------
step "Network"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  skip "docker network '$NETWORK'"
else
  docker network create "$NETWORK" >/dev/null
  ok "created docker network '$NETWORK'"
fi

# ---------------------------------------------------------------------------
# 6. Firecrawl (vendored, official compose file, pre-built GHCR images)
# ---------------------------------------------------------------------------
step "Firecrawl"
if [[ -d "$FIRECRAWL_DIR/.git" ]]; then
  skip "firecrawl source present ($FIRECRAWL_DIR)"
else
  run_quiet "cloning firecrawl" git clone --depth 1 "$FIRECRAWL_REPO_URL" "$FIRECRAWL_DIR"
  ok "cloned firecrawl into vendor/firecrawl"
fi

if [[ ! -f "$FIRECRAWL_DIR/.env" ]]; then
  cp "$FIRECRAWL_DIR/apps/api/.env.example" "$FIRECRAWL_DIR/.env" 2>/dev/null || touch "$FIRECRAWL_DIR/.env"
  auth_key="${FIRECRAWL_BULL_AUTH_KEY:-$(openssl rand -hex 16 2>/dev/null || date +%s%N)}"
  {
    echo "PORT=3002"
    echo "HOST=0.0.0.0"
    echo "USE_DB_AUTHENTICATION=false"
    echo "BULL_AUTH_KEY=$auth_key"
  } >> "$FIRECRAWL_DIR/.env"
  ok "generated vendor/firecrawl/.env (auth key persisted, won't regenerate)"
else
  skip "vendor/firecrawl/.env"
fi

run_quiet "starting firecrawl" docker compose -f "$FIRECRAWL_DIR/docker-compose.yml" \
  --env-file "$FIRECRAWL_DIR/.env" up -d
ok "firecrawl stack up (port ${FIRECRAWL_PORT})"

# connect firecrawl's api container to hermes-net too, if not already
docker network connect "$NETWORK" firecrawl-api >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. llama-server (+ hermes-agent if its Dockerfile exists)
# ---------------------------------------------------------------------------
step "llama.cpp server + Hermes agent"
PROFILE_ARGS=()
if [[ -f "$HERMES_DIR/Dockerfile" ]]; then
  PROFILE_ARGS=(--profile hermes)
  ok "found $HERMES_DIR/Dockerfile - will build/start hermes-agent"
else
  warn "no Dockerfile at $HERMES_DIR - starting llama-server only, skipping hermes-agent"
fi

run_quiet "starting llama-server stack" docker compose -f "$ROOT_DIR/docker-compose.yml" \
  "${PROFILE_ARGS[@]}" up -d --build

ok "llama-server up (port ${LLAMA_PORT})"

# ---------------------------------------------------------------------------
# 8. Health checks
# ---------------------------------------------------------------------------
step "Waiting for services to be healthy"
wait_for() {
  local name="$1" url="$2" tries=30
  for ((i=1; i<=tries; i++)); do
    if curl -fs "$url" >/dev/null 2>&1; then
      ok "$name is up"
      return 0
    fi
    sleep 2
  done
  warn "$name did not become healthy in time (check: docker logs <container>)"
  return 1
}
wait_for "llama-server"  "http://localhost:${LLAMA_PORT}/health"
wait_for "firecrawl-api" "http://localhost:${FIRECRAWL_PORT}/v0/health/liveness" || true

# ---------------------------------------------------------------------------
# 9. Summary + foreground monitor
# ---------------------------------------------------------------------------
step "Stack running"
printf "  llama.cpp (OpenAI-compatible): %shttp://localhost:%s/v1%s\n" "$C_BOLD" "$LLAMA_PORT" "$C_RESET"
printf "  firecrawl:                     %shttp://localhost:%s%s\n" "$C_BOLD" "$FIRECRAWL_PORT" "$C_RESET"
[[ -n "${PROFILE_ARGS[*]:-}" ]] && printf "  hermes-agent:                   %shttp://localhost:%s%s\n" "$C_BOLD" "$HERMES_PORT" "$C_RESET"
printf "\n  %sCtrl-C to stop and clean up.%s\n\n" "$C_DIM" "$C_RESET"

while true; do
  sleep 30
  if ! curl -fs "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1; then
    warn "llama-server health check failed - see: docker logs hermes-llama-server"
  fi
done