// Opt-in live acceptance check. Run against an isolated local backend with:
// flutter test tool/realtime_acceptance_test.dart --dart-define=LIVE_ACCEPTANCE=true
import 'package:client/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitUntil(bool Function() ready, String description) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void connectProbe(
  RealtimeClient client,
  ApiClient api,
  List<AppMessage> received,
  List<String?> rejoined,
  List<String> deniedServers,
) {
  client.connect(
    getAccessToken: () async {
      await api.getMe(); // Uses the production refresh-on-401 interceptor.
      return api.accessToken;
    },
    onSessionExpired: () => throw StateError('Test session expired'),
    onIdentified: () async {},
    onMessageNew: received.add,
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
    onReconnected: rejoined.add,
  );
}

void main() {
  test(
    'two Flutter clients survive JWT TTL, catch up 120 messages, and isolate a new account',
    () async {
      // This opt-in Flutter test runs from tool/ so default test runs stay fast.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final suffix = DateTime.now().microsecondsSinceEpoch;
      const password = 'Acceptance-12345';
      final ownerApi = ApiClient();
      final memberApi = ApiClient();
      final outsiderApi = ApiClient();
      final ownerClient = RealtimeClient();
      final memberClient = RealtimeClient();
      addTearDown(() {
        ownerClient.dispose();
        memberClient.dispose();
      });

      Future<LoginResult> createUser(ApiClient api, String label) async {
        final email = 'acceptance-$label-$suffix@plums.test';
        await api.register(username: label, email: email, password: password);
        return api.login(email: email, password: password);
      }

      await createUser(ownerApi, 'owner');
      await createUser(memberApi, 'member');
      final server = await ownerApi.createServer(name: 'Acceptance $suffix');
      final channel = await ownerApi.createChannel(
        serverId: server.id,
        name: 'general',
        type: ChannelType.text,
      );
      final invite = await ownerApi.createInvite(serverId: server.id);
      await memberApi.joinInvite(invite.code);

      final ownerReceived = <AppMessage>[];
      final memberReceived = <AppMessage>[];
      final ownerRejoined = <String?>[];
      final memberRejoined = <String?>[];
      final ownerDenied = <String>[];
      final memberDenied = <String>[];
      connectProbe(
        ownerClient,
        ownerApi,
        ownerReceived,
        ownerRejoined,
        ownerDenied,
      );
      connectProbe(
        memberClient,
        memberApi,
        memberReceived,
        memberRejoined,
        memberDenied,
      );
      ownerClient.joinServer(server.id);
      ownerClient.joinChannel(channel.id);
      memberClient.joinServer(server.id);
      memberClient.joinChannel(channel.id);
      await waitUntil(
        () =>
            ownerRejoined.contains(channel.id) &&
            memberRejoined.contains(channel.id),
        'initial room joins',
      );

      final seed = await ownerApi.sendMessage(
        channelId: channel.id,
        content: 'seed',
      );
      await waitUntil(
        () => memberReceived.any((message) => message.id == seed.id),
        'initial message',
      );

      memberClient.socket.disconnect();
      await waitUntil(() => !memberClient.socket.connected, 'disconnect');
      final missedIds = <String>[];
      for (var i = 0; i < 120; i++) {
        final sent = await ownerApi.sendMessage(
          channelId: channel.id,
          content: 'missed-$i',
        );
        missedIds.add(sent.id);
      }
      memberClient.socket.connect();
      await waitUntil(
        () => memberRejoined.where((id) => id == channel.id).length >= 2,
        'room rejoin after 120 missed messages',
      );

      var cursor = seed.id;
      final caughtUp = <AppMessage>[];
      for (var page = 0; page < 5; page++) {
        final batch = await memberApi.getMessages(
          channel.id,
          limit: 50,
          after: cursor,
        );
        if (batch.isEmpty) break;
        caughtUp.addAll(batch);
        cursor = batch.last.id;
        if (batch.length < 50) break;
      }
      expect(caughtUp.map((message) => message.id).toList(), missedIds);
      final merged = mergeMessagesChronologically(memberReceived, caughtUp);
      expect(merged.map((message) => message.id).toSet().length, 121);
      expect(merged.first.id, seed.id);
      expect(merged.last.id, missedIds.last);

      // Access JWT lasts 15 minutes in AuthService. Keep both transports open
      // beyond its real TTL, then verify that automatic refresh and rejoin
      // still deliver exactly one copy of each new message.
      await Future<void>.delayed(const Duration(minutes: 15, seconds: 30));
      await waitUntil(
        () =>
            ownerRejoined.where((id) => id == channel.id).length >= 2 &&
            memberRejoined.where((id) => id == channel.id).length >= 3,
        'rejoin after real JWT expiry',
      );
      final afterTtl = await ownerApi.sendMessage(
        channelId: channel.id,
        content: 'after-ttl',
      );
      await waitUntil(
        () => memberReceived.any((message) => message.id == afterTtl.id),
        'message after JWT refresh',
      );
      expect(
        memberReceived.where((message) => message.id == afterTtl.id),
        hasLength(1),
      );
      final reply = await memberApi.sendMessage(
        channelId: channel.id,
        content: 'reply-after-ttl',
      );
      await waitUntil(
        () => ownerReceived.any((message) => message.id == reply.id),
        'reply after JWT refresh',
      );
      expect(
        ownerReceived.where((message) => message.id == reply.id),
        hasLength(1),
      );

      final outsider = await createUser(outsiderApi, 'outsider');
      final switched = await memberClient.socket.timeout(5000).emitWithAckAsync(
        'presence:identify',
        {'token': outsider.accessToken},
      );
      expect((switched as Map)['userId'], outsider.user.id);
      final receivedBeforeSwitch = memberReceived.length;
      await ownerApi.sendMessage(
        channelId: channel.id,
        content: 'private-after-switch',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(memberReceived.length, receivedBeforeSwitch);
      expect(ownerDenied, isEmpty);
      expect(memberDenied, isEmpty);
    },
    skip: !const bool.fromEnvironment('LIVE_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
