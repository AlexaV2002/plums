import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/main.dart';

RequestOptions _options() => RequestOptions(path: '/users/me');

// Поведение настраивается тестом через [behavior], а не фиксировано заранее —
// это позволяет одним и тем же fake-клиентом сначала воспроизвести временный
// сетевой сбой, а затем (после нажатия "Повторить") подтверждённый отказ или
// успех, без необходимости поднимать реальный HTTP-сервер.
class _ScriptedApiClient extends ApiClient {
  _ScriptedApiClient(this.behavior);

  Future<AppUser> Function() behavior;

  @override
  Future<AppUser> getMe() => behavior();
}

void main() {
  testWidgets(
    'temporary network failure during restoreSession keeps tokens and '
    'shows an offline retry screen instead of logging out',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {
        'accessToken': 'stored-access-token',
        'refreshToken': 'stored-refresh-token',
      });

      final storage = AuthStorage();
      final client = _ScriptedApiClient(
        () async => throw DioException(
          requestOptions: _options(),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(apiClient: client, authStorage: storage),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Нет соединения с сервером'), findsOneWidget);
      expect(find.text('Вход в plums'), findsNothing);

      // Временная ошибка не должна считаться подтверждённым отказом сессии —
      // валидные токены обязаны остаться на месте.
      expect(await storage.readAccessToken(), 'stored-access-token');
      expect(await storage.readRefreshToken(), 'stored-refresh-token');
    },
  );

  testWidgets(
    'retry after a confirmed rejection clears tokens and returns to login',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {
        'accessToken': 'stored-access-token',
        'refreshToken': 'stored-refresh-token',
      });

      final storage = AuthStorage();
      var attempt = 0;
      final client = _ScriptedApiClient(() async {
        attempt += 1;
        if (attempt == 1) {
          throw DioException(
            requestOptions: _options(),
            type: DioExceptionType.connectionError,
          );
        }
        // Второй вызов (по кнопке "Повторить") — backend явно ответил и
        // отверг сессию: это ПОДТВЕРЖДЁННЫЙ отказ, а не временный сбой.
        throw DioException(
          requestOptions: _options(),
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: _options(), statusCode: 401),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(apiClient: client, authStorage: storage),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Нет соединения с сервером'), findsOneWidget);

      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();

      expect(find.text('Нет соединения с сервером'), findsNothing);
      expect(find.text('Вход в plums'), findsOneWidget);
      expect(await storage.readAccessToken(), isNull);
      expect(await storage.readRefreshToken(), isNull);
    },
  );

  // Намеренно НЕ тестируем здесь виджетом полный путь "повтор успешен ->
  // AuthGate показывает MainShell": при currentUser != null AuthGate строит
  // реальный MainShell, чей initState синхронно запускает
  // realtimeClient.connect() (настоящий Socket.IO-коннект) и
  // apiClient.getMe() через глобальный singleton — в widget-тесте это
  // оставляет настоящие сетевые таймеры висящими после теста ("A Timer is
  // still pending even after the widget tree was disposed"), что требует
  // отдельного мокирования RealtimeClient/apiClient внутри MainShell
  // (сейчас не DI-параметризован) — выходит за рамки этой задачи. Переход
  // "temporary error -> isTemporaryRequestError(true) -> isOffline" и ветка
  // "подтверждённый отказ после Повторить -> очистка токенов -> экран
  // логина" уже покрыты двумя тестами выше и используют тот же код пути
  // restoreSession()/retryRestoreSession(), которым бы прошёл и успешный
  // повтор — различие там только в том, какой экран рисуется после
  // setState(currentUser = user), что не относится к багу из Проблемы 1.
}
