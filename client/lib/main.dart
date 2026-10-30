import 'dart:async';
import 'dart:math';

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
      theme: ThemeData(scaffoldBackgroundColor: const Color(0xFF15131A)),
      home: const AuthGate(),
    );
  }
}

/* =========================
   API
========================= */

const String _apiBaseUrlRaw = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:3000',
);

// Адрес backend для HTTP (ApiClient) и Socket.IO (RealtimeClient), а также
// для ссылок-приглашений. Настраивается через --dart-define=API_BASE_URL=...,
// без него поведение не меняется (localhost:3000). Убираем завершающий "/",
// чтобы не получить "//" при конкатенации путей (например, "/invites/...").
final String apiBaseUrl = _apiBaseUrlRaw.endsWith('/')
    ? _apiBaseUrlRaw.substring(0, _apiBaseUrlRaw.length - 1)
    : _apiBaseUrlRaw;

// Единая точка превращения ошибки запроса в сообщение для пользователя.
// Раньше каждое место строило текст вручную из error.response?.statusCode и
// error.response?.data — если backend недоступен (connection refused/timeout),
// у DioException вообще нет response, и пользователь видел буквально
// «Ошибка null: null». Эта функция различает таймаут, отсутствие соединения,
// конкретные статусы и некорректную структуру ответа, не печатая сырые
// значения (в т.ч. заголовки/токены) напрямую.
String describeRequestError(Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Сервер не отвечает, проверьте соединение и попробуйте ещё раз';
      case DioExceptionType.connectionError:
        return 'Не удалось подключиться к серверу';
      case DioExceptionType.cancel:
        return 'Запрос отменён';
      case DioExceptionType.badCertificate:
        return 'Небезопасное соединение с сервером';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    final response = error.response;

    if (response == null) {
      return 'Не удалось подключиться к серверу';
    }

    switch (response.statusCode) {
      case 401:
        return 'Сессия истекла, войдите снова';
      case 403:
        return 'Недостаточно прав для этого действия';
      case 429:
        return 'Слишком много запросов, попробуйте позже';
    }

    final statusCode = response.statusCode;

    if (statusCode != null && statusCode >= 500) {
      return 'Сервер временно недоступен, попробуйте позже';
    }

    final data = response.data;

    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }

    if (data is String && data.isNotEmpty) {
      return data;
    }

    return 'Сервер вернул некорректный ответ (код ${statusCode ?? 'неизвестен'})';
  }

  return 'Непредвиденная ошибка, попробуйте ещё раз';
}

// Отличает ВРЕМЕННУЮ недоступность сети/backend (таймаут, отсутствие
// соединения, 5xx, либо вообще не распознанная не-DioException ошибка) от
// ПОДТВЕРЖДЁННОГО отказа — когда backend успел ответить и явно отверг запрос
// (например, 401/403 с реальным response). Используется restoreSession(),
// чтобы не стирать валидный refresh-токен только потому, что Wi-Fi/backend
// на секунду пропали. DioException без response (таймауты, connectionError и
// т.п.) всегда попадает во "временная" — именно так backend ничего не успел
// подтвердить или отвергнуть.
bool isTemporaryRequestError(Object error) {
  if (error is! DioException) {
    return true;
  }

  final statusCode = error.response?.statusCode;

  if (error.response == null) {
    return true;
  }

  return statusCode == null || statusCode >= 500;
}

