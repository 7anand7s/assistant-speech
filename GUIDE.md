# Self-Hosted Speech Endpoint — Connection Guide

**Service:** `kokoro-tts` container on Unraid (`your-server`) · **Port:** `8880` · **Auth:** none (private network only)

Does two things: **TTS** (text → speech) and **STT** (speech → text). Both local, both on CPU.

## 1. Addresses — which URL to use from where

| You are… | Base URL |
|---|---|
| On home WiFi (any device) | `http://<server-ip>:8880` |
| Anywhere else, device on your Tailscale tailnet | `http://<tailscale-ip>:8880` |
| Same, with MagicDNS | `http://<your-machine>.<tailnet>.ts.net:8880` |

- **Phones/laptops away from home:** install the Tailscale app, log into your tailnet, then use the `<tailscale-ip>` URL. Works on cellular.
- The endpoint is deliberately **not** on the public internet and has **no API key**. Don't add it to Tailscale Funnel.
- It's plain `http`, not `https` — some clients warn about this; that's expected on a LAN/tailnet service.

Quick reachability test from any machine:

```bash
curl http://<server-ip>:8880/health
```

Healthy response starts with `{"status":"ok", ...}`.

## 2. The endpoints

### `POST /tts` — main endpoint, full control

Send JSON, get an MP3 back.

```bash
curl -X POST http://<server-ip>:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello there!", "voice": "af_bella", "speed": 1.1}' \
  -o speech.mp3
```

All fields (only `text` is required):

| Field | Type | Default | Meaning |
|---|---|---|---|
| `text` | string | — | What to say |
| `engine` | `"kokoro"` / `"edge"` | `kokoro` | Kokoro = local/offline. Edge = Microsoft cloud voices (needs internet) |
| `voice` | string | `af_heart` (kokoro) / `en-US-AriaNeural` (edge) | See §4 |
| `speed` | number | `1.0` | Kokoro only, e.g. `1.2` |
| `rate` | string | — | Edge only, e.g. `"+10%"` |
| `pitch` | string | — | Edge only, e.g. `"-5Hz"` |
| `normalize` | bool | `true` | `false` skips the text-cleanup pipeline (see §5) |
| `stream` | bool | server default (off) | See §3 |

### `POST /v1/audio/speech` — OpenAI-compatible

Drop-in for anything that speaks the OpenAI TTS API (Open WebUI, many apps, iPhone Shortcuts).

```bash
curl -X POST http://<server-ip>:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1", "input": "Hello!", "voice": "nova", "speed": 1.1}' \
  -o speech.mp3
```

- Fields: `model` (accepted, ignored), `input`, `voice`, `speed`. `response_format` is mp3 only.
- OpenAI voice names (`alloy`, `nova`, `onyx`, …) map to Kokoro voices automatically; native names (`af_heart`, `en-US-GuyNeural`) also work.
- **Never streams and always normalizes** — by design, to stay strictly OpenAI-shaped. Use `/tts` if you need per-request control.

### `GET /voices` — list available voices

```bash
curl "http://<server-ip>:8880/voices?engine=kokoro&lang=en-us"
curl "http://<server-ip>:8880/voices?engine=edge&lang=en-US"
```

### `POST /stt` — speech to text (transcription)

The reverse of `/tts`: upload an audio file, get English text back. Any format works (wav, mp3, m4a, ogg, flac…) — it's transcribed by Parakeet locally on CPU, comfortably faster than real-time (a ~7-second clip transcribes in ~2–3s here).

```bash
curl -X POST http://<server-ip>:8880/stt -F "file=@recording.m4a"
# -> {"text": "...", "duration_seconds": 11.0, "language": "en", "model": "parakeet-tdt-0.6b-v2"}
```

### `POST /v1/audio/transcriptions` — OpenAI-compatible STT

Drop-in for anything that speaks the OpenAI transcription API (Whisper clients, etc.). Multipart form upload:

```bash
curl -X POST http://<server-ip>:8880/v1/audio/transcriptions \
  -F "file=@recording.wav" -F "model=whisper-1"
# -> {"text": "..."}     (add -F "response_format=text" for plain text)
```

English only. Both STT endpoints return **404** if the deployment sets `STT_ENABLED=0`.

### `GET /health` — status of every component

Reports the TTS engine, normalization LLM, and STT engine separately (`kokoro_available`, `stt_engine.available`, models loaded, etc.).

### `POST /chat/speak` — ⚠️ disabled in this deployment

