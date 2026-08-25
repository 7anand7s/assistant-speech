"""TTS voice-reply tests (kokoro-tts integration).

Pins the three layers of the feature, all hermetic (no live TTS box):

* :func:`app.services.tts.synthesize_speech` — request shape against a
  ``MockTransport``, the off/offline/blank gates, fail-quiet on every error
  class (HTTP status, transport, empty body), and sentence-boundary truncation.
* :meth:`TelegramClient.send_voice` — multipart ``sendVoice`` upload shape,
  offline no-op, and token-free failure (mirrors the send_message contract).
* the webhook send path — the voice note goes out AFTER the text, is skipped
  when synthesis yields nothing, and a raising send never breaks text delivery.
"""

from __future__ import annotations

import httpx
import pytest

from app.config import Settings
from app.services.tts import _truncate_for_speech, synthesize_speech
from app.telegram.client import TelegramClient, TelegramSendError

TTS_BASE = "http://tts-box:8880"


def _settings(**over) -> Settings:
    # _env_file=None + explicit fields: hermetic against the host's real .env
    # (the live deployment sets TTS_BASE_URL, which must not leak in here).
    base = {"tts_base_url": TTS_BASE, "offline_mode": False}
    base.update(over)
    return Settings(_env_file=None, **base)


def _client(handler) -> httpx.Client:
    return httpx.Client(transport=httpx.MockTransport(handler))


# --- synthesize_speech ------------------------------------------------------

def test_synthesis_posts_expected_payload_and_returns_audio():
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json

        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, content=b"MP3BYTES", headers={"X-TTS-Engine": "kokoro"})

    audio = synthesize_speech(
        "Hello coach.",
        settings=_settings(tts_voice="am_michael", tts_speed=1.2),
        client=_client(handler),
    )

    assert audio == b"MP3BYTES"
    assert seen["url"] == f"{TTS_BASE}/tts"
    assert seen["body"] == {"text": "Hello coach.", "voice": "am_michael", "speed": 1.2}


def test_disabled_without_base_url():
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("no TTS request may be made when the feature is off")

    assert synthesize_speech("hi", settings=_settings(tts_base_url=""), client=_client(handler)) is None


def test_disabled_in_offline_mode():
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("offline mode must not make a request")

    assert synthesize_speech("hi", settings=_settings(offline_mode=True), client=_client(handler)) is None


def test_blank_text_yields_none():
    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("blank text must not make a request")

    assert synthesize_speech("   ", settings=_settings(), client=_client(handler)) is None


@pytest.mark.parametrize(
    "handler_result",
    [
        lambda req: httpx.Response(500, text="boom"),           # HTTP error
        lambda req: httpx.Response(200, content=b""),           # empty audio
        lambda req: (_ for _ in ()).throw(httpx.ConnectError("refused")),  # transport
    ],
)
def test_every_failure_is_quiet_none(handler_result):
    assert synthesize_speech("hi", settings=_settings(), client=_client(handler_result)) is None


def test_truncation_prefers_sentence_boundary():
    text = "First sentence. Second sentence. " + "x" * 100
    out = _truncate_for_speech(text, 40)
    assert out == "First sentence. Second sentence."


def test_truncation_falls_back_to_whitespace_then_hard_cut():
    assert _truncate_for_speech("word " * 20, 12).strip() == "word word"
    assert _truncate_for_speech("y" * 50, 10) == "y" * 10  # no boundary at all


def test_short_text_untouched():
    assert _truncate_for_speech("short.", 3000) == "short."


# --- TelegramClient.send_voice ----------------------------------------------

TOKEN = "123456:FAKE-TOKEN-abc"


def _mock_httpx(monkeypatch, handler):
    client = httpx.Client(transport=httpx.MockTransport(handler))
    monkeypatch.setattr(httpx, "post", lambda url, **kw: client.post(url, **kw))


def test_send_voice_uploads_multipart(monkeypatch):
    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = str(request.url)
        seen["content_type"] = request.headers.get("content-type", "")
        seen["body"] = request.read()
        return httpx.Response(200, json={"ok": True, "result": {"message_id": 7}})

    _mock_httpx(monkeypatch, handler)
    out = TelegramClient(TOKEN).send_voice(42, b"MP3BYTES")

    assert out["ok"] is True
    assert seen["url"] == f"https://api.telegram.org/bot{TOKEN}/sendVoice"
    assert seen["content_type"].startswith("multipart/form-data")
    assert b"MP3BYTES" in seen["body"]
    assert b'name="chat_id"' in seen["body"]
    assert b"42" in seen["body"]


def test_send_voice_offline_noop():
    out = TelegramClient("", offline=True).send_voice(42, b"x")
    assert out == {"ok": True, "offline": True}


