import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:client/main.dart';

// Минимальный фейковый транспорт, подставляемый через
// `dio.httpClientAdapter`, чтобы реально прогнать настоящий
// `InterceptorsWrapper.onError` ApiClient (а не подменять сам ApiClient
// подклассом, как в auth_gate_restore_session_test.dart — там это оправдано
// для другого бага в restoreSession(), здесь же нужно проверить код самого
// Dio-перехватчика).
class _FakeHttpClientAdapter implements HttpClientAdapter {
  _FakeHttpClientAdapter(this.handle);

  final Future<ResponseBody> Function(RequestOptions options) handle;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handle(options);
  }
}

ResponseBody _jsonBody(Map<String, dynamic> data, int statusCode) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

ResponseBody _plainStatus(int statusCode) {
  return ResponseBody.fromString('', statusCode);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  test(
    'temporary /auth/refresh failure (timeout) keeps tokens and surfaces '
    'the real refresh error instead of the original 401',
    () async {
      await authStorage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      final client = ApiClient();
      client.accessToken = 'old-access';
      client.refreshToken = 'old-refresh';

      var refreshCalls = 0;
      client.dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.path == '/auth/refresh') {
          refreshCalls += 1;
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          );
        }
        return _plainStatus(401);
      });

      await expectLater(
        client.dio.get<void>('/protected'),
        throwsA(
          isA<DioException>()
              .having(
                (e) => isTemporaryRequestError(e),
                'isTemporaryRequestError',
                isTrue,
              )
              .having(
                (e) => e.requestOptions.path,
                'requestOptions.path (must be the refresh error, not the '
                    'original 401)',
                '/auth/refresh',
              ),
        ),
      );

      // Ровно один вызов /auth/refresh и ни одного повтора исходного запроса.
      expect(refreshCalls, 1);

      // Временный сбой самого /auth/refresh не должен стирать валидную сессию.
      expect(client.accessToken, 'old-access');
      expect(client.refreshToken, 'old-refresh');
      expect(await authStorage.readAccessToken(), 'old-access');
      expect(await authStorage.readRefreshToken(), 'old-refresh');
    },
  );

  test(
    'confirmed /auth/refresh rejection (401 response) still clears tokens '
    'like before the fix',
    () async {
      await authStorage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      final client = ApiClient();
      client.accessToken = 'old-access';
      client.refreshToken = 'old-refresh';

      client.dio.httpClientAdapter = _FakeHttpClientAdapter(
        (options) async => _plainStatus(401),
      );

      await expectLater(
        client.dio.get<void>('/protected'),
        throwsA(
          isA<DioException>().having(
            (e) => e.requestOptions.path,
            'requestOptions.path (должна дойти исходная ошибка)',
            '/protected',
          ),
        ),
      );

      expect(client.accessToken, isNull);
      expect(client.refreshToken, isNull);
      expect(await authStorage.readAccessToken(), isNull);
      expect(await authStorage.readRefreshToken(), isNull);
    },
  );

  test(
    'two parallel 401s trigger exactly one /auth/refresh call '
    '(single-flight is not broken by the fix)',
    () async {
      await authStorage.saveTokens(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
      );

      final client = ApiClient();
      client.accessToken = 'old-access';
      client.refreshToken = 'old-refresh';

      var refreshCalls = 0;
      client.dio.httpClientAdapter = _FakeHttpClientAdapter((options) async {
        if (options.path == '/auth/refresh') {
          refreshCalls += 1;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _jsonBody({
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
          }, 200);
        }

        if (options.extra['retried'] == true) {
          return _jsonBody({'ok': true}, 200);
        }

        return _plainStatus(401);
      });

      final results = await Future.wait([
        client.dio.get<void>('/protected'),
        client.dio.get<void>('/protected'),
      ]);

      expect(refreshCalls, 1);
      expect(results.every((r) => r.statusCode == 200), isTrue);
      expect(client.accessToken, 'new-access');
      expect(client.refreshToken, 'new-refresh');
    },
  );
}
