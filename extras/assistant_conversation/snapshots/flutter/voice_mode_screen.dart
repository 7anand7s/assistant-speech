import "dart:async";
import "dart:io";

import "package:audioplayers/audioplayers.dart";
import "package:flutter/material.dart";
import "package:path_provider/path_provider.dart";
import "package:record/record.dart";
import "package:wakelock_plus/wakelock_plus.dart";

import "../api/api_client.dart";
import "../theme.dart";
import "../voice/aligned_speech_text.dart";
import "../voice/assistant_router_commands.dart";
import "../voice/conversation_controller.dart";
import "../voice/speech_clip.dart";

class AssistantRouterReturn {
  const AssistantRouterReturn();
}

/// Speaking mode — the hands-free, Alexa-style conversation screen (plan V1).
/// A thin shell: real mic/player/wakelock wired into [ConversationController];
/// all the loop logic lives (and is tested) in the controller.
///
/// Works for **every** agent, not just the coach. Which one it talks to is the
/// injected [sendVoice] — the loop itself never knew about the coach, but this
/// screen used to hardcode `api.chatVoice`, so the headphones button answered
/// in the coach's voice even when you were standing in the Docs or Jaap tab.
class VoiceModeScreen extends StatefulWidget {
  final ApiClient api;

  /// Screen title, e.g. "Speaking to Docs".
  final String title;

  /// Short agent name used in captions ("the archive", "Jaap").
  final String agentLabel;

  /// One hands-free turn for the agent this session belongs to. Defaults to
  /// the coach so existing callers and tests keep working.
  final Future<VoiceTurn> Function(String path)? sendVoice;

  /// Coach-only Assistant STT seam and selected opaque thread. Supplying both
  /// enables the resumable run/SSE/automatic-speech contract. Other agents
  /// continue using their existing [sendVoice] adapters unchanged.
  final CoachSpeechTranscriber? coachTranscriber;
  final String? coachThreadId;

  /// Jaap v6 uses the same Assistant STT service, but consumes Jaap's durable
  /// event log and generation-bound cancellation instead of Coach SSE.
  final CoachSpeechTranscriber? jaapTranscriber;
  final String? jaapThreadId;
  final int? jaapThreadVersion;

  /// Accepted standalone agents share the same Assistant-owned STT/TTS loop.
  /// Their producer-specific transports are normalized to public durable
  /// lifecycle events before entering the conversation controller.
  final CoachSpeechTranscriber? durableTranscriber;
  final Future<String> Function(String transcript)? durableSubmit;
  final Future<DurableVoicePoll> Function(String runId, int afterSequence)?
      durablePoll;
  final Future<void> Function(String runId)? durableCancel;

  /// What to say while the agent is working. Agent-specific because the honest
  /// answer differs by an order of magnitude: the coach is usually seconds,
  /// a Jaap pipeline run is minutes, and a silent screen that under-promises
  /// reads as broken.
  final String thinkingHint;

