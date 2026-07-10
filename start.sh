#!/usr/bin/env bash
# Start the self-hosted neural TTS service.
#
# Config is grouped by the THREE INDEPENDENT MODEL ROLES (see config.py).
# They are unrelated - changing one does not affect the others.
#
# Override any of these by exporting them before running, e.g.:
#   CHAT_MODEL="qwen3:8b" ./start.sh
#   CHAT_ENABLED=0 ./start.sh          # TTS only, no demo chat endpoint
cd "$(dirname "$0")"

export TTS_PORT="${TTS_PORT:-8880}"
export OLLAMA_URL="${OLLAMA_URL:-http://172.18.0.1:11434}"   # Ollama on the Unraid host (docker gateway)

# --- ROLE 1: TTS engine - the core product. No LLM involved. ---------------
export TTS_ENGINE="${TTS_ENGINE:-kokoro}"          # "kokoro" (local, offline) or "edge" (Windows voices)
export KOKORO_VOICE="${KOKORO_VOICE:-af_heart}"    # default kokoro voice
export TTS_VOICE="${TTS_VOICE:-en-US-AriaNeural}"  # default Windows/edge voice; also the fallback if kokoro fails
export ONNX_PROVIDER="CPUExecutionProvider"        # force CPU-only, never touch the GPU

# --- ROLE 2: normalization LLM - rewords text aloud-friendly. Never generates.
export NORM_ENABLED="${NORM_ENABLED:-1}"                        # text-cleanup pipeline on by default
export NORM_LLM_PRIMARY="${NORM_LLM_PRIMARY:-qwen2.5:1.5b}"     # tried first for flagged text
export NORM_LLM_SECONDARY="${NORM_LLM_SECONDARY:-gemma3:1b}"    # tried if primary fails/unreachable
export NORM_LLM_KEEP_ALIVE="${NORM_LLM_KEEP_ALIVE:--1}"         # -1 = keep both resident forever (CPU, always on)

# --- ROLE 3: chat LLM - DEMO ONLY. Writes text for /chat/speak to speak. ----
# Not part of the TTS pipeline. Set CHAT_ENABLED=0 and everything else still works.
export CHAT_ENABLED="${CHAT_ENABLED:-1}"
export CHAT_MODEL="${CHAT_MODEL:-llama3.2:3b}"

exec .venv/bin/python app.py
