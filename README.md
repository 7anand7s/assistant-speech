# Self-hosted Neural Speech (TTS + STT)

A local speech service. **Text-to-speech**: Kokoro runs the audio, Windows
neural voices are the fallback, and a tiny LLM cleans up messy text before it's
spoken. **Speech-to-text**: Parakeet TDT 0.6B v2 transcribes uploaded audio back
to text. Both run on CPU, fully offline.

## Everything runs on CPU

Verified, not assumed — running the STT engine added **0 MiB** of GPU use
(measured identical `nvidia-smi` memory before/after, and the service's PID
never appears in the GPU compute list) while all models are loaded and serving.

- **Kokoro** (TTS) and **Parakeet** (STT) *cannot* reach the GPU: Kokoro is
  pinned via `ONNX_PROVIDER=CPUExecutionProvider`, Parakeet runs through
  sherpa-onnx which defaults to CPU, and neither installed build ships a CUDA
  provider at all.
- **Both LLM roles** run inside Ollama, which *will* put a model on the GPU
  unless told otherwise. Every Ollama call therefore sends `num_gpu: 0`, built
  by the single `config.ollama_options()` helper so a new call site can't
  silently forget it. Confirm with `curl $OLLAMA_URL/api/ps` → `size_vram: 0`
  for every model.

Set `OLLAMA_FORCE_CPU=0` to allow the LLM roles onto the GPU. Kokoro stays on
CPU regardless (there's no CUDA provider to switch to).

### Does this affect other things using the same Ollama host?

**Different models: no, fully isolated.** Verified — while this service's
models sit on CPU, another app loading e.g. `mistral:7b` gets the GPU as
normal.

**The same model: yes.** `num_gpu` is a *load-time* parameter, and Ollama keeps
only **one instance** per model. If another app is using the same model this
service is configured with, our `num_gpu: 0` call **evicts its GPU instance and
reloads it on CPU**. Worse, a subsequent normal call from that app does *not*
move it back — Ollama reuses the resident CPU instance.

To get it back on the GPU, the CPU instance has to **unload first**:

```bash
curl $OLLAMA_URL/api/generate -d '{"model":"llama3.2:3b","keep_alive":0}'   # force unload
# next normal call from any app now loads it on the GPU again
```

This is why `CHAT_KEEP_ALIVE` defaults to `5m` rather than `-1` — the demo chat
model drops out of memory on its own after 5 minutes idle, so it stops
squatting on a shared model in CPU mode. The two normalization models *are*
pinned (`keep_alive: -1`), but `qwen2.5:1.5b` / `gemma3:1b` are unlikely to be
shared with anything else.

If you do share `CHAT_MODEL` with other workloads and don't want this, either
set `OLLAMA_FORCE_CPU=0`, or point `CHAT_MODEL` at a model nothing else uses.

## Four independent roles — don't confuse them

There are up to four models in play, doing **completely different jobs**.
They are unrelated: changing one doesn't affect the others. `/health` reports
each separately.

| # | Role | Where | Default model | Job |
|---|---|---|---|---|
| 1 | **TTS engine** — *core* | `engines.py` | Kokoro (ONNX) | Turns text into audio. **No LLM involved.** |
| 2 | **Normalization LLM** — *support* | `normalize.py` | `qwen2.5:1.5b` → `gemma3:1b` | **Rewords** existing text so it reads cleanly aloud. Never generates content. |
| 3 | **Chat LLM** — *demo only* | `chat.py` | `llama3.2:3b` | **Writes new text** from a prompt, purely so `/chat/speak` has something to speak. **Not part of the pipeline.** |
| 4 | **STT engine** — *core* | `stt.py` | Parakeet TDT 0.6B v2 (ONNX) | Turns audio into text — the reverse of role 1. **No LLM involved.** |

Roles 2 and 3 both talk to Ollama, but that's just shared transport — different
models, opposite jobs. Roles 1 and 4 are the core product (text↔audio) and need
neither. **If you already have text to speak, you only need role 1; to
transcribe, only role 4.**

Proof they're separate: `CHAT_ENABLED=0 ./start.sh` → `llama3.2:3b` never loads
and `/chat/speak` 404s; `STT_ENABLED=0 ./start.sh` → Parakeet never loads and
`/stt` 404s; either way every other endpoint works exactly as before.

## Role 1 — the TTS engine (core)

- **Kokoro** (default) — a local, open-weight neural TTS model (`kokoro-onnx`).
  Runs fully offline, **CPU-only** (forced via `ONNX_PROVIDER=CPUExecutionProvider`
  — the installed `onnxruntime` build has no CUDA provider anyway, so it
  physically cannot touch the GPU). No internet required.
- **Edge / Windows voices** — Microsoft's cloud neural voices (Aria, Jenny,
  Guy, Andrew, etc., via `edge-tts`), the same voices as Windows 11's
  "natural" voices. Requires internet. Used as **automatic fallback** if
  Kokoro fails to load or errors on a request.

