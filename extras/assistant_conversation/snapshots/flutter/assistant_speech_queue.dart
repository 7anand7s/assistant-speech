import "dart:async";

import "package:flutter/foundation.dart";

import "speech_clip.dart";

typedef AssistantSpeechSynthesizer = Future<AssistantSpeechClip> Function(
    String agent, String text);
typedef AssistantSpeechPlayer = Future<void> Function(
    String agent, AssistantSpeechClip clip);

class _SpeechItem {
  final String agent;
  final String text;
  final AssistantSpeechClip? preparedClip;
  final Completer<void> done = Completer<void>();
  bool cancelled = false;

  _SpeechItem(this.agent, this.text, {this.preparedClip});
}

/// One global, attributed speech queue for all Assistant agents.
///
/// Agent replies may land concurrently while the user switches tabs. A shared
/// queue prevents a later reply from replacing audio already playing, keeps
/// attribution visible, and lets a generation-bound cancel remove only the
/// matching agent's speech without muting unrelated completions.
class AssistantSpeechQueue extends ChangeNotifier {
  final AssistantSpeechSynthesizer synthesize;
  final AssistantSpeechPlayer play;
  final Future<void> Function() stopPlayback;
  final Future<void> Function() pausePlayback;
  final Future<void> Function() resumePlayback;

  AssistantSpeechQueue({
    required this.synthesize,
    required this.play,
    required this.stopPlayback,
    required this.pausePlayback,
    required this.resumePlayback,
  });

  final List<_SpeechItem> _pending = [];
  _SpeechItem? _active;
  Future<void>? _drainFuture;
  bool _disposed = false;
  AssistantSpeechClip? _activeClip;
  int _activeWordIndex = -1;
  int _activeWordOffset = 0;
  bool _paused = false;

  String get activeAgent => _active?.agent ?? "";
  String get activeText => _active?.text ?? "";
  String get activeSpokenText => _activeClip?.text ?? "";
  AssistantSpeechClip? get activeClip => _activeClip;
  int get activeWordIndex => _activeWordIndex;
  bool get paused => _paused;
  int get queued => _pending.where((item) => !item.cancelled).length;
  bool get speaking => _active != null;

  void updatePosition(Duration position) {
    final words = _activeClip?.words ?? const <AssistantWordTiming>[];
    if (_active == null || words.isEmpty) return;
    var next = words.lastIndexWhere(
      (word) => position.inMilliseconds >= word.startMs,
    );
    if (next >= 0 &&
        next == words.length - 1 &&
        position.inMilliseconds > words[next].endMs) {
      next = -1;
    }
    final nextGlobal = next < 0 ? -1 : _activeWordOffset + next;
    if (nextGlobal == _activeWordIndex) return;
    _activeWordIndex = nextGlobal;
    notifyListeners();
  }

  Future<void> togglePause() async {
    if (_active == null) return;
    if (_paused) {
      await resumePlayback();
      _paused = false;
    } else {
      await pausePlayback();
      _paused = true;
    }
    notifyListeners();
  }

  Future<void> enqueue(String agent, String text) {
    final cleanAgent = agent.trim().isEmpty ? "Assistant" : agent.trim();
    final cleanText = text.trim();
    if (_disposed || cleanText.isEmpty) return Future<void>.value();
    final item = _SpeechItem(cleanAgent, cleanText);
    _pending.add(item);
    notifyListeners();
    _drainFuture ??= _drain();
    return item.done.future;
  }

  Future<void> enqueueClip(
      String agent, String displayText, AssistantSpeechClip clip) {
    final cleanAgent = agent.trim().isEmpty ? "Assistant" : agent.trim();
    final cleanText = displayText.trim();
    if (_disposed || cleanText.isEmpty) return Future<void>.value();
    final item = _SpeechItem(cleanAgent, cleanText, preparedClip: clip);
    _pending.add(item);
    notifyListeners();
    _drainFuture ??= _drain();
    return item.done.future;
  }

  Future<void> cancelAgent(String agent) async {
    final clean = agent.trim();
    for (final item in _pending) {
      if (item.agent == clean) item.cancelled = true;
    }
    if (_active?.agent == clean) {
      _active!.cancelled = true;
      _paused = false;
      await stopPlayback();
    }
    notifyListeners();
  }

  Future<void> cancelAll() async {
    for (final item in _pending) {
      item.cancelled = true;
    }
    if (_active != null) _active!.cancelled = true;
    _paused = false;
    await stopPlayback();
    notifyListeners();
  }

  Future<void> _drain() async {
    while (!_disposed && _pending.isNotEmpty) {
      final item = _pending.removeAt(0);
      if (item.cancelled) {
        if (!item.done.isCompleted) item.done.complete();
        continue;
      }
      _active = item;
      _activeClip = null;
      _activeWordIndex = -1;
      _activeWordOffset = 0;
      _paused = false;
      notifyListeners();
      try {
        if (item.preparedClip != null) {
          final clip = item.preparedClip!;
          _activeClip = clip;
          if (!_disposed && !item.cancelled && !clip.isEmpty) {
            notifyListeners();
            await play(item.agent, clip);
          }
        } else {
          final chunks = assistantSpeechChunks(item.text);
          Future<AssistantSpeechClip>? prepared = chunks.isEmpty
              ? null
              : _synthesizeSafely(item.agent, chunks.first);
          var wordOffset = 0;
          for (var index = 0;
              index < chunks.length && !_disposed && !item.cancelled;
              index += 1) {
            final clip = await prepared!;
            // Start one request ahead before playback. It normally completes
            // while the current audio is speaking, removing sentence gaps
            // without flooding the shared TTS service with every chunk.
            prepared = index + 1 < chunks.length
                ? _synthesizeSafely(item.agent, chunks[index + 1])
                : null;
            _activeClip = clip;
            _activeWordOffset = wordOffset;
            _activeWordIndex = -1;
            if (!_disposed && !item.cancelled && !clip.isEmpty) {
              notifyListeners();
              await play(item.agent, clip);
            }
            wordOffset += _spokenWordCount(chunks[index]);
          }
        }
      } catch (_) {
        // Speech is an enhancement. The canonical text already landed.
      } finally {
        if (!item.done.isCompleted) item.done.complete();
        if (identical(_active, item)) {
          _active = null;
          _activeClip = null;
          _activeWordIndex = -1;
          _activeWordOffset = 0;
          _paused = false;
        }
        if (!_disposed) notifyListeners();
      }
    }
    _drainFuture = null;
    // An enqueue can land between the loop's final condition and clearing the
    // future. Restart deterministically instead of leaving that item stranded.
    if (!_disposed && _pending.isNotEmpty) _drainFuture = _drain();
  }

  Future<AssistantSpeechClip> _synthesizeSafely(
      String agent, String text) async {
    try {
      return await synthesize(agent, text);
    } catch (_) {
      return AssistantSpeechClip(text: text, audioBytes: const []);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final item in [..._pending, if (_active != null) _active!]) {
      item.cancelled = true;
      if (!item.done.isCompleted) item.done.complete();
    }
    _pending.clear();
    _active = null;
    _activeClip = null;
    _activeWordIndex = -1;
    _activeWordOffset = 0;
    _paused = false;
    unawaited(stopPlayback());
    super.dispose();
  }
}

int _spokenWordCount(String value) =>
    RegExp(r"[\w']+").allMatches(value).length;
