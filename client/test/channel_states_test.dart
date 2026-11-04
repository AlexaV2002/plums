import 'package:client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('channel loading, error and retry reach the empty state', (tester) async {
    final scroll = ScrollController();
    final drafts = ChannelAttachmentDrafts(ApiClient());
    late StateSetter update;
    var loading = true;
    String? error;
    var retries = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return ChatArea(
          channel: const AppChannel(id: 'c', name: 'general', type: ChannelType.text),
          messages: const [], isMessagesLoading: loading, messagesError: error,
          hasMoreMessages: false, isLoadingMoreMessages: false,
          canSendMessages: true, messagesScrollController: scroll,
          attachmentDrafts: drafts,
          onSendWithAttachments: (_, _, _, _) async => AttachmentSendResult.sent,
          onEditMessage: (_) {}, onDeleteMessage: (_) {}, onShowMembers: () {},
          onLoadMoreMessages: () {}, onRetryMessages: () {
            retries++;
            setState(() { error = null; });
          },
        );
      },
    ))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    update(() { loading = false; error = 'Ошибка загрузки сообщений'; });
    await tester.pump();
    expect(find.text('Ошибка загрузки сообщений'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pump();
    expect(retries, 1);
    expect(find.text('В этом канале пока нет сообщений'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    drafts.dispose();
    scroll.dispose();
  });

  testWidgets('channel reconnect preserves the draft and enables sending', (tester) async {
    final scroll = ScrollController();
    final drafts = ChannelAttachmentDrafts(ApiClient());
    late StateSetter update;
    var connected = true;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: StatefulBuilder(
      builder: (context, setState) {
        update = setState;
        return ChatArea(
          channel: const AppChannel(id: 'c', name: 'general', type: ChannelType.text),
          messages: const [], isMessagesLoading: false, messagesError: null,
          hasMoreMessages: false, isLoadingMoreMessages: false,
          canSendMessages: true, isConnected: connected, messagesScrollController: scroll,
          attachmentDrafts: drafts,
          onSendWithAttachments: (_, _, _, _) async => AttachmentSendResult.sent,
          onEditMessage: (_) {}, onDeleteMessage: (_) {}, onShowMembers: () {},
          onLoadMoreMessages: () {}, onRetryMessages: () {},
        );
      },
    ))));
    await tester.enterText(find.byType(TextField), 'черновик');
    update(() => connected = false);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        'Нет соединения');
    update(() => connected = true);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);
    expect(field.controller!.text, 'черновик');
    await tester.pumpWidget(const SizedBox.shrink());
    drafts.dispose();
    scroll.dispose();
  });
}
