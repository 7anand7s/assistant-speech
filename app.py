"""
Neural TTS endpoint: Kokoro (local, offline, CPU-only) as the default engine,
with Microsoft Edge neural voices (same voices as Windows 11 "natural" voices)
as an automatic fallback if Kokoro is unavailable. Backed by Ollama for chat.

Text is run through a normalization pipeline before synthesis (see
normalize.py): a regex cleaner strips markdown/URLs/emoji, then a whitelist
check flags anything left over for a tiny local LLM (gemma3:1b, then
qwen2.5:1.5b) to rewrite - CPU-only, kept resident, only invoked on flagged
text, never on the normal hot path.

Engines:
  kokoro - local ONNX model (kokoro-onnx), runs on CPU only, no internet needed.
  edge   - Microsoft neural voices via edge-tts, needs internet, used as fallback.

Endpoints:
  GET  /health              - liveness check + which engines/models are up
  GET  /voices?engine=...   - list available voices for an engine (filter with &lang=en)
  POST /tts                 - {"text": "...", "engine": "kokoro"|"edge", "voice": "..."} -> mp3
  POST /v1/audio/speech     - OpenAI-compatible (works as TTS backend in Open WebUI etc.)
  POST /chat/speak          - {"prompt": "..."} -> ask Ollama, speak the reply -> mp3
  POST /chat/speak?json=1   - same, but returns {"reply": ..., "audio_b64": ..., "engine": ...}
  POST /normalize           - {"text": "..."} -> inspect the cleanup pipeline without doing TTS

Streaming: pass "stream": true to /tts or /chat/speak to get audio streamed
sentence-by-sentence as it's synthesized instead of waiting for the whole
thing. For /chat/speak, this also streams LLM tokens from Ollama rather
than waiting for the full reply - tokens are buffered into sentences, each
sentence is normalized + synthesized + streamed as soon as it's ready, so
audio for the first sentence can reach the client while the LLM is still
generating later ones. "stream": true ignores ?json=1 (streaming returns
raw audio only, no reply text alongside it) - see streaming.py.
"""

import asyncio
import base64
import io
import logging
import os
from pathlib import Path

import edge_tts
import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

import normalize
import streaming

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("tts")

BASE_DIR = Path(__file__).resolve().parent

DEFAULT_ENGINE = os.getenv("TTS_ENGINE", "kokoro")  # "kokoro" or "edge"

EDGE_VOICE = os.getenv("TTS_VOICE", "en-US-AriaNeural")
KOKORO_VOICE = os.getenv("KOKORO_VOICE", "af_heart")
KOKORO_MODEL_PATH = os.getenv("KOKORO_MODEL_PATH", str(BASE_DIR / "models" / "kokoro-v1.0.onnx"))
KOKORO_VOICES_PATH = os.getenv("KOKORO_VOICES_PATH", str(BASE_DIR / "models" / "voices-v1.0.bin"))

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.2")

# Map OpenAI voice names to a voice for each engine, so OpenAI-compatible
# clients (Open WebUI, etc.) work without knowing engine-specific voice names.
EDGE_OPENAI_MAP = {
    "alloy": "en-US-AriaNeural",
    "echo": "en-US-GuyNeural",
    "fable": "en-GB-SoniaNeural",
    "onyx": "en-US-ChristopherNeural",
    "nova": "en-US-JennyNeural",
    "shimmer": "en-US-MichelleNeural",
}
KOKORO_OPENAI_MAP = {
    "alloy": "af_alloy",
    "echo": "am_echo",
    "fable": "bm_fable",
    "onyx": "am_onyx",
    "nova": "af_nova",
    "shimmer": "af_sky",
}

# Kokoro voice codes are "<lang><gender>_<name>", e.g. af_heart = American Female.
KOKORO_LANG_NAMES = {
    "a": "English (US)", "b": "English (UK)", "j": "Japanese", "z": "Mandarin Chinese",
    "e": "Spanish", "f": "French", "h": "Hindi", "i": "Italian", "p": "Portuguese (Brazil)",
}
KOKORO_LANG_CODES = {
    "a": "en-us", "b": "en-gb", "j": "ja", "z": "cmn",
    "e": "es", "f": "fr-fr", "h": "hi", "i": "it", "p": "pt-br",
}

app = FastAPI(title="Neural TTS (Kokoro + Windows voices) + Ollama", version="2.0.0")

# --- Kokoro (local, CPU-only) -----------------------------------------------

_kokoro_instance = None
_kokoro_init_error: Exception | None = None
_kokoro_lock = asyncio.Lock()


