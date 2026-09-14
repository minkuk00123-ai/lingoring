import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

/// On-device speech-to-text via whisper.cpp, replacing Android's built-in
/// SpeechRecognizer entirely. That native recognizer was the source of
/// every reliability problem the call flow hit — a start/stop beep with no
/// way to silence it, an Android-side bug where every error reports
/// `permanent: true` (breaking retry logic that trusted it), and sessions
/// that ended with a partial result like "hello" captured but no final
/// result or error ever following, silently dropping what was said. Since
/// we now own the whole capture→transcribe loop, none of those apply: no
/// OS-level beep is played, and `finish()` always resolves to *something*
/// (whisper_ggml itself falls back to the last partial on a mid-session
/// error — see its own WhisperLiveSession.stop).
class WhisperSttService {
  static const _sampleRate = 16000;

  final _whisper = WhisperController();
  final _recorder = AudioRecorder();

  WhisperLiveSession? _session;
  StreamSubscription<Uint8List>? _micSub;
  Timer? _silenceTimer;
  DateTime _lastVoiceAt = DateTime.now();
  bool _modelReady = false;
  // Sole owner of "how a listening session ends" — both the internal
  // silence timer and an external cancel() call go through this, so
  // whichever fires first is the one that actually resolves the pending
  // listenUntilSilence() future. Without funneling cancel() through the
  // same completer, an external cancel while a session was in flight left
  // that call's Future permanently unresolved (a hung, never-completing
  // await in the caller) since nothing else knew how to complete it.
  Future<void> Function()? _finishCurrent;

  /// Downloads the model on first call (cached on device after — checked
  /// via a plain file-exists, so this is cheap on every later call). The
  /// package has no download-progress callback, so the caller can only
  /// show an indeterminate "getting ready" state, not a percentage.
  Future<void> ensureModelReady() async {
    if (_modelReady) return;
    await _whisper.downloadModel(WhisperModel.baseEn);
    _modelReady = true;
  }

  /// Starts listening and resolves once the user has stopped talking
  /// (silence held for [silenceTimeout]) or [maxDuration] is hit. Calls
  /// [onPartial] with the progressively-refined transcript as it's heard —
  /// this is what feeds the call screen's live caption.
  ///
  /// [voiceRmsThreshold] is the mean-abs PCM16 sample level (0-32767) above
  /// which a chunk counts as "someone is talking" for the silence timer —
  /// separate from whisper_ggml's own internal energy gate, which only
  /// decides what reaches the decoder, not when to end the turn.
  Future<String> listenUntilSilence({
    required void Function(String text) onPartial,
    // Was 1500ms — every turn ate that much dead air before the reply even
    // started. 900ms is short enough to feel snappy but still comfortably
    // longer than a mid-sentence breath pause at normal speaking pace.
    Duration silenceTimeout = const Duration(milliseconds: 900),
    Duration maxDuration = const Duration(seconds: 30),
    double voiceRmsThreshold = 400,
  }) async {
    await ensureModelReady();

    final session = await startWhisperLiveSession(
      modelPath: (await _whisper.getPath(WhisperModel.baseEn)),
      lang: 'en',
    );
    _session = session;

    final completer = Completer<String>();
    session.partials.listen(onPartial, onError: (_) {});

    final micStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
    );

    _lastVoiceAt = DateTime.now();
    final startedAt = DateTime.now();

    Future<void> finish() async {
      _finishCurrent = null;
      _silenceTimer?.cancel();
      await _micSub?.cancel();
      await _recorder.stop();
      final text = await session.stop();
      _session = null;
      if (!completer.isCompleted) completer.complete(text);
    }

    _finishCurrent = finish;

    _silenceTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final silentFor = DateTime.now().difference(_lastVoiceAt);
      final elapsed = DateTime.now().difference(startedAt);
      if (silentFor >= silenceTimeout || elapsed >= maxDuration) {
        finish();
      }
    });

    _micSub = micStream.listen(
      (chunk) {
        session.feed(chunk);
        if (_rms(chunk) >= voiceRmsThreshold) {
          _lastVoiceAt = DateTime.now();
        }
      },
      onError: (_) => finish(),
      onDone: finish,
    );

    return completer.future;
  }

  /// Ends listening immediately (e.g. the user hung up mid-turn) without
  /// waiting for the silence timeout, and resolves any in-flight
  /// listenUntilSilence() call. Safe to call even if not listening.
  Future<void> cancel() async {
    final finish = _finishCurrent;
    if (finish != null) {
      await finish();
    } else {
      // No listenUntilSilence() is in flight (or it already finished on
      // its own) — nothing to resolve, but tear down defensively in case
      // some native resource is still held.
      _silenceTimer?.cancel();
      await _micSub?.cancel();
      if (await _recorder.isRecording()) await _recorder.stop();
      await _session?.stop();
      _session = null;
    }
  }

  void dispose() {
    _silenceTimer?.cancel();
    _micSub?.cancel();
    _recorder.dispose();
  }

  double _rms(Uint8List pcm16Bytes) {
    // NOT pcm16Bytes.buffer.asInt16List(offsetInBytes, ...): the stream
    // chunk's offset within its underlying buffer isn't guaranteed to be
    // even, and Int16List views require 2-byte alignment — this crashed
    // with a RangeError the first time a misaligned chunk arrived.
    // ByteData reads bytes manually instead, so alignment doesn't matter.
    final n = pcm16Bytes.length ~/ 2;
    if (n == 0) return 0;
    final data = ByteData.sublistView(pcm16Bytes);
    var sumSquares = 0.0;
    for (var i = 0; i < n; i++) {
      final s = data.getInt16(i * 2, Endian.little);
      sumSquares += s * s;
    }
    return sqrt(sumSquares / n);
  }
}
