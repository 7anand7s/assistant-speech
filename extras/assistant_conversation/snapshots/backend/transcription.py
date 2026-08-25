"""Local voice transcription (PRD work item #10, voice input pipeline).

Turns a voice memo (OGG/Opus bytes, already downloaded to the home server) into
text. Two local backends, tried in order:

1. **Self-hosted STT endpoint** (``STT_BASE_URL``, Parakeet on the kokoro box —
   ``POST /stt``). Preferred when configured: it offloads transcription to a
   dedicated, purpose-built, faster-than-real-time container instead of loading a
   Whisper model into the bot's own process.
2. **In-process ``faster-whisper``** — the original path, and the automatic
   fallback if the endpoint is unset, unreachable, or errors.

Privacy boundary (hard requirement): audio is transcribed *on the homelab* and
never egresses. The endpoint is a LAN/tailnet host (same class as Ollama), and
Whisper runs in-process — there is deliberately **no cloud-STT path**. The bytes
fed in here come from Telegram's file API (inbound download) or the Mini App,
are held in memory, transcribed, and dropped; they are never forwarded off-box.

The heavy ``faster_whisper`` import and model load stay lazy and cached, so
importing this module (and the whole test suite) costs nothing until a real
Whisper transcription is requested. Tests replace :func:`_load_model` with a fake
model, inject an ``httpx`` client for the endpoint path, or drive the Telegram
handler with a stub transcriber.
"""

from __future__ import annotations

import io
import logging
from functools import lru_cache
from typing import Any

from app.compute.context import (
    AdmissionRequired,
    accelerator_admission_required,
    require_admitted_execution,
)
from app.config import Settings, get_settings

logger = logging.getLogger("coach.transcription")

# Parakeet transcribes faster than real time, but a voice note can be a minute+
# and the box is shared — a generous ceiling that still bounds a stuck request.
_STT_TIMEOUT = 60.0


class TranscriptionError(RuntimeError):
    """Raised when transcription is unavailable or fails on every backend.

    The Telegram handler catches this and replies with a friendly "couldn't
    transcribe — mind typing it?" rather than crashing the update.
    """


def _transcribe_remote(
    audio: bytes, settings: Settings, *, client: Any | None = None
) -> str:
    """Transcribe via the self-hosted STT endpoint (``POST {STT_BASE_URL}/stt``).

    Sends the bytes as a multipart ``file`` field and returns the ``text`` from the
    JSON response, stripped. Raises :class:`TranscriptionError` on any transport /
    HTTP / decode failure so the caller can fall back to local Whisper. ``client``
    is an optional pre-built ``httpx.Client`` (tests inject a ``MockTransport``).
    """
    base = settings.stt_base_url.rstrip("/")
    owns_client = client is None
    if owns_client:
        import httpx

        client = httpx.Client(timeout=_STT_TIMEOUT)
    try:
        resp = client.post(
            f"{base}/stt",
            files={"file": ("voice.oga", audio, "application/octet-stream")},
        )
        resp.raise_for_status()
        data = resp.json()
    except Exception as exc:  # noqa: BLE001 — any failure → typed, so caller can fall back
        raise TranscriptionError(f"remote STT failed: {type(exc).__name__}") from exc
    finally:
        if owns_client:
            client.close()

    text = data.get("text") if isinstance(data, dict) else None
    if not isinstance(text, str):
        raise TranscriptionError("remote STT returned no 'text' field")
    return text.strip()


@lru_cache(maxsize=2)
def _load_model(model_size: str, compute_type: str) -> Any:
    """Load (and cache) a local faster-whisper model. CPU-only inference.

    Cached on ``(model_size, compute_type)`` so the model is materialised once per
    process. The import is deferred to here so a machine without the (heavy)
    dependency — or the model weights — only fails when Whisper is actually used.

    Note on network: **inference** is fully local, but on the *first* load with a
    cold cache faster-whisper downloads the weights from the HuggingFace Hub. No
    audio ever egresses either way.
    """
    from faster_whisper import WhisperModel  # lazy, heavy, optional at rest

    return WhisperModel(model_size, device="cpu", compute_type=compute_type)


def _transcribe_whisper(audio: bytes, settings: Settings) -> str:
    """Transcribe with the in-process faster-whisper model (local, CPU)."""
    try:
        model = _load_model(settings.whisper_model, settings.whisper_compute_type)
    except Exception as exc:  # noqa: BLE001 — surface as a typed, catchable error
        raise TranscriptionError(f"local whisper model unavailable: {exc}") from exc

    language = settings.whisper_language.strip() or None
    try:
        segments, _info = model.transcribe(io.BytesIO(audio), language=language)
        return " ".join((seg.text or "").strip() for seg in segments).strip()
    except Exception as exc:  # noqa: BLE001 — decode/inference failure, degrade gracefully
        raise TranscriptionError(f"transcription failed: {exc}") from exc


def transcribe_audio(
    audio: bytes, *, settings: Settings | None = None, client: Any | None = None
) -> str:
    """Transcribe in-memory audio bytes to text (endpoint preferred, Whisper fallback).

    When ``STT_BASE_URL`` is set (and not in ``OFFLINE_MODE``), the self-hosted
    endpoint is tried first; on ANY failure it falls back to local faster-whisper,
    so a transient endpoint outage never drops a voice note. With no endpoint
    configured it goes straight to Whisper (the original path). Returns the
    transcript, stripped. Raises :class:`TranscriptionError` on empty input or when
    every available backend fails — audio never leaves the homelab either way.
    """
    settings = settings or get_settings()
    if not audio:
        raise TranscriptionError("no audio data to transcribe")
    if settings.stt_accelerator_backed and accelerator_admission_required(settings):
        # The deployed Parakeet service and local faster-whisper fallback are
        # CPU-only.  If an operator replaces them with accelerator-backed STT,
        # the explicit capability flag restores the fail-closed lease guard.
        try:
            require_admitted_execution()
        except AdmissionRequired as exc:
            raise TranscriptionError("STT is waiting for durable compute admission") from exc

    base = (settings.stt_base_url or "").strip()
    if base and not settings.offline_mode:
        try:
            return _transcribe_remote(audio, settings, client=client)
        except TranscriptionError as exc:
            logger.warning(
                "remote STT unavailable (%s) — falling back to local whisper", exc
            )

    return _transcribe_whisper(audio, settings)