def _load_kokoro_sync():
    # onnxruntime's CPU-only wheel has no CUDA provider, so this can never touch the GPU.
    import onnxruntime as ort
    log.info("onnxruntime providers available: %s", ort.get_available_providers())

    import espeakng_loader
    from phonemizer.backend.espeak.wrapper import EspeakWrapper
    EspeakWrapper.set_library(espeakng_loader.get_library_path())
    EspeakWrapper.set_data_path(espeakng_loader.get_data_path())

    from kokoro_onnx import Kokoro
    return Kokoro(KOKORO_MODEL_PATH, KOKORO_VOICES_PATH)


async def get_kokoro():
    global _kokoro_instance, _kokoro_init_error
    if _kokoro_instance is not None:
        return _kokoro_instance
    if _kokoro_init_error is not None:
        raise _kokoro_init_error
    async with _kokoro_lock:
        if _kokoro_instance is not None:
            return _kokoro_instance
        if _kokoro_init_error is not None:
            raise _kokoro_init_error
        try:
            _kokoro_instance = await asyncio.to_thread(_load_kokoro_sync)
            log.info("Kokoro loaded from %s", KOKORO_MODEL_PATH)
        except Exception as e:
            _kokoro_init_error = e
            log.warning("Kokoro failed to load, will fall back to edge-tts: %s", e)
            raise
    return _kokoro_instance


async def wav_to_mp3(wav_bytes: bytes) -> bytes:
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0", "-f", "mp3", "-codec:a", "libmp3lame", "-qscale:a", "2", "pipe:1",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate(wav_bytes)
    if proc.returncode != 0:
        raise HTTPException(status_code=500, detail=f"ffmpeg mp3 encode failed: {err.decode()[:300]}")
    return out


async def synth_kokoro(text: str, voice: str, speed: float = 1.0) -> bytes:
    import soundfile as sf

    kokoro = await get_kokoro()
    lang = KOKORO_LANG_CODES.get(voice[:1], "en-us")
    samples, sr = await asyncio.to_thread(kokoro.create, text, voice=voice, speed=speed, lang=lang)
    wav_buf = io.BytesIO()
    sf.write(wav_buf, samples, sr, format="WAV")
    return await wav_to_mp3(wav_buf.getvalue())


# --- Edge (Microsoft neural / Windows voices) -------------------------------

async def synth_edge(text: str, voice: str, rate: str = "+0%", pitch: str = "+0Hz") -> bytes:
    communicate = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
    buf = io.BytesIO()
    try:
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                buf.write(chunk["data"])
    except edge_tts.exceptions.NoAudioReceived:
        raise HTTPException(status_code=400, detail=f"No audio received - is '{voice}' a valid voice? Try GET /voices?engine=edge")
    return buf.getvalue()


# --- Streaming synthesis: sentence-by-sentence, audio flows as it's ready ---

async def synth_kokoro_sentences_stream(sentences_iter, voice: str, speed: float = 1.0):
    """One continuous MP3 stream built from per-sentence Kokoro synthesis."""
    kokoro = await get_kokoro()
    lang = KOKORO_LANG_CODES.get(voice[:1], "en-us")
    async with streaming.StreamingMp3Encoder(sample_rate=24000) as enc:
        async def feed():
            async for sentence in sentences_iter:
                try:
                    samples, sr = await asyncio.to_thread(kokoro.create, sentence, voice=voice, speed=speed, lang=lang)
                except Exception as e:
                    log.warning("kokoro streaming synth failed for a sentence, skipping it: %s", e)
                    continue
                await enc.write(samples)
            await enc.finish_writing()

        feed_task = asyncio.create_task(feed())
        while True:
            chunk = await enc.read_chunk()
            if chunk is None:
                break
            yield chunk
        await feed_task


async def synth_edge_sentences_stream(sentences_iter, voice: str, rate: str = "+0%", pitch: str = "+0Hz"):
    """edge-tts already produces streamable MP3 chunks from Microsoft's own
    encoder - just forward them sentence by sentence, no re-encoding needed."""
    async for sentence in sentences_iter:
        try:
            communicate = edge_tts.Communicate(sentence, voice, rate=rate, pitch=pitch)
            async for chunk in communicate.stream():
                if chunk["type"] == "audio":
                    yield chunk["data"]
        except Exception as e:
            log.warning("edge streaming synth failed for a sentence, skipping it: %s", e)
            continue


async def resolve_streaming_engine(engine: str | None) -> str:
    """Decide the engine once, upfront, since a streaming MP3 response can't
    switch encoders mid-flight the way the non-streaming path's per-request
    fallback can."""
    engine = engine or DEFAULT_ENGINE
    if engine == "kokoro":
        try:
            await get_kokoro()
            return "kokoro"
        except Exception:
            return "edge-fallback"
    return "edge"


async def normalized_sentence_stream(sentences_iter):
    async for s in sentences_iter:
        final, _flagged, _model = await normalize.normalize_text(s)
        if final.strip():
            yield final


