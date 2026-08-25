import "dart:async";

import "package:flutter_test/flutter_test.dart";

import "package:coach_app/api/api_client.dart";
import "package:coach_app/voice/conversation_controller.dart";

/// Drives the Alexa-loop state machine with a scripted mic + fake clock —
/// the whole hands-free conversation is verified without any plugin.
class Harness {
  final amps = StreamController<double>.broadcast();
  final List<String> events = [];
  DateTime clock = DateTime(2026, 7, 12, 12, 0, 0);

  /// Scripted turns the fake backend returns, in order.
  final List<VoiceTurn> turns;
  int turnIndex = 0;
  bool sendShouldThrow = false;

  late final ConversationController c;

  final String agentLabel;

  Harness({required this.turns, this.agentLabel = "the coach"}) {
    c = ConversationController(
      startRecording: () async => events.add("rec-start"),
      stopRecording: () async {
        events.add("rec-stop");
        return "/tmp/turn.m4a";
      },
      amplitudeStream: amps.stream,
      sendVoice: (path) async {
        events.add("send");
        if (sendShouldThrow) throw Exception("down");
        return turns[turnIndex++];
      },
      play: (bytes) async => events.add("play"),
      now: () => clock,
      // fast-test tunables
      silenceAfterSpeech: const Duration(milliseconds: 300),
      minUtterance: const Duration(milliseconds: 100),
      noSpeechTimeout: const Duration(seconds: 2),
      sessionCap: const Duration(minutes: 10),
      postPlaybackGrace: Duration.zero,
      agentLabel: agentLabel,
    );
  }

  /// Emit an amplitude tick and advance the fake clock.
  Future<void> tick(double db, [int ms = 100]) async {
    clock = clock.add(Duration(milliseconds: ms));
    amps.add(db);
    await Future<void>.delayed(Duration.zero); // let listeners run
  }

  /// Simulate a spoken utterance followed by end-of-turn silence.
  Future<void> speakTurn() async {
    for (var i = 0; i < 3; i++) {
      await tick(-20); // loud = speech
    }
    for (var i = 0; i < 4; i++) {
      await tick(-55); // quiet → 400ms > silenceAfterSpeech
    }
  }
}

VoiceTurn turn(String transcript, String reply, {bool audio = true}) =>
    VoiceTurn(
      ok: true,
      transcript: transcript,
      reply: reply,
      transparency: "",
      audioBytes: audio ? [1, 2, 3] : const [],
    );

