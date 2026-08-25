"""Local voice-transcription service tests (work item #10).

These never touch the real (heavy) faster-whisper model or the network: the
model is faked by monkeypatching :func:`_load_model`. What we pin here is the
service contract the Telegram voice handler depends on — a joined/stripped
transcript on success, and a typed :class:`TranscriptionError` (never a raw
crash) on empty input, an unavailable model, or a decode failure — plus the
privacy invariant that no cloud-STT path exists.
"""

from __future__ import annotations

from dataclasses import dataclass

import pytest

from app.config import Settings
from app.services import transcription
from app.services.transcription import TranscriptionError, transcribe_audio


@dataclass
class _Seg:
    text: str


class _FakeModel:
    """Stand-in for faster-whisper's WhisperModel: records the call, returns segs."""

    def __init__(self, segments: list[_Seg]) -> None:
        self.segments = segments
        self.calls: list[dict] = []

    def transcribe(self, source, language=None):
        self.calls.append({"language": language})
        return iter(self.segments), {"language": "en"}


def _settings(**over) -> Settings:
    # _env_file=None keeps these hermetic against the host's real .env (which now
    # carries STT_BASE_URL live) — the Whisper-path tests need it empty.
    base = dict(
        whisper_model="base",
        whisper_compute_type="int8",
        whisper_language="",
        stt_base_url="",
    )
    base.update(over)
    return Settings(_env_file=None, **base)


