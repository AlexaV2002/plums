import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

void main() {
  runApp(const PlumsApp());
}

class PlumsApp extends StatelessWidget {
  const PlumsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'plums',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xFF15131A),
      ),
      home: const AuthGate(),
    );
  }
}

/* =========================
   API
========================= */

class ApiClient {
  ApiClient()
    : dio = Dio(
        BaseOptions(
          baseUrl: 'http://localhost:3000',
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          headers: {'Content-Type': 'application/json'},
        ),
      );

  final Dio dio;
  String? accessToken;

  Options get authOptions {
    return Options(headers: {'Authorization': 'Bearer $accessToken'});
  }

  Future<void> register({
    required String username,
    required String email,
    required String password,
  }) async {
    await dio.post(
      '/auth/register',
      data: {'username': username, 'email': email, 'password': password},
    );
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final response = await dio.post(
      '/auth/login',
      data: {'email': email, 'password': password},
    );

    final token = response.data['accessToken'] as String;
    accessToken = token;

    final userJson = response.data['user'] as Map<String, dynamic>;

    return LoginResult(accessToken: token, user: AppUser.fromJson(userJson));
  }

  Future<AppUser> getMe() async {
    final response = await dio.get('/users/me', options: authOptions);

    return AppUser.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppUser> updateMe({
    String? username,
    String? bio,
    String? status,
  }) async {
    final response = await dio.patch(
      '/users/me',
      options: authOptions,
      data: {
        if (username != null) 'username': username,
        if (bio != null) 'bio': bio,
        if (status != null) 'status': status,
      },
    );

    return AppUser.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<AppServer>> getServers() async {
    final response = await dio.get('/servers', options: authOptions);

    final list = response.data as List;

    return list
        .map((item) => AppServer.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<AppServerMember>> getServerMembers(String serverId) async {
    final response = await dio.get(
      '/servers/$serverId/members',
      options: authOptions,
    );

    final list = response.data as List;

    return list
        .map((item) => AppServerMember.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppServer> createServer({required String name}) async {
    final response = await dio.post(
      '/servers',
      options: authOptions,
      data: {'name': name},
    );

    return AppServer.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppServer> updateServer({
    required String serverId,
    required String name,
  }) async {
    final response = await dio.patch(
      '/servers/$serverId',
      options: authOptions,
      data: {'name': name},
    );

    return AppServer.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> deleteServer({required String serverId}) async {
    await dio.delete('/servers/$serverId', options: authOptions);
  }

  Future<void> leaveServer({required String serverId}) async {
    await dio.delete('/servers/$serverId/members/me', options: authOptions);
  }

  Future<void> kickServerMember({
    required String serverId,
    required String memberId,
  }) async {
    await dio.delete(
      '/servers/$serverId/members/$memberId',
      options: authOptions,
    );
  }

  Future<AppInvite> createInvite({required String serverId}) async {
    final response = await dio.post(
      '/servers/$serverId/invites',
      options: authOptions,
      data: {},
    );

    return AppInvite.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppInvite> getInvite(String code) async {
    final response = await dio.get('/invites/$code', options: authOptions);

    return AppInvite.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppServer> joinInvite(String code) async {
    final response = await dio.post(
      '/invites/$code/join',
      options: authOptions,
    );

    return AppServer.fromJson(response.data as Map<String, dynamic>);
  }

  Future<List<AppChannel>> getChannels(String serverId) async {
    final response = await dio.get(
      '/servers/$serverId/channels',
      options: authOptions,
    );

    final list = response.data as List;

    return list
        .map((item) => AppChannel.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppChannel> createChannel({
    required String serverId,
    required String name,
    required ChannelType type,
  }) async {
    final response = await dio.post(
      '/servers/$serverId/channels',
      options: authOptions,
      data: {'name': name, 'type': type.toBackend()},
    );

    return AppChannel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppChannel> updateChannel({
    required String channelId,
    required String name,
  }) async {
    final response = await dio.patch(
      '/channels/$channelId',
      options: authOptions,
      data: {'name': name},
    );

    return AppChannel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppChannel> updateChannelPermissions({
    required String channelId,
    required ChannelPermissions permissions,
  }) async {
    final response = await dio.patch(
      '/channels/$channelId/permissions',
      options: authOptions,
      data: permissions.toJson(),
    );

    return AppChannel.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> deleteChannel({required String channelId}) async {
    await dio.delete('/channels/$channelId', options: authOptions);
  }

  Future<List<AppMessage>> getMessages(String channelId) async {
    final response = await dio.get(
      '/channels/$channelId/messages',
      options: authOptions,
    );

    final list = response.data as List;

    return list
        .map((item) => AppMessage.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppMessage> sendMessage({
    required String channelId,
    required String content,
  }) async {
    final response = await dio.post(
      '/channels/$channelId/messages',
      options: authOptions,
      data: {'content': content},
    );

    return AppMessage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppMessage> updateMessage({
    required String messageId,
    required String content,
  }) async {
    final response = await dio.patch(
      '/messages/$messageId',
      options: authOptions,
      data: {'content': content},
    );

    return AppMessage.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> deleteMessage({required String messageId}) async {
    await dio.delete('/messages/$messageId', options: authOptions);
  }
}

final apiClient = ApiClient();

final authStorage = AuthStorage();

class AuthStorage {
  static const String _accessTokenKey = 'accessToken';

  Future<void> saveAccessToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, token);
  }

  Future<String?> readAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessTokenKey);
  }

  Future<void> clearAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
  }
}

class RealtimeClient {
  RealtimeClient() {
    socket = io.io(
      'http://localhost:3000',
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );
  }

  late final io.Socket socket;

  void connect({
    required ValueChanged<AppMessage> onMessageNew,
    required ValueChanged<AppMessage> onMessageUpdate,
    required ValueChanged<RealtimeMessageDelete> onMessageDelete,
    required ValueChanged<AppChannel> onChannelNew,
    required ValueChanged<AppChannel> onChannelUpdate,
    required ValueChanged<RealtimeChannelDelete> onChannelDelete,
    required ValueChanged<RealtimeMemberLeave> onMemberLeave,
  }) {
    socket.on('message:new', (data) {
      if (data is Map) {
        onMessageNew(AppMessage.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('message:update', (data) {
      if (data is Map) {
        onMessageUpdate(AppMessage.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('message:delete', (data) {
      if (data is Map) {
        onMessageDelete(
          RealtimeMessageDelete.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.on('member:leave', (data) {
      if (data is Map) {
        onMemberLeave(
          RealtimeMemberLeave.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.on('channel:new', (data) {
      if (data is Map) {
        onChannelNew(AppChannel.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('channel:update', (data) {
      if (data is Map) {
        onChannelUpdate(AppChannel.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('channel:delete', (data) {
      if (data is Map) {
        onChannelDelete(
          RealtimeChannelDelete.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.connect();
  }

  void joinServer(String serverId) {
    if (!socket.connected) {
      socket.connect();
    }

    socket.emit('server:join', {'serverId': serverId});
  }

  void leaveServer(String serverId) {
    socket.emit('server:leave', {'serverId': serverId});
  }

  void joinChannel(String channelId) {
    if (!socket.connected) {
      socket.connect();
    }

    socket.emit('channel:join', {'channelId': channelId});
  }

  void leaveChannel(String channelId) {
    socket.emit('channel:leave', {'channelId': channelId});
  }

  void dispose() {
    socket.dispose();
  }
}

class RealtimeMessageDelete {
  const RealtimeMessageDelete({required this.id, required this.channelId});

  final String id;
  final String channelId;

  factory RealtimeMessageDelete.fromJson(Map<String, dynamic> json) {
    return RealtimeMessageDelete(
      id: json['id'] as String,
      channelId: json['channelId'] as String,
    );
  }
}

class RealtimeMemberLeave {
  const RealtimeMemberLeave({
    required this.serverId,
    required this.userId,
    required this.memberId,
    required this.reason,
  });

  final String serverId;
  final String userId;
  final String memberId;
  final String reason;

  factory RealtimeMemberLeave.fromJson(Map<String, dynamic> json) {
    return RealtimeMemberLeave(
      serverId: json['serverId'] as String,
      userId: json['userId'] as String,
      memberId: json['memberId'] as String,
      reason: json['reason'] as String,
    );
  }
}

class RealtimeChannelDelete {
  const RealtimeChannelDelete({required this.id, required this.serverId});

  final String id;
  final String serverId;

  factory RealtimeChannelDelete.fromJson(Map<String, dynamic> json) {
    return RealtimeChannelDelete(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
    );
  }
}

/* =========================
   AUTH
========================= */

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  AppUser? currentUser;
  bool isCheckingAuth = true;

  @override
  void initState() {
    super.initState();
    restoreSession();
  }

  Future<void> restoreSession() async {
    final token = await authStorage.readAccessToken();

    if (token == null || token.isEmpty) {
      if (!mounted) return;

      setState(() {
        isCheckingAuth = false;
      });

      return;
    }

    try {
      apiClient.accessToken = token;
      final user = await apiClient.getMe();

      if (!mounted) return;

      setState(() {
        currentUser = user;
        isCheckingAuth = false;
      });
    } catch (_) {
      await authStorage.clearAccessToken();
      apiClient.accessToken = null;

      if (!mounted) return;

      setState(() {
        currentUser = null;
        isCheckingAuth = false;
      });
    }
  }

  Future<void> handleLogin(AppUser user) async {
    final token = apiClient.accessToken;

    if (token != null && token.isNotEmpty) {
      await authStorage.saveAccessToken(token);
    }

    if (!mounted) return;

    setState(() {
      currentUser = user;
    });
  }

  Future<void> handleLogout() async {
    await authStorage.clearAccessToken();
    apiClient.accessToken = null;

    if (!mounted) return;

    setState(() {
      currentUser = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (isCheckingAuth) {
      return const Scaffold(
        backgroundColor: Color(0xFF15131A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF8D5CFF)),
        ),
      );
    }

    if (currentUser == null) {
      return LoginScreen(onLoggedIn: handleLogin);
    }

    return MainShell(initialUser: currentUser!, onLoggedOut: handleLogout);
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn});

  final ValueChanged<AppUser> onLoggedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final usernameController = TextEditingController(text: 'new_user');
  final emailController = TextEditingController(text: 'test@mail.com');
  final passwordController = TextEditingController(text: '12345678');

  bool isRegisterMode = false;
  bool isLoading = false;
  String? errorMessage;

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (isRegisterMode) {
      await submitRegister();
    } else {
      await submitLogin();
    }
  }

  Future<void> submitLogin() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final result = await apiClient.login(
        email: emailController.text.trim(),
        password: passwordController.text,
      );

      widget.onLoggedIn(result.user);
    } on DioException catch (error) {
      final data = error.response?.data;
      final statusCode = error.response?.statusCode;

      setState(() {
        errorMessage = 'Ошибка $statusCode: $data';
      });
    } catch (error) {
      setState(() {
        errorMessage = 'Неизвестная ошибка входа: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> submitRegister() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      await apiClient.register(
        username: usernameController.text.trim(),
        email: emailController.text.trim(),
        password: passwordController.text,
      );

      final result = await apiClient.login(
        email: emailController.text.trim(),
        password: passwordController.text,
      );

      widget.onLoggedIn(result.user);
    } on DioException catch (error) {
      final data = error.response?.data;
      final statusCode = error.response?.statusCode;

      setState(() {
        errorMessage = 'Ошибка $statusCode: $data';
      });
    } catch (error) {
      setState(() {
        errorMessage = 'Неизвестная ошибка регистрации: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void toggleMode() {
    setState(() {
      isRegisterMode = !isRegisterMode;
      errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF15131A),
      body: Center(
        child: Container(
          width: 420,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF211C29),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: const Color(0xFF342D3F)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.35),
                blurRadius: 30,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF8D5CFF), Color(0xFFFF7AC8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Center(
                  child: Text(
                    'P',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                isRegisterMode ? 'Регистрация в plums' : 'Вход в plums',
                style: const TextStyle(
                  color: Color(0xFFF3EEFF),
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isRegisterMode
                    ? 'Создай аккаунт, чтобы начать пользоваться plums'
                    : 'Войди в аккаунт, чтобы открыть свои серверы и каналы',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFB8ADC8), fontSize: 14),
              ),
              const SizedBox(height: 26),
              if (isRegisterMode) ...[
                PlumsTextField(
                  controller: usernameController,
                  label: 'Username',
                  hintText: 'new_user',
                ),
                const SizedBox(height: 14),
              ],
              PlumsTextField(
                controller: emailController,
                label: 'Email',
                hintText: 'test@mail.com',
              ),
              const SizedBox(height: 14),
              PlumsTextField(
                controller: passwordController,
                label: 'Пароль',
                hintText: '12345678',
                obscureText: true,
              ),
              if (errorMessage != null) ...[
                const SizedBox(height: 14),
                Text(
                  errorMessage!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFFF7A7A),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: isLoading ? null : submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8D5CFF),
                    disabledBackgroundColor: const Color(0xFF4E4261),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          isRegisterMode ? 'Зарегистрироваться' : 'Войти',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: isLoading ? null : toggleMode,
                child: Text(
                  isRegisterMode
                      ? 'Уже есть аккаунт? Войти'
                      : 'Нет аккаунта? Зарегистрироваться',
                  style: const TextStyle(
                    color: Color(0xFFBFA7FF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlumsTextField extends StatelessWidget {
  const PlumsTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.hintText,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String hintText;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF8F849F),
            fontSize: 11,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: const TextStyle(color: Color(0xFFF3EEFF), fontSize: 14),
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: const TextStyle(color: Color(0xFF6F647E)),
            filled: true,
            fillColor: const Color(0xFF302A39),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 15,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFF40374D)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: Color(0xFF40374D)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                color: Color(0xFF8D5CFF),
                width: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/* =========================
   MAIN SHELL
========================= */

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.initialUser,
    required this.onLoggedOut,
  });

  final AppUser initialUser;
  final Future<void> Function() onLoggedOut;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final realtimeClient = RealtimeClient();

  AppUser? currentUser;
  List<AppServer> servers = [];
  List<AppChannel> channels = [];
  List<AppMessage> messages = [];
  List<AppServerMember> members = [];

  String? selectedServerId;
  String? selectedChannelId;
  String? realtimeServerId;
  String? realtimeChannelId;

  bool isLoading = true;
  bool isMessagesLoading = false;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    currentUser = widget.initialUser;
    realtimeClient.connect(
      onMessageNew: handleRealtimeMessage,
      onMessageUpdate: handleRealtimeMessageUpdate,
      onMessageDelete: handleRealtimeMessageDelete,
      onChannelNew: handleRealtimeChannelNew,
      onChannelUpdate: handleRealtimeChannelUpdate,
      onChannelDelete: handleRealtimeChannelDelete,
      onMemberLeave: handleRealtimeMemberLeave,
    );
    loadInitialData();
  }

  @override
  void dispose() {
    realtimeClient.dispose();
    super.dispose();
  }

  Future<void> logout() async {
    realtimeClient.dispose();
    await widget.onLoggedOut();
  }

  void handleRealtimeMessage(AppMessage message) {
    if (!mounted || message.channelId != selectedChannelId) {
      return;
    }

    if (messages.any((item) => item.id == message.id)) {
      return;
    }

    setState(() {
      messages = [...messages, message];
    });
  }

  void handleRealtimeMessageUpdate(AppMessage message) {
    if (!mounted || message.channelId != selectedChannelId) {
      return;
    }

    setState(() {
      messages = messages
          .map((item) => item.id == message.id ? message : item)
          .toList();
    });
  }

  void handleRealtimeMessageDelete(RealtimeMessageDelete message) {
    if (!mounted || message.channelId != selectedChannelId) {
      return;
    }

    setState(() {
      messages = messages.where((item) => item.id != message.id).toList();
    });
  }

  void handleRealtimeChannelNew(AppChannel channel) {
    if (!mounted ||
        channel.serverId == null ||
        channel.serverId != selectedServerId) {
      return;
    }

    if (!canViewRealtimeChannel(channel)) {
      return;
    }

    if (channels.any((item) => item.id == channel.id)) {
      return;
    }

    setState(() {
      channels = sortChannels([...channels, channel]);
    });
  }

  void handleRealtimeChannelUpdate(AppChannel channel) {
    if (!mounted ||
        channel.serverId == null ||
        channel.serverId != selectedServerId) {
      return;
    }

    if (!canViewRealtimeChannel(channel)) {
      handleRealtimeChannelDelete(
        RealtimeChannelDelete(id: channel.id, serverId: channel.serverId!),
      );
      return;
    }

    setState(() {
      channels = sortChannels(
        channels
            .map<AppChannel>((item) => item.id == channel.id ? channel : item)
            .toList(),
      );
    });
  }

  void handleRealtimeMemberLeave(RealtimeMemberLeave event) {
    if (!mounted || event.serverId != selectedServerId) {
      return;
    }

    setState(() {
      members = members.where((item) => item.id != event.memberId).toList();
    });

    if (event.userId == currentUser?.id) {
      selectNextServerAfterRemoving(event.serverId);
      showErrorSnackBar(
        context,
        event.reason == 'kick' ? 'Вас удалили с сервера' : 'Вы вышли с сервера',
      );
    }
  }

  void handleRealtimeChannelDelete(RealtimeChannelDelete channel) {
    if (!mounted || channel.serverId != selectedServerId) {
      return;
    }

    final remainingChannels = channels
        .where((item) => item.id != channel.id)
        .toList();
    final deletedSelectedChannel = selectedChannelId == channel.id;
    final nextChannel = deletedSelectedChannel && remainingChannels.isNotEmpty
        ? remainingChannels.first
        : null;

    setState(() {
      channels = remainingChannels;

      if (deletedSelectedChannel) {
        selectedChannelId = nextChannel?.id;
        messages = [];
      }
    });

    if (!deletedSelectedChannel) {
      return;
    }

    if (nextChannel != null) {
      selectChannel(nextChannel.id);
    } else {
      syncRealtimeChannel(null);
    }
  }

  bool get isSelectedServerOwner {
    final serverId = selectedServerId;
    final userId = currentUser?.id;

    if (serverId == null || userId == null) {
      return false;
    }

    final server = servers.cast<AppServer?>().firstWhere(
      (item) => item?.id == serverId,
      orElse: () => null,
    );

    return server?.ownerId == userId;
  }

  bool canViewRealtimeChannel(AppChannel channel) {
    return isSelectedServerOwner || channel.resolvedPermissions.canView;
  }

  List<AppChannel> sortChannels(List<AppChannel> items) {
    return [...items]..sort((left, right) {
      final positionCompare = left.position.compareTo(right.position);

      if (positionCompare != 0) {
        return positionCompare;
      }

      return left.name.compareTo(right.name);
    });
  }

  void syncRealtimeServer(String? nextServerId) {
    if (realtimeServerId == nextServerId) {
      return;
    }

    if (realtimeServerId != null) {
      realtimeClient.leaveServer(realtimeServerId!);
    }

    realtimeServerId = nextServerId;

    if (nextServerId != null) {
      realtimeClient.joinServer(nextServerId);
    }
  }

  void syncRealtimeChannel(AppChannel? channel) {
    final nextChannelId = channel != null && channel.type == ChannelType.text
        ? channel.id
        : null;

    if (realtimeChannelId == nextChannelId) {
      return;
    }

    if (realtimeChannelId != null) {
      realtimeClient.leaveChannel(realtimeChannelId!);
    }

    realtimeChannelId = nextChannelId;

    if (nextChannelId != null) {
      realtimeClient.joinChannel(nextChannelId);
    }
  }

  Future<void> loadInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final me = await apiClient.getMe();
      final loadedServers = await apiClient.getServers();

      final firstServerId = loadedServers.isNotEmpty
          ? loadedServers.first.id
          : null;

      final loadedChannels = firstServerId != null
          ? await apiClient.getChannels(firstServerId)
          : <AppChannel>[];
      final loadedMembers = firstServerId != null
          ? await apiClient.getServerMembers(firstServerId)
          : <AppServerMember>[];

      final firstChannel = loadedChannels.isNotEmpty
          ? loadedChannels.first
          : null;

      final loadedMessages =
          firstChannel != null && firstChannel.type == ChannelType.text
          ? await apiClient.getMessages(firstChannel.id)
          : <AppMessage>[];

      setState(() {
        currentUser = me;
        servers = loadedServers;
        selectedServerId = firstServerId;
        channels = loadedChannels;
        members = loadedMembers;
        selectedChannelId = firstChannel?.id;
        messages = loadedMessages;
        isLoading = false;
      });
      syncRealtimeServer(firstServerId);
      syncRealtimeChannel(firstChannel);
    } on DioException catch (error) {
      setState(() {
        errorMessage = 'Ошибка загрузки данных: ${error.response?.data}';
        isLoading = false;
      });
    } catch (error) {
      setState(() {
        errorMessage = 'Не удалось загрузить данные приложения: $error';
        isLoading = false;
      });
    }
  }

  Future<void> selectServer(String serverId) async {
    setState(() {
      selectedServerId = serverId;
      channels = [];
      members = [];
      selectedChannelId = null;
      messages = [];
      isLoading = true;
      errorMessage = null;
    });

    try {
      final loadedChannels = await apiClient.getChannels(serverId);
      final loadedMembers = await apiClient.getServerMembers(serverId);
      final firstChannel = loadedChannels.isNotEmpty
          ? loadedChannels.first
          : null;

      final loadedMessages =
          firstChannel != null && firstChannel.type == ChannelType.text
          ? await apiClient.getMessages(firstChannel.id)
          : <AppMessage>[];

      setState(() {
        channels = loadedChannels;
        members = loadedMembers;
        selectedChannelId = firstChannel?.id;
        messages = loadedMessages;
        isLoading = false;
      });
      syncRealtimeServer(serverId);
      syncRealtimeChannel(firstChannel);
    } on DioException catch (error) {
      final statusCode = error.response?.statusCode;

      if (statusCode == 403 || statusCode == 404) {
        await selectNextServerAfterRemoving(serverId);

        if (!mounted) return;

        showErrorSnackBar(context, 'Вы больше не состоите на этом сервере');

        return;
      }

      if (!mounted) return;

      setState(() {
        errorMessage = 'Ошибка загрузки каналов: ${error.response?.data}';
        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Не удалось загрузить каналы: $error';
        isLoading = false;
      });
    }
  }

  Future<void> selectChannel(String channelId) async {
    final channel = channels.firstWhere(
      (item) => item.id == channelId,
      orElse: () => channels.first,
    );

    setState(() {
      selectedChannelId = channelId;
      messages = [];
      isMessagesLoading = channel.type == ChannelType.text;
      errorMessage = null;
    });

    if (channel.type == ChannelType.voice) {
      setState(() {
        isMessagesLoading = false;
      });
      syncRealtimeChannel(null);
      return;
    }

    try {
      final loadedMessages = await apiClient.getMessages(channel.id);

      setState(() {
        messages = loadedMessages;
        isMessagesLoading = false;
      });
      syncRealtimeChannel(channel);
    } on DioException catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Ошибка загрузки сообщений: ${error.response?.data}';
        isMessagesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Не удалось загрузить сообщения: $error';
        isMessagesLoading = false;
      });
    }
  }

  Future<void> showMembers() async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    try {
      final loadedMembers = await apiClient.getServerMembers(serverId);

      setState(() {
        members = loadedMembers;
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка загрузки участников: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось загрузить участников: $error');
    }
  }

  Future<void> kickMember(AppServerMember member) async {
    final serverId = selectedServerId;
    final memberId = member.id;

    if (serverId == null) {
      return;
    }

    if (memberId.isEmpty) {
      showErrorSnackBar(
        context,
        'Не удалось удалить участника: пустой memberId',
      );
      return;
    }

    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить участника?',
      message: 'Пользователь "${member.user.username}" будет удалён с сервера.',
      confirmText: 'Удалить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.kickServerMember(serverId: serverId, memberId: memberId);

      if (!mounted) return;

      setState(() {
        members = members.where((item) => item.id != memberId).toList();
      });

      showErrorSnackBar(context, 'Участник удалён с сервера');
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления участника: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить участника: $error');
    }
  }

  Future<void> sendMessage(String content) async {
    final channelId = selectedChannelId;

    if (channelId == null) {
      return;
    }

    final sentMessage = await apiClient.sendMessage(
      channelId: channelId,
      content: content,
    );

    setState(() {
      if (messages.any((item) => item.id == sentMessage.id)) {
        return;
      }

      messages = [...messages, sentMessage];
    });
  }

  Future<void> editMessage(AppMessage message) async {
    final newContent = await showTextDialog(
      context: context,
      title: 'Редактировать сообщение',
      label: 'Текст сообщения',
      hintText: message.content,
      initialValue: message.content,
      confirmText: 'Сохранить',
    );

    if (newContent == null || newContent.trim().isEmpty) {
      return;
    }

    try {
      final updatedMessage = await apiClient.updateMessage(
        messageId: message.id,
        content: newContent.trim(),
      );

      setState(() {
        messages = messages
            .map((item) => item.id == updatedMessage.id ? updatedMessage : item)
            .toList();
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка редактирования сообщения: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Не удалось отредактировать сообщение: $error',
      );
    }
  }

  Future<void> deleteMessage(AppMessage message) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить сообщение?',
      message: 'Сообщение будет удалено из истории канала.',
      confirmText: 'Удалить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.deleteMessage(messageId: message.id);

      setState(() {
        messages = messages.where((item) => item.id != message.id).toList();
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления сообщения: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить сообщение: $error');
    }
  }

  Future<void> createServer() async {
    final name = await showTextDialog(
      context: context,
      title: 'Создать сервер',
      label: 'Название сервера',
      hintText: 'Мой новый сервер',
      confirmText: 'Создать',
    );

    if (name == null) {
      return;
    }

    final trimmedName = name.trim();

    if (trimmedName.length < 2) {
      showErrorSnackBar(
        context,
        'Название сервера должно быть не короче 2 символов',
      );
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final server = await apiClient.createServer(name: trimmedName);
      final loadedChannels = await apiClient.getChannels(server.id);
      final loadedMembers = await apiClient.getServerMembers(server.id);

      setState(() {
        servers = [...servers, server];
        selectedServerId = server.id;
        channels = loadedChannels;
        members = loadedMembers;
        selectedChannelId = loadedChannels.isNotEmpty
            ? loadedChannels.first.id
            : null;
        messages = [];
        isLoading = false;
      });
      syncRealtimeServer(server.id);
      syncRealtimeChannel(
        loadedChannels.isNotEmpty ? loadedChannels.first : null,
      );
    } on DioException catch (error) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(
        context,
        'Ошибка создания сервера: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(context, 'Не удалось создать сервер: $error');
    }
  }

  Future<void> selectNextServerAfterRemoving(String serverId) async {
    final remainingServers = servers
        .where((server) => server.id != serverId)
        .toList();
    final nextServer = remainingServers.isNotEmpty
        ? remainingServers.first
        : null;

    if (nextServer == null) {
      setState(() {
        servers = [];
        selectedServerId = null;
        channels = [];
        selectedChannelId = null;
        messages = [];
        members = [];
        isMessagesLoading = false;
        isLoading = false;
        errorMessage = null;
      });
      syncRealtimeServer(null);
      syncRealtimeChannel(null);
      return;
    }

    setState(() {
      servers = remainingServers;
    });

    await selectServer(nextServer.id);
  }

  Future<void> renameServer(AppServer server) async {
    final newName = await showTextDialog(
      context: context,
      title: 'Переименовать сервер',
      label: 'Новое название',
      hintText: server.name,
      initialValue: server.name,
      confirmText: 'Сохранить',
    );

    if (newName == null || newName.trim().isEmpty) {
      return;
    }

    try {
      final updatedServer = await apiClient.updateServer(
        serverId: server.id,
        name: newName.trim(),
      );

      setState(() {
        servers = servers
            .map<AppServer>(
              (item) => item.id == updatedServer.id ? updatedServer : item,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка переименования сервера: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось переименовать сервер: $error');
    }
  }

  Future<void> deleteServer(AppServer server) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить сервер?',
      message:
          'Сервер "${server.name}" будет удалён вместе с каналами и сообщениями.',
      confirmText: 'Удалить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.deleteServer(serverId: server.id);
      await selectNextServerAfterRemoving(server.id);
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления сервера: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить сервер: $error');
    }
  }

  Future<void> leaveServer(AppServer server) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Выйти с сервера?',
      message: 'Сервер "${server.name}" исчезнет из вашего списка серверов.',
      confirmText: 'Выйти',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.leaveServer(serverId: server.id);
      await selectNextServerAfterRemoving(server.id);
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка выхода с сервера: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось выйти с сервера: $error');
    }
  }

  String parseInviteCode(String input) {
    final trimmed = input.trim();

    if (trimmed.isEmpty) {
      return '';
    }

    final uri = Uri.tryParse(trimmed);

    if (uri != null && uri.pathSegments.isNotEmpty) {
      final segments = uri.pathSegments;
      final invitesIndex = segments.indexOf('invites');

      if (invitesIndex >= 0 && invitesIndex + 1 < segments.length) {
        return segments[invitesIndex + 1];
      }

      return segments.last == 'join' && segments.length >= 2
          ? segments[segments.length - 2]
          : segments.last;
    }

    return trimmed;
  }

  Future<void> joinServerByInvite() async {
    final input = await showTextDialog(
      context: context,
      title: 'Вступить на сервер',
      label: 'Код или ссылка приглашения',
      hintText: 'GWNqgkBdN54',
      confirmText: 'Вступить',
    );

    if (input == null || input.trim().isEmpty) {
      return;
    }

    final code = parseInviteCode(input);

    if (code.isEmpty) {
      return;
    }

    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final server = await apiClient.joinInvite(code);
      final loadedServers = await apiClient.getServers();
      final loadedChannels = await apiClient.getChannels(server.id);
      final loadedMembers = await apiClient.getServerMembers(server.id);
      final firstChannel = loadedChannels.isNotEmpty
          ? loadedChannels.first
          : null;
      final loadedMessages =
          firstChannel != null && firstChannel.type == ChannelType.text
          ? await apiClient.getMessages(firstChannel.id)
          : <AppMessage>[];

      setState(() {
        servers = loadedServers;
        selectedServerId = server.id;
        channels = loadedChannels;
        members = loadedMembers;
        selectedChannelId = firstChannel?.id;
        messages = loadedMessages;
        isLoading = false;
      });
      syncRealtimeServer(server.id);
      syncRealtimeChannel(firstChannel);
    } on DioException catch (error) {
      setState(() {
        errorMessage = 'Ошибка вступления на сервер: ${error.response?.data}';
        isLoading = false;
      });
    } catch (error) {
      setState(() {
        errorMessage = 'Не удалось вступить на сервер: $error';
        isLoading = false;
      });
    }
  }

  Future<void> createInvite() async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    try {
      final invite = await apiClient.createInvite(serverId: serverId);

      if (!mounted) return;

      await showInviteDialog(context: context, invite: invite);
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка создания приглашения: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось создать приглашение: $error');
    }
  }

  Future<void> createChannel() async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    final result = await showCreateChannelDialog(context: context);

    if (result == null) {
      return;
    }

    try {
      final channel = await apiClient.createChannel(
        serverId: serverId,
        name: result.name,
        type: result.type,
      );

      setState(() {
        channels = sortChannels(
          channels.any((item) => item.id == channel.id)
              ? channels
                    .map<AppChannel>(
                      (item) => item.id == channel.id ? channel : item,
                    )
                    .toList()
              : [...channels, channel],
        );
        selectedChannelId = channel.id;
        messages = [];
      });

      if (channel.type == ChannelType.text) {
        await selectChannel(channel.id);
      }
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка создания канала: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось создать канал: $error');
    }
  }

  Future<void> editProfile() async {
    final user = currentUser;

    if (user == null) {
      return;
    }

    final result = await showEditProfileDialog(context: context, user: user);

    if (result == null) {
      return;
    }

    try {
      final updatedUser = await apiClient.updateMe(
        username: result.username,
        bio: result.bio,
        status: result.status,
      );

      setState(() {
        currentUser = updatedUser;
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка обновления профиля: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось обновить профиль: $error');
    }
  }

  Future<void> renameChannel(AppChannel channel) async {
    final newName = await showTextDialog(
      context: context,
      title: 'Переименовать канал',
      label: 'Новое название',
      hintText: channel.name,
      initialValue: channel.name,
      confirmText: 'Сохранить',
    );

    if (newName == null || newName.trim().isEmpty) {
      return;
    }

    try {
      final updatedChannel = await apiClient.updateChannel(
        channelId: channel.id,
        name: newName.trim(),
      );

      setState(() {
        channels = channels
            .map<AppChannel>(
              (item) => item.id == updatedChannel.id ? updatedChannel : item,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка переименования канала: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось переименовать канал: $error');
    }
  }

  Future<void> deleteChannel(AppChannel channel) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить канал?',
      message: 'Канал "${channel.name}" будет удалён вместе с сообщениями.',
      confirmText: 'Удалить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.deleteChannel(channelId: channel.id);

      final remainingChannels = channels
          .where((item) => item.id != channel.id)
          .toList();

      final nextChannel = remainingChannels.isNotEmpty
          ? remainingChannels.first
          : null;

      setState(() {
        channels = remainingChannels;
        selectedChannelId = nextChannel?.id;
        messages = [];
      });

      if (nextChannel != null && nextChannel.type == ChannelType.text) {
        await selectChannel(nextChannel.id);
      }
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления канала: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить канал: $error');
    }
  }

  Future<void> editChannelPermissions(AppChannel channel) async {
    final result = await showChannelPermissionsDialog(
      context: context,
      channel: channel,
    );

    if (result == null) {
      return;
    }

    try {
      final updatedChannel = await apiClient.updateChannelPermissions(
        channelId: channel.id,
        permissions: result,
      );

      setState(() {
        channels = channels
            .map<AppChannel>(
              (item) => item.id == updatedChannel.id ? updatedChannel : item,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка изменения прав канала: ${error.response?.data}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось изменить права канала: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = currentUser;

    if (isLoading || user == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF15131A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF8D5CFF)),
        ),
      );
    }

    if (errorMessage != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF15131A),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              errorMessage!,
              style: const TextStyle(
                color: Color(0xFFFF7A7A),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
    }

    final selectedServer = servers.isNotEmpty && selectedServerId != null
        ? servers.firstWhere(
            (server) => server.id == selectedServerId,
            orElse: () => servers.first,
          )
        : null;

    final selectedChannel = channels.isNotEmpty && selectedChannelId != null
        ? channels.firstWhere(
            (channel) => channel.id == selectedChannelId,
            orElse: () => channels.first,
          )
        : null;
    final canManageChannels = selectedServer?.ownerId == user.id;
    final canSendMessages =
        selectedChannel == null ||
        canManageChannels ||
        selectedChannel.resolvedPermissions.canSendMessages;

    return Scaffold(
      body: Row(
        children: [
          ServersSidebar(
            servers: servers,
            selectedServerId: selectedServerId,
            onServerSelected: selectServer,
            onCreateServer: createServer,
            onJoinServer: joinServerByInvite,
          ),
          ChannelsPanel(
            serverName: selectedServer?.name ?? 'Нет серверов',
            channels: channels,
            selectedChannelId: selectedChannelId,
            currentUser: user,
            canManageChannels: canManageChannels,
            hasSelectedServer: selectedServer != null,
            canManageServer: canManageChannels,
            onChannelSelected: selectChannel,
            onCreateChannel: createChannel,
            onEditChannel: renameChannel,
            onDeleteChannel: deleteChannel,
            onEditChannelPermissions: editChannelPermissions,
            onCreateInvite: createInvite,
            onRenameServer: selectedServer == null
                ? null
                : () => renameServer(selectedServer!),
            onDeleteServer: selectedServer == null
                ? null
                : () => deleteServer(selectedServer!),
            onLeaveServer: selectedServer == null
                ? null
                : () => leaveServer(selectedServer!),
            onEditProfile: editProfile,
            onLogout: logout,
          ),
          Expanded(
            child: selectedChannel == null
                ? const EmptyChatPlaceholder()
                : ChatArea(
                    channel: selectedChannel,
                    messages: messages,
                    isMessagesLoading: isMessagesLoading,
                    canSendMessages: canSendMessages,
                    onSendMessage: sendMessage,
                    onEditMessage: editMessage,
                    onDeleteMessage: deleteMessage,
                    onShowMembers: showMembers,
                  ),
          ),
          if (selectedServer != null)
            MembersSidebar(
              members: members,
              currentUserId: user.id,
              isServerOwner: canManageChannels,
              onKickMember: kickMember,
              onRefresh: showMembers,
            ),
        ],
      ),
    );
  }
}

/* =========================
   SERVERS
========================= */

class ServersSidebar extends StatelessWidget {
  const ServersSidebar({
    super.key,
    required this.servers,
    required this.selectedServerId,
    required this.onServerSelected,
    required this.onCreateServer,
    required this.onJoinServer,
  });

  final List<AppServer> servers;
  final String? selectedServerId;
  final ValueChanged<String> onServerSelected;
  final VoidCallback onCreateServer;
  final VoidCallback onJoinServer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      color: const Color(0xFF101015),
      child: Column(
        children: [
          const SizedBox(height: 14),
          const PlumsLogoButton(),
          const SizedBox(height: 12),
          Container(width: 44, height: 1, color: const Color(0xFF2B2633)),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: servers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final server = servers[index];
                final isSelected = server.id == selectedServerId;

                return ServerIconButton(
                  server: server,
                  isSelected: isSelected,
                  onTap: () => onServerSelected(server.id),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Создать сервер',
            onPressed: onCreateServer,
            icon: const Icon(Icons.add),
            color: const Color(0xFFBFA7FF),
          ),
          IconButton(
            tooltip: 'Вступить по приглашению',
            onPressed: onJoinServer,
            icon: const Icon(Icons.login_rounded),
            color: const Color(0xFFB8ADC8),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class PlumsLogoButton extends StatelessWidget {
  const PlumsLogoButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(
          colors: [Color(0xFF8D5CFF), Color(0xFFFF7AC8)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8D5CFF).withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Center(
        child: Text(
          'P',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class ServerIconButton extends StatelessWidget {
  const ServerIconButton({
    super.key,
    required this.server,
    required this.isSelected,
    required this.onTap,
  });

  final AppServer server;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: server.name,
      child: InkWell(
        borderRadius: BorderRadius.circular(isSelected ? 18 : 26),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF8D5CFF)
                : const Color(0xFF24202B),
            borderRadius: BorderRadius.circular(isSelected ? 18 : 26),
          ),
          child: Center(
            child: Text(
              server.shortName,
              style: TextStyle(
                color: isSelected ? Colors.white : const Color(0xFFCFC4E8),
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* =========================
   CHANNELS
========================= */

class ChannelsPanel extends StatelessWidget {
  const ChannelsPanel({
    super.key,
    required this.serverName,
    required this.channels,
    required this.selectedChannelId,
    required this.currentUser,
    required this.canManageChannels,
    required this.hasSelectedServer,
    required this.canManageServer,
    required this.onChannelSelected,
    required this.onCreateChannel,
    required this.onEditChannel,
    required this.onDeleteChannel,
    required this.onEditChannelPermissions,
    required this.onCreateInvite,
    required this.onRenameServer,
    required this.onDeleteServer,
    required this.onLeaveServer,
    required this.onEditProfile,
    required this.onLogout,
  });

  final String serverName;
  final List<AppChannel> channels;
  final String? selectedChannelId;
  final AppUser currentUser;
  final bool canManageChannels;
  final bool hasSelectedServer;
  final bool canManageServer;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final ValueChanged<AppChannel> onEditChannel;
  final ValueChanged<AppChannel> onDeleteChannel;
  final ValueChanged<AppChannel> onEditChannelPermissions;
  final VoidCallback onCreateInvite;
  final VoidCallback? onRenameServer;
  final VoidCallback? onDeleteServer;
  final VoidCallback? onLeaveServer;
  final VoidCallback onEditProfile;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final textChannels = channels
        .where((channel) => channel.type == ChannelType.text)
        .toList();

    final voiceChannels = channels
        .where((channel) => channel.type == ChannelType.voice)
        .toList();

    return Container(
      width: 260,
      color: const Color(0xFF191620),
      child: Column(
        children: [
          ServerHeader(
            serverName: serverName,
            hasSelectedServer: hasSelectedServer,
            canManageServer: canManageServer,
            canCreateInvite: canManageChannels,
            onCreateInvite: onCreateInvite,
            onRenameServer: onRenameServer,
            onDeleteServer: onDeleteServer,
            onLeaveServer: onLeaveServer,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                ChannelSectionHeader(
                  title: 'Текстовые каналы',
                  onAdd: canManageChannels ? onCreateChannel : null,
                ),
                const SizedBox(height: 6),
                for (final channel in textChannels)
                  ChannelTile(
                    channel: channel,
                    isSelected: channel.id == selectedChannelId,
                    onTap: () => onChannelSelected(channel.id),
                    onEdit: () => onEditChannel(channel),
                    onDelete: () => onDeleteChannel(channel),
                    onPermissions: () => onEditChannelPermissions(channel),
                    canManageChannel: canManageChannels,
                  ),
                const SizedBox(height: 18),
                ChannelSectionHeader(
                  title: 'Голосовые каналы',
                  onAdd: canManageChannels ? onCreateChannel : null,
                ),
                const SizedBox(height: 6),
                for (final channel in voiceChannels)
                  ChannelTile(
                    channel: channel,
                    isSelected: channel.id == selectedChannelId,
                    onTap: () => onChannelSelected(channel.id),
                    onEdit: () => onEditChannel(channel),
                    onDelete: () => onDeleteChannel(channel),
                    onPermissions: () => onEditChannelPermissions(channel),
                    canManageChannel: canManageChannels,
                  ),
              ],
            ),
          ),
          UserPanel(
            user: currentUser,
            onEditProfile: onEditProfile,
            onLogout: onLogout,
          ),
        ],
      ),
    );
  }
}

class ServerHeader extends StatelessWidget {
  const ServerHeader({
    super.key,
    required this.serverName,
    required this.hasSelectedServer,
    required this.canManageServer,
    required this.canCreateInvite,
    required this.onCreateInvite,
    required this.onRenameServer,
    required this.onDeleteServer,
    required this.onLeaveServer,
  });

  final String serverName;
  final bool hasSelectedServer;
  final bool canManageServer;
  final bool canCreateInvite;
  final VoidCallback onCreateInvite;
  final VoidCallback? onRenameServer;
  final VoidCallback? onDeleteServer;
  final VoidCallback? onLeaveServer;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF1D1925),
        border: Border(bottom: BorderSide(color: Color(0xFF2B2633), width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFF3EEFF),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (canCreateInvite)
            IconButton(
              tooltip: 'Создать приглашение',
              onPressed: onCreateInvite,
              icon: const Icon(Icons.link_rounded),
              color: const Color(0xFFBFA7FF),
            ),
          PopupMenuButton<String>(
            tooltip: 'Настройки сервера',
            enabled: hasSelectedServer,
            color: const Color(0xFF2B2535),
            icon: const Icon(
              Icons.keyboard_arrow_down,
              color: Color(0xFFCFC4E8),
            ),
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  onRenameServer?.call();
                  break;
                case 'delete':
                  onDeleteServer?.call();
                  break;
                case 'leave':
                  onLeaveServer?.call();
                  break;
              }
            },
            itemBuilder: (context) {
              if (canManageServer) {
                return const [
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(
                      'Переименовать сервер',
                      style: TextStyle(color: Color(0xFFF3EEFF)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Удалить сервер',
                      style: TextStyle(color: Color(0xFFFF7A7A)),
                    ),
                  ),
                ];
              }

              return const [
                PopupMenuItem(
                  value: 'leave',
                  child: Text(
                    'Выйти с сервера',
                    style: TextStyle(color: Color(0xFFFFC66D)),
                  ),
                ),
              ];
            },
          ),
        ],
      ),
    );
  }
}

class ChannelSectionHeader extends StatelessWidget {
  const ChannelSectionHeader({super.key, required this.title, this.onAdd});

  final String title;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF8F849F),
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
          ),
        ),
        const Spacer(),
        if (onAdd != null)
          InkWell(
            onTap: onAdd,
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.add, size: 16, color: Color(0xFF8F849F)),
            ),
          ),
      ],
    );
  }
}

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.channel,
    required this.isSelected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onPermissions,
    required this.canManageChannel,
  });

  final AppChannel channel;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onPermissions;
  final bool canManageChannel;

  @override
  Widget build(BuildContext context) {
    final icon = channel.type == ChannelType.text
        ? Icons.tag
        : Icons.volume_up_rounded;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF2B2535) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: isSelected
                    ? const Color(0xFFF3EEFF)
                    : const Color(0xFF8F849F),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFFF3EEFF)
                        : const Color(0xFFB8ADC8),
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (isSelected && canManageChannel) ...[
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Права канала',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onPermissions,
                  icon: const Icon(
                    Icons.lock_outline,
                    size: 15,
                    color: Color(0xFFBFA7FF),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Переименовать канал',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onEdit,
                  icon: const Icon(
                    Icons.edit_outlined,
                    size: 15,
                    color: Color(0xFF8F849F),
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Удалить канал',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    size: 15,
                    color: Color(0xFFFF7A7A),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/* =========================
   USER PANEL
========================= */

class UserPanel extends StatelessWidget {
  const UserPanel({
    super.key,
    required this.user,
    required this.onEditProfile,
    required this.onLogout,
  });

  final AppUser user;
  final VoidCallback onEditProfile;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final letter = user.username.isNotEmpty
        ? user.username.characters.first.toUpperCase()
        : '?';

    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: const Color(0xFF141119),
      child: Row(
        children: [
          Stack(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF8D5CFF),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Center(
                  child: Text(
                    letter,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    color: const Color(0xFF35D07F),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(
                      color: const Color(0xFF141119),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.username,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF3EEFF),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user.status,
                  style: const TextStyle(
                    color: Color(0xFF8F849F),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Настройки профиля',
            onPressed: onEditProfile,
            icon: const Icon(Icons.settings_outlined),
            color: const Color(0xFFB8ADC8),
          ),
          IconButton(
            tooltip: 'Выйти',
            onPressed: onLogout,
            icon: const Icon(Icons.logout_rounded),
            color: const Color(0xFFFF7A7A),
          ),
        ],
      ),
    );
  }
}

/* =========================
   CHAT
========================= */

class EmptyChatPlaceholder extends StatelessWidget {
  const EmptyChatPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF211C29),
      child: const Center(
        child: Text(
          'На этом сервере пока нет каналов',
          style: TextStyle(
            color: Color(0xFFB8ADC8),
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class ChatArea extends StatelessWidget {
  const ChatArea({
    super.key,
    required this.channel,
    required this.messages,
    required this.isMessagesLoading,
    required this.canSendMessages,
    required this.onSendMessage,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.onShowMembers,
  });

  final AppChannel channel;
  final List<AppMessage> messages;
  final bool isMessagesLoading;
  final bool canSendMessages;
  final Future<void> Function(String content) onSendMessage;
  final ValueChanged<AppMessage> onEditMessage;
  final ValueChanged<AppMessage> onDeleteMessage;
  final VoidCallback onShowMembers;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF211C29),
      child: Column(
        children: [
          ChatHeader(channel: channel, onShowMembers: onShowMembers),
          Expanded(
            child: channel.type == ChannelType.text
                ? isMessagesLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF8D5CFF),
                          ),
                        )
                      : MessagesList(
                          messages: messages,
                          onEditMessage: onEditMessage,
                          onDeleteMessage: onDeleteMessage,
                        )
                : const VoiceChannelPlaceholder(),
          ),
          if (channel.type == ChannelType.text)
            MessageInput(
              channelName: channel.name,
              canSendMessages: canSendMessages,
              onSendMessage: onSendMessage,
            ),
        ],
      ),
    );
  }
}

class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.channel,
    required this.onShowMembers,
  });

  final AppChannel channel;
  final VoidCallback onShowMembers;

  @override
  Widget build(BuildContext context) {
    final icon = channel.type == ChannelType.text
        ? Icons.tag
        : Icons.volume_up_rounded;

    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF241F2D),
        border: Border(bottom: BorderSide(color: Color(0xFF312A3B), width: 1)),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFCFC4E8), size: 20),
          const SizedBox(width: 10),
          Text(
            channel.name,
            style: const TextStyle(
              color: Color(0xFFF3EEFF),
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 12),
          Container(width: 1, height: 22, color: const Color(0xFF3A3245)),
          const SizedBox(width: 12),
          Text(
            channel.type == ChannelType.text
                ? 'Текстовый канал'
                : 'Голосовой канал',
            style: const TextStyle(color: Color(0xFF8F849F), fontSize: 13),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Поиск',
            onPressed: () {},
            icon: const Icon(Icons.search),
            color: const Color(0xFFB8ADC8),
          ),
          IconButton(
            tooltip: 'Участники',
            onPressed: onShowMembers,
            icon: const Icon(Icons.people_alt_outlined),
            color: const Color(0xFFB8ADC8),
          ),
        ],
      ),
    );
  }
}

class MembersSidebar extends StatelessWidget {
  const MembersSidebar({
    super.key,
    required this.members,
    required this.currentUserId,
    required this.isServerOwner,
    required this.onKickMember,
    required this.onRefresh,
  });

  final List<AppServerMember> members;
  final String currentUserId;
  final bool isServerOwner;
  final ValueChanged<AppServerMember> onKickMember;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        color: Color(0xFF191620),
        border: Border(left: BorderSide(color: Color(0xFF2B2633), width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: const BoxDecoration(
              color: Color(0xFF1D1925),
              border: Border(
                bottom: BorderSide(color: Color(0xFF2B2633), width: 1),
              ),
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Участники',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xFFF3EEFF),
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                  color: const Color(0xFFB8ADC8),
                ),
              ],
            ),
          ),
          Expanded(
            child: members.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'Участников пока нет',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFF8F849F),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: members.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final member = members[index];
                      final user = member.user;
                      final letter = user.username.isNotEmpty
                          ? user.username.characters.first.toUpperCase()
                          : '?';
                      final canKick =
                          isServerOwner &&
                          member.userId != currentUserId &&
                          member.id.isNotEmpty;

                      return Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: const Color(0xFF8D5CFF),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Text(
                                letter,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.username,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFF3EEFF),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  user.status,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF8F849F),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (canKick)
                            IconButton(
                              tooltip: 'Удалить участника',
                              onPressed: () => onKickMember(member),
                              icon: const Icon(Icons.person_remove_outlined),
                              color: const Color(0xFFFF7A7A),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class MessagesList extends StatelessWidget {
  const MessagesList({
    super.key,
    required this.messages,
    required this.onEditMessage,
    required this.onDeleteMessage,
  });

  final List<AppMessage> messages;
  final ValueChanged<AppMessage> onEditMessage;
  final ValueChanged<AppMessage> onDeleteMessage;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const Center(
        child: Text(
          'В этом канале пока нет сообщений',
          style: TextStyle(
            color: Color(0xFFB8ADC8),
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];

        return MessageBubble(
          message: message,
          onEdit: () => onEditMessage(message),
          onDelete: () => onDeleteMessage(message),
        );
      },
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onEdit,
    required this.onDelete,
  });

  final AppMessage message;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isSystem = message.author == 'system';

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: isSystem
                  ? const Color(0xFF383142)
                  : const Color(0xFF8D5CFF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Text(
                isSystem ? 'S' : message.authorInitial,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: const Color(0xFF282230),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF342D3F)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        message.author,
                        style: TextStyle(
                          color: isSystem
                              ? const Color(0xFFBFA7FF)
                              : const Color(0xFFF3EEFF),
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        message.isEdited
                            ? '${message.time} · изменено'
                            : message.time,
                        style: const TextStyle(
                          color: Color(0xFF8F849F),
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Редактировать сообщение',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: onEdit,
                        icon: const Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: Color(0xFF8F849F),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: 'Удалить сообщение',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: onDelete,
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Color(0xFFFF7A7A),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    message.content,
                    style: const TextStyle(
                      color: Color(0xFFDCD3EA),
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MessageInput extends StatefulWidget {
  const MessageInput({
    super.key,
    required this.channelName,
    required this.canSendMessages,
    required this.onSendMessage,
  });

  final String channelName;
  final bool canSendMessages;
  final Future<void> Function(String content) onSendMessage;

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final TextEditingController controller = TextEditingController();
  bool isSending = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> submitMessage() async {
    final text = controller.text.trim();

    if (!widget.canSendMessages || text.isEmpty || isSending) {
      return;
    }

    setState(() {
      isSending = true;
    });

    try {
      await widget.onSendMessage(text);
      controller.clear();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
      color: const Color(0xFF211C29),
      child: Container(
        constraints: const BoxConstraints(minHeight: 54),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF302A39),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFF40374D)),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Прикрепить файл',
              onPressed: () {},
              icon: const Icon(Icons.add_circle_outline),
              color: const Color(0xFFBFA7FF),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: widget.canSendMessages && !isSending,
                onSubmitted: (_) => submitMessage(),
                style: const TextStyle(color: Color(0xFFF3EEFF), fontSize: 14),
                decoration: InputDecoration(
                  hintText: widget.canSendMessages
                      ? 'Написать в #${widget.channelName}'
                      : 'Нет прав писать в этот канал',
                  hintStyle: const TextStyle(color: Color(0xFF8F849F)),
                  border: InputBorder.none,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Отправить',
              onPressed: widget.canSendMessages && !isSending
                  ? submitMessage
                  : null,
              icon: isSending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFFFF7AC8),
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              color: const Color(0xFFFF7AC8),
            ),
          ],
        ),
      ),
    );
  }
}

class VoiceChannelPlaceholder extends StatelessWidget {
  const VoiceChannelPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: const Color(0xFF282230),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF3A3245)),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.volume_up_rounded, size: 42, color: Color(0xFFBFA7FF)),
            SizedBox(height: 16),
            Text(
              'Голосовой канал',
              style: TextStyle(
                color: Color(0xFFF3EEFF),
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'В backend 0.1 голосовой канал уже существует как сущность. Подключение к голосу добавим позже по ТЗ.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFB8ADC8),
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* =========================
   DIALOGS
========================= */

Future<String?> showTextDialog({
  required BuildContext context,
  required String title,
  required String label,
  required String hintText,
  required String confirmText,
  String? initialValue,
}) {
  final controller = TextEditingController(text: initialValue ?? '');

  return showDialog<String>(
    context: context,
    builder: (context) {
      return PlumsDialog(
        title: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PlumsTextField(
              controller: controller,
              label: label,
              hintText: hintText,
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB8ADC8),
                      side: const BorderSide(color: Color(0xFF40374D)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Отмена'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context, controller.text.trim());
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8D5CFF),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      confirmText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

Future<void> showInviteDialog({
  required BuildContext context,
  required AppInvite invite,
}) {
  final inviteUrl = 'http://localhost:3000/invites/${invite.code}';

  return showDialog<void>(
    context: context,
    builder: (context) {
      return PlumsDialog(
        title: 'Приглашение создано',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              invite.server?.name ?? 'Сервер',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB8ADC8),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF302A39),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF40374D)),
              ),
              child: SelectableText(
                invite.code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFF3EEFF),
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: invite.code));
                      Navigator.pop(context);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB8ADC8),
                      side: const BorderSide(color: Color(0xFF40374D)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Копировать код'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: inviteUrl));
                      Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8D5CFF),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Копировать ссылку',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Закрыть',
                style: TextStyle(
                  color: Color(0xFFBFA7FF),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Future<CreateChannelResult?> showCreateChannelDialog({
  required BuildContext context,
}) {
  final controller = TextEditingController();
  ChannelType selectedType = ChannelType.text;

  return showDialog<CreateChannelResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: 'Создать канал',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlumsTextField(
                  controller: controller,
                  label: 'Название канала',
                  hintText: 'general',
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: RadioListTile<ChannelType>(
                        value: ChannelType.text,
                        groupValue: selectedType,
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            selectedType = value;
                          });
                        },
                        activeColor: const Color(0xFF8D5CFF),
                        title: const Text(
                          'Текстовый',
                          style: TextStyle(
                            color: Color(0xFFF3EEFF),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: RadioListTile<ChannelType>(
                        value: ChannelType.voice,
                        groupValue: selectedType,
                        onChanged: (value) {
                          if (value == null) return;
                          setDialogState(() {
                            selectedType = value;
                          });
                        },
                        activeColor: const Color(0xFF8D5CFF),
                        title: const Text(
                          'Голосовой',
                          style: TextStyle(
                            color: Color(0xFFF3EEFF),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB8ADC8),
                          side: const BorderSide(color: Color(0xFF40374D)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          final name = controller.text.trim();

                          if (name.isEmpty) {
                            return;
                          }

                          Navigator.pop(
                            context,
                            CreateChannelResult(name: name, type: selectedType),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8D5CFF),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Создать',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmText,
}) {
  return showDialog<bool>(
    context: context,
    builder: (context) {
      return PlumsDialog(
        title: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB8ADC8),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFB8ADC8),
                      side: const BorderSide(color: Color(0xFF40374D)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Отмена'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5C7A),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      confirmText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

Future<EditProfileResult?> showEditProfileDialog({
  required BuildContext context,
  required AppUser user,
}) {
  final usernameController = TextEditingController(text: user.username);
  final bioController = TextEditingController(text: user.bio ?? '');
  String selectedStatus = user.status;

  return showDialog<EditProfileResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: 'Редактировать профиль',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlumsTextField(
                  controller: usernameController,
                  label: 'Username',
                  hintText: 'alexandra',
                ),
                const SizedBox(height: 14),
                PlumsTextField(
                  controller: bioController,
                  label: 'О себе',
                  hintText: 'Расскажи немного о себе',
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  value: selectedStatus,
                  dropdownColor: const Color(0xFF302A39),
                  decoration: InputDecoration(
                    labelText: 'STATUS',
                    labelStyle: const TextStyle(
                      color: Color(0xFF8F849F),
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF302A39),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  style: const TextStyle(
                    color: Color(0xFFF3EEFF),
                    fontSize: 14,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'ONLINE', child: Text('ONLINE')),
                    DropdownMenuItem(value: 'OFFLINE', child: Text('OFFLINE')),
                    DropdownMenuItem(value: 'AWAY', child: Text('AWAY')),
                    DropdownMenuItem(
                      value: 'DO_NOT_DISTURB',
                      child: Text('DO_NOT_DISTURB'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() {
                      selectedStatus = value;
                    });
                  },
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB8ADC8),
                          side: const BorderSide(color: Color(0xFF40374D)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(
                            context,
                            EditProfileResult(
                              username: usernameController.text.trim(),
                              bio: bioController.text.trim(),
                              status: selectedStatus,
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8D5CFF),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Сохранить',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

Future<ChannelPermissions?> showChannelPermissionsDialog({
  required BuildContext context,
  required AppChannel channel,
}) {
  var canView = channel.resolvedPermissions.canView;
  var canSendMessages = channel.resolvedPermissions.canSendMessages;
  var canConnect = channel.resolvedPermissions.canConnect;

  return showDialog<ChannelPermissions>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: 'Права канала',
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '#${channel.name}',
                  style: const TextStyle(
                    color: Color(0xFFB8ADC8),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 18),
                PermissionSwitchTile(
                  title: 'Видеть канал',
                  subtitle: 'Пользователь может видеть этот канал в списке.',
                  value: canView,
                  onChanged: (value) {
                    setDialogState(() {
                      canView = value;
                    });
                  },
                ),
                PermissionSwitchTile(
                  title: 'Писать сообщения',
                  subtitle:
                      'Для текстовых каналов: можно отправлять сообщения.',
                  value: canSendMessages,
                  onChanged: (value) {
                    setDialogState(() {
                      canSendMessages = value;
                    });
                  },
                ),
                PermissionSwitchTile(
                  title: 'Подключаться',
                  subtitle:
                      'Для голосовых каналов: можно подключаться к каналу.',
                  value: canConnect,
                  onChanged: (value) {
                    setDialogState(() {
                      canConnect = value;
                    });
                  },
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFB8ADC8),
                          side: const BorderSide(color: Color(0xFF40374D)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('Отмена'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(
                            context,
                            ChannelPermissions(
                              canView: canView,
                              canSendMessages: canSendMessages,
                              canConnect: canConnect,
                            ),
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8D5CFF),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          'Сохранить',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class PermissionSwitchTile extends StatelessWidget {
  const PermissionSwitchTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeColor: const Color(0xFF8D5CFF),
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFF3EEFF),
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(
          color: Color(0xFF8F849F),
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}

Future<void> showServerMembersDialog({
  required BuildContext context,
  required List<AppServerMember> members,
  required String? currentUserId,
  required bool isServerOwner,
  required ValueChanged<AppServerMember> onKickMember,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return PlumsDialog(
        title: 'Участники сервера',
        child: SizedBox(
          width: 420,
          height: 420,
          child: members.isEmpty
              ? const Center(
                  child: Text(
                    'Участников пока нет',
                    style: TextStyle(
                      color: Color(0xFFB8ADC8),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              : ListView.separated(
                  itemCount: members.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final member = members[index];
                    final user = member.user;
                    final letter = user.username.isNotEmpty
                        ? user.username.characters.first.toUpperCase()
                        : '?';

                    final canKick =
                        isServerOwner &&
                        member.userId != currentUserId &&
                        member.id.isNotEmpty;

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF302A39),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF40374D)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: const Color(0xFF8D5CFF),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Center(
                              child: Text(
                                letter,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.username,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFF3EEFF),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  user.email,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF8F849F),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            user.status,
                            style: const TextStyle(
                              color: Color(0xFFBFA7FF),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (canKick) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: 'Удалить участника',
                              onPressed: () {
                                Navigator.pop(context);
                                onKickMember(member);
                              },
                              icon: const Icon(Icons.person_remove_outlined),
                              color: const Color(0xFFFF7A7A),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
      );
    },
  );
}

class PlumsDialog extends StatelessWidget {
  const PlumsDialog({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: const Color(0xFF211C29),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFF342D3F)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFF3EEFF),
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

void showErrorSnackBar(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/* =========================
   MODELS
========================= */

class LoginResult {
  const LoginResult({required this.accessToken, required this.user});

  final String accessToken;
  final AppUser user;
}

class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.email,
    this.avatarUrl,
    this.bio,
    required this.status,
  });

  final String id;
  final String username;
  final String email;
  final String? avatarUrl;
  final String? bio;
  final String status;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      username: json['username'] as String,
      email: json['email'] as String,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      status: json['status'] as String,
    );
  }
}

class AppServer {
  const AppServer({
    required this.id,
    required this.name,
    this.iconUrl,
    this.ownerId,
  });

  final String id;
  final String name;
  final String? iconUrl;
  final String? ownerId;

  String get shortName {
    if (name.isEmpty) {
      return '?';
    }

    return name.characters.first.toUpperCase();
  }

  factory AppServer.fromJson(Map<String, dynamic> json) {
    return AppServer(
      id: json['id'] as String,
      name: json['name'] as String,
      iconUrl: json['iconUrl'] as String?,
      ownerId: json['ownerId'] as String?,
    );
  }
}

class AppInvite {
  const AppInvite({
    required this.id,
    required this.code,
    this.expiresAt,
    this.maxUses,
    this.currentUses = 0,
    this.server,
  });

  final String id;
  final String code;
  final String? expiresAt;
  final int? maxUses;
  final int currentUses;
  final AppServer? server;

  factory AppInvite.fromJson(Map<String, dynamic> json) {
    final serverJson = json['server'];

    return AppInvite(
      id: json['id'] as String,
      code: json['code'] as String,
      expiresAt: json['expiresAt'] as String?,
      maxUses: json['maxUses'] as int?,
      currentUses: json['currentUses'] as int? ?? 0,
      server: serverJson is Map<String, dynamic>
          ? AppServer.fromJson(serverJson)
          : null,
    );
  }
}

enum ChannelType { text, voice }

extension ChannelTypeX on ChannelType {
  static ChannelType fromBackend(String value) {
    switch (value) {
      case 'VOICE':
        return ChannelType.voice;
      case 'TEXT':
      default:
        return ChannelType.text;
    }
  }

  String toBackend() {
    switch (this) {
      case ChannelType.voice:
        return 'VOICE';
      case ChannelType.text:
        return 'TEXT';
    }
  }
}

class AppChannel {
  const AppChannel({
    required this.id,
    required this.name,
    required this.type,
    this.serverId,
    this.position = 0,
    this.permissions,
  });

  final String id;
  final String name;
  final ChannelType type;
  final String? serverId;
  final int position;
  final ChannelPermissions? permissions;

  ChannelPermissions get resolvedPermissions {
    return permissions ??
        const ChannelPermissions(
          canView: true,
          canSendMessages: true,
          canConnect: true,
        );
  }

  factory AppChannel.fromJson(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];

    return AppChannel(
      id: json['id'] as String,
      serverId: json['serverId'] as String?,
      name: json['name'] as String,
      type: ChannelTypeX.fromBackend(json['type'] as String),
      position: json['position'] as int? ?? 0,
      permissions: rawPermissions is Map<String, dynamic>
          ? ChannelPermissions.fromJson(rawPermissions)
          : null,
    );
  }
}

class ChannelPermissions {
  const ChannelPermissions({
    required this.canView,
    required this.canSendMessages,
    required this.canConnect,
  });

  final bool canView;
  final bool canSendMessages;
  final bool canConnect;

  factory ChannelPermissions.fromJson(Map<String, dynamic> json) {
    return ChannelPermissions(
      canView: json['canView'] as bool? ?? true,
      canSendMessages: json['canSendMessages'] as bool? ?? true,
      canConnect: json['canConnect'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'canView': canView,
      'canSendMessages': canSendMessages,
      'canConnect': canConnect,
    };
  }
}

class AppMessage {
  const AppMessage({
    required this.id,
    required this.channelId,
    required this.authorId,
    required this.author,
    required this.content,
    required this.time,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String channelId;
  final String authorId;
  final String author;
  final String content;
  final String time;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get authorInitial {
    if (author.isEmpty) {
      return '?';
    }

    return author.characters.first.toUpperCase();
  }

  bool get isEdited {
    final created = createdAt;
    final updated = updatedAt;

    if (created == null || updated == null) {
      return false;
    }

    return updated.difference(created).inSeconds.abs() > 1;
  }

  factory AppMessage.fromJson(Map<String, dynamic> json) {
    final authorJson = json['author'] as Map<String, dynamic>?;
    final createdAtRaw = json['createdAt'] as String?;
    final updatedAtRaw = json['updatedAt'] as String?;

    return AppMessage(
      id: json['id'] as String,
      channelId: json['channelId'] as String,
      authorId: json['authorId'] as String,
      author: authorJson?['username'] as String? ?? 'unknown',
      content: json['content'] as String,
      time: _formatTime(createdAtRaw),
      createdAt: DateTime.tryParse(createdAtRaw ?? ''),
      updatedAt: DateTime.tryParse(updatedAtRaw ?? ''),
    );
  }

  static String _formatTime(String? rawDate) {
    if (rawDate == null) {
      return '';
    }

    final date = DateTime.tryParse(rawDate);

    if (date == null) {
      return '';
    }

    final local = date.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }
}

class CreateChannelResult {
  const CreateChannelResult({required this.name, required this.type});

  final String name;
  final ChannelType type;
}

class EditProfileResult {
  const EditProfileResult({
    required this.username,
    required this.bio,
    required this.status,
  });

  final String username;
  final String bio;
  final String status;
}

class AppServerMember {
  const AppServerMember({
    required this.id,
    required this.serverId,
    required this.userId,
    required this.joinedAt,
    required this.user,
  });

  final String id;
  final String serverId;
  final String userId;
  final DateTime? joinedAt;
  final AppUser user;

  factory AppServerMember.fromJson(Map<String, dynamic> json) {
    return AppServerMember(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
      userId: json['userId'] as String,
      joinedAt: DateTime.tryParse(json['joinedAt'] as String? ?? ''),
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
