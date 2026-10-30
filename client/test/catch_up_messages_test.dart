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

// Воспроизводит цикл докачки НАЗАД после фикса "дефекта 2": ошибка на
// отдельной странице (элемент [pages] равен null) больше не делает `return`
// до snackbar — цикл прерывается, но функция возвращает `failed: true` и
// курсор, достигнутый последней УСПЕШНО обработанной страницей (ровно то,
// что передаст кнопка "Повторить" в реальном _catchUpMessagesBefore).
({
  List<AppMessage> messages,
  bool hasMoreMessages,
  bool interrupted,
  bool failed,
  String cursor,
})
_runBackwardCatchUpWithFailures(
  List<AppMessage> initial,
  List<List<AppMessage>?> pages, {
  required String startCursor,
  int pageSize = 50,
  int maxPages = 40,
}) {
  var messages = initial;
  var hasMoreMessages = false;
  var cursor = startCursor;
  var failed = false;

  try {
    for (var i = 0; i < pages.length && i < maxPages; i++) {
      final page = pages[i];
      if (page == null) {
        throw Exception('network error on page $i');
      }

      final step = applyCatchUpPage(
        current: messages,
        page: page,
        pageSize: pageSize,
      );
      messages = step.messages;
      hasMoreMessages = step.isFull;

      final nextCursor = step.nextCursor;
      if (nextCursor != null) {
        cursor = nextCursor;
      }

      if (!step.isFull) {
        return (
          messages: messages,
          hasMoreMessages: false,
          interrupted: false,
          failed: false,
          cursor: cursor,
        );
      }
    }
  } catch (_) {
    failed = true;
  }

  return (
    messages: messages,
    hasMoreMessages: hasMoreMessages,
    interrupted: hasMoreMessages || failed,
    failed: failed,
    cursor: cursor,
  );
}