# --- Unified dispatch with kokoro -> edge fallback --------------------------

def resolve_voice(engine: str, voice: str | None) -> str:
    if voice:
        return {"kokoro": KOKORO_OPENAI_MAP, "edge": EDGE_OPENAI_MAP}[engine].get(voice.lower(), voice)
    return KOKORO_VOICE if engine == "kokoro" else EDGE_VOICE


async def synthesize(
    text: str,
    engine: str | None = None,
    voice: str | None = None,
    speed: float = 1.0,
    rate: str = "+0%",
    pitch: str = "+0Hz",
    do_normalize: bool = True,
) -> tuple[bytes, str, bool, str | None]:
    """Returns (mp3_bytes, engine_actually_used, was_flagged, normalize_model_used)."""
    if not text.strip():
        raise HTTPException(status_code=400, detail="text is empty")
    engine = engine or DEFAULT_ENGINE

    was_flagged = False
    norm_model = None
    if do_normalize:
        text, was_flagged, norm_model = await normalize.normalize_text(text)
        if not text.strip():
            raise HTTPException(status_code=400, detail="text was empty after normalization")

    if engine == "kokoro":
        try:
            audio = await synth_kokoro(text, resolve_voice("kokoro", voice), speed)
            return audio, "kokoro", was_flagged, norm_model
        except HTTPException:
            raise
        except Exception as e:
            log.warning("Kokoro synthesis failed, falling back to edge-tts (Windows voice): %s", e)
            audio = await synth_edge(text, resolve_voice("edge", voice if voice not in (None,) else None), rate, pitch)
            return audio, "edge-fallback", was_flagged, norm_model

    audio = await synth_edge(text, resolve_voice("edge", voice), rate, pitch)
    return audio, "edge", was_flagged, norm_model


@app.get("/health")
async def health():
    kokoro_ok = True
    if _kokoro_instance is None and _kokoro_init_error is None:
        try:
            await get_kokoro()
        except Exception:
            kokoro_ok = False
    elif _kokoro_init_error is not None:
        kokoro_ok = False
    return {
        "status": "ok",
        "default_engine": DEFAULT_ENGINE,
        "kokoro_available": kokoro_ok,
        "kokoro_error": str(_kokoro_init_error) if _kokoro_init_error else None,
        "default_kokoro_voice": KOKORO_VOICE,
        "default_edge_voice": EDGE_VOICE,
        "normalize_enabled": normalize.NORM_ENABLED,
        "normalize_fallback_models": normalize.FALLBACK_MODELS,
        "normalize_keep_alive": normalize.FALLBACK_KEEP_ALIVE,
        "ollama_url": OLLAMA_URL,
        "ollama_model": OLLAMA_MODEL,
    }


@app.get("/voices")
async def voices(
    engine: str = Query(DEFAULT_ENGINE, description="'kokoro' or 'edge'"),
    lang: str | None = Query(None, description="filter by language prefix, e.g. 'en' or 'en-US'"),
):
    if engine == "kokoro":
        kokoro = await get_kokoro()
        out = []
        for code in sorted(kokoro.get_voices()):
            prefix = code[:1]
            locale = KOKORO_LANG_CODES.get(prefix, "?")
            if lang and not locale.lower().startswith(lang.lower()):
                continue
            out.append({
                "name": code,
                "gender": "Female" if code[1:2] == "f" else "Male",
                "locale": locale,
                "language": KOKORO_LANG_NAMES.get(prefix, "Unknown"),
            })
        return {"engine": "kokoro", "count": len(out), "voices": out}

    all_voices = await edge_tts.list_voices()
    out = [
        {"name": v["ShortName"], "gender": v["Gender"], "locale": v["Locale"]}
        for v in all_voices
        if not lang or v["Locale"].lower().startswith(lang.lower())
    ]
    return {"engine": "edge", "count": len(out), "voices": out}


class TTSRequest(BaseModel):
    text: str
    engine: str | None = None   # "kokoro" (default) or "edge"
    voice: str | None = None
    speed: float = 1.0          # used by kokoro
    rate: str = "+0%"           # used by edge, e.g. "-10%", "+25%"
    pitch: str = "+0Hz"         # used by edge, e.g. "-5Hz", "+10Hz"
    normalize: bool = True      # run text-cleanup pipeline (regex + LLM fallback) first
    stream: bool = False        # stream audio sentence-by-sentence instead of waiting for it all