Every response includes an `X-TTS-Engine` header telling you which engine
actually produced the audio (`kokoro`, `edge`, or `edge-fallback`).

## Role 2 — the normalization pipeline

Before synthesis, text passes through a **normalization pipeline**
(`normalize.py`) built on one rule: **reframe for speech, never delete
information.** A link still points somewhere real — the goal is to make it
speakable, not erase it.

- **Stage 1 (regex, microseconds):** strips pure styling (markdown emphasis,
  emoji, code-fence bodies) and rewrites URLs/markdown links into a speakable
  `"label (linked to example.com)"` form — the domain is kept, not deleted.
  Each link mention is swapped for an opaque `LINK0`/`LINK1`/... placeholder
  before anything downstream can touch it.
- **Stage 2 (whitelist check):** flags anything still unsafe to speak —
  leftover symbols, long digit runs (phone numbers/IDs), table-like
  low-word-density text.
- **Stage 3 (LLM, only for flagged text):** `qwen2.5:1.5b` first, `gemma3:1b`
  second, both **CPU-only** (`num_gpu: 0`) and kept resident indefinitely
  (`keep_alive: -1`, warmed at startup — no cold-start on the first flagged
  request). The LLM only ever sees placeholder tokens where links were, never
  the real domain text — so it's structurally unable to corrupt a link. Its
  output is verified to contain every placeholder from the input, verbatim;
  if a model drops or mangles one (tiny models do this), that output is
  discarded and the next model is tried. If every candidate fails
  verification, the Stage-1 text is used as-is — phrasing may be less
  natural, but information is never lost to a hallucination.

Normal clean text skips the LLM stage entirely. Flagged cases are logged to
`flagged_log.jsonl` for review — recurring patterns should get folded into
the Stage 1 regex cleaner.

### Is normalization on by default? Yes — at every layer

| Layer | Default | How to turn off |
|---|---|---|
| Service-wide | on (`NORM_ENABLED=1`) | `NORM_ENABLED=0` — disables the whole pipeline |
| Per request | on (`"normalize": true`) | `"normalize": false` on `/tts` and `/chat/speak` |
| Stage 3 LLM | **only on flagged text** | n/a — clean text never reaches it |

"Normalization enabled" does **not** mean an LLM call per request. Clean text
only pays the microsecond regex pass; the LLM fires only for the small
fraction Stage 2 flags. Check `X-Text-Normalized` on the response to see
whether it fired.

Note: `/v1/audio/speech` has **no** `normalize` field — it always normalizes,
and can only be turned off globally via `NORM_ENABLED=0`. This keeps the
endpoint's schema strictly OpenAI-compatible.

## Role 3 — the chat LLM (demo only, optional)

`llama3.2:3b` exists **only** to write text for the `/chat/speak` demo, so you
can hear the TTS engine without supplying your own text. It is not part of the
TTS pipeline and not part of normalization. Turn it off with `CHAT_ENABLED=0`
and nothing else changes.

## Role 4 — the STT engine (core)

The reverse of role 1: upload audio, get text back. **Parakeet TDT 0.6B v2**
(English, int8 ONNX, ~660MB) runs on CPU via sherpa-onnx — it currently tops the
Hugging Face Open ASR leaderboard among sub-1B models, and its token-and-duration
transducer decoder is genuinely fast on CPU (measured **RTF ≈ 0.05–0.30** here,
i.e. 3–20× faster than real-time). No LLM involved. Any input audio
format/samplerate works — ffmpeg decodes it to the 16 kHz mono the model wants.
English only; disable with `STT_ENABLED=0`.

## Run

```bash
./start.sh                      # everything
CHAT_ENABLED=0 ./start.sh       # TTS only — no demo chat endpoint, no chat model loaded
CHAT_MODEL="qwen3:8b" ./start.sh  # swap the demo's writer model
```

Server listens on `0.0.0.0:8880`. Config is grouped by role (see `config.py`):

**Shared**

