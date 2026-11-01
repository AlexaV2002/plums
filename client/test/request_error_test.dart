import 'package:client/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registration validation errors show the field requirements', () {
    final request = RequestOptions(path: '/auth/register');
    final error = DioException(
      requestOptions: request,
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: request,
        statusCode: 400,
        data: {
          'message': [
            'password must be longer than or equal to 8 characters',
          ],
          'error': 'Bad Request',
          'statusCode': 400,
        },
      ),
    );

    expect(
      describeRequestError(error),
      'password must be longer than or equal to 8 characters',
    );
  });
}