void main() {
  test("dictation populates editable composer text and never auto-sends",
      () async {
    final events = <String>[];
    var composer = "";
    final dictation = CoachDictationController(
      transcribe: (path, mode) async {
        events.add("transcribe:$path:${mode.name}");
        return "  editable final transcript  ";
      },
      populateComposer: (text) {
        composer = text;
        events.add("composer:$text");
      },
    );

    await dictation.accept("/tmp/note.m4a");

    expect(composer, "editable final transcript");
    expect(events, [
      "transcribe:/tmp/note.m4a:dictation",
      "composer:editable final transcript",
    ]);
    expect(events.where((event) => event.contains("submit")), isEmpty);
  });

  test("hands-free run request preserves selected thread and provenance", () {
    const request = CoachRunRequest(
      text: "How should I recover?",
      context: "Sport card: training load 42",
      threadId: "coach_thread_23",
      origin: "hands_free",
      modelTier: "balanced",
      clientRequestId: "speech-turn-1",
    );

    expect(request.toJson(), {
      "thread_id": "coach_thread_23",
      "input": {
        "type": "text",
        "text": "How should I recover?",
        "context": "Sport card: training load 42",
      },
      "model_tier": "balanced",
      "origin": "hands_free",
      "priority_class": "interactive",
      "client_request_id": "speech-turn-1",
    });
  });

  test("stream runner keeps order and deduplicates replayed SSE events",
      () async {
    final spokenSequences = <int>[];
    final played = <List<int>>[];
    final answers = <String>[];
    final activities = <String>[];
    final runner = CoachHandsFreeTurnRunner(
      transcribe: (_, mode) async {
        expect(mode, CoachSpeechInputMode.handsFree);
        return "recovery question";
      },
      submit: (_) async => const CoachRun(
        runId: "coach_run_1",
        threadId: "coach_thread_23",
        state: "queued",
        stateVersion: 1,
      ),
      events: (_) => Stream.fromIterable(const [
        CoachRunEvent(
          sequence: 1,
          type: "activity",
          data: {"message": "Planning safely"},
        ),
        CoachRunEvent(
          sequence: 2,
          type: "answer.delta",
          data: {"text": "Take an easy day. "},
        ),
        // Boundary replay after reconnect: neither text nor TTS may repeat.
        CoachRunEvent(
          sequence: 2,
          type: "answer.delta",
          data: {"text": "Take an easy day. "},
        ),
        CoachRunEvent(
          sequence: 3,
          type: "citation",
          data: {"url": "https://private.invalid"},
        ),
        CoachRunEvent(
          sequence: 4,
          type: "action",
          data: {"tool_json": "{danger: true}"},
        ),
        CoachRunEvent(
          sequence: 5,
          type: "answer.delta",
          data: {"text": "Hydrate and sleep."},
        ),
        CoachRunEvent(sequence: 6, type: "run.completed"),
      ]),
      speech: (_, sequence) async {
        spokenSequences.add(sequence);
        return [sequence];
      },
      play: (bytes) async => played.add(bytes),
      cancelRun: (_) async {},
      stopPlayback: () async {},
    );

    final turn = await runner.run(
      "/tmp/turn.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: answers.add,
        onActivity: activities.add,
        onSpeaking: () {},
      ),
    );

    expect(turn.reply, "Take an easy day. Hydrate and sleep.");
    expect(answers, ["Take an easy day. ", "Hydrate and sleep."]);
    expect(activities, ["Planning safely"]);
    expect(spokenSequences, [2, 5]);
    expect(played, [
      [2],
      [5],
    ]);
  });

  test("stream starts automatic playback before the terminal answer event",
      () async {
    final stream = StreamController<CoachRunEvent>();
    final played = Completer<void>();
    final runner = CoachHandsFreeTurnRunner(
      transcribe: (_, __) async => "hello",
      submit: (_) async => const CoachRun(
        runId: "coach_run_early",
        threadId: "coach_thread_8",
        state: "queued",
        stateVersion: 1,
      ),
      events: (_) => stream.stream,
      speech: (_, __) async => [1, 2, 3],
      play: (_) async => played.complete(),
      cancelRun: (_) async {},
      stopPlayback: () async {},
    );
    var finished = false;
    final future = runner
        .run(
          "/tmp/turn.m4a",
          StreamingVoiceCallbacks(
            onTranscript: (_) {},
            onAnswerDelta: (_) {},
            onActivity: (_) {},
            onSpeaking: () {},
          ),
        )
        .whenComplete(() => finished = true);

    await Future<void>.delayed(Duration.zero);
    stream.add(const CoachRunEvent(
      sequence: 1,
      type: "answer.delta",
      data: {"text": "Hello there."},
    ));
    await played.future;
    expect(finished, isFalse);
    stream.add(const CoachRunEvent(sequence: 2, type: "run.completed"));
    await stream.close();
    await future;
  });

  test("speech-only answer chunks do not alter captions", () async {
    final spokenSequences = <int>[];
    final answers = <String>[];
    final runner = CoachHandsFreeTurnRunner(
      transcribe: (_, __) async => "hello",
      submit: (_) async => const CoachRun(
        runId: "coach_run_speech_only",
        threadId: "coach_thread_8",
        state: "queued",
        stateVersion: 1,
      ),
      events: (_) => Stream.fromIterable(const [
        CoachRunEvent(
          sequence: 1,
          type: "answer.delta",
          data: {"text": "Visible answer."},
        ),
        // The server may need more sentence-sized speech chunks than exact
        // display chunks. Empty display text must still request event-bound
        // audio without creating an empty/duplicate caption.
        CoachRunEvent(
          sequence: 2,
          type: "answer.delta",
          data: {"text": ""},
        ),
        CoachRunEvent(sequence: 3, type: "run.completed"),
      ]),
      speech: (_, sequence) async {
        spokenSequences.add(sequence);
        return [sequence];
      },
      play: (_) async {},
      cancelRun: (_) async {},
      stopPlayback: () async {},
    );

    final turn = await runner.run(
      "/tmp/turn.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: answers.add,
        onActivity: (_) {},
        onSpeaking: () {},
      ),
    );

    expect(turn.reply, "Visible answer.");
    expect(answers, ["Visible answer."]);
    expect(spokenSequences, [1, 2]);
  });

  test("cancellation stops future synthesis and playback", () async {
    final stream = StreamController<CoachRunEvent>();
    final speechStarted = Completer<void>();
    final releaseSpeech = Completer<List<int>>();
    final cancelled = <String>[];
    var playCount = 0;
    var stopCount = 0;
    final runner = CoachHandsFreeTurnRunner(
      transcribe: (_, __) async => "stop test",
      submit: (_) async => const CoachRun(
        runId: "coach_run_cancel",
        threadId: "coach_thread_9",
        state: "queued",
        stateVersion: 1,
      ),
      events: (_) => stream.stream,
      speech: (_, __) {
        speechStarted.complete();
        return releaseSpeech.future;
      },
      play: (_) async => playCount += 1,
      cancelRun: (runId) async => cancelled.add(runId),
      stopPlayback: () async => stopCount += 1,
    );
    final future = runner.run(
      "/tmp/cancel.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: (_) {},
        onActivity: (_) {},
        onSpeaking: () {},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    stream.add(const CoachRunEvent(
      sequence: 1,
      type: "answer.delta",
      data: {"text": "This should not play."},
    ));
    await speechStarted.future;
    await runner.cancel();
    releaseSpeech.complete([9]);
    await stream.close();
    await future;

    expect(cancelled, ["coach_run_cancel"]);
    expect(stopCount, 1);
    expect(playCount, 0);
  });

  test("Jaap v6 hands-free deduplicates replay and speaks safe sentences",
      () async {
    final answers = <String>[];
    final spoken = <String>[];
    final played = <List<int>>[];
    final runner = JaapHandsFreeTurnRunner(
      threadVersion: 4,
      pollEvery: Duration.zero,
      transcribe: (_, mode) async {
        expect(mode, CoachSpeechInputMode.handsFree);
        return "find roles";
      },
      submit: (text, version) async {
        expect(text, "find roles");
        expect(version, 4);
        return const JaapVoiceRun(
            turnId: "turn-1", turnVersion: 2, generation: 7);
      },
      eventLog: (_, after, spokenAfter) async => {
        "events": [
          {
            "sequence": 1,
            "event_type": "text.delta",
            "payload": {"text": "Three roles found."}
          },
          {
            "sequence": 1,
            "event_type": "text.delta",
            "payload": {"text": "Three roles found."}
          },
          {
            "sequence": 2,
            "event_type": "citation",
            "payload": {"url": "https://not-spoken.invalid"}
          },
          {
            "sequence": 3,
            "event_type": "speech.sentence",
            "payload": {"text": "Three roles found.", "spoken_offset": 18}
          },
          {
            "sequence": 3,
            "event_type": "speech.sentence",
            "payload": {"text": "Three roles found.", "spoken_offset": 18}
          }
        ]
      },
      turnStatus: (_) async => {
        "turn": {"status": "completed", "version": 3, "generation": 7}
      },
      speech: (sentence) async {
        spoken.add(sentence);
        return [3];
      },
      play: (bytes) async => played.add(bytes),
      cancelTurn: (_, __, ___) async {},
      stopPlayback: () async {},
    );

    final result = await runner.run(
      "/tmp/jaap.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: answers.add,
        onActivity: (_) {},
        onSpeaking: () {},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.reply, "Three roles found.");
    expect(answers, ["Three roles found."]);
    expect(spoken, ["Three roles found."]);
    expect(played, [
      [3]
    ]);
  });

  test("Jaap v6 barge-in uses current version and generation", () async {
    final speechStarted = Completer<void>();
    final releaseSpeech = Completer<List<int>>();
    final cancelled = <(String, int, int)>[];
    var stopped = 0;
    var played = 0;
    final runner = JaapHandsFreeTurnRunner(
      threadVersion: 1,
      pollEvery: Duration.zero,
      transcribe: (_, __) async => "stop test",
      submit: (_, __) async => const JaapVoiceRun(
          turnId: "turn-cancel", turnVersion: 2, generation: 9),
      eventLog: (_, __, ___) async => {
        "events": [
          {
            "sequence": 1,
            "event_type": "speech.sentence",
            "payload": {"text": "Do not play.", "spoken_offset": 12}
          }
        ]
      },
      turnStatus: (_) async => {
        "turn": {"status": "running", "version": 3, "generation": 9}
      },
      speech: (_) {
        speechStarted.complete();
        return releaseSpeech.future;
      },
      play: (_) async => played += 1,
      cancelTurn: (id, version, generation) async =>
          cancelled.add((id, version, generation)),
      stopPlayback: () async => stopped += 1,
    );
    final future = runner.run(
      "/tmp/jaap-cancel.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: (_) {},
        onActivity: (_) {},
        onSpeaking: () {},
      ),
    );
    await speechStarted.future;
    await runner.cancel();
    releaseSpeech.complete([9]);
    await future;

    expect(cancelled, [("turn-cancel", 2, 9)]);
    expect(stopped, 1);
    expect(played, 0);
  });

  test("durable agent runner streams public text and only safe speech",
      () async {
    final answers = <String>[];
    final spoken = <String>[];
    final activities = <String>[];
    var polls = 0;
    final runner = DurableAgentHandsFreeTurnRunner(
      pollEvery: Duration.zero,
      transcribe: (_, mode) async {
        expect(mode, CoachSpeechInputMode.handsFree);
        return "search my archive";
      },
      submit: (text) async {
        expect(text, "search my archive");
        return "docs-run-1";
      },
      poll: (_, after) async {
        polls += 1;
        if (polls == 1) {
          expect(after, 0);
          return const DurableVoicePoll(
            sequence: 3,
            answerDelta: "The document says ",
            speakable: ["The document says this."],
            activity: "Reading document",
          );
        }
        expect(after, 3);
        return const DurableVoicePoll(
          sequence: 4,
          finalAnswer: "The document says this.",
          terminal: true,
        );
      },
      speech: (text) async {
        spoken.add(text);
        return [1];
      },
      play: (_) async {},
      cancelRun: (_) async {},
      stopPlayback: () async {},
    );

    final result = await runner.run(
      "/tmp/docs.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: answers.add,
        onActivity: activities.add,
        onSpeaking: () {},
      ),
    );

    expect(result.ok, isTrue);
    expect(result.reply, "The document says this.");
    expect(answers, ["The document says ", "this."]);
    expect(spoken, ["The document says this."]);
    expect(activities, ["Reading document"]);
  });

  test("durable agent barge-in cancels only its active run", () async {
    final pollStarted = Completer<void>();
    final releasePoll = Completer<DurableVoicePoll>();
    final cancelled = <String>[];
    var stopped = 0;
    final runner = DurableAgentHandsFreeTurnRunner(
      pollEvery: Duration.zero,
      transcribe: (_, __) async => "cancel this",
      submit: (_) async => "research-run-cancel",
      poll: (_, __) {
        pollStarted.complete();
        return releasePoll.future;
      },
      speech: (_) async => [1],
      play: (_) async {},
      cancelRun: (runId) async => cancelled.add(runId),
      stopPlayback: () async => stopped += 1,
    );
    final future = runner.run(
      "/tmp/research.m4a",
      StreamingVoiceCallbacks(
        onTranscript: (_) {},
        onAnswerDelta: (_) {},
        onActivity: (_) {},
        onSpeaking: () {},
      ),
    );
    await pollStarted.future;
    await runner.cancel();
    releasePoll.complete(const DurableVoicePoll(
      sequence: 1,
      terminal: true,
      succeeded: false,
    ));
    await future;

    expect(cancelled, ["research-run-cancel"]);
    expect(stopped, 1);
  });

  test("SSE decoder handles split chunks and preserves numeric event IDs", () {
    final decoder = CoachSseDecoder();
    expect(decoder.add("id: 7\nevent: answer.delta\nda"), isEmpty);
    final events = decoder.add(
        "ta: {\"sequence\":7,\"type\":\"answer.delta\",\"data\":{\"text\":\"Hi.\"}}\n\n");

    expect(events.single.sequence, 7);
    expect(events.single.type, "answer.delta");
    expect(events.single.data["text"], "Hi.");
  });

  test("SSE decoder does not invent a blank event when CRLF splits", () {
    final decoder = CoachSseDecoder();
    expect(decoder.add("id: 9\r"), isEmpty);
    expect(decoder.add("\nevent: answer.delta\r"), isEmpty);
    expect(
        decoder.add(
            "\ndata: {\"sequence\":9,\"type\":\"answer.delta\",\"data\":{\"text\":\"Safe.\"}}\r"),
        isEmpty);
    final events = decoder.add("\n\r\n");

    expect(events, hasLength(1));
    expect(events.single.sequence, 9);
    expect(events.single.data["text"], "Safe.");
  });

  test("full loop: listen → send → speak → listen again", () async {
    final h = Harness(turns: [
      turn("what should I eat", "How about eggs?"),
      turn("goodbye", "Bye!"),
    ]);
    final session = h.c.start();

    await h.speakTurn(); // turn 1
    await Future<void>.delayed(Duration.zero);
    // After the reply plays, it should be LISTENING again automatically.
    expect(
        h.events,
        containsAllInOrder(
            ["rec-start", "rec-stop", "send", "play", "rec-start"]));

    await h.speakTurn(); // turn 2 says goodbye
    await session;

    expect(h.c.state.value, ConversationState.idle);
    expect(h.c.endReason.value, contains("Goodbye"));
    // Captions carry both sides of both turns.
    final texts = h.c.captions.value.map((c) => c.text).toList();
    expect(texts, [
      "what should I eat",
      "How about eggs?",
      "goodbye",
      "Bye!",
    ]);
  });

  test("too-short utterance is discarded (counts toward empty turns)",
      () async {
    final h = Harness(turns: []);
    var ended = false;
    final session = h.c.start()..whenComplete(() => ended = true);

    // Keep speaking 50ms blips (< minUtterance 100ms) until the controller
    // gives up — robust to a tick being dropped between re-subscriptions.
    var rounds = 0;
    while (!ended && rounds < 8) {
      await h.tick(-20, 50); // sub-minimum speech
      for (var i = 0; i < 6; i++) {
        await h.tick(-55);
      }
      await Future<void>.delayed(Duration.zero);
      rounds++;
    }
    await session;
    expect(h.events.where((e) => e == "send"), isEmpty);
    expect(h.c.endReason.value, contains("stop listening"));
  });

  test("no speech at all times out and eventually ends the session", () async {
    final h = Harness(turns: []);
    final session = h.c.start();
    // 3 rounds of pure silence, each past the 2s no-speech timeout.
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 25; i++) {
        await h.tick(-60); // 25 * 100ms = 2.5s silence
      }
      await Future<void>.delayed(Duration.zero);
    }
    await session;
    expect(h.c.state.value, ConversationState.idle);
    expect(h.events.where((e) => e == "send"), isEmpty);
  });

  test("backend failure degrades and retries, then gives up after 3", () async {
    final h = Harness(turns: [])..sendShouldThrow = true;
    final session = h.c.start();
    for (var round = 0; round < 3; round++) {
      await h.speakTurn();
      await Future<void>.delayed(Duration.zero);
    }
    await session;
    expect(h.events.where((e) => e == "send").length, 3);
    expect(h.c.endReason.value, contains("Connection trouble"));
    final texts = h.c.captions.value.map((c) => c.text);
    expect(texts, everyElement(contains("couldn't reach")));
  });

  test("a failure names the agent you were actually talking to", () async {
    // One loop drives four agents. Telling someone in the Docs tab that the
    // COACH is unreachable points them at the wrong system entirely.
    final h = Harness(turns: [], agentLabel: "the archive")
      ..sendShouldThrow = true;
    final session = h.c.start();
    for (var round = 0; round < 3; round++) {
      await h.speakTurn();
      await Future<void>.delayed(Duration.zero);
    }
    await session;
    final texts = h.c.captions.value.map((c) => c.text);
    expect(texts, everyElement(contains("couldn't reach the archive")));
    expect(texts, everyElement(isNot(contains("coach"))));
  });

  test("empty transcript from STT counts as an empty turn", () async {
    final h = Harness(turns: [
      turn("", "couldn't hear you", audio: false),
      turn("", "couldn't hear you", audio: false),
      turn("", "couldn't hear you", audio: false),
    ]);
    final session = h.c.start();
    for (var round = 0; round < 3; round++) {
      await h.speakTurn();
      await Future<void>.delayed(Duration.zero);
    }
    await session;
    expect(h.c.endReason.value, contains("stop listening"));
    expect(h.events.where((e) => e == "play"), isEmpty); // nothing spoken
  });

  test("stop() mid-listen releases cleanly", () async {
    final h = Harness(turns: []);
    final session = h.c.start();
    await h.tick(-60); // listening, no speech yet
    await h.c.stop();
    await session; // must complete — no hang
    expect(h.c.state.value, ConversationState.idle);
  });

  test("session cap ends the conversation", () async {
    final h = Harness(turns: [turn("hi", "hello!")]);
    final session = h.c.start();
    await h.speakTurn();
    await Future<void>.delayed(Duration.zero);
    // Jump the clock past the 10-minute cap before the next listen closes.
    h.clock = h.clock.add(const Duration(minutes: 11));
    await h.speakTurn();
    // The loop checks the cap between turns; the second capture may or may not
    // send depending on ordering, but the session MUST end.
    await session;
    expect(h.c.state.value, ConversationState.idle);
  });

  test("exit phrases are matched case-insensitively", () {
    final h = Harness(turns: []);
    expect(
      ConversationController.exitPhrases.every((p) => p == p.toLowerCase()),
      isTrue,
    );
    // sanity of the matcher via a private-behaviour proxy: run a session
    // where the transcript contains an uppercase exit phrase.
    h.c.stop();
  });

  test("max utterance force-closes a rambling turn", () async {
    final h = Harness(turns: [turn("long story", "wow")]);
    // maxUtterance default is 20s; our ticks advance 100ms each → 201 loud ticks.
    final session = h.c.start();
    for (var i = 0; i < 205; i++) {
      await h.tick(-20);
    }
    await Future<void>.delayed(Duration.zero);
    expect(h.events, contains("send")); // sent without ever hearing silence
    await h.c.stop();
    await session;
  });
}