| Variable | Default | Meaning |
|---|---|---|
| `TTS_PORT` | `8880` | Listen port |
| `OLLAMA_URL` | `http://172.18.0.1:11434` | Ollama host (docker gateway). Used by roles 2 and 3 only. |
| `OLLAMA_FORCE_CPU` | `1` | Sends `num_gpu: 0` on every Ollama call. `0` allows the GPU. Note: pins *shared* models to CPU for other apps too — see above. |

**Role 1 — TTS engine (no LLM)**

| Variable | Default | Meaning |
|---|---|---|
| `TTS_ENGINE` | `kokoro` | Default engine: `kokoro` or `edge` |
| `KOKORO_VOICE` | `af_heart` | Default Kokoro voice |
| `TTS_VOICE` | `en-US-AriaNeural` | Default edge/Windows voice (used directly, or as fallback) |
| `ONNX_PROVIDER` | `CPUExecutionProvider` | Forces Kokoro to run on CPU only |
| `TTS_STREAM_DEFAULT` | `0` | `1` = stream by default on `/tts` and `/chat/speak`; per-request `stream` always wins |

**Role 2 — normalization LLM (rewords, never generates)**

| Variable | Default | Meaning |
|---|---|---|
| `NORM_ENABLED` | `1` | Set to `0` to disable the normalization pipeline globally |
| `NORM_LLM_PRIMARY` | `qwen2.5:1.5b` | Primary normalization model (CPU, always resident) |
| `NORM_LLM_SECONDARY` | `gemma3:1b` | Tried if the primary fails/is unreachable |
| `NORM_LLM_KEEP_ALIVE` | `-1` | Ollama keep_alive for both models; `-1` = never unload |

**Role 3 — chat LLM (demo only)**

| Variable | Default | Meaning |
|---|---|---|
| `CHAT_ENABLED` | `1` | `0` unmounts `/chat/speak` entirely; no chat model is loaded |
| `CHAT_MODEL` | `llama3.2:3b` | The demo's text *writer*. Nothing to do with TTS or normalization. |
| `CHAT_NUM_CTX` | `4096` | Chat writes prose, so it needs more context than the normalizer's 1024 |
| `CHAT_KEEP_ALIVE` | `5m` | Demo model; not pinned resident forever the way the normalizers are |

> `OLLAMA_MODEL` is still accepted as a legacy alias for `CHAT_MODEL` (it
> shipped in the first release), but the name was misleading — it only ever
> set the chat model. Prefer `CHAT_MODEL`.

**Role 4 — STT engine (no LLM)**

| Variable | Default | Meaning |
|---|---|---|
| `STT_ENABLED` | `1` | `0` unmounts `/stt` and `/v1/audio/transcriptions`; Parakeet never loads |
| `STT_MODEL_DIR` | `models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | Path to the extracted Parakeet model dir |
| `STT_NUM_THREADS` | `4` | CPU threads for transcription |

## Endpoints

### `POST /tts` — plain text to speech

```bash
# default engine (kokoro)
curl -X POST http://localhost:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello there!","voice":"af_bella","speed":1.1}' \
  -o speech.mp3

# force the Windows/edge voice explicitly
curl -X POST http://localhost:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text":"Hello there!","engine":"edge","voice":"en-US-JennyNeural","rate":"+10%"}' \
  -o speech.mp3
```

Fields: `text`, `engine` (`kokoro`|`edge`, default `kokoro`), `voice`,
`speed` (kokoro), `rate`/`pitch` (edge, e.g. `"+10%"` / `"-5Hz"`), `normalize`
(bool, default `true` — set `false` to skip the cleanup pipeline for
already-clean text and shave off the regex pass), `stream` (bool; omit to use
the server's `TTS_STREAM_DEFAULT` — see [Streaming](#streaming) below).

Response headers: `X-TTS-Engine`, `X-Text-Normalized` (`true` if the LLM
fallback stage fired), `X-Normalize-Model` (which model handled it, if any).

### `POST /v1/audio/speech` — OpenAI-compatible

Drop-in TTS backend for **Open WebUI** or anything that speaks the OpenAI audio
API. OpenAI voice names (`alloy`, `nova`, `onyx`, ...) map to a Kokoro voice by
default; you can also pass a native voice name directly (e.g. `af_heart` or
`en-US-GuyNeural`).

```bash
curl -X POST http://localhost:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model":"tts-1","input":"Hello!","voice":"nova","speed":1.1}' \
  -o speech.mp3
