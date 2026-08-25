import "package:flutter_test/flutter_test.dart";

import "package:coach_app/api/api_client.dart";

/// The hands-free loop understands exactly one shape, [VoiceTurn]. Each agent
/// answers differently, so each has an adapter — and the adapters are where a
/// hands-free session can silently break: a wrong field name means the loop
/// speaks "…" forever, and a missed not-accepted case means it polls a turn
/// that was never started until the budget runs out.
class _FakeApi extends ApiClient {
  // --- informant ---
  InformantVoiceTurn informantResult = InformantVoiceTurn(
    ok: true,
    transcript: "what did Bob send",
    reply: "Bob sent the invoice.",
    sources: const [
      {"subject": "invoice"}
    ],
    actions: const [
      {"kind": "reply"}
    ],
    audioBytes: const [1, 2, 3],
  );
  String? informantMailboxSeen;

  @override
  Future<InformantVoiceTurn> informantChatVoice(String filePath,
      {String mailbox = ""}) async {
    informantMailboxSeen = mailbox;
    return informantResult;
  }

  // --- paperless ---
  Map<String, dynamic> paperlessResult = const {
    "ok": true,
    "transcript": "where is my passport scan",
    "reply": "It is in document 41.",
    "transparency": "1 source",
    // base64 for the bytes [1,2,3]
    "audio": "AQID",
  };

  @override
  Future<Map<String, dynamic>> paperlessVoice(String filePath) async =>
      paperlessResult;

  // --- japp ---
  Map<String, dynamic> startResult = const {
    "ok": true,
    "accepted": true,
    "transcript": "find me a job",
  };
  List<Map<String, dynamic>> jappStates = const [];
  int stateCalls = 0;
  String? jappAgentSeen;
  String? spokeText;

  @override
  Future<Map<String, dynamic>> jappVoice(String filePath,
      {String agent = "assistant"}) async {
    jappAgentSeen = agent;
    return startResult;
  }

  @override
  Future<Map<String, dynamic>> jappState({String agent = "assistant"}) async {
    final i =
        stateCalls < jappStates.length ? stateCalls : jappStates.length - 1;
    stateCalls++;
    return jappStates.isEmpty ? {"ok": false} : jappStates[i];
  }

  @override
  Future<List<int>> jappSpeak(String text) async {
    spokeText = text;
    return const [9, 9];
  }
}

Map<String, dynamic> _settled(String reply) => {
      "ok": true,
      "thinking": false,
      "transcript": [
        {"role": "user", "content": "find me a job"},
        {"role": "assistant", "content": reply},
      ],
    };

