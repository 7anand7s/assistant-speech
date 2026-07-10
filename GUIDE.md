# Self-Hosted TTS Endpoint — Connection Guide

**Service:** `kokoro-tts` container on Unraid (`tower`) · **Port:** `8880` · **Auth:** none (private network only)

## 1. Addresses — which URL to use from where

| You are… | Base URL |
|---|---|
| On home WiFi (any device) | `http://192.168.0.250:8880` |
| Anywhere else, device on your Tailscale tailnet | `http://100.91.190.65:8880` |
| Same, with MagicDNS | `http://tower.fairy-fahrenheit.ts.net:8880` |

- **Phones/laptops away from home:** install the Tailscale app, log into your tailnet, then use the `100.91.190.65` URL. Works on cellular.
- The endpoint is deliberately **not** on the public internet and has **no API key**. Don't add it to Tailscale Funnel.
- It's plain `http`, not `https` — some clients warn about this; that's expected on a LAN/tailnet service.

Quick reachability test from any machine:

```bash
curl http://192.168.0.250:8880/health
```

Healthy response starts with `{"status":"ok", ...}`.

## 2. The endpoints

### `POST /tts` — main endpoint, full control

Send JSON, get an MP3 back.

```bash
curl -X POST http://192.168.0.250:8880/tts \
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
curl -X POST http://192.168.0.250:8880/v1/audio/speech \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1", "input": "Hello!", "voice": "nova", "speed": 1.1}' \
  -o speech.mp3
```

- Fields: `model` (accepted, ignored), `input`, `voice`, `speed`. `response_format` is mp3 only.
- OpenAI voice names (`alloy`, `nova`, `onyx`, …) map to Kokoro voices automatically; native names (`af_heart`, `en-US-GuyNeural`) also work.
- **Never streams and always normalizes** — by design, to stay strictly OpenAI-shaped. Use `/tts` if you need per-request control.

### `GET /voices` — list available voices

```bash
curl "http://192.168.0.250:8880/voices?engine=kokoro&lang=en-us"
curl "http://192.168.0.250:8880/voices?engine=edge&lang=en-US"
```

### `POST /normalize` — debug the text cleanup

Returns JSON showing what the cleanup pipeline would do to a text, without doing TTS:

```bash
curl -X POST http://192.168.0.250:8880/normalize \
  -H "Content-Type: application/json" \
  -d '{"text": "**Important**: see [details](https://example.com/track) 📦"}'
```

### `GET /health` — status of every component

Reports the TTS engine and normalization LLM separately (`kokoro_available`, models loaded, etc.).

### `POST /chat/speak` — ⚠️ disabled in this deployment

The container runs with `CHAT_ENABLED=0`, so this returns **404**. It's a demo that writes text with an LLM and then speaks it — not part of the TTS pipeline. To enable it, see §8.

## 3. Streaming — enable / disable

Streaming sends audio as it's synthesized (sentence by sentence) instead of waiting for the whole MP3. Worth it for long texts; for one short sentence it makes little difference.

**Per request** (this always wins):

```bash
# stream ON — note curl's -N (no buffering)
curl -N -X POST http://192.168.0.250:8880/tts \
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

### iPhone — Shortcuts app

1. Shortcuts → **+** → add action **"Get Contents of URL"**
2. URL: `http://192.168.0.250:8880/v1/audio/speech` (WiFi) or the Tailscale URL (anywhere)
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
curl -X POST http://192.168.0.250:8880/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "Test from the command line."}' \
  -o out.mp3 && open out.mp3    # 'open' on macOS, 'xdg-open' on Linux
```

### Windows — PowerShell

```powershell
Invoke-RestMethod -Uri http://192.168.0.250:8880/tts -Method Post `
  -ContentType "application/json" `
  -Body '{"text": "Hello from Windows."}' `
  -OutFile out.mp3
Start-Process out.mp3
```

### Python

```python
import requests

r = requests.post("http://192.168.0.250:8880/tts",
                  json={"text": "Hello from Python.", "voice": "af_heart"})
open("out.mp3", "wb").write(r.content)
print(r.headers["X-TTS-Engine"])

# streaming variant — audio arrives sentence by sentence
with requests.post("http://192.168.0.250:8880/tts",
                   json={"text": "Long text here...", "stream": True},
                   stream=True) as r, open("out.mp3", "wb") as f:
    for chunk in r.iter_content(8192):
        f.write(chunk)
```

Or use the OpenAI SDK directly:

```python
from openai import OpenAI
client = OpenAI(base_url="http://192.168.0.250:8880/v1", api_key="anything")
client.audio.speech.create(model="tts-1", input="Hi!", voice="nova").write_to_file("out.mp3")
```

### JavaScript / Node

```javascript
const res = await fetch("http://192.168.0.250:8880/tts", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ text: "Hello from Node." }),
});
require("fs").writeFileSync("out.mp3", Buffer.from(await res.arrayBuffer()));
```

### Open WebUI

Admin → Settings → Audio → TTS: engine **OpenAI**, API base `http://192.168.0.250:8880/v1`, any API key, voice e.g. `nova`.

### Telegram-bot direction

A bot (running anywhere on the LAN/tailnet) POSTs incoming message text to `/tts` and sends the MP3 back as a voice note. Shortcuts can't reliably trigger on incoming Telegram messages — that part belongs server-side.

## 8. Operating the service (on the Unraid box)

All from this folder (`/mnt/user/ML/TTS`):

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

Note: `docker compose` itself vanishes from the host on every Unraid reboot (the container keeps running; only the CLI plugin is lost). Reinstall before rebuild work, or persist it via `/boot/config/go`.

## 9. Troubleshooting

| Symptom | Check |
|---|---|
| No response at all | Same network? On cellular, is Tailscale connected? `curl .../health` from the machine itself |
| `X-TTS-Engine: edge-fallback` | Kokoro failed — `curl .../health` → `tts_engine.kokoro_error`; likely the models/ mount |
| Edge voice fails | Edge needs internet (Microsoft cloud); Kokoro doesn't |
| Speech sounds odd on messy text | Inspect with `POST /normalize`; check `flagged_log.jsonl` |
| `/chat/speak` → 404 | Intentional — `CHAT_ENABLED=0` (§2/§8) |
| Container gone after reboot | It should auto-start (`restart: unless-stopped`). If Docker itself was off: check the array started first |
| Slow first response after idle | Normalization models are pinned resident, so it's not them; edge = internet latency; check server load (`docker stats kokoro-tts`) |