```

Fields are the strict OpenAI set — `model` (accepted, ignored), `input`,
`voice`, `response_format` (mp3 only), `speed`. There is deliberately **no
`normalize` or `stream` field** here; normalization always runs (disable
globally with `NORM_ENABLED=0`), and audio is returned as one complete MP3.
Use `/tts` if you want per-request control over either.

Open WebUI setup: **Admin → Settings → Audio → TTS** → engine `OpenAI`,
API base `http://<this-host>:8880/v1`, any API key.

### `POST /chat/speak` — **demo only** (role 3)

Asks the *chat* LLM (`CHAT_MODEL`) to **write** a reply to your prompt, then
speaks it. This is a convenience demo, not the TTS product — if you already
have text, use `/tts`. Only mounted when `CHAT_ENABLED=1`.

`"model"` here overrides the **chat** model, not the TTS engine or the
normalization model.

```bash
# returns mp3 directly
curl -X POST http://localhost:8880/chat/speak \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Tell me a one-line joke","model":"qwen3:8b","voice":"am_michael"}' \
  -o reply.mp3

# or JSON — note the three roles are reported separately
curl -X POST "http://localhost:8880/chat/speak?json=1" -H "Content-Type: application/json" \
  -d '{"prompt":"Tell me a one-line joke"}'
# -> {"reply": "...", "chat_model": "llama3.2:3b",   <- role 3 wrote it
#     "engine": "kokoro",                            <- role 1 spoke it
#     "normalize_model": null, ...}                  <- role 2 wasn't needed
```

Response header is `X-Chat-Model` (was `X-Ollama-Model` before v3 — renamed
because "Ollama model" was ambiguous between roles 2 and 3).

## Streaming

Controlled per request, with a server-wide default:

| `"stream"` in request | Result |
|---|---|
| `true` | stream, regardless of server default |
| `false` | don't stream, regardless of server default |
| omitted / `null` | use `TTS_STREAM_DEFAULT` (default `0` = off) |

So `TTS_STREAM_DEFAULT=1 ./start.sh` makes streaming the default for `/tts`
and `/chat/speak`, and any request can still opt out with `"stream": false`.
`/v1/audio/speech` ignores all of this and never streams — it stays strictly
OpenAI-shaped.

Pass `"stream": true` to `/tts` or `/chat/speak` to get audio as it's
produced instead of waiting for the whole thing (see `streaming.py`).

```bash
# audio starts arriving before the LLM has finished writing its reply
curl -N -X POST http://localhost:8880/chat/speak \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Write three sentences about the ocean.","stream":true}' \
  -o reply.mp3
```

For `/chat/speak`, this streams **both** stages: Ollama tokens are consumed
as they're generated, buffered into complete sentences, and each sentence is
normalized → synthesized → streamed out immediately while the LLM is still
writing later ones. Measured on this box (llama3.2:3b, three sentences):

| | first audio byte | total |
|---|---|---|
| `stream: true` | **5.2s** | 9.3s |
| `stream: false` | 13.3s | 13.3s |

Notes and limits:

- Kokoro is not autoregressive — it needs a full sentence per synthesis pass,
  so **sentence** is the streaming granularity, not token. (This is what
  production streaming-TTS APIs do for non-autoregressive vocoders too.)
- Kokoro's per-sentence audio is piped through a **single long-lived ffmpeg
  process**, so the result is one continuous, gapless MP3 rather than
  concatenated files with duplicate headers — verified to decode with zero
  frame errors at the sentence joins. `edge` streams Microsoft's own MP3
  chunks straight through, no re-encoding.
- `stream: true` returns audio only — it ignores `?json=1`, and omits the
  `X-Text-Normalized` / `X-Normalize-Model` headers, since those aren't
  known until after the stream is done.
