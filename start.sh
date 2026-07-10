#!/usr/bin/env bash
# Start the neural TTS + Ollama endpoint.
# Override any of these by exporting them before running, e.g.:
#   OLLAMA_MODEL="qwen3:8b" ./start.sh
cd "$(dirname "$0")"

export OLLAMA_URL="${OLLAMA_URL:-http://172.18.0.1:11434}"   # Ollama on the Unraid host (docker gateway)
export OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
export TTS_PORT="${TTS_PORT:-8880}"

export TTS_ENGINE="${TTS_ENGINE:-kokoro}"          # default engine: kokoro (local, offline). "edge" for Windows voices.
export KOKORO_VOICE="${KOKORO_VOICE:-af_heart}"    # default kokoro voice
export TTS_VOICE="${TTS_VOICE:-en-US-AriaNeural}"  # default Windows/edge voice, used as fallback if kokoro fails
export ONNX_PROVIDER="CPUExecutionProvider"         # force CPU-only, never touch the GPU

export NORM_ENABLED="${NORM_ENABLED:-1}"                      # text-cleanup pipeline on by default
export NORM_LLM_PRIMARY="${NORM_LLM_PRIMARY:-qwen2.5:1.5b}"   # tried first for flagged text
export NORM_LLM_SECONDARY="${NORM_LLM_SECONDARY:-gemma3:1b}"  # tried if primary fails/unreachable
export NORM_LLM_KEEP_ALIVE="${NORM_LLM_KEEP_ALIVE:--1}"       # -1 = keep both models resident forever (CPU, always on)

exec .venv/bin/python app.py
