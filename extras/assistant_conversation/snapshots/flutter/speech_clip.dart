class AssistantWordTiming {
  final String word;
  final int startMs;
  final int endMs;

  const AssistantWordTiming({
    required this.word,
    required this.startMs,
    required this.endMs,
  });

  factory AssistantWordTiming.fromJson(Map<String, dynamic> json) =>
      AssistantWordTiming(
        word: "${json["word"] ?? ""}",
        startMs: (json["start_ms"] as num?)?.toInt() ?? 0,
        endMs: (json["end_ms"] as num?)?.toInt() ?? 0,
      );
}

class AssistantSpeechClip {
  final String text;
  final List<int> audioBytes;
  final List<AssistantWordTiming> words;
  final String alignment;

  const AssistantSpeechClip({
    required this.text,
    required this.audioBytes,
    this.words = const [],
    this.alignment = "unavailable",
  });

  bool get isEmpty => audioBytes.isEmpty;

  factory AssistantSpeechClip.fromJson(
    Map<String, dynamic> json, {
    required String text,
    required List<int> audioBytes,
  }) =>
      AssistantSpeechClip(
        text: "${json["text"] ?? text}",
        audioBytes: audioBytes,
        words: ((json["words"] as List?) ?? const [])
            .whereType<Map>()
            .map((item) =>
                AssistantWordTiming.fromJson(item.cast<String, dynamic>()))
            .where((item) => item.word.isNotEmpty)
            .toList(growable: false),
        alignment: "${json["alignment"] ?? "unavailable"}",
      );
}

class AssistantSpeechProgress {
  final AssistantSpeechClip? clip;
  final int activeWordIndex;
  final bool paused;

  const AssistantSpeechProgress({
    this.clip,
    this.activeWordIndex = -1,
    this.paused = false,
  });
}

/// Text that is safe and natural to read aloud.
///
/// Canonical chat content remains untouched. Only the speech presentation
/// drops code blocks, URLs, citation markers, and Markdown punctuation so the
/// voice never reads formatting noise or source links.
String assistantSpokenText(String source) {
  var value = source;
  value = value.replaceAll(RegExp(r"```[\s\S]*?```"), " ");
  value = value.replaceAllMapped(
    RegExp(r"!\[[^\]]*\]\([^\)]*\)"),
    (_) => " ",
  );
  value = value.replaceAllMapped(
    RegExp(r"\[([^\]]+)\]\([^\)]*\)"),
    (match) => match.group(1) ?? "",
  );
  value = value.replaceAll(RegExp(r"https?://\S+"), " ");
  value = value.replaceAll(
      RegExp(r"\[(?:\d+|source[^\]]*)\]", caseSensitive: false), " ");
  value = value.replaceAll(
      RegExp(r"^\s{0,3}(?:#{1,6}|>|[-+*]|\d+[.)])\s+", multiLine: true), "");
  value = value.replaceAll(RegExp(r"[*_~`]"), "");
  return value.replaceAll(RegExp(r"\s+"), " ").trim();
}

/// Split speech for low time-to-first-audio without turning every sentence
/// into a cold, serial request. The opening phrase stays deliberately short;
/// later chunks are larger because the queue synthesizes one ahead while the
/// current clip is playing.
List<String> assistantSpeechChunks(
  String source, {
  int firstMaxChars = 96,
  int nextMaxChars = 260,
}) {
  var remaining = assistantSpokenText(source);
  if (remaining.isEmpty) return const [];
  final chunks = <String>[];
  var first = true;
  while (remaining.isNotEmpty) {
    final limit = first ? firstMaxChars : nextMaxChars;
    first = false;
    if (remaining.length <= limit) {
      chunks.add(remaining);
      break;
    }
    final head = remaining.substring(0, limit + 1);
    final minimum = (limit / 3).round().clamp(24, limit).toInt();
    var cut = _lastSpeechBoundary(head, RegExp(r"[.!?](?=\s|$)"), minimum);
    cut = cut > 0
        ? cut
        : _lastSpeechBoundary(head, RegExp(r"[,;:](?=\s|$)"), minimum);
    if (cut <= 0) {
      final space = head.lastIndexOf(" ", limit);
      cut = space >= minimum ? space : limit;
    }
    final chunk = remaining.substring(0, cut).trim();
    if (chunk.isNotEmpty) chunks.add(chunk);
    remaining = remaining.substring(cut).trimLeft();
  }
  return chunks;
}

int _lastSpeechBoundary(String value, RegExp pattern, int minimum) {
  var cut = -1;
  for (final match in pattern.allMatches(value)) {
    final candidate = match.end;
    if (candidate >= minimum) cut = candidate;
  }
  return cut;
}
