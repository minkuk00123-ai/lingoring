import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:llamadart/llamadart.dart';

import 'conversation_models.dart' show ConversationReply;

/// Same production task as [ConversationService] (see that file's
/// SYSTEM_PROMPT/generate_data.py in finetune/) but run entirely on-device
/// with the fine-tuned model produced by finetune/, via llama.cpp
/// (llamadart). No network call, no shared free-tier quota — this is what
/// actually makes the conversation feature free to ship.
///
/// Unlike `ConversationService.reply(List<ConversationTurn>)`, which resends
/// the whole turn history every call (built for a stateless HTTP API), this
/// keeps a persistent ChatSession so only the newest user turn is encoded
/// each time — the KV cache carries the rest, which matters a lot for
/// speed on-device.
class LlamaConversationService {
  // Hosted on GitHub Releases (see finetune/README.md for how the GGUF is
  // produced) — ModelSource.parse treats an http(s) string as a
  // download-once-and-cache source automatically. Overridable via
  // --dart-define for local testing against a device-local path.
  static const String modelSource = String.fromEnvironment(
    'LINGORING_LLM_MODEL_SOURCE',
    defaultValue:
        'https://github.com/minkuk00123-ai/lingoring/releases/download/v0.1.0-model/lingoring-conversation-q4_k_m.gguf',
  );

  static const _systemPrompt =
      'You are a friendly English conversation partner for a Korean learner '
      'practicing spoken English. Reply with ONLY a single-line JSON object '
      'of the exact shape {"reply": "...", "correction": "..."} — no markdown '
      'fences, no text outside the JSON. Keep "reply" short (1-3 sentences), '
      'use simple everyday vocabulary, and just continue the conversation '
      'naturally — never mention grammar, corrections, or explain anything '
      'inside "reply" itself. If the user\'s last message had an English '
      'mistake, put ONLY the corrected version of their sentence in '
      '"correction"; otherwise set "correction" to an empty string. Always '
      'reply in English only.';

  // Forces well-formed {"reply": "...", "correction": "..."} output at the
  // sampler level, independent of how reliably the fine-tune itself follows
  // the format — the cloud version has no such backstop (see
  // ConversationService._stripJsonFence) since NVIDIA's API offers no
  // grammar/JSON-mode constraint.
  static const _jsonGrammar = r'''
root ::= "{\"reply\": \"" jstring "\", \"correction\": \"" jstring "\"}"
jstring ::= jchar*
jchar ::= [^"\\] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
''';

  final _engine = LlamaEngine(LlamaBackend());
  ChatSession? _session;
  bool _modelReady = false;
  Future<void>? _loading;

  bool get isReady => _modelReady;

  /// Downloads (first run only, then cached on device) and loads the
  /// fine-tuned model. Safe to call repeatedly — later calls await the
  /// same in-flight load rather than starting a second one.
  Future<void> ensureModelReady() {
    if (_modelReady) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      await _engine.setLogLevel(LlamaLogLevel.none);
      await _engine.loadModelSource(
        ModelSource.parse(modelSource),
        modelParams: const ModelParams(gpuLayers: 99, contextSize: 4096),
      );
      _session = ChatSession(_engine, systemPrompt: _systemPrompt);
      _modelReady = true;
    } finally {
      _loading = null;
    }
  }

  /// Sends the learner's latest utterance and returns the model's reply, or
  /// null on failure. Conversation history before this turn is carried by
  /// the session's own KV cache, not resent — see the class doc.
  Future<ConversationReply?> reply(String userText) async {
    final trimmed = userText.trim();
    if (trimmed.isEmpty) return null;

    try {
      // Model-load failures land here too (not just generation failures) —
      // same fail-soft-to-null contract as ConversationService.reply, so a
      // caller never has to tell "couldn't load" apart from "couldn't
      // generate".
      await ensureModelReady();
      final session = _session;
      if (session == null) return null;

      final buffer = StringBuffer();
      await for (final chunk in session.create(
        [LlamaTextContent(trimmed)],
        params: const GenerationParams(
          maxTokens: 200,
          temp: 0.6,
          topP: 0.9,
          grammar: _jsonGrammar,
        ),
      )) {
        final text = chunk.choices.first.delta.content;
        if (text != null) buffer.write(text);
      }

      final json = jsonDecode(buffer.toString()) as Map<String, dynamic>;
      final replyText = (json['reply'] as String?)?.trim();
      if (replyText == null || replyText.isEmpty) return null;
      final correction = (json['correction'] as String?)?.trim();
      return ConversationReply(
        text: replyText,
        correction: (correction == null || correction.isEmpty) ? null : correction,
      );
    } catch (e) {
      debugPrint('LlamaConversationService.reply failed: $e');
      return null;
    }
  }

  /// Starts a fresh conversation (new call) — clears turn history but keeps
  /// the model loaded, so the next reply() doesn't pay the load cost again.
  void resetConversation() {
    _session?.reset();
  }

  Future<void> dispose() async {
    await _engine.dispose();
  }
}