- The engine is resolved **once, upfront** for a stream (a streaming response
  can't swap encoders mid-flight). If Kokoro is unavailable the whole stream
  uses edge, reported as `X-TTS-Engine: edge-fallback`.

### `GET /voices?engine=kokoro|edge` — list voices

```bash
curl "http://localhost:8880/voices?engine=kokoro&lang=en-us"
curl "http://localhost:8880/voices?engine=edge&lang=en-US"
```

Kokoro voice codes are `<lang><gender>_<name>`, e.g. `af_heart` = American
Female "Heart", `bm_george` = British Male "George". 54 voices span English
(US/UK), Japanese, Mandarin, Spanish, French, Hindi, Italian, and Portuguese.

### `POST /normalize` — inspect the cleanup pipeline directly

Debug endpoint: runs the same normalization pipeline as `/tts` but returns
JSON instead of doing TTS. Useful for iterating on the regex cleaner or
checking what the LLM fallback does with a given input.

```bash
curl -X POST http://localhost:8880/normalize -H "Content-Type: application/json" \
  -d '{"text":"**Important**: your order #4829103 ships tomorrow 📦 see [details](https://example.com/track)"}'
# -> {"raw": "...", "stage1_cleaned": "...", "flagged": true, "final": "...", "model_used": "qwen2.5:1.5b"}
```

### `POST /stt` — transcribe audio to text (role 4)

Upload an audio file (any format — wav, mp3, m4a, ogg, flac…), get English text
back. Only mounted when `STT_ENABLED=1`.

```bash
curl -X POST http://localhost:8880/stt -F "file=@recording.mp3"
# -> {"text": "...", "duration_seconds": 11.0, "language": "en", "model": "parakeet-tdt-0.6b-v2"}
```

### `POST /v1/audio/transcriptions` — OpenAI-compatible STT

Drop-in for clients that speak the OpenAI transcription API (multipart form,
not JSON). `model` is accepted and ignored; `response_format` is `json`
(default) or `text`.

```bash
curl -X POST http://localhost:8880/v1/audio/transcriptions \
  -F "file=@recording.wav" -F "model=whisper-1"
# -> {"text": "..."}
```

### `GET /health` — liveness + status of each role, reported separately

Returns `tts_engine`, `normalization_llm`, `chat_llm` and `stt_engine` as
distinct objects, each with a plain-English `role` description, so it's always
obvious which model is doing what.

## Repo layout

The file structure mirrors the four roles:

```
config.py      all config, grouped by role, with each role's job documented
engines.py     ROLE 1  TTS engines (Kokoro + edge-tts). No LLM anywhere in it.
normalize.py   ROLE 2  normalization LLM — rewords text, never generates
chat.py        ROLE 3  chat LLM demo — /chat/speak router; not mounted if CHAT_ENABLED=0
stt.py         ROLE 4  STT engine (Parakeet) — /stt + /v1/audio/transcriptions; not mounted if STT_ENABLED=0
streaming.py   shared  sentence chunking + gapless streaming MP3 encoder
app.py         FastAPI app: /tts, /v1/audio/speech, /voices, /health, /normalize
```

## Notes

- Model weights live in `models/` and are **not** committed (too large for git).
  Re-download if the folder is missing:
  - **Kokoro (TTS):** `models/kokoro-v1.0.onnx` (~311MB) + `models/voices-v1.0.bin`
    (~27MB) from the [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases).
  - **Parakeet (STT):** `sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2`
    (~482MB) from the [sherpa-onnx asr-models release](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models),
    extracted into `models/`.
- `edge-tts` uses Microsoft's online neural TTS service, so it needs internet;
  Kokoro needs none. The LLM side (Ollama) is always local either way.
- Ollama defaults to the GPU. Until `OLLAMA_FORCE_CPU` existed, the chat model
  silently ran there (2.5GB VRAM) while Kokoro and the normalizers were on CPU
  — `num_gpu: 0` was only being sent on the normalization calls. All Ollama
  calls now go through `config.ollama_options()`, which always sets it.
- If Kokoro fails to load (missing model files, etc.) or errors on a specific
  request, requests transparently fall back to the edge/Windows voice — check
  `X-TTS-Engine: edge-fallback` on the response, or `GET /health` →
  `tts_engine.kokoro_available` / `tts_engine.kokoro_error`.
- `gemma3:270m` was tested first for the normalization fallback and rejected —
  it refused a benign request, ignored its system prompt on another, and
  returned empty on a third. `gemma3:1b` and `qwen2.5:1.5b` both perform
  reliably; `qwen2.5:1.5b` is primary, `gemma3:1b` is the secondary.
- Digit-sequence formatting (e.g. spelling out a phone number) is
  best-effort by the LLM stage and sometimes a no-op — that's a phrasing
  quality gap, not an info-loss bug, and the kind of thing to tune via
  `flagged_log.jsonl` over time. Link preservation, by contrast, is
  structurally guaranteed (placeholder + verification), not best-effort.
- Setup was done with [uv](https://docs.astral.sh/uv/): `uv venv .venv && uv pip install -p .venv/bin/python -r requirements.txt`.
