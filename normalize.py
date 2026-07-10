"""
NORMALIZATION LLM (role 2) - rewords text so it reads cleanly aloud.

This stage NEVER generates content. It only rewords text that already exists,
and only for the small fraction of it that the regex stage flags. The models
here (qwen2.5:1.5b, then gemma3:1b) are unrelated to the chat model in chat.py,
which does the opposite job - writing new text from a prompt.

Design principle: reframe for speech, never delete information. A URL or
markdown link still points somewhere real - the goal is to make it speakable
(e.g. mention the domain), not to erase it.

Stage 1: deterministic regex cleaner (microseconds, handles the bulk of
          markdown/URL/emoji/code-fence junk). URLs are rewritten to a
          speakable "linked to <domain>" form, not deleted; markdown links
          keep both their label and their target domain. Each link mention
          is then swapped for an opaque placeholder token (LINK0, LINK1, ...)
          so Stage 3 physically cannot corrupt or drop the domain text.
Stage 2: whitelist check (needs_review) on what Stage 1 left behind.
Stage 3: tiny local LLM fallback (Ollama, CPU-only, kept resident) - only
          invoked for text Stage 2 flags, never on the hot path for normal
          text. qwen2.5:1.5b is tried first, gemma3:1b second. Each
          candidate's output is verified to contain every placeholder used
          in the input, verbatim - if a model drops or mangles one (tiny
          models do this), its output is discarded and the next candidate
          is tried. If every candidate fails verification, the Stage-1
          text is used as-is (read-through) - information is never lost to
          a hallucination, worst case the phrasing is just less natural.
          Placeholders are swapped back to the real link text at the end.

Flagged cases are logged to flagged_log.jsonl for later review - patterns
that show up repeatedly should get folded into the Stage 1 regex cleaner.
"""

import json
import logging
import re
import time
import urllib.parse

import httpx

import config

log = logging.getLogger("tts.normalize")

FALLBACK_SYSTEM_PROMPT = (
    "You reword text so a text-to-speech engine reads it naturally. Only "
    "reword ambiguous digit sequences (phone numbers, IDs, codes) into a "
    "spoken form, and drop stray leftover symbols. Never delete or change "
    "any word, fact, name, or number. Tokens like LINK0 or LINK1 are "
    "placeholders standing in for a link mention - copy each one into your "
    "output EXACTLY as written, unchanged, in the same relative position; "
    "never invent, remove, merge, or renumber them. Output ONLY the "
    "reworded sentence itself - no prefix, no quotation marks, no labels "
    "like 'Rewritten:' or 'Here is'.\n\n"
    "Example:\n"
    "Input: Order 4829103 ships tomorrow, LINK0\n"
    "Output: Order four eight two nine one zero three ships tomorrow, LINK0"
)

# --- Stage 1: deterministic regex cleaner + link protection -----------------

_SMART_QUOTES = str.maketrans({
    "‘": "'", "’": "'", "“": '"', "”": '"',
    "–": "-", "—": "-", "…": "...",
})
_CODE_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`([^`]+)`")
_MD_LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")
_URL_RE = re.compile(r"https?://\S+|www\.\S+")
_MD_SYMBOLS_RE = re.compile(r"[*_`#~]{1,3}")
_EMOJI_RE = re.compile("[\U0001F300-\U0001FAFF\U00002600-\U000027BF]+")
_PLACEHOLDER_RE = re.compile(r"LINK\d+")


def _domain_of(url: str) -> str:
    """Extract a speakable domain from a URL - preserves *where it points*
    without reading a full path/query string aloud."""
    candidate = url if re.match(r"^https?://", url, re.IGNORECASE) else f"http://{url}"
    try:
        host = urllib.parse.urlparse(candidate).netloc
    except ValueError:
        host = ""
    host = re.sub(r"^www\.", "", host)
    return host or url


def clean_stage1(text: str) -> tuple[str, dict[str, str]]:
    """Returns (text_with_link_placeholders, {placeholder: real_link_text})."""
    text = text.translate(_SMART_QUOTES)
    text = _CODE_BLOCK_RE.sub(" code omitted ", text)
    text = _INLINE_CODE_RE.sub(r"\1", text)

    placeholders: dict[str, str] = {}

    def _protect(mention: str) -> str:
        token = f"LINK{len(placeholders)}"
        placeholders[token] = mention
        return token

    text = _MD_LINK_RE.sub(lambda m: f"{m.group(1)} ({_protect(f'linked to {_domain_of(m.group(2))}')})", text)
    text = _URL_RE.sub(lambda m: _protect(f"link to {_domain_of(m.group(0))}"), text)
    text = _MD_SYMBOLS_RE.sub("", text)
    text = _EMOJI_RE.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text, placeholders


