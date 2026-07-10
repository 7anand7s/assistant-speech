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


# --- ROLE 1: TTS engine (core; no LLM involved) ------------------------------

DEFAULT_ENGINE = os.getenv("TTS_ENGINE", "kokoro")   # "kokoro" or "edge"

KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_heart")
KOKORO_MODEL_PATH = os.getenv("KOKORO_MODEL_PATH", str(BASE_DIR / "models" / "kokoro-v1.0.onnx"))
KOKORO_VOICES_PATH = os.getenv("KOKORO_VOICES_PATH", str(BASE_DIR / "models" / "voices-v1.0.bin"))

EDGE_VOICE = os.getenv("TTS_VOICE", "en-US-AriaNeural")


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