The container runs with `CHAT_ENABLED=0`, so this returns **404**. It's a demo that writes text with an LLM and then speaks it — not part of the TTS pipeline. To enable it, see §8.

## 3. Streaming — enable / disable

Streaming sends audio as it's synthesized (sentence by sentence) instead of waiting for the whole MP3. Worth it for long texts; for one short sentence it makes little difference.

**Per request** (this always wins):

```bash
# stream ON — note curl's -N (no buffering)
curl -N -X POST http://<server-ip>:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "First sentence. Second sentence. Third one.", "stream": true}' \
  -o speech.mp3

# stream OFF explicitly
... -d '{"text": "...", "stream": false}' ...
```

**Server-wide default** (what happens when a request doesn't say): currently **off**. To make streaming the default, add `TTS_STREAM_DEFAULT=1` to the `environment:` list in `docker-compose.yml` and run `docker compose up -d` from this folder. Any request can still opt out with `"stream": false`.

Rules and limits:

- `/v1/audio/speech` **ignores all of this** — it never streams.
- The result is one continuous, gapless MP3 either way.
- Streamed responses omit the `X-Text-Normalized` / `X-Normalize-Model` headers (unknowable until the stream ends), and the engine is locked in upfront — if Kokoro is down, the whole stream falls back to edge.
- iPhone Shortcuts' "Get Contents of URL" waits for the complete response anyway, so streaming buys nothing there — leave it off for Shortcuts.

## 4. Voices

**Kokoro** (local, 54 voices — English US/UK, Japanese, Mandarin, Spanish, French, Hindi, Italian, Portuguese). Code format `<lang><gender>_<name>`:

- `af_heart` — American female (default) · `af_bella`, `af_nicole`, …
- `am_michael` — American male
- `bf_emma` — British female · `bm_george` — British male

**Edge** (Microsoft cloud, needs internet): `en-US-AriaNeural`, `en-US-JennyNeural`, `en-US-GuyNeural`, `en-US-AndrewNeural`, …

**OpenAI aliases** (on `/v1/audio/speech`): `alloy`, `nova`, `onyx`, `echo`, `fable`, `shimmer` map to Kokoro voices.

Full live list: `GET /voices?engine=kokoro` or `?engine=edge`.

## 5. Normalization — what it is, how to control it

Before speaking, text passes a cleanup pipeline: markdown/emoji stripped, URLs rewritten to a speakable "label (linked to example.com)" form, and — only for text flagged as still-unspeakable — a tiny local LLM rewords it. Links are structurally protected from LLM corruption. Clean text costs microseconds; the LLM only fires on flagged text.

- Per request: `"normalize": false` on `/tts`.
- `/v1/audio/speech`: always normalizes (no field, by design).
- Globally off: add `NORM_ENABLED=0` to the compose environment and `docker compose up -d`.
- Flagged texts are logged to `flagged_log.jsonl` in this folder for review.

## 6. Response headers worth reading

| Header | Meaning |
|---|---|
| `X-TTS-Engine` | Who actually spoke: `kokoro`, `edge`, or `edge-fallback` (Kokoro failed, cloud voice covered it) |
| `X-Text-Normalized` | `true` if the LLM cleanup stage fired |
| `X-Normalize-Model` | Which model did the rewording, if any |

## 7. Client recipes

Two directions here: **Text → Speech** (play audio you generate) and **Speech → Text** (send a recording, get the words back). TTS recipes first (7A), then STT (7B), then a combined voice loop (7C).

## 7A — Text → Speech

### iPhone — Shortcuts app

1. Shortcuts → **+** → add action **"Get Contents of URL"**
2. URL: `http://<server-ip>:8880/v1/audio/speech` (WiFi) or the Tailscale URL (anywhere)
3. Method **POST** · Header `Content-Type: application/json`
4. Request Body → JSON:
   - `model` = `tts-1`
   - `input` = *Shortcut Input* variable (or "Ask Each Time," or fixed text)
   - `voice` = `nova` (or any Kokoro voice)
5. Add action **"Play Sound"** fed by the URL output. (Or "Quick Look".)
6. Test by tapping it, then trigger via "Hey Siri, *[shortcut name]*", the Share Sheet (enable "Show in Share Sheet" to speak selected text from any app), or a personal automation (location/time/DND).

### Android

**HTTP Shortcuts** app (free): new shortcut → POST → same URL/body as above → response handling "Play as sound". Or **Tasker**: HTTP Request action → save response to file → Play Audio action.

### Any machine — curl

```bash
curl -X POST http://<server-ip>:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "Test from the command line."}' \
  -o out.mp3 && open out.mp3    # 'open' on macOS, 'xdg-open' on Linux
```

### Windows — PowerShell

```powershell
Invoke-RestMethod -Uri http://<server-ip>:8880/tts -Method Post `
  -ContentType "application/json" `
  -Body '{"text": "Hello from Windows."}' `
  -OutFile out.mp3
Start-Process out.mp3
```

### Python

```python
import requests

r = requests.post("http://<server-ip>:8880/tts",
                  json={"text": "Hello from Python.", "voice": "af_heart"})
open("out.mp3", "wb").write(r.content)
print(r.headers["X-TTS-Engine"])

# streaming variant — audio arrives sentence by sentence
with requests.post("http://<server-ip>:8880/tts",
                   json={"text": "Long text here...", "stream": True},
                   stream=True) as r, open("out.mp3", "wb") as f:
    for chunk in r.iter_content(8192):
        f.write(chunk)
```

Or use the OpenAI SDK directly (TTS):

```python
from openai import OpenAI
client = OpenAI(base_url="http://<server-ip>:8880/v1", api_key="anything")
client.audio.speech.create(model="tts-1", input="Hi!", voice="nova").write_to_file("out.mp3")
```

### JavaScript / Node

```javascript
const res = await fetch("http://<server-ip>:8880/tts", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ text: "Hello from Node." }),
});
require("fs").writeFileSync("out.mp3", Buffer.from(await res.arrayBuffer()));
```

### Open WebUI — TTS

Admin → Settings → Audio → **TTS**: engine **OpenAI**, API base `http://<server-ip>:8880/v1`, any API key, voice e.g. `nova`. (The **STT** half of this same page is in 7B.)

