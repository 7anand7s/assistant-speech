"""
Streaming helpers for TTS: incremental sentence-splitting from an LLM token
stream, and incremental audio synthesis so the HTTP response starts flowing
before the full text (or the full audio) is ready.

Kokoro is not an autoregressive model - it can't stream audio mid-sentence,
it needs a complete sentence to run one synthesis pass. So the practical
granularity for "streaming TTS" here is per-sentence: as soon as the LLM
(or the caller, for plain /tts) has produced one complete sentence, that
sentence gets synthesized and its audio streamed to the client immediately,
while later sentences are still being generated/synthesized. This is the
same approach production streaming-TTS APIs use for non-autoregressive
vocoders.
"""

import asyncio
import json
import logging
import re

import httpx

log = logging.getLogger("tts.streaming")

_SENTENCE_BOUNDARY_RE = re.compile(r"([.!?]+[\s\n]+)")
MAX_BUFFER_CHARS = 300  # force a flush if no sentence boundary shows up this soon


def pop_complete_sentences(buffer: str) -> tuple[list[str], str]:
    """Extract complete sentences from the front of buffer. Returns
    (sentences, remainder-still-being-built). If the buffer runs long with
    no sentence-ending punctuation at all, force a flush at the nearest
    whitespace so one very long run of text can't stall the whole stream."""
    parts = _SENTENCE_BOUNDARY_RE.split(buffer)
    sentences = []
    i = 0
    while i + 1 < len(parts):
        sentences.append(parts[i] + parts[i + 1])
        i += 2
    remainder = parts[i] if i < len(parts) else ""
    if not sentences and len(remainder) > MAX_BUFFER_CHARS:
        cut = remainder.rfind(" ", 0, MAX_BUFFER_CHARS)
        cut = cut if cut > 0 else MAX_BUFFER_CHARS
        sentences.append(remainder[:cut])
        remainder = remainder[cut:].lstrip()
    return sentences, remainder


def split_all_sentences(text: str) -> list[str]:
    """For text that's already fully known upfront (no LLM involved)."""
    sentences, remainder = pop_complete_sentences(text)
    if remainder.strip():
        sentences.append(remainder)
    return sentences


async def stream_ollama_tokens(ollama_url: str, model: str, prompt: str, system: str | None = None):
    """Async-generator over raw text tokens from Ollama's streaming /api/generate (NDJSON)."""
    payload = {"model": model, "prompt": prompt, "stream": True}
    if system:
        payload["system"] = system
    async with httpx.AsyncClient(timeout=None) as client:
        async with client.stream("POST", f"{ollama_url}/api/generate", json=payload) as r:
            r.raise_for_status()
            async for line in r.aiter_lines():
                if not line:
                    continue
                data = json.loads(line)
                if data.get("response"):
                    yield data["response"]
                if data.get("done"):
                    break


async def sentences_from_token_stream(token_iter):
    """Buffer LLM tokens into complete sentences as they arrive."""
    buffer = ""
    async for token in token_iter:
        buffer += token
        sentences, buffer = pop_complete_sentences(buffer)
        for s in sentences:
            if s.strip():
                yield s
    if buffer.strip():
        yield buffer


class StreamingMp3Encoder:
    """Wraps one long-lived ffmpeg process that takes raw f32le PCM on stdin
    and emits a single continuous, seamless MP3 on stdout - so sentence-by-
    sentence audio doesn't produce clicks/gaps or duplicate MP3 headers at
    the joins. stdout is drained concurrently with stdin writes to avoid
    pipe deadlock on long streams."""

    def __init__(self, sample_rate: int):
        self.sample_rate = sample_rate
        self._proc = None
        self._queue: asyncio.Queue = asyncio.Queue()
        self._pump_task = None

    async def __aenter__(self):
        self._proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-f", "f32le", "-ar", str(self.sample_rate), "-ac", "1", "-i", "pipe:0",
            "-f", "mp3", "-codec:a", "libmp3lame", "-qscale:a", "2", "-write_xing", "0",
            "pipe:1",
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        self._pump_task = asyncio.create_task(self._pump_stdout())
        return self

    async def _pump_stdout(self):
        try:
            while True:
                chunk = await self._proc.stdout.read(4096)
                if not chunk:
                    break
                await self._queue.put(chunk)
        finally:
            await self._queue.put(None)

    async def write(self, samples) -> None:
        self._proc.stdin.write(samples.astype("float32").tobytes())
        await self._proc.stdin.drain()

    async def read_chunk(self):
        return await self._queue.get()

    async def finish_writing(self) -> None:
        self._proc.stdin.close()

    async def __aexit__(self, *exc):
        await self._pump_task
        await self._proc.wait()
