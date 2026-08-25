import "dart:async";

import "package:flutter/foundation.dart";

import "../api/api_client.dart";

/// The states of a hands-free coach conversation (docs/plan/alexa-mode.md §2).
enum ConversationState { idle, listening, thinking, speaking }

/// One line of the live caption feed.
class Caption {
  final String text;
  final bool fromUser;
  Caption(this.text, {required this.fromUser});
}

enum CoachSpeechInputMode { dictation, handsFree }

/// Assistant-owned STT is injected at the Coach boundary. Coach never falls
/// back to `/api/chat/voice` for dictation because that endpoint also runs the
/// agent and would silently auto-send editable composer input.
typedef CoachSpeechTranscriber = Future<String> Function(
  String path,
  CoachSpeechInputMode mode,
);

class CoachDictationController {
  final CoachSpeechTranscriber transcribe;
  final void Function(String finalTranscript) populateComposer;

  const CoachDictationController({
    required this.transcribe,
    required this.populateComposer,
  });

  /// Produces editable composer text only. There is deliberately no submit
  /// callback in this class, making auto-send impossible by construction.
  Future<String> accept(String path) async {
    final transcript =
        (await transcribe(path, CoachSpeechInputMode.dictation)).trim();
    if (transcript.isNotEmpty) populateComposer(transcript);
    return transcript;
  }
}

class StreamingVoiceTurn {
  final bool ok;
  final String transcript;
  final String reply;

  const StreamingVoiceTurn({
    required this.ok,
    required this.transcript,
    required this.reply,
  });
}

class StreamingVoiceCallbacks {
  final void Function(String transcript) onTranscript;
  final void Function(String delta) onAnswerDelta;
  final void Function(String activity) onActivity;
  final void Function() onSpeaking;

  const StreamingVoiceCallbacks({
    required this.onTranscript,
    required this.onAnswerDelta,
    required this.onActivity,
    required this.onSpeaking,
  });
}

typedef StreamingVoiceSender = Future<StreamingVoiceTurn> Function(
  String path,
  StreamingVoiceCallbacks callbacks,
);

/// Coach-only streaming turn runner. Transport, TTS and playback are injected
/// so replay, cancellation and filtering are deterministic in unit tests.
class CoachHandsFreeTurnRunner {
  final CoachSpeechTranscriber transcribe;
  final Future<CoachRun> Function(String transcript) submit;
  final Stream<CoachRunEvent> Function(String runId) events;
  final Future<List<int>> Function(String runId, int eventSequence) speech;
  final Future<void> Function(List<int> bytes) play;
  final Future<void> Function(String runId) cancelRun;
  final Future<void> Function() stopPlayback;

  StreamIterator<CoachRunEvent>? _iterator;
  String? _activeRunId;
  int _generation = 0;

  CoachHandsFreeTurnRunner({
    required this.transcribe,
    required this.submit,
    required this.events,
    required this.speech,
    required this.play,
    required this.cancelRun,
    required this.stopPlayback,
  });

  String? get activeRunId => _activeRunId;

