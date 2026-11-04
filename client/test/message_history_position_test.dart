import 'package:client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppMessage historyMessage(String id, int n, String text) => AppMessage(
  id: id, channelId: 'c', authorId: 'u', author: 'user', content: text,
  time: '00:00', createdAt: DateTime.utc(2026, 1, 1, 0, 0, n),
  updatedAt: DateTime.utc(2026, 1, 1, 0, 0, n),
);

void main() {
  for (final isDm in [false, true]) {
    testWidgets('${isDm ? 'DM' : 'channel'} composer has the same gap as messages', (tester) async {
      final controller = ScrollController();
      final drafts = ChannelAttachmentDrafts(ApiClient());
      final messages = [historyMessage('first', 1, 'first'), historyMessage('last', 2, 'last')];
      final composer = isDm
          ? MessageInput(channelId: 'c', channelName: 'chat', canSendMessages: true,
              onSendMessage: (_, _) async => true)
          : ChannelAttachmentInput(channelId: 'c', channelName: 'chat',
              canSendMessages: true, drafts: drafts,
              onSend: (_, _, _, _) async => AttachmentSendResult.sent);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
        Expanded(child: MessagesList(messages: messages, hasMoreMessages: false,
          isLoadingMoreMessages: false, scrollController: controller,
          onEditMessage: (_) {}, onDeleteMessage: (_) {}, onLoadMoreMessages: () {})),
        composer,
      ]))));
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      Finder row(String id) => find.descendant(
        of: find.byKey(ValueKey(id)), matching: find.byType(Row),
      ).first;
      final fieldBox = find.byWidgetPredicate((widget) => widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).color == const Color(0xFF302A39));
      final betweenMessages = tester.getTopLeft(row('last')).dy - tester.getBottomLeft(row('first')).dy;
      final beforeComposer = tester.getTopLeft(fieldBox).dy - tester.getBottomLeft(row('last')).dy;
      expect(betweenMessages, closeTo(18, 1));
      expect(beforeComposer, closeTo(betweenMessages, 1));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      drafts.dispose();
    });
  }

  testWidgets('short history places the last message at the bottom', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
      height: 400,
      child: MessagesList(
        messages: [historyMessage('only', 1, 'only message')],
        hasMoreMessages: false, isLoadingMoreMessages: false,
        scrollController: controller, onEditMessage: (_) {},
        onDeleteMessage: (_) {}, onLoadMoreMessages: () {},
      ),
    ))));
    await tester.pump();
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    final listBottom = tester.getBottomLeft(find.byType(CustomScrollView)).dy;
    final messageBottom = tester.getBottomLeft(find.byKey(const ValueKey('only'))).dy;
    expect(messageBottom, closeTo(listBottom, 1));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  for (final chatId in ['channel', 'dm']) {
    testWidgets('long $chatId history opens at the last message', (tester) async {
      final controller = ScrollController();
      final messages = List.generate(100, (index) {
        final text = index == 99 ? 'last message in $chatId' :
            'message $index ${'long text ' * (index % 8 + 1)}';
        return AppMessage(
          id: '$chatId-$index', channelId: chatId, authorId: 'u',
          author: 'user', content: text, time: '00:00',
          createdAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
          updatedAt: DateTime.utc(2026, 1, 1).add(Duration(seconds: index)),
        );
      });
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessagesList(
        messages: messages, hasMoreMessages: true, isLoadingMoreMessages: false,
        scrollController: controller, onEditMessage: (_) {},
        onDeleteMessage: (_) {}, onLoadMoreMessages: () {},
      ))));
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(find.text('last message in $chatId'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  }

  testWidgets('older page and new message keep the same visible anchor', (tester) async {
    final controller = ScrollController();
    late StateSetter update;
    var messages = <AppMessage>[
      historyMessage('previous', 19, 'A long message ' * 30),
      historyMessage('anchor', 20, 'visible anchor'),
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
    controller.jumpTo(controller.position.maxScrollExtent);
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
