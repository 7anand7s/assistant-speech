import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:coach_app/voice/assistant_speech_queue.dart";
import "package:coach_app/voice/speech_clip.dart";

void main() {
  test("serializes attributed replies in arrival order", () async {
    final played = <String>[];
    final firstPlayback = Completer<void>();
    final queue = AssistantSpeechQueue(
      synthesize: (agent, text) async =>
          AssistantSpeechClip(text: text, audioBytes: text.codeUnits),
      play: (agent, clip) async {
        played.add("$agent:${String.fromCharCodes(clip.audioBytes)}");
        if (agent == "Informant") await firstPlayback.future;
      },
      stopPlayback: () async {},
      pausePlayback: () async {},
      resumePlayback: () async {},
    );

    final first = queue.enqueue("Informant", "Mail answer");
    final second = queue.enqueue("Docs", "Archive answer");
    await Future<void>.delayed(Duration.zero);

    expect(queue.activeAgent, "Informant");
    expect(queue.queued, 1);
    expect(played, ["Informant:Mail answer"]);

    firstPlayback.complete();
    await Future.wait([first, second]);
    expect(played, ["Informant:Mail answer", "Docs:Archive answer"]);
    queue.dispose();
  });

  test("agent cancellation preserves another agent's queued reply", () async {
    final played = <String>[];
    final activePlayback = Completer<void>();
    var stops = 0;
    final queue = AssistantSpeechQueue(
      synthesize: (agent, text) async =>
          AssistantSpeechClip(text: text, audioBytes: text.codeUnits),
      play: (agent, clip) async {
        played.add(agent);
        if (agent == "Research") await activePlayback.future;
      },
      stopPlayback: () async {
        stops += 1;
        if (!activePlayback.isCompleted) activePlayback.complete();
      },
      pausePlayback: () async {},
      resumePlayback: () async {},
    );

    final research = queue.enqueue("Research", "Long answer");
    final coach = queue.enqueue("Coach", "Keep this answer");
    await Future<void>.delayed(Duration.zero);
    await queue.cancelAgent("Research");
    await Future.wait([research, coach]);

    expect(stops, 1);
    expect(played, ["Research", "Coach"]);
    queue.dispose();
  });

  test("speech strips formatting noise without changing bubble identity",
      () async {
    String synthesized = "";
    final queue = AssistantSpeechQueue(
      synthesize: (agent, text) async {
        synthesized = text;
        return AssistantSpeechClip(text: text, audioBytes: const [1]);
      },
      play: (agent, clip) async {},
      stopPlayback: () async {},
      pausePlayback: () async {},
      resumePlayback: () async {},
    );
    const canonical = "See **the answer** [here](https://example.test) [1].";

    await queue.enqueue("Docs", canonical);

    expect(synthesized, "See the answer here .");
    expect(queue.activeText, isEmpty);
    queue.dispose();
  });

  test("prepared replay does not synthesize a second time", () async {
    var synthesisCalls = 0;
    final queue = AssistantSpeechQueue(
      synthesize: (agent, text) async {
        synthesisCalls += 1;
        return AssistantSpeechClip(text: text, audioBytes: const [9]);
      },
      play: (agent, clip) async {},
      stopPlayback: () async {},
      pausePlayback: () async {},
      resumePlayback: () async {},
    );

    await queue.enqueueClip(
      "Coach",
      "**Visible** answer",
      const AssistantSpeechClip(text: "Visible answer", audioBytes: [1, 2]),
    );

    expect(synthesisCalls, 0);
    queue.dispose();
  });

  test("starts with a short phrase and prefetches while it is playing",
      () async {
    final synthesized = <String>[];
    final played = <String>[];
    final firstPlayback = Completer<void>();
    final queue = AssistantSpeechQueue(
      synthesize: (agent, text) async {
        synthesized.add(text);
        return AssistantSpeechClip(text: text, audioBytes: text.codeUnits);
      },
      play: (agent, clip) async {
        played.add(clip.text);
        if (played.length == 1) await firstPlayback.future;
      },
      stopPlayback: () async {},
      pausePlayback: () async {},
      resumePlayback: () async {},
    );
    const answer =
        "This opening phrase should begin quickly, while the rest of this detailed answer is synthesized in the background so conversational playback has no long silent gap between its chunks and still preserves the full visible message identity.";

    final done = queue.enqueue("Coach", answer);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(synthesized.length, greaterThanOrEqualTo(2));
    expect(synthesized.first.length, lessThanOrEqualTo(96));
    expect(played, [synthesized.first]);
    expect(queue.activeText, answer);

    firstPlayback.complete();
    await done;
    expect(played.join(" "), assistantSpokenText(answer));
    queue.dispose();
  });

  test("word progress does not notify repeatedly inside a later chunk",
      () async {
    late AssistantSpeechQueue queue;
    var plays = 0;
    var notifications = 0;
    var secondChunkPositionNotifications = -1;
    queue = AssistantSpeechQueue(
      synthesize: (agent, text) async => AssistantSpeechClip(
        text: text,
        audioBytes: const [1],
        words: const [
          AssistantWordTiming(word: "word", startMs: 0, endMs: 800),
        ],
      ),
      play: (agent, clip) async {
        plays += 1;
        if (plays != 2) return;
        notifications = 0;
        queue.updatePosition(const Duration(milliseconds: 100));
        queue.updatePosition(const Duration(milliseconds: 100));
        secondChunkPositionNotifications = notifications;
        expect(queue.activeWordIndex, greaterThan(0));
      },
      stopPlayback: () async {},
      pausePlayback: () async {},
      resumePlayback: () async {},
    )..addListener(() => notifications += 1);

    await queue.enqueue(
      "Teaching",
      "This opening phrase should begin quickly, while a later chunk carries "
          "enough additional words to verify that its local word index is "
          "translated to one stable global transcript index.",
    );

    expect(plays, greaterThanOrEqualTo(2));
    expect(secondChunkPositionNotifications, 1);
    queue.dispose();
  });

  test("speech chunker keeps short answers whole", () {
    expect(assistantSpeechChunks("A short natural reply."),
        ["A short natural reply."]);
  });
}
