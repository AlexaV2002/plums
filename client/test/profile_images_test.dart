import 'dart:convert';
import 'dart:typed_data';
import 'package:client/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ImageAdapter implements HttpClientAdapter {
  final paths = <String>[];
  final headers = <Object?>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(options.path);
    headers.add(options.headers['Authorization']);
    return ResponseBody.fromBytes(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='), 200, headers: {Headers.contentTypeHeader: ['image/png']});
  }
}

void main() {
  test('older events and snapshots cannot replace newer revision', () {
    profileImageRevisions.clear();
    profileImageUpdates.value = {};
    applyProfileImageUpdate({'userId': 'u', 'url': '/new', 'revision': 4});
    applyProfileImageUpdate({'userId': 'u', 'url': '/old', 'revision': 3});
    syncProfileImages(const [], const [], const AppUser(id: 'u', username: 'u', status: 'ONLINE', avatarUrl: '/snapshot', profileImageRevision: 2));
    expect(profileImageUpdates.value['user:u'], '/new');
    syncProfileImages(const [], const [], const AppUser(id: 'u', username: 'u', status: 'ONLINE', avatarUrl: '/latest', profileImageRevision: 5));
    applyProfileImageUpdate({'userId': 'u', 'url': '/new', 'revision': 4});
    expect(profileImageUpdates.value['user:u'], '/latest');
  });
  testWidgets('version changes use authenticated requests and deletion falls back', (tester) async {
    final adapter = ImageAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    apiClient.accessToken = 'test-token';
    profileImageRevisions.clear();
    profileImageUpdates.value = {};
    const first = '/profile-images/11111111-1111-4111-8111-111111111111/content';
    const second = '/profile-images/22222222-2222-4222-8222-222222222222/content';
    await tester.pumpWidget(const MaterialApp(home: ProfileImage(entityKey: 'user:u', url: first, size: 42, child: Text('fallback'))));
    await tester.pumpAndSettle();
    expect(adapter.paths, [first]);
    expect(adapter.headers, ['Bearer test-token']);
    applyProfileImageUpdate({'userId': 'u', 'url': second, 'revision': 2});
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(adapter.paths, [first, second]);
    applyProfileImageUpdate({'userId': 'u', 'url': null, 'revision': 3});
    await tester.pumpAndSettle();
    expect(find.text('fallback'), findsOneWidget);
    applyProfileImageUpdate({'userId': 'u', 'url': first, 'revision': 1});
    await tester.pump();
    expect(find.text('fallback'), findsOneWidget);
    expect(adapter.paths, [first, second]);
  });
  testWidgets('legacy external URLs do not receive bearer tokens', (tester) async {
    final adapter = ImageAdapter();
    apiClient.dio.httpClientAdapter = adapter;
    profileImageRevisions.clear();
    profileImageUpdates.value = {};
    await tester.pumpWidget(const MaterialApp(home: ProfileImage(entityKey: 'user:u', url: 'https://example.com/evil.png', size: 42, child: Text('fallback'))));
    await tester.pumpAndSettle();
    expect(adapter.paths, isEmpty);
    expect(find.text('fallback'), findsOneWidget);
  });
}
