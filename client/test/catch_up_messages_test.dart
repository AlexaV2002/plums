import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

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

// Воспроизводит цикл докачки НАЗАД, который реализует
// _MainShellState._catchUpMessagesBefore: постранично читает фиктивные
// страницы из [pages] (как если бы их возвращал apiClient.getMessages с
// курсором `before`) и прогоняет каждую через applyCatchUpPage, пока
// страница не окажется короче pageSize или не будет исчерпан maxPages.
({List<AppMessage> messages, bool hasMoreMessages, bool interrupted})
_runBackwardCatchUp(
  List<AppMessage> initial,
  List<List<AppMessage>> pages, {
  int pageSize = 50,
  int maxPages = 40,
}) {
  var messages = initial;
  var hasMoreMessages = false;

  for (var i = 0; i < pages.length && i < maxPages; i++) {
    final step = applyCatchUpPage(
      current: messages,
      page: pages[i],
      pageSize: pageSize,
    );
    messages = step.messages;
    hasMoreMessages = step.isFull;

    if (!step.isFull) {
      return (
        messages: messages,
        hasMoreMessages: false,
        interrupted: false,
      );
    }
  }

  // Цикл дошёл до maxPages (или до конца списка фикстур в тесте) с ещё
  // полной последней страницей — докачка не завершена, в реальном коде это
  // ветка "показать snackbar с Повторить".
  return (messages: messages, hasMoreMessages: hasMoreMessages, interrupted: hasMoreMessages);
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

  group('backward catch-up loop (mirrors _catchUpMessagesBefore)', () {
    test('channel with exactly 60 messages is fully restored in 2 pages', () {
      // Страница без курсора уже выдала последние 50 (id 10..59); докачка
      // назад должна забрать оставшиеся 10 (id 0..9) одной короткой страницей.
      final result = _runBackwardCatchUp(_page(10, 50), [_page(0, 10)]);

      expect(result.hasMoreMessages, isFalse);
      expect(result.interrupted, isFalse);
      expect(result.messages, hasLength(60));
    });

    test('channel with exactly 120 messages needs 3 pages total', () {
      // Первая страница (без курсора) уже вернула id 70..119 (последние 50).
      final initial = _page(70, 50);

      final result = _runBackwardCatchUp(initial, [
        _page(20, 50), // id 20..69
        _page(0, 20), // id 0..19 — короче pageSize, докачка завершена
      ]);

      expect(result.hasMoreMessages, isFalse);
      expect(result.interrupted, isFalse);
      expect(result.messages, hasLength(120));
    });

    test(
      'a live message that arrives mid catch-up is kept, not overwritten',
      () {
        final initial = _page(50, 50); // id 50..99
        final live = _message(
          id: 'z-live',
          createdAt: DateTime.utc(2027),
        ); // новее всех, прилетело по realtime во время докачки

        // Симулируем: перед обработкой первой страницы докачки назад
        // в messages уже добавлено live-сообщение.
        final afterLive = [...initial, live];
        final result = _runBackwardCatchUp(afterLive, [_page(0, 50)]);

        expect(result.messages.map((m) => m.id), contains('z-live'));
        expect(result.messages, hasLength(101));
      },
    );

    test(
      'catch-up interrupted by maxPages is NOT reported as complete',
      () {
        // 3 страницы по 50 — все полные, но maxPages=2 обрывает цикл раньше,
        // чем страница окажется короче pageSize.
        final result = _runBackwardCatchUp(
          _page(100, 50),
          [_page(50, 50), _page(0, 50)],
          maxPages: 2,
        );

        expect(result.interrupted, isTrue);
        expect(result.hasMoreMessages, isTrue);
      },
    );
  });
}
