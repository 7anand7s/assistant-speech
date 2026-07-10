# Neural TTS + Ollama Endpoint

A local TTS API with two engines, wired to the **Ollama** instance running on
the Unraid host:

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

## Run

```bash
./start.sh
```

Server listens on `0.0.0.0:8880`. Defaults (override via env vars before running):

| Variable | Default | Meaning |
|---|---|---|
| `TTS_PORT` | `8880` | Listen port |
| `TTS_ENGINE` | `kokoro` | Default engine: `kokoro` or `edge` |
| `KOKORO_VOICE` | `af_heart` | Default Kokoro voice |
| `TTS_VOICE` | `en-US-AriaNeural` | Default edge/Windows voice (used directly, or as fallback) |
| `ONNX_PROVIDER` | `CPUExecutionProvider` | Forces Kokoro to run on CPU only |
| `OLLAMA_URL` | `http://172.18.0.1:11434` | Ollama on the Unraid host (docker gateway) |
| `OLLAMA_MODEL` | `llama3.2:3b` | Default chat model |
| `NORM_ENABLED` | `1` | Set to `0` to disable the normalization pipeline globally |
| `NORM_LLM_PRIMARY` | `qwen2.5:1.5b` | Primary normalization fallback model (CPU, always resident) |
| `NORM_LLM_SECONDARY` | `gemma3:1b` | Tried if the primary fails/is unreachable |
| `NORM_LLM_KEEP_ALIVE` | `-1` | Ollama keep_alive for both models; `-1` = never unload |

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
already-clean text and shave off the regex pass).

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

Open WebUI setup: **Admin → Settings → Audio → TTS** → engine `OpenAI`,
API base `http://<this-host>:8880/v1`, any API key.

### `POST /chat/speak` — ask Ollama, hear the answer

Sends your prompt to Ollama, speaks the reply with the default (or requested) engine.

```bash
# returns mp3 directly
curl -X POST http://localhost:8880/chat/speak \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Tell me a one-line joke","model":"qwen3:8b","voice":"am_michael"}' \
  -o reply.mp3

# or JSON with the text reply + base64 audio + which engine was used
curl -X POST "http://localhost:8880/chat/speak?json=1" -H "Content-Type: application/json" \
  -d '{"prompt":"Tell me a one-line joke"}'
```

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
# -> {"raw": "...", "stage1_cleaned": "...", "flagged": true, "final": "...", "model_used": "gemma3:1b"}
```

### `GET /health` — liveness, which engines/models are up, current config

## Notes

- Kokoro model files (`models/kokoro-v1.0.onnx`, ~311MB, and
  `models/voices-v1.0.bin`, ~27MB) are downloaded from the
  [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases)
  and are **not** committed — re-download them if the `models/` folder is missing.
- `edge-tts` uses Microsoft's online neural TTS service, so it needs internet;
  Kokoro needs none. The LLM side (Ollama) is always local either way.
- If Kokoro fails to load (missing model files, etc.) or errors on a specific
  request, requests transparently fall back to the edge/Windows voice — check
  `X-TTS-Engine: edge-fallback` on the response, or `GET /health` →
  `kokoro_available` / `kokoro_error`.
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
