"""
STT ENGINE (role 4) - audio in, text out. The reverse of engines.py, and just
as independent: no LLM anywhere in this file.

  Parakeet TDT 0.6B v2 - English, int8 ONNX, CPU-only, via sherpa-onnx.

sherpa-onnx runs on CPU by default and this build has no CUDA path, so - like
Kokoro - it physically cannot touch the GPU. Any input audio format/samplerate
is accepted: ffmpeg decodes it to the 16 kHz mono float32 the model expects.

Two modes:
  - Batch (POST /stt, POST /v1/audio/transcriptions): upload a whole clip.
  - Streaming (WebSocket /stt/stream): send audio frames as you capture them,
    get transcript segments back as each phrase completes. Parakeet is an
    offline model, so streaming is VAD-segmented (see config.py) rather than
    token-by-token - same accurate model, transcripts emitted at speech pauses.
"""

import asyncio
import json
import logging

import numpy as np
from fastapi import APIRouter, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect

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


# --- Streaming: VAD-segmented transcription over a WebSocket ------------------
#
# Parakeet is offline (see module docstring), so we can't emit tokens mid-word.
# Instead a Silero VAD segments the incoming audio at natural pauses, and each
# completed speech segment is transcribed with the full accurate model and sent
# back immediately. From the client's side it's genuine streaming: talk, and
# transcript segments arrive as you pause.

def _make_vad():
    import sherpa_onnx

    cfg = sherpa_onnx.VadModelConfig()
    cfg.silero_vad.model = config.STT_VAD_MODEL_PATH
    cfg.silero_vad.threshold = config.STT_VAD_THRESHOLD
    cfg.silero_vad.min_silence_duration = config.STT_VAD_MIN_SILENCE
    cfg.silero_vad.min_speech_duration = config.STT_VAD_MIN_SPEECH
    cfg.sample_rate = TARGET_SR
    if not cfg.validate():
        raise RuntimeError(f"invalid VAD config - is {config.STT_VAD_MODEL_PATH} present?")
    return sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=30)


def _transcribe_samples(recognizer, samples: np.ndarray) -> str:
    stream = recognizer.create_stream()
    stream.accept_waveform(TARGET_SR, samples)
    recognizer.decode_stream(stream)
    return stream.result.text.strip()


@router.websocket("/stt/stream")
async def stt_stream(ws: WebSocket):
    """Streaming STT.

    Protocol (all audio is 16 kHz mono):
      client -> server  binary frames of raw PCM. int16 (default) or, if the
                        connection is opened with ?format=f32, float32.
      client -> server  text "done"  ->  flush any trailing audio and finish.
      server -> client  {"type":"segment","seq":N,"text":...,"start":s,"duration":s}
                        emitted as each speech segment completes.
      server -> client  {"type":"final","text": "<all segments joined>"} at the end.
      server -> client  {"type":"error","detail":...} on failure.
    """
    await ws.accept()
    fmt = ws.query_params.get("format", "int16")

    try:
        recognizer = await get_recognizer()
    except Exception as e:
        await ws.send_text(json.dumps({"type": "error", "detail": f"STT model unavailable: {e}"}))
        await ws.close()
        return

    try:
        vad = await asyncio.to_thread(_make_vad)
    except Exception as e:
        await ws.send_text(json.dumps({"type": "error", "detail": str(e)}))
        await ws.close()
        return

    seq = 0
    segments: list[str] = []

    async def drain_segments():
        nonlocal seq
        while not vad.empty():
            seg = vad.front
            # Copy every field we need BEFORE vad.pop(): pop() frees the
            # segment's underlying C++ buffer, and seg.samples is a view into
            # it - reading it after pop() is a use-after-free that yields
            # garbage samples (and <unk> transcripts). np.array(..., copy=True)
            # snapshots it into memory we own.
            samples = np.array(seg.samples, dtype=np.float32, copy=True)
            seg_start = seg.start
            seg_len = len(samples)
            vad.pop()
            text = await asyncio.to_thread(_transcribe_samples, recognizer, samples)
            seq += 1
            if text:
                segments.append(text)
            await ws.send_text(json.dumps({
                "type": "segment", "seq": seq, "text": text,
                "start": round(seg_start / TARGET_SR, 2),
                "duration": round(seg_len / TARGET_SR, 2),
            }))

    try:
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                break

            if msg.get("bytes") is not None:
                data = msg["bytes"]
                if fmt == "f32":
                    samples = np.frombuffer(data, dtype=np.float32)
                else:
                    samples = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768.0
                if samples.size:
                    vad.accept_waveform(samples)
                    await drain_segments()

            elif msg.get("text") is not None:
                if msg["text"].strip().lower() == "done":
                    vad.flush()
                    await drain_segments()
                    await ws.send_text(json.dumps({"type": "final", "text": " ".join(segments)}))
                    break
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.warning("stt stream error: %s", e)
        try:
            await ws.send_text(json.dumps({"type": "error", "detail": str(e)}))
        except Exception:
            pass
    finally:
        try:
            await ws.close()
        except Exception:
            pass