### Telegram bot — speak replies

A bot (running in `your-client-host`) POSTs message text to `/tts` and sends the MP3 back as a voice note. Shortcuts can't reliably trigger on incoming Telegram messages — that direction belongs server-side.

## 7B — Speech → Text

The pattern is the same everywhere: send the audio as a **multipart form field named `file`** — to `/stt` (native JSON) or `/v1/audio/transcriptions` (OpenAI-shaped). Any container/codec works (ffmpeg decodes it); English only.

### Any machine — curl

```bash
curl -X POST http://<server-ip>:8880/stt -F "file=@recording.m4a"
# -> {"text":"...","duration_seconds":11.0,"language":"en","model":"parakeet-tdt-0.6b-v2"}
```

### iPhone — Shortcuts app (dictate / transcribe)

1. Action **"Record Audio"** (tap to start, tap to stop) — or pick a Voice Memo / audio file instead.
2. **"Get Contents of URL"**:
   - URL `http://<server-ip>:8880/stt` (WiFi) or the Tailscale URL (anywhere)
   - Method **POST**
   - Request Body **Form**
   - Add a field → type **File**, key `file`, value = the recorded audio (the previous action's output)
3. **"Get Dictionary Value"** → key `text` from the response.
4. Do something with it: **Copy to Clipboard**, **Show Result**, drop it into a Message, or pipe it straight into your TTS shortcut.
- Trigger with "Hey Siri, *transcribe*", or from the **Share Sheet** (share a Voice Memo → transcribe it).

### Android

**HTTP Shortcuts** or **Tasker**: record audio to a file → HTTP **POST** multipart to `/stt`, field name `file` → read the JSON `text` value. In Tasker: *Get Voice* / a recording action → *HTTP Request* (multipart body) → parse `text`.

### Open WebUI — voice input (mic button)

Admin → Settings → Audio → **STT (Speech-to-Text)**: engine **OpenAI**, base URL `http://<server-ip>:8880/v1`, model `whisper-1`, any key. The mic button in the chat box now transcribes through your endpoint. It's the same settings page as the TTS half (7A) — point both directions at this one service.

### Telegram bot — transcribe voice notes (server-side)

The bot (in `your-client-host`) receives a `voice`/`audio` message, downloads it, POSTs to `/stt`, and replies with the transcript (or forwards the text to the LLM). With python-telegram-bot:

```python
import requests
f = await context.bot.get_file(update.message.voice.file_id)
audio = await f.download_as_bytearray()
r = requests.post("http://<server-ip>:8880/stt",
                  files={"file": ("voice.oga", bytes(audio))})
await update.message.reply_text(r.json()["text"])
```

Use the host URL `http://<server-ip>:8880` from your-client-host — the TTS container is on a different docker network, so its container name won't resolve from there.

### Python / Node

```python
# Python — native endpoint
import requests
with open("recording.mp3", "rb") as f:
    print(requests.post("http://<server-ip>:8880/stt", files={"file": f}).json()["text"])

# Python — OpenAI SDK
from openai import OpenAI
client = OpenAI(base_url="http://<server-ip>:8880/v1", api_key="anything")
with open("recording.mp3", "rb") as f:
    print(client.audio.transcriptions.create(model="whisper-1", file=f).text)
```

```javascript
// Node 18+ (global fetch/FormData/Blob)
import { readFileSync } from "fs";
const fd = new FormData();
fd.append("file", new Blob([readFileSync("recording.m4a")]), "recording.m4a");
const r = await fetch("http://<server-ip>:8880/stt", { method: "POST", body: fd });
console.log((await r.json()).text);
```

### Home Assistant / any Whisper client

Anything that speaks the OpenAI `/v1/audio/transcriptions` API points at base URL `http://<server-ip>:8880/v1` (model `whisper-1`, any key) for fully local transcription — no cloud, no per-minute cost.

## 7C — Full voice loop (STT → LLM → TTS)

You already have every piece: this endpoint (STT + TTS) plus Ollama on `:11434`. Record → transcribe → ask the LLM → speak the answer:

```bash
BASE=http://<server-ip>:8880
OLLAMA=http://<server-ip>:11434

text=$(curl -s -X POST $BASE/stt -F "file=@question.m4a" | grep -o '"text":"[^"]*"' | cut -d'"' -f4)
reply=$(curl -s $OLLAMA/api/generate -d "{\"model\":\"llama3.2:3b\",\"prompt\":\"$text\",\"stream\":false}" | grep -o '"response":"[^"]*"' | cut -d'"' -f4)
curl -s -X POST $BASE/tts -H "Content-Type: application/json" -d "{\"text\":\"$reply\"}" -o answer.mp3
```

On iPhone, chain three actions in one Shortcut: the STT recipe (7B) → an HTTP call to Ollama (or your bot) → the TTS recipe (7A). That's a private, offline voice assistant.

## 8. Operating the service (on the Unraid box)

All from this folder (`<repo-dir>`):

```bash
docker compose up -d            # start / apply compose changes
docker compose up -d --build    # redeploy after editing the code
docker compose logs -f          # follow logs
docker compose down             # stop
docker logs kokoro-tts          # logs by container name
```

Config changes = edit `environment:` in `docker-compose.yml`, then `docker compose up -d`:

| Setting | Add to environment |
|---|---|
| Stream by default | `TTS_STREAM_DEFAULT=1` |
| Disable normalization globally | `NORM_ENABLED=0` |
| Enable the `/chat/speak` demo | `CHAT_ENABLED=1` (loads `llama3.2:3b`; can pin that model to CPU for other apps — see README) |
| Different default voice | `KOKORO_VOICE=am_michael` |
| Default to cloud voices | `TTS_ENGINE=edge` |
| Turn off transcription (STT) | `STT_ENABLED=0` (unmounts `/stt` + `/v1/audio/transcriptions`; Parakeet never loads) |

Note: `docker compose` itself vanishes from the host on every Unraid reboot (the container keeps running; only the CLI plugin is lost). Reinstall before rebuild work, or persist it via `/boot/config/go`.

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| No response at all | Same network? On cellular, is Tailscale connected? `curl .../health` from the machine itself |
| `X-TTS-Engine: edge-fallback` | Kokoro failed — `curl .../health` → `tts_engine.kokoro_error`; likely the models/ mount |
| Edge voice fails | Edge needs internet (Microsoft cloud); Kokoro doesn't |
| Speech sounds odd on messy text | Inspect with `POST /normalize`; check `flagged_log.jsonl` |
| `/chat/speak` → 404 | Intentional — `CHAT_ENABLED=0` (§2/§8) |
| `/stt` → 404 | `STT_ENABLED=0` in this deployment (§8) |
| `/stt` → 400 "could not decode audio" | Not a valid/complete audio file; try re-exporting to wav or mp3 |
| STT transcript empty or wrong | Parakeet is English-only; check the clip actually has speech. `curl .../health` → `stt_engine.error` if the model didn't load (models/ mount) |
| Container gone after reboot | It should auto-start (`restart: unless-stopped`). If Docker itself was off: check the array started first |
| Slow first response after idle | Normalization models are pinned resident, so it's not them; edge = internet latency; check server load (`docker stats kokoro-tts`) |
