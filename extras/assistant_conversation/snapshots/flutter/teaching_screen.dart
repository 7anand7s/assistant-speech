import "dart:async";
import "dart:convert";
import "dart:io";

import "package:audioplayers/audioplayers.dart";
import "package:file_selector/file_selector.dart";
import "package:flutter/material.dart";
import "package:path_provider/path_provider.dart";
import "package:record/record.dart";
import "package:url_launcher/url_launcher.dart";
import "package:web_socket_channel/io.dart";
import "package:web_socket_channel/web_socket_channel.dart";

import "../api/api_client.dart";
import "../theme.dart";
import "../voice/aligned_speech_text.dart";
import "../voice/assistant_router_commands.dart";
import "../voice/speech_clip.dart";

enum _LessonEntryKind { learner, narration, answer, image, diagram }

class _LessonEntry {
  final _LessonEntryKind kind;
  String text;
  AssistantSpeechClip? clip;
  String src;
  String caption;

  _LessonEntry(
    this.kind,
    this.text, {
    this.src = "",
    this.caption = "",
  });
}

class _QueuedClip {
  final int entryIndex;
  final AssistantSpeechClip clip;
  const _QueuedClip(this.entryIndex, this.clip);
}

/// Native Teaching surface embedded as Assistant's eighth agent tab.
///
/// The producer remains authoritative for courses, graph pauses, narration,
/// knowledge-graph connections, and media. This widget owns only authenticated
/// transport and device interaction: aligned playback, highlighting, AEC/VAD
/// barge-in, typed/voice questions, and course actions.
class TeachingPane extends StatefulWidget {
  final ApiClient api;
  final String routedPrompt;
  final Future<void> Function()? onRouterRequest;

  const TeachingPane({
    super.key,
    required this.api,
    this.routedPrompt = "",
    this.onRouterRequest,
  });

  @override
  State<TeachingPane> createState() => _TeachingPaneState();
}

class _TeachingPaneState extends State<TeachingPane> {
  final _player = AudioPlayer();
  final _questionRecorder = AudioRecorder();
  final _bargeRecorder = AudioRecorder();
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final List<_LessonEntry> _entries = [];
  final List<_QueuedClip> _audioQueue = [];
  final Map<int, int> _narrationEntries = {};

  List<Map<String, dynamic>> _courses = const [];
  Map<String, dynamic>? _course;
  Map<String, dynamic>? _section;
  List<Map<String, dynamic>> _videos = const [];
  Map<String, dynamic> _connections = const {};
  WebSocketChannel? _channel;
  StreamSubscription? _socketSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Amplitude>? _bargeAmplitudeSubscription;
  StreamSubscription<Amplitude>? _questionAmplitudeSubscription;
  Timer? _bargeMaximum;
  Timer? _firstLessonEventTimer;
  String _status = "Loading your courses…";
  String _routedPrompt = "";
  String _pendingAnswer = "";
  int _pendingAnswerIndex = -1;
  String _pendingQuestion = "";
  String _awaitingReason = "";
  bool _loading = true;
  bool _connecting = false;
  bool _sessionFailed = false;
  bool _playing = false;
  bool _paused = false;
  bool _recordingQuestion = false;
  bool _bargeTriggered = false;
  bool _receivedLessonEvent = false;
  bool _privateUploadsEnabled = false;
  bool _disposed = false;
  int _activeEntry = -1;
  int _activeWord = -1;
  Completer<void>? _playbackDone;
  Completer<void>? _bargeDone;
  String? _bargePath;

  String get _sectionId => "${_section?["id"] ?? ""}";
  String get _fieldId => "${_course?["field_id"] ?? ""}";
  String get _courseSlug => "${_course?["course_slug"] ?? ""}";

  @override
  void initState() {
    super.initState();
    _applyRoutedPrompt(widget.routedPrompt);
    _positionSubscription = _player.onPositionChanged.listen(_positionChanged);
    _playerStateSubscription =
        _player.onPlayerStateChanged.listen(_playerState);
    unawaited(_loadLibrary());
  }

