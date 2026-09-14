/// A single turn in the conversation, in the order they were spoken.
/// `correction` is a UI-only annotation on the model's own turns — it is
/// never sent back as part of a request's history.
class ConversationTurn {
  final bool isUser;
  final String text;
  final String? correction;

  const ConversationTurn({
    required this.isUser,
    required this.text,
    this.correction,
  });
}

/// The model's reply, split so the UI can keep the chat bubble purely
/// conversational and show any grammar fix as a small caption instead.
class ConversationReply {
  final String text;
  final String? correction;

  const ConversationReply({required this.text, this.correction});
}