void main() {
  group("informant adapter", () {
    test("carries transcript, reply and audio onto a VoiceTurn", () async {
      final api = _FakeApi();
      final t =
          await api.informantVoiceTurn("/tmp/a.m4a", mailbox: "me@x.test");
      expect(t.ok, isTrue);
      expect(t.transcript, "what did Bob send");
      expect(t.reply, "Bob sent the invoice.");
      expect(t.audioBytes, [1, 2, 3]);
      // The mailbox scope must survive — hands-free must not silently widen
      // a question to every account the user has connected.
      expect(api.informantMailboxSeen, "me@x.test");
    });

    test("a failed turn stays ok:false so the loop can count it", () async {
      final api = _FakeApi()
        ..informantResult =
            InformantVoiceTurn(ok: false, transcript: "", reply: "unreachable");
      final t = await api.informantVoiceTurn("/tmp/a.m4a");
      expect(t.ok, isFalse);
      expect(t.audioBytes, isEmpty);
    });
  });

  group("archive adapter", () {
    test("decodes the spoken answer", () async {
      final t = await _FakeApi().paperlessVoiceTurn("/tmp/a.m4a");
      expect(t.ok, isTrue);
      expect(t.transcript, "where is my passport scan");
      expect(t.reply, "It is in document 41.");
      expect(t.audioBytes, [1, 2, 3]);
    });

    test("an archive that cannot answer degrades, never throws", () async {
      final api = _FakeApi()
        ..paperlessResult = const {
          "ok": false,
          "reply": "The document archive isn't reachable right now.",
          "error": {"type": "unavailable", "retryable": true},
        };
      final t = await api.paperlessVoiceTurn("/tmp/a.m4a");
      expect(t.ok, isFalse);
      expect(t.reply, contains("isn't reachable"));
      expect(t.audioBytes, isEmpty);
    });

    test("no audio is survivable — the caption still carries the answer",
        () async {
      // TTS off, or kokoro down. The loop must still show the reply.
      final api = _FakeApi()
        ..paperlessResult = const {
          "ok": true,
          "transcript": "q",
          "reply": "the answer",
        };
      final t = await api.paperlessVoiceTurn("/tmp/a.m4a");
      expect(t.reply, "the answer");
      expect(t.audioBytes, isEmpty);
    });
  });

  group("Jaap adapter (the only one that must poll)", () {
    test("starts the turn, waits for it to settle, then speaks the reply",
        () async {
      final api = _FakeApi()
        ..jappStates = [
          {"ok": true, "thinking": true, "transcript": const []},
          {"ok": true, "thinking": true, "transcript": const []},
          _settled("I found three roles."),
        ];
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          agent: "assistant",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(seconds: 5));
      expect(t.ok, isTrue);
      expect(t.transcript, "find me a job");
      expect(t.reply, "I found three roles.");
      // Spoken only AFTER settling — Jaap has no audio to give before then.
      expect(api.spokeText, "I found three roles.");
      expect(t.audioBytes, [9, 9]);
      expect(api.jappAgentSeen, "assistant");
    });

    test("a turn that was NOT accepted never polls", () async {
      // Polling a turn that was never started would burn the whole budget and
      // then report a timeout, hiding the real reason.
      final api = _FakeApi()
        ..startResult = const {
          "ok": true,
          "accepted": false,
          "reason": "already_running",
          "transcript": "find me a job",
        };
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(seconds: 5));
      expect(t.ok, isFalse);
      expect(t.reply, contains("still working on the last thing"));
      expect(api.stateCalls, 0, reason: "it polled a turn it never started");
    });

    test("busy is reported as busy, not as already_running", () async {
      final api = _FakeApi()
        ..startResult = const {
          "ok": true,
          "accepted": false,
          "reason": "busy",
          "transcript": "hi",
        };
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1));
      expect(t.reply, contains("busy"));
    });

    test("a failed upload does not poll and says so", () async {
      final api = _FakeApi()
        ..startResult = const {
          "ok": false,
          "error": {"type": "unavailable"}
        };
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1));
      expect(t.ok, isFalse);
      expect(api.stateCalls, 0);
    });

    test("an empty transcript is not sent on as a turn", () async {
      final api = _FakeApi()
        ..startResult = const {"ok": true, "accepted": true, "transcript": ""};
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1));
      expect(t.ok, isFalse);
      expect(api.stateCalls, 0);
    });

    test("a state blip is ridden out, not treated as the end of the turn",
        () async {
      final api = _FakeApi()
        ..jappStates = [
          {
            "ok": false,
            "error": const {"type": "unavailable"}
          },
          {"ok": true, "thinking": true, "transcript": const []},
          _settled("done"),
        ];
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(seconds: 5));
      expect(t.ok, isTrue);
      expect(t.reply, "done");
    });

    test("running past the budget tells the user where the answer went",
        () async {
      // A pipeline run CAN outlive any sane spoken-session budget. Silence
      // would be the worst outcome; the reply must point at the tab.
      final api = _FakeApi()
        ..jappStates = [
          {"ok": true, "thinking": true, "transcript": const []},
        ];
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(milliseconds: 20));
      expect(t.ok, isFalse);
      expect(t.reply, contains("Jaap tab"));
      expect(t.audioBytes, isEmpty);
    });

    test("onWaiting ticks so a long run can show progress", () async {
      final ticks = <Duration>[];
      final api = _FakeApi()
        ..jappStates = [
          {"ok": true, "thinking": true, "transcript": const []},
          {"ok": true, "thinking": true, "transcript": const []},
          _settled("ok"),
        ];
      await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(seconds: 5),
          onWaiting: ticks.add);
      expect(ticks, isNotEmpty);
    });

    test("the LAST assistant message is the reply, not the first", () async {
      final api = _FakeApi()
        ..jappStates = [
          {
            "ok": true,
            "thinking": false,
            "transcript": const [
              {"role": "assistant", "content": "an older answer"},
              {"role": "user", "content": "find me a job"},
              {"role": "assistant", "content": "the new answer"},
            ],
          },
        ];
      final t = await api.jappVoiceTurn("/tmp/a.m4a",
          pollEvery: const Duration(milliseconds: 1),
          budget: const Duration(seconds: 5));
      expect(t.reply, "the new answer");
    });
  });
}
