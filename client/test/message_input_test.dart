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
            channelId: 'channel-1',
            channelName: 'general',
            canSendMessages: true,
            onSendMessage: (_, _) async => false,
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
            channelId: 'channel-1',
            channelName: 'general',
            canSendMessages: true,
            onSendMessage: (_, _) async => true,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      expect(find.text('hello'), findsNothing);
    });

    testWidgets(
      'reuses one id for retries and creates a new id after success',
      (tester) async {
        final ids = <String>[];
        await tester.pumpWidget(
          _wrap(
            MessageInput(
              channelId: 'channel-1',
              channelName: 'general',
              canSendMessages: true,
              onSendMessage: (_, clientMessageId) async {
                ids.add(clientMessageId);
                return ids.length >= 3;
              },
            ),
          ),
        );

        await tester.enterText(find.byType(TextField), 'hello');
        for (var attempt = 0; attempt < 3; attempt++) {
          await tester.tap(find.byIcon(Icons.send_rounded));
          await tester.pumpAndSettle();
        }

        expect(ids, hasLength(3));
        expect(ids[0], ids[1]);
        expect(ids[1], ids[2]);
        expect(find.text('hello'), findsNothing);

        await tester.enterText(find.byType(TextField), 'hello');
        await tester.tap(find.byIcon(Icons.send_rounded));
        await tester.pumpAndSettle();
        expect(ids[3], isNot(ids[0]));
      },
    );

    testWidgets('keeps retry ids scoped to each channel draft', (tester) async {
      final ids = <String>[];
      Widget input(String channelId) => _wrap(
        MessageInput(
          channelId: channelId,
          channelName: channelId,
          canSendMessages: true,
          onSendMessage: (_, clientMessageId) async {
            ids.add(clientMessageId);
            return false;
          },
        ),
      );

      await tester.pumpWidget(input('channel-1'));
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      await tester.pumpWidget(input('channel-2'));
      expect(find.text('hello'), findsNothing);
      await tester.enterText(find.byType(TextField), 'world');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();

      await tester.pumpWidget(input('channel-1'));
      expect(find.text('hello'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pumpAndSettle();
      expect(ids[0], ids[2]);
      expect(ids[1], isNot(ids[0]));
    });
  });
}
