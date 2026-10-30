// Покрывает P1-дефект "новое live-сообщение может стать курсором докачки,
// пропустив реальный пробел": handleRealtimeReconnected раньше брало курсор
// из messages.last.id уже ПОСЛЕ реконнекта, а к этому моменту по
// восстановленному соединению может успеть прийти новое live-сообщение
// (handleRealtimeMessage синхронный и ничего не ждёт), из-за чего реальный
// пробел истории молча терялся.
//
// MainShell сейчас не DI-параметризован для apiClient/RealtimeClient (как
// уже отмечено в auth_gate_restore_session_test.dart для apiClient), и
// realtimeClient создаётся внутри _MainShellState без возможности подменить
// socketUrl — полноценный widget-тест с реальным Socket.IO потребовал бы
// отдельного DI-рефакторинга MainShell, затрагивающего ~60 обращений к
// apiClient/realtimeClient по всему файлу, что противоречит правилу
// минимального diff для этой задачи. Поэтому, как и остальные сценарии
// catch-up в catch_up_messages_test.dart, тест мирроит РЕАЛЬНУЮ логику
// _MainShellState (handleRealtimeDisconnected/handleRealtimeReconnected/
// _runReconnectSync/_flushPendingReconnectSync/handleRealtimeMessage,
// main.dart ~1812-1900) построчно, используя настоящие экспортированные
// чистые функции mergeMessagesChronologically/applyCatchUpPage, и подменяя
// только сетевой вызов apiClient.getMessages на инжектируемую функцию.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

AppMessage _msg(String id, DateTime createdAt) {
  return AppMessage(
    id: id,
    channelId: 'channel-1',
    authorId: 'author-1',
    author: 'tester',
    content: 'content-$id',
    time: '00:00',
    createdAt: createdAt,
    updatedAt: createdAt,
  );
}

List<AppMessage> _range(int from, int to) {
  return [
    for (var i = from; i <= to; i++)
      _msg('$i', DateTime.utc(2026, 1, 1).add(Duration(seconds: i))),
  ];
}

typedef _GetMessagesFn =
    Future<List<AppMessage>> Function(
      String channelId, {
      int? limit,
      String? after,
      String? before,
    });

// Мини-фикстура backend-пагинации: ids — числовые строки, `after`/`before`
// фильтруют и режут по `limit`, как реальный REST-курсор getMessages.
_GetMessagesFn _backedBy(List<AppMessage> all) {
  final sorted = [...all]
    ..sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));

  return (channelId, {limit, after, before}) async {
    var pool = sorted;
    if (after != null) {
      final afterId = int.parse(after);
      pool = pool.where((m) => int.parse(m.id) > afterId).toList();
    }
    if (before != null) {
      final beforeId = int.parse(before);
      pool = pool.where((m) => int.parse(m.id) < beforeId).toList();
    }
    final take = limit ?? pool.length;
    if (pool.length <= take) return pool;
    // `after` (докачка вперёд): следующая страница — самые СТАРЫЕ из
    // оставшихся после курсора. Без курсора вовсе (как и `before`, докачка
    // назад/начальная загрузка) — backend отдаёт самые НОВЫЕ: сначала
    // последнюю страницу, которую затем можно докачивать `before` вглубь
    // истории (см. _catchUpEmptyChannel/selectChannel).
    return after != null
        ? pool.sublist(0, take)
        : pool.sublist(pool.length - take);
  };
}

class _ReconnectSyncHarness {
  _ReconnectSyncHarness(this._getMessages);

  final _GetMessagesFn _getMessages;

  List<AppMessage> messages = [];
  String? selectedChannelId;
  bool isMessagesLoading = false;
  bool reconnectCatchUpInProgress = false;
  String? syncAnchorChannelId;
  String? syncAnchorMessageId;
  String? pendingReconnectSyncChannelId;
  final mounted = true;

  // Фиксирует, какой курсор `after` реально использовал REST-запрос —
  // ключевая проверка сценария: должен быть якорь ('10'), а не
  // messages.last.id ('71'), захваченное после гонки с live-событием.
  final List<String> afterCursorsUsed = [];

  void handleRealtimeMessage(AppMessage message) {
    if (!mounted || message.channelId != selectedChannelId) return;
    if (messages.any((item) => item.id == message.id)) return;
    messages = [...messages, message];
  }

  void handleRealtimeDisconnected() {
    syncAnchorChannelId = selectedChannelId;
    syncAnchorMessageId =
        (selectedChannelId != null && messages.isNotEmpty)
            ? messages.last.id
            : null;
  }

