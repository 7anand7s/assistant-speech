class SpeakAnyRequest(BaseModel):
    """Body for ``POST /api/speak-message`` — read this text aloud, now."""

    text: str = Field(min_length=1, max_length=8000)
    # Automatic and hands-free playback use the low-latency path. Explicit
    # speaker-button playback defaults to exact forced word alignment.
    realtime: bool = False


@router.post("/speak-message")
async def speak_message(
    body: SpeakAnyRequest, user: TokenPayload = Depends(require_app_user)
) -> dict:
    """Read one message aloud on demand, whichever agent said it.

    Deliberately does NOT consult ``tts_replies_enabled``. That preference
    governs speaking replies AUTOMATICALLY; this route only ever runs because
    somebody tapped the speaker on a specific message, and refusing that
    because a background toggle is off would read as a broken button.

    The text is supplied by the client rather than looked up by message id: it
    is already on that user's screen, so this adds no read path to anything
    they could not already see, and it works identically for all four agents
    without four id spaces to resolve.
    """
    settings = get_settings()

    def _speak() -> dict:
        # Belt-and-braces: the client sends what is on screen, which is already
        # reasoning-free — but if a think block ever reaches this endpoint it
        # must not be read aloud.
        clean, _ = split_thinking(body.text)
        from app.services.speech_alignment import synthesize_aligned_speech

        result = synthesize_aligned_speech(
            clean or body.text,
            settings=settings,
            synthesizer=synthesize_speech,
            prefer_estimated=body.realtime,
        )
        audio = result["audio"]
        if not audio:
            return {
                "ok": False,
                "audio": "",
                "audio_mime": "",
                "words": [],
                "alignment": "unavailable",
            }
        return {
            "ok": True,
            "audio": base64.b64encode(audio).decode("ascii"),
            "audio_mime": "audio/mpeg",
            "words": result["words"],
            "alignment": result["alignment"],
            "realtime": body.realtime,
        }

    return await run_in_threadpool(_speak)

# --- transcription boundary ---

# Voice path mirrors the Mini App's meals/voice + the webhook's voice handling:
# the SAME friendly, never-crash degradation messages, so a native memo and a
# Telegram memo degrade identically rather than the native one 500-ing.
_VOICE_FAIL_MSG = "I couldn't transcribe that voice note — mind typing it instead?"
_VOICE_EMPTY_MSG = "I couldn't make out any words in that voice note."
_MAX_SPEECH_UPLOAD_BYTES = 25 * 1024 * 1024


def _transcribe_speech_input(data: bytes, settings: Settings, mode: str) -> dict:
    """Assistant-owned, transcription-only speech boundary.

    This function deliberately has no thread, run or agent dependency. Editable
    dictation must never submit a Coach turn as a side effect; hands-free mode
    submits separately through the authenticated durable run contract after the
    final transcript reaches the client.
    """
    try:
        transcript = (transcribe_audio(data, settings=settings) or "").strip()
    except TranscriptionError:
        logger.exception("Assistant speech transcription failed")
        return {
            "ok": False,
            "schema_version": 1,
            "transcript": "",
            "error": {"code": "transcription_unavailable"},
            "provenance": {"owner": "assistant", "mode": mode},
        }
    if not transcript:
        return {
            "ok": False,
            "schema_version": 1,
            "transcript": "",
            "error": {"code": "empty_transcript"},
            "provenance": {"owner": "assistant", "mode": mode},
        }
    return {
        "ok": True,
        "schema_version": 1,
        "transcription_id": f"stt_{uuid.uuid4().hex}",
        "transcript": transcript,
        "provenance": {
            "owner": "assistant",
            "mode": mode,
            "audio_retained": False,
        },
    }


@router.post("/speech/transcriptions")
async def speech_transcription(
    audio: UploadFile = File(...),
    mode: Literal["dictation", "hands_free"] = Form(default="dictation"),
    user: TokenPayload = Depends(require_app_user),
) -> dict:
    """Return final Assistant STT text without running any agent.

    The authenticated user is intentionally consumed only by the authorization
    boundary. No transcript or audio is durably stored here; framework request
    buffering is discarded with the upload. No private Coach persistence is
    read. Coach receives only the final text plus the explicit ``origin`` on
    its later run submission.
    """
    del user
    data = await audio.read(_MAX_SPEECH_UPLOAD_BYTES + 1)
    if not data:
        raise HTTPException(status_code=400, detail="empty audio upload")
    if len(data) > _MAX_SPEECH_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="audio upload exceeds 25 MiB")
    return await run_in_threadpool(_transcribe_speech_input, data, get_settings(), mode)
