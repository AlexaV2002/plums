import 'package:client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppMessage historyMessage(String id, int n, String text) => AppMessage(
  id: id, channelId: 'c', authorId: 'u', author: 'user', content: text,
  time: '00:00', createdAt: DateTime.utc(2026, 1, 1, 0, 0, n),
  updatedAt: DateTime.utc(2026, 1, 1, 0, 0, n),
);

void main() {
  testWidgets('older page and new message keep the same visible anchor', (tester) async {
    final controller = ScrollController();
    late StateSetter update;
    var messages = <AppMessage>[
      historyMessage('anchor', 20, 'visible anchor'),
      historyMessage('next', 21, 'A long message ' * 30),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return MessagesList(messages: messages, hasMoreMessages: false,
          isLoadingMoreMessages: false, scrollController: controller,
          onEditMessage: (_) {}, onDeleteMessage: (_) {}, onLoadMoreMessages: () {});
      },
    ))));
    await tester.pump();
    final before = tester.getTopLeft(find.text('visible anchor')).dy;
    update(() => messages = [
      historyMessage('old1', 1, 'An older short message'),
      historyMessage('old2', 2, 'An older long message ' * 30),
      ...messages,
      historyMessage('new', 22, 'new message'),
    ]);
    await tester.pump();
    expect(tester.getTopLeft(find.text('visible anchor')).dy, closeTo(before, 1));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
