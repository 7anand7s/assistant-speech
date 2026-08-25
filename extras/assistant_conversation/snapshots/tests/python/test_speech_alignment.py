"""CPU-only tests for Assistant-wide exact-reference speech timing."""
from __future__ import annotations

from dataclasses import dataclass

from app.config import get_settings
from app.services.speech_alignment import (
    align_reference_words,
    synthesize_aligned_speech,
)


@dataclass
class _Word:
    word: str
    start: float
    end: float


@dataclass
class _Segment:
    words: list[_Word]


class _Recognizer:
    def transcribe(self, path, **kwargs):
        assert kwargs == {"word_timestamps": True, "language": "en"}
        return (
            [
                _Segment(
                    [
                        _Word("Natural", 0.1, 0.4),
                        _Word("speech", 0.4, 0.8),
                        _Word("now", 1.2, 1.5),
                    ]
                )
            ],
            None,
        )


def test_exact_source_words_are_timed_and_asr_gaps_are_interpolated():
    words = align_reference_words(
        b"fake-mp3",
        "Natural speech feels better now.",
        model=_Recognizer(),
    )

    assert [item["word"] for item in words] == [
        "Natural",
        "speech",
        "feels",
        "better",
        "now",
    ]
    assert words[0]["start_ms"] == 100
    assert 800 <= words[2]["start_ms"] < words[2]["end_ms"]
    assert words[3]["end_ms"] <= 1200
    assert words[-1]["end_ms"] == 1500


def test_alignment_is_fail_soft_and_never_invokes_real_tts():
    settings = get_settings().model_copy(
        update={"speech_alignment_enabled": False}
    )
    result = synthesize_aligned_speech(
        "Two spoken words",
        settings=settings,
        synthesizer=lambda text, *, settings: b"audio",
    )
    assert result["audio"] == b"audio"
    assert result["alignment"] == "estimated"
    assert [item["word"] for item in result["words"]] == ["Two", "spoken", "words"]


def test_realtime_speech_skips_forced_alignment_even_when_enabled(monkeypatch):
    settings = get_settings().model_copy(update={"speech_alignment_enabled": True})
    monkeypatch.setattr(
        "app.services.speech_alignment.align_reference_words",
        lambda *args, **kwargs: (_ for _ in ()).throw(
            AssertionError("realtime speech must not wait for forced alignment")
        ),
    )

    result = synthesize_aligned_speech(
        "Start speaking right away",
        settings=settings,
        synthesizer=lambda text, *, settings: b"audio",
        prefer_estimated=True,
    )

    assert result["alignment"] == "estimated"
    assert [item["word"] for item in result["words"]] == [
        "Start",
        "speaking",
        "right",
        "away",
    ]
