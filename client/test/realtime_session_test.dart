import 'dart:async';
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
  bool holdChannelAck = false;
  bool denyServerJoin = false;
  String? pendingChannelAckId;
  String? pendingChannelId;

  static Future<_SocketIoProbe> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
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
        } else if (name == 'server:join' && denyServerJoin) {
          final serverId = (body[1] as Map)['serverId'] as String;
          connected.add(
            '42["server:error",${jsonEncode({'serverId': serverId, 'error': 'Нет доступа к серверу'})}]',
          );
        } else if (name == 'channel:join' && ackId.isNotEmpty) {
          final channelId = (body[1] as Map)['channelId'] as String;
          if (holdChannelAck) {
            pendingChannelAckId = ackId;
            pendingChannelId = channelId;
          } else {
            connected.add(
              '43$ackId[${jsonEncode({'joined': true, 'channelId': channelId})}]',
            );
          }
        }
      });
    }
  }

  void expireSession() {
    socket!.add('42["session:expired",{"reason":"token_expired"}]');
  }

  void disconnectNamespace() {
    socket!.add('41');
  }

  void releaseIdentifyAck() {
    socket!.add('43$pendingAckId[{"userId":"user-1"}]');
    pendingAckId = null;
  }

  void releaseChannelAck() {
    socket!.add(
      '43$pendingChannelAckId[${jsonEncode({'joined': true, 'channelId': pendingChannelId})}]',
    );
    pendingChannelAckId = null;
    pendingChannelId = null;
  }

  Future<void> waitForCondition(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Timed out waiting for callback');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
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

  test('restores the selected channel after the backend restarts', () async {
    final first = await _SocketIoProbe.start();
    final port = first.server.port;
    final client = RealtimeClient(socketUrl: 'http://127.0.0.1:$port');
    _SocketIoProbe? restarted;
    addTearDown(() async {
      client.dispose();
      await restarted?.close();
    });

    final reconnectedChannels = <String?>[];
    client.connect(
      getAccessToken: () async => 'valid-token',
      onSessionExpired: () {},
      onIdentified: () async {},
      onMessageNew: (_) {},
      onMessageUpdate: (_) {},
      onMessageDelete: (_) {},
      onChannelNew: (_) {},
      onChannelUpdate: (_) {},
      onChannelDelete: (_) {},
      onServerAccessDenied: (_) {},
      onMemberLeave: (_) {},
      onMemberJoin: (_) {},
      onUserStatus: (_) {},
      onRoleNew: (_) {},
      onRoleUpdate: (_) {},
      onRoleDelete: (_) {},
      onMemberRolesUpdate: (_) {},
      onReconnected: reconnectedChannels.add,
    );
    client.joinServer('server-1');
    client.joinChannel('channel-1');
    await first.waitFor('channel:join', 1);

    await first.close();
    await Future<void>.delayed(const Duration(seconds: 4));
    restarted = await _SocketIoProbe.start(port: port);
    await restarted.waitFor('channel:join', 1);
    expect(
      restarted.events.where((event) => event.$1 == 'server:join').length,
      1,
    );
    expect(reconnectedChannels, ['channel-1', 'channel-1']);

    client.socket.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(
      restarted.events.where((event) => event.$1 == 'presence:identify').length,
      1,
    );
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
      final reconnectedChannels = <String?>[];
      final deniedServers = <String>[];
      final accessRefreshGate = Completer<void>();
      var holdAccessRefresh = false;
      var accessRefreshStarted = false;
      void connect() => client.connect(
        getAccessToken: () async => token,
        onSessionExpired: () => loggedOut = true,
        onIdentified: () async {
          if (holdAccessRefresh) {
            accessRefreshStarted = true;
            await accessRefreshGate.future;
          }
        },
        onMessageNew: (_) {},
        onMessageUpdate: (_) {},
        onMessageDelete: (_) {},
        onChannelNew: (_) {},
        onChannelUpdate: (_) {},
        onChannelDelete: (_) {},
        onServerAccessDenied: deniedServers.add,
        onMemberLeave: (_) {},
        onMemberJoin: (_) {},
        onUserStatus: (_) {},
        onRoleNew: (_) {},
        onRoleUpdate: (_) {},
        onRoleDelete: (_) {},
        onMemberRolesUpdate: (_) {},
        onReconnected: reconnectedChannels.add,
      );

      connect();
      connect(); // Repeated connect must not install duplicate listeners.
      client.joinServer('server-1');
      client.joinChannel('channel-old');
      await probe.waitFor('channel:join', 1);
      await probe.waitForCondition(
        () => reconnectedChannels.contains('channel-old'),
      );
      expect(
        probe.events.where((event) => event.$1 == 'presence:identify'),
        hasLength(1),
      );

      token = 'new-token';
      probe.holdIdentifyAck = true;
      probe.holdChannelAck = true;
      holdAccessRefresh = true;
      probe.expireSession();
      await probe.waitFor('presence:identify', 2);
      client.leaveChannel('channel-old');
      client.joinChannel('channel-new');
      expect(
        probe.events.where((event) => event.$1 == 'channel:join'),
        hasLength(1),
      );

      probe.releaseIdentifyAck();
      await probe.waitForCondition(() => accessRefreshStarted);
      expect(
        probe.events.where((event) => event.$1 == 'channel:join'),
        hasLength(1),
      );
      accessRefreshGate.complete();
      await probe.waitFor('channel:join', 2);
      expect(reconnectedChannels, isNot(contains('channel-new')));
      probe.releaseChannelAck();
      await probe.waitForCondition(
        () => reconnectedChannels.contains('channel-new'),
      );
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

      // Access was revoked while the transport was down. A failed server
      // rejoin must notify the UI so it can discard cached server metadata.
      probe.holdIdentifyAck = false;
      probe.holdChannelAck = false;
      probe.denyServerJoin = true;
      await probe.socket!.close();
      await probe.waitFor('server:join', 3);
      await probe.waitForCondition(() => deniedServers.isNotEmpty);
      expect(deniedServers, ['server-1']);

      probe.denyServerJoin = false;
      probe.disconnectNamespace();
      await probe.waitFor('presence:identify', 4);
      await probe.waitFor('server:join', 4);
    },
  );
}
