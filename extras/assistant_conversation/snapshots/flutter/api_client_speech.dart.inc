  /// Assistant-owned, transcription-only speech boundary used by Coach
  /// dictation and hands-free mode. This endpoint cannot submit an agent turn;
  /// callers explicitly decide whether to populate the composer or submit a
  /// later durable run with the matching origin.
  Future<String> assistantTranscribe(
    String filePath,
    String mode,
  ) async {
    if (mode != "dictation" && mode != "hands_free") {
      throw ArgumentError.value(mode, "mode", "unsupported speech input mode");
    }
    final request =
        http.MultipartRequest("POST", _u("/api/speech/transcriptions"));
    request.headers.addAll(_headers());
    request.fields["mode"] = mode;
    request.files.add(await http.MultipartFile.fromPath("audio", filePath));
    final streamed = await request.send().timeout(const Duration(seconds: 120));
    final response = await http.Response.fromStream(streamed)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception("Assistant transcription failed: ${response.statusCode}");
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final provenance = data["provenance"] is Map
        ? (data["provenance"] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final transcript = "${data["transcript"] ?? ""}".trim();
    if (data["ok"] != true ||
        transcript.isEmpty ||
        provenance["owner"] != "assistant" ||
        provenance["mode"] != mode) {
      throw StateError("Assistant returned an invalid transcription result");
    }
    return transcript;
  }

// --- aligned TTS client ---

  /// Read ONE message aloud on demand, whichever agent said it. Empty list
  /// when TTS is unavailable — the caller shows that rather than pretending.
  Future<List<int>> speakMessage(String text) async {
    return (await speakAligned(text)).audioBytes;
  }

  /// Assistant-wide aligned TTS. The server synthesizes locally and maps the
  /// exact source words onto the generated audio using CPU forced alignment.
  Future<AssistantSpeechClip> speakAligned(String text,
      {bool realtime = false}) async {
    try {
      final d = await _postJson(
          "/api/speak-message", {"text": text, "realtime": realtime},
          timeout: const Duration(seconds: 120));
      final b64 = d["audio"] as String?;
      final bytes =
          b64 == null || b64.isEmpty ? const <int>[] : base64Decode(b64);
      return AssistantSpeechClip.fromJson(d, text: text, audioBytes: bytes);
    } catch (_) {
      return AssistantSpeechClip(text: text, audioBytes: const []);
    }
  }
