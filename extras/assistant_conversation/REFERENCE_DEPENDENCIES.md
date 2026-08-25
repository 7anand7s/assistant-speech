# Reference integration dependencies

These are the versions resolved by the Assistant checkout when this bundle was
captured. They document a known integration environment; they do not alter the
top-level TTS service dependencies.

## Python

- Python 3.11
- `faster-whisper==1.1.0`
- `httpx==0.28.1`
- `fastapi==0.115.6`
- `pydantic==2.10.4`
- `python-multipart==0.0.20`

`speech_alignment.py` uses CPU faster-whisper with `compute_type="int8"`.
The proxy snapshots additionally depend on Assistant's settings and durable
compute-context modules; those are application boundaries, not speech-engine
dependencies.

## Flutter

- Flutter/Dart compatible with SDK `>=3.4.0 <4.0.0`
- `record` constraint `^7.1.1` (resolved `7.1.1`)
- `audioplayers` constraint `^6.1.0` (resolved `6.8.1`)
- `path_provider` constraint `^2.1.4`
- `http` constraint `^1.2.0`
- `web_socket_channel` constraint `^3.0.3` for Teaching events

The mobile snapshots also use the surrounding Assistant theme, API client,
producer runners, permissions and screen lifecycle.
