"""Assistant-wide TTS plus exact-reference word timing.

The implementation is deliberately the same architecture proven by Teaching:
CPU faster-whisper obtains word timestamps from the generated audio, then a
sequence alignment maps them back onto the exact source words. Every reference
word receives a timing; missed ASR words are interpolated rather than dropped.
"""

from __future__ import annotations

import difflib
import logging
import re
import tempfile
import threading
from collections.abc import Callable
from typing import Any

from app.config import Settings
from app.services.tts import synthesize_speech

logger = logging.getLogger("coach.speech_alignment")
_WORD_RE = re.compile(r"[\w']+")
_MODEL_LOCK = threading.Lock()
_MODELS: dict[str, Any] = {}


def _model(size: str):
    clean = (size or "small").strip() or "small"
    with _MODEL_LOCK:
        if clean not in _MODELS:
            from faster_whisper import WhisperModel

            _MODELS[clean] = WhisperModel(clean, device="cpu", compute_type="int8")
        return _MODELS[clean]


def _normalize(word: str) -> str:
    return word.strip().lower().strip(".,!?;:\"'()[]")


def _fill_gaps(timings: list[dict[str, int | str] | None], words: list[str]) -> None:
    index = 0
    while index < len(timings):
        if timings[index] is not None:
            index += 1
            continue
        gap_start = index
        while index < len(timings) and timings[index] is None:
            index += 1
        gap_end = index
        left = int(timings[gap_start - 1]["end_ms"]) if gap_start > 0 else 0
        right = (
            int(timings[gap_end]["start_ms"])
            if gap_end < len(timings)
            else left + 400 * (gap_end - gap_start + 1)
        )
        span = max(right - left, gap_end - gap_start + 1)
        step = span / (gap_end - gap_start + 1)
        for offset, word_index in enumerate(range(gap_start, gap_end), start=1):
            timings[word_index] = {
                "word": words[word_index],
                "start_ms": round(left + step * (offset - 1)),
                "end_ms": round(left + step * offset),
            }


def align_reference_words(
    audio: bytes,
    source_text: str,
    *,
    model_size: str = "small",
    model: Any | None = None,
) -> list[dict[str, int | str]]:
    reference = _WORD_RE.findall(source_text)
    if not reference or not audio:
        return []
    recognizer = model or _model(model_size)
    with tempfile.NamedTemporaryFile(suffix=".mp3") as tmp:
        tmp.write(audio)
        tmp.flush()
        segments, _ = recognizer.transcribe(
            tmp.name, word_timestamps=True, language="en"
        )
        heard = [
            (word.word.strip(), float(word.start), float(word.end))
            for segment in segments
            for word in (segment.words or [])
        ]
    matcher = difflib.SequenceMatcher(
        a=[_normalize(word) for word in reference],
        b=[_normalize(word) for word, _, _ in heard],
        autojunk=False,
    )
    timings: list[dict[str, int | str] | None] = [None] * len(reference)
    for tag, ref_low, ref_high, heard_low, _ in matcher.get_opcodes():
        if tag != "equal":
            continue
        for offset in range(ref_high - ref_low):
            _, start, end = heard[heard_low + offset]
            timings[ref_low + offset] = {
                "word": reference[ref_low + offset],
                "start_ms": round(start * 1000),
                "end_ms": round(end * 1000),
            }
    _fill_gaps(timings, reference)
    return [timing for timing in timings if timing is not None]


def _estimated_words(text: str) -> list[dict[str, int | str]]:
    # Fail-soft presentation fallback only. The response marks this as
    # estimated so it can never be confused with measured forced alignment.
    words = _WORD_RE.findall(text)
    return [
        {"word": word, "start_ms": index * 300, "end_ms": (index + 1) * 300}
        for index, word in enumerate(words)
    ]


def synthesize_aligned_speech(
    text: str,
    *,
    settings: Settings,
    synthesizer: Callable[..., bytes | None] = synthesize_speech,
    prefer_estimated: bool = False,
) -> dict[str, object]:
    audio = synthesizer(text, settings=settings) or b""
    if not audio:
        return {"audio": b"", "words": [], "alignment": "unavailable"}
    # Conversational playback values time-to-first-audio over post-hoc exact
    # alignment. The client still receives deterministic timings immediately,
    # while an explicit per-message replay keeps the slower forced alignment.
    if prefer_estimated or not settings.speech_alignment_enabled:
        return {
            "audio": audio,
            "words": _estimated_words(text),
            "alignment": "estimated",
        }
    try:
        words = align_reference_words(
            audio,
            text,
            model_size=settings.speech_alignment_model,
        )
        if words:
            return {"audio": audio, "words": words, "alignment": "forced"}
    except Exception as exc:  # noqa: BLE001 - speech must remain fail-soft
        logger.warning("speech alignment failed (%s)", type(exc).__name__)
    return {
        "audio": audio,
        "words": _estimated_words(text),
        "alignment": "estimated",
    }