  Future<StreamingVoiceTurn> run(
    String path,
    StreamingVoiceCallbacks callbacks,
  ) async {
    final generation = ++_generation;
    final transcript =
        (await transcribe(path, CoachSpeechInputMode.handsFree)).trim();
    if (generation != _generation || transcript.isEmpty) {
      return StreamingVoiceTurn(
        ok: false,
        transcript: transcript,
        reply: "",
      );
    }
    callbacks.onTranscript(transcript);
    final run = await submit(transcript);
    if (generation != _generation) {
      await cancelRun(run.runId);
      return StreamingVoiceTurn(ok: false, transcript: transcript, reply: "");
    }
    _activeRunId = run.runId;
    var lastSequence = 0;
    var answer = "";
    var ok = true;
    final iterator = StreamIterator(events(run.runId));
    _iterator = iterator;
    try {
      while (generation == _generation && await iterator.moveNext()) {
        final event = iterator.current;
        // SSE reconnects replay from Last-Event-ID, but this second guard is
        // cheap insurance against a proxy repeating the boundary event.
        if (event.sequence <= lastSequence) continue;
        lastSequence = event.sequence;
        switch (event.type) {
          case "answer.delta":
            final delta = "${event.data["text"] ?? ""}";
            if (delta.isNotEmpty) {
              answer += delta;
              callbacks.onAnswerDelta(delta);
            }
            // Never send arbitrary client text to TTS. The event sequence lets
            // Coach validate answer.delta and derive/filter speakable content.
            final bytes = await speech(run.runId, event.sequence);
            if (generation != _generation) break;
            if (bytes.isNotEmpty) {
              callbacks.onSpeaking();
              await play(bytes);
            }
          case "activity":
            final activity = "${event.data["message"] ?? ""}".trim();
            if (activity.isNotEmpty) callbacks.onActivity(activity);
          case "run.failed":
            ok = false;
          case "run.cancelled":
            ok = false;
        }
        if (event.terminal) break;
      }
    } finally {
      if (identical(_iterator, iterator)) _iterator = null;
      if (_activeRunId == run.runId) _activeRunId = null;
      await iterator.cancel();
    }
    return StreamingVoiceTurn(
      ok: ok && generation == _generation,
      transcript: transcript,
      reply: answer,
    );
  }

  Future<void> cancel() async {
    _generation += 1;
    final runId = _activeRunId;
    _activeRunId = null;
    await _iterator?.cancel();
    _iterator = null;
    await stopPlayback();
    if (runId != null) await cancelRun(runId);
  }
}

class JaapVoiceRun {
  final String turnId;
  final int turnVersion;
  final int generation;

  const JaapVoiceRun({
    required this.turnId,
    required this.turnVersion,
    required this.generation,
  });
}

/// Normalized public lifecycle used by standalone agents in hands-free mode.
/// Producer-specific event names are adapted at the HTTP boundary; this class
/// never receives citations, actions, tool payloads or private reasoning.
class DurableVoicePoll {
  final int sequence;
  final String answerDelta;
  final String finalAnswer;
  final List<String> speakable;
  final String activity;
  final bool terminal;
  final bool succeeded;

  const DurableVoicePoll({
    required this.sequence,
    this.answerDelta = "",
    this.finalAnswer = "",
    this.speakable = const [],
    this.activity = "",
    this.terminal = false,
    this.succeeded = true,
  });
}

/// Shared durable STT → producer run → public events → global TTS loop.
///
/// Informant, Docs, Garage and Research all use this runner. Their adapters
/// normalize only public answer/activity/speakable events, keeping sources,
/// actions and tool details out of hands-free speech by construction.
class DurableAgentHandsFreeTurnRunner {
  final CoachSpeechTranscriber transcribe;
  final Future<String> Function(String transcript) submit;
  final Future<DurableVoicePoll> Function(String runId, int afterSequence) poll;
  final Future<List<int>> Function(String sentence) speech;
  final Future<void> Function(List<int> bytes) play;
  final Future<void> Function(String runId) cancelRun;
  final Future<void> Function() stopPlayback;
  final Duration pollEvery;

  int _generation = 0;
  String? _activeRunId;

  DurableAgentHandsFreeTurnRunner({
    required this.transcribe,
    required this.submit,
    required this.poll,
    required this.speech,
    required this.play,
    required this.cancelRun,
    required this.stopPlayback,
    this.pollEvery = const Duration(milliseconds: 700),
  });

