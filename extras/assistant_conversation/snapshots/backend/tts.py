"""Text-to-speech via the self-hosted kokoro-tts endpoint (voice replies).

``synthesize_speech(text)`` turns a bot reply into MP3 bytes by POSTing to the
homelab's kokoro-tts container (``TTS_BASE_URL``, e.g. ``http://192.168.0.250:8880``
— LAN/tailnet only, deliberately never Funnel-exposed). The webhook calls it
from :func:`app.telegram.webhook._send_voice_notes`, strictly AFTER every text
reply is delivered (post-ack, in a background task on the fast path), so the
owner gets the same content as a Telegram voice note without TTS latency ever
touching text delivery.

Design rules:

* **Fail-quiet, always.** This function returns ``bytes`` or ``None`` — it never
  raises. A TTS outage, timeout, or bad response must never delay or break the
  text reply; the coach just goes silent-audio for that turn (logged).
* **Off by default.** An empty ``TTS_BASE_URL`` (or ``OFFLINE_MODE``) disables
  the feature entirely — no HTTP, no latency added.
* **Bounded input.** Text beyond ``tts_max_chars`` is truncated at the last
  sentence boundary under the cap (falling back to whitespace, then a hard cut)
  so a huge digest can't produce a minutes-long synth call. Truncation is logged.
* The endpoint runs its own normalization pipeline (markdown/emoji stripped,
  URLs made speakable), so the reply text is sent as-is.

Privacy note: the reply text — which can contain personal data — leaves the
process, but only to the owner's own TTS box on the same private network. That
is inside the SPEC §5 boundary (local homelab services), like Ollama itself.
"""

from __future__ import annotations

import logging
from typing import Any

from app.compute.context import (
    AdmissionRequired,
    accelerator_admission_required,
    require_admitted_execution,
)
from app.config import Settings, get_settings

logger = logging.getLogger("coach.tts")

# Sentence enders considered when truncating an over-long text (see module doc).
_SENTENCE_ENDERS = (". ", "! ", "? ", ".\n", "!\n", "?\n")


def _truncate_for_speech(text: str, max_chars: int) -> str:
    """Cap ``text`` at ``max_chars``, preferring the last sentence boundary.

    Falls back to the last whitespace under the cap, then to a hard cut, so the
    result is never empty for a non-empty input.
    """
    if len(text) <= max_chars:
        return text
    head = text[:max_chars]
    best = max(head.rfind(e) + len(e.rstrip("\n ")) for e in _SENTENCE_ENDERS)
    if best <= 0:
        space = head.rfind(" ")
        best = space if space > 0 else max_chars
    truncated = head[:best].rstrip()
    logger.info("tts: reply truncated for speech (%d -> %d chars)", len(text), len(truncated))
    return truncated or head


def synthesize_speech(
    text: str,
    *,
    settings: Settings | None = None,
    client: Any | None = None,
) -> bytes | None:
    """Synthesise ``text`` to MP3 bytes via kokoro-tts, or ``None``.

    Returns ``None`` — never raises — when the feature is off (no
    ``TTS_BASE_URL``), in ``OFFLINE_MODE``, for blank text, or on any HTTP/
    transport failure or empty audio body. ``client`` is an optional pre-built
    ``httpx.Client`` (tests inject a ``MockTransport``-backed one).
    """
    settings = settings or get_settings()
    base = (settings.tts_base_url or "").strip().rstrip("/")
    if not base or settings.offline_mode:
        return None
    speak = (text or "").strip()
    if not speak:
        return None
    if settings.tts_accelerator_backed and accelerator_admission_required(settings):
        # CPU-only shared speech is deliberately outside the GPU broker.  A
        # deployment which selects an accelerator-backed TTS endpoint must say
        # so explicitly and is then fenced like every other accelerator path.
        try:
            require_admitted_execution()
        except AdmissionRequired:
            logger.info("tts: durable compute admission required — reply stays text-only")
            return None
    speak = _truncate_for_speech(speak, settings.tts_max_chars)

    payload = {"text": speak, "voice": settings.tts_voice, "speed": settings.tts_speed}

    owns_client = client is None
    if owns_client:
        import httpx

        client = httpx.Client(timeout=settings.tts_timeout_seconds)
    try:
        resp = client.post(f"{base}/tts", json=payload)
        resp.raise_for_status()
        audio = resp.content
    except Exception as exc:  # noqa: BLE001 — audio is best-effort, never fatal
        logger.warning("tts: synthesis failed (%s: %s) — reply stays text-only",
                       type(exc).__name__, exc)
        return None
    finally:
        if owns_client:
            client.close()

    if not audio:
        logger.warning("tts: endpoint returned empty audio — reply stays text-only")
        return None
    engine = resp.headers.get("X-TTS-Engine", "?")
    logger.debug("tts: %d chars -> %d bytes (engine=%s)", len(speak), len(audio), engine)
    return audio
