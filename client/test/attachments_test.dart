import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:client/main.dart';
import 'package:file_selector/file_selector.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
);

class FakeAttachmentApi extends ApiClient {
  final discarded = <String>[];
  int uploads = 0;
  bool downloadFails = false;
  int downloads = 0;
  @override
  Future<AppAttachment> uploadAttachment(
    String channelId,
    String name,
    Uint8List bytes,
  ) async {
    uploads++;
    return AppAttachment(
      id: 'upload-$uploads',
      originalName: name,
      mimeType: 'image/png',
      sizeBytes: bytes.length,
    );
  }

  @override
  Future<void> discardAttachment(String id) async {
    discarded.add(id);
  }

  @override
  Future<Uint8List> downloadAttachment(String id) async {
    downloads++;
    if (downloadFails) throw StateError('access denied');
    return png;
  }
}

class _UploadAdapter implements HttpClientAdapter {
  int uploads = 0;
  int refreshes = 0;
  final sizes = <int>[];
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/auth/refresh') {
      refreshes++;
      return ResponseBody.fromString(
        jsonEncode({'accessToken': 'new', 'refreshToken': 'new-refresh'}),
        201,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    var size = 0;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        size += chunk.length;
      }
    }
    sizes.add(size);
    uploads++;
    if (uploads == 1) return ResponseBody.fromString('', 401);
    return ResponseBody.fromString(
      jsonEncode({
        'id': 'i',
        'originalName': 'x.png',
        'mimeType': 'image/png',
        'sizeBytes': 12,
      }),
      201,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  testWidgets('offline composer shows the reason and disables sending', (tester) async {
    final drafts = ChannelAttachmentDrafts(FakeAttachmentApi());
    addTearDown(drafts.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChannelAttachmentInput(
      channelId: 'c', channelName: 'general', canSendMessages: false,
      disabledHintText: 'Нет соединения', drafts: drafts,
      onSend: (_, _, _, _) async => AttachmentSendResult.sent,
    ))));
    expect(find.text('Нет соединения'), findsOneWidget);
    final send = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Отправить',
    );
    expect(tester.widget<IconButton>(send).onPressed, isNull);
  });

  testWidgets('composer blocks a second send while the first is pending', (tester) async {
    final drafts = ChannelAttachmentDrafts(FakeAttachmentApi());
    addTearDown(drafts.dispose);
    final pending = Completer<AttachmentSendResult>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ChannelAttachmentInput(
      channelId: 'c', channelName: 'general', canSendMessages: true,
      drafts: drafts, onSend: (_, _, _, _) { calls++; return pending.future; },
    ))));
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.byTooltip('Отправить'));
    await tester.pump();
    final send = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Отправить',
    );
    expect(tester.widget<IconButton>(send).onPressed, isNull);
    expect(calls, 1);
    pending.complete(AttachmentSendResult.sent);
    await tester.pump();
  });

  test('upload retries multipart content after a 401 refresh', () async {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient()
      ..accessToken = 'old'
      ..refreshToken = 'refresh';
    final adapter = _UploadAdapter();
    api.dio.httpClientAdapter = adapter;
    final attachment = await api.uploadAttachment('c', 'x.png', png);
    expect(attachment.id, 'i');
    expect(adapter.refreshes, 1);
    expect(adapter.uploads, 2);
    expect(adapter.sizes.every((size) => size > png.length), isTrue);
  });

  test(
    'parses public attachment metadata in history and realtime messages',
    () {
      final msg = AppMessage.fromJson({
        'id': 'm',
        'channelId': 'c',
        'authorId': 'a',
        'content': '',
        'author': {'username': 'A'},
        'createdAt': '2026-01-01T00:00:00Z',
        'updatedAt': '2026-01-01T00:00:00Z',
        'attachments': [
          {
            'id': 'i',
            'originalName': 'x.png',
            'mimeType': 'image/png',
            'sizeBytes': 12,
          },
        ],
      });
      expect(msg.attachments.single.id, 'i');
      expect(msg.attachments.single.originalName, 'x.png');
    },
  );

  testWidgets(
    'protected image offers retry and displays the authenticated response',
    (tester) async {
      final api = FakeAttachmentApi()..downloadFails = true;
      const attachment = AppAttachment(
        id: 'i',
        originalName: 'photo.png',
        mimeType: 'image/png',
        sizeBytes: 12,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProtectedAttachmentImage(attachment: attachment, api: api),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Не удалось загрузить изображение — повторить'),
        findsOneWidget,
      );
      api.downloadFails = false;
      await tester.tap(find.byType(TextButton));
      await tester.pumpAndSettle();
      expect(api.downloads, 2);
      expect(find.byType(Image), findsOneWidget);
      final provider = tester.widget<Image>(find.byType(Image)).image;
      expect(provider, isA<ResizeImage>());
      final resized = provider as ResizeImage;
      expect(resized.width, 720);
      expect(resized.height, 560);
      expect(resized.policy, ResizeImagePolicy.fit);
    },
  );

  testWidgets(
    'uncertain send retains the same message and upload IDs on retry',
    (tester) async {
      final api = FakeAttachmentApi();
      final drafts = ChannelAttachmentDrafts(api);
      addTearDown(drafts.dispose);
      final calls = <(String, String, List<String>)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChannelAttachmentInput(
              channelId: 'c',
              channelName: 'general',
              canSendMessages: true,
              drafts: drafts,
              pickFiles: () async => [XFile.fromData(png, name: 'x.png')],
              onSend: (channel, content, id, ids) async {
                calls.add((content, id, List.of(ids)));
                return calls.length == 1
                    ? AttachmentSendResult.uncertain
                    : AttachmentSendResult.sent;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Прикрепить изображение'));
      await tester.pumpAndSettle();
      expect(api.uploads, 1);
      expect(find.byTooltip('Убрать изображение'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byTooltip('Отправить'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ответ сервера не получен'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(api.discarded, isEmpty);
      await tester.tap(find.byTooltip('Повторить отправку'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls[1].$1, calls[0].$1);
      expect(calls[1].$2, calls[0].$2);
      expect(calls[1].$3, calls[0].$3);
      expect(calls[0].$3, ['upload-1']);
      expect(find.byTooltip('Убрать изображение'), findsNothing);
    },
  );

  testWidgets('removing an uploaded preview cancels it through the API', (
    tester,
  ) async {
    final api = FakeAttachmentApi();
    final drafts = ChannelAttachmentDrafts(api);
    addTearDown(drafts.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChannelAttachmentInput(
            channelId: 'c',
            channelName: 'general',
            canSendMessages: true,
            drafts: drafts,
            pickFiles: () async => [XFile.fromData(png, name: 'x.png')],
            onSend: (_, _, _, _) async => AttachmentSendResult.sent,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Прикрепить изображение'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Убрать изображение'));
    await tester.pumpAndSettle();
    expect(api.discarded, ['upload-1']);
    expect(find.byTooltip('Убрать изображение'), findsNothing);
  });

  testWidgets(
    'channel switches preserve drafts without exposing them in another channel',
    (tester) async {
      final api = FakeAttachmentApi();
      final drafts = ChannelAttachmentDrafts(api);
      addTearDown(drafts.dispose);
      Widget view(String channel) => MaterialApp(
        home: Scaffold(
          body: ChannelAttachmentInput(
            channelId: channel,
            channelName: channel,
            canSendMessages: true,
            drafts: drafts,
            pickFiles: () async => [XFile.fromData(png, name: 'x.png')],
            onSend: (_, _, _, _) async => AttachmentSendResult.sent,
          ),
        ),
      );
      await tester.pumpWidget(view('first'));
      await tester.tap(find.byTooltip('Прикрепить изображение'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Убрать изображение'), findsOneWidget);
      await tester.pumpWidget(view('second'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Убрать изображение'), findsNothing);
      await tester.pumpWidget(view('first'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Убрать изображение'), findsOneWidget);
      expect(api.uploads, 1);
    },
  );

  testWidgets('more than four selected files are rejected before upload', (
    tester,
  ) async {
    final api = FakeAttachmentApi();
    final drafts = ChannelAttachmentDrafts(api);
    addTearDown(drafts.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChannelAttachmentInput(
            channelId: 'c',
            channelName: 'general',
            canSendMessages: true,
            drafts: drafts,
            pickFiles: () async =>
                List.generate(5, (i) => XFile.fromData(png, name: '$i.png')),
            onSend: (_, _, _, _) async => AttachmentSendResult.sent,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Прикрепить изображение'));
    await tester.pump();
    expect(api.uploads, 0);
    expect(
      find.text('Можно прикрепить не более четырёх изображений'),
      findsOneWidget,
    );
  });
}