  Future<StreamingVoiceTurn> run(
    String path,
    StreamingVoiceCallbacks callbacks,
  ) async {
    final generation = ++_generation;
    final transcript =
        (await transcribe(path, CoachSpeechInputMode.handsFree)).trim();
    if (generation != _generation || transcript.isEmpty) {
      return StreamingVoiceTurn(ok: false, transcript: transcript, reply: "");
    }
    callbacks.onTranscript(transcript);
    final runId = (await submit(transcript)).trim();
    if (runId.isEmpty) {
      throw StateError("producer did not return a durable run id");
    }
    if (generation != _generation) {
      await cancelRun(runId);
      return StreamingVoiceTurn(ok: false, transcript: transcript, reply: "");
    }
    _activeRunId = runId;
    var sequence = 0;
    var answer = "";
    var succeeded = true;
    try {
      while (generation == _generation) {
        final next = await poll(runId, sequence);
        if (next.sequence > sequence) sequence = next.sequence;
        if (next.answerDelta.isNotEmpty) {
          answer += next.answerDelta;
          callbacks.onAnswerDelta(next.answerDelta);
        }
        if (next.finalAnswer.isNotEmpty && next.finalAnswer != answer) {
          final delta = next.finalAnswer.startsWith(answer)
              ? next.finalAnswer.substring(answer.length)
              : next.finalAnswer;
          if (delta.isNotEmpty) callbacks.onAnswerDelta(delta);
          answer = next.finalAnswer;
        }
        if (next.activity.isNotEmpty) callbacks.onActivity(next.activity);
        for (final sentence in next.speakable) {
          if (generation != _generation || sentence.trim().isEmpty) break;
          final bytes = await speech(sentence.trim());
          if (generation != _generation) break;
          if (bytes.isNotEmpty) {
            callbacks.onSpeaking();
            await play(bytes);
          }
        }
        if (next.terminal) {
          succeeded = next.succeeded;
          break;
        }
        await Future<void>.delayed(pollEvery);
      }
    } finally {
      if (_activeRunId == runId) _activeRunId = null;
    }
    return StreamingVoiceTurn(
      ok: succeeded && generation == _generation,
      transcript: transcript,
      reply: answer,
    );
  }

  Future<void> cancel() async {
    _generation += 1;
    final runId = _activeRunId;
    _activeRunId = null;
    await stopPlayback();
    if (runId != null) await cancelRun(runId);
  }
}

/// Jaap v6 hands-free runner. It consumes the same durable JSON event log as
/// chat mode, deduplicates reconnect replay by sequence/spoken offset, and
/// synthesizes only producer-approved `speech.sentence` payloads. Cancellation
/// is bound to both the current turn version and generation, so barge-in cannot
/// accidentally stop a newer run.
class JaapHandsFreeTurnRunner {
  final CoachSpeechTranscriber transcribe;
  final Future<JaapVoiceRun> Function(String transcript, int threadVersion)
      submit;
  final Future<Map<String, dynamic>> Function(
      String turnId, int afterSequence, int spokenAfter) eventLog;
  final Future<Map<String, dynamic>> Function(String turnId) turnStatus;
  final Future<List<int>> Function(String sentence) speech;
  final Future<void> Function(List<int> bytes) play;
  final Future<void> Function(
      String turnId, int expectedVersion, int generation) cancelTurn;
  final Future<void> Function() stopPlayback;
  final Duration pollEvery;

  int _threadVersion;
  int _runGeneration = 0;
  String? _activeTurnId;
  int _activeTurnVersion = 1;
  int _activeTurnGeneration = 1;

  JaapHandsFreeTurnRunner({
    required int threadVersion,
    required this.transcribe,
    required this.submit,
    required this.eventLog,
    required this.turnStatus,
    required this.speech,
    required this.play,
    required this.cancelTurn,
    required this.stopPlayback,
    this.pollEvery = const Duration(milliseconds: 700),
  }) : _threadVersion = threadVersion;

