"""
CHAT LLM (role 3) - DEMO ONLY. NOT part of the TTS pipeline.

This module exists purely so there's a convenient way to hear the TTS engine
speak something without having to supply the text yourself: it asks a general-
purpose Ollama model (config.CHAT_MODEL, default llama3.2:3b) to *write* a
reply to your prompt, then hands that reply to the TTS engine.

Three things this is NOT:
  - It is not the TTS engine (that's engines.py - Kokoro / edge-tts).
  - It is not the normalization LLM (that's normalize.py - qwen2.5:1.5b /
    gemma3:1b, which reword text and never generate content).
  - It is not required. Set CHAT_ENABLED=0 and this router is not mounted;
    /tts, /v1/audio/speech, /voices and /normalize are entirely unaffected.

If you already have text to speak, use POST /tts and ignore this file.
"""

import base64
import io
import logging

import httpx
from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

import config
import engines
import normalize
import streaming

log = logging.getLogger("tts.chat")

router = APIRouter()


class ChatSpeakRequest(BaseModel):
    prompt: str
    model: str | None = None      # chat model override; defaults to config.CHAT_MODEL
    engine: str | None = None     # TTS engine: "kokoro" | "edge"
    voice: str | None = None
    system: str | None = None
    normalize: bool = True
    stream: bool | None = None    # stream LLM tokens -> sentence chunks -> streamed audio;
                                  # None -> server default (TTS_STREAM_DEFAULT)


async def _normalized_sentences(sentences_iter):
    async for s in sentences_iter:
        final, _flagged, _model = await normalize.normalize_text(s)
        if final.strip():
            yield final


@router.post("/chat/speak")
async def chat_speak(req: ChatSpeakRequest, json_out: bool = Query(False, alias="json")):
    """Demo endpoint: ask the chat LLM to write a reply, then speak it."""
    chat_model = req.model or config.CHAT_MODEL
    want_stream = config.STREAM_DEFAULT if req.stream is None else req.stream

    if want_stream:
        token_iter = streaming.stream_ollama_tokens(config.OLLAMA_URL, chat_model, req.prompt, req.system)
        sentence_iter = streaming.sentences_from_token_stream(token_iter)
        sentences = _normalized_sentences(sentence_iter) if req.normalize else sentence_iter
        gen, used = await engines.synthesize_stream(sentences, req.engine, req.voice)
        return StreamingResponse(gen, media_type="audio/mpeg", headers={
            "X-Chat-Model": chat_model, "X-TTS-Engine": used,
            "Content-Disposition": 'inline; filename="reply.mp3"',
        })

    payload = {
        "model": chat_model,
        "prompt": req.prompt,
        "stream": False,
        "keep_alive": config.CHAT_KEEP_ALIVE,
        "options": config.ollama_options(config.CHAT_NUM_CTX),  # num_gpu: 0 -> CPU only
    }
    if req.system:
        payload["system"] = req.system
    try:
        async with httpx.AsyncClient(timeout=300) as client:
            r = await client.post(f"{config.OLLAMA_URL}/api/generate", json=payload)
            r.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise HTTPException(status_code=502, detail=f"Ollama returned {e.response.status_code}: {e.response.text[:300]}")
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"Cannot reach Ollama at {config.OLLAMA_URL}: {e}")

    reply = r.json().get("response", "").strip()
    if not reply:
        raise HTTPException(status_code=502, detail="Ollama returned an empty response")

    audio, used, flagged, norm_model = await engines.synthesize(
        reply, req.engine, req.voice, do_normalize=req.normalize)
    if json_out:
        return JSONResponse({
            "reply": reply, "audio_b64": base64.b64encode(audio).decode(), "format": "mp3",
            "chat_model": chat_model, "engine": used,
            "text_normalized": flagged, "normalize_model": norm_model,
        })
    return StreamingResponse(io.BytesIO(audio), media_type="audio/mpeg", headers={
        "X-Chat-Model": chat_model, "X-TTS-Engine": used,
        "X-Text-Normalized": str(flagged).lower(), "X-Normalize-Model": norm_model or "",
        "Content-Disposition": 'inline; filename="reply.mp3"',
    })
