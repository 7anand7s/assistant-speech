"""
Central config, organised by the THREE INDEPENDENT MODEL ROLES in this service.
They are unrelated to each other - changing one does not affect the others.

  1. TTS ENGINE (core)        - turns text into audio. Kokoro (local ONNX, CPU)
                                or edge-tts (Microsoft neural voices). This is
                                the actual product. It uses NO language model.

  2. NORMALIZATION LLM        - never generates content. Only rewords already-
     (support, optional)        written text so it reads cleanly aloud, and only
                                for the small fraction of text the regex stage
                                flags. Tiny models, CPU-only, kept resident.

  3. CHAT LLM (demo, optional)- writes NEW text from a prompt, purely so the
                                /chat/speak demo endpoint has something to
                                speak. NOT part of the TTS pipeline. Disable it
                                (CHAT_ENABLED=0) and /tts, /v1/audio/speech and
                                /normalize all still work exactly the same.
"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent

TTS_PORT = int(os.getenv("TTS_PORT", "8880"))

# Ollama host. Shared transport for roles 2 and 3 below, but they are otherwise
# completely separate - same server, different models, different purposes.
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")

# CPU-only enforcement. This whole service is meant to stay off the GPU.
#
# Role 1 (Kokoro) can't reach the GPU at all: ONNX_PROVIDER pins it to
# CPUExecutionProvider, and the installed onnxruntime build ships no CUDA
# provider. Roles 2 and 3 run inside Ollama, which WILL happily put a model on
# the GPU unless told otherwise - so every Ollama call must pass num_gpu: 0.
# Call ollama_options() rather than writing the dict inline, so a new call site
# can't silently forget it and leak onto the GPU.
#
# Caveat: num_gpu is a LOAD-TIME parameter and Ollama keeps one instance per
# model. Sending num_gpu:0 for a model another app is running on the GPU evicts
# that instance and reloads it on CPU - and a later normal call won't move it
# back until the CPU instance unloads. Different models are unaffected. This is
# why CHAT_KEEP_ALIVE is 5m rather than -1: the demo model shouldn't squat on a
# possibly-shared model in CPU mode indefinitely.
OLLAMA_FORCE_CPU = os.getenv("OLLAMA_FORCE_CPU", "1") != "0"
OLLAMA_NUM_CTX = int(os.getenv("OLLAMA_NUM_CTX", "1024"))


def ollama_options(num_ctx: int | None = None) -> dict:
    """Options block for any Ollama call. num_gpu: 0 keeps the model on CPU."""
    opts: dict = {"num_ctx": num_ctx or OLLAMA_NUM_CTX}
    if OLLAMA_FORCE_CPU:
        opts["num_gpu"] = 0
    return opts


# --- ROLE 1: TTS engine (core; no LLM involved) ------------------------------

DEFAULT_ENGINE = os.getenv("TTS_ENGINE", "kokoro")   # "kokoro" or "edge"

KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_heart")
KOKORO_MODEL_PATH = os.getenv("KOKORO_MODEL_PATH", str(BASE_DIR / "models" / "kokoro-v1.0.onnx"))
KOKORO_VOICES_PATH = os.getenv("KOKORO_VOICES_PATH", str(BASE_DIR / "models" / "voices-v1.0.bin"))

EDGE_VOICE = os.getenv("TTS_VOICE", "en-US-AriaNeural")

# Server-wide default for streaming audio. A request's own "stream" field always
# wins; this only decides what happens when the request doesn't say either way.
# /v1/audio/speech ignores this - it stays strictly OpenAI-shaped (never streams).
STREAM_DEFAULT = os.getenv("TTS_STREAM_DEFAULT", "0") != "0"


# --- ROLE 2: normalization LLM (support; rewords, never generates) -----------

NORM_ENABLED = os.getenv("NORM_ENABLED", "1") != "0"

# Tried in order. Forced CPU-only (num_gpu: 0) and kept resident (keep_alive).
NORM_MODELS = [m for m in [
    os.getenv("NORM_LLM_PRIMARY", "qwen2.5:1.5b"),
    os.getenv("NORM_LLM_SECONDARY", "gemma3:1b"),
] if m]
NORM_KEEP_ALIVE = int(os.getenv("NORM_LLM_KEEP_ALIVE", "-1"))  # -1 = never unload
NORM_TIMEOUT = float(os.getenv("NORM_LLM_TIMEOUT", "10"))
NORM_LOG_PATH = Path(os.getenv("NORM_LOG_PATH", str(BASE_DIR / "flagged_log.jsonl")))


# --- ROLE 3: chat LLM (demo only; generates the text to be spoken) -----------

CHAT_ENABLED = os.getenv("CHAT_ENABLED", "1") != "0"

# CHAT_MODEL is the intended name. OLLAMA_MODEL is accepted as a legacy alias
# because it shipped in the first release, but it is *only* the chat model -
# it has never had anything to do with TTS or with normalization.
CHAT_MODEL = os.getenv("CHAT_MODEL") or os.getenv("OLLAMA_MODEL") or "llama3.2:3b"

# The chat model writes prose, so it needs more context than the normalizer's
# short single-sentence rewrites. Still CPU-only (see OLLAMA_FORCE_CPU above).
CHAT_NUM_CTX = int(os.getenv("CHAT_NUM_CTX", "4096"))
CHAT_KEEP_ALIVE = os.getenv("CHAT_KEEP_ALIVE", "5m")