  Future<StreamingVoiceTurn> run(
    String path,
    StreamingVoiceCallbacks callbacks,
  ) async {
    final localGeneration = ++_runGeneration;
    final transcript =
        (await transcribe(path, CoachSpeechInputMode.handsFree)).trim();
    if (localGeneration != _runGeneration || transcript.isEmpty) {
      return StreamingVoiceTurn(ok: false, transcript: transcript, reply: "");
    }
    callbacks.onTranscript(transcript);
    final started = await submit(transcript, _threadVersion);
    if (localGeneration != _runGeneration) {
      await cancelTurn(started.turnId, started.turnVersion, started.generation);
      return StreamingVoiceTurn(ok: false, transcript: transcript, reply: "");
    }
    _threadVersion += 1;
    _activeTurnId = started.turnId;
    _activeTurnVersion = started.turnVersion;
    _activeTurnGeneration = started.generation;
    var sequence = 0;
    var spokenOffset = 0;
    var answer = "";
    var ok = true;
    try {
      while (localGeneration == _runGeneration) {
        final log = await eventLog(started.turnId, sequence, spokenOffset);
        final events = (log["events"] as List?) ?? const [];
        for (final raw in events) {
          if (raw is! Map) continue;
          final event = raw.cast<String, dynamic>();
          final nextSequence = (event["sequence"] as num?)?.toInt() ?? 0;
          if (nextSequence <= sequence) continue;
          sequence = nextSequence;
          final type = "${event["event_type"] ?? ""}";
          final payload = event["payload"] is Map
              ? (event["payload"] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          if (type == "text.delta") {
            final delta = "${payload["text"] ?? ""}";
            if (delta.isNotEmpty) {
              answer += delta;
              callbacks.onAnswerDelta(delta);
            }
          } else if (type == "text.final") {
            final finalText = "${payload["text"] ?? ""}";
            if (finalText.startsWith(answer)) {
              final delta = finalText.substring(answer.length);
              if (delta.isNotEmpty) callbacks.onAnswerDelta(delta);
            }
            if (finalText.isNotEmpty) answer = finalText;
          } else if (type == "speech.sentence") {
            final offset = (payload["spoken_offset"] as num?)?.toInt() ?? 0;
            if (offset <= spokenOffset) continue;
            spokenOffset = offset;
            final sentence = "${payload["text"] ?? ""}".trim();
            if (sentence.isEmpty) continue;
            final bytes = await speech(sentence);
            if (localGeneration != _runGeneration) break;
            if (bytes.isNotEmpty) {
              callbacks.onSpeaking();
              await play(bytes);
            }
          } else if (type == "activity" ||
              type == "tool.started" ||
              type == "tool.finished" ||
              type == "queue.updated") {
            final label =
                "${payload["label"] ?? payload["state"] ?? type}".trim();
            if (label.isNotEmpty) callbacks.onActivity(label);
          }
        }
        if (localGeneration != _runGeneration) break;
        final statusResponse = await turnStatus(started.turnId);
        final rawTurn = statusResponse["turn"];
        if (rawTurn is Map) {
          final turn = rawTurn.cast<String, dynamic>();
          _activeTurnVersion =
              (turn["version"] as num?)?.toInt() ?? _activeTurnVersion;
          _activeTurnGeneration =
              (turn["generation"] as num?)?.toInt() ?? _activeTurnGeneration;
          final status = "${turn["status"] ?? ""}";
          if (status != "accepted" && status != "running") {
            ok = status == "completed";
            break;
          }
        }
        await Future<void>.delayed(pollEvery);
      }
    } finally {
      if (_activeTurnId == started.turnId) _activeTurnId = null;
    }
    return StreamingVoiceTurn(
      ok: ok && localGeneration == _runGeneration,
      transcript: transcript,
      reply: answer,
    );
  }

  Future<void> cancel() async {
    _runGeneration += 1;
    final turnId = _activeTurnId;
    final version = _activeTurnVersion;
    final generation = _activeTurnGeneration;
    _activeTurnId = null;
    await stopPlayback();
    if (turnId != null) await cancelTurn(turnId, version, generation);
  }
}

/// The Alexa-style conversation loop as a PLAIN state machine — every side
/// effect (mic, upload, playback, clock) is injected, so the whole loop is
/// unit-testable with fakes and the UI is a thin observer.
///
/// Loop: listening —(silence after speech)→ thinking —(reply)→ speaking —→
/// listening again. Exits: [stop], an exit phrase in the transcript, too many
/// empty turns, or the session cap.
class ConversationController {
  ConversationController({
    required this.startRecording,
    required this.stopRecording,
    required this.amplitudeStream,
    required this.sendVoice,
    required this.play,
    this.sendStreamingVoice,
    this.cancelStreamingVoice,
    this.takeBargeInRecording,
    DateTime Function()? now,
    // --- tunables (see plan §2; override in tests) ---
    this.speechThresholdDb = -40.0,
    this.silenceAfterSpeech = const Duration(milliseconds: 1200),
    this.minUtterance = const Duration(milliseconds: 500),
    this.maxUtterance = const Duration(seconds: 20),
    this.noSpeechTimeout = const Duration(seconds: 8),
    this.sessionCap = const Duration(minutes: 10),
    this.maxEmptyTurns = 3,
    this.postPlaybackGrace = const Duration(milliseconds: 250),
    this.adaptiveThreshold = false,
    this.agentLabel = "the coach",
  }) : _now = now ?? DateTime.now;

