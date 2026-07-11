"""
Self-hosted neural speech service (TTS + STT).

The service is built around FOUR INDEPENDENT ROLES - see config.py for the
full explanation. In short:

  1. TTS engine (core, no LLM)  -> engines.py   Kokoro (local, CPU) / edge-tts
  2. Normalization LLM (support) -> normalize.py  rewords text, never generates
  3. Chat LLM (demo, optional)   -> chat.py       generates text to demo the TTS
  4. STT engine (core, no LLM)  -> stt.py        Parakeet (local, CPU) audio->text

Roles 2 and 3 both happen to talk to Ollama, but they are unrelated: different
models, different jobs. Roles 1 and 4 are the core product (text<->audio) and
need neither of them.

Endpoints:
  GET  /health                  - liveness + status of each role, reported separately
  GET  /voices?engine=...       - list voices for an engine (filter with &lang=en)
  POST /tts                     - {"text": "..."} -> mp3          [role 1]
  POST /v1/audio/speech         - OpenAI-compatible TTS           [role 1]
  POST /normalize               - inspect the cleanup pipeline    [role 2, debug]
  POST /chat/speak              - prompt -> LLM writes -> speak   [role 3, demo;
                                  only mounted when CHAT_ENABLED=1]
  POST /stt                     - upload audio -> text            [role 4;
  POST /v1/audio/transcriptions - OpenAI-compatible STT             only mounted
                                                                    when STT_ENABLED=1]

Streaming: pass "stream": true to /tts or /chat/speak to get audio streamed
sentence-by-sentence as it's synthesized instead of waiting for the whole
thing. For /chat/speak, this also streams LLM tokens from Ollama rather than
waiting for the full reply. "stream": true ignores ?json=1 (streaming returns
raw audio only) - see streaming.py.
"""

import io
import logging

import edge_tts
from fastapi import FastAPI, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import config
import engines
import normalize
import streaming

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("tts")

app = FastAPI(title="Self-hosted neural speech (TTS + STT)", version="4.0.0")

if config.CHAT_ENABLED:
    import chat
    app.include_router(chat.router)

if config.STT_ENABLED:
    import stt
    app.include_router(stt.router)


async def _iter(items: list):
    for item in items:
        yield item


async def _normalized_sentences(sentences_iter):
    async for s in sentences_iter:
        final, _flagged, _model = await normalize.normalize_text(s)
        if final.strip():
            yield final


@app.get("/health")
async def health():
    """Status of each of the four roles, reported separately so it's obvious
    which model does what."""
    if not engines._kokoro_instance and not engines._kokoro_init_error:
        try:
            await engines.get_kokoro()
        except Exception:
            pass
    kokoro_ok, kokoro_err = engines.kokoro_status()

    stt_block = {
        "role": "turns audio into text (no LLM involved)",
        "enabled": config.STT_ENABLED,
    }
    if config.STT_ENABLED:
        import stt
        if not stt._recognizer and not stt._init_error:
            try:
                await stt.get_recognizer()
            except Exception:
                pass
        stt_ok, stt_err = stt.stt_status()
        import os
        stt_block.update({
            "model": "parakeet-tdt-0.6b-v2",
            "available": stt_ok,
            "error": stt_err if not stt_ok else None,
            "streaming": {                       # WebSocket /stt/stream, VAD-segmented
                "endpoint": "/stt/stream",
                "vad_model_present": os.path.exists(config.STT_VAD_MODEL_PATH),
            },
        })

    return {
        "status": "ok",
        "tts_engine": {                       # role 1: the actual product
            "role": "turns text into audio (no LLM involved)",
            "default_engine": config.DEFAULT_ENGINE,
            "kokoro_available": kokoro_ok,
            "kokoro_error": kokoro_err if not kokoro_ok else None,
            "default_kokoro_voice": config.KOKORO_VOICE,
            "default_edge_voice": config.EDGE_VOICE,
        },
        "normalization_llm": {                # role 2: rewords, never generates
            "role": "rewords flagged text so it reads cleanly aloud",
            "enabled": config.NORM_ENABLED,
            "models": config.NORM_MODELS,
            "keep_alive": config.NORM_KEEP_ALIVE,
        },
        "chat_llm": {                         # role 3: demo only
            "role": "DEMO ONLY - writes text for /chat/speak to speak; not part of TTS",
            "enabled": config.CHAT_ENABLED,
            "model": config.CHAT_MODEL if config.CHAT_ENABLED else None,
        },
        "stt_engine": stt_block,              # role 4: audio -> text
        "ollama_url": config.OLLAMA_URL,
    }


@app.get("/voices")
async def voices(
    engine: str = Query(config.DEFAULT_ENGINE, description="'kokoro' or 'edge'"),
    lang: str | None = Query(None, description="filter by language prefix, e.g. 'en' or 'en-US'"),
):
    if engine == "kokoro":
        kokoro = await engines.get_kokoro()
        out = []
        for code in sorted(kokoro.get_voices()):
            prefix = code[:1]
            locale = engines.KOKORO_LANG_CODES.get(prefix, "?")
            if lang and not locale.lower().startswith(lang.lower()):
                continue
            out.append({
                "name": code,
                "gender": "Female" if code[1:2] == "f" else "Male",
                "locale": locale,
                "language": engines.KOKORO_LANG_NAMES.get(prefix, "Unknown"),
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
    stream: bool | None = None  # stream audio sentence-by-sentence; None -> TTS_STREAM_DEFAULT


@app.post("/tts")
async def tts(req: TTSRequest):
    if config.STREAM_DEFAULT if req.stream is None else req.stream:
        sentence_iter = _iter(streaming.split_all_sentences(req.text))
        sentences = _normalized_sentences(sentence_iter) if req.normalize else sentence_iter
        gen, used = await engines.synthesize_stream(
            sentences, req.engine, req.voice, req.speed, req.rate, req.pitch)
        return StreamingResponse(gen, media_type="audio/mpeg", headers={
            "Content-Disposition": 'inline; filename="speech.mp3"', "X-TTS-Engine": used,
        })

    audio, used, flagged, norm_model = await engines.synthesize(
        req.text, req.engine, req.voice, req.speed, req.rate, req.pitch, req.normalize)
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "Content-Disposition": 'inline; filename="speech.mp3"',
        "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(),
        "X-Normalize-Model": norm_model or "",
    })


class OpenAISpeechRequest(BaseModel):
    # Strict OpenAI schema - no "normalize"/"stream" extensions, so clients that
    # validate against the spec keep working. Use /tts for per-request control.
    model: str = "tts-1"          # accepted and ignored
    input: str
    voice: str | None = None
    response_format: str = "mp3"  # only mp3 is produced
    speed: float = 1.0


@app.post("/v1/audio/speech")
async def openai_speech(req: OpenAISpeechRequest):
    pct = int((max(0.25, min(req.speed, 4.0)) - 1.0) * 100)
    rate = f"{'+' if pct >= 0 else ''}{pct}%"
    # Normalization always on here; only NORM_ENABLED=0 disables it.
    audio, used, flagged, norm_model = await engines.synthesize(req.input, None, req.voice, req.speed, rate)
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(),
        "X-Normalize-Model": norm_model or "",
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
        await engines.get_kokoro()
    except Exception:
        pass  # already logged; requests will fall back to edge
    if config.NORM_ENABLED:
        await normalize.warm_up_models()
    if config.STT_ENABLED:
        import stt
        try:
            await stt.get_recognizer()  # load Parakeet at boot, not on first request
        except Exception:
            pass  # already logged; /stt will surface the error


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=config.TTS_PORT)
