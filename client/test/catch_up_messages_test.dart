import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

import 'support/fake_message_backend.dart';

AppMessage _message({required String id, required DateTime createdAt}) {
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

// Нумерует сообщения так, чтобы id и порядок createdAt совпадали — так же,
// как возвращает backend (сообщения в хронологическом порядке, старые
// первыми), что и предполагает applyCatchUpPage (nextCursor = page.first.id).
List<AppMessage> _page(int startSeq, int count) {
  return List.generate(
    count,
    (i) => _message(
      id: 'm${startSeq + i}',
      createdAt: DateTime.utc(2026, 1, 1).add(
        Duration(seconds: startSeq + i),
      ),
    ),
  );
}

void main() {
  group('applyCatchUpPage', () {
    test('empty page stops catch-up without advancing the cursor', () {
      final step = applyCatchUpPage(current: const [], page: const [], pageSize: 50);

      expect(step.isFull, isFalse);
      expect(step.nextCursor, isNull);
      expect(step.messages, isEmpty);
    });

    test('a short page (< pageSize) is reported as not full', () {
      final page = _page(0, 10);

      final step = applyCatchUpPage(current: const [], page: page, pageSize: 50);

      expect(step.isFull, isFalse);
      expect(step.nextCursor, page.first.id);
      expect(step.messages, hasLength(10));
    });

    test('a full page (== pageSize) is reported as full', () {
      final page = _page(0, 50);

      final step = applyCatchUpPage(current: const [], page: page, pageSize: 50);

      expect(step.isFull, isTrue);
      expect(step.nextCursor, page.first.id);
    });

    test('merging a page that overlaps a live message deduplicates by id', () {
      final live = _page(49, 1); // то же id, что последнее сообщение страницы
      final page = _page(0, 50);

      final step = applyCatchUpPage(current: live, page: page, pageSize: 50);

      expect(step.messages, hasLength(50));
      expect(
        step.messages.map((m) => m.id).toSet(),
        page.map((m) => m.id).toSet(),
      );
    });
  });

  // Восстановление пустого/неизвестного baseline: последняя страница без
  // курсора + докачка назад (MessageSyncController, restoreLatest).
  group('MessageSyncController: backward restore', () {
    test('channel with exactly 60 messages is fully restored in 2 pages', () async {
      final backend = FakeMessageBackend()..add(range(1, 60));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', const []);

      await f.sync.onRoomJoined('channel-1');

      expect(backend.calls.map((c) => c.before).toList(), [null, '11']);
      expect(ids(f.messages), idRange(1, 60));
      expect(f.hasMore, isFalse);
      expect(f.incomplete, isEmpty);
    });

    test('channel with exactly 120 messages needs 3 pages total', () async {
      final backend = FakeMessageBackend()..add(range(1, 120));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', const []);

      await f.sync.onRoomJoined('channel-1');

      expect(backend.calls.map((c) => c.before).toList(), [null, '71', '21']);
      expect(ids(f.messages), idRange(1, 120));
      expect(f.hasMore, isFalse);
    });

    test('a live message that arrives mid catch-up is kept once', () async {
      final backend = FakeMessageBackend()..add(range(1, 100));
      final f = SyncFixture(backend);
      f.loadBaseline('channel-1', const []);
      backend.beforeRespond = (call) {
        if (call == 2) f.live(msg(101));
      };

      await f.sync.onRoomJoined('channel-1');

      expect(ids(f.messages), idRange(1, 101));
    });

    test('catch-up interrupted by maxPages is NOT reported as complete', () async {
      final backend = FakeMessageBackend()..add(range(1, 300));
      final f = SyncFixture(backend, maxPages: 2);
      f.loadBaseline('channel-1', const []);

      await f.sync.onRoomJoined('channel-1');

      expect(f.incomplete, ['channel-1']);
      expect(f.hasMore, isTrue);
      expect(f.sync.inSync, isFalse);
      expect(ids(f.messages), idRange(151, 300));
    });
  });

  // Ошибка отдельной страницы: цикл останавливается на последней успешной
  // странице, onIncomplete даёт «Повторить», retry продолжает с неё.
  group('MessageSyncController: page-level network failure', () {
    test(
      'backward: page 3 throws -> progress kept, retry completes the '
      'history without duplicates',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 120));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', const []);
        backend.failOnCalls.add(3);

        await f.sync.onRoomJoined('channel-1');

        expect(f.incomplete, ['channel-1']);
        expect(ids(f.messages), idRange(21, 120));
        expect(f.sync.confirmedMessageId, '120');

        await f.lastRetry!();

        expect(backend.calls[3].after, '120');
        expect(backend.calls[4].before, '21');
        expect(ids(f.messages), idRange(1, 120));
        expect(f.incomplete, hasLength(1));
        expect(f.sync.inSync, isTrue);
      },
    );

    test(
      'backward: a live message delivered before the failing page survives '
      'the error and the retry without being duplicated',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 120));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', const []);
        backend.failOnCalls.add(3);
        backend.beforeRespond = (call) {
          if (call == 3) f.live(msg(121));
        };

        await f.sync.onRoomJoined('channel-1');
        expect(ids(f.messages), idRange(21, 121));

        await f.lastRetry!();

        expect(ids(f.messages), idRange(1, 121));
      },
    );

    test(
      'forward: page 2 throws -> confirmed point stays at the first page '
      'boundary; live message survives; retry completes',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 120));
        final f = SyncFixture(backend);
        f.loadBaseline('channel-1', range(1, 10));
        backend.failOnCalls.add(2);
        backend.beforeRespond = (call) {
          if (call == 2) f.live(msg(121));
        };

        await f.sync.onRoomJoined('channel-1');

        expect(f.incomplete, ['channel-1']);
        expect(f.sync.confirmedMessageId, '60');
        expect(ids(f.messages), [...idRange(1, 60), '121']);

        await f.lastRetry!();

        expect(backend.afterCursors.skip(2).toList(),['60', '110']);
        expect(ids(f.messages), idRange(1, 121));
      },
    );

    test(
      'unknown baseline: the very first page (no cursor) throws -> '
      'incomplete, nothing confirmed, retry restores everything',
      () async {
        final backend = FakeMessageBackend()..add(range(1, 90));
        final f = SyncFixture(backend);
        f.sync.resetForChannel('channel-1');
        backend.failOnCalls.add(1);

        await f.sync.onRoomJoined('channel-1');

        expect(f.incomplete, ['channel-1']);
        expect(f.sync.baselineKnown, isFalse);
        expect(f.sync.confirmedMessageId, isNull);
        expect(f.messages, isEmpty);

        f.live(msg(91));
        await f.lastRetry!();

        expect(backend.calls[1].after, isNull);
        expect(ids(f.messages), idRange(1, 91));
        expect(f.sync.confirmedMessageId, '91');
      },
    );
  });
}