  // ---- injected effects ----
  final Future<void> Function() startRecording;

  /// Stops the mic and returns the recorded file path (null = nothing).
  final Future<String?> Function() stopRecording;

  /// dBFS ticks while recording (0 = max, silence ≈ -60 and below).
  final Stream<double> amplitudeStream;
  final Future<VoiceTurn> Function(String path) sendVoice;
  final StreamingVoiceSender? sendStreamingVoice;
  final Future<void> Function()? cancelStreamingVoice;

  /// Returns speech captured while reply audio was playing. The device layer
  /// applies AEC/VAD and hands the complete recording to the normal STT path,
  /// so an interruption becomes the next turn without asking the user to
  /// repeat the first words.
  final Future<String?> Function()? takeBargeInRecording;

  /// Plays reply audio; the future completes when playback finishes.
  final Future<void> Function(List<int> bytes) play;
  final DateTime Function() _now;

  // ---- tunables ----
  final double speechThresholdDb;
  final Duration silenceAfterSpeech;
  final Duration minUtterance;
  final Duration maxUtterance;
  final Duration noSpeechTimeout;
  final Duration sessionCap;
  final int maxEmptyTurns;
  final Duration postPlaybackGrace;

  /// Which agent this session is talking to ("the coach", "the informant",
  /// "Jaap", "the archive"). Only used in spoken//captioned copy — the loop
  /// itself is agent-agnostic, which is why one tested state machine can drive
  /// all four tabs instead of four loops drifting apart.
  final String agentLabel;

  /// Calibrate the speech threshold from the ambient noise floor at the start
  /// of every listen, instead of trusting the fixed [speechThresholdDb].
  /// Phones report wildly different dBFS baselines (bit us live: readings sat
  /// above -40 permanently, so silence was never detected and every turn ran
  /// to [maxUtterance]). Off by default so the tuned unit tests stay exact.
  final bool adaptiveThreshold;

  /// Said aloud to leave. Deliberately agent-neutral apart from "bye coach",
  /// which is kept because it is muscle memory from when this was Coach Mode.
  static const List<String> exitPhrases = [
    "goodbye",
    "good bye",
    "stop listening",
    "that's all",
    "bye coach",
    "we're done",
    "we are done",
  ];

  // ---- observable state ----
  final ValueNotifier<ConversationState> state =
      ValueNotifier(ConversationState.idle);
  final ValueNotifier<List<Caption>> captions = ValueNotifier(const []);

  /// Set when the session ends, explaining why (shown by the UI).
  final ValueNotifier<String?> endReason = ValueNotifier(null);
  final ValueNotifier<String> activity = ValueNotifier("");

  /// dB above the calibrated noise floor that counts as speech.
  static const double speechMarginDb = 9.0;

  bool _running = false;
  bool _heardSpeechThisListen = false;
  int _emptyTurns = 0;
  DateTime? _sessionStart;
  StreamSubscription<double>? _ampSub;
  Completer<bool>? _listenDone;

  bool get running => _running;

  void _caption(String text, {required bool fromUser}) {
    captions.value = [...captions.value, Caption(text, fromUser: fromUser)];
  }

