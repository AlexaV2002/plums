import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:client/main.dart';

RequestOptions _options() => RequestOptions(path: '/test');

Response<T> _response<T>({required int statusCode, T? data}) {
  return Response<T>(
    requestOptions: _options(),
    statusCode: statusCode,
    data: data,
  );
}

void _expectSafe(String message) {
  expect(message, isNot(contains('null')));
  expect(message, isNot(contains('Instance of')));
  expect(message.toLowerCase(), isNot(contains('bearer')));
  expect(message.toLowerCase(), isNot(contains('token')));
}

void main() {
  group('describeRequestError', () {
    test('connection timeout produces a readable message', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.connectionTimeout,
      );

      final message = describeRequestError(error);

      _expectSafe(message);
      expect(message, isNotEmpty);
    });

    test('connection error (no response) does not say "null: null"', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.connectionError,
      );

      final message = describeRequestError(error);

      _expectSafe(message);
      expect(message, contains('подключиться'));
    });

    test('401 response is reported without raw status/data', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.badResponse,
        response: _response<Map<String, dynamic>>(statusCode: 401),
      );

      final message = describeRequestError(error);

      _expectSafe(message);
    });

    test('403 response mentions insufficient permissions', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.badResponse,
        response: _response<Map<String, dynamic>>(statusCode: 403),
      );

      final message = describeRequestError(error);

      _expectSafe(message);
      expect(message, contains('прав'));
    });

    test('429 response mentions rate limiting', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.badResponse,
        response: _response<Map<String, dynamic>>(statusCode: 429),
      );

      final message = describeRequestError(error);

      _expectSafe(message);
      expect(message, contains('позже'));
    });

    test('5xx response is reported as temporary server failure', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.badResponse,
        response: _response<Map<String, dynamic>>(statusCode: 503),
      );

      final message = describeRequestError(error);

      _expectSafe(message);
    });

    test('unexpected response.data shape falls back to a safe message', () {
      final error = DioException(
        requestOptions: _options(),
        type: DioExceptionType.badResponse,
        response: _response<List<int>>(statusCode: 400, data: const [1, 2, 3]),
      );

      final message = describeRequestError(error);

      _expectSafe(message);
    });

    test('non-DioException error falls back to a generic message', () {
      final message = describeRequestError(StateError('boom'));

      _expectSafe(message);
      expect(message, isNot(contains('boom')));
    });
  });
}
