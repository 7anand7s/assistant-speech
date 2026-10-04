# Assistant conversational speech reference bundle

This directory preserves the enriched speech layer currently used by the
household **Assistant** app alongside the low-level STT/TTS service in this
repository. It is a reproducibility and integration bundle, not part of the
port-8880 runtime.

## Isolation guarantee

Nothing in this directory is imported by `app.py`, `stt.py`, `engines.py`, or
`streaming.py`. The production Dockerfile copies only top-level `*.py` files,
so `extras/` is not present in the service image. Adding this bundle therefore
does not change the deployed API, models, latency, residency, or Assistant.

## Provenance

- Source repository: `https://github.com/7anand7s/personel-coach.git`
- Source checkout: `<source-checkout>`
- Source commit: `de8eadaf0c93ea17e0f1106d9aca45ca0a269e11`
- Product: Assistant native app `0.43.2+87`
- Snapshot manifest: [`SOURCE_MANIFEST.json`](SOURCE_MANIFEST.json)

Every full-file snapshot is byte-for-byte identical to its source at capture
time; the two `.inc` files are byte-for-byte excerpts whose source line ranges
are recorded in the manifest. The manifest pins every bundled path and SHA-256
so later syncs cannot silently rewrite the historical contract.

## What the complete speech system consists of

| Layer | Owner | Preserved here |
|---|---|---|
| Kokoro CPU TTS and sentence MP3 streaming | This repository | Top-level runtime |
| Parakeet CPU batch/final STT | This repository | Top-level runtime |
| CPU-resident text normalization fallback | This repository | Top-level runtime |
| Authenticated final-transcript boundary | Assistant backend | Backend snapshots + OpenAPI |
| TTS proxy and safe speech projection | Assistant backend/client | Backend and Flutter snapshots |
| Forced/estimated word alignment | Assistant backend | `snapshots/backend/speech_alignment.py` |
| Short opening phrase and one-ahead prefetch | Assistant Flutter | `speech_clip.dart`, `assistant_speech_queue.dart` |
| One attributed queue across all agents | Assistant Flutter | `assistant_speech_queue.dart` |
| Highlighting, pause/resume/stop | Assistant Flutter | Flutter snapshots |
| Hands-free silence detection and barge-in | Assistant Flutter | `conversation_controller.dart`, `voice_mode_screen.dart` |
| Teaching narration/audio event handling | Assistant Flutter | `teaching_screen.dart` + event contract |

## Behavioral contract

1. **Dictation is transcription-only.** The API returns one final transcript.
   It never submits an agent turn. The mobile composer remains editable and the
   user explicitly taps Send.
2. **Hands-free uses the same final STT boundary.** The app separately submits
   the transcript to the selected producer and binds cancellation to that run.
3. **Canonical chat text is never rewritten by speech.** Markdown, citations,
   URLs and code are removed only from the speakable projection.
4. **Automatic speech favors time-to-first-audio.** The opening phrase is at
   most 96 characters; later chunks are at most 260. Exactly one next chunk is
   synthesized while the current chunk plays.
5. **Manual replay favors exactness.** It uses CPU faster-whisper forced word
   alignment when available. Automatic/hands-free playback uses deterministic
   estimated timings so first audio does not wait for post-hoc alignment.
6. **Speech is globally serialized and attributed.** Concurrent agent replies
   cannot talk over one another. Cancelling one agent leaves other agents'
   queued speech intact.
7. **Barge-in is device-side.** Recording requests echo cancellation, noise
   suppression and automatic gain. Each listen calibrates its noise floor,
   requires sustained speech before interruption, stops only the matching
   playback/generation, then transcribes the completed interruption.
8. **Speech is fail-soft.** Canonical text remains usable when recording,
   synthesis, alignment, or playback fails.

## Current limitations, preserved honestly

- STT is final-utterance transcription. The previously experimented
  `/stt/stream` VAD WebSocket was reverted and is not claimed here.
- Kokoro is non-autoregressive. The current app achieves low perceived latency
  with phrase requests and one-ahead prefetch; it is not token-to-waveform TTS.
- There is no always-listening wake word or background microphone lifecycle.
- Authentication and per-user authorization belong to the embedding app. The
  port-8880 service remains private-LAN/tailnet infrastructure.
- The snapshot Flutter files depend on the surrounding Assistant application;
  they are reference sources, not a second independently buildable mobile app.

## Reproducing the integration

1. Deploy this repository's normal service and verify `/health`, `/stt`, and
   `/tts` over the private network.
2. Put the service behind an authenticated application boundary.
3. Implement the two endpoints frozen in
   [`contracts/assistant-speech-v1.openapi.json`](contracts/assistant-speech-v1.openapi.json):
   a bounded transcription-only upload and aligned TTS response.
4. Use `speech_clip.dart` and `assistant_speech_queue.dart` for safe chunking,
   global serialization, attribution and word progress.
5. Use the conversation/voice snapshots for microphone lifecycle, adaptive
   silence detection, pause/resume/stop and barge-in.
6. For a producer that supplies audio itself, consume only the event shapes in
   [`contracts/teaching-speech-events-v1.json`](contracts/teaching-speech-events-v1.json).
7. Run the copied Python and Flutter contract tests inside an application with
   the dependencies listed in [`REFERENCE_DEPENDENCIES.md`](REFERENCE_DEPENDENCIES.md).

## Validation

Run the repository-local, dependency-free integrity check:

```bash
python3 extras/assistant_conversation/verify_bundle.py
```

It verifies the frozen source hashes and JSON contracts without importing or
starting the TTS service, loading a model, or touching a GPU.
