import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('MessageInput', () {
    testWidgets('keeps the typed text when onSendMessage fails', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MessageInput(
            channelName: 'general',
            canSendMessages: true,
            onSendMessage: (_) async => false,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('clears the typed text when onSendMessage succeeds', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          MessageInput(
            channelName: 'general',
            canSendMessages: true,
            onSendMessage: (_) async => true,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('hello'), findsNothing);
    });
  });
}