def restore_placeholders(text: str, placeholders: dict[str, str]) -> str:
    for token, mention in placeholders.items():
        text = text.replace(token, mention)
    return text


# --- Stage 2: whitelist check for what Stage 1 left behind ------------------

_SAFE_RE = re.compile(r"^[a-zA-Z0-9\s.,!?'\"\-:;()]+$")


def needs_review(cleaned_text: str) -> bool:
    if not cleaned_text:
        return False
    if not _SAFE_RE.match(cleaned_text):
        return True  # leftover unicode/symbols Stage 1 missed
    if re.search(r"\d{6,}", cleaned_text):
        return True  # long digit run - phone number? ID? ambiguous read mode
    words = re.findall(r"\S+", cleaned_text)
    if len(words) / max(len(cleaned_text), 1) < 0.1:
        return True  # low word-density - probably a table or ASCII art
    return False


# --- Stage 3: tiny LLM fallback (Ollama), only for flagged text --------------

def _log_flagged(raw: str, cleaned: str, final: str, model_used: str | None):
    try:
        config.NORM_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with config.NORM_LOG_PATH.open("a") as f:
            f.write(json.dumps({
                "ts": time.time(), "raw": raw, "stage1_cleaned": cleaned,
                "final": final, "model_used": model_used,
            }) + "\n")
    except Exception as e:
        log.warning("could not write flagged-text log: %s", e)


async def _call_ollama(model: str, text: str, timeout: float) -> str:
    async with httpx.AsyncClient(timeout=timeout) as client:
        r = await client.post(f"{config.OLLAMA_URL}/api/generate", json={
            "model": model,
            "system": FALLBACK_SYSTEM_PROMPT,
            "prompt": text,
            "stream": False,
            "keep_alive": config.NORM_KEEP_ALIVE,
            "options": config.ollama_options(),  # num_gpu: 0 -> CPU only
        })
        r.raise_for_status()
        return r.json().get("response", "").strip()


def _placeholders_intact(input_text: str, output_text: str) -> bool:
    expected = set(_PLACEHOLDER_RE.findall(input_text))
    if not expected:
        return True
    return expected.issubset(set(_PLACEHOLDER_RE.findall(output_text)))


async def llm_normalize(text: str) -> tuple[str, str | None]:
    """Try each fallback model in order. Returns (text, model_used).
    A candidate is only accepted if every placeholder from the input is
    still present, verbatim, in its output - otherwise it's discarded as a
    corruption risk and the next model is tried. Falls back to the input
    unchanged (safe read-through) if every candidate fails."""
    for model in config.NORM_MODELS:
        try:
            out = await _call_ollama(model, text, config.NORM_TIMEOUT)
            if not out:
                continue
            if not _placeholders_intact(text, out):
                log.warning("normalize model '%s' dropped/altered a link placeholder - discarding its output", model)
                continue
            return out, model
        except Exception as e:
            log.warning("normalize fallback model '%s' failed: %s", model, e)
            continue
    return text, None


async def warm_up_models():
    """Ping each fallback model once at startup so they're resident (CPU)
    before the first flagged request needs them; keep_alive keeps them
    loaded indefinitely after that."""
    for model in config.NORM_MODELS:
        try:
            await _call_ollama(model, "hello", timeout=60)
            log.info("warmed up normalize model '%s' (CPU, keep_alive=%s)", model, config.NORM_KEEP_ALIVE)
        except Exception as e:
            log.warning("could not warm up normalize model '%s': %s", model, e)


async def normalize_text(text: str) -> tuple[str, bool, str | None]:
    """Full pipeline. Returns (final_text, was_flagged, model_used)."""
    if not config.NORM_ENABLED:
        return text, False, None
    cleaned, placeholders = clean_stage1(text)
    if not needs_review(cleaned):
        return restore_placeholders(cleaned, placeholders), False, None
    final, model_used = await llm_normalize(cleaned)
    _log_flagged(text, cleaned, final, model_used)
    return restore_placeholders(final, placeholders), True, model_used
