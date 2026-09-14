import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lingoring/features/conversation/conversation_screen.dart';

void main() {
  testWidgets('Conversation screen shows title, mic button, and input bar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConversationScreen()));
    await tester.pump();

    expect(find.text('링고링'), findsOneWidget);
    expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('Typing and sending a message shows it as a user bubble', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConversationScreen()));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Hello there');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();

    expect(find.text('Hello there'), findsOneWidget);
  });
}
