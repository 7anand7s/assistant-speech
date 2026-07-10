"""
STT ENGINE (role 4) - audio in, text out. The reverse of engines.py, and just
as independent: no LLM anywhere in this file.

  Parakeet TDT 0.6B v2 - English, int8 ONNX, CPU-only, via sherpa-onnx.

sherpa-onnx runs on CPU by default and this build has no CUDA path, so - like
Kokoro - it physically cannot touch the GPU. Any input audio format/samplerate
is accepted: ffmpeg decodes it to the 16 kHz mono float32 the model expects.
"""

import asyncio
import logging

import numpy as np
from fastapi import APIRouter, File, Form, HTTPException, UploadFile

import config

log = logging.getLogger("tts.stt")

router = APIRouter()

TARGET_SR = 16000

_recognizer = None
_init_error: Exception | None = None
_lock = asyncio.Lock()


def _load_sync():
    import os

    import sherpa_onnx

    d = config.STT_MODEL_DIR
    encoder = os.path.join(d, "encoder.int8.onnx")
    decoder = os.path.join(d, "decoder.int8.onnx")
    joiner = os.path.join(d, "joiner.int8.onnx")
    tokens = os.path.join(d, "tokens.txt")
    for p in (encoder, decoder, joiner, tokens):
        if not os.path.exists(p):
            raise FileNotFoundError(f"STT model file missing: {p}")
    # CPU only - sherpa-onnx defaults to CPU and this wheel has no CUDA provider.
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=encoder,
        decoder=decoder,
        joiner=joiner,
        tokens=tokens,
        num_threads=config.STT_NUM_THREADS,
        model_type="nemo_transducer",
    )


async def get_recognizer():
    global _recognizer, _init_error
    if _recognizer is not None:
        return _recognizer
    if _init_error is not None:
        raise _init_error
    async with _lock:
        if _recognizer is not None:
            return _recognizer
        if _init_error is not None:
            raise _init_error
        try:
            _recognizer = await asyncio.to_thread(_load_sync)
            log.info("Parakeet STT loaded from %s", config.STT_MODEL_DIR)
        except Exception as e:
            _init_error = e
            log.warning("STT failed to load: %s", e)
            raise
    return _recognizer


def stt_status() -> tuple[bool, str | None]:
    if _recognizer is not None:
        return True, None
    if _init_error is not None:
        return False, str(_init_error)
    return False, "not loaded yet"


async def decode_to_pcm(raw_bytes: bytes) -> np.ndarray:
    """Decode any audio container/codec to 16 kHz mono float32 via ffmpeg.
    Reading from a pipe means we never touch the filesystem for uploads."""
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", "pipe:0", "-ar", str(TARGET_SR), "-ac", "1", "-f", "f32le", "pipe:1",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate(raw_bytes)
    if proc.returncode != 0:
        raise HTTPException(status_code=400, detail=f"could not decode audio: {err.decode()[:300]}")
    samples = np.frombuffer(out, dtype=np.float32)
    if samples.size == 0:
        raise HTTPException(status_code=400, detail="decoded audio was empty - is this a valid audio file?")
    return samples


async def transcribe(raw_bytes: bytes) -> dict:
    recognizer = await get_recognizer()
    samples = await decode_to_pcm(raw_bytes)
    duration = samples.size / TARGET_SR

    def _run():
        stream = recognizer.create_stream()
        stream.accept_waveform(TARGET_SR, samples)
        recognizer.decode_stream(stream)
        return stream.result.text

    text = await asyncio.to_thread(_run)
    return {"text": text.strip(), "duration_seconds": round(duration, 2)}


@router.post("/stt")
async def stt(file: UploadFile = File(...)):
    """Transcribe an uploaded audio file (any format) to English text."""
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="empty upload")
    result = await transcribe(raw)
    return {
        "text": result["text"],
        "duration_seconds": result["duration_seconds"],
        "language": "en",
        "model": "parakeet-tdt-0.6b-v2",
    }


class OpenAITranscriptionResponse(dict):
    pass


@router.post("/v1/audio/transcriptions")
async def openai_transcriptions(
    file: UploadFile = File(...),
    model: str = Form("whisper-1"),          # accepted and ignored
    response_format: str = Form("json"),     # "json" or "text"
    language: str = Form("en"),              # accepted; model is English-only
):
    """OpenAI-compatible transcription endpoint - drop-in for clients that
    already speak the OpenAI /v1/audio/transcriptions API."""
    raw = await file.read()
    if not raw:
        raise HTTPException(status_code=400, detail="empty upload")
    result = await transcribe(raw)
    if response_format == "text":
        from fastapi.responses import PlainTextResponse
        return PlainTextResponse(result["text"])
    return {"text": result["text"]}