@app.post("/tts")
async def tts(req: TTSRequest):
    if req.stream:
        used = await resolve_streaming_engine(req.engine)
        sentences = normalized_sentence_stream(_iter(streaming.split_all_sentences(req.text))) \
            if req.normalize else _iter(streaming.split_all_sentences(req.text))
        if used == "kokoro":
            gen = synth_kokoro_sentences_stream(sentences, resolve_voice("kokoro", req.voice), req.speed)
        else:
            gen = synth_edge_sentences_stream(sentences, resolve_voice("edge", req.voice), req.rate, req.pitch)
        return StreamingResponse(gen, media_type="audio/mpeg", headers={
            "Content-Disposition": 'inline; filename="speech.mp3"', "X-TTS-Engine": used,
        })

    audio, used, flagged, norm_model = await synthesize(
        req.text, req.engine, req.voice, req.speed, req.rate, req.pitch, req.normalize)
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "Content-Disposition": 'inline; filename="speech.mp3"',
        "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(),
        "X-Normalize-Model": norm_model or "",
    })


async def _iter(items: list):
    for item in items:
        yield item


class OpenAISpeechRequest(BaseModel):
    model: str = "tts-1"          # accepted and ignored
    input: str
    voice: str | None = None
    response_format: str = "mp3"  # only mp3 is produced
    speed: float = 1.0


@app.post("/v1/audio/speech")
async def openai_speech(req: OpenAISpeechRequest):
    pct = int((max(0.25, min(req.speed, 4.0)) - 1.0) * 100)
    rate = f"{'+' if pct >= 0 else ''}{pct}%"
    audio, used, flagged, norm_model = await synthesize(req.input, None, req.voice, req.speed, rate)
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(),
        "X-Normalize-Model": norm_model or "",
    })


class ChatSpeakRequest(BaseModel):
    prompt: str
    model: str | None = None
    engine: str | None = None
    voice: str | None = None
    system: str | None = None
    normalize: bool = True
    stream: bool = False   # pipeline: stream LLM tokens -> sentence chunks -> streamed audio


@app.post("/chat/speak")
async def chat_speak(req: ChatSpeakRequest, json_out: bool = Query(False, alias="json")):
    if req.stream:
        model = req.model or OLLAMA_MODEL
        used = await resolve_streaming_engine(req.engine)
        token_iter = streaming.stream_ollama_tokens(OLLAMA_URL, model, req.prompt, req.system)
        sentence_iter = streaming.sentences_from_token_stream(token_iter)
        sentences = normalized_sentence_stream(sentence_iter) if req.normalize else sentence_iter
        if used == "kokoro":
            gen = synth_kokoro_sentences_stream(sentences, resolve_voice("kokoro", req.voice))
        else:
            gen = synth_edge_sentences_stream(sentences, resolve_voice("edge", req.voice))
        return StreamingResponse(gen, media_type="audio/mpeg", headers={
            "X-Ollama-Model": model, "X-TTS-Engine": used,
            "Content-Disposition": 'inline; filename="reply.mp3"',
        })

    payload = {
        "model": req.model or OLLAMA_MODEL,
        "prompt": req.prompt,
        "stream": False,
    }
    if req.system:
        payload["system"] = req.system
    try:
        async with httpx.AsyncClient(timeout=300) as client:
            r = await client.post(f"{OLLAMA_URL}/api/generate", json=payload)
            r.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=502, detail=f"Ollama returned {e.response.status_code}: {e.response.text[:300]}")
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach Ollama at {OLLAMA_URL}: {e}")

    reply = r.json().get("response", "").strip()
    if not reply:
        raise HTTPException(status_code=502, detail="Ollama returned an empty response")

    audio, used, flagged, norm_model = await synthesize(reply, req.engine, req.voice, do_normalize=req.normalize)
    if json_out:
        return JSONResponse({
            "reply": reply, "audio_b64": base64.b64encode(audio).decode(), "format": "mp3",
            "engine": used, "text_normalized": flagged, "normalize_model": norm_model,
        })
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "X-Ollama-Model": payload["model"], "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(), "X-Normalize-Model": norm_model or "",
        "Content-Disposition": 'inline; filename="reply.mp3"',
    })


class NormalizeRequest(BaseModel):
    text: str


@app.post("/normalize")
async def normalize_only(req: NormalizeRequest):
    """Debug/inspection endpoint: run the text-cleanup pipeline without doing TTS."""
    cleaned_with_placeholders, placeholders = normalize.clean_stage1(req.text)
    stage1_cleaned = normalize.restore_placeholders(cleaned_with_placeholders, placeholders)
    final, flagged, model_used = await normalize.normalize_text(req.text)
    return {
        "raw": req.text, "stage1_cleaned": stage1_cleaned, "flagged": flagged,
        "final": final, "model_used": model_used,
    }


@app.on_event("startup")
async def warm_up():
    try:
        await get_kokoro()
    except Exception:
        pass  # already logged in get_kokoro(); requests will fall back to edge
    if normalize.NORM_ENABLED:
        await normalize.warm_up_fallback_models()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("TTS_PORT", "8880")))