class ApiClient {
  ApiClient()
    : dio = Dio(
        BaseOptions(
          baseUrl: apiBaseUrl,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          headers: {'Content-Type': 'application/json'},
        ),
      ) {
    // Если access-токен истёк (401), пробуем тихо обновить его через refreshToken
    // и повторить исходный запрос. Если обновить не удалось — отдаём исходную
    // ошибку дальше, как раньше, и вызывающий код разлогинивает пользователя.
    dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          final isUnauthorized = error.response?.statusCode == 401;
          final isRefreshRequest = error.requestOptions.path == '/auth/refresh';
          final alreadyRetried = error.requestOptions.extra['retried'] == true;

          if (!isUnauthorized ||
              isRefreshRequest ||
              alreadyRetried ||
              refreshToken == null) {
            handler.next(error);
            return;
          }

          try {
            await _refreshTokens();
          } catch (refreshError) {
            if (isTemporaryRequestError(refreshError)) {
              // Сам запрос /auth/refresh временно недоступен (таймаут,
              // connectionError, 5xx) — backend ничего не подтвердил и не
              // отверг, сессия потенциально ещё валидна. Не стираем токены и
              // пробрасываем вызывающему коду РЕАЛЬНУЮ ошибку refresh (а не
              // исходную 401 от первого запроса), чтобы
              // isTemporaryRequestError() выше по стеку (например, в
              // restoreSession()) увидел настоящую временную ошибку, а не
              // подтверждённый отказ.
              final rejection = refreshError is DioException
                  ? refreshError
                  : DioException(
                      requestOptions: error.requestOptions,
                      error: refreshError,
                      type: DioExceptionType.unknown,
                    );
              handler.reject(rejection);
              return;
            }

            // Backend ответил и явно отверг refresh (например, 401/400) —
            // refresh-токен действительно недействителен.
            accessToken = null;
            refreshToken = null;
            await authStorage.clearTokens();
            handler.next(error);
            return;
          }

          final retryRequest = error.requestOptions;
          retryRequest.headers['Authorization'] = 'Bearer $accessToken';
          retryRequest.extra['retried'] = true;

          try {
            final response = await dio.fetch(retryRequest);
            handler.resolve(response);
          } on DioException catch (retryError) {
            handler.next(retryError);
          }
        },
      ),
    );
  }

  final Dio dio;
  String? accessToken;
  String? refreshToken;
  Future<void>? _refreshInFlight;

  Options get authOptions {
    return Options(headers: {'Authorization': 'Bearer $accessToken'});
  }

  // Ротация на бэкенде отзывает refresh-токен сразу после использования, поэтому
  // параллельные 401 не должны запускать обновление токена дважды — один
  // конкурентный запрос выиграет гонку, а второй получит уже отозванный токен.
  // Все обращения идут через один и тот же in-flight Future.
  Future<void> _refreshTokens() {
    return _refreshInFlight ??= _performRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<void> _performRefresh() async {
    final currentRefreshToken = refreshToken;

    if (currentRefreshToken == null) {
      throw StateError('Нет refresh-токена');
    }

    final response = await dio.post(
      '/auth/refresh',
      data: {'refreshToken': currentRefreshToken},
    );

    accessToken = response.data['accessToken'] as String;
    refreshToken = response.data['refreshToken'] as String;

    await authStorage.saveTokens(
      accessToken: accessToken!,
      refreshToken: refreshToken!,
    );
  }

  Future<void> logout() async {
    final currentRefreshToken = refreshToken;

    if (currentRefreshToken == null) {
      return;
    }

    try {
      await dio.post(
        '/auth/logout',
        data: {'refreshToken': currentRefreshToken},
      );
    } catch (_) {
      // Логаут на клиенте не должен блокироваться ошибкой бэкенда.
    }
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
    final newRefreshToken = response.data['refreshToken'] as String;
    accessToken = token;
    refreshToken = newRefreshToken;

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
        'username': ?username,
        'bio': ?bio,
        'status': ?status,
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

  Future<void> banServerMember({
    required String serverId,
    required String userId,
    String? reason,
  }) async {
    await dio.post(
      '/servers/$serverId/bans/$userId',
      options: authOptions,
      data: {if (reason != null && reason.isNotEmpty) 'reason': reason},
    );
  }

  Future<void> unbanServerMember({
    required String serverId,
    required String userId,
  }) async {
    await dio.delete(
      '/servers/$serverId/bans/$userId',
      options: authOptions,
    );
  }

  Future<List<AppServerBan>> getServerBans(String serverId) async {
    final response = await dio.get(
      '/servers/$serverId/bans',
      options: authOptions,
    );

    final list = response.data as List;

    return list
        .map((item) => AppServerBan.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<List<AppRole>> getServerRoles(String serverId) async {
    final response = await dio.get(
      '/servers/$serverId/roles',
      options: authOptions,
    );

    final list = response.data as List;

    return list
        .map((item) => AppRole.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppRole> createRole({
    required String serverId,
    required String name,
    String? color,
    required Map<String, bool> permissions,
  }) async {
    final response = await dio.post(
      '/servers/$serverId/roles',
      options: authOptions,
      data: {
        'name': name,
        'color': ?color,
        ...permissions,
      },
    );

    return AppRole.fromJson(response.data as Map<String, dynamic>);
  }

  Future<AppRole> updateRole({
    required String roleId,
    required String name,
    String? color,
    required Map<String, bool> permissions,
  }) async {
    final response = await dio.patch(
      '/roles/$roleId',
      options: authOptions,
      data: {'name': name, 'color': color, ...permissions},
    );

    return AppRole.fromJson(response.data as Map<String, dynamic>);
  }

  Future<void> deleteRole({required String roleId}) async {
    await dio.delete('/roles/$roleId', options: authOptions);
  }

  Future<void> assignRole({
    required String serverId,
    required String memberId,
    required String roleId,
  }) async {
    await dio.post(
      '/servers/$serverId/members/$memberId/roles/$roleId',
      options: authOptions,
    );
  }

  Future<void> unassignRole({
    required String serverId,
    required String memberId,
    required String roleId,
  }) async {
    await dio.delete(
      '/servers/$serverId/members/$memberId/roles/$roleId',
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

  Future<List<AppMessage>> getMessages(
    String channelId, {
    int limit = 50,
    String? before,
    String? after,
  }) async {
    final response = await dio.get(
      '/channels/$channelId/messages',
      options: authOptions,
      queryParameters: {
        'limit': limit,
        'before': ?before,
        'after': ?after,
      },
    );

    final list = response.data as List;

    return list
        .map((item) => AppMessage.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<AppMessage> sendMessage({
    required String channelId,
    required String content,
    String? clientMessageId,
  }) async {
    final response = await dio.post(
      '/channels/$channelId/messages',
      options: authOptions,
      data: {
        'content': content,
        'clientMessageId': ?clientMessageId,
      },
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
  static const String _refreshTokenKey = 'refreshToken';

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessTokenKey, accessToken);
    await prefs.setString(_refreshTokenKey, refreshToken);
  }

  Future<String?> readAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_accessTokenKey);
  }

  Future<String?> readRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_refreshTokenKey);
  }

  Future<void> clearTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_accessTokenKey);
    await prefs.remove(_refreshTokenKey);
  }
}

class RealtimeClient {
  RealtimeClient({String? socketUrl}) {
    try {
      socket = io.io(
        socketUrl ?? apiBaseUrl,
        io.OptionBuilder()
            .setTransports(['websocket'])
            .enableForceNew()
            .disableAutoConnect()
            .build(),
      );
    } catch (_) {
      // Совсем некорректный API_BASE_URL (например, пустая строка) может
      // привести к синхронному исключению внутри io.io(). Не даём этому
      // уронить запуск приложения — откатываемся на дефолтный адрес,
      // ошибки подключения всё равно обработает onError/connect_error ниже.
      socket = io.io(
        'http://localhost:3000',
        io.OptionBuilder()
            .setTransports(['websocket'])
            .enableForceNew()
            .disableAutoConnect()
            .build(),
      );
    }
  }

  late final io.Socket socket;
  String? _currentServerId;
  String? _currentChannelId;
  bool _identified = false;
  bool _disposed = false;
  bool _handlersInstalled = false;
  bool _manuallyDisconnected = false;
  Timer? _reconnectWatchdog;
  int _connectionEpoch = 0;
  ValueChanged<String?>? _onRoomJoined;
  ValueChanged<RealtimeChannelDelete>? _onChannelJoinDenied;

  // Сокет подключён и сессия подтверждена presence:identify — только тогда
  // ранее выбранная комната канала действительно активна на backend.
  bool get isIdentified => _identified && socket.connected;

  void connect({
    required Future<String?> Function() getAccessToken,
    required VoidCallback onSessionExpired,
    required Future<void> Function() onIdentified,
    required ValueChanged<AppMessage> onMessageNew,
    required ValueChanged<AppMessage> onMessageUpdate,
    required ValueChanged<RealtimeMessageDelete> onMessageDelete,
    required ValueChanged<AppChannel> onChannelNew,
    required ValueChanged<AppChannel> onChannelUpdate,
    required ValueChanged<RealtimeChannelDelete> onChannelDelete,
    required ValueChanged<String> onServerAccessDenied,
    required ValueChanged<RealtimeMemberLeave> onMemberLeave,
    required ValueChanged<AppServerMember> onMemberJoin,
    required ValueChanged<RealtimeUserStatus> onUserStatus,
    required ValueChanged<RealtimeRoleEvent> onRoleNew,
    required ValueChanged<RealtimeRoleEvent> onRoleUpdate,
    required ValueChanged<RealtimeRoleDelete> onRoleDelete,
    required ValueChanged<RealtimeMemberRolesUpdate> onMemberRolesUpdate,
    required ValueChanged<String?> onReconnected,
    VoidCallback? onDisconnected,
  }) {
    if (_disposed || _handlersInstalled) return;
    _handlersInstalled = true;
    _onRoomJoined = onReconnected;
    _onChannelJoinDenied = onChannelDelete;

    Future<void> identifyAndRejoin() async {
      final epoch = ++_connectionEpoch;
      _identified = false;
      try {
        // getMe обновляет истёкший access-токен через существующий Dio interceptor.
        final token = await getAccessToken();
        if (_disposed || !socket.connected || epoch != _connectionEpoch) return;
        if (token == null || token.isEmpty) {
          onSessionExpired();
          return;
        }
        final ack = await socket.timeout(5000).emitWithAckAsync(
          'presence:identify',
          {'token': token},
        );
        if (_disposed || !socket.connected || epoch != _connectionEpoch) return;
        if (ack is! Map || ack['userId'] is! String) {
          throw StateError('Не получено подтверждение сессии');
        }

        _identified = true;
        await onIdentified();
        if (_disposed || !socket.connected || epoch != _connectionEpoch) return;
        final serverId = _currentServerId;
        if (serverId != null) socket.emit('server:join', {'serverId': serverId});
        var channelId = _currentChannelId;
        while (channelId != null) {
          // Догрузка должна начинаться после фактического входа в комнату:
          // иначе сообщение между REST-ответом и join теряется.
          final joinAck = await socket.timeout(5000).emitWithAckAsync(
            'channel:join',
            {'channelId': channelId},
          );
          if (_disposed || !socket.connected || epoch != _connectionEpoch) return;
          if (_currentChannelId != channelId) {
            socket.emit('channel:leave', {'channelId': channelId});
            channelId = _currentChannelId;
            continue;
          }
          if (joinAck is! Map ||
              joinAck['joined'] != true ||
              joinAck['channelId'] != channelId) {
            if (joinAck is Map &&
                (joinAck['reason'] == 'forbidden' ||
                    joinAck['reason'] == 'not_found') &&
                _currentServerId != null) {
              onChannelDelete(
                RealtimeChannelDelete(
                  id: channelId,
                  serverId: _currentServerId!,
                ),
              );
              return;
            }
            throw StateError('Не получено подтверждение входа в канал');
          }
          onReconnected(channelId);
          return;
        }
        onReconnected(null);
      } catch (_) {
        if (_disposed || !socket.connected || epoch != _connectionEpoch) return;
        Future.delayed(const Duration(seconds: 5), () {
          if (!_disposed && socket.connected && epoch == _connectionEpoch) {
            identifyAndRejoin();
          }
        });
      }
    }

    socket.onConnect((_) {
      _manuallyDisconnected = false;
      identifyAndRejoin();
    });
    socket.onDisconnect((reason) {
      // Фиксируем точку синхронизации ДО любой другой обработки разрыва:
      // после этого момента по этому соединению не может прийти новое
      // realtime-событие, поэтому вызывающая сторона может безопасно
      // использовать текущее состояние как надёжный якорь для докачки.
      onDisconnected?.call();
      _identified = false;
      _connectionEpoch++;
      _manuallyDisconnected = reason == 'io client disconnect';
      // Socket.IO не переподключает namespace после штатного отключения
      // сервером (io server disconnect). После перезапуска backend запускаем
      // повторное подключение сами.
      if (!_disposed && reason == 'io server disconnect') {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!_disposed && !_manuallyDisconnected && !socket.connected) {
            socket.connect();
          }
        });
      }
    });
    socket.on('session:expired', (_) {
      if (_disposed || !socket.connected) return;
      // Backend уже удалил защищённые комнаты. Получаем актуальный JWT через
      // getMe (401 запускает refresh), затем вступаем обратно только после ack.
      _identified = false;
      identifyAndRejoin();
    });

    socket.on('server:error', (data) {
      if (data is Map && data['serverId'] is String) {
        onServerAccessDenied(data['serverId'] as String);
      }
    });

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

    socket.on('member:join', (data) {
      if (data is Map) {
        onMemberJoin(AppServerMember.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('user:status', (data) {
      if (data is Map) {
        onUserStatus(
          RealtimeUserStatus.fromJson(Map<String, dynamic>.from(data)),
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

    socket.on('role:new', (data) {
      if (data is Map) {
        onRoleNew(RealtimeRoleEvent.fromJson(Map<String, dynamic>.from(data)));
      }
    });

    socket.on('role:update', (data) {
      if (data is Map) {
        onRoleUpdate(
          RealtimeRoleEvent.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.on('role:delete', (data) {
      if (data is Map) {
        onRoleDelete(
          RealtimeRoleDelete.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    socket.on('member:roles:update', (data) {
      if (data is Map) {
        onMemberRolesUpdate(
          RealtimeMemberRolesUpdate.fromJson(Map<String, dynamic>.from(data)),
        );
      }
    });

    // На случай, если автоматическое переподключение транспорта остановилось,
    // периодически пробуем вернуть сессию. Намеренный disconnect() и dispose()
    // повторно не подключаем.
    _reconnectWatchdog ??= Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_disposed && !_manuallyDisconnected && !socket.connected) {
        socket.connect();
      }
    });

    if (socket.connected) identifyAndRejoin();
    socket.connect();
  }

  void joinServer(String serverId) {
    _currentServerId = serverId;

    if (!socket.connected) {
      socket.connect();
      return;
    }

    if (_identified) socket.emit('server:join', {'serverId': serverId});
  }

  void leaveServer(String serverId) {
    if (_currentServerId == serverId) {
      _currentServerId = null;
    }

    if (socket.connected) socket.emit('server:leave', {'serverId': serverId});
  }

  void joinChannel(String channelId) {
    _currentChannelId = channelId;
    if (!socket.connected) {
      socket.connect();
      return;
    }

    if (_identified) unawaited(_joinChannelWithAck(channelId));
  }

  // Вход в комнату уже identified-сокетом: докачка истории должна стартовать
  // только после подтверждения входа (ack), иначе сообщения между REST-ответом
  // и фактическим join теряются. До identify канал войдёт identifyAndRejoin.
  Future<void> _joinChannelWithAck(String channelId) async {
    final epoch = _connectionEpoch;
    bool stale() =>
        _disposed ||
        !socket.connected ||
        epoch != _connectionEpoch ||
        !_identified ||
        _currentChannelId != channelId;
    try {
      final ack = await socket.timeout(5000).emitWithAckAsync(
        'channel:join',
        {'channelId': channelId},
      );
      // При смене канала leaveChannel уже отправил channel:leave.
      if (stale()) return;
      if (ack is Map &&
          ack['joined'] == true &&
          ack['channelId'] == channelId) {
        _onRoomJoined?.call(channelId);
        return;
      }
      if (ack is Map &&
          (ack['reason'] == 'forbidden' || ack['reason'] == 'not_found') &&
          _currentServerId != null) {
        _onChannelJoinDenied?.call(
          RealtimeChannelDelete(id: channelId, serverId: _currentServerId!),
        );
        return;
      }
    } catch (_) {
      if (stale()) return;
    }
    Future.delayed(const Duration(seconds: 5), () {
      if (!stale()) unawaited(_joinChannelWithAck(channelId));
    });
  }

  void leaveChannel(String channelId) {
    if (_currentChannelId == channelId) _currentChannelId = null;
    if (socket.connected) socket.emit('channel:leave', {'channelId': channelId});
  }

  void dispose() {
    _disposed = true;
    _connectionEpoch++;
    _reconnectWatchdog?.cancel();
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

class RealtimeUserStatus {
  const RealtimeUserStatus({required this.userId, required this.status});

  final String userId;
  final String status;

  factory RealtimeUserStatus.fromJson(Map<String, dynamic> json) {
    return RealtimeUserStatus(
      userId: json['userId'] as String,
      status: json['status'] as String,
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

class RealtimeRoleEvent {
  const RealtimeRoleEvent({required this.serverId, required this.role});

  final String serverId;
  final AppRole role;

  factory RealtimeRoleEvent.fromJson(Map<String, dynamic> json) {
    return RealtimeRoleEvent(
      serverId: json['serverId'] as String,
      role: AppRole.fromJson(json['role'] as Map<String, dynamic>),
    );
  }
}

class RealtimeRoleDelete {
  const RealtimeRoleDelete({required this.serverId, required this.roleId});

  final String serverId;
  final String roleId;

  factory RealtimeRoleDelete.fromJson(Map<String, dynamic> json) {
    return RealtimeRoleDelete(
      serverId: json['serverId'] as String,
      roleId: json['roleId'] as String,
    );
  }
}

class RealtimeMemberRolesUpdate {
  const RealtimeMemberRolesUpdate({
    required this.serverId,
    required this.memberId,
    required this.userId,
    required this.roles,
  });

  final String serverId;
  final String memberId;
  final String userId;
  final List<AppRole> roles;

  factory RealtimeMemberRolesUpdate.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];

    return RealtimeMemberRolesUpdate(
      serverId: json['serverId'] as String,
      memberId: json['memberId'] as String,
      userId: json['userId'] as String,
      roles: rawRoles is List
          ? rawRoles
              .map((item) => AppRole.fromJson(item as Map<String, dynamic>))
              .toList()
          : const [],
    );
  }
}

/* =========================
   AUTH
========================= */

class AuthGate extends StatefulWidget {
  // apiClient/authStorage по умолчанию берутся из глобальных singleton — это
  // сохраняет прежнее поведение. Необязательные параметры добавлены только
  // для тестируемости restoreSession() (подмена в widget-тестах), поведение
  // приложения по умолчанию не меняется.
  const AuthGate({super.key, this.apiClient, this.authStorage});

  final ApiClient? apiClient;
  final AuthStorage? authStorage;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final ApiClient _apiClient = widget.apiClient ?? apiClient;
  late final AuthStorage _authStorage = widget.authStorage ?? authStorage;

  AppUser? currentUser;
  bool isCheckingAuth = true;
  // true, когда restoreSession() столкнулась с ВРЕМЕННОЙ недоступностью
  // сети/backend (см. isTemporaryRequestError) — токены в этом случае не
  // стираются, пользователь остаётся на экране "нет соединения" с кнопкой
  // "Повторить", а не выкидывается на логин.
  bool isOffline = false;

  @override
  void initState() {
    super.initState();
    restoreSession();
  }

  Future<void> restoreSession() async {
    final token = await _authStorage.readAccessToken();
    final storedRefreshToken = await _authStorage.readRefreshToken();

    if (token == null || token.isEmpty) {
      if (!mounted) return;

      setState(() {
        isCheckingAuth = false;
        isOffline = false;
      });

      return;
    }

    try {
      _apiClient.accessToken = token;
      _apiClient.refreshToken = storedRefreshToken;
      // Если accessToken уже истёк, ApiClient сам попробует тихо обновить его
      // через refreshToken прямо во время этого запроса.
      final user = await _apiClient.getMe();

      if (!mounted) return;

      setState(() {
        currentUser = user;
        isCheckingAuth = false;
        isOffline = false;
      });
    } catch (error) {
      if (isTemporaryRequestError(error)) {
        // Сеть/backend временно недоступны — это не подтверждённый отказ
        // сессии, поэтому валидные токены трогать нельзя.
        if (!mounted) return;

        setState(() {
          isCheckingAuth = false;
          isOffline = true;
        });

        return;
      }

      await _authStorage.clearTokens();
      _apiClient.accessToken = null;
      _apiClient.refreshToken = null;

      if (!mounted) return;

      setState(() {
        currentUser = null;
        isCheckingAuth = false;
        isOffline = false;
      });
    }
  }

  // Кнопка "Повторить" на экране "нет соединения": возвращаемся в состояние
  // проверки и заново пытаемся восстановить сессию.
  Future<void> retryRestoreSession() async {
    if (!mounted) return;

    setState(() {
      isCheckingAuth = true;
      isOffline = false;
    });

    await restoreSession();
  }

  Future<void> handleLogin(AppUser user) async {
    final token = _apiClient.accessToken;
    final refreshToken = _apiClient.refreshToken;

    if (token != null &&
        token.isNotEmpty &&
        refreshToken != null &&
        refreshToken.isNotEmpty) {
      await _authStorage.saveTokens(
        accessToken: token,
        refreshToken: refreshToken,
      );
    }

    if (!mounted) return;

    setState(() {
      currentUser = user;
    });
  }

  Future<void> handleLogout() async {
    await _apiClient.logout();
    await _authStorage.clearTokens();
    _apiClient.accessToken = null;
    _apiClient.refreshToken = null;

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

    if (isOffline) {
      return Scaffold(
        backgroundColor: const Color(0xFF15131A),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Нет соединения с сервером',
                style: TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8D5CFF),
                ),
                onPressed: () => unawaited(retryRestoreSession()),
                child: const Text('Повторить'),
              ),
            ],
          ),
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
    } catch (error) {
      // На экране входа 401 означает неверный email/пароль, а не истёкшую
      // сессию — общая формулировка describeRequestError здесь не подходит.
      final isInvalidCredentials =
          error is DioException && error.response?.statusCode == 401;

      setState(() {
        errorMessage = isInvalidCredentials
            ? 'Неверный email или пароль'
            : 'Не удалось войти: ${describeRequestError(error)}';
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
    } catch (error) {
      // Авторегистрация сразу логинится — 401 здесь тоже означает неверные
      // учётные данные, а не истёкшую сессию (см. submitLogin).
      final isInvalidCredentials =
          error is DioException && error.response?.statusCode == 401;

      setState(() {
        errorMessage = isInvalidCredentials
            ? 'Неверный email или пароль'
            : 'Не удалось зарегистрироваться: ${describeRequestError(error)}';
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
                color: Colors.black.withValues(alpha: 0.35),
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
  List<AppRole> serverRoles = [];

  String? selectedServerId;
  String? selectedChannelId;
  String? realtimeServerId;
  String? realtimeChannelId;

  bool isLoading = true;
  bool isMessagesLoading = false;
  bool hasMoreMessages = false;
  bool isLoadingMoreMessages = false;
  String? errorMessage;
  String? messagesError;

  // Докачка истории выбранного канала после (пере)входа в комнату: хранит
  // подтверждённую точку непрерывной синхронизации, pending-запрос и guard
  // против параллельных циклов (см. MessageSyncController).
  late final MessageSyncController _messageSync = MessageSyncController(
    fetch: (channelId, {required limit, after, before}) => apiClient
        .getMessages(channelId, limit: limit, after: after, before: before),
    readMessages: () => messages,
    writeMessages: (next, {hasMore}) {
      if (!mounted) return;
      setState(() {
        messages = next;
        if (hasMore != null) {
          hasMoreMessages = hasMore;
          messagesError = null;
        }
      });
    },
    isChannelActive: (channelId) =>
        mounted && selectedChannelId == channelId,
    onIncomplete: (channelId, retry) {
      if (!mounted || selectedChannelId != channelId) return;
      showErrorSnackBar(
        context,
        'Не удалось полностью восстановить историю сообщений после '
        'переподключения',
        action: SnackBarAction(
          label: 'Повторить',
          onPressed: () => unawaited(retry()),
        ),
      );
    },
  );

  final ScrollController messagesScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    currentUser = widget.initialUser;
    messagesScrollController.addListener(_handleMessagesScroll);
    realtimeClient.connect(
      getAccessToken: () async {
        try {
          await apiClient.getMe();
        } catch (_) {
          if (apiClient.accessToken == null) return null;
          rethrow;
        }
        return apiClient.accessToken;
      },
      onSessionExpired: () {
        if (mounted) unawaited(widget.onLoggedOut());
      },
      onIdentified: refreshAccessAfterReidentify,
      onMessageNew: handleRealtimeMessage,
      onMessageUpdate: handleRealtimeMessageUpdate,
      onMessageDelete: handleRealtimeMessageDelete,
      onChannelNew: handleRealtimeChannelNew,
      onChannelUpdate: handleRealtimeChannelUpdate,
      onChannelDelete: handleRealtimeChannelDelete,
      onServerAccessDenied: handleRealtimeServerAccessDenied,
      onMemberLeave: handleRealtimeMemberLeave,
      onMemberJoin: handleRealtimeMemberJoin,
      onUserStatus: handleRealtimeUserStatus,
      onRoleNew: handleRealtimeRoleNew,
      onRoleUpdate: handleRealtimeRoleUpdate,
      onRoleDelete: handleRealtimeRoleDelete,
      onMemberRolesUpdate: handleRealtimeMemberRolesUpdate,
      onReconnected: handleRealtimeReconnected,
      onDisconnected: handleRealtimeDisconnected,
    );
    loadInitialData();
  }

  @override
  void dispose() {
    messagesScrollController.removeListener(_handleMessagesScroll);
    messagesScrollController.dispose();
    realtimeClient.dispose();
    super.dispose();
  }

  void _handleMessagesScroll() {
    if (!messagesScrollController.hasClients) {
      return;
    }

    // Подгружаем более старые сообщения, когда пользователь подскроллил
    // близко к верхней границе списка (список не reversed: верх = старые сообщения).
    const loadMoreThreshold = 200.0;

    if (messagesScrollController.position.pixels <= loadMoreThreshold) {
      loadMoreMessages();
    }
  }

  void _scrollMessagesToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !messagesScrollController.hasClients) {
        return;
      }

      messagesScrollController.jumpTo(
        messagesScrollController.position.maxScrollExtent,
      );
    });
  }

  Future<void> logout() async {
    realtimeClient.dispose();
    await widget.onLoggedOut();
  }

  bool handleUnauthorized(DioException error) {
    if (error.response?.statusCode != 401) {
      return false;
    }

    logout();
    return true;
  }

  // События kick/ban/скрытия канала могли пройти, пока сокет был отключён.
  // Перед восстановлением комнат сверяем локальные списки с REST, сохраняя
  // выбранный канал и уже загруженные сообщения, если доступ не изменился.
  Future<void> refreshAccessAfterReidentify() async {
    if (!mounted || isLoading) return;
    final serverId = selectedServerId;

    try {
      final availableServers = await apiClient.getServers();
      if (!mounted || selectedServerId != serverId) return;

      if (serverId == null) {
        setState(() => servers = availableServers);
        return;
      }
      if (!availableServers.any((server) => server.id == serverId)) {
        setState(() => servers = availableServers);
        await selectNextServerAfterRemoving(serverId);
        if (mounted) {
          showErrorSnackBar(context, 'Вы больше не состоите на этом сервере');
        }
        return;
      }

      final visibleChannels = await apiClient.getChannels(serverId);
      if (!mounted || selectedServerId != serverId) return;
      final currentChannelId = selectedChannelId;
      setState(() {
        servers = availableServers;
        channels = sortChannels(visibleChannels);
      });
      if (currentChannelId != null &&
          !visibleChannels.any((channel) => channel.id == currentChannelId)) {
        final nextChannel = visibleChannels.isNotEmpty ? visibleChannels.first : null;
        setState(() {
          selectedChannelId = null;
          messages = [];
          hasMoreMessages = false;
        });
        syncRealtimeChannel(null);
        if (nextChannel != null) await selectChannel(nextChannel.id);
      }
    } on DioException catch (error) {
      if (serverId != null &&
          (error.response?.statusCode == 403 ||
              error.response?.statusCode == 404) &&
          mounted &&
          selectedServerId == serverId) {
        await selectNextServerAfterRemoving(serverId);
      }
      // При временной ошибке сети оставляем локальные данные. Проверки join
      // на backend всё равно не разрешат вернуть отозванный доступ.
    }
  }

  // После обрыва и восстановления Socket.IO-соединения клиент заново
  // присоединяется к комнате канала, но сообщения, отправленные другими
  // участниками за время обрыва, по realtime не придут — их докачивает
  // MessageSyncController от подтверждённой точки синхронизации. Сам разрыв
  // только снимает признак inSync: последнее отображённое (возможно, live)
  // сообщение курсором не становится.
  void handleRealtimeDisconnected() {
    _messageSync.onDisconnected();
  }

  // Вызывается RealtimeClient после подтверждённого (ack) входа в комнату —
  // и при переподключении, и при первом входе/переключении канала.
  Future<void> handleRealtimeReconnected(String? channelId) async {
    if (!mounted || channelId == null) return;
    await _messageSync.onRoomJoined(channelId);
  }

  void handleRealtimeMessage(AppMessage message) {
    if (!mounted || message.channelId != selectedChannelId) {
      return;
    }

    if (!messages.any((item) => item.id == message.id)) {
      setState(() {
        messages = [...messages, message];
      });
    }
    // Продвигает подтверждённую точку только в состоянии inSync.
    _messageSync.onLiveMessage(message);
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
      final hasChannel = channels.any((item) => item.id == channel.id);

      channels = sortChannels(
        hasChannel
            ? channels
                  .map<AppChannel>(
                    (item) => item.id == channel.id ? channel : item,
                  )
                  .toList()
            : [...channels, channel],
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

      final message = switch (event.reason) {
        'kick' => 'Вас удалили с сервера',
        'ban' => 'Вас забанили на сервере',
        _ => 'Вы вышли с сервера',
      };

      showErrorSnackBar(context, message);
    }
  }

  void handleRealtimeServerAccessDenied(String serverId) {
    if (!mounted || selectedServerId != serverId) return;
    unawaited(selectNextServerAfterRemoving(serverId));
    showErrorSnackBar(context, 'Вы больше не состоите на этом сервере');
  }

  void handleRealtimeMemberJoin(AppServerMember member) {
    if (!mounted || member.serverId != selectedServerId) {
      return;
    }

    if (members.any((item) => item.id == member.id)) {
      return;
    }

    setState(() {
      members = [...members, member];
    });
  }

  void handleRealtimeRoleNew(RealtimeRoleEvent event) {
    if (!mounted || event.serverId != selectedServerId) {
      return;
    }

    if (serverRoles.any((role) => role.id == event.role.id)) {
      return;
    }

    setState(() {
      serverRoles = [...serverRoles, event.role];
    });

    // Событие несёт краткую роль (без permissions). Подтягиваем полный
    // список ролей и участников из API, чтобы effectivePermissions у всех
    // клиентов пересчитался по актуальным правам.
    unawaited(_refreshServerRolesAndMembers(event.serverId));
  }

  void handleRealtimeRoleUpdate(RealtimeRoleEvent event) {
    if (!mounted || event.serverId != selectedServerId) {
      return;
    }

    setState(() {
      serverRoles = _mergeUpdatedRoleInto(serverRoles, event.role);

      members = members
          .map<AppServerMember>(
            (member) => member.roles.any((role) => role.id == event.role.id)
                ? member.copyWith(
                    roles: _mergeUpdatedRoleInto(member.roles, event.role),
                  )
                : member,
          )
          .toList();
    });

    // Событие несёт краткую роль (без permissions). Подтягиваем полный
    // список ролей и участников из API, чтобы effectivePermissions у всех
    // клиентов пересчитался по актуальным правам.
    unawaited(_refreshServerRolesAndMembers(event.serverId));
  }

  // При обновлении роли по realtime-событию сохраняем permissions из
  // существующей полной роли, если событие их не несёт (краткая роль).
  // Это не даёт потерять права у клиентов, кроме инициатора, до того как
  // refresh подтянет полные роли из backend.
  List<AppRole> _mergeUpdatedRoleInto(List<AppRole> roles, AppRole updated) {
    final hasRole = roles.any((role) => role.id == updated.id);
    if (!hasRole) {
      return [...roles, updated];
    }

    return roles
        .map<AppRole>(
          (role) => role.id == updated.id
              ? _preservePermissions(updated, role)
              : role,
        )
        .toList();
  }

  AppRole _preservePermissions(AppRole incoming, AppRole existing) {
    if (incoming.permissions.isNotEmpty) {
      return incoming;
    }
    if (existing.permissions.isEmpty) {
      return incoming;
    }
    // Краткая роль из события не несёт permissions — оставляем существующие,
    // чтобы effectivePermissions не проседал до успешного refresh.
    return AppRole(
      id: incoming.id,
      name: incoming.name,
      color: incoming.color,
      position: incoming.position,
      permissions: existing.permissions,
    );
  }

  // Пересинхронизация после role:new / role:update: источник истины для
  // прав — backend. Полные роли (с permissions) даёт getServerRoles,
  // актуальные назначения — getServerMembers. Заменяем локальные списки
  // целиком, без дубликатов. Ошибки API перехватываются здесь, чтобы
  // unawaited не превратил их в unhandled future, а существующая полная
  // роль не потеряла permissions при неудачном refresh.
  Future<void> _refreshServerRolesAndMembers(String serverId) async {
    try {
      final latestRoles = await apiClient.getServerRoles(serverId);
      final latestMembers = await apiClient.getServerMembers(serverId);

      if (!mounted || serverId != selectedServerId) {
        return;
      }

      setState(() {
        serverRoles = latestRoles;
        members = latestMembers;
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;
      if (!mounted || serverId != selectedServerId) return;

      showErrorSnackBar(
        context,
        'Не удалось обновить роли: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted || serverId != selectedServerId) return;

      showErrorSnackBar(context, 'Не удалось обновить роли: ${describeRequestError(error)}');
    }
  }

  void handleRealtimeRoleDelete(RealtimeRoleDelete event) {
    if (!mounted || event.serverId != selectedServerId) {
      return;
    }

    setState(() {
      serverRoles = serverRoles
          .where((role) => role.id != event.roleId)
          .toList();

      members = members
          .map<AppServerMember>(
            (member) => member.roles.any((role) => role.id == event.roleId)
                ? member.copyWith(
                    roles: member.roles
                        .where((role) => role.id != event.roleId)
                        .toList(),
                  )
                : member,
          )
          .toList();
    });
  }

  void handleRealtimeMemberRolesUpdate(RealtimeMemberRolesUpdate event) {
    if (!mounted || event.serverId != selectedServerId) {
      return;
    }

    setState(() {
      members = members
          .map<AppServerMember>(
            (member) => member.id == event.memberId
                ? member.copyWith(roles: event.roles)
                : member,
          )
          .toList();
    });
  }

  void handleRealtimeUserStatus(RealtimeUserStatus event) {
    if (!mounted) {
      return;
    }

    setState(() {
      if (currentUser?.id == event.userId) {
        currentUser = currentUser?.copyWith(status: event.status);
      }

      members = members
          .map<AppServerMember>(
            (member) => member.userId == event.userId
                ? member.copyWith(
                    user: member.user.copyWith(status: event.status),
                  )
                : member,
          )
          .toList();
    });
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

  // Владелец сервера всегда получает полный доступ (см. PermissionsService
  // на бэкенде). У обычного участника права — это объединение permissions
  // всех назначенных ему ролей: member.roles из /members содержит только
  // id/name/color/position, поэтому реальные флаги берём из serverRoles
  // (полный список ролей сервера с правами) по совпадению id.
  AppPermissions get effectivePermissions {
    if (isSelectedServerOwner) {
      return AppPermissions.owner;
    }

    final userId = currentUser?.id;

    if (userId == null) {
      return AppPermissions.none;
    }

    final member = members.cast<AppServerMember?>().firstWhere(
      (item) => item?.userId == userId,
      orElse: () => null,
    );

    if (member == null) {
      return AppPermissions.none;
    }

    final assignedRoleIds = member.roles.map((role) => role.id).toSet();
    final matchedRoles = serverRoles.where(
      (role) => assignedRoleIds.contains(role.id),
    );

    return AppPermissions.fromRoles(matchedRoles);
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

  // Фиксирует успешно загруженную через REST страницу как baseline канала.
  void _confirmLoadedBaseline(AppChannel? channel, List<AppMessage> loaded) {
    _messageSync.resetForChannel(channel?.id);
    if (channel != null && channel.type == ChannelType.text) {
      _messageSync.confirmBaseline(channel.id, loaded);
    }
  }

  // Вход в комнату после REST-загрузки. Докачка от baseline запустится по
  // ack входа (onReconnected). Если комната уже была выбрана ранее,
  // syncRealtimeChannel повторно не входит — синхронизируем сразу.
  // Иначе выполняем pending-запрос, отложенный на время загрузки.
  void _syncRealtimeChannelAfterBaseline(AppChannel? channel) {
    // Без активной identified-сессии комната не подтверждена: синхронизация
    // запустится по ack из identifyAndRejoin после переподключения.
    final alreadyJoined =
        channel != null &&
        channel.type == ChannelType.text &&
        realtimeChannelId == channel.id &&
        realtimeClient.isIdentified;
    syncRealtimeChannel(channel);
    if (alreadyJoined) {
      unawaited(_messageSync.onRoomJoined(channel.id));
    } else {
      unawaited(_messageSync.flushPending());
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
      final loadedRoles = firstServerId != null
          ? await apiClient.getServerRoles(firstServerId)
          : <AppRole>[];

      final firstChannel = loadedChannels.isNotEmpty
          ? loadedChannels.first
          : null;

      final loadedMessages =
          firstChannel != null && firstChannel.type == ChannelType.text
          ? await apiClient.getMessages(firstChannel.id)
          : <AppMessage>[];
      final currentMember = loadedMembers.cast<AppServerMember?>().firstWhere(
        (member) => member?.userId == me.id,
        orElse: () => null,
      );

      setState(() {
        currentUser = currentMember?.user ?? me;
        servers = loadedServers;
        selectedServerId = firstServerId;
        channels = loadedChannels;
        members = loadedMembers;
        serverRoles = loadedRoles;
        selectedChannelId = firstChannel?.id;
        messages = mergeMessagesChronologically(messages, loadedMessages);
        hasMoreMessages = loadedMessages.length >= 50;
        isLoading = false;
      });
      _confirmLoadedBaseline(firstChannel, loadedMessages);
      _scrollMessagesToBottom();
      syncRealtimeServer(firstServerId);
      _syncRealtimeChannelAfterBaseline(firstChannel);
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;
      setState(() {
        errorMessage = 'Ошибка загрузки данных: ${describeRequestError(error)}';
        isLoading = false;
      });
    } catch (error) {
      setState(() {
        errorMessage = 'Не удалось загрузить данные приложения: ${describeRequestError(error)}';
        isLoading = false;
      });
    }
  }

  Future<void> selectServer(String serverId) async {
    setState(() {
      selectedServerId = serverId;
      channels = [];
      members = [];
      serverRoles = [];
      selectedChannelId = null;
      messages = [];
      isLoading = true;
      errorMessage = null;
    });
    _messageSync.resetForChannel(null);

    try {
      final loadedChannels = await apiClient.getChannels(serverId);
      final loadedMembers = await apiClient.getServerMembers(serverId);
      final loadedRoles = await apiClient.getServerRoles(serverId);
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
        serverRoles = loadedRoles;
        selectedChannelId = firstChannel?.id;
        messages = loadedMessages;
        hasMoreMessages = loadedMessages.length >= 50;
        isLoading = false;
      });
      _confirmLoadedBaseline(firstChannel, loadedMessages);
      _scrollMessagesToBottom();
      syncRealtimeServer(serverId);
      _syncRealtimeChannelAfterBaseline(firstChannel);
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;
      final statusCode = error.response?.statusCode;

      if (statusCode == 403 || statusCode == 404) {
        await selectNextServerAfterRemoving(serverId);

        if (!mounted) return;

        showErrorSnackBar(context, 'Вы больше не состоите на этом сервере');

        return;
      }

      if (!mounted) return;

      setState(() {
        errorMessage = 'Ошибка загрузки каналов: ${describeRequestError(error)}';
        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        errorMessage = 'Не удалось загрузить каналы: ${describeRequestError(error)}';
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
      hasMoreMessages = false;
      errorMessage = null;
      messagesError = null;
    });
    _messageSync.resetForChannel(
      channelId,
      baselineLoading: channel.type == ChannelType.text,
    );

    if (channel.type == ChannelType.voice) {
      setState(() {
        isMessagesLoading = false;
      });
      syncRealtimeChannel(null);
      return;
    }

    try {
      const pageSize = 50;
      final loadedMessages = await apiClient.getMessages(
        channel.id,
        limit: pageSize,
      );

      // Пользователь мог успеть выбрать другой канал, пока шёл запрос —
      // тогда этот ответ устарел и не должен перетирать уже открытый канал.
      if (!mounted || selectedChannelId != channelId) return;

      setState(() {
        messages = loadedMessages;
        hasMoreMessages = loadedMessages.length >= pageSize;
        isMessagesLoading = false;
        messagesError = null;
      });
      _messageSync.confirmBaseline(channelId, loadedMessages);
      _scrollMessagesToBottom();
      // Реконнект мог прийти во время этой первоначальной загрузки и быть
      // отложен — он выполнится здесь же, а не при случайном следующем.
      _syncRealtimeChannelAfterBaseline(channel);
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted || selectedChannelId != channelId) return;

      setState(() {
        messagesError = 'Ошибка загрузки сообщений: ${describeRequestError(error)}';
        isMessagesLoading = false;
      });
      // Baseline остаётся неизвестным; отложенный запрос не должен висеть.
      _messageSync.abortBaseline(channelId);
      _syncRealtimeChannelAfterBaseline(channel);
    } catch (error) {
      if (!mounted || selectedChannelId != channelId) return;

      setState(() {
        messagesError = 'Не удалось загрузить сообщения: ${describeRequestError(error)}';
        isMessagesLoading = false;
      });
      _messageSync.abortBaseline(channelId);
      _syncRealtimeChannelAfterBaseline(channel);
    }
  }

  Future<void> loadMoreMessages() async {
    final channelId = selectedChannelId;

    if (channelId == null ||
        messages.isEmpty ||
        isLoadingMoreMessages ||
        !hasMoreMessages) {
      return;
    }

    setState(() {
      isLoadingMoreMessages = true;
    });

    try {
      const pageSize = 50;
      final olderMessages = await apiClient.getMessages(
        channelId,
        limit: pageSize,
        before: messages.first.id,
      );

      // Пользователь мог переключить канал, пока грузились старые сообщения —
      // тогда эта страница относится к уже неактуальному каналу.
      if (!mounted || selectedChannelId != channelId) return;

      // Запоминаем текущую позицию и высоту прокрутки до того, как в начало
      // списка добавятся старые сообщения, чтобы после перестройки списка
      // восстановить ту же видимую точку и не "прыгать" к низу.
      final hasScrollPosition = messagesScrollController.hasClients;
      final previousPixels = hasScrollPosition
          ? messagesScrollController.position.pixels
          : 0.0;
      final previousMaxScrollExtent = hasScrollPosition
          ? messagesScrollController.position.maxScrollExtent
          : 0.0;

      setState(() {
        // Merge вместо склейки: страница могла уже прийти докачкой назад.
        messages = mergeMessagesChronologically(messages, olderMessages);
        hasMoreMessages = olderMessages.length >= pageSize;
        isLoadingMoreMessages = false;
      });

      if (hasScrollPosition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !messagesScrollController.hasClients) return;

          final addedExtent =
              messagesScrollController.position.maxScrollExtent -
              previousMaxScrollExtent;

          messagesScrollController.jumpTo(previousPixels + addedExtent);
        });
      }
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted || selectedChannelId != channelId) return;

      setState(() {
        isLoadingMoreMessages = false;
      });

      showErrorSnackBar(
        context,
        'Не удалось загрузить более старые сообщения: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted || selectedChannelId != channelId) return;

      setState(() {
        isLoadingMoreMessages = false;
      });

      showErrorSnackBar(
        context,
        'Не удалось загрузить более старые сообщения: ${describeRequestError(error)}',
      );
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка загрузки участников: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось загрузить участников: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления участника: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить участника: ${describeRequestError(error)}');
    }
  }

  Future<void> banMember(AppServerMember member) async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Забанить участника?',
      message:
          'Пользователь "${member.user.username}" будет удалён с сервера и не сможет вернуться по инвайт-ссылке.',
      confirmText: 'Забанить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.banServerMember(
        serverId: serverId,
        userId: member.userId,
      );

      if (!mounted) return;

      setState(() {
        members = members.where((item) => item.id != member.id).toList();
      });

      showErrorSnackBar(context, 'Пользователь забанен на сервере');
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка бана участника: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось забанить участника: ${describeRequestError(error)}');
    }
  }

  Future<void> showBans() async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    try {
      final bans = await apiClient.getServerBans(serverId);

      if (!mounted) return;

      await showServerBansDialog(
        context: context,
        bans: bans,
        onUnban: (ban) => unbanMember(serverId, ban),
      );
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка загрузки списка банов: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось загрузить список банов: ${describeRequestError(error)}');
    }
  }

  Future<bool> unbanMember(String serverId, AppServerBan ban) async {
    try {
      await apiClient.unbanServerMember(serverId: serverId, userId: ban.userId);

      if (mounted) {
        showErrorSnackBar(
          context,
          'Пользователь "${ban.user.username}" разбанен',
        );
      }

      return true;
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return false;

      if (mounted) {
        showErrorSnackBar(context, 'Ошибка разбана: ${describeRequestError(error)}');
      }

      return false;
    } catch (error) {
      if (mounted) {
        showErrorSnackBar(context, 'Не удалось разбанить участника: ${describeRequestError(error)}');
      }

      return false;
    }
  }

  Future<void> manageServerRoles() async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    final canManageRoles = effectivePermissions.manageRoles;

    await showManageRolesDialog(
      context: context,
      roles: serverRoles,
      canManageRoles: canManageRoles,
      onCreateRole: () => createRoleFlow(serverId),
      onEditRole: (role) => editRoleFlow(role),
      onDeleteRole: (role) => deleteServerRole(role),
    );
  }

  Future<void> createRoleFlow(String serverId) async {
    final result = await showRoleFormDialog(context: context);

    if (result == null) {
      return;
    }

    try {
      final role = await apiClient.createRole(
        serverId: serverId,
        name: result.name,
        color: result.color,
        permissions: result.permissions,
      );

      if (!mounted) return;

      setState(() {
        serverRoles = [...serverRoles, role];
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(context, 'Ошибка создания роли: ${describeRequestError(error)}');
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось создать роль: ${describeRequestError(error)}');
    }
  }

  Future<void> editRoleFlow(AppRole role) async {
    final result = await showRoleFormDialog(context: context, existing: role);

    if (result == null) {
      return;
    }

    try {
      final updated = await apiClient.updateRole(
        roleId: role.id,
        name: result.name,
        color: result.color,
        permissions: result.permissions,
      );

      if (!mounted) return;

      setState(() {
        serverRoles = serverRoles
            .map<AppRole>((item) => item.id == updated.id ? updated : item)
            .toList();
        members = members
            .map<AppServerMember>(
              (member) => member.roles.any((item) => item.id == updated.id)
                  ? member.copyWith(
                      roles: member.roles
                          .map<AppRole>(
                            (item) =>
                                item.id == updated.id ? updated : item,
                          )
                          .toList(),
                    )
                  : member,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(context, 'Ошибка изменения роли: ${describeRequestError(error)}');
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось изменить роль: ${describeRequestError(error)}');
    }
  }

  Future<void> deleteServerRole(AppRole role) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить роль?',
      message: 'Роль "${role.name}" будет снята со всех участников.',
      confirmText: 'Удалить',
    );

    if (confirmed != true) {
      return;
    }

    try {
      await apiClient.deleteRole(roleId: role.id);

      if (!mounted) return;

      setState(() {
        serverRoles = serverRoles.where((item) => item.id != role.id).toList();
        members = members
            .map<AppServerMember>(
              (member) => member.roles.any((item) => item.id == role.id)
                  ? member.copyWith(
                      roles: member.roles
                          .where((item) => item.id != role.id)
                          .toList(),
                    )
                  : member,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(context, 'Ошибка удаления роли: ${describeRequestError(error)}');
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить роль: ${describeRequestError(error)}');
    }
  }

  Future<void> manageMemberRoles(AppServerMember member) async {
    await showMemberRolesDialog(
      context: context,
      member: member,
      roles: serverRoles,
      onToggle: (role, assign) =>
          toggleMemberRole(member: member, role: role, assign: assign),
    );
  }

  Future<void> toggleMemberRole({
    required AppServerMember member,
    required AppRole role,
    required bool assign,
  }) async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    try {
      if (assign) {
        await apiClient.assignRole(
          serverId: serverId,
          memberId: member.id,
          roleId: role.id,
        );
      } else {
        await apiClient.unassignRole(
          serverId: serverId,
          memberId: member.id,
          roleId: role.id,
        );
      }

      if (!mounted) return;

      setState(() {
        members = members
            .map<AppServerMember>(
              (item) => item.id == member.id
                  ? item.copyWith(
                      roles: assign
                          ? (item.roles.any((r) => r.id == role.id)
                                ? item.roles
                                : [...item.roles, role])
                          : item.roles
                                .where((r) => r.id != role.id)
                                .toList(),
                    )
                  : item,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        assign
            ? 'Ошибка назначения роли: ${describeRequestError(error)}'
            : 'Ошибка снятия роли: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        assign ? 'Не удалось назначить роль: ${describeRequestError(error)}' : 'Не удалось снять роль: ${describeRequestError(error)}',
      );
    }
  }

  // Возвращает true, если сообщение подтверждено backend и добавлено в
  // messages, и false при любой ошибке (уже показанной пользователю здесь же
  // через describeRequestError) — вызывающий код (MessageInput) решает, можно
  // ли очищать поле ввода. Повторная попытка использует тот же clientMessageId.
  Future<bool> sendMessage(String content, String clientMessageId) async {
    final channelId = selectedChannelId;

    if (channelId == null) {
      return false;
    }

    try {
      final sentMessage = await apiClient.sendMessage(
        channelId: channelId,
        content: content,
        clientMessageId: clientMessageId,
      );

      if (!mounted || selectedChannelId != channelId) return true;

      setState(() {
        // Merge по id и (createdAt, id): то же сообщение могло уже прийти
        // через message:new, а чужое live-сообщение — раньше HTTP-ответа.
        messages = mergeMessagesChronologically(messages, [sentMessage]);
      });

      return true;
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return false;

      if (!mounted) return false;

      showErrorSnackBar(
        context,
        'Ошибка отправки сообщения: ${describeRequestError(error)}',
      );

      return false;
    } catch (error) {
      if (!mounted) return false;

      showErrorSnackBar(context, 'Не удалось отправить сообщение: ${describeRequestError(error)}');

      return false;
    }
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка редактирования сообщения: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Не удалось отредактировать сообщение: ${describeRequestError(error)}',
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления сообщения: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить сообщение: ${describeRequestError(error)}');
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
      // Сообщения не загружались: baseline неизвестен, после входа в комнату
      // контроллер восстановит последнюю страницу без курсора.
      _messageSync.resetForChannel(selectedChannelId);
      syncRealtimeServer(server.id);
      syncRealtimeChannel(
        loadedChannels.isNotEmpty ? loadedChannels.first : null,
      );
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(
        context,
        'Ошибка создания сервера: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(context, 'Не удалось создать сервер: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка переименования сервера: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось переименовать сервер: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления сервера: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить сервер: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка выхода с сервера: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось выйти с сервера: ${describeRequestError(error)}');
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
        hasMoreMessages = loadedMessages.length >= 50;
        isLoading = false;
      });
      _confirmLoadedBaseline(firstChannel, loadedMessages);
      _scrollMessagesToBottom();
      syncRealtimeServer(server.id);
      _syncRealtimeChannelAfterBaseline(firstChannel);
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(
        context,
        'Ошибка вступления на сервер: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      showErrorSnackBar(context, 'Не удалось вступить на сервер: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка создания приглашения: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось создать приглашение: ${describeRequestError(error)}');
    }
  }

  Future<void> createChannel({
    ChannelType initialType = ChannelType.text,
  }) async {
    final serverId = selectedServerId;

    if (serverId == null) {
      return;
    }

    final result = await showCreateChannelDialog(
      context: context,
      initialType: initialType,
    );

    if (result == null) {
      return;
    }

    final channelName = result.name.trim();

    if (channelName.length < 2) {
      showErrorSnackBar(
        context,
        'Название канала должно быть не короче 2 символов',
      );
      return;
    }

    try {
      final channel = await apiClient.createChannel(
        serverId: serverId,
        name: channelName,
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

      await selectChannel(channel.id);
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка создания канала: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось создать канал: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка обновления профиля: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось обновить профиль: ${describeRequestError(error)}');
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

    if (newName == null) {
      return;
    }

    final channelName = newName.trim();

    if (channelName.length < 2) {
      showErrorSnackBar(
        context,
        'Название канала должно быть не короче 2 символов',
      );
      return;
    }

    try {
      final updatedChannel = await apiClient.updateChannel(
        channelId: channel.id,
        name: channelName,
      );

      setState(() {
        channels = channels
            .map<AppChannel>(
              (item) => item.id == updatedChannel.id ? updatedChannel : item,
            )
            .toList();
      });
    } on DioException catch (error) {
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка переименования канала: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось переименовать канал: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка удаления канала: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось удалить канал: ${describeRequestError(error)}');
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
      if (handleUnauthorized(error)) return;

      if (!mounted) return;

      showErrorSnackBar(
        context,
        'Ошибка изменения прав канала: ${describeRequestError(error)}',
      );
    } catch (error) {
      if (!mounted) return;

      showErrorSnackBar(context, 'Не удалось изменить права канала: ${describeRequestError(error)}');
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
    final permissions = effectivePermissions;
    final canManageChannels = permissions.manageChannels;
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
            canManageServer: permissions.manageServer,
            canManageRoles: permissions.manageRoles,
            onChannelSelected: selectChannel,
            onCreateChannel: createChannel,
            onEditChannel: renameChannel,
            onDeleteChannel: deleteChannel,
            onEditChannelPermissions: editChannelPermissions,
            onCreateInvite: createInvite,
            onManageRoles: selectedServer == null ? null : manageServerRoles,
            onRenameServer: selectedServer == null
                ? null
                : () => renameServer(selectedServer),
            onDeleteServer: selectedServer == null
                ? null
                : () => deleteServer(selectedServer),
            onLeaveServer: selectedServer == null
                ? null
                : () => leaveServer(selectedServer),
            onEditProfile: editProfile,
            onLogout: logout,
          ),
          Expanded(
            child: selectedChannel == null
                ? EmptyChatPlaceholder(
                    hasSelectedServer: selectedServer != null,
                    canCreateChannel:
                        selectedServer != null && canManageChannels,
                    onCreateTextChannel: () =>
                        createChannel(initialType: ChannelType.text),
                    onCreateVoiceChannel: () =>
                        createChannel(initialType: ChannelType.voice),
                  )
                : ChatArea(
                    channel: selectedChannel,
                    messages: messages,
                    isMessagesLoading: isMessagesLoading,
                    messagesError: messagesError,
                    hasMoreMessages: hasMoreMessages,
                    isLoadingMoreMessages: isLoadingMoreMessages,
                    canSendMessages: canSendMessages,
                    messagesScrollController: messagesScrollController,
                    onSendMessage: sendMessage,
                    onEditMessage: editMessage,
                    onDeleteMessage: deleteMessage,
                    onShowMembers: showMembers,
                    onLoadMoreMessages: loadMoreMessages,
                    onRetryMessages: () => selectChannel(selectedChannel.id),
                  ),
          ),
          if (selectedServer != null)
            MembersSidebar(
              members: members,
              currentUserId: user.id,
              canKickMembers: permissions.manageMembers,
              canBanMembers: permissions.manageBans,
              canManageRoles: permissions.manageRoles,
              onKickMember: kickMember,
              onBanMember: banMember,
              onManageMemberRoles: manageMemberRoles,
              onShowBans: showBans,
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
              separatorBuilder: (_, _) => const SizedBox(height: 10),
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
            color: const Color(0xFF8D5CFF).withValues(alpha: 0.35),
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
    required this.canManageRoles,
    required this.onChannelSelected,
    required this.onCreateChannel,
    required this.onEditChannel,
    required this.onDeleteChannel,
    required this.onEditChannelPermissions,
    required this.onCreateInvite,
    this.onManageRoles,
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
  final bool canManageRoles;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final ValueChanged<AppChannel> onEditChannel;
  final ValueChanged<AppChannel> onDeleteChannel;
  final ValueChanged<AppChannel> onEditChannelPermissions;
  final VoidCallback onCreateInvite;
  final VoidCallback? onManageRoles;
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
            canManageRoles: canManageRoles,
            canCreateInvite: canManageChannels,
            onCreateInvite: onCreateInvite,
            onManageRoles: onManageRoles,
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
    required this.canManageRoles,
    required this.canCreateInvite,
    required this.onCreateInvite,
    this.onManageRoles,
    required this.onRenameServer,
    required this.onDeleteServer,
    required this.onLeaveServer,
  });

  final String serverName;
  final bool hasSelectedServer;
  final bool canManageServer;
  final bool canManageRoles;
  final bool canCreateInvite;
  final VoidCallback onCreateInvite;
  final VoidCallback? onManageRoles;
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
                case 'roles':
                  onManageRoles?.call();
                  break;
                case 'leave':
                  onLeaveServer?.call();
                  break;
              }
            },
            itemBuilder: (context) {
              if (canManageServer || canManageRoles) {
                return [
                  if (canManageServer)
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text(
                        'Переименовать сервер',
                        style: TextStyle(color: Color(0xFFF3EEFF)),
                      ),
                    ),
                  if (canManageRoles)
                    const PopupMenuItem(
                      value: 'roles',
                      child: Text(
                        'Роли сервера',
                        style: TextStyle(color: Color(0xFFF3EEFF)),
                      ),
                    ),
                  if (canManageServer)
                    const PopupMenuItem(
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
    final statusColor = switch (user.status) {
      'ONLINE' => const Color(0xFF35D07F),
      'AWAY' => const Color(0xFFFFC66D),
      'DO_NOT_DISTURB' => const Color(0xFFFF5C7A),
      _ => const Color(0xFF6F657C),
    };

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
                    color: statusColor,
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
  const EmptyChatPlaceholder({
    super.key,
    required this.hasSelectedServer,
    required this.canCreateChannel,
    required this.onCreateTextChannel,
    required this.onCreateVoiceChannel,
  });

  final bool hasSelectedServer;
  final bool canCreateChannel;
  final VoidCallback onCreateTextChannel;
  final VoidCallback onCreateVoiceChannel;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF211C29),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                hasSelectedServer
                    ? Icons.forum_outlined
                    : Icons.add_circle_outline_rounded,
                color: const Color(0xFF8D5CFF),
                size: 42,
              ),
              const SizedBox(height: 16),
              Text(
                hasSelectedServer
                    ? 'На этом сервере пока нет каналов'
                    : 'Выберите или создайте сервер',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFF3EEFF),
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                hasSelectedServer
                    ? canCreateChannel
                          ? 'Создайте первый текстовый или голосовой канал.'
                          : 'Попросите владельца сервера создать канал.'
                    : 'Серверы появятся в левой панели.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF8F849F),
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (hasSelectedServer && canCreateChannel) ...[
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: onCreateTextChannel,
                      icon: const Icon(Icons.tag_rounded, size: 18),
                      label: const Text('Текстовый'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8D5CFF),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onCreateVoiceChannel,
                      icon: const Icon(Icons.volume_up_rounded, size: 18),
                      label: const Text('Голосовой'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFBFA7FF),
                        side: const BorderSide(color: Color(0xFF40374D)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
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
    required this.messagesError,
    required this.hasMoreMessages,
    required this.isLoadingMoreMessages,
    required this.canSendMessages,
    required this.messagesScrollController,
    required this.onSendMessage,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.onShowMembers,
    required this.onLoadMoreMessages,
    required this.onRetryMessages,
  });

  final AppChannel channel;
  final List<AppMessage> messages;
  final bool isMessagesLoading;
  final String? messagesError;
  final bool hasMoreMessages;
  final bool isLoadingMoreMessages;
  final bool canSendMessages;
  final ScrollController messagesScrollController;
  final Future<bool> Function(String content, String clientMessageId)
  onSendMessage;
  final ValueChanged<AppMessage> onEditMessage;
  final ValueChanged<AppMessage> onDeleteMessage;
  final VoidCallback onShowMembers;
  final VoidCallback onLoadMoreMessages;
  final VoidCallback onRetryMessages;

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
                      : messagesError != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                messagesError!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Color(0xFFFF7A7A),
                                ),
                              ),
                              TextButton(
                                onPressed: onRetryMessages,
                                child: const Text('Повторить загрузку'),
                              ),
                            ],
                          ),
                        )
                      : MessagesList(
                          messages: messages,
                          hasMoreMessages: hasMoreMessages,
                          isLoadingMoreMessages: isLoadingMoreMessages,
                          scrollController: messagesScrollController,
                          onEditMessage: onEditMessage,
                          onDeleteMessage: onDeleteMessage,
                          onLoadMoreMessages: onLoadMoreMessages,
                        )
                : const VoiceChannelPlaceholder(),
          ),
          if (channel.type == ChannelType.text)
            MessageInput(
              channelId: channel.id,
              channelName: channel.name,
              canSendMessages: canSendMessages && messagesError == null,
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
    required this.canKickMembers,
    required this.canBanMembers,
    required this.canManageRoles,
    required this.onKickMember,
    required this.onBanMember,
    required this.onManageMemberRoles,
    required this.onShowBans,
    required this.onRefresh,
  });

  final List<AppServerMember> members;
  final String currentUserId;
  final bool canKickMembers;
  final bool canBanMembers;
  final bool canManageRoles;
  final ValueChanged<AppServerMember> onKickMember;
  final ValueChanged<AppServerMember> onBanMember;
  final ValueChanged<AppServerMember> onManageMemberRoles;
  final VoidCallback onShowBans;
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
                if (canBanMembers)
                  IconButton(
                    tooltip: 'Забаненные',
                    onPressed: onShowBans,
                    icon: const Icon(Icons.block_rounded),
                    color: const Color(0xFFB8ADC8),
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
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final member = members[index];
                      final user = member.user;
                      final letter = user.username.isNotEmpty
                          ? user.username.characters.first.toUpperCase()
                          : '?';
                      final isSelf = member.userId == currentUserId;
                      final canKick =
                          canKickMembers && !isSelf && member.id.isNotEmpty;
                      final canBan =
                          canBanMembers && !isSelf && member.id.isNotEmpty;

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                if (member.roles.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      for (final role in member.roles)
                                        RoleChip(role: role),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (canManageRoles)
                            IconButton(
                              tooltip: 'Роли участника',
                              onPressed: () => onManageMemberRoles(member),
                              icon: const Icon(Icons.shield_outlined),
                              color: const Color(0xFFB8ADC8),
                            ),
                          if (canKick)
                            IconButton(
                              tooltip: 'Удалить участника',
                              onPressed: () => onKickMember(member),
                              icon: const Icon(Icons.person_remove_outlined),
                              color: const Color(0xFFFF7A7A),
                            ),
                          if (canBan)
                            IconButton(
                              tooltip: 'Забанить участника',
                              onPressed: () => onBanMember(member),
                              icon: const Icon(Icons.block_rounded),
                              color: const Color(0xFFFF3B3B),
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

class RoleChip extends StatelessWidget {
  const RoleChip({super.key, required this.role});

  final AppRole role;

  @override
  Widget build(BuildContext context) {
    final color = parseHexColor(role.color) ?? const Color(0xFF8D5CFF);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Text(
        role.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class MessagesList extends StatelessWidget {
  const MessagesList({
    super.key,
    required this.messages,
    required this.hasMoreMessages,
    required this.isLoadingMoreMessages,
    required this.scrollController,
    required this.onEditMessage,
    required this.onDeleteMessage,
    required this.onLoadMoreMessages,
  });

  final List<AppMessage> messages;
  final bool hasMoreMessages;
  final bool isLoadingMoreMessages;
  final ScrollController scrollController;
  final ValueChanged<AppMessage> onEditMessage;
  final ValueChanged<AppMessage> onDeleteMessage;
  final VoidCallback onLoadMoreMessages;

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

    final itemCount = messages.length + (hasMoreMessages ? 1 : 0);

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (hasMoreMessages && index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Center(
              child: isLoadingMoreMessages
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF8D5CFF),
                      ),
                    )
                  : TextButton(
                      onPressed: onLoadMoreMessages,
                      child: const Text(
                        'Загрузить более старые сообщения',
                        style: TextStyle(
                          color: Color(0xFF8D5CFF),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
            ),
          );
        }

        final message = messages[index - (hasMoreMessages ? 1 : 0)];

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

String _newClientMessageId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class _MessageDraft {
  const _MessageDraft(
    this.text,
    this.pendingContent,
    this.pendingClientMessageId,
  );

  final String text;
  final String? pendingContent;
  final String? pendingClientMessageId;
}

class MessageInput extends StatefulWidget {
  const MessageInput({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.canSendMessages,
    required this.onSendMessage,
  });

  final String channelId;
  final String channelName;
  final bool canSendMessages;
  final Future<bool> Function(String content, String clientMessageId)
  onSendMessage;

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final TextEditingController controller = TextEditingController();
  bool isSending = false;
  String? pendingContent;
  String? pendingClientMessageId;
  final Map<String, _MessageDraft> draftsByChannel = {};

  @override
  void didUpdateWidget(covariant MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId) {
      draftsByChannel[oldWidget.channelId] = _MessageDraft(
        controller.text,
        pendingContent,
        pendingClientMessageId,
      );
      final draft = draftsByChannel[widget.channelId];
      controller.text = draft?.text ?? '';
      pendingContent = draft?.pendingContent;
      pendingClientMessageId = draft?.pendingClientMessageId;
    }
  }

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

    final channelId = widget.channelId;
    if (pendingContent != text || pendingClientMessageId == null) {
      pendingContent = text;
      pendingClientMessageId = _newClientMessageId();
    }
    final clientMessageId = pendingClientMessageId!;

    setState(() {
      isSending = true;
    });

    try {
      // sendMessage сам показывает snackbar при ошибке и не бросает
      // исключения — здесь только решаем, очищать ли поле ввода.
      final sent = await widget.onSendMessage(text, clientMessageId);

      if (sent &&
          mounted &&
          widget.channelId == channelId &&
          controller.text.trim() == text) {
        controller.clear();
        pendingContent = null;
        pendingClientMessageId = null;
        draftsByChannel.remove(channelId);
      } else if (sent && widget.channelId != channelId) {
        draftsByChannel.remove(channelId);
      }
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
  final inviteUrl = '$apiBaseUrl/invites/${invite.code}';

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
  ChannelType initialType = ChannelType.text,
}) {
  final controller = TextEditingController();
  ChannelType selectedType = initialType;

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

                      if (!value) {
                        canSendMessages = false;
                        canConnect = false;
                      }
                    });
                  },
                ),
                if (channel.type == ChannelType.text)
                  PermissionSwitchTile(
                    title: 'Писать сообщения',
                    subtitle:
                        'Для текстовых каналов: можно отправлять сообщения.',
                    value: canSendMessages,
                    enabled: canView,
                    onChanged: (value) {
                      if (!canView) {
                        return;
                      }

                      setDialogState(() {
                        canSendMessages = value;
                      });
                    },
                  ),
                if (channel.type == ChannelType.voice)
                  PermissionSwitchTile(
                    title: 'Подключаться',
                    subtitle:
                        'Для голосовых каналов: можно подключаться к каналу.',
                    value: canConnect,
                    enabled: canView,
                    onChanged: (value) {
                      if (!canView) {
                        return;
                      }

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
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: enabled ? onChanged : null,
      activeThumbColor: const Color(0xFF8D5CFF),
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? const Color(0xFFF3EEFF) : const Color(0xFF6F657C),
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: enabled ? const Color(0xFF8F849F) : const Color(0xFF5F566B),
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
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
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

Future<void> showServerBansDialog({
  required BuildContext context,
  required List<AppServerBan> bans,
  required Future<bool> Function(AppServerBan ban) onUnban,
}) {
  final mutableBans = List<AppServerBan>.of(bans);

  return showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: 'Забаненные участники',
            child: SizedBox(
              width: 420,
              height: 420,
              child: mutableBans.isEmpty
                  ? const Center(
                      child: Text(
                        'Забаненных пока нет',
                        style: TextStyle(
                          color: Color(0xFFB8ADC8),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: mutableBans.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final ban = mutableBans[index];
                        final user = ban.user;
                        final letter = user.username.isNotEmpty
                            ? user.username.characters.first.toUpperCase()
                            : '?';

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
                                      ban.reason?.isNotEmpty == true
                                          ? ban.reason!
                                          : 'Причина не указана',
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
                              IconButton(
                                tooltip: 'Разбанить',
                                onPressed: () async {
                                  final success = await onUnban(ban);

                                  if (success) {
                                    setDialogState(() {
                                      mutableBans.removeAt(index);
                                    });
                                  }
                                },
                                icon: const Icon(Icons.lock_open_rounded),
                                color: const Color(0xFF7ADE9C),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          );
        },
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

void showErrorSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), action: action),
  );
}

// Сливает текущий список сообщений канала с новыми (докачанными после
// реконнекта или пришедшими по live realtime-событию), убирает дубликаты по
// `id` и восстанавливает хронологический порядок по тому же критерию, что
// backend использует для курсора пагинации: сначала по `createdAt`, при
// равенстве — по `id`. Это чистая функция без побочных эффектов, вынесенная
// отдельно, чтобы её можно было покрыть unit-тестами без виджетов и сети.
List<AppMessage> mergeMessagesChronologically(
  List<AppMessage> current,
  Iterable<AppMessage> incoming,
) {
  final byId = <String, AppMessage>{};

  for (final message in current) {
    byId[message.id] = message;
  }
  for (final message in incoming) {
    byId[message.id] = message;
  }

  final merged = byId.values.toList()
    ..sort((a, b) {
      final aCreatedAt =
          a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bCreatedAt =
          b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final createdAtCompare = aCreatedAt.compareTo(bCreatedAt);
      if (createdAtCompare != 0) return createdAtCompare;
      return a.id.compareTo(b.id);
    });

  return merged;
}

// Результат применения одной докачанной страницы истории (вперёд или назад)
// к текущему списку сообщений канала: обновлённый (слитый и
// отсортированный через mergeMessagesChronologically) список, курсор для
// следующей страницы (null, если страница была пустой — курсор не
// продвигаем) и признак того, что страница была полной (== pageSize, значит,
// вероятно, есть ещё не загруженные сообщения и докачку нужно продолжать).
// Чистая функция без побочных эффектов и сети, поэтому тестируется без
// виджетов: вызывающий код сам отвечает за setState и обязан передавать
// актуальный [current] перед каждым вызовом, чтобы не потерять сообщение,
// пришедшее по realtime во время докачки (см. MessageSyncController).
class CatchUpPageStep {
  CatchUpPageStep({
    required this.messages,
    required this.nextCursor,
    required this.isFull,
  });

  final List<AppMessage> messages;
  final String? nextCursor;
  final bool isFull;
}

CatchUpPageStep applyCatchUpPage({
  required List<AppMessage> current,
  required List<AppMessage> page,
  required int pageSize,
}) {
  final isFull = page.length >= pageSize;

  if (page.isEmpty) {
    return CatchUpPageStep(
      messages: current,
      nextCursor: null,
      isFull: isFull,
    );
  }

  return CatchUpPageStep(
    messages: mergeMessagesChronologically(current, page),
    // Для курсора `before` следующая страница должна начинаться раньше
    // самого старого сообщения из уже полученных — это первый элемент
    // страницы, т.к. getMessages возвращает сообщения в хронологическом
    // порядке (см. backend-пагинацию и использование `before` в
    // loadMoreMessages).
    nextCursor: page.first.id,
    isFull: isFull,
  );
}

// Стратегия докачки после входа в комнату канала. Курсором `after` служит
// только подтверждённая точка непрерывной синхронизации — никогда не
// последнее отображённое (возможно, live) сообщение.
enum ReconnectSyncStrategy {
  // Baseline известен и непуст — докачка вперёд `after` подтверждённой точки.
  afterConfirmed,
  // Baseline неизвестен или подтверждённо пуст — последняя страница без
  // курсора и, если она полная, докачка назад по `before`.
  restoreLatest,
}

ReconnectSyncStrategy chooseReconnectSyncStrategy({
  required bool baselineKnown,
  required String? confirmedMessageId,
}) {
  return baselineKnown && confirmedMessageId != null
      ? ReconnectSyncStrategy.afterConfirmed
      : ReconnectSyncStrategy.restoreLatest;
}

typedef FetchMessagesPage =
    Future<List<AppMessage>> Function(
      String channelId, {
      required int limit,
      String? after,
      String? before,
    });

// Синхронизация истории выбранного канала с backend после (пере)входа в
// комнату Socket.IO. Хранит подтверждённую точку непрерывной синхронизации
// (confirmedMessageId): до неё история канала гарантированно без пробелов.
// Live-сообщения продвигают её только в состоянии inSync (комната подтверждена
// и докачка завершилась без обрыва). Чистый Dart без виджетов и сети —
// сеть и состояние UI передаются колбэками, поэтому класс тестируется напрямую.
class MessageSyncController {
  MessageSyncController({
    required this.fetch,
    required this.readMessages,
    required this.writeMessages,
    required this.isChannelActive,
    required this.onIncomplete,
    this.pageSize = 50,
    this.maxPages = 40,
    this.maxFlushRounds = 8,
  });

  final FetchMessagesPage fetch;
  final List<AppMessage> Function() readMessages;
  final void Function(List<AppMessage> messages, {bool? hasMore})
  writeMessages;
  // mounted && selectedChannelId == channelId
  final bool Function(String channelId) isChannelActive;
  // Неполная синхронизация (ошибка страницы / maxPages): UI показывает
  // «Повторить», retry продолжает с сохранённой точки под тем же guard'ом.
  final void Function(String channelId, Future<void> Function() retry)
  onIncomplete;
  final int pageSize;
  final int maxPages;
  final int maxFlushRounds;

  String? _channelId;
  bool _baselineKnown = false;
  bool _baselineLoading = false;
  String? _confirmed;
  // Незавершённая докачка назад после restoreLatest (продолжается в retry).
  String? _backwardCursor;
  bool _inSync = false;
  int _generation = 0;
  int _cycleCounter = 0;
  int? _activeCycle;
  String? _pending;

  String? get channelId => _channelId;
  bool get baselineKnown => _baselineKnown;
  bool get isBaselineLoading => _baselineLoading;
  String? get confirmedMessageId => _confirmed;
  bool get inSync => _inSync;
  bool get isRunning => _activeCycle != null;
  String? get pendingChannelId => _pending;

  // Смена канала/сервера: baseline неизвестен, текущий цикл (если был)
  // брошен — его результаты будут отброшены после ближайшего await.
  void resetForChannel(String? channelId, {bool baselineLoading = false}) {
    _channelId = channelId;
    _baselineKnown = false;
    _baselineLoading = channelId != null && baselineLoading;
    _confirmed = null;
    _backwardCursor = null;
    _inSync = false;
    _activeCycle = null;
    _pending = null;
  }

  // Успешная REST-загрузка последней страницы канала.
  void confirmBaseline(String channelId, List<AppMessage> restPage) {
    if (_channelId != channelId) resetForChannel(channelId);
    _baselineLoading = false;
    _baselineKnown = true;
    _confirmed = restPage.isEmpty ? null : restPage.last.id;
    _backwardCursor = null;
  }

  // REST-загрузка не удалась: baseline остаётся неизвестным, отложенная
  // синхронизация больше не ждёт загрузку (вызывающий делает flushPending).
  void abortBaseline(String channelId) {
    if (_channelId == channelId) _baselineLoading = false;
  }

  void onDisconnected() {
    _inSync = false;
    _generation++;
  }

  void onLiveMessage(AppMessage message) {
    if (_inSync && message.channelId == _channelId) {
      _confirmed = message.id;
    }
  }

  // Вход в комнату подтверждён ack: с этого момента live-события канала
  // доходят, поэтому докачка от подтверждённой точки закрывает пробел.
  Future<void> onRoomJoined(String channelId) async {
    if (!isChannelActive(channelId)) return;
    if (_channelId != channelId) resetForChannel(channelId);
    _pending = channelId;
    await flushPending();
  }

  // Выполняет отложенную синхронизацию, если ничего не занято. Число
  // раундов ограничено; оставшийся запрос не теряется молча — onIncomplete.
  Future<void> flushPending() async {
    for (var round = 0; round < maxFlushRounds; round++) {
      final channelId = _pending;
      if (channelId == null || isRunning || _baselineLoading) return;
      _pending = null;
      if (channelId != _channelId || !isChannelActive(channelId)) return;
      await _runCycle(channelId);
    }
    final leftover = _pending;
    if (leftover != null &&
        !isRunning &&
        !_baselineLoading &&
        leftover == _channelId &&
        isChannelActive(leftover)) {
      _pending = null;
      onIncomplete(leftover, () => _retry(leftover));
    }
  }

  Future<void> _retry(String channelId) async {
    if (channelId != _channelId || !isChannelActive(channelId)) return;
    _pending = channelId;
    await flushPending();
  }

  Future<void> _runCycle(String channelId) async {
    final cycle = ++_cycleCounter;
    _activeCycle = cycle;
    final generation = _generation;
    _inSync = false;
    bool alive() =>
        _activeCycle == cycle &&
        _channelId == channelId &&
        isChannelActive(channelId);

    var complete = false;
    try {
      complete = await _syncSteps(channelId, alive);
    } catch (_) {
      // Ошибка страницы: confirmed остаётся на последней успешной странице.
      complete = false;
    }

    if (_activeCycle != cycle) return; // цикл брошен resetForChannel
    _activeCycle = null;
    if (_channelId != channelId || !isChannelActive(channelId)) return;

    if (complete) {
      // Обрыв во время цикла: точка продвинута, но непрерывность после неё
      // не гарантирована — продолжит следующая (pending) синхронизация.
      if (generation == _generation) _inSync = true;
    } else {
      onIncomplete(channelId, () => _retry(channelId));
    }
  }

  Future<bool> _syncSteps(String channelId, bool Function() alive) async {
    switch (chooseReconnectSyncStrategy(
      baselineKnown: _baselineKnown,
      confirmedMessageId: _confirmed,
    )) {
      case ReconnectSyncStrategy.afterConfirmed:
        if (!await _syncForward(channelId, alive)) return false;
      case ReconnectSyncStrategy.restoreLatest:
        if (!await _restoreLatest(channelId, alive)) return false;
    }
    if (_backwardCursor != null) return _syncBackward(channelId, alive);
    return true;
  }

  // Вперёд от подтверждённой точки; каждая страница сливается с актуальным
  // списком (live-сообщения, пришедшие во время await, не теряются).
  Future<bool> _syncForward(String channelId, bool Function() alive) async {
    for (var page = 0; page < maxPages; page++) {
      final cursor = _confirmed;
      if (cursor == null) return false;
      final next = await fetch(channelId, limit: pageSize, after: cursor);
      if (!alive()) return false;
      if (next.isNotEmpty) {
        writeMessages(mergeMessagesChronologically(readMessages(), next));
        _confirmed = next.last.id;
      }
      if (next.length < pageSize) return true;
    }
    return false; // maxPages исчерпан при полной странице — не «успех»
  }

  Future<bool> _restoreLatest(String channelId, bool Function() alive) async {
    final latest = await fetch(channelId, limit: pageSize);
    if (!alive()) return false;
    final step = applyCatchUpPage(
      current: readMessages(),
      page: latest,
      pageSize: pageSize,
    );
    writeMessages(step.messages, hasMore: step.isFull);
    _baselineKnown = true;
    _confirmed = latest.isEmpty ? null : latest.last.id;
    _backwardCursor = step.isFull ? step.nextCursor : null;
    return true;
  }

  // Назад до начала истории; confirmed не меняет.
  Future<bool> _syncBackward(String channelId, bool Function() alive) async {
    for (var page = 0; page < maxPages; page++) {
      final cursor = _backwardCursor;
      if (cursor == null) return true;
      final previous = await fetch(
        channelId,
        limit: pageSize,
        before: cursor,
      );
      if (!alive()) return false;
      final step = applyCatchUpPage(
        current: readMessages(),
        page: previous,
        pageSize: pageSize,
      );
      writeMessages(step.messages, hasMore: step.isFull);
      if (!step.isFull) {
        _backwardCursor = null;
        return true;
      }
      _backwardCursor = step.nextCursor;
    }
    return false;
  }
}

Color? parseHexColor(String? hex) {
  if (hex == null || hex.isEmpty) {
    return null;
  }

  final normalized = hex.replaceFirst('#', '');
  final value = int.tryParse(
    normalized.length == 6 ? 'FF$normalized' : normalized,
    radix: 16,
  );

  return value == null ? null : Color(value);
}

const Map<String, String> rolePermissionLabels = {
  'manageServer': 'Управление сервером',
  'manageChannels': 'Управление каналами',
  'manageMembers': 'Управление участниками (кик)',
  'manageBans': 'Управление банами',
  'manageInvites': 'Управление приглашениями',
  'manageRoles': 'Управление ролями',
};

class RoleFormResult {
  const RoleFormResult({
    required this.name,
    required this.color,
    required this.permissions,
  });

  final String name;
  final String? color;
  final Map<String, bool> permissions;
}

Future<void> showManageRolesDialog({
  required BuildContext context,
  required List<AppRole> roles,
  required bool canManageRoles,
  required VoidCallback onCreateRole,
  required ValueChanged<AppRole> onEditRole,
  required ValueChanged<AppRole> onDeleteRole,
}) {
  final sortedRoles = [...roles]
    ..sort((left, right) => left.position.compareTo(right.position));

  return showDialog<void>(
    context: context,
    builder: (context) {
      return PlumsDialog(
        title: 'Роли сервера',
        child: SizedBox(
          width: 420,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (canManageRoles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(context);
                      onCreateRole();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Создать роль'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFBFA7FF),
                      side: const BorderSide(color: Color(0xFF40374D)),
                    ),
                  ),
                ),
              Expanded(
                child: sortedRoles.isEmpty
                    ? const Center(
                        child: Text(
                          'Ролей пока нет',
                          style: TextStyle(
                            color: Color(0xFFB8ADC8),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: sortedRoles.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final role = sortedRoles[index];
                          final color =
                              parseHexColor(role.color) ??
                              const Color(0xFF8D5CFF);

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
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    role.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Color(0xFFF3EEFF),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (canManageRoles) ...[
                                  IconButton(
                                    tooltip: 'Редактировать роль',
                                    onPressed: () {
                                      Navigator.pop(context);
                                      onEditRole(role);
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                    color: const Color(0xFFB8ADC8),
                                  ),
                                  IconButton(
                                    tooltip: 'Удалить роль',
                                    onPressed: () {
                                      Navigator.pop(context);
                                      onDeleteRole(role);
                                    },
                                    icon: const Icon(Icons.delete_outline),
                                    color: const Color(0xFFFF7A7A),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<RoleFormResult?> showRoleFormDialog({
  required BuildContext context,
  AppRole? existing,
}) {
  final nameController = TextEditingController(text: existing?.name ?? '');
  final colorController = TextEditingController(text: existing?.color ?? '');
  final permissions = <String, bool>{
    for (final key in rolePermissionLabels.keys) key: existing?.has(key) ?? false,
  };

  const fieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
    borderSide: BorderSide(color: Color(0xFF40374D)),
  );
  const focusedFieldBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
    borderSide: BorderSide(color: Color(0xFF8D5CFF), width: 1.5),
  );

  return showDialog<RoleFormResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: existing == null ? 'Новая роль' : 'Изменить роль',
            child: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameController,
                    style: const TextStyle(color: Color(0xFFF3EEFF)),
                    decoration: const InputDecoration(
                      labelText: 'Название роли',
                      labelStyle: TextStyle(color: Color(0xFF8F849F)),
                      enabledBorder: fieldBorder,
                      focusedBorder: focusedFieldBorder,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: colorController,
                    style: const TextStyle(color: Color(0xFFF3EEFF)),
                    decoration: const InputDecoration(
                      labelText: 'Цвет (#RRGGBB)',
                      labelStyle: TextStyle(color: Color(0xFF8F849F)),
                      enabledBorder: fieldBorder,
                      focusedBorder: focusedFieldBorder,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 240,
                    child: ListView(
                      children: [
                        for (final entry in rolePermissionLabels.entries)
                          CheckboxListTile(
                            value: permissions[entry.key] ?? false,
                            activeColor: const Color(0xFF8D5CFF),
                            checkColor: Colors.white,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text(
                              entry.value,
                              style: const TextStyle(
                                color: Color(0xFFF3EEFF),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onChanged: (value) {
                              setDialogState(() {
                                permissions[entry.key] = value ?? false;
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
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
                            final name = nameController.text.trim();

                            if (name.isEmpty) {
                              return;
                            }

                            Navigator.pop(
                              context,
                              RoleFormResult(
                                name: name,
                                color: colorController.text.trim().isEmpty
                                    ? null
                                    : colorController.text.trim(),
                                permissions: permissions,
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
            ),
          );
        },
      );
    },
  );
}

Future<void> showMemberRolesDialog({
  required BuildContext context,
  required AppServerMember member,
  required List<AppRole> roles,
  required Future<void> Function(AppRole role, bool assign) onToggle,
}) {
  final sortedRoles = [...roles]
    ..sort((left, right) => left.position.compareTo(right.position));
  final assignedIds = <String>{for (final role in member.roles) role.id};

  return showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setDialogState) {
          return PlumsDialog(
            title: 'Роли участника "${member.user.username}"',
            child: SizedBox(
              width: 380,
              height: 380,
              child: sortedRoles.isEmpty
                  ? const Center(
                      child: Text(
                        'На сервере пока нет ролей',
                        style: TextStyle(
                          color: Color(0xFFB8ADC8),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: sortedRoles.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final role = sortedRoles[index];
                        final assigned = assignedIds.contains(role.id);
                        final color =
                            parseHexColor(role.color) ?? const Color(0xFF8D5CFF);

                        return CheckboxListTile(
                          value: assigned,
                          activeColor: const Color(0xFF8D5CFF),
                          checkColor: Colors.white,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                role.name,
                                style: const TextStyle(
                                  color: Color(0xFFF3EEFF),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          onChanged: (value) async {
                            final assign = value ?? false;

                            setDialogState(() {
                              if (assign) {
                                assignedIds.add(role.id);
                              } else {
                                assignedIds.remove(role.id);
                              }
                            });

                            await onToggle(role, assign);
                          },
                        );
                      },
                    ),
            ),
          );
        },
      );
    },
  );
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
    this.email,
    this.avatarUrl,
    this.bio,
    required this.status,
  });

  final String id;
  final String username;
  final String? email;
  final String? avatarUrl;
  final String? bio;
  final String status;

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      username: json['username'] as String,
      email: json['email'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      status: json['status'] as String? ?? 'OFFLINE',
    );
  }

  AppUser copyWith({
    String? id,
    String? username,
    String? email,
    String? avatarUrl,
    String? bio,
    String? status,
  }) {
    return AppUser(
      id: id ?? this.id,
      username: username ?? this.username,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      status: status ?? this.status,
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

class AppRole {
  const AppRole({
    required this.id,
    required this.name,
    this.color,
    this.position = 0,
    this.permissions = const {},
  });

  final String id;
  final String name;
  final String? color;
  final int position;
  final Map<String, bool> permissions;

  bool has(String key) => permissions[key] == true;

  factory AppRole.fromJson(Map<String, dynamic> json) {
    final rawPermissions = json['permissions'];

    return AppRole(
      id: json['id'] as String,
      name: json['name'] as String,
      color: json['color'] as String?,
      position: json['position'] as int? ?? 0,
      permissions: rawPermissions is Map
          ? rawPermissions.map(
              (key, value) => MapEntry(key as String, value == true),
            )
          : const {},
    );
  }
}

// Зеркалит SERVER_PERMISSION_KEYS на бэкенде (backend/src/permissions/permission-keys.ts).
class AppPermissions {
  const AppPermissions({
    this.manageServer = false,
    this.manageChannels = false,
    this.manageMembers = false,
    this.manageBans = false,
    this.manageInvites = false,
    this.manageRoles = false,
  });

  final bool manageServer;
  final bool manageChannels;
  final bool manageMembers;
  final bool manageBans;
  final bool manageInvites;
  final bool manageRoles;

  static const AppPermissions none = AppPermissions();
  static const AppPermissions owner = AppPermissions(
    manageServer: true,
    manageChannels: true,
    manageMembers: true,
    manageBans: true,
    manageInvites: true,
    manageRoles: true,
  );

  factory AppPermissions.fromRoles(Iterable<AppRole> roles) {
    return AppPermissions(
      manageServer: roles.any((role) => role.has('manageServer')),
      manageChannels: roles.any((role) => role.has('manageChannels')),
      manageMembers: roles.any((role) => role.has('manageMembers')),
      manageBans: roles.any((role) => role.has('manageBans')),
      manageInvites: roles.any((role) => role.has('manageInvites')),
      manageRoles: roles.any((role) => role.has('manageRoles')),
    );
  }
}

class AppServerMember {
  const AppServerMember({
    required this.id,
    required this.serverId,
    required this.userId,
    required this.joinedAt,
    required this.user,
    this.roles = const [],
  });

  final String id;
  final String serverId;
  final String userId;
  final DateTime? joinedAt;
  final AppUser user;
  final List<AppRole> roles;

  factory AppServerMember.fromJson(Map<String, dynamic> json) {
    final rawRoles = json['roles'];

    return AppServerMember(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
      userId: json['userId'] as String,
      joinedAt: DateTime.tryParse(json['joinedAt'] as String? ?? ''),
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
      roles: rawRoles is List
          ? rawRoles
              .map((item) => AppRole.fromJson(item as Map<String, dynamic>))
              .toList()
          : const [],
    );
  }

  AppServerMember copyWith({
    String? id,
    String? serverId,
    String? userId,
    DateTime? joinedAt,
    AppUser? user,
    List<AppRole>? roles,
  }) {
    return AppServerMember(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      userId: userId ?? this.userId,
      joinedAt: joinedAt ?? this.joinedAt,
      user: user ?? this.user,
      roles: roles ?? this.roles,
    );
  }
}

class AppServerBan {
  const AppServerBan({
    required this.id,
    required this.serverId,
    required this.userId,
    required this.reason,
    required this.createdAt,
    required this.user,
  });

  final String id;
  final String serverId;
  final String userId;
  final String? reason;
  final DateTime? createdAt;
  final AppUser user;

  factory AppServerBan.fromJson(Map<String, dynamic> json) {
    return AppServerBan(
      id: json['id'] as String,
      serverId: json['serverId'] as String,
      userId: json['userId'] as String,
      reason: json['reason'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      user: AppUser.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