def _mock_client(handler):
    """An httpx.Client whose requests hit a MockTransport handler (no network)."""
    import httpx

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_transcribe_joins_and_strips_segments(monkeypatch):
    model = _FakeModel([_Seg("  two eggs "), _Seg(" and toast  ")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)

    text = transcribe_audio(b"oggbytes", settings=_settings())

    assert text == "two eggs and toast"


def test_language_setting_is_passed_through(monkeypatch):
    model = _FakeModel([_Seg("hallo")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)

    transcribe_audio(b"x", settings=_settings(whisper_language="de"))

    assert model.calls == [{"language": "de"}]


def test_blank_language_autodetects(monkeypatch):
    # "" (the default) must become None so Whisper auto-detects, not the literal "".
    model = _FakeModel([_Seg("hi")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)

    transcribe_audio(b"x", settings=_settings(whisper_language=""))

    assert model.calls == [{"language": None}]


def test_empty_audio_raises(monkeypatch):
    # Must fail before any model load — nothing to transcribe.
    def _boom(*a):
        raise AssertionError("model must not be loaded for empty audio")

    monkeypatch.setattr(transcription, "_load_model", _boom)
    with pytest.raises(TranscriptionError):
        transcribe_audio(b"", settings=_settings())


def test_unavailable_model_becomes_transcription_error(monkeypatch):
    def _fail(*a):
        raise RuntimeError("weights not found")

    monkeypatch.setattr(transcription, "_load_model", _fail)
    with pytest.raises(TranscriptionError):
        transcribe_audio(b"x", settings=_settings())


def test_decode_failure_becomes_transcription_error(monkeypatch):
    class _BadModel:
        def transcribe(self, source, language=None):
            raise RuntimeError("corrupt ogg")

    monkeypatch.setattr(transcription, "_load_model", lambda *a: _BadModel())
    with pytest.raises(TranscriptionError):
        transcribe_audio(b"x", settings=_settings())


# --- self-hosted STT endpoint (primary) + whisper fallback -----------------

def test_remote_stt_used_when_configured(monkeypatch):
    import httpx

    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["ctype"] = request.headers.get("content-type", "")
        seen["body"] = request.read()
        return httpx.Response(200, json={"text": "  two eggs and toast  "})

    # Whisper must NOT be touched when the endpoint answers.
    monkeypatch.setattr(
        transcription, "_load_model",
        lambda *a: pytest.fail("whisper must not load when remote STT succeeds"),
    )
    text = transcribe_audio(
        b"oggbytes", settings=_settings(stt_base_url="http://stt.test:8880"),
        client=_mock_client(handler),
    )
    assert text == "two eggs and toast"
    assert seen["url"] == "http://stt.test:8880/stt"
    assert seen["ctype"].startswith("multipart/form-data")
    assert b'name="file"' in seen["body"] and b"oggbytes" in seen["body"]


def test_remote_trailing_slash_normalised(monkeypatch):
    import httpx

    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        return httpx.Response(200, json={"text": "ok"})

    transcribe_audio(
        b"x", settings=_settings(stt_base_url="http://stt.test:8880/"),
        client=_mock_client(handler),
    )
    assert seen["url"] == "http://stt.test:8880/stt"  # no double slash


@pytest.mark.parametrize("handler_kind", ["http_500", "transport_error", "bad_json", "no_text_field"])
def test_remote_failure_falls_back_to_whisper(monkeypatch, handler_kind):
    import httpx

    def handler(request: httpx.Request) -> httpx.Response:
        if handler_kind == "http_500":
            return httpx.Response(500, text="boom")
        if handler_kind == "transport_error":
            raise httpx.ConnectError("refused")
        if handler_kind == "bad_json":
            return httpx.Response(200, content=b"not json")
        return httpx.Response(200, json={"duration_seconds": 1.0})  # no "text"

    model = _FakeModel([_Seg("fallback text")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)

    text = transcribe_audio(
        b"x", settings=_settings(stt_base_url="http://stt.test:8880"),
        client=_mock_client(handler),
    )
    assert text == "fallback text"  # whisper covered the endpoint failure


def test_offline_mode_skips_remote_uses_whisper(monkeypatch):
    # OFFLINE_MODE must not make the network call even if an endpoint is set.
    def handler(request):  # pragma: no cover - must never run
        raise AssertionError("offline mode must not call the STT endpoint")

    model = _FakeModel([_Seg("local only")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)
    text = transcribe_audio(
        b"x",
        settings=_settings(stt_base_url="http://stt.test:8880", offline_mode=True),
        client=_mock_client(handler),
    )
    assert text == "local only"


def test_remote_empty_transcript_is_returned_not_fallback(monkeypatch):
    # An endpoint that succeeds with empty text (silence) is a VALID result — do
    # not fall back to whisper (which would re-process the same silence).
    import httpx

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"text": "   "})

    monkeypatch.setattr(
        transcription, "_load_model",
        lambda *a: pytest.fail("empty (valid) transcript must not fall back"),
    )
    assert transcribe_audio(
        b"x", settings=_settings(stt_base_url="http://stt.test:8880"),
        client=_mock_client(handler),
    ) == ""


def _imported_module_names(mod) -> set[str]:
    """Top-level names pulled in by ``mod``'s import statements, via the AST.

    Parses the real ``import`` / ``from`` statements — including deferred ones
    nested in a function, like the lazy ``faster_whisper`` load — so it can't be
    fooled by a vendor name appearing in a comment or string, and can't miss an
    aliased import (``import openai as x``).
    """
    import ast
    import inspect

    tree = ast.parse(inspect.getsource(mod))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module.split(".")[0])
    return names


def test_no_cloud_stt_sdk_is_imported():
    # Privacy guard: the module may talk to the LOCAL whisper stack and the LAN
    # STT endpoint (httpx, like the Ollama/search/TTS clients), but must import NO
    # cloud-STT SDK — so there is provably no code path that ships audio to a
    # third-party service. AST-based (real imports, incl. the lazy ones) rather
    # than a source-substring denylist. httpx is allowed BECAUSE the endpoint it
    # reaches is an owner-configured homelab host, never a public service.
    cloud_stt = {
        "openai", "deepgram", "assemblyai", "google", "boto3", "azure",
        "aiohttp", "websocket", "requests",
    }
    leaked = _imported_module_names(transcription) & cloud_stt
    assert not leaked, f"transcription must not import a cloud-STT SDK: {leaked}"


def test_transcription_path_opens_no_socket(monkeypatch):
    # Behavioral egress guard: running the service's own code on every voice memo
    # (settings read → decode-to-BytesIO → join/strip) must open no network
    # socket. The heavy model is faked, so this pins that the *wrapper* — the only
    # code that runs before the local model — never reaches out, regardless of
    # which SDK a regression might reach for.
    import socket

    def _blocked(*a, **k):
        raise AssertionError("transcription attempted network egress")

    monkeypatch.setattr(socket.socket, "connect", _blocked)
    monkeypatch.setattr(socket, "create_connection", _blocked)

    model = _FakeModel([_Seg("two eggs")])
    monkeypatch.setattr(transcription, "_load_model", lambda *a: model)

    assert transcribe_audio(b"oggbytes", settings=_settings()) == "two eggs"