  @override
  void didUpdateWidget(covariant TeachingPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.routedPrompt != oldWidget.routedPrompt) {
      _applyRoutedPrompt(widget.routedPrompt);
    }
  }

  void _applyRoutedPrompt(String value) {
    final prompt = value.trim();
    _routedPrompt = prompt;
    if (prompt.isEmpty) return;
    _question.text = prompt;
    _question.selection = TextSelection.collapsed(offset: prompt.length);
    _status = _course == null
        ? "Assistant routed this request. Choose a course, or create one with the topic prefilled."
        : "Assistant routed this request. Review it below, then ask Teaching.";
  }

  Future<void> _loadLibrary({bool preserveSelection = true}) async {
    final selectedId = preserveSelection ? _sectionId : "";
    try {
      final courses = await widget.api.teachingLibrary();
      Map<String, dynamic> compute = const {};
      try {
        compute = await widget.api.teachingComputeStatus();
      } catch (_) {
        // Upload placement is privacy-sensitive. An unreadable authority
        // contract must keep the action disabled rather than guessing local.
      }
      if (!mounted) return;
      Map<String, dynamic>? selectedCourse;
      Map<String, dynamic>? selectedSection;
      if (selectedId.isNotEmpty) {
        for (final course in courses) {
          for (final raw in (course["sections"] as List?) ?? const []) {
            if (raw is Map && "${raw["id"] ?? ""}" == selectedId) {
              selectedCourse = course;
              selectedSection = raw.cast<String, dynamic>();
            }
          }
        }
      }
      setState(() {
        _courses = courses;
        _course = selectedCourse;
        _section = selectedSection;
        _privateUploadsEnabled =
            "${compute["compute_authority"] ?? ""}".toLowerCase() == "local";
        _loading = false;
        _status = _routedPrompt.isNotEmpty
            ? (courses.isEmpty
                ? "Assistant routed this request. Create a course with the topic prefilled."
                : "Assistant routed this request. Choose a course, then review the prefilled question.")
            : (courses.isEmpty
                ? "No courses yet — create one from Teaching actions."
                : "Choose a ready lesson to begin.");
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = "Teaching is not reachable right now.";
      });
    }
  }

  Future<void> _selectSection(
    Map<String, dynamic> course,
    Map<String, dynamic> section,
  ) async {
    if ("${section["status"] ?? "ready"}" != "ready") return;
    try {
      await _closeSession();
    } catch (_) {
      // A stale media/socket backend must never make a ready course tile
      // untappable. The new session starts from a clean local UI regardless.
    }
    if (!mounted) return;
    setState(() {
      _course = course;
      _section = section;
      _routedPrompt = "";
      _entries.clear();
      _videos = const [];
      _connections = const {};
      _status = "Ready — tap Start lesson.";
      _connecting = false;
      _sessionFailed = false;
      _activeEntry = -1;
      _activeWord = -1;
      _narrationEntries.clear();
      _receivedLessonEvent = false;
    });
    try {
      // The lesson body is the primary content. Fetch and render it before
      // optional video/discovery metadata so a slow or unavailable auxiliary
      // endpoint can never leave a successfully selected lesson grey.
      final detail = await widget.api.teachingSection(_sectionId);
      if (!mounted || _sectionId != "${section["id"]}") return;
      setState(() {
        final blocks = (detail["blocks"] as List?) ?? const [];
        _entries.clear();
        _narrationEntries.clear();
        for (var blockIndex = 0; blockIndex < blocks.length; blockIndex++) {
          final rawBlock = blocks[blockIndex];
          if (rawBlock is! Map || "${rawBlock["kind"] ?? ""}" != "text") {
            continue;
          }
          final text = "${rawBlock["text"] ?? ""}".trim();
          if (text.isEmpty) continue;
          _narrationEntries[blockIndex] = _entries.length;
          _entries.add(_LessonEntry(_LessonEntryKind.narration, text));
        }
        if (_entries.isNotEmpty) {
          _status = "Lesson text is ready — tap Start for narrated teaching.";
        } else {
          _status = "This lesson has no readable text yet.";
        }
      });
    } catch (_) {
      if (!mounted || _sectionId != "${section["id"]}") return;
      setState(() => _status =
          "The lesson content could not be loaded — retry this lesson.");
      return;
    }
    try {
      final values = await Future.wait([
        widget.api.teachingVideos(_sectionId),
        widget.api.teachingConnections(_sectionId),
      ]);
      if (!mounted || _sectionId != "${section["id"]}") return;
      setState(() {
        _videos = values[0] as List<Map<String, dynamic>>;
        final raw = values[1] as Map<String, dynamic>;
        _connections = raw["result"] is Map
            ? (raw["result"] as Map).cast<String, dynamic>()
            : raw;
      });
    } catch (_) {
      // Discovery and optional media enrich the canonical lesson text. Their
      // absence must not hide or disable the lesson itself.
    }
  }

  Future<void> _startLesson() async {
    if (_sectionId.isEmpty || _channel != null || _connecting) return;
    setState(() {
      _connecting = true;
      _sessionFailed = false;
      _status = "Connecting to your tutor…";
    });
    IOWebSocketChannel? channel;
    try {
      channel = IOWebSocketChannel.connect(
        widget.api.teachingNarrationUri(_sectionId),
        headers: widget.api.authHeaders,
        pingInterval: const Duration(seconds: 20),
        connectTimeout: const Duration(seconds: 30),
      );
      // connect() returns before nginx finishes the HTTP upgrade. Waiting for
      // ready prevents a stripped/failed upgrade from leaving a non-null but
      // unusable socket and an apparently blank lesson on a release build.
      await channel.ready.timeout(const Duration(seconds: 30));
      if (!mounted) {
        await channel.sink.close();
        return;
      }
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        _event,
        onError: (_) => _sessionError("The lesson stream disconnected."),
        onDone: () {
          if (!_disposed && _status != "Lesson complete.") {
            _sessionError("The lesson stream closed.");
          }
        },
      );
      setState(() {
        _connecting = false;
        _status = "Tutor connected — buffering narration…";
        _receivedLessonEvent = false;
      });
      _firstLessonEventTimer?.cancel();
      _firstLessonEventTimer = Timer(const Duration(seconds: 75), () {
        if (!mounted || _receivedLessonEvent || _channel == null) return;
        _sessionError(
          "Teaching connected but narration did not start in time.",
        );
      });
    } catch (_) {
      try {
        await channel?.sink.close();
      } catch (_) {}
      _sessionError("Couldn't connect to Teaching.");
    }
  }

  void _event(dynamic raw) {
    if (!mounted) return;
    try {
      final event = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : jsonDecode(utf8.decode(raw as List<int>)) as Map<String, dynamic>;
      final type = "${event["type"] ?? ""}";
      _receivedLessonEvent = true;
      _firstLessonEventTimer?.cancel();
      _firstLessonEventTimer = null;
      switch (type) {
        case "narration_chunk":
          final block = (event["block_index"] as num?)?.toInt() ?? -1;
          final text = "${event["text"] ?? ""}";
          if (text.isEmpty) return;
          final existing = _narrationEntries[block];
          final index = existing ?? _entries.length;
          setState(() {
            if (existing == null) {
              _entries.add(_LessonEntry(_LessonEntryKind.narration, text));
            } else {
              _entries[existing].text = text;
            }
            if (block >= 0) _narrationEntries[block] = index;
            _status = "Narration is streaming.";
          });
          _scrollDown();
        case "audio_chunk":
          final block = (event["block_index"] as num?)?.toInt() ?? -1;
          final index = _narrationEntries[block];
          if (index == null || index >= _entries.length) return;
          _attachAudio(index, event);
        case "answer_chunk":
          final text = "${event["text"] ?? ""}";
          if (text.isEmpty) return;
          _pendingAnswer = text;
          _pendingAnswerIndex = _entries.length;
          setState(
              () => _entries.add(_LessonEntry(_LessonEntryKind.answer, text)));
          _scrollDown();
        case "answer_audio":
          if (_pendingAnswerIndex >= 0 &&
              _pendingAnswerIndex < _entries.length) {
            _attachAudio(_pendingAnswerIndex, event,
                fallbackText: _pendingAnswer);
          }
          _pendingAnswer = "";
          _pendingAnswerIndex = -1;
        case "diagram":
          setState(() => _entries.add(_LessonEntry(
                _LessonEntryKind.diagram,
                "Diagram",
                src: "${event["src"] ?? ""}",
                caption: "${event["caption"] ?? ""}",
              )));
          _scrollDown();
        case "image":
          setState(() => _entries.add(_LessonEntry(
                _LessonEntryKind.image,
                "Illustration",
                src: "${event["src"] ?? ""}",
                caption: "${event["caption"] ?? ""}",
              )));
          _scrollDown();
        case "pause_at_diagram":
          setState(() => _status = "Paused at the diagram.");
        case "awaiting_input":
          _awaitingReason = "${event["reason"] ?? "block_gap"}";
          unawaited(_respondAtPause());
        case "narration_complete":
          setState(() => _status = "Lesson complete.");
        case "error":
          _sessionError("${event["message"] ?? "Teaching hit an error."}");
      }
    } catch (_) {
      _sessionError("Teaching sent an unreadable lesson event.");
    }
  }

  void _attachAudio(
    int entryIndex,
    Map<String, dynamic> event, {
    String fallbackText = "",
  }) {
    final encoded = "${event["audio_base64"] ?? ""}";
    if (encoded.isEmpty) return;
    final text = _entries[entryIndex].text.isEmpty
        ? fallbackText
        : _entries[entryIndex].text;
    final clip = AssistantSpeechClip.fromJson(
      event,
      text: text,
      audioBytes: base64Decode(encoded),
    );
    setState(() => _entries[entryIndex].clip = clip);
    _audioQueue.add(_QueuedClip(entryIndex, clip));
    unawaited(_drainAudio());
  }

  Future<void> _drainAudio() async {
    if (_playing || _paused || _audioQueue.isEmpty) return;
    final queued = _audioQueue.removeAt(0);
    _playing = true;
    _activeEntry = queued.entryIndex;
    _activeWord = -1;
    if (mounted) setState(() {});
    File? file;
    try {
      final dir = await getTemporaryDirectory();
      file = File(
          "${dir.path}${Platform.pathSeparator}lesson_${DateTime.now().microsecondsSinceEpoch}.mp3");
      await file.writeAsBytes(queued.clip.audioBytes, flush: true);
      _playbackDone = Completer<void>();
      await _startBargeMonitor();
      await _player.play(DeviceFileSource(file.path));
      await _playbackDone!.future;
      if (_bargeTriggered && _bargeDone != null) await _bargeDone!.future;
    } catch (_) {
      // The text is canonical and remains visible if playback fails.
    } finally {
      await _stopBargeMonitor(discard: !_bargeTriggered);
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
      _playbackDone = null;
      _playing = false;
      _activeWord = -1;
      if (!_paused) _activeEntry = -1;
      if (mounted) setState(() {});
    }
    await _respondAtPause();
    if (!_bargeTriggered) unawaited(_drainAudio());
  }

  void _positionChanged(Duration position) {
    if (!mounted || _activeEntry < 0 || _activeEntry >= _entries.length) return;
    final words = _entries[_activeEntry].clip?.words ?? const [];
    if (words.isEmpty) return;
    var next =
        words.lastIndexWhere((word) => position.inMilliseconds >= word.startMs);
    if (next >= 0 &&
        position.inMilliseconds > words[next].endMs &&
        next == words.length - 1) {
      next = -1;
    }
    if (next != _activeWord) setState(() => _activeWord = next);
  }

  Future<void> _togglePause() async {
    if (_playing && !_paused) {
      _paused = true;
      await _player.pause();
      await _stopBargeMonitor(discard: true);
    } else if (_paused) {
      _paused = false;
      await _startBargeMonitor();
      await _player.resume();
    }
    if (mounted) setState(() {});
  }

  Future<void> _interruptPlayback() async {
    _paused = false;
    _audioQueue.clear();
    try {
      await _player.stop();
    } catch (_) {
      // Selecting or leaving a lesson must still work when the platform audio
      // backend is absent/restarting. Canonical lesson text is independent.
    }
    if (!(_playbackDone?.isCompleted ?? true)) _playbackDone!.complete();
    if (mounted) setState(() {});
  }

  Future<void> _respondAtPause() async {
    if (_awaitingReason.isEmpty ||
        _playing ||
        _audioQueue.isNotEmpty ||
        _paused) {
      return;
    }
    if (_pendingQuestion.isNotEmpty) {
      final question = _pendingQuestion;
      _pendingQuestion = "";
      _awaitingReason = "";
      _channel?.sink.add(jsonEncode({"type": "ask", "question": question}));
      if (mounted) setState(() => _status = "Tutor is answering…");
      return;
    }
    if (_awaitingReason == "block_gap") {
      _awaitingReason = "";
      _channel?.sink.add('{"type":"continue"}');
      if (mounted) setState(() => _status = "Continuing…");
    } else if (mounted) {
      setState(() => _status = "Natural pause — continue or ask a question.");
    }
  }

  Future<void> _continueLesson() async {
    if (_awaitingReason.isEmpty) return;
    _awaitingReason = "";
    _channel?.sink.add('{"type":"continue"}');
    setState(() => _status = "Continuing…");
  }

  Future<void> _ask(String value) async {
    final question = value.trim();
    if (question.isEmpty || _channel == null) return;
    _question.clear();
    setState(() {
      _entries.add(_LessonEntry(_LessonEntryKind.learner, question));
      _pendingQuestion = question;
      _status = "Waiting for the next natural pause…";
    });
    _scrollDown();
    if (_playing || _paused) await _interruptPlayback();
    await _respondAtPause();
  }

  Future<void> _toggleQuestionRecording() async {
    if (_recordingQuestion) {
      await _questionAmplitudeSubscription?.cancel();
      _questionAmplitudeSubscription = null;
      final path = await _questionRecorder.stop();
      if (mounted) setState(() => _recordingQuestion = false);
      if (path != null) await _transcribeAndAsk(path);
      return;
    }
    if (!await _questionRecorder.hasPermission()) return;
    if (_playing || _paused) await _interruptPlayback();
    final dir = await getTemporaryDirectory();
    final path =
        "${dir.path}${Platform.pathSeparator}teaching_question_${DateTime.now().microsecondsSinceEpoch}.m4a";
    await _questionRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
      path: path,
    );
    if (mounted) setState(() => _recordingQuestion = true);
  }

  Future<void> _transcribeAndAsk(String path) async {
    if (mounted) setState(() => _status = "Transcribing locally…");
    try {
      final text = await widget.api.assistantTranscribe(path, "hands_free");
      if (isAssistantRouterRequest(text)) {
        setState(() => _status = "Opening the Assistant router…");
        await widget.onRouterRequest?.call();
        return;
      }
      await _ask(text);
    } catch (_) {
      if (mounted) {
        setState(() => _status = "I couldn't transcribe that question.");
      }
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }

  Future<void> _startBargeMonitor() async {
    if (!_playing || await _bargeRecorder.isRecording()) return;
    if (!await _bargeRecorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    _bargePath =
        "${dir.path}${Platform.pathSeparator}teaching_barge_${DateTime.now().microsecondsSinceEpoch}.m4a";
    _bargeTriggered = false;
    _bargeDone = Completer<void>();
    await _bargeRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
      path: _bargePath!,
    );
    final started = DateTime.now();
    final floor = <double>[];
    double threshold = -40;
    DateTime? loudSince;
    DateTime? lastLoud;
    _bargeAmplitudeSubscription = _bargeRecorder
        .onAmplitudeChanged(const Duration(milliseconds: 75))
        .listen((sample) {
      final now = DateTime.now();
      if (now.difference(started) < const Duration(milliseconds: 600)) {
        floor.add(sample.current);
        return;
      }
      if (floor.isNotEmpty) {
        final average = floor.reduce((a, b) => a + b) / floor.length;
        threshold = (average + 9).clamp(-55.0, -12.0);
        floor.clear();
      }
      if (sample.current > threshold) {
        loudSince ??= now;
        lastLoud = now;
        if (!_bargeTriggered &&
            now.difference(loudSince!) >= const Duration(milliseconds: 150)) {
          _bargeTriggered = true;
          unawaited(_interruptPlayback());
          if (mounted) setState(() => _status = "I heard you — go ahead…");
        }
        return;
      }
      loudSince = null;
      if (_bargeTriggered &&
          lastLoud != null &&
          now.difference(lastLoud!) >= const Duration(milliseconds: 700)) {
        unawaited(_completeBargeCapture());
      }
    });
    _bargeMaximum = Timer(const Duration(seconds: 15), () {
      if (_bargeTriggered) unawaited(_completeBargeCapture());
    });
  }

  Future<void> _completeBargeCapture() async {
    if (!(_bargeDone?.isCompleted ?? true)) {
      await _bargeAmplitudeSubscription?.cancel();
      _bargeAmplitudeSubscription = null;
      _bargeMaximum?.cancel();
      final path = await _bargeRecorder.stop();
      _bargeDone!.complete();
      if (path != null) await _transcribeAndAsk(path);
    }
  }

  Future<void> _stopBargeMonitor({required bool discard}) async {
    _bargeMaximum?.cancel();
    _bargeMaximum = null;
    try {
      await _bargeAmplitudeSubscription?.cancel();
    } catch (_) {}
    _bargeAmplitudeSubscription = null;
    String? path;
    try {
      if (await _bargeRecorder.isRecording()) {
        path = await _bargeRecorder.stop();
      }
    } catch (_) {
      // Recorder teardown is best-effort; it cannot block navigation.
    }
    if (!(_bargeDone?.isCompleted ?? true)) _bargeDone!.complete();
    if (discard && path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    _bargePath = null;
  }

  void _playerState(PlayerState state) {
    if ((state == PlayerState.completed || state == PlayerState.stopped) &&
        !(_playbackDone?.isCompleted ?? true)) {
      _playbackDone!.complete();
    }
  }

  Future<void> _closeSession() async {
    _firstLessonEventTimer?.cancel();
    _firstLessonEventTimer = null;
    if (_playing ||
        _paused ||
        _audioQueue.isNotEmpty ||
        _playbackDone != null) {
      await _interruptPlayback();
    }
    if (_bargeAmplitudeSubscription != null ||
        _bargeMaximum != null ||
        _bargeDone != null ||
        _bargePath != null) {
      await _stopBargeMonitor(discard: true);
    }
    try {
      await _socketSubscription?.cancel();
    } catch (_) {}
    _socketSubscription = null;
    try {
      await _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _connecting = false;
    _receivedLessonEvent = false;
  }

  void _sessionError(String message) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _sessionFailed = true;
      _status = "$message Tap Retry when the connection is available.";
    });
    // A dead lesson socket must not leave narration or the barge-in recorder
    // running behind a failed/grey session. The shared cleanup is idempotent
    // and preserves the visible failure state for the Retry control.
    unawaited(_closeSession());
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<String?> _prompt(
    String title, {
    required String hint,
    String initial = "",
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text("Cancel")),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text("Continue")),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _createCourse() async {
    final field = await _prompt("Course field", hint: "e.g. science");
    if (!mounted || field == null || field.trim().isEmpty) return;
    final topic = await _prompt(
      "What should Teaching build?",
      hint: "Course topic",
      initial: _routedPrompt,
    );
    if (!mounted || topic == null || topic.trim().isEmpty) return;
    setState(() => _status = "Creating the course and first lesson…");
    try {
      final result = await widget.api.teachingCreateCourse(
          field.trim().replaceAll(RegExp(r"[^A-Za-z0-9_-]"), "-"),
          topic.trim());
      if (!mounted) return;
      setState(() {
        if (result["ok"] == true) _routedPrompt = "";
        _status = result["ok"] == true
            ? "Course created. Refreshing the library…"
            : "Teaching couldn't create that course.";
      });
      await _loadLibrary(preserveSelection: false);
    } catch (_) {
      if (mounted) setState(() => _status = "Course creation failed.");
    }
  }

  Future<void> _uploadMaterial() async {
    if (_course == null || !_privateUploadsEnabled) {
      if (mounted) {
        setState(() => _status =
            "Private course uploads are not available under central authority yet.");
      }
      return;
    }
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() => _status = "Uploading ${file.name}…");
    try {
      final result = await widget.api
          .teachingUpload(_fieldId, _courseSlug, file.path, file.name);
      if (!mounted) return;
      setState(() => _status = result["ok"] == true
          ? "Material queued. Teaching will place it in this course."
          : "Teaching refused that material.");
    } catch (_) {
      if (mounted) setState(() => _status = "Material upload failed.");
    }
  }

  Future<void> _materializeNext() async {
    if (_course == null) return;
    setState(() => _status = "Generating the next lesson…");
    try {
      await widget.api.teachingMaterializeNext(_fieldId, _courseSlug);
      await _loadLibrary();
    } catch (_) {
      if (mounted) {
        setState(() => _status = "The next lesson could not be generated.");
      }
    }
  }

  Future<void> _actions() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined),
            title: const Text("Create a course"),
            onTap: () {
              Navigator.pop(sheet);
              unawaited(_createCourse());
            },
          ),
          ListTile(
            enabled: _course != null && _privateUploadsEnabled,
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text("Add material to this course"),
            subtitle: !_privateUploadsEnabled
                ? const Text(
                    "Private upload placement is pending; shared-library publication is never automatic.")
                : null,
            onTap: _course == null || !_privateUploadsEnabled
                ? null
                : () {
                    Navigator.pop(sheet);
                    unawaited(_uploadMaterial());
                  },
          ),
          ListTile(
            enabled: _course != null,
            leading: const Icon(Icons.next_plan_outlined),
            title: const Text("Generate next lesson"),
            onTap: _course == null
                ? null
                : () {
                    Navigator.pop(sheet);
                    unawaited(_materializeNext());
                  },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text("Refresh library"),
            onTap: () {
              Navigator.pop(sheet);
              unawaited(_loadLibrary());
            },
          ),
        ]),
      ),
    );
  }

  Widget _library(CoachPalette palette) => ListView(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
        children: [
          Row(children: [
            Expanded(
              child: Text("Courses",
                  style: TextStyle(
                      color: palette.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w800)),
            ),
            IconButton(
                tooltip: "Teaching actions",
                onPressed: _actions,
                icon: const Icon(Icons.tune)),
          ]),
          if (_routedPrompt.isNotEmpty)
            Card(
              color: palette.acc.withValues(alpha: .12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Assistant routed this request",
                      style: TextStyle(
                        color: palette.text,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _routedPrompt,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.text),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      "Choose a ready course, or create one with this topic prefilled.",
                      style: TextStyle(color: palette.sub, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (!_loading && _courses.isEmpty)
            Card(
              color: palette.card,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _status,
                      style: TextStyle(color: palette.text),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_loadLibrary()),
                      icon: const Icon(Icons.refresh),
                      label: const Text("Retry"),
                    ),
                  ],
                ),
              ),
            ),
          for (final course in _courses)
            Card(
              color: palette.card,
              child: ExpansionTile(
                initiallyExpanded: _courses.length == 1,
                title: Text("${course["title"] ?? course["course_slug"]}",
                    style: TextStyle(
                        color: palette.text, fontWeight: FontWeight.w700)),
                subtitle: Text("${course["field_id"] ?? ""}",
                    style: TextStyle(color: palette.sub)),
                children: [
                  for (final raw in (course["sections"] as List?) ?? const [])
                    if (raw is Map)
                      Builder(builder: (_) {
                        final section = raw.cast<String, dynamic>();
                        final ready =
                            "${section["status"] ?? "ready"}" == "ready";
                        return ListTile(
                          enabled: ready,
                          leading: Icon(
                              ready
                                  ? Icons.play_circle_outline
                                  : Icons.hourglass_top,
                              color: ready ? palette.acc : palette.sub),
                          title: Text("${section["title"] ?? section["id"]}",
                              style: TextStyle(color: palette.text)),
                          subtitle: Text(
                              ready ? "Ready" : "${section["status"]}",
                              style: TextStyle(color: palette.sub)),
                          onTap: ready
                              ? () => _selectSection(course, section)
                              : null,
                        );
                      }),
                ],
              ),
            ),
        ],
      );

  Widget _entry(CoachPalette palette, int index) {
    final entry = _entries[index];
    if (entry.kind == _LessonEntryKind.image ||
        entry.kind == _LessonEntryKind.diagram) {
      final filename = entry.src.split("/").last;
      final raster = RegExp(r"\.(png|jpe?g|webp)$", caseSensitive: false)
          .hasMatch(filename);
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (raster)
            Image.network(
              widget.api.teachingAssetUrl(_sectionId, filename),
              headers: widget.api.authHeaders,
              fit: BoxFit.contain,
              width: double.infinity,
              errorBuilder: (_, __, ___) => const SizedBox(
                  height: 120,
                  child: Center(child: Icon(Icons.broken_image_outlined))),
            )
          else
            Padding(
              padding: const EdgeInsets.all(22),
              child: Row(children: [
                Icon(Icons.schema_outlined, color: palette.acc, size: 34),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                        filename.isEmpty ? "Interactive diagram" : filename,
                        style: TextStyle(color: palette.text))),
              ]),
            ),
          if (entry.caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(entry.caption, style: TextStyle(color: palette.sub)),
            ),
        ]),
      );
    }
    final learner = entry.kind == _LessonEntryKind.learner;
    return Align(
      alignment: learner ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .88),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: learner ? palette.acc.withValues(alpha: .34) : palette.chip,
          borderRadius: BorderRadius.circular(16),
        ),
        child: entry.clip != null && index == _activeEntry
            ? AlignedSpeechText(
                text: entry.text,
                activeWordIndex: _activeWord,
                style: TextStyle(color: palette.text, height: 1.5),
                highlightColor: palette.acc,
                highlightTextColor: palette.bg,
              )
            : SelectableText(entry.text,
                style: TextStyle(color: palette.text, height: 1.45)),
      ),
    );
  }

  Widget _lesson(CoachPalette palette) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 8, 4),
          child: Row(children: [
            IconButton(
                tooltip: "Back to courses",
                onPressed: () async {
                  await _closeSession();
                  if (mounted) setState(() => _section = null);
                },
                icon: const Icon(Icons.arrow_back)),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("${_section?["title"] ?? "Lesson"}",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: palette.text, fontWeight: FontWeight.w800)),
                    Text(_status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: palette.sub, fontSize: 11)),
                  ]),
            ),
            if (_channel == null)
              FilledButton.icon(
                  onPressed: _connecting ? null : _startLesson,
                  icon: _connecting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_sessionFailed ? Icons.refresh : Icons.play_arrow),
                  label: Text(_sessionFailed ? "Retry" : "Start"))
            else ...[
              IconButton(
                tooltip: _paused ? "Resume narration" : "Pause narration",
                onPressed: _playing || _paused ? _togglePause : null,
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
              ),
            ],
            IconButton(
                tooltip: "Teaching actions",
                onPressed: _actions,
                icon: const Icon(Icons.tune)),
          ]),
        ),
        if (_videos.isNotEmpty || _connections.isNotEmpty)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final video in _videos.take(4))
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(Icons.play_circle_outline, size: 17),
                      label: Text("${video["title"] ?? "Related video"}",
                          overflow: TextOverflow.ellipsis),
                      onPressed: () {
                        final id = "${video["video_id"] ?? ""}";
                        if (id.isNotEmpty) {
                          unawaited(launchUrl(
                            Uri.parse("https://www.youtube.com/watch?v=$id"),
                            mode: LaunchMode.externalApplication,
                          ));
                        }
                      },
                    ),
                  ),
                if (((_connections["prerequisites"] as List?) ?? const [])
                    .isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.only(right: 6),
                    child: Chip(
                        avatar: Icon(Icons.account_tree_outlined, size: 17),
                        label: Text("Builds on prior concepts")),
                  ),
                if (((_connections["related"] as List?) ?? const []).isNotEmpty)
                  const Chip(
                      avatar: Icon(Icons.hub_outlined, size: 17),
                      label: Text("Cross-course connections")),
              ],
            ),
          ),
        Expanded(
          child: _entries.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _sessionFailed
                              ? Icons.cloud_off_outlined
                              : Icons.school_outlined,
                          color: _sessionFailed ? Colors.orange : palette.acc,
                          size: 38,
                        ),
                        const SizedBox(height: 10),
                        Text(_status,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: palette.sub)),
                        if (_sessionFailed) ...[
                          const SizedBox(height: 14),
                          FilledButton.tonalIcon(
                            onPressed: _connecting ? null : _startLesson,
                            icon: const Icon(Icons.refresh),
                            label: const Text("Retry lesson stream"),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 8),
                  itemCount: _entries.length,
                  itemBuilder: (_, index) => _entry(palette, index),
                ),
        ),
        if (_awaitingReason == "pause_directive" && !_playing)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: FilledButton.tonalIcon(
              onPressed: _continueLesson,
              icon: const Icon(Icons.play_arrow),
              label: const Text("Continue lesson"),
            ),
          ),
        if (_channel != null)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Container(
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: palette.border),
                ),
                child: Row(children: [
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _question,
                      decoration: const InputDecoration(
                          hintText: "Interrupt or ask at the next pause…",
                          border: InputBorder.none),
                      onSubmitted: _ask,
                    ),
                  ),
                  IconButton(
                    tooltip: _recordingQuestion
                        ? "Finish voice question"
                        : "Ask by voice",
                    onPressed: _toggleQuestionRecording,
                    icon: Icon(_recordingQuestion ? Icons.stop : Icons.mic_none,
                        color: _recordingQuestion
                            ? Colors.redAccent
                            : palette.sub),
                  ),
                  IconButton.filled(
                      onPressed: () => _ask(_question.text),
                      icon: const Icon(Icons.arrow_upward)),
                  const SizedBox(width: 4),
                ]),
              ),
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final palette = CoachThemeScope.of(context).ambientPalette;
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: palette.acc));
    }
    return _section == null ? _library(palette) : _lesson(palette);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_closeSession());
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _questionAmplitudeSubscription?.cancel();
    _bargeAmplitudeSubscription?.cancel();
    _question.dispose();
    _scroll.dispose();
    _questionRecorder.dispose();
    _bargeRecorder.dispose();
    _player.dispose();
    super.dispose();
  }
}