  /// Start a hands-free session: listen → send → speak → listen …
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _emptyTurns = 0;
    _sessionStart = _now();
    endReason.value = null;
    captions.value = const [];
    while (_running) {
      if (_now().difference(_sessionStart!) >= sessionCap) {
        return _end("Session limit reached.");
      }
      final interrupted = await takeBargeInRecording?.call();
      final path = interrupted ?? await _listenOnce();
      if (!_running) return; // stopped mid-listen
      if (path == null) {
        _emptyTurns += 1;
        if (_emptyTurns >= maxEmptyTurns) {
          return _end("I'll stop listening for now — tap to talk again.");
        }
        continue; // listen again
      }
      state.value = ConversationState.thinking;
      if (sendStreamingVoice != null) {
        StreamingVoiceTurn turn;
        int? answerCaptionIndex;
        try {
          turn = await sendStreamingVoice!(
            path,
            StreamingVoiceCallbacks(
              onTranscript: (transcript) {
                if (_running) _caption(transcript, fromUser: true);
              },
              onAnswerDelta: (delta) {
                if (!_running) return;
                final current = [...captions.value];
                if (answerCaptionIndex == null) {
                  current.add(Caption(delta, fromUser: false));
                  answerCaptionIndex = current.length - 1;
                } else {
                  final index = answerCaptionIndex!;
                  current[index] = Caption(
                    current[index].text + delta,
                    fromUser: false,
                  );
                }
                captions.value = current;
              },
              onActivity: (message) {
                if (_running) activity.value = message;
              },
              onSpeaking: () {
                if (_running) state.value = ConversationState.speaking;
              },
            ),
          );
        } catch (_) {
          if (!_running) return;
          _caption("(couldn't reach $agentLabel — try again)", fromUser: false);
          _emptyTurns += 1;
          if (_emptyTurns >= maxEmptyTurns) return _end("Connection trouble.");
          continue;
        } finally {
          activity.value = "";
        }
        if (!_running) return;
        if (turn.transcript.isEmpty) {
          _emptyTurns += 1;
          if (_emptyTurns >= maxEmptyTurns) {
            return _end("I'll stop listening for now — tap to talk again.");
          }
          continue;
        }
        _emptyTurns = 0;
        if (_containsExitPhrase(turn.transcript)) return _end("Goodbye! 👋");
        if (state.value == ConversationState.speaking) {
          await Future<void>.delayed(postPlaybackGrace);
        }
        continue;
      }
      VoiceTurn turn;
      try {
        turn = await sendVoice(path);
      } catch (_) {
        _caption("(couldn't reach $agentLabel — try again)", fromUser: false);
        _emptyTurns += 1;
        if (_emptyTurns >= maxEmptyTurns) return _end("Connection trouble.");
        continue;
      }
      if (!_running) return;

      if (turn.transcript.isEmpty) {
        _emptyTurns += 1;
        if (_emptyTurns >= maxEmptyTurns) {
          return _end("I'll stop listening for now — tap to talk again.");
        }
        continue;
      }
      _emptyTurns = 0;
      _caption(turn.transcript, fromUser: true);
      _caption(turn.reply, fromUser: false);

      final saidExit = _containsExitPhrase(turn.transcript);
      if (turn.audioBytes.isNotEmpty) {
        state.value = ConversationState.speaking;
        try {
          await play(turn.audioBytes);
        } catch (_) {
          // playback is a bonus — the caption already carries the reply
        }
        await Future<void>.delayed(postPlaybackGrace);
      }
      if (saidExit) return _end("Goodbye! 👋");
    }
  }