  const VoiceModeScreen({
    super.key,
    required this.api,
    this.title = "Coach Mode",
    this.agentLabel = "the coach",
    this.sendVoice,
    this.coachTranscriber,
    this.coachThreadId,
    this.jaapTranscriber,
    this.jaapThreadId,
    this.jaapThreadVersion,
    this.durableTranscriber,
    this.durableSubmit,
    this.durablePoll,
    this.durableCancel,
    this.thinkingHint = "Thinking… (a cold start can take a minute)",
  });

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen> {
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  final _amplitudes = StreamController<double>.broadcast();
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<Amplitude>? _bargeAmpSub;
  StreamSubscription<Duration>? _speechPositionSub;
  ConversationController? _controllerOrNull;
  ConversationController get _controller => _controllerOrNull!;
  CoachHandsFreeTurnRunner? _coachRunner;
  JaapHandsFreeTurnRunner? _jaapRunner;
  DurableAgentHandsFreeTurnRunner? _durableRunner;
  Completer<void>? _playInterrupted;
  Completer<void>? _bargeCaptureDone;
  Timer? _bargeMaximum;
  String? _pendingBargePath;
  bool _bargeTriggered = false;
  bool _playbackPaused = false;
  final ValueNotifier<AssistantSpeechProgress> _speechProgress =
      ValueNotifier(const AssistantSpeechProgress());

  bool get _coachSpeechUnavailable =>
      widget.coachThreadId != null && widget.coachTranscriber == null;
  bool get _jaapSpeechUnavailable =>
      widget.jaapThreadId != null && widget.jaapTranscriber == null;
  bool get _durableSpeechUnavailable =>
      widget.durableSubmit != null && widget.durableTranscriber == null;

  Future<VoiceTurn> _unavailableCoachTurn(String _) async => VoiceTurn(
        ok: false,
        transcript: "",
        reply:
            "Hands-free Coach needs the Assistant speech service on this build.",
        transparency: "",
        audioBytes: [],
      );

  Future<VoiceTurn> _unavailableJaapTurn(String _) async => VoiceTurn(
        ok: false,
        transcript: "",
        reply:
            "Hands-free Jaap needs the Assistant speech service on this build.",
        transparency: "",
        audioBytes: [],
      );

  Future<VoiceTurn> _unavailableDurableTurn(String _) async => VoiceTurn(
        ok: false,
        transcript: "",
        reply:
            "Hands-free ${widget.agentLabel} needs the Assistant speech service on this build.",
        transparency: "",
        audioBytes: [],
      );

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  void _setSpeechClip(AssistantSpeechClip clip) {
    _speechProgress.value = AssistantSpeechProgress(clip: clip);
  }

  Future<List<int>> _alignedSentence(String sentence) async {
    final clip = await widget.api.speakAligned(sentence, realtime: true);
    _setSpeechClip(clip);
    return clip.audioBytes;
  }

  Future<List<int>> _alignedCoachEvent(
    String runId,
    int sequence,
  ) async {
    final clip = await widget.api.coachRunSpeechAligned(
      runId,
      eventSequence: sequence,
    );
    _setSpeechClip(clip);
    return clip.audioBytes;
  }

  Future<VoiceTurn> _alignedLegacyTurn(
    Future<VoiceTurn> Function(String path) send,
    String path,
    bool automaticSpeech,
  ) async {
    final turn = await send(path);
    if (!automaticSpeech || turn.reply.trim().isEmpty) return turn;
    final clip = await widget.api.speakAligned(turn.reply, realtime: true);
    _setSpeechClip(clip);
    return VoiceTurn(
      ok: turn.ok,
      transcript: turn.transcript,
      reply: turn.reply,
      transparency: turn.transparency,
      audioBytes: clip.audioBytes,
    );
  }

  CoachSpeechTranscriber _routeAware(CoachSpeechTranscriber transcriber) {
    return (path, mode) async {
      final transcript = (await transcriber(path, mode)).trim();
      if (isAssistantRouterRequest(transcript)) {
        await _returnToRouter();
        return "";
      }
      return transcript;
    };
  }

  Future<void> _returnToRouter() async {
    await _controllerOrNull?.stop();
    if (mounted) Navigator.of(context).pop(const AssistantRouterReturn());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controllerOrNull != null) return; // build once
    // Settings' "Input sensitivity": Low (0.5) raises the speech threshold
    // (needs a louder voice), High (1.5) lowers it. Medium = the tuned -40 dBFS.
    // Read here (not initState) — inherited widgets aren't available earlier.
    final sens = CoachThemeScope.of(context).inputSensitivity;
    final threshold = sens < 0.75
        ? -34.0
        : sens > 1.25
            ? -46.0
            : -40.0;
    final transcriber = widget.coachTranscriber == null
        ? null
        : _routeAware(widget.coachTranscriber!);
    final coachThreadId = widget.coachThreadId;
    final automaticSpeech = CoachThemeScope.of(context).autoplayVoice;
    if (transcriber != null && coachThreadId != null) {
      _coachRunner = CoachHandsFreeTurnRunner(
        transcribe: transcriber,
        submit: (transcript) => widget.api.coachSubmitRun(
          text: transcript,
          threadId: coachThreadId,
          origin: "hands_free",
          clientRequestId: ApiClient.newClientRequestId(),
        ),
        events: widget.api.coachRunEvents,
        speech: automaticSpeech
            ? _alignedCoachEvent
            : (runId, sequence) async => const [],
        play: _play,
        cancelRun: (runId) async {
          await widget.api.coachCancelRun(runId);
        },
        stopPlayback: _stopPlayback,
      );
    }
    final jaapTranscriber = widget.jaapTranscriber == null
        ? null
        : _routeAware(widget.jaapTranscriber!);
    final jaapThreadId = widget.jaapThreadId;
    if (jaapTranscriber != null &&
        jaapThreadId != null &&
        jaapThreadId.isNotEmpty &&
        widget.jaapThreadVersion != null) {
      _jaapRunner = JaapHandsFreeTurnRunner(
        threadVersion: widget.jaapThreadVersion!,
        transcribe: jaapTranscriber,
        submit: (transcript, expectedVersion) async {
          final result = await widget.api.jappThreadTurn(
            jaapThreadId,
            transcript,
            expectedVersion: expectedVersion,
          );
          final raw = result["turn"];
          if (result["ok"] != true || raw is! Map) {
            throw StateError("Jaap did not accept the durable turn");
          }
          final turn = raw.cast<String, dynamic>();
          return JaapVoiceRun(
            turnId: "${turn["id"] ?? ""}",
            turnVersion: (turn["version"] as num?)?.toInt() ?? 1,
            generation: (turn["generation"] as num?)?.toInt() ?? 1,
          );
        },
        eventLog: (turnId, afterSequence, spokenAfter) =>
            widget.api.jappTurnEvents(
          turnId,
          afterSequence: afterSequence,
          spokenAfter: spokenAfter,
        ),
        turnStatus: widget.api.jappTurn,
        speech:
            automaticSpeech ? _alignedSentence : (sentence) async => const [],
        play: _play,
        cancelTurn: (turnId, expectedVersion, generation) async {
          await widget.api.jappCancelTurn(
            turnId,
            expectedVersion: expectedVersion,
            generation: generation,
          );
        },
        stopPlayback: _stopPlayback,
      );
    }
    final durableTranscriber = widget.durableTranscriber == null
        ? null
        : _routeAware(widget.durableTranscriber!);
    final durableSubmit = widget.durableSubmit;
    final durablePoll = widget.durablePoll;
    final durableCancel = widget.durableCancel;
    if (durableTranscriber != null &&
        durableSubmit != null &&
        durablePoll != null &&
        durableCancel != null) {
      _durableRunner = DurableAgentHandsFreeTurnRunner(
        transcribe: durableTranscriber,
        submit: durableSubmit,
        poll: durablePoll,
        speech:
            automaticSpeech ? _alignedSentence : (sentence) async => const [],
        play: _play,
        cancelRun: durableCancel,
        stopPlayback: _stopPlayback,
      );
    }
    final legacySend = _coachSpeechUnavailable
        ? _unavailableCoachTurn
        : _jaapSpeechUnavailable
            ? _unavailableJaapTurn
            : _durableSpeechUnavailable
                ? _unavailableDurableTurn
                : widget.sendVoice ?? widget.api.chatVoice;
    _controllerOrNull = ConversationController(
      startRecording: _startRecording,
      stopRecording: _stopRecording,
      amplitudeStream: _amplitudes.stream,
      // A Coach screen with an opaque thread ID is the new global-speech
      // contract. If Assistant STT was not injected, fail closed instead of
      // silently falling back to the legacy endpoint that also runs the agent.
      sendVoice: (path) =>
          _alignedLegacyTurn(legacySend, path, automaticSpeech),
      play: _play,
      sendStreamingVoice:
          _coachRunner?.run ?? _jaapRunner?.run ?? _durableRunner?.run,
      cancelStreamingVoice:
          _coachRunner?.cancel ?? _jaapRunner?.cancel ?? _durableRunner?.cancel,
      takeBargeInRecording: _takeBargeInRecording,
      agentLabel: widget.agentLabel,
      speechThresholdDb: threshold,
      // Calibrate to THIS phone's noise floor each listen — fixed thresholds
      // proved wrong on real hardware (never-ending listening).
      adaptiveThreshold: true,
    );
    if (_coachSpeechUnavailable ||
        _jaapSpeechUnavailable ||
        _durableSpeechUnavailable) {
      _controller.endReason.value = _coachSpeechUnavailable
          ? "Hands-free Coach needs the Assistant speech service on this build."
          : _jaapSpeechUnavailable
              ? "Hands-free Jaap needs the Assistant speech service on this build."
              : "Hands-free ${widget.agentLabel} needs the Assistant speech service on this build.";
    } else {
      _begin();
    }
  }

