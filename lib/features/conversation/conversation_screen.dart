import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/services/conversation_models.dart' show ConversationTurn;
import '../../core/services/llama_conversation_service.dart';
import '../../core/services/whisper_stt_service.dart';
import '../../core/theme/app_colors.dart';

/// Free voice-conversation practice, entirely on-device: whisper.cpp speech
/// recognition (see WhisperSttService) feeds the user's turn to the
/// fine-tuned local LLM (see LlamaConversationService, finetune/), and the
/// reply is read aloud with the device's own TTS. No network call and no
/// shared API quota — see finetune/README.md for how the model got here.
class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

enum _CallPhase { listening, thinking, speaking }

class _ConversationScreenState extends State<ConversationScreen> {
  final _service = LlamaConversationService();
  final _stt = WhisperSttService();
  final _tts = FlutterTts();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  final List<ConversationTurn> _turns = [];
  bool _sttReady = false;
  bool _preparingStt = false;
  bool _listening = false;
  bool _waitingForReply = false;
  bool _speaking = false;
  // One tap starts a hands-free call: 사용자 > AI > 사용자 > AI, looping on
  // its own until the user taps again to end it — not a separate mode to
  // opt into on top of the mic button.
  bool _inCall = false;
  // Bumped on every _endCall so a _startListening loop still in flight from
  // before the hangup (whisper's listenUntilSilence is a single future with
  // no external stop-and-discard) knows not to act on its own result.
  int _callGeneration = 0;

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('en-US');
    // Without this, the Future from _tts.speak() completes immediately
    // instead of when playback actually finishes, so the call flow would
    // try to start listening again while the reply is still being read.
    _tts.awaitSpeakCompletion(true);
  }

  @override
  void dispose() {
    _stt.dispose();
    _service.dispose();
    _tts.stop();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // The mic button is the single call control: tap to start (사용자 > AI >
  // 사용자 > AI, on its own), tap again — whether mid-listen, mid-thinking,
  // or mid-reply — to end it.
  Future<void> _onMicTap() async {
    if (_inCall) {
      _endCall();
      return;
    }
    if (!_sttReady || !_service.isReady) {
      setState(() => _preparingStt = true);
      try {
        // Both are one-time-download-then-cached (see WhisperSttService,
        // LlamaConversationService) so this only shows on the very first
        // call after install.
        await Future.wait([_stt.ensureModelReady(), _service.ensureModelReady()]);
      } catch (e) {
        if (!mounted) return;
        setState(() => _preparingStt = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('모델을 준비하지 못했어요 ($e).')),
        );
        return;
      }
      if (!mounted) return;
      setState(() {
        _sttReady = true;
        _preparingStt = false;
      });
    }
    setState(() => _inCall = true);
    _listenLoop(_callGeneration);
  }

  Future<void> _endCall() async {
    _callGeneration++;
    setState(() => _inCall = false);
    await _stt.cancel();
    await _tts.stop();
    _service.resetConversation();
    if (!mounted) return;
    setState(() {
      _listening = false;
      _speaking = false;
    });
  }

  // Whisper's listen call is a single future per turn (unlike the old
  // callback-driven SpeechRecognizer flow), so "keep listening across
  // turns" is just this loop calling itself — no separate restart-on-error
  // path needed since listenUntilSilence always resolves to *something*
  // (possibly empty) rather than firing a callback that might never come.
  Future<void> _listenLoop(int generation) async {
    while (mounted && _inCall && generation == _callGeneration) {
      setState(() {
        _listening = true;
        _textController.clear();
      });
      final text = await _stt.listenUntilSilence(
        onPartial: (partial) {
          if (mounted) setState(() => _textController.text = partial);
        },
      );
      if (!mounted || generation != _callGeneration) return;
      setState(() => _listening = false);
      final trimmed = text.trim();
      if (trimmed.isEmpty) {
        continue; // nothing heard this round — just listen again
      }
      await _send(trimmed);
      if (!mounted || generation != _callGeneration) return;
      // _send's own hungUpMidFlight handling already covers the case where
      // the call ended while waiting on the reply/TTS; loop back to listen
      // for the next turn as long as the call (this generation) is still on.
    }
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    debugPrint('[send] called with "$trimmed" (waitingForReply=$_waitingForReply)');
    if (trimmed.isEmpty || _waitingForReply) return;
    // Captured up front so a hangup that happens while this request is in
    // flight (_inCall flips false) can be told apart from "never in a call
    // to begin with" (typed messages should still get a spoken reply).
    final wasInCall = _inCall;

    setState(() {
      _turns.add(ConversationTurn(isUser: true, text: trimmed));
      _waitingForReply = true;
      _textController.clear();
    });
    _scrollToBottom();

    final reply = await _service.reply(trimmed);
    debugPrint('[send] reply: ${reply == null ? "null (failed)" : reply.text}');
    if (!mounted) return;

    setState(() {
      _waitingForReply = false;
      if (reply != null) {
        _turns.add(
          ConversationTurn(
            isUser: false,
            text: reply.text,
            correction: reply.correction,
          ),
        );
      }
    });
    _scrollToBottom();

    if (reply == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('응답을 만들지 못했어요. 다시 시도해주세요.')),
      );
    }
    // Only the natural reply is ever spoken — the correction is a written
    // hint for the learner, not something the roleplayed partner "said".
    // Skip it if the user hung up while this was in flight; a plain typed
    // message (never in a call) still gets read aloud as before.
    final hungUpMidFlight = wasInCall && !_inCall;
    if (reply != null && !hungUpMidFlight) {
      setState(() => _speaking = true);
      await _tts.speak(reply.text);
      if (mounted) setState(() => _speaking = false);
    }
    // No explicit restart here: _listenLoop (the caller, when this turn
    // came from a call) just loops back and listens again on its own.
  }

  IconData get _micIcon {
    if (_preparingStt) return Icons.downloading_rounded;
    if (!_inCall) return Icons.mic_none_rounded;
    if (_listening) return Icons.mic_rounded;
    if (_speaking) return Icons.volume_up_rounded;
    if (_waitingForReply) return Icons.more_horiz_rounded;
    return Icons.mic_rounded;
  }

  _CallPhase get _callPhase {
    if (_speaking) return _CallPhase.speaking;
    if (_waitingForReply) return _CallPhase.thinking;
    return _CallPhase.listening;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            if (_preparingStt) const _ModelDownloadBanner(),
            Expanded(
              child: _inCall
                  ? _CallOrbView(
                      phase: _callPhase,
                      liveText: _listening ? _textController.text : null,
                      onHangUp: _endCall,
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                      itemCount: _turns.length + (_waitingForReply ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _turns.length) return const _ThinkingBubble();
                        return _TurnBubble(turn: _turns[i]);
                      },
                    ),
            ),
            if (!_inCall) _buildInputBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            '링고링',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.text1,
            ),
          ),
          if (_inCall) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.live.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                '통화 중',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.live,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: AppColors.text1.withValues(alpha: 0.06),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            _GhostIconButton(
              tooltip: _preparingStt
                  ? '음성 인식 준비 중...'
                  : (_inCall ? '통화 종료' : '통화 시작'),
              icon: _micIcon,
              active: _inCall,
              activeColor: AppColors.live,
              onPressed: _preparingStt ? null : _onMicTap,
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_waitingForReply,
                style: const TextStyle(fontSize: 15, color: AppColors.text1),
                decoration: InputDecoration(
                  hintText: '영어로 입력하거나 마이크를 눌러 말해보세요',
                  hintStyle: const TextStyle(color: AppColors.text3, fontSize: 14),
                  border: InputBorder.none,
                  isDense: true,
                ),
                onSubmitted: _send,
              ),
            ),
            _GhostIconButton(
              tooltip: '보내기',
              icon: Icons.arrow_upward_rounded,
              active: true,
              onPressed: _waitingForReply
                  ? null
                  : () => _send(_textController.text),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen call view modeled on ChatGPT's Advanced Voice Mode "orb"
/// (Separate Mode): a breathing gradient sphere that stands in for the
/// chat transcript while a call is active, color- and speed-coded by
/// phase, with a live partial-recognition caption and a single hang-up
/// control — replacing the ordinary chat list + input bar for the
/// duration of the call.
class _CallOrbView extends StatefulWidget {
  final _CallPhase phase;
  final String? liveText;
  final VoidCallback onHangUp;

  const _CallOrbView({
    required this.phase,
    required this.liveText,
    required this.onHangUp,
  });

  @override
  State<_CallOrbView> createState() => _CallOrbViewState();
}

class _CallOrbViewState extends State<_CallOrbView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _CallOrbView old) {
    super.didUpdateWidget(old);
    // Thinking pulses noticeably faster than listening/speaking — a quiet
    // visual cue that something is happening even with no live caption.
    final ms = widget.phase == _CallPhase.thinking ? 800 : 1600;
    if (_pulse.duration!.inMilliseconds != ms) {
      _pulse.duration = Duration(milliseconds: ms);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  // ChatGPT's own orb stays blue across listening/thinking/speaking rather
  // than color-coding by phase — pulse speed (see didUpdateWidget) is what
  // carries the state cue instead.
  Color get _orbColor => AppColors.primary;

  String get _phaseLabel {
    switch (widget.phase) {
      case _CallPhase.listening:
        return '듣고 있어요';
      case _CallPhase.thinking:
        return '생각하는 중이에요';
      case _CallPhase.speaking:
        return '말하는 중이에요';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _orbColor;
    return Column(
      children: [
        Expanded(
          child: Center(
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final t = Curves.easeInOut.transform(_pulse.value);
                final scale = 0.92 + t * 0.16;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          color.withValues(alpha: 0.95),
                          color.withValues(alpha: 0.55),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.35 * t + 0.1),
                          blurRadius: 40 + t * 30,
                          spreadRadius: 4 + t * 10,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Padding(
            key: ValueKey(widget.liveText?.isNotEmpty == true ? 'live' : widget.phase),
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              (widget.liveText != null && widget.liveText!.isNotEmpty)
                  ? widget.liveText!
                  : _phaseLabel,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: widget.liveText?.isNotEmpty == true ? 17 : 15,
                fontWeight: widget.liveText?.isNotEmpty == true
                    ? FontWeight.w600
                    : FontWeight.w500,
                color: widget.liveText?.isNotEmpty == true
                    ? AppColors.text1
                    : AppColors.text2,
                height: 1.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 36),
        Material(
          color: AppColors.live,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onHangUp,
            child: const Padding(
              padding: EdgeInsets.all(18),
              child: Icon(Icons.call_end_rounded, color: Colors.white, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

/// A static (no spinner, no animation) stand-in for the AI's bubble while
/// a reply is in flight — otherwise a slow or dropped request looks
/// indistinguishable from the app doing nothing at all.
class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: const Text(
          '· · ·',
          style: TextStyle(
            color: AppColors.text3,
            fontSize: 15,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
        ),
      ),
    );
  }
}

/// Toss-style icon button: no filled circle at rest, a soft tinted circle
/// when `active` — the color itself (not a background chip) is what
/// mimics Material's own IconButton usage elsewhere in the app.
class _GhostIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final Color activeColor;
  final VoidCallback? onPressed;

  const _GhostIconButton({
    required this.tooltip,
    required this.icon,
    required this.active,
    this.activeColor = AppColors.primary,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = onPressed == null
        ? AppColors.text3
        : (active ? activeColor : AppColors.text2);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? activeColor.withValues(alpha: 0.1) : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, size: 22, color: color),
          ),
        ),
      ),
    );
  }
}

class _TurnBubble extends StatelessWidget {
  final ConversationTurn turn;

  const _TurnBubble({required this.turn});

  @override
  Widget build(BuildContext context) {
    final isUser = turn.isUser;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    return Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            constraints: BoxConstraints(maxWidth: maxWidth),
            decoration: BoxDecoration(
              color: isUser ? AppColors.primary : AppColors.surfaceMuted,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isUser ? 20 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 20),
              ),
            ),
            child: Text(
              turn.text,
              style: TextStyle(
                color: isUser ? Colors.white : AppColors.text1,
                fontSize: 15,
                height: 1.4,
              ),
            ),
          ),
        ),
        if (turn.correction != null)
          Container(
            margin: const EdgeInsets.only(top: 6, left: 4),
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1.5),
                  child: Icon(Icons.auto_awesome_rounded, size: 13, color: AppColors.text3),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    turn.correction!,
                    style: const TextStyle(
                      color: AppColors.text2,
                      fontSize: 12.5,
                      fontStyle: FontStyle.italic,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ModelDownloadBanner extends StatelessWidget {
  const _ModelDownloadBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: const Text(
        '처음 한 번만 온디바이스 모델을 내려받고 있어요. 이후에는 인터넷 없이도 바로 대화할 수 있어요.',
        style: TextStyle(color: AppColors.text2, fontSize: 12),
      ),
    );
  }
}