// Симметричный хелпер для направления ВПЕРЁД (мирроит _catchUpMessagesAfter
// после фикса): страницы сливаются через mergeMessagesChronologically,
// курсор продвигается на id последнего сообщения страницы.
({List<AppMessage> messages, bool failed, bool interrupted, String cursor})
_runForwardCatchUpWithFailures(
  List<AppMessage> initial,
  List<List<AppMessage>?> pages, {
  required String startCursor,
  int pageSize = 50,
  int maxPages = 40,
}) {
  var messages = initial;
  var cursor = startCursor;
  var lastPageWasFull = false;
  var failed = false;

  try {
    for (var i = 0; i < pages.length && i < maxPages; i++) {
      final next = pages[i];
      if (next == null) {
        throw Exception('network error on page $i');
      }

      if (next.isNotEmpty) {
        messages = mergeMessagesChronologically(messages, next);
        cursor = next.last.id;
      }

      lastPageWasFull = next.length >= pageSize;
      if (!lastPageWasFull) {
        return (
          messages: messages,
          failed: false,
          interrupted: false,
          cursor: cursor,
        );
      }
    }
  } catch (_) {
    failed = true;
  }

  return (
    messages: messages,
    failed: failed,
    interrupted: lastPageWasFull || failed,
    cursor: cursor,
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

  // Регрессия на "дефект 2": ошибка на отдельной странице (не исчерпание
  // maxPages, а настоящее исключение сети) больше не должна "сдаваться"
  // молча — цикл обязан остановиться на границе последней УСПЕШНО
  // обработанной страницы и сохранить курсор для кнопки "Повторить", а не
  // прервать выполнение до того, как об этом можно узнать.
  group('catch-up loop reports a page-level network failure (defect 2)', () {
    test(
      'backward: channel with 120 messages, page 2 throws -> cursor stays '
      'at the boundary of the first successful page',
      () {
        final initial = _page(70, 50); // id70..119, nextCursor уже 'm70'
        final result = _runBackwardCatchUpWithFailures(
          initial,
          [_page(20, 50), null], // страница 2 (id20..69) ok, страница 3 throws
          startCursor: 'm70',
        );

        expect(result.failed, isTrue);
        expect(result.interrupted, isTrue);
        // Курсор продвинулся только до границы УСПЕШНО обработанной
        // страницы (id20..69), не потерян и не "ушёл" дальше.
        expect(result.cursor, 'm20');
        expect(result.messages, hasLength(100)); // id20..119
      },
    );

    test(
      'backward: retry from the saved cursor completes the remaining '
      'history without duplicates',
      () {
        final initial = _page(70, 50);
        final firstAttempt = _runBackwardCatchUpWithFailures(
          initial,
          [_page(20, 50), null],
          startCursor: 'm70',
        );
        expect(firstAttempt.failed, isTrue);

        // "Повторить" продолжает с сохранённого курсора (не с начала).
        final retry = _runBackwardCatchUpWithFailures(
          firstAttempt.messages,
          [_page(0, 20)], // id0..19 — короче pageSize, завершает докачку
          startCursor: firstAttempt.cursor,
        );

        expect(retry.failed, isFalse);
        expect(retry.interrupted, isFalse);
        expect(retry.messages, hasLength(120));
        expect(
          retry.messages.map((m) => m.id).toSet(),
          _page(0, 120).map((m) => m.id).toSet(),
        );
      },
    );

    test(
      'backward: a live message present before the failing page survives '
      'the error and the retry without being duplicated',
      () {
        final live = _message(id: 'z-live', createdAt: DateTime.utc(2027));
        final initial = [..._page(70, 50), live];

        final firstAttempt = _runBackwardCatchUpWithFailures(
          initial,
          [_page(20, 50), null],
          startCursor: 'm70',
        );
        expect(firstAttempt.failed, isTrue);
        expect(
          firstAttempt.messages.where((m) => m.id == 'z-live'),
          hasLength(1),
        );

        final retry = _runBackwardCatchUpWithFailures(
          firstAttempt.messages,
          [_page(0, 20)],
          startCursor: firstAttempt.cursor,
        );

        expect(retry.messages.where((m) => m.id == 'z-live'), hasLength(1));
        expect(retry.messages, hasLength(121)); // 120 истории + live
      },
    );

    test(
      'backward: a live message that arrived before the very first catch-up '
      'page (channel:join race) is not lost even if that first page fails',
      () {
        final live = _message(id: 'z-live', createdAt: DateTime.utc(2027));
        // current уже содержит live-сообщение к моменту первого вызова —
        // симулирует "сообщение прилетело сразу после channel:join, до того
        // как докачка успела сделать первый запрос".
        final initial = [..._page(70, 50), live];

        final firstAttempt = _runBackwardCatchUpWithFailures(
          initial,
          [null], // первая же страница падает
          startCursor: 'm70',
        );

        expect(firstAttempt.failed, isTrue);
        expect(
          firstAttempt.messages.where((m) => m.id == 'z-live'),
          hasLength(1),
        );
        expect(firstAttempt.messages, hasLength(51)); // 50 исходных + live
      },
    );

    test(
      'forward: channel with 120 messages, page 2 throws -> cursor stays '
      'at the boundary of the first successful page',
      () {
        final initial = _page(1, 10); // id1..10, последнее известное m10
        final result = _runForwardCatchUpWithFailures(
          initial,
          [_page(11, 50), null], // страница id11..60 ok, страница 2 throws
          startCursor: 'm10',
        );

        expect(result.failed, isTrue);
        expect(result.interrupted, isTrue);
        expect(result.cursor, 'm60');
        expect(result.messages, hasLength(60)); // id1..60
      },
    );

    test(
      'forward: retry from the saved cursor completes the remaining '
      'history without duplicates',
      () {
        final initial = _page(1, 10);
        final firstAttempt = _runForwardCatchUpWithFailures(
          initial,
          [_page(11, 50), null],
          startCursor: 'm10',
        );
        expect(firstAttempt.failed, isTrue);

        final retry = _runForwardCatchUpWithFailures(
          firstAttempt.messages,
          [_page(61, 50), _page(111, 10)], // id61..110, затем id111..120 (short)
          startCursor: firstAttempt.cursor,
        );

        expect(retry.failed, isFalse);
        expect(retry.interrupted, isFalse);
        expect(retry.messages, hasLength(120));
        expect(
          retry.messages.map((m) => m.id).toSet(),
          _page(1, 120).map((m) => m.id).toSet(),
        );
      },
    );

    test(
      'forward: a live message present before the failing page survives '
      'the error and the retry without being duplicated',
      () {
        final live = _message(id: 'z-live', createdAt: DateTime.utc(2027));
        final initial = [..._page(1, 10), live];

        final firstAttempt = _runForwardCatchUpWithFailures(
          initial,
          [_page(11, 50), null],
          startCursor: 'm10',
        );
        expect(firstAttempt.failed, isTrue);
        expect(
          firstAttempt.messages.where((m) => m.id == 'z-live'),
          hasLength(1),
        );

        final retry = _runForwardCatchUpWithFailures(
          firstAttempt.messages,
          [_page(61, 50), _page(111, 10)],
          startCursor: firstAttempt.cursor,
        );

        expect(retry.messages.where((m) => m.id == 'z-live'), hasLength(1));
        expect(retry.messages, hasLength(121)); // 120 истории + live
      },
    );
  });
}
