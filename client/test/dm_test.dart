import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

const me = AppDmUser(id: 'me', username: 'me');
const alice = AppDmUser(id: 'u-alice', username: 'alice');
const bob = AppDmUser(id: 'u-bob', username: 'bob');

AppMessage dmMsg(int seq, String conversationId, {String senderId = 'u-x'}) {
  final createdAt = DateTime.utc(2026, 1, 1).add(Duration(seconds: seq));
  return AppMessage(
    id: 'm${seq.toString().padLeft(3, '0')}',
    channelId: conversationId,
    authorId: senderId,
    author: senderId,
    content: 'text-$seq',
    time: '00:00',
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

AppDmConversation conv(String id, AppDmUser peer, {AppMessage? last}) {
  return AppDmConversation(
    id: id,
    userA: me,
    userB: peer,
    createdAt: DateTime.utc(2025),
    updatedAt: last?.createdAt ?? DateTime.utc(2025),
    lastMessage: last,
  );
}

DioException httpError(int status) {
  final options = RequestOptions(path: '/dm');
  return DioException(
    requestOptions: options,
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: options,
      statusCode: status,
      data: {'message': 'Вы не участник этого диалога'},
    ),
  );
}

typedef HistoryCall = ({String id, int limit, String? before, String? after});

class FakeDmApi implements DmApi {
  List<AppDmConversation> conversations = [];
  final Map<String, List<AppMessage>> history = {};
  final List<HistoryCall> historyCalls = [];
  final Map<String, Completer<void>> holdBaseline = {};
  final Map<String, Object> historyErrors = {};
  Object? conversationsError;
  int conversationsCalls = 0;
  AppDmConversation? opened;
  final List<String> deleted = [];
  final List<(String, String)> sent = [];
  int _seq = 500;

  void add(AppMessage message) {
    final list = history.putIfAbsent(message.channelId, () => []);
    if (!list.any((m) => m.id == message.id)) list.add(message);
    list.sort((a, b) => a.createdAt!.compareTo(b.createdAt!));
  }

  @override
  Future<List<AppDmUser>> searchUsers(String query) async =>
      [alice, bob].where((user) => user.username.contains(query)).toList();

  @override
  Future<List<AppDmConversation>> getConversations() async {
    conversationsCalls++;
    final error = conversationsError;
    if (error != null) throw error;
    return List.of(conversations);
  }

  @override
  Future<AppDmConversation> openConversation(String userId) async {
    final result = opened!;
    if (!conversations.any((c) => c.id == result.id)) {
      conversations.insert(0, result);
    }
    return result;
  }

  @override
  Future<List<AppMessage>> getMessages(
    String conversationId, {
    required int limit,
    String? before,
    String? after,
  }) async {
    historyCalls.add((
      id: conversationId,
      limit: limit,
      before: before,
      after: after,
    ));
    await Future<void>.value();
    if (before == null && after == null) {
      final hold = holdBaseline.remove(conversationId);
      if (hold != null) await hold.future;
    }
    final error = historyErrors[conversationId];
    if (error != null) throw error;
    final pool = List<AppMessage>.of(history[conversationId] ?? const []);
    if (after != null) {
      final index = pool.indexWhere((m) => m.id == after);
      return pool.sublist(index + 1).take(limit).toList();
    }
    var older = pool;
    if (before != null) {
      older = pool.sublist(0, pool.indexWhere((m) => m.id == before));
    }
    return older.length <= limit ? older : older.sublist(older.length - limit);
  }

  @override
  Future<AppMessage> sendMessage(String conversationId, String content) async {
    sent.add((conversationId, content));
    final message = AppMessage(
      id: 'm${_seq++}',
      channelId: conversationId,
      authorId: me.id,
      author: me.username,
      content: content,
      time: '00:00',
      createdAt: DateTime.utc(2026, 2, 1).add(Duration(seconds: _seq)),
      updatedAt: DateTime.utc(2026, 2, 1).add(Duration(seconds: _seq)),
    );
    add(message);
    return message;
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    deleted.add(messageId);
  }
}

class FakeDmRealtime {
  final List<String> joins = [];
  final List<String> leaves = [];
  bool connected = true;
}

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

DmController makeController(FakeDmApi api, FakeDmRealtime realtime) {
  return DmController(
    api: api,
    joinRoom: realtime.joins.add,
    leaveRoom: realtime.leaves.add,
    isConnected: () => realtime.connected,
    myUserId: () => me.id,
  );
}

List<String> ids(List<AppMessage> messages) =>
    messages.map((m) => m.id).toList();

void main() {
  group('AppDmConversation / DmMessage parsing', () {
    test('parses DmMessage and tolerates missing avatarUrl', () {
      final json = {
        'id': 'c1',
        'createdAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-01T00:01:00.000Z',
        'userA': {'id': 'me', 'username': 'me'},
        'userB': {'id': 'u-alice', 'username': 'alice', 'avatarUrl': null},
        'lastMessage': {
          'id': 'm1',
          'conversationId': 'c1',
          'senderId': 'u-alice',
          'content': 'hi',
          'createdAt': '2026-01-01T00:01:00.000Z',
          'updatedAt': '2026-01-01T00:01:00.000Z',
          'sender': {'id': 'u-alice', 'username': 'alice'},
        },
      };
      final conversation = AppDmConversation.fromJson(json);
      expect(conversation.peerFor('me').username, 'alice');
      expect(conversation.peerFor('u-alice').username, 'me');
      expect(conversation.lastMessage!.channelId, 'c1');
      expect(conversation.lastMessage!.authorId, 'u-alice');
      expect(conversation.lastMessage!.author, 'alice');
    });
  });

  group('DmController', () {
    late FakeDmApi api;
    late FakeDmRealtime realtime;
    late DmController controller;

    setUp(() {
      api = FakeDmApi();
      realtime = FakeDmRealtime();
      controller = makeController(api, realtime);
    });

    tearDown(() => controller.dispose());

    test(
      'opens (creates) a conversation with a user and joins its room',
      () async {
        api.conversations = [];
        await controller.loadConversations();
        expect(controller.conversations, isEmpty);

        api.opened = conv('c-alice', alice);
        api.add(dmMsg(1, 'c-alice', senderId: alice.id));
        final ok = await controller.openWithUser(alice.id);
        await settle();

        expect(ok, isTrue);
        expect(controller.selectedId, 'c-alice');
        expect(
          controller.peerOf(controller.selectedConversation!)!.username,
          'alice',
        );
        expect(controller.conversations.map((c) => c.id), ['c-alice']);
        expect(ids(controller.messages), ['m001']);
        expect(realtime.joins, ['c-alice']);
      },
    );

    test('late result of A after switching does not leak into B', () async {
      api.conversations = [conv('A', alice), conv('B', bob)];
      api.add(dmMsg(1, 'A'));
      api.add(dmMsg(2, 'B'));
      await controller.loadConversations();

      final gate = Completer<void>();
      api.holdBaseline['A'] = gate;
      unawaited(controller.selectConversation('A'));
      await settle();
      await controller.selectConversation('B');
      gate.complete();
      await settle();

      expect(controller.selectedId, 'B');
      expect(ids(controller.messages), ['m002']);
      expect(realtime.joins, ['B']);
      expect(realtime.leaves, isEmpty);
    });

    test('switching A -> B leaves A and joins B', () async {
      api.conversations = [conv('A', alice), conv('B', bob)];
      api.add(dmMsg(1, 'A'));
      api.add(dmMsg(2, 'B'));
      await controller.loadConversations();
      await controller.selectConversation('A');
      await controller.selectConversation('B');
      await settle();

      expect(realtime.joins, ['A', 'B']);
      expect(realtime.leaves, ['A']);
      expect(ids(controller.messages), ['m002']);
    });

    test('dm:new and REST send of the same id do not duplicate', () async {
      api.conversations = [conv('A', alice)];
      api.add(dmMsg(1, 'A'));
      await controller.loadConversations();
      await controller.selectConversation('A');

      controller.handleDmNew(dmMsg(1, 'A')); // уже из REST
      controller.handleDmNew(dmMsg(2, 'A'));
      controller.handleDmNew(dmMsg(2, 'A'));
      expect(ids(controller.messages), ['m001', 'm002']);

      expect(await controller.sendMessage('hello'), isTrue);
      final sentId = controller.messages.last.id;
      controller.handleDmNew(controller.messages.last); // эхо dm:new
      expect(controller.messages.where((m) => m.id == sentId), hasLength(1));
      expect(api.sent, [('A', 'hello')]);
      expect(controller.conversations.single.lastMessage!.id, sentId);
    });

    test('dm:new of another conversation raises it in the list', () async {
      api.conversations = [
        conv('A', alice, last: dmMsg(5, 'A')),
        conv('B', bob, last: dmMsg(1, 'B')),
      ];
      api.add(dmMsg(5, 'A'));
      await controller.loadConversations();
      await controller.selectConversation('A');
      expect(controller.conversations.map((c) => c.id), ['A', 'B']);

      controller.handleDmNew(dmMsg(9, 'B'));
      expect(controller.conversations.map((c) => c.id), ['B', 'A']);
      expect(controller.conversations.first.lastMessage!.content, 'text-9');
      expect(ids(controller.messages), ['m005']); // выбранный не тронут

      final callsBefore = api.conversationsCalls;
      controller.handleDmNew(dmMsg(10, 'unknown'));
      await settle();
      expect(api.conversationsCalls, callsBefore + 1);
    });

    test('incoming dialog appears in an open empty DM view without switching tabs', () async {
      await controller.activate();
      expect(controller.conversations, isEmpty);
      api.conversations = [conv('A', alice)];
      api.add(dmMsg(1, 'A'));

      for (var i = 0; i < 60; i++) {
        controller.handleConversationChanged('A');
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle();

      expect(api.conversationsCalls, 2);
      expect(controller.selectedId, 'A');
      expect(ids(controller.messages), ['m001']);
      expect(realtime.joins, ['A']);
    });

    test('dm:delete removes only the matching message', () async {
      api.conversations = [conv('A', alice), conv('B', bob)];
      for (var i = 1; i <= 3; i++) {
        api.add(dmMsg(i, 'A'));
      }
      await controller.loadConversations();
      await controller.selectConversation('A');

      controller.handleDmDelete(
        const RealtimeDmDelete(id: 'm002', conversationId: 'A'),
      );
      controller.handleDmDelete(
        const RealtimeDmDelete(id: 'm002', conversationId: 'A'),
      );
      controller.handleDmDelete(
        const RealtimeDmDelete(id: 'm001', conversationId: 'B'),
      );
      expect(ids(controller.messages), ['m001', 'm003']);
    });

    test('deletes only own messages via API', () async {
      api.conversations = [conv('A', alice)];
      api.add(dmMsg(1, 'A', senderId: alice.id));
      api.add(dmMsg(2, 'A', senderId: me.id));
      await controller.loadConversations();
      await controller.selectConversation('A');

      expect(
        await controller.deleteMessage(controller.messages.first),
        isFalse,
      );
      expect(await controller.deleteMessage(controller.messages.last), isTrue);
      expect(api.deleted, ['m002']);
      expect(ids(controller.messages), ['m001']);
    });

    test('reconnect catches up with after from the confirmed point', () async {
      api.conversations = [conv('A', alice)];
      api.add(dmMsg(1, 'A'));
      api.add(dmMsg(2, 'A'));
      await controller.loadConversations();
      await controller.selectConversation('A');
      controller.handleDmJoined('A');
      await settle();
      expect(api.historyCalls.last.after, 'm002');
      expect(controller.sync.inSync, isTrue);

      // Live в состоянии inSync продвигает подтверждённую точку.
      api.add(dmMsg(3, 'A'));
      controller.handleDmNew(dmMsg(3, 'A'));

      controller.handleDisconnected();
      api.add(dmMsg(4, 'A'));
      api.add(dmMsg(5, 'A'));
      controller.handleDmJoined('A');
      await settle();

      expect(api.historyCalls.last.after, 'm003');
      expect(ids(controller.messages), [
        'm001',
        'm002',
        'm003',
        'm004',
        'm005',
      ]);
    });

    test('ack forbidden drops the conversation and reports an error', () async {
      api.conversations = [conv('A', alice)];
      await controller.loadConversations();
      await controller.selectConversation('A');
      final notices = <String>[];
      final sub = controller.notices.listen((n) => notices.add(n.message));

      controller.handleDmJoinDenied(
        const RealtimeDmJoinDenied(conversationId: 'A', reason: 'forbidden'),
      );
      await settle();

      expect(controller.selectedId, isNull);
      expect(controller.conversations, isEmpty);
      expect(controller.messages, isEmpty);
      expect(notices, ['Нет доступа к этому диалогу']);
      await sub.cancel();
    });

    test('403 on history does not keep a foreign conversation open', () async {
      api.conversations = [conv('A', alice), conv('B', bob)];
      api.add(dmMsg(1, 'B'));
      api.historyErrors['A'] = httpError(403);
      await controller.loadConversations();
      await controller.selectConversation('A');
      await settle();

      expect(controller.conversations.map((c) => c.id), ['B']);
      expect(controller.selectedId, 'B');
      expect(realtime.joins, ['B']);
    });
  });

  group('DmView', () {
    late FakeDmApi api;
    late FakeDmRealtime realtime;
    late DmController controller;

    setUp(() {
      api = FakeDmApi();
      realtime = FakeDmRealtime();
      controller = makeController(api, realtime);
    });

    Finder inChat(String text) =>
        find.descendant(of: find.byType(DmChatArea), matching: find.text(text));

    Future<void> pumpMany(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
    }

    Future<void> pumpView(
      WidgetTester tester, {
      ValueNotifier<bool>? connection,
    }) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DmView(
              controller: controller,
              connection: connection ?? ValueNotifier<bool>(true),
            ),
          ),
        ),
      );
    }

    Future<void> load(WidgetTester tester, String select) async {
      unawaited(
        controller.loadConversations().then(
          (_) => controller.selectConversation(select),
        ),
      );
      await pumpMany(tester);
    }

    testWidgets('shows empty conversation list', (tester) async {
      await pumpView(tester);
      unawaited(controller.loadConversations());
      await pumpMany(tester);
      expect(find.text('Нет личных сообщений'), findsWidgets);
    });

    testWidgets('shows empty history', (tester) async {
      api.conversations = [conv('A', alice)];
      await pumpView(tester);
      await load(tester, 'A');
      expect(inChat('Сообщений пока нет'), findsOneWidget);
      expect(inChat('alice'), findsOneWidget); // заголовок с собеседником
    });

    testWidgets('history error offers retry', (tester) async {
      api.conversations = [conv('A', alice)];
      api.historyErrors['A'] = Exception('offline');
      await pumpView(tester);
      await load(tester, 'A');
      expect(find.textContaining('Ошибка загрузки сообщений'), findsOneWidget);

      api.historyErrors.clear();
      api.add(dmMsg(1, 'A'));
      await tester.tap(find.text('Повторить'));
      await pumpMany(tester);
      expect(inChat('text-1'), findsOneWidget);
      expect(find.textContaining('Ошибка загрузки сообщений'), findsNothing);
    });

    testWidgets('switching conversations changes shown messages', (
      tester,
    ) async {
      api.conversations = [conv('A', alice), conv('B', bob)];
      api.add(dmMsg(1, 'A'));
      api.add(dmMsg(2, 'B'));
      await pumpView(tester);
      await load(tester, 'A');
      expect(inChat('text-1'), findsOneWidget);

      await tester.tap(find.text('bob'));
      await pumpMany(tester);
      expect(inChat('text-2'), findsOneWidget);
      expect(inChat('text-1'), findsNothing);
      expect(inChat('bob'), findsWidgets);
    });

    testWidgets('input is disabled without connection', (tester) async {
      api.conversations = [conv('A', alice)];
      final connection = ValueNotifier<bool>(false);
      await pumpView(tester, connection: connection);
      await load(tester, 'A');

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isFalse);
      expect(find.text('Нет соединения'), findsOneWidget);

      connection.value = true;
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });
  });
}