  /// One listen turn. Returns the recorded path, or null for a discarded /
  /// empty capture. VAD: speech = amplitude above [speechThresholdDb]; end of
  /// turn = [silenceAfterSpeech] of quiet AFTER speech began.
  Future<String?> _listenOnce() async {
    state.value = ConversationState.listening;
    await startRecording();
    final done = Completer<bool>(); // true = speech captured, false = discard
    _listenDone = done; // so stop() can release a hanging listen
    var heardSpeech = false;
    _heardSpeechThisListen = false;
    DateTime? speechStart;
    DateTime? lastLoud;
    final listenStart = _now();

    // Adaptive calibration: the first ~600ms of readings are treated as the
    // ambient noise floor; speech = floor + margin (clamped to sane dBFS).
    const calibration = Duration(milliseconds: 600);
    final floorSamples = <double>[];
    var threshold = speechThresholdDb;

    // Watchdog (production only): if the device never delivers amplitude
    // events, VAD can't work at all — fall back to a fixed-length capture so
    // the conversation still functions instead of listening forever.
    Timer? watchdog;
    var sawAmpEvent = false;
    if (adaptiveThreshold) {
      watchdog = Timer(const Duration(milliseconds: 1500), () {
        if (!sawAmpEvent && !done.isCompleted) {
          Timer(const Duration(seconds: 6), () {
            if (!done.isCompleted) done.complete(true);
          });
        }
      });
    }

    _ampSub = amplitudeStream.listen((db) {
      sawAmpEvent = true;
      final now = _now();
      if (adaptiveThreshold) {
        if (now.difference(listenStart) < calibration) {
          floorSamples.add(db);
          return; // still calibrating — don't classify yet
        }
        if (floorSamples.isNotEmpty) {
          final floor =
              floorSamples.reduce((a, b) => a + b) / floorSamples.length;
          threshold = (floor + speechMarginDb).clamp(-55.0, -12.0);
          floorSamples.clear();
        }
      }
      if (db > threshold) {
        heardSpeech = true;
        _heardSpeechThisListen = true;
        speechStart ??= now;
        lastLoud = now;
        if (now.difference(speechStart!) >= maxUtterance && !done.isCompleted) {
          done.complete(true);
        }
        return;
      }
      if (done.isCompleted) return;
      if (!heardSpeech) {
        if (now.difference(listenStart) >= noSpeechTimeout) {
          done.complete(false);
        }
        return;
      }
      if (lastLoud != null && now.difference(lastLoud!) >= silenceAfterSpeech) {
        // Silence after real speech → end of the utterance.
        final spoke = lastLoud!.difference(speechStart!);
        done.complete(spoke >= minUtterance);
      }
    });

    final captured = await done.future;
    watchdog?.cancel();
    _listenDone = null;
    await _ampSub?.cancel();
    _ampSub = null;
    if (!_running) return null; // stopped mid-listen
    final path = await stopRecording();
    if (!captured || path == null) return null;
    return path;
  }

  bool _containsExitPhrase(String transcript) {
    final t = transcript.toLowerCase();
    return exitPhrases.any(t.contains);
  }

  void _end(String reason) {
    _running = false;
    endReason.value = reason;
    state.value = ConversationState.idle;
  }

  /// Manual end-of-utterance: the user tapped the orb while listening —
  /// send whatever was captured right now (the always-works override when
  /// automatic silence detection misjudges a device's mic levels).
  void endUtterance() {
    if (state.value != ConversationState.listening) return;
    if (_listenDone != null && !_listenDone!.isCompleted) {
      _listenDone!.complete(_heardSpeechThisListen || adaptiveThreshold);
    }
  }

  /// Cancel only the current streamed producer turn after device-side barge-in.
  /// The outer conversation loop remains alive and consumes the captured audio
  /// as its next user turn.
  Future<void> bargeIn() async {
    try {
      await cancelStreamingVoice?.call();
    } catch (_) {
      // The captured user turn remains usable even if remote cancellation races
      // with a producer terminal event.
    }
  }

  /// Hard stop (END button / screen dispose).
  Future<void> stop() async {
    _running = false;
    if (_listenDone != null && !_listenDone!.isCompleted) {
      _listenDone!.complete(false); // release a listen awaiting silence
    }
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      await cancelStreamingVoice?.call();
    } catch (_) {
      // SQL cancellation or playback stop is best-effort during screen exit.
    }
    try {
      await stopRecording();
    } catch (_) {
      // mic may not be active — fine
    }
    state.value = ConversationState.idle;
    endReason.value ??= "Ended.";
  }
}
