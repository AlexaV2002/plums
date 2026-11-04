import 'package:client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AppMessage message(String id, String content) => AppMessage(
  id: id, channelId: 'c', authorId: 'u', author: 'user', content: content,
  time: '00:00', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
);

void main() {
  testWidgets('follows a long sent message while the composer shrinks', (tester) async {
    final controller = ScrollController();
    late StateSetter update;
    var composerHeight = 120.0;
    var messages = [message('first', 'short')];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return Column(children: [
          Expanded(child: MessagesList(messages: messages, hasMoreMessages: false,
            isLoadingMoreMessages: false, scrollController: controller,
            onEditMessage: (_) {}, onDeleteMessage: (_) {}, onLoadMoreMessages: () {})),
          SizedBox(height: composerHeight),
        ]);
      },
    ))));
    await tester.pump();
    controller.jumpTo(controller.position.maxScrollExtent);
    final follow = MessageScrollFollower.capture(controller);
    update(() {
      messages = [...messages, message('long', 'long message ' * 500)];
      composerHeight = 50;
    });
    follow.schedule(controller, isCurrent: () => true);
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(controller.position.extentAfter, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('follows new messages only while near the bottom', (tester) async {
    final controller = ScrollController();
    late StateSetter update;
    var count = 30;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return ListView.builder(
          controller: controller,
          itemCount: count,
          itemBuilder: (_, index) => SizedBox(height: 50, child: Text('$index')),
        );
      })),
    ));

    controller.jumpTo(controller.position.maxScrollExtent);
    var follow = MessageScrollFollower.capture(controller);
    update(() => count++);
    follow.schedule(controller, isCurrent: () => true);
    await tester.pump();
    expect(controller.position.pixels, controller.position.maxScrollExtent);

    controller.jumpTo(100);
    follow = MessageScrollFollower.capture(controller);
    update(() => count++);
    follow.schedule(controller, isCurrent: () => true);
    await tester.pump();
    expect(controller.position.pixels, 100);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('does not jump after the user switches chats', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView.builder(
        controller: controller,
        itemCount: 30,
        itemBuilder: (_, index) => SizedBox(height: 50, child: Text('$index')),
      )),
    ));
    controller.jumpTo(controller.position.maxScrollExtent);
    final follow = MessageScrollFollower.capture(controller);
    controller.jumpTo(100);
    follow.schedule(controller, isCurrent: () => false);
    await tester.pump();
    expect(controller.position.pixels, 100);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