  Future<void> _begin() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Microphone permission was denied.")),
      );
      Navigator.of(context).pop();
      return;
    }
    _controller.start();
  }

  Future<void> _startRecording() async {
    final dir = await getTemporaryDirectory();
    final path =
        "${dir.path}${Platform.pathSeparator}turn_${DateTime.now().millisecondsSinceEpoch}.m4a";
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((a) => _amplitudes.add(a.current));
  }

  Future<String?> _stopRecording() async {
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      return await _recorder.stop();
    } catch (_) {
      return null;
    }
  }

  Future<void> _play(List<int> bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File(
      "${dir.path}${Platform.pathSeparator}say_${DateTime.now().millisecondsSinceEpoch}.mp3",
    );
    await f.writeAsBytes(bytes, flush: true);
    final completed = _player.onPlayerComplete.first;
    final interrupted = Completer<void>();
    _playInterrupted = interrupted;
    try {
      _speechPositionSub = _player.onPositionChanged.listen((position) {
        final progress = _speechProgress.value;
        final words = progress.clip?.words ?? const <AssistantWordTiming>[];
        if (words.isEmpty) return;
        var active = words.lastIndexWhere(
          (word) => position.inMilliseconds >= word.startMs,
        );
        if (active >= 0 &&
            active == words.length - 1 &&
            position.inMilliseconds > words[active].endMs) {
          active = -1;
        }
        if (active != progress.activeWordIndex) {
          _speechProgress.value = AssistantSpeechProgress(
            clip: progress.clip,
            activeWordIndex: active,
            paused: _playbackPaused,
          );
        }
      });
      await _startBargeCapture();
      await _player.play(DeviceFileSource(f.path));
      await Future.any([completed, interrupted.future]);
      if (_bargeTriggered && _bargeCaptureDone != null) {
        await _bargeCaptureDone!.future;
      }
    } finally {
      if (identical(_playInterrupted, interrupted)) _playInterrupted = null;
      await _speechPositionSub?.cancel();
      _speechPositionSub = null;
      await _stopBargeCapture(discard: !_bargeTriggered);
      _playbackPaused = false;
      _speechProgress.value = const AssistantSpeechProgress();
      try {
        await f.delete();
      } catch (_) {
        // temp cleanup is best-effort
      }
    }
  }

  Future<void> _startBargeCapture() async {
    if (await _recorder.isRecording() || !await _recorder.hasPermission()) {
      return;
    }
    final dir = await getTemporaryDirectory();
    final path =
        "${dir.path}${Platform.pathSeparator}barge_${DateTime.now().millisecondsSinceEpoch}.m4a";
    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
        path: path,
      );
    } catch (_) {
      return; // Device cannot record and play concurrently; playback still works.
    }
    _bargeTriggered = false;
    _bargeCaptureDone = Completer<void>();
    final started = DateTime.now();
    final floor = <double>[];
    double threshold = -40;
    DateTime? loudSince;
    DateTime? lastLoud;
    _bargeAmpSub = _recorder
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
          if (!(_playInterrupted?.isCompleted ?? true)) {
            _playInterrupted!.complete();
          }
          unawaited(_player.stop());
          unawaited(_controller.bargeIn());
          _controller.activity.value = "Interrupted — listening to you…";
        }
        return;
      }
      loudSince = null;
      if (_bargeTriggered &&
          lastLoud != null &&
          now.difference(lastLoud!) >= const Duration(milliseconds: 700)) {
        unawaited(_finishBargeCapture(path));
      }
    });
    _bargeMaximum = Timer(const Duration(seconds: 20), () {
      if (_bargeTriggered) unawaited(_finishBargeCapture(path));
    });
  }

  Future<void> _finishBargeCapture(String path) async {
    if (_bargeCaptureDone?.isCompleted ?? true) return;
    await _bargeAmpSub?.cancel();
    _bargeAmpSub = null;
    _bargeMaximum?.cancel();
    String? captured;
    try {
      captured = await _recorder.stop();
    } catch (_) {}
    _pendingBargePath = captured ?? path;
    _bargeCaptureDone!.complete();
  }

  Future<void> _stopBargeCapture({required bool discard}) async {
    _bargeMaximum?.cancel();
    _bargeMaximum = null;
    await _bargeAmpSub?.cancel();
    _bargeAmpSub = null;
    String? path;
    try {
      if (await _recorder.isRecording()) path = await _recorder.stop();
    } catch (_) {}
    if (!(_bargeCaptureDone?.isCompleted ?? true)) {
      if (!discard && path != null) _pendingBargePath = path;
      _bargeCaptureDone!.complete();
    }
    if (discard && path != null) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    _bargeCaptureDone = null;
  }

  Future<String?> _takeBargeInRecording() async {
    final path = _pendingBargePath;
    _pendingBargePath = null;
    _bargeTriggered = false;
    return path;
  }

  Future<void> _togglePlaybackPause() async {
    if (_controller.state.value != ConversationState.speaking) return;
    if (_playbackPaused) {
      await _player.resume();
      _playbackPaused = false;
    } else {
      await _player.pause();
      _playbackPaused = true;
    }
    final progress = _speechProgress.value;
    _speechProgress.value = AssistantSpeechProgress(
      clip: progress.clip,
      activeWordIndex: progress.activeWordIndex,
      paused: _playbackPaused,
    );
  }

  Future<void> _stopPlayback() async {
    if (!(_playInterrupted?.isCompleted ?? true)) {
      _playInterrupted!.complete();
    }
    _playbackPaused = false;
    await _player.stop();
  }

  Future<void> _endConversation() async {
    await _controller.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.stop();
    _ampSub?.cancel();
    _bargeAmpSub?.cancel();
    _speechPositionSub?.cancel();
    _bargeMaximum?.cancel();
    _amplitudes.close();
    _speechProgress.dispose();
    _recorder.dispose();
    _player.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: "Back to Assistant router",
            onPressed: _returnToRouter,
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            ValueListenableBuilder<ConversationState>(
              valueListenable: _controller.state,
              // Tap the orb while listening → send immediately (manual
              // override when silence detection misjudges the mic).
              builder: (context, s, _) => GestureDetector(
                onTap: _controller.endUtterance,
                child: _Orb(state: s),
              ),
            ),
            ValueListenableBuilder<AssistantSpeechProgress>(
              valueListenable: _speechProgress,
              builder: (context, progress, _) {
                final clip = progress.clip;
                if (clip == null || clip.text.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(children: [
                      Expanded(
                        child: AlignedSpeechText(
                          text: clip.text,
                          activeWordIndex: progress.activeWordIndex,
                          style: TextStyle(
                            color: scheme.onSurface,
                            height: 1.45,
                          ),
                          highlightColor: scheme.primary,
                          highlightTextColor: scheme.onPrimary,
                        ),
                      ),
                      IconButton(
                        tooltip: progress.paused ? "Resume" : "Pause",
                        onPressed: _togglePlaybackPause,
                        icon: Icon(
                          progress.paused ? Icons.play_arrow : Icons.pause,
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<ConversationState>(
              valueListenable: _controller.state,
              builder: (context, s, _) => Text(
                switch (s) {
                  ConversationState.listening =>
                    "Listening… talk, pause — or tap the orb to send",
                  ConversationState.thinking => widget.thinkingHint,
                  ConversationState.speaking => "Speaking",
                  ConversationState.idle => "",
                },
                style: TextStyle(color: scheme.outline),
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: _controller.endReason,
              builder: (context, reason, _) => reason == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.all(8),
                      child:
                          Text(reason, style: TextStyle(color: scheme.primary)),
                    ),
            ),
            ValueListenableBuilder<String>(
              valueListenable: _controller.activity,
              builder: (context, activity, _) => activity.isEmpty
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Text(activity,
                          style: TextStyle(color: scheme.tertiary)),
                    ),
            ),
            Expanded(
              child: ValueListenableBuilder<List<Caption>>(
                valueListenable: _controller.captions,
                builder: (context, caps, _) => ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: caps.length,
                  itemBuilder: (context, i) {
                    final c = caps[caps.length - 1 - i];
                    return Align(
                      alignment: c.fromUser
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: c.fromUser
                              ? scheme.primary
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          c.text,
                          style: TextStyle(
                            color: c.fromUser
                                ? scheme.onPrimary
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.tonalIcon(
                onPressed: _endConversation,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text("End conversation"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The status orb: colour + gentle pulse per state.
class _Orb extends StatefulWidget {
  final ConversationState state;
  const _Orb({required this.state});

  @override
  State<_Orb> createState() => _OrbState();
}

class _OrbState extends State<_Orb> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.85,
    upperBound: 1.0,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (widget.state) {
      ConversationState.listening => scheme.primary,
      ConversationState.thinking => scheme.tertiary,
      ConversationState.speaking => scheme.secondary,
      ConversationState.idle => scheme.outlineVariant,
    };
    final icon = switch (widget.state) {
      ConversationState.listening => Icons.mic,
      ConversationState.thinking => Icons.more_horiz,
      ConversationState.speaking => Icons.graphic_eq,
      ConversationState.idle => Icons.mic_off,
    };
    return ScaleTransition(
      scale: _pulse,
      child: Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.18),
          border: Border.all(color: color, width: 3),
        ),
        child: Icon(icon, size: 48, color: color),
      ),
    );
  }
}
