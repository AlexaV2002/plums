// Восстановление истории после (пере)входа в комнату Socket.IO (A04).
// Тесты драйвят РЕАЛЬНЫЙ MessageSyncController из main.dart поверх
// in-memory backend (test/support/fake_message_backend.dart); от
// _MainShellState повторена только тривиальная обвязка handleRealtimeMessage
// (SyncFixture.live: добавить без дубля + controller.onLiveMessage).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

import 'support/fake_message_backend.dart';

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('MessageSyncController: confirmed sync point', () {
    test(
      '1. first connect: live #71 during the first page never becomes the '
      'cursor; history 1-71 is restored from the REST baseline',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 10));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));

        // Пока сокет ещё не в комнате, A отправляет 11-70.
        backend.add(range(11, 70));
        // B вошёл в комнату; live #71 приходит во время первой REST-страницы.
        backend.beforeRespond = (call) {
          if (call == 1) f.live(msg(71));
        };

        await f.sync.onRoomJoined('channel-1');

        expect(backend.calls.first.after, '10');
        expect(backend.afterCursors, ['10', '60']);
        expect(ids(f.messages), idRange(1, 71));
        expect(f.sync.inSync, isTrue);
        expect(f.sync.confirmedMessageId, '71');
        expect(f.incomplete, isEmpty);
      },
    );

    test(
      '2. channel empty at disconnect + live #71 before sync -> full '
      'restore 1-71 without a forward cursor',
      () async {
        final backend = FakeMessageBackend();
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', const []);
        expect(f.sync.baselineKnown, isTrue);
        expect(f.sync.confirmedMessageId, isNull);

        f.sync.onDisconnected();
        backend.add(range(1, 70));
        f.live(msg(71));
        expect(ids(f.messages), ['71']);

        await f.sync.onRoomJoined('channel-1');

        expect(backend.afterCursors, everyElement(isNull));
        expect(backend.calls.map((c) => c.before).toList(), [null, '22']);
        expect(ids(f.messages), idRange(1, 71));
        expect(f.hasMore, isFalse);
        expect(f.sync.confirmedMessageId, '71');
        expect(f.sync.inSync, isTrue);
      },
    );

    test(
      '3. non-empty channel: 10 + 60 missed + live #71 -> 1-71 without '
      'duplicates, cursor is the confirmed point (10), not #71',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 10));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        await f.sync.onRoomJoined('channel-1');
        expect(f.sync.inSync, isTrue);

        f.sync.onDisconnected();
        backend.add(range(11, 70));
        f.live(msg(71));
        expect(f.sync.confirmedMessageId, '10');

        await f.sync.onRoomJoined('channel-1');

        expect(backend.afterCursors, ['10', '10', '60']);
        expect(ids(f.messages), idRange(1, 71));
        expect(ids(f.messages).toSet(), hasLength(71));
      },
    );

    test(
      '4. two quick disconnect/reconnect cycles: the second join is pending '
      'and runs after the first cycle, fetch is never concurrent',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 10));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        backend.add(range(11, 130));
        final gate = Completer<void>();
        backend.beforeRespond = (call) async {
          if (call == 1) await gate.future;
        };

        f.sync.onDisconnected();
        final first = f.sync.onRoomJoined('channel-1');
        await _settle();
        expect(backend.calls, hasLength(1));
        expect(f.sync.isRunning, isTrue);

        f.sync.onDisconnected();
        final second = f.sync.onRoomJoined('channel-1');
        await _settle();
        expect(backend.calls, hasLength(1), reason: 'no concurrent cycle');
        expect(f.sync.pendingChannelId, 'channel-1');

        gate.complete();
        await Future.wait([first, second]);

        expect(backend.maxInFlight, 1);
        expect(backend.afterCursors, ['10', '60', '110', '130']);
        expect(ids(f.messages), idRange(1, 130));
        expect(f.sync.pendingChannelId, isNull);
        expect(f.sync.inSync, isTrue);
        expect(f.incomplete, isEmpty);
      },
    );

    test(
      '5. disconnect in the middle of catch-up: the next cycle resumes from '
      'the last confirmed page (60), not from live #71',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 10));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        backend.add(range(11, 70));
        backend.failOnCalls.add(2);
        backend.beforeRespond = (call) {
          if (call == 2) {
            f.live(msg(71));
            f.sync.onDisconnected();
          }
        };

        await f.sync.onRoomJoined('channel-1');
        expect(f.sync.confirmedMessageId, '60');
        expect(f.sync.inSync, isFalse);
        expect(ids(f.messages), [...idRange(1, 60), '71']);

        backend.add(range(72, 120));
        await f.sync.onRoomJoined('channel-1');

        expect(backend.calls[2].after, '60');
        expect(ids(f.messages), idRange(1, 120));
        expect(ids(f.messages).toSet(), hasLength(120));
        expect(f.sync.inSync, isTrue);
      },
    );

    test(
      '6. join confirmed while the baseline is still loading -> pending, '
      'runs after confirmBaseline + flushPending',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 30));
        final f = SyncFixture(backend);
        f.sync.resetForChannel('channel-1', baselineLoading: true);

        await f.sync.onRoomJoined('channel-1');
        expect(backend.calls, isEmpty);
        expect(f.sync.pendingChannelId, 'channel-1');

        f.messages = range(1, 10);
        f.sync.confirmBaseline('channel-1', range(1, 10));
        await f.sync.flushPending();

        expect(backend.afterCursors, ['10']);
        expect(ids(f.messages), idRange(1, 30));
        expect(f.sync.pendingChannelId, isNull);
        expect(f.sync.inSync, isTrue);
      },
    );

    test(
      '6b. baseline REST failed -> pending join restores without a cursor',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 30));
        final f = SyncFixture(backend);
        f.sync.resetForChannel('channel-1', baselineLoading: true);
        await f.sync.onRoomJoined('channel-1');
        expect(backend.calls, isEmpty);

        f.sync.abortBaseline('channel-1');
        await f.sync.flushPending();

        expect(backend.calls.single.after, isNull);
        expect(backend.calls.single.before, isNull);
        expect(ids(f.messages), idRange(1, 30));
        expect(f.sync.baselineKnown, isTrue);
        expect(f.sync.confirmedMessageId, '30');
      },
    );

    test(
      '7. second page fails -> onIncomplete, confirmed stays at the first '
      'page boundary, retry completes without duplicates',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 130));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        backend.failOnCalls.add(2);

        await f.sync.onRoomJoined('channel-1');

        expect(f.incomplete, ['channel-1']);
        expect(f.sync.confirmedMessageId, '60');
        expect(f.sync.inSync, isFalse);
        expect(ids(f.messages), idRange(1, 60));

        await f.lastRetry!();

        expect(backend.afterCursors, ['10', '60', '60', '110']);
        expect(ids(f.messages), idRange(1, 130));
        expect(f.sync.inSync, isTrue);
        expect(f.incomplete, hasLength(1));
      },
    );

    test(
      '8. switching the channel during catch-up drops the old results',
      () async {
        final backend = FakeMessageBackend()
          ..add(range(1, 40))
          ..add(range(100, 102, channelId: 'channel-2'));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        final gate = Completer<void>();
        backend.beforeRespond = (call) async {
          if (call == 1) await gate.future;
        };

        final stale = f.sync.onRoomJoined('channel-1');
        await _settle();
        f.loadBaseline(
          'channel-2',
          range(100, 102, channelId: 'channel-2'),
        );
        expect(f.sync.isRunning, isFalse);

        gate.complete();
        await stale;

        expect(ids(f.messages), ['100', '101', '102']);
        expect(f.incomplete, isEmpty);
        expect(f.sync.confirmedMessageId, '102');

        await f.sync.onRoomJoined('channel-2');
        expect(backend.calls.last.channelId, 'channel-2');
        expect(backend.calls.last.after, '102');
        expect(ids(f.messages), ['100', '101', '102']);
        expect(f.sync.inSync, isTrue);
      },
    );

    test('9. the same message via REST and live is kept once', () async {
      final backend = FakeMessageBackend()..add(range(1, 10));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', range(1, 10));
      await f.sync.onRoomJoined('channel-1');

      f.sync.onDisconnected();
      f.live(msg(11));
      await f.sync.onRoomJoined('channel-1');

      expect(backend.calls.last.after, '10');
      expect(ids(f.messages), idRange(1, 11));
      expect(ids(f.messages).where((id) => id == '11'), hasLength(1));
    });

    test(
      '10. maxPages reached with a full page -> onIncomplete, not a silent '
      'success; retry continues from the confirmed point',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 210));
        final f = SyncFixture(backend, maxPages: 2);
        f.loadBaseline('channel-1', range(1, 10));

        await f.sync.onRoomJoined('channel-1');
        expect(f.incomplete, ['channel-1']);
        expect(f.sync.inSync, isFalse);
        expect(f.sync.confirmedMessageId, '110');

        await f.lastRetry!();
        expect(f.incomplete, hasLength(2), reason: '161-210 is full again');
        expect(f.sync.confirmedMessageId, '210');

        await f.lastRetry!();
        expect(f.incomplete, hasLength(2));
        expect(f.sync.inSync, isTrue);
        expect(ids(f.messages), idRange(1, 210));
      },
    );

    test('11. 150 missed messages are restored page by page', () async {
      final backend = FakeMessageBackend()..add(range(1, 160));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', range(1, 10));

      await f.sync.onRoomJoined('channel-1');

      expect(backend.afterCursors, ['10', '60', '110', '160']);
      expect(ids(f.messages), idRange(1, 160));
      expect(f.sync.inSync, isTrue);
      expect(f.incomplete, isEmpty);
    });

    test(
      '12. live messages advance the point only while in sync',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 10));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));

        f.live(msg(11));
        expect(f.sync.confirmedMessageId, '10', reason: 'not joined yet');

        await f.sync.onRoomJoined('channel-1');
        expect(f.sync.inSync, isTrue);
        expect(f.sync.confirmedMessageId, '11');

        f.live(msg(12));
        expect(f.sync.confirmedMessageId, '12');

        f.sync.onDisconnected();
        f.live(msg(13));
        expect(f.sync.confirmedMessageId, '12');

        await f.sync.onRoomJoined('channel-1');
        expect(backend.calls.last.after, '12');
        expect(ids(f.messages), idRange(1, 13));
      },
    );

    test('join for a channel that is not selected is ignored', () async {
      final backend = FakeMessageBackend()..add(range(1, 10));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', range(1, 10));
      f.selected = 'channel-2';

      await f.sync.onRoomJoined('channel-1');

      expect(backend.calls, isEmpty);
    });
  });

  group('chooseReconnectSyncStrategy', () {
    test('known non-empty baseline -> afterConfirmed', () {
      expect(
        chooseReconnectSyncStrategy(
          baselineKnown: true,
          confirmedMessageId: '10',
        ),
        ReconnectSyncStrategy.afterConfirmed,
      );
    });

    test('confirmed empty or unknown baseline -> restoreLatest', () {
      expect(
        chooseReconnectSyncStrategy(
          baselineKnown: true,
          confirmedMessageId: null,
        ),
        ReconnectSyncStrategy.restoreLatest,
      );
      expect(
        chooseReconnectSyncStrategy(
          baselineKnown: false,
          confirmedMessageId: null,
        ),
        ReconnectSyncStrategy.restoreLatest,
      );
    });
  });
}
