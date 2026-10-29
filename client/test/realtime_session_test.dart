import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:client/main.dart';

class _SocketIoProbe {
  _SocketIoProbe._(this.server);

  final HttpServer server;
  final List<(String, Object?)> events = [];
  WebSocket? socket;
  bool holdIdentifyAck = false;
  String? pendingAckId;

  static Future<_SocketIoProbe> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final probe = _SocketIoProbe._(server);
    probe._listen();
    return probe;
  }

  void _listen() async {
    await for (final request in server) {
      final connected = await WebSocketTransformer.upgrade(request);
      socket = connected;
      connected.add(
        '0${jsonEncode({'sid': 'session-test', 'upgrades': <String>[], 'pingInterval': 25000, 'pingTimeout': 20000})}',
      );
      connected.listen((message) {
        final packet = message.toString();
        if (packet == '40') {
          connected.add('40${jsonEncode({'sid': 'socket-test'})}');
          return;
        }
        if (!packet.startsWith('42')) return;
        final bodyStart = packet.indexOf('[');
        if (bodyStart < 0) return;
        final ackId = packet.substring(2, bodyStart);
        final body = jsonDecode(packet.substring(bodyStart)) as List<dynamic>;
        final name = body.first as String;
        events.add((name, body.length > 1 ? body[1] : null));
        if (name == 'presence:identify') {
          if (holdIdentifyAck) {
            pendingAckId = ackId;
          } else {
            connected.add('43$ackId[{"userId":"user-1"}]');
          }
        }
      });
    }
  }

  void expireSession() {
    socket!.add('42["session:expired",{"reason":"token_expired"}]');
  }

  void releaseIdentifyAck() {
    socket!.add('43$pendingAckId[{"userId":"user-1"}]');
    pendingAckId = null;
  }

  Future<void> waitFor(String name, int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (events.where((event) => event.$1 == name).length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Timed out waiting for $name ($count)');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    await socket?.close();
    await server.close(force: true);
  }
}

void main() {
  test('different sessions use independent Socket.IO connections', () {
    final first = RealtimeClient(socketUrl: 'http://127.0.0.1:3107');
    final second = RealtimeClient(socketUrl: 'http://127.0.0.1:3107');
    addTearDown(() {
      first.dispose();
      second.dispose();
    });
    expect(identical(first.socket, second.socket), isFalse);
  });

  test(
    'expiry reidentifies and rejoins only the selected channel after ack',
    () async {
      final probe = await _SocketIoProbe.start();
      final client = RealtimeClient(
        socketUrl: 'http://127.0.0.1:${probe.server.port}',
      );
      addTearDown(() async {
        client.dispose();
        await probe.close();
      });

      var token = 'old-token';
      var loggedOut = false;
      void connect() => client.connect(
        getAccessToken: () async => token,
        onSessionExpired: () => loggedOut = true,
        onMessageNew: (_) {},
        onMessageUpdate: (_) {},
        onMessageDelete: (_) {},
        onChannelNew: (_) {},
        onChannelUpdate: (_) {},
        onChannelDelete: (_) {},
        onMemberLeave: (_) {},
        onMemberJoin: (_) {},
        onUserStatus: (_) {},
        onRoleNew: (_) {},
        onRoleUpdate: (_) {},
        onRoleDelete: (_) {},
        onMemberRolesUpdate: (_) {},
        onReconnected: (_) {},
      );

      connect();
      connect(); // Repeated connect must not install duplicate listeners.
      client.joinServer('server-1');
      client.joinChannel('channel-old');
      await probe.waitFor('channel:join', 1);
      expect(
        probe.events.where((event) => event.$1 == 'presence:identify'),
        hasLength(1),
      );

      token = 'new-token';
      probe.holdIdentifyAck = true;
      probe.expireSession();
      await probe.waitFor('presence:identify', 2);
      client.leaveChannel('channel-old');
      client.joinChannel('channel-new');
      expect(
        probe.events.where((event) => event.$1 == 'channel:join'),
        hasLength(1),
      );

      probe.releaseIdentifyAck();
      await probe.waitFor('channel:join', 2);
      final joins = probe.events
          .where((event) => event.$1 == 'channel:join')
          .toList();
      expect((joins.last.$2 as Map)['channelId'], 'channel-new');
      expect(
        probe.events.where((event) => event.$1 == 'server:join'),
        hasLength(2),
      );
      final identify = probe.events
          .where((event) => event.$1 == 'presence:identify')
          .toList();
      expect((identify.last.$2 as Map)['token'], 'new-token');
      expect(loggedOut, isFalse);
    },
  );
}