  Future<void> handleRealtimeReconnected(String? channelId) async {
    if (!mounted || channelId == null || channelId != selectedChannelId) {
      return;
    }
    if (isMessagesLoading || reconnectCatchUpInProgress) {
      pendingReconnectSyncChannelId = channelId;
      return;
    }
    await _runReconnectSync(channelId);
  }

  Future<void> _runReconnectSync(String channelId) async {
    pendingReconnectSyncChannelId = null;
    reconnectCatchUpInProgress = true;
    try {
      final hasAnchorForChannel = syncAnchorChannelId == channelId;
      final anchorId = hasAnchorForChannel ? syncAnchorMessageId : null;

      // Вызывает настоящую production-функцию выбора стратегии
      // (main.dart ~6600), а не копию логики — только сами ветки докачки
      // (сетевые вызовы) всё ещё мирроятся harness-ом ниже.
      switch (chooseReconnectSyncStrategy(
        hasAnchorForChannel: hasAnchorForChannel,
        anchorMessageId: anchorId,
        messagesEmpty: messages.isEmpty,
      )) {
        case ReconnectSyncStrategy.afterAnchor:
          await _catchUpMessagesAfter(channelId, anchorId!);
        case ReconnectSyncStrategy.emptyChannelRestore:
          await _catchUpEmptyChannel(channelId);
        case ReconnectSyncStrategy.afterLastMessage:
          await _catchUpMessagesAfter(channelId, messages.last.id);
      }
    } catch (_) {
      // как и в реальном коде — молча игнорируем.
    } finally {
      reconnectCatchUpInProgress = false;
    }
    await flushPendingReconnectSync();
  }

  Future<void> flushPendingReconnectSync() async {
    final pending = pendingReconnectSyncChannelId;
    if (pending == null ||
        !mounted ||
        pending != selectedChannelId ||
        isMessagesLoading ||
        reconnectCatchUpInProgress) {
      return;
    }
    await _runReconnectSync(pending);
  }

  Future<void> _catchUpMessagesAfter(
    String channelId,
    String startCursor,
  ) async {
    const pageSize = 50;
    const maxPages = 40;
    var cursor = startCursor;

    for (var page = 0; page < maxPages; page++) {
      afterCursorsUsed.add(cursor);
      final next = await _getMessages(channelId, limit: pageSize, after: cursor);

      if (!mounted || selectedChannelId != channelId) return;

      if (next.isNotEmpty) {
        messages = mergeMessagesChronologically(messages, next);
        cursor = next.last.id;
      }

      if (next.length < pageSize) return;
    }
  }

  Future<void> _catchUpEmptyChannel(String channelId) async {
    const pageSize = 50;
    final latest = await _getMessages(channelId, limit: pageSize);

    if (!mounted || selectedChannelId != channelId) return;

    final step = applyCatchUpPage(
      current: messages,
      page: latest,
      pageSize: pageSize,
    );
    messages = step.messages;

    final nextCursor = step.nextCursor;
    if (!step.isFull || nextCursor == null) return;

    await _catchUpMessagesBefore(channelId, nextCursor);
  }

  Future<void> _catchUpMessagesBefore(
    String channelId,
    String startCursor,
  ) async {
    const pageSize = 50;
    const maxPages = 40;
    var cursor = startCursor;

    for (var page = 0; page < maxPages; page++) {
      final previous = await _getMessages(channelId, limit: pageSize, before: cursor);

      if (!mounted || selectedChannelId != channelId) return;

      final step = applyCatchUpPage(
        current: messages,
        page: previous,
        pageSize: pageSize,
      );
      messages = step.messages;

      final nextCursor = step.nextCursor;
      if (nextCursor != null) cursor = nextCursor;

      if (!step.isFull) return;
    }
  }
}

