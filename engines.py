"""
TTS ENGINES (role 1) - text in, audio out. No language model is involved
anywhere in this file.

  kokoro - local ONNX model (kokoro-onnx). CPU-only, fully offline.
  edge   - Microsoft neural voices via edge-tts (same voices as Windows 11's
           "natural" voices). Needs internet. Used as automatic fallback if
           Kokoro is unavailable.
"""

import asyncio
import io
import logging

import edge_tts
from fastapi import HTTPException

import config
import streaming

log = logging.getLogger("tts.engines")

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

KOKORO_SAMPLE_RATE = 24000

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
    return Kokoro(config.KOKORO_MODEL_PATH, config.KOKORO_VOICES_PATH)


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
            log.info("Kokoro loaded from %s", config.KOKORO_MODEL_PATH)
        except Exception as e:
            _kokoro_init_error = e
            log.warning("Kokoro failed to load, will fall back to edge-tts: %s", e)
            raise
    return _kokoro_instance


def kokoro_status() -> tuple[bool, str | None]:
    if _kokoro_instance is not None:
        return True, None
    if _kokoro_init_error is not None:
        return False, str(_kokoro_init_error)
    return False, "not loaded yet"


def resolve_voice(engine: str, voice: str | None) -> str:
    if voice:
        return {"kokoro": KOKORO_OPENAI_MAP, "edge": EDGE_OPENAI_MAP}[engine].get(voice.lower(), voice)
    return config.KOKORO_VOICE if engine == "kokoro" else config.EDGE_VOICE


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


# --- One-shot synthesis ------------------------------------------------------

async def synth_kokoro(text: str, voice: str, speed: float = 1.0) -> bytes:
    import soundfile as sf

    kokoro = await get_kokoro()
    lang = KOKORO_LANG_CODES.get(voice[:1], "en-us")
    samples, sr = await asyncio.to_thread(kokoro.create, text, voice=voice, speed=speed, lang=lang)
    wav_buf = io.BytesIO()
    sf.write(wav_buf, samples, sr, format="WAV")
    return await wav_to_mp3(wav_buf.getvalue())


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


# --- Streaming synthesis: sentence-by-sentence, audio flows as it's ready ----

async def synth_kokoro_sentences_stream(sentences_iter, voice: str, speed: float = 1.0):
    """One continuous MP3 stream built from per-sentence Kokoro synthesis."""
    kokoro = await get_kokoro()
    lang = KOKORO_LANG_CODES.get(voice[:1], "en-us")
    async with streaming.StreamingMp3Encoder(sample_rate=KOKORO_SAMPLE_RATE) as enc:
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
    engine = engine or config.DEFAULT_ENGINE
    if engine == "kokoro":
        try:
            await get_kokoro()
            return "kokoro"
        except Exception:
            return "edge-fallback"
    return "edge"


# --- Unified dispatch with kokoro -> edge fallback ---------------------------

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
    import normalize  # imported here so engines.py has no import-time LLM dependency

    if not text.strip():
        raise HTTPException(status_code=400, detail="text is empty")
    engine = engine or config.DEFAULT_ENGINE

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
            audio = await synth_edge(text, resolve_voice("edge", voice), rate, pitch)
            return audio, "edge-fallback", was_flagged, norm_model

    audio = await synth_edge(text, resolve_voice("edge", voice), rate, pitch)
    return audio, "edge", was_flagged, norm_model


async def synthesize_stream(
    sentences_iter,
    engine: str | None = None,
    voice: str | None = None,
    speed: float = 1.0,
    rate: str = "+0%",
    pitch: str = "+0Hz",
):
    """Returns (async_audio_chunk_generator, engine_used)."""
    used = await resolve_streaming_engine(engine)
    if used == "kokoro":
        return synth_kokoro_sentences_stream(sentences_iter, resolve_voice("kokoro", voice), speed), used
    return synth_edge_sentences_stream(sentences_iter, resolve_voice("edge", voice), rate, pitch), used
