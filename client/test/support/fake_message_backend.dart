import 'dart:async';

import 'package:client/main.dart';

AppMessage msg(int seq, {String channelId = 'channel-1'}) {
  final createdAt = DateTime.utc(2026, 1, 1).add(Duration(seconds: seq));
  return AppMessage(
    id: '$seq',
    channelId: channelId,
    authorId: 'author-1',
    author: 'tester',
    content: 'content-$seq',
    time: '00:00',
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

List<AppMessage> range(int from, int to, {String channelId = 'channel-1'}) {
  return [for (var i = from; i <= to; i++) msg(i, channelId: channelId)];
}

List<String> idRange(int from, int to) => [for (var i = from; i <= to; i++) '$i'];

List<String> ids(List<AppMessage> messages) =>
    messages.map((m) => m.id).toList();

typedef FetchCall = ({String channelId, int limit, String? after, String? before});

// In-memory backend с числовыми id, упорядоченными как курсор getMessages:
// без курсора — последние `limit`, `after` — первые `limit` после курсора,
// `before` — последние `limit` до курсора (страница всегда хронологическая).
class FakeMessageBackend {
  final Map<String, List<AppMessage>> _byChannel = {};
  final List<FetchCall> calls = [];
  final Set<int> failOnCalls = {};
  // Выполняется внутри fetch (номер вызова с 1) до вычисления ответа —
  // позволяет доставить live-сообщение «во время» REST-запроса или
  // придержать ответ Completer'ом.
  FutureOr<void> Function(int call)? beforeRespond;
  int inFlight = 0;
  int maxInFlight = 0;

  void add(List<AppMessage> messages) {
    for (final message in messages) {
      final list = _byChannel.putIfAbsent(message.channelId, () => []);
      if (!list.any((m) => m.id == message.id)) list.add(message);
      list.sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));
    }
  }

  List<String?> get afterCursors => calls.map((c) => c.after).toList();

  Future<List<AppMessage>> fetch(
    String channelId, {
    required int limit,
    String? after,
    String? before,
  }) async {
    final call = calls.length + 1;
    calls.add((channelId: channelId, limit: limit, after: after, before: before));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(Duration.zero);
      final hook = beforeRespond;
      if (hook != null) await hook(call);
      if (failOnCalls.contains(call)) {
        throw Exception('network error on call $call');
      }

      var pool = List<AppMessage>.of(_byChannel[channelId] ?? const []);
      if (after != null) {
        final cursor = int.parse(after);
        pool = pool.where((m) => int.parse(m.id) > cursor).toList();
        return pool.take(limit).toList();
      }
      if (before != null) {
        final cursor = int.parse(before);
        pool = pool.where((m) => int.parse(m.id) < cursor).toList();
      }
      return pool.length <= limit ? pool : pool.sublist(pool.length - limit);
    } finally {
      inFlight--;
    }
  }
}

// Минимальное состояние экрана вокруг РЕАЛЬНОГО MessageSyncController:
// список сообщений, выбранный канал и snackbar «Повторить».
class SyncFixture {
  SyncFixture(this.backend, {int pageSize = 50, int maxPages = 40}) {
    sync = MessageSyncController(
      fetch: backend.fetch,
      readMessages: () => messages,
      writeMessages: (next, {hasMore}) {
        messages = next;
        if (hasMore != null) this.hasMore = hasMore;
      },
      isChannelActive: (channelId) => selected == channelId,
      onIncomplete: (channelId, retry) {
        incomplete.add(channelId);
        lastRetry = retry;
      },
      pageSize: pageSize,
      maxPages: maxPages,
    );
  }

  final FakeMessageBackend backend;
  late final MessageSyncController sync;
  String? selected = 'channel-1';
  List<AppMessage> messages = [];
  bool? hasMore;
  final List<String> incomplete = [];
  Future<void> Function()? lastRetry;

  // Успешная REST-загрузка канала (как selectChannel): baseline + список.
  void loadBaseline(String channelId, List<AppMessage> page) {
    selected = channelId;
    sync.resetForChannel(channelId);
    messages = page;
    sync.confirmBaseline(channelId, page);
  }

  // Live message:new: сервер пишет в БД до emit, клиент добавляет без
  // дублей и сообщает контроллеру (как handleRealtimeMessage).
  void live(AppMessage message) {
    backend.add([message]);
    if (message.channelId != selected) return;
    if (!messages.any((m) => m.id == message.id)) {
      messages = [...messages, message];
    }
    sync.onLiveMessage(message);
  }
}