void main() {
  group('reconnect sync anchor (mirrors handleRealtimeDisconnected/'
      'handleRealtimeReconnected, main.dart ~1812-1878)', () {
    test(
      'a live message that arrives before catch-up runs does not become '
      'the cursor and does not hide the real gap',
      () async {
        // Backend ("A") содержит сообщения 1-70 — 11-70 отправлены за время
        // обрыва B. #71 придёт отдельно, только по realtime (см. ниже).
        final harness = _ReconnectSyncHarness(_backedBy(_range(1, 70)));
        harness.selectedChannelId = 'channel-1';
        harness.messages = _range(1, 10);

        // B видел 1-10. Соединение рвётся: якорь фиксирует последнее УВИДЕННОЕ
        // сообщение (#10) ДО того, как что-то новое сможет прийти.
        harness.handleRealtimeDisconnected();
        expect(harness.syncAnchorChannelId, 'channel-1');
        expect(harness.syncAnchorMessageId, '10');

        // Реконнект восстановился, и ДО того, как выполнится REST-докачка,
        // по сокету уже прилетело #71 — ровно гонка из описания дефекта.
        harness.handleRealtimeMessage(_msg('71', DateTime.utc(2026, 1, 1, 0, 1, 11)));
        // Без фикса курсором стало бы именно это значение.
        expect(harness.messages.last.id, '71');

        await harness.handleRealtimeReconnected('channel-1');

        // Докачка пошла от якоря '10' (не от '71'), двумя страницами по 50:
        // 11-60 (полная, pageSize=50) и 61-70 (короче — докачка завершена).
        expect(harness.afterCursorsUsed, ['10', '60']);
        expect(
          harness.messages.map((m) => m.id).toList(),
          [for (var i = 1; i <= 71; i++) '$i'],
        );
        expect(
          harness.messages.map((m) => m.id).toSet().length,
          71,
          reason: 'без дублей',
        );
      },
    );

    test(
      'repeated disconnect/reconnect cycles keep rewriting the anchor to '
      'the latest known message without duplicates or stale cursors',
      () async {
        var callCount = 0;
        final harness = _ReconnectSyncHarness((channelId, {limit, after, before}) async {
          callCount++;
          if (callCount == 1) return _range(6, 10);
          // Второй цикл: backend уже содержит #11 (та же live-доставка, что
          // пришла и по сокету) — REST-ответ идемпотентно пересечётся с ней.
          return [_msg('11', DateTime.utc(2026, 1, 1, 0, 0, 11))];
        });
        harness.selectedChannelId = 'channel-1';
        harness.messages = _range(1, 5);

        harness.handleRealtimeDisconnected();
        expect(harness.syncAnchorMessageId, '5');
        await harness.handleRealtimeReconnected('channel-1');
        expect(harness.afterCursorsUsed, ['5']);
        expect(harness.messages.map((m) => m.id).toList(), [for (var i = 1; i <= 10; i++) '$i']);

        // Второй обрыв: якорь должен перезаписаться на актуальное #10, а не
        // остаться на #5 и не накопить мусор от первого цикла.
        harness.handleRealtimeDisconnected();
        expect(harness.syncAnchorMessageId, '10');

        harness.handleRealtimeMessage(_msg('11', DateTime.utc(2026, 1, 1, 0, 0, 11)));
        await harness.handleRealtimeReconnected('channel-1');

        expect(harness.afterCursorsUsed, ['5', '10']);
        expect(
          harness.messages.map((m) => m.id).toList(),
          [for (var i = 1; i <= 11; i++) '$i'],
        );
        expect(harness.messages.map((m) => m.id).toSet().length, 11);
      },
    );

    test(
      'a reconnect that arrives while busy is not lost and runs right '
      'after the current operation frees up',
      () async {
        final harness = _ReconnectSyncHarness(_backedBy(_range(1, 10)));
        harness.selectedChannelId = 'channel-1';
        harness.messages = _range(1, 5);
        harness.handleRealtimeDisconnected();

        // Первоначальная загрузка канала ещё идёт — реконнект не должен
        // молча потеряться, а должен быть отложен.
        harness.isMessagesLoading = true;
        await harness.handleRealtimeReconnected('channel-1');
        expect(harness.afterCursorsUsed, isEmpty);
        expect(harness.pendingReconnectSyncChannelId, 'channel-1');

        // Первоначальная загрузка завершилась — отложенная синхронизация
        // выполняется немедленно, а не ждёт следующего случайного реконнекта.
        harness.isMessagesLoading = false;
        await harness.flushPendingReconnectSync();

        expect(harness.afterCursorsUsed, ['5']);
        expect(harness.pendingReconnectSyncChannelId, isNull);
        expect(
          harness.messages.map((m) => m.id).toList(),
          [for (var i = 1; i <= 10; i++) '$i'],
        );
      },
    );

    test(
      'switching the selected channel while catch-up for the previous '
      'channel is still in flight does not leak messages across channels',
      () async {
        final pageA = Completer<List<AppMessage>>();
        final harness = _ReconnectSyncHarness((channelId, {limit, after, before}) {
          return pageA.future;
        });
        harness.selectedChannelId = 'channel-1';
        harness.messages = _range(1, 5);
        harness.handleRealtimeDisconnected();

        final pending = harness.handleRealtimeReconnected('channel-1');

        // Пока REST-ответ канала A ещё не пришёл, пользователь переключается
        // на канал B — это защищено существующей проверкой
        // selectedChannelId != channelId внутри _catchUpMessagesAfter.
        harness.selectedChannelId = 'channel-2';
        harness.messages = _range(100, 102);

        pageA.complete(_range(6, 50));
        await pending;

        expect(
          harness.messages.map((m) => m.id).toList(),
          ['100', '101', '102'],
          reason: 'докачка канала A не должна писать в messages канала B',
        );
      },
    );

    test(
      'channel empty at disconnect time + a live message arriving before '
      'reconnect runs must still trigger full empty-channel restore, not '
      'be mistaken for "no anchor at all"',
      () async {
        // Backend содержит полную историю 1-70 (канал был пуст у B только
        // локально — например, B присоединился во время обрыва и ещё не
        // успел ничего загрузить).
        final harness = _ReconnectSyncHarness(_backedBy(_range(1, 70)));
        harness.selectedChannelId = 'channel-1';
        harness.messages = [];

        // Разрыв застаёт канал пустым: якорь зафиксирован (канал == этот),
        // но anchorMessageId == null — это НЕ "якоря нет вовсе".
        harness.handleRealtimeDisconnected();
        expect(harness.syncAnchorChannelId, 'channel-1');
        expect(harness.syncAnchorMessageId, isNull);

        // До того, как реально выполнится докачка, по восстановленному
        // соединению уже пришло #71 по realtime.
        harness.handleRealtimeMessage(
          _msg('71', DateTime.utc(2026, 1, 1, 0, 1, 11)),
        );
        expect(harness.messages.map((m) => m.id).toList(), ['71']);

        await harness.handleRealtimeReconnected('channel-1');

        // Без фикса messages было бы непустым («71») и код бы попал в ветку
        // "докачка after messages.last.id('71')" — backend ничего не вернёт
        // после 71, и история 1-70 потерялась бы молча. Форвард-курсор не
        // использовался вовсе — восстановление прошло через
        // _catchUpEmptyChannel (без курсора) + докачку назад.
        expect(harness.afterCursorsUsed, isEmpty);
        expect(
          harness.messages.map((m) => m.id).toList(),
          [for (var i = 1; i <= 71; i++) '$i'],
        );
        expect(
          harness.messages.map((m) => m.id).toSet().length,
          71,
          reason: 'без дублей',
        );
      },
    );
  });

  group('chooseReconnectSyncStrategy (pure decision function, main.dart '
      '~6600, used directly by _runReconnectSync)', () {
    test('anchor present for the channel -> afterAnchor', () {
      expect(
        chooseReconnectSyncStrategy(
          hasAnchorForChannel: true,
          anchorMessageId: 'm10',
          messagesEmpty: false,
        ),
        ReconnectSyncStrategy.afterAnchor,
      );

      // Якорь главнее текущего messagesEmpty (которое может быть устаревшим
      // из-за гонки с live-сообщением) — проверяем, что сам messagesEmpty не
      // влияет на эту ветку.
      expect(
        chooseReconnectSyncStrategy(
          hasAnchorForChannel: true,
          anchorMessageId: 'm10',
          messagesEmpty: true,
        ),
        ReconnectSyncStrategy.afterAnchor,
      );
    });

    test(
      'anchor for the channel exists but is explicitly null (channel was '
      'empty at disconnect) -> emptyChannelRestore, regardless of current '
      'messagesEmpty',
      () {
        expect(
          chooseReconnectSyncStrategy(
            hasAnchorForChannel: true,
            anchorMessageId: null,
            messagesEmpty: false,
          ),
          ReconnectSyncStrategy.emptyChannelRestore,
          reason: 'даже если messages уже непустой из-за live-гонки',
        );

        expect(
          chooseReconnectSyncStrategy(
            hasAnchorForChannel: true,
            anchorMessageId: null,
            messagesEmpty: true,
          ),
          ReconnectSyncStrategy.emptyChannelRestore,
        );
      },
    );

    test(
      'no anchor for the channel at all (e.g. first connect, no prior '
      'onDisconnect) and messages not empty -> afterLastMessage fallback',
      () {
        expect(
          chooseReconnectSyncStrategy(
            hasAnchorForChannel: false,
            anchorMessageId: null,
            messagesEmpty: false,
          ),
          ReconnectSyncStrategy.afterLastMessage,
        );
      },
    );

    test(
      'no anchor for the channel at all and messages empty -> '
      'emptyChannelRestore (boundary case)',
      () {
        expect(
          chooseReconnectSyncStrategy(
            hasAnchorForChannel: false,
            anchorMessageId: null,
            messagesEmpty: true,
          ),
          ReconnectSyncStrategy.emptyChannelRestore,
        );
      },
    );
  });
}
