import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

AppMessage _message({
  required String id,
  required DateTime createdAt,
}) {
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

void main() {
  group('mergeMessagesChronologically', () {
    test('deduplicates by id, preferring the incoming version', () {
      final base = _message(
        id: 'm1',
        createdAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
      );
      final updated = _message(
        id: 'm1',
        createdAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
      );

      final merged = mergeMessagesChronologically([base], [updated]);

      expect(merged.length, 1);
      expect(merged.single.id, 'm1');
    });

    test(
      'restores chronological order when a newer live message races ahead '
      'of older catch-up pages',
      () {
        // Воспроизводит сценарий гонки из багрепорта: во время докачки
        // страницы [M51..M100] по этому же соединению уже успело прилететь
        // новое live-сообщение M200 (отправленное ПОСЛЕ реконнекта) и быть
        // дописанным в конец текущего списка. Наивное
        // `[...messages, ...missing]` оставило бы M200 раньше M51..M100,
        // хотя оно самое новое.
        final m50 = _message(
          id: 'm50',
          createdAt: DateTime.utc(2026, 1, 1, 12, 0, 50),
        );
        final m200 = _message(
          id: 'm200',
          createdAt: DateTime.utc(2026, 1, 1, 12, 2, 0),
        );
        final m51 = _message(
          id: 'm51',
          createdAt: DateTime.utc(2026, 1, 1, 12, 0, 51),
        );
        final m100 = _message(
          id: 'm100',
          createdAt: DateTime.utc(2026, 1, 1, 12, 1, 40),
        );

        // Текущее состояние списка на момент прихода страницы докачки:
        // live-событие M200 уже дописано в конец после M50.
        final current = [m50, m200];
        final catchUpPage = [m51, m100];

        final merged = mergeMessagesChronologically(current, catchUpPage);

        expect(
          merged.map((message) => message.id).toList(),
          ['m50', 'm51', 'm100', 'm200'],
        );
      },
    );

    test('ties broken by id keep a stable deterministic order', () {
      final sameTime = DateTime.utc(2026, 1, 1, 12, 0, 0);
      final a = _message(id: 'a', createdAt: sameTime);
      final b = _message(id: 'b', createdAt: sameTime);

      final merged = mergeMessagesChronologically([b], [a]);

      expect(merged.map((message) => message.id).toList(), ['a', 'b']);
    });

    test('merging the same data twice is idempotent', () {
      final messages = [
        _message(id: 'm1', createdAt: DateTime.utc(2026, 1, 1, 12, 0, 0)),
        _message(id: 'm2', createdAt: DateTime.utc(2026, 1, 1, 12, 0, 1)),
      ];

      final firstMerge = mergeMessagesChronologically(const [], messages);
      final secondMerge = mergeMessagesChronologically(
        firstMerge,
        firstMerge,
      );

      expect(
        secondMerge.map((message) => message.id).toList(),
        firstMerge.map((message) => message.id).toList(),
      );
      expect(secondMerge.length, 2);
    });
  });
}