def test_send_voice_failure_is_token_free(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(400, json={"ok": False, "description": "Bad Request"})

    _mock_httpx(monkeypatch, handler)
    with pytest.raises(TelegramSendError) as exc_info:
        TelegramClient(TOKEN).send_voice(42, b"x")
    msg = str(exc_info.value)
    assert TOKEN not in msg
    assert "400" in msg


# --- webhook send path -------------------------------------------------------
#
# Architecture under test (council #99): _process_and_send delivers ALL texts
# and only RETURNS the responses; voice notes happen afterwards in
# _send_voice_notes — post-ack in a background task on the fast path — so a
# slow/hung TTS box can never delay a text reply or the webhook 200.

def test_process_and_send_delivers_texts_and_returns_them_without_voicing(
    monkeypatch, tmp_path
):
    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    calls: list[tuple] = []
    monkeypatch.setattr(
        wh, "handle_update",
        lambda update, **kw: [
            BotResponse(chat_id=42, text="First."),
            BotResponse(chat_id=42, text="Second."),
        ],
    )
    monkeypatch.setattr(
        wh.TelegramClient, "send_message",
        lambda self, chat_id, text, **kw: calls.append(("text", text)) or {"ok": True},
    )
    monkeypatch.setattr(
        wh.TelegramClient, "send_voice",
        lambda self, *a, **kw: pytest.fail("_process_and_send must never voice"),
    )
    monkeypatch.setattr(
        wh, "synthesize_speech",
        lambda *a, **kw: pytest.fail("_process_and_send must never synthesise"),
    )

    sent, responses = wh._process_and_send(
        {"message": {}}, _settings(database_path=tmp_path / "coach.db")
    )

    # Both texts out back-to-back, nothing between them; responses handed back.
    assert sent == 2
    assert calls == [("text", "First."), ("text", "Second.")]
    assert [r.text for r in responses] == ["First.", "Second."]


def test_send_voice_notes_voices_each_reply_and_skips_none(monkeypatch, tmp_path):
    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    voiced: list[tuple] = []
    monkeypatch.setattr(
        wh, "synthesize_speech",
        lambda text, settings=None: b"MP3" if text != "unspeakable" else None,
    )
    monkeypatch.setattr(
        wh.TelegramClient, "send_voice",
        lambda self, chat_id, audio, **kw: voiced.append((chat_id, audio)) or {"ok": True},
    )

    responses = [
        BotResponse(chat_id=42, text="Hi."),
        BotResponse(chat_id=42, text="unspeakable"),
        BotResponse(chat_id=42, text="Bye."),
    ]
    sent = wh._send_voice_notes(responses, _settings(database_path=tmp_path / "coach.db"))

    assert sent == 2  # the None-synth reply is skipped, not fatal
    assert voiced == [(42, b"MP3"), (42, b"MP3")]


def test_send_voice_notes_noop_when_unconfigured(monkeypatch, tmp_path):
    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    monkeypatch.setattr(
        wh, "synthesize_speech",
        lambda *a, **kw: pytest.fail("must not synthesise when TTS is off"),
    )
    sent = wh._send_voice_notes(
        [BotResponse(chat_id=42, text="Hi.")],
        _settings(tts_base_url="", database_path=tmp_path / "coach.db"),
    )
    assert sent == 0


def test_send_voice_notes_one_failure_never_skips_the_rest(monkeypatch, tmp_path):
    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    voiced: list[str] = []
    monkeypatch.setattr(wh, "synthesize_speech", lambda text, settings=None: b"MP3")

    def _send(self, chat_id, audio, **kw):
        # First send blows up; later ones must still be attempted.
        if not voiced:
            voiced.append("boom")
            raise TelegramSendError("sendVoice failed: HTTP 400")
        voiced.append("ok")
        return {"ok": True}

    monkeypatch.setattr(wh.TelegramClient, "send_voice", _send)

    responses = [BotResponse(chat_id=42, text="A."), BotResponse(chat_id=42, text="B.")]
    sent = wh._send_voice_notes(responses, _settings(database_path=tmp_path / "coach.db"))

    assert voiced == ["boom", "ok"]
    assert sent == 1  # only the successful one counted; no exception escaped


def test_run_voice_task_never_raises(monkeypatch, tmp_path):
    import asyncio

    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    def _boom(responses, settings):
        raise RuntimeError("threadpool body exploded")

    monkeypatch.setattr(wh, "_send_voice_notes", _boom)
    # Must complete without raising — the guard logs and swallows.
    asyncio.run(
        wh._run_voice_task(
            [BotResponse(chat_id=42, text="Hi.")],
            _settings(database_path=tmp_path / "coach.db"),
        )
    )


def test_fast_path_spawns_voice_task_post_ack(monkeypatch, tmp_path):
    """End-to-end through the webhook endpoint: 200 comes back, then the
    background voice task delivers — never inline with the request."""
    import time

    from fastapi.testclient import TestClient

    from app.config import get_settings
    from app.telegram import webhook as wh
    from app.telegram.handlers import BotResponse

    monkeypatch.setenv("OFFLINE_MODE", "0")  # spawn gate requires online
    monkeypatch.setenv("TELEGRAM_ENABLED", "1")
    monkeypatch.setenv("TELEGRAM_WEBHOOK_SECRET", "top-secret-token")
    monkeypatch.setenv("TELEGRAM_OWNER_CHAT_ID", "424242")
    monkeypatch.setenv("TTS_BASE_URL", TTS_BASE)
    monkeypatch.setenv("DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("DATABASE_PATH", str(tmp_path / "data" / "coach.db"))
    monkeypatch.setenv("CHROMA_DIR", str(tmp_path / "data" / "chroma"))
    get_settings.cache_clear()

    monkeypatch.setattr(
        wh, "_process_and_send",
        lambda update, settings: (1, [BotResponse(chat_id=424242, text="Hi.")]),
    )
    voiced: list[str] = []
    monkeypatch.setattr(
        wh, "_send_voice_notes",
        lambda responses, settings: voiced.append(responses[0].text) or 1,
    )

    from app.main import build_app

    try:
        with TestClient(build_app()) as c:
            resp = c.post(
                "/telegram/webhook",
                json={"update_id": 777, "message": {"chat": {"id": 424242}, "text": "hi"}},
                headers={"X-Telegram-Bot-Api-Secret-Token": "top-secret-token"},
            )
            assert resp.status_code == 200
            assert resp.json() == {"ok": True, "sent": 1}
            # Voice went out via the tracked background task, post-ack.
            deadline = time.monotonic() + 5.0
            while wh._background_tasks and time.monotonic() < deadline:
                time.sleep(0.01)
            assert voiced == ["Hi."]
    finally:
        get_settings.cache_clear()
