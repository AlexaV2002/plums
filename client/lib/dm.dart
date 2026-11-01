part of 'main.dart';

/* =========================
   DIRECT MESSAGES
========================= */

// Сетевые операции ЛС. Реализуется адаптером над ApiClient (ApiClientDmApi),
// в тестах — фейком. Права проверяет backend: клиент лишь отображает 403/404.
abstract class DmApi {
  Future<List<AppDmUser>> searchUsers(String query);
  Future<List<AppDmConversation>> getConversations();
  Future<AppDmConversation> openConversation(String userId);
  Future<List<AppMessage>> getMessages(
    String conversationId, {
    required int limit,
    String? before,
    String? after,
  });
  Future<AppMessage> sendMessage(String conversationId, String content);
  Future<void> deleteMessage(String messageId);
}

class ApiClientDmApi implements DmApi {
  ApiClientDmApi(this.client);

  final ApiClient client;

  @override
  Future<List<AppDmUser>> searchUsers(String query) =>
      client.searchUsers(query);

  @override
  Future<List<AppDmConversation>> getConversations() =>
      client.getDmConversations();

  @override
  Future<AppDmConversation> openConversation(String userId) =>
      client.openDmConversation(userId);

  @override
  Future<List<AppMessage>> getMessages(
    String conversationId, {
    required int limit,
    String? before,
    String? after,
  }) => client.getDmMessages(
    conversationId,
    limit: limit,
    before: before,
    after: after,
  );

  @override
  Future<AppMessage> sendMessage(String conversationId, String content) =>
      client.sendDmMessage(conversationId, content);

  @override
  Future<void> deleteMessage(String messageId) =>
      client.deleteDmMessage(messageId);
}

// Одноразовое уведомление для UI (snackbar), опционально с «Повторить».
class DmNotice {
  const DmNotice(this.message, {this.retry});

  final String message;
  final VoidCallback? retry;
}

int? _dmStatusCode(Object error) =>
    error is DioException ? error.response?.statusCode : null;

// Состояние экрана личных сообщений без виджетов: список диалогов, выбранный
// диалог и его история. История синхронизируется отдельным экземпляром
// MessageSyncController («канал» = conversationId), поэтому reconnect
// докачивает пропущенное от подтверждённой точки без потерь и дублей.
class DmController extends ChangeNotifier {
  DmController({
    required this.api,
    required this.joinRoom,
    required this.leaveRoom,
    required this.isConnected,
    required this.myUserId,
    this.onUnauthorized,
    this.pageSize = 50,
  }) {
    _sync = MessageSyncController(
      fetch: (conversationId, {required limit, after, before}) =>
          api.getMessages(
            conversationId,
            limit: limit,
            after: after,
            before: before,
          ),
      readMessages: () => _messages,
      writeMessages: (next, {hasMore}) {
        if (_disposed) return;
        _messages = next;
        if (hasMore != null) {
          _hasMore = hasMore;
          _messagesError = null;
        }
        final selectedId = _selectedId;
        if (selectedId != null && next.isNotEmpty) {
          _applyLastMessage(selectedId, next.last);
        }
        notifyListeners();
      },
      isChannelActive: (conversationId) =>
          !_disposed && _selectedId == conversationId,
      onIncomplete: (conversationId, retry) {
        if (_disposed || _selectedId != conversationId) return;
        _notify(
          const DmNotice(
            'Не удалось полностью восстановить историю сообщений после '
            'переподключения',
          ),
          retry: () => unawaited(retry()),
        );
      },
      pageSize: pageSize,
    );
  }

  final DmApi api;
  final void Function(String conversationId) joinRoom;
  final void Function(String conversationId) leaveRoom;
  final bool Function() isConnected;
  final String? Function() myUserId;
  final VoidCallback? onUnauthorized;
  final int pageSize;

  late final MessageSyncController _sync;
  final StreamController<DmNotice> _notices =
      StreamController<DmNotice>.broadcast();

  List<AppDmConversation> _conversations = [];
  bool _conversationsLoaded = false;
  bool _conversationsLoading = false;
  String? _conversationsError;
  int _listGeneration = 0;

  String? _selectedId;
  AppDmConversation? _selected;
  // Комната, в которую запрошен вход (joinRoom), — для парного leaveRoom.
  String? _joinedRoomId;
  List<AppMessage> _messages = [];
  bool _messagesLoading = false;
  String? _messagesError;
  bool _hasMore = false;
  bool _loadingMore = false;
  int _historyGeneration = 0;
  bool _disposed = false;
  bool _active = false;
  Timer? _conversationRefreshTimer;

  List<AppDmConversation> get conversations =>
      List.unmodifiable(_conversations);
  bool get conversationsLoaded => _conversationsLoaded;
  bool get conversationsLoading => _conversationsLoading;
  String? get conversationsError => _conversationsError;
  String? get selectedId => _selectedId;
  AppDmConversation? get selectedConversation => _selected;
  List<AppMessage> get messages => List.unmodifiable(_messages);
  bool get messagesLoading => _messagesLoading;
  String? get messagesError => _messagesError;
  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;
  Stream<DmNotice> get notices => _notices.stream;
  MessageSyncController get sync => _sync;

  AppDmUser? peerOf(AppDmConversation conversation) =>
      conversation.peerFor(myUserId());

  bool isOwnMessage(AppMessage message) => message.authorId == myUserId();

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _notify(DmNotice notice, {VoidCallback? retry}) {
    if (_disposed) return;
    _notices.add(
      retry == null ? notice : DmNotice(notice.message, retry: retry),
    );
  }

  bool _handleUnauthorized(Object error) {
    if (_dmStatusCode(error) != 401) return false;
    onUnauthorized?.call();
    return true;
  }

  // Вход в режим ЛС: первый раз — с индикатором, далее — тихое обновление.
  Future<void> activate() {
    _active = true;
    return loadConversations(silent: _conversationsLoaded);
  }

  void deactivate() {
    _active = false;
    _conversationRefreshTimer?.cancel();
  }

  Future<void> loadConversations({bool silent = false}) async {
    if (_disposed) return;
    final generation = ++_listGeneration;
    if (!silent) {
      _conversationsLoading = true;
      _conversationsError = null;
      _changed();
    }

    try {
      final loaded = await api.getConversations();
      if (_disposed || generation != _listGeneration) return;

      final known = {for (final item in _conversations) item.id: item};
      final merged = <AppDmConversation>[];
      for (final item in loaded) {
        // Live dm:new мог прийти во время запроса — не откатываем lastMessage.
        final local = known[item.id];
        merged.add(
          local != null && _isNewer(local.lastMessage, item.lastMessage)
              ? item.withLastMessage(local.lastMessage)
              : item,
        );
      }
      final selected = _selected;
      if (selected != null && !merged.any((item) => item.id == selected.id)) {
        // Только что созданный диалог может отсутствовать в старом ответе;
        // доступ всё равно проверит backend при загрузке истории.
        merged.add(selected);
      }
      _conversations = _sorted(merged);
      _refreshSelected();
      _conversationsLoaded = true;
      _conversationsLoading = false;
      _conversationsError = null;
      _changed();
      if (_active && _selectedId == null && _conversations.length == 1) {
        unawaited(selectConversation(_conversations.first.id));
      }
    } catch (error) {
      if (_disposed || generation != _listGeneration) return;
      if (_handleUnauthorized(error)) return;
      _conversationsLoading = false;
      if (silent && _conversationsLoaded) {
        _notify(
          DmNotice(
            'Не удалось обновить личные сообщения: '
            '${describeRequestError(error)}',
          ),
        );
      } else {
        _conversationsError = describeRequestError(error);
      }
      _changed();
    }
  }

  Future<List<AppDmUser>> searchUsers(String query) => api.searchUsers(query);

  // Создаёт/открывает диалог с пользователем (идемпотентно на backend).
  Future<bool> openWithUser(String userId) async {
    try {
      final conversation = await api.openConversation(userId);
      if (_disposed) return false;
      _upsertConversation(conversation);
      _changed();
      await selectConversation(conversation.id);
      return true;
    } catch (error) {
      if (_disposed || _handleUnauthorized(error)) return false;
      _notify(
        DmNotice('Не удалось открыть диалог: ${describeRequestError(error)}'),
      );
      return false;
    }
  }

  // Переключение: leave старой комнаты, сброс, baseline по REST, join новой.
  // Ответы для прежнего диалога отбрасываются по selectedId/поколению.
  Future<void> selectConversation(String conversationId) async {
    if (_disposed) return;
    if (_selectedId == conversationId) {
      if (_messagesError != null && !_messagesLoading) {
        await retryMessages();
      }
      return;
    }

    final joined = _joinedRoomId;
    if (joined != null) {
      leaveRoom(joined);
      _joinedRoomId = null;
    }
    _selectedId = conversationId;
    _refreshSelected();
    _resetHistory(loading: true);
    _sync.resetForChannel(conversationId, baselineLoading: true);
    _changed();
    await _loadBaseline(conversationId);
  }

  Future<void> retryMessages() async {
    final conversationId = _selectedId;
    if (_disposed || conversationId == null) return;
    _resetHistory(loading: true);
    _sync.resetForChannel(conversationId, baselineLoading: true);
    _changed();
    await _loadBaseline(conversationId);
  }

  void _resetHistory({required bool loading}) {
    _historyGeneration++;
    _messages = [];
    _hasMore = false;
    _loadingMore = false;
    _messagesError = null;
    _messagesLoading = loading;
  }

  Future<void> _loadBaseline(String conversationId) async {
    final generation = _historyGeneration;
    bool stale() =>
        _disposed ||
        _selectedId != conversationId ||
        generation != _historyGeneration;

    try {
      final page = await api.getMessages(conversationId, limit: pageSize);
      if (stale()) return;
      _messages = mergeMessagesChronologically(_messages, page);
      _hasMore = page.length >= pageSize;
      _messagesLoading = false;
      _messagesError = null;
      _sync.confirmBaseline(conversationId, page);
      if (_messages.isNotEmpty) {
        _applyLastMessage(conversationId, _messages.last);
      }
      _changed();
    } catch (error) {
      if (stale()) return;
      if (_handleUnauthorized(error)) return;
      final status = _dmStatusCode(error);
      if (status == 403 || status == 404) {
        _dropConversation(conversationId, describeRequestError(error));
        return;
      }
      _messagesLoading = false;
      _messagesError =
          'Ошибка загрузки сообщений: ${describeRequestError(error)}';
      _sync.abortBaseline(conversationId);
      _changed();
    }
    _joinAfterBaseline(conversationId);
  }

  // Как для каналов: докачка стартует по ack входа (handleDmJoined). Если
  // комната уже подтверждена, синхронизируемся сразу.
  void _joinAfterBaseline(String conversationId) {
    final alreadyJoined = _joinedRoomId == conversationId && isConnected();
    if (_joinedRoomId != conversationId) {
      _joinedRoomId = conversationId;
      joinRoom(conversationId);
    }
    if (alreadyJoined) {
      unawaited(_sync.onRoomJoined(conversationId));
    } else {
      unawaited(_sync.flushPending());
    }
  }

  Future<void> loadMore() async {
    final conversationId = _selectedId;
    if (_disposed ||
        conversationId == null ||
        _messages.isEmpty ||
        _loadingMore ||
        !_hasMore) {
      return;
    }
    final generation = _historyGeneration;
    bool stale() =>
        _disposed ||
        _selectedId != conversationId ||
        generation != _historyGeneration;

    _loadingMore = true;
    _changed();
    try {
      final older = await api.getMessages(
        conversationId,
        limit: pageSize,
        before: _messages.first.id,
      );
      if (stale()) return;
      _messages = mergeMessagesChronologically(_messages, older);
      _hasMore = older.length >= pageSize;
    } catch (error) {
      if (stale() || _handleUnauthorized(error)) return;
      _notify(
        DmNotice(
          'Не удалось загрузить более старые сообщения: '
          '${describeRequestError(error)}',
        ),
      );
    }
    if (stale()) return;
    _loadingMore = false;
    _changed();
  }

  // Возвращает true, если сообщение принято backend (для очистки ввода).
  Future<bool> sendMessage(String content) async {
    final conversationId = _selectedId;
    final text = content.trim();
    if (_disposed || conversationId == null || text.isEmpty) return false;

    try {
      final message = await api.sendMessage(conversationId, text);
      if (_disposed) return true;
      _addMessage(message, live: false);
      _changed();
      return true;
    } catch (error) {
      if (_disposed || _handleUnauthorized(error)) return false;
      final status = _dmStatusCode(error);
      if (status == 403 || status == 404) {
        _dropConversation(conversationId, describeRequestError(error));
        return false;
      }
      _notify(
        DmNotice(
          'Не удалось отправить сообщение: ${describeRequestError(error)}',
        ),
      );
      return false;
    }
  }

  // Клиент предлагает удалить только своё; решение всё равно за backend (403).
  Future<bool> deleteMessage(AppMessage message) async {
    if (_disposed || !isOwnMessage(message)) return false;
    try {
      await api.deleteMessage(message.id);
      if (_disposed) return true;
      _removeMessage(message.channelId, message.id);
      _changed();
      return true;
    } catch (error) {
      if (_disposed || _handleUnauthorized(error)) return false;
      _notify(
        DmNotice(
          'Не удалось удалить сообщение: ${describeRequestError(error)}',
        ),
      );
      return false;
    }
  }

  /* ---- realtime ---- */

  void handleDmNew(AppMessage message) {
    if (_disposed) return;
    _addMessage(message, live: true);
    _changed();
  }

  void handleDmDelete(RealtimeDmDelete event) {
    if (_disposed) return;
    _removeMessage(event.conversationId, event.id);
    _changed();
  }

  void handleDmJoined(String conversationId) {
    if (_disposed || conversationId != _selectedId) return;
    unawaited(_sync.onRoomJoined(conversationId));
  }

  void handleDmJoinDenied(RealtimeDmJoinDenied event) {
    if (_disposed) return;
    if (_joinedRoomId == event.conversationId) _joinedRoomId = null;
    _dropConversation(
      event.conversationId,
      event.reason == 'forbidden'
          ? 'Нет доступа к этому диалогу'
          : 'Диалог не найден',
    );
  }

  void handleDisconnected() {
    _sync.onDisconnected();
  }

  // Получатель может ещё не состоять в комнате нового диалога. Событие
  // содержит только id; авторизованный REST даёт актуальный список.
  void handleConversationChanged(String conversationId) {
    if (_disposed || !_active || conversationId.isEmpty) return;
    _scheduleConversationRefresh();
  }

  void handleReidentified() {
    if (!_disposed && _active) _scheduleConversationRefresh();
  }

  void _scheduleConversationRefresh() {
    _conversationRefreshTimer?.cancel();
    _conversationRefreshTimer = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed && _active) {
        unawaited(loadConversations(silent: _conversationsLoaded));
      }
    });
  }

  /* ---- внутреннее ---- */

  void _addMessage(AppMessage message, {required bool live}) {
    final conversationId = message.channelId;
    if (!_conversations.any((item) => item.id == conversationId)) {
      // Неизвестный диалог (например, новый) — перечитываем список.
      unawaited(loadConversations(silent: true));
    } else {
      _applyLastMessage(conversationId, message);
    }
    if (conversationId != _selectedId) return;
    if (!_messages.any((item) => item.id == message.id)) {
      _messages = mergeMessagesChronologically(_messages, [message]);
    }
    // Продвигает подтверждённую точку только в состоянии inSync.
    if (live) _sync.onLiveMessage(message);
  }

  void _removeMessage(String conversationId, String messageId) {
    if (conversationId == _selectedId) {
      _messages = _messages.where((item) => item.id != messageId).toList();
    }
    final index = _conversations.indexWhere(
      (item) => item.id == conversationId,
    );
    if (index < 0 || _conversations[index].lastMessage?.id != messageId) {
      return;
    }
    if (conversationId == _selectedId) {
      _conversations[index] = _conversations[index].withLastMessage(
        _messages.isEmpty ? null : _messages.last,
      );
      _refreshSelected();
    } else {
      unawaited(loadConversations(silent: true));
    }
  }

  // Обновляет lastMessage и поднимает диалог наверх, если сообщение новее.
  void _applyLastMessage(String conversationId, AppMessage message) {
    final index = _conversations.indexWhere(
      (item) => item.id == conversationId,
    );
    if (index < 0) return;
    final current = _conversations[index];
    if (current.lastMessage?.id == message.id ||
        !_isNewer(message, current.lastMessage)) {
      return;
    }
    _conversations.removeAt(index);
    _conversations.insert(0, current.withLastMessage(message));
    _refreshSelected();
  }

  void _upsertConversation(AppDmConversation conversation) {
    final index = _conversations.indexWhere(
      (item) => item.id == conversation.id,
    );
    if (index >= 0) {
      _conversations[index] = conversation;
    } else {
      _conversations.insert(0, conversation);
    }
    _conversations = _sorted(_conversations);
    _refreshSelected();
  }

  // Диалог недоступен (403/404/ack forbidden): убираем из списка и выбора,
  // выбираем следующий доступный, если он есть.
  void _dropConversation(String conversationId, String reason) {
    _conversations.removeWhere((item) => item.id == conversationId);
    final wasSelected = _selectedId == conversationId;
    if (wasSelected) {
      if (_joinedRoomId == conversationId) {
        leaveRoom(conversationId);
        _joinedRoomId = null;
      }
      _selectedId = null;
      _selected = null;
      _resetHistory(loading: false);
      _sync.resetForChannel(null);
    }
    _notify(DmNotice(reason));
    _changed();
    if (wasSelected && _conversations.isNotEmpty) {
      unawaited(selectConversation(_conversations.first.id));
    }
  }

  void _refreshSelected() {
    final id = _selectedId;
    if (id == null) {
      _selected = null;
      return;
    }
    for (final item in _conversations) {
      if (item.id == id) {
        _selected = item;
        return;
      }
    }
  }

  static bool _isNewer(AppMessage? candidate, AppMessage? current) {
    if (candidate == null) return false;
    if (current == null) return true;
    final a = candidate.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final b = current.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final compare = a.compareTo(b);
    return compare > 0 ||
        (compare == 0 && candidate.id.compareTo(current.id) > 0);
  }

  static List<AppDmConversation> _sorted(List<AppDmConversation> items) {
    return List.of(items)..sort((a, b) => b.activityAt.compareTo(a.activityAt));
  }

  @override
  void dispose() {
    _disposed = true;
    _historyGeneration++;
    _listGeneration++;
    _conversationRefreshTimer?.cancel();
    _sync.resetForChannel(null);
    unawaited(_notices.close());
    super.dispose();
  }
}

/* ---- UI ---- */

// Экран ЛС: средняя панель — диалоги, правая — чат. Принимает контроллер и
// состояние соединения, поэтому тестируется без MainShell и глобального API.
class DmView extends StatefulWidget {
  const DmView({
    super.key,
    required this.controller,
    required this.connection,
    this.footer,
  });

  final DmController controller;
  final ValueListenable<bool> connection;
  final Widget? footer;

  @override
  State<DmView> createState() => _DmViewState();
}

class _DmViewState extends State<DmView> {
  final ScrollController scrollController = ScrollController();
  StreamSubscription<DmNotice>? _noticeSubscription;
  String? _shownConversationId;
  String? _shownLastMessageId;

  @override
  void initState() {
    super.initState();
    _subscribe();
    widget.controller.addListener(_handleControllerChange);
    scrollController.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant DmView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChange);
      widget.controller.addListener(_handleControllerChange);
      unawaited(_noticeSubscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    _noticeSubscription = widget.controller.notices.listen((notice) {
      if (!mounted) return;
      final retry = notice.retry;
      showErrorSnackBar(
        context,
        notice.message,
        action: retry == null
            ? null
            : SnackBarAction(label: 'Повторить', onPressed: retry),
      );
    });
  }

  @override
  void dispose() {
    unawaited(_noticeSubscription?.cancel());
    widget.controller.removeListener(_handleControllerChange);
    scrollController.removeListener(_handleScroll);
    scrollController.dispose();
    super.dispose();
  }

  // Прокрутка вниз при смене диалога и при новом последнем сообщении.
  void _handleControllerChange() {
    final controller = widget.controller;
    final messages = controller.messages;
    final lastId = messages.isEmpty ? null : messages.last.id;
    if (controller.selectedId == _shownConversationId &&
        lastId == _shownLastMessageId) {
      return;
    }
    _shownConversationId = controller.selectedId;
    _shownLastMessageId = lastId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    });
  }

  void _handleScroll() {
    if (!scrollController.hasClients) return;
    final controller = widget.controller;
    if (scrollController.position.pixels > 200 ||
        controller.loadingMore ||
        !controller.hasMore) {
      return;
    }
    final previousPixels = scrollController.position.pixels;
    final previousExtent = scrollController.position.maxScrollExtent;
    final lastId = _shownLastMessageId;
    unawaited(
      controller.loadMore().then((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !scrollController.hasClients ||
              _shownLastMessageId != lastId) {
            return;
          }
          final added =
              scrollController.position.maxScrollExtent - previousExtent;
          scrollController.jumpTo(previousPixels + added);
        });
      }),
    );
  }

  Future<void> _startNewConversation() async {
    final user = await showDmUserSearchDialog(
      context: context,
      search: widget.controller.searchUsers,
    );
    if (user == null || !mounted) return;
    await widget.controller.openWithUser(user.id);
  }

  Future<void> _confirmDelete(AppMessage message) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: 'Удалить сообщение?',
      message: 'Сообщение будет удалено из диалога.',
      confirmText: 'Удалить',
    );
    if (confirmed != true || !mounted) return;
    await widget.controller.deleteMessage(message);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        return Row(
          children: [
            DmConversationsPanel(
              controller: widget.controller,
              onNewConversation: _startNewConversation,
              footer: widget.footer,
            ),
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: widget.connection,
                builder: (context, connected, _) => DmChatArea(
                  controller: widget.controller,
                  connected: connected,
                  scrollController: scrollController,
                  onDeleteMessage: _confirmDelete,
                  onNewConversation: _startNewConversation,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DmStateMessage extends StatelessWidget {
  const _DmStateMessage({
    required this.text,
    this.isError = false,
    this.onRetry,
    this.action,
  });

  final String text;
  final bool isError;
  final VoidCallback? onRetry;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isError
                    ? const Color(0xFFFF7A7A)
                    : const Color(0xFFB8ADC8),
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Повторить')),
            ?action,
          ],
        ),
      ),
    );
  }
}

class DmConversationsPanel extends StatelessWidget {
  const DmConversationsPanel({
    super.key,
    required this.controller,
    required this.onNewConversation,
    this.footer,
  });

  final DmController controller;
  final VoidCallback onNewConversation;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final conversations = controller.conversations;
    final Widget body;
    if (controller.conversationsLoading && conversations.isEmpty) {
      body = const Center(
        child: CircularProgressIndicator(color: Color(0xFF8D5CFF)),
      );
    } else if (controller.conversationsError != null) {
      body = _DmStateMessage(
        text: controller.conversationsError!,
        isError: true,
        onRetry: () => unawaited(controller.loadConversations()),
      );
    } else if (conversations.isEmpty) {
      body = const _DmStateMessage(text: 'Нет личных сообщений');
    } else {
      body = ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final conversation in conversations)
            DmConversationTile(
              peer: controller.peerOf(conversation),
              lastMessage: conversation.lastMessage,
              isSelected: conversation.id == controller.selectedId,
              onTap: () =>
                  unawaited(controller.selectConversation(conversation.id)),
            ),
        ],
      );
    }

    return Container(
      width: 260,
      color: const Color(0xFF191620),
      child: Column(
        children: [
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    'Личные сообщения',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Color(0xFFF3EEFF),
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Новое сообщение',
                  onPressed: onNewConversation,
                  icon: const Icon(Icons.edit_square),
                  color: const Color(0xFFBFA7FF),
                ),
              ],
            ),
          ),
          Expanded(child: body),
          ?footer,
        ],
      ),
    );
  }
}

class DmConversationTile extends StatelessWidget {
  const DmConversationTile({
    super.key,
    required this.peer,
    required this.lastMessage,
    required this.isSelected,
    required this.onTap,
  });

  final AppDmUser? peer;
  final AppMessage? lastMessage;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = peer?.username ?? 'Неизвестный пользователь';
    final preview = lastMessage?.content ?? 'Сообщений пока нет';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: isSelected ? const Color(0xFF2B2535) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
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
                      peer?.initial ?? '?',
                      style: const TextStyle(
                        color: Colors.white,
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
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFFF3EEFF)
                              : const Color(0xFFCFC4E8),
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF8F849F),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DmChatArea extends StatelessWidget {
  const DmChatArea({
    super.key,
    required this.controller,
    required this.connected,
    required this.scrollController,
    required this.onDeleteMessage,
    required this.onNewConversation,
  });

  final DmController controller;
  final bool connected;
  final ScrollController scrollController;
  final ValueChanged<AppMessage> onDeleteMessage;
  final VoidCallback onNewConversation;

  @override
  Widget build(BuildContext context) {
    final conversation = controller.selectedConversation;
    final conversationId = controller.selectedId;

    if (conversationId == null) {
      return Container(
        color: const Color(0xFF211C29),
        child: _DmStateMessage(
          text: controller.conversations.isEmpty
              ? 'Нет личных сообщений'
              : 'Выберите диалог',
          action: TextButton.icon(
            onPressed: onNewConversation,
            icon: const Icon(Icons.chat_bubble_outline, size: 18),
            label: const Text('Новое сообщение'),
          ),
        ),
      );
    }

    final peer = conversation == null ? null : controller.peerOf(conversation);
    final peerName = peer?.username ?? '';
    final Widget body;
    if (controller.messagesLoading) {
      body = const Center(
        child: CircularProgressIndicator(color: Color(0xFF8D5CFF)),
      );
    } else if (controller.messagesError != null) {
      body = _DmStateMessage(
        text: controller.messagesError!,
        isError: true,
        onRetry: () => unawaited(controller.retryMessages()),
      );
    } else {
      body = MessagesList(
        messages: controller.messages,
        hasMoreMessages: controller.hasMore,
        isLoadingMoreMessages: controller.loadingMore,
        scrollController: scrollController,
        emptyText: 'Сообщений пока нет',
        canEditMessage: (_) => false,
        canDeleteMessage: controller.isOwnMessage,
        onEditMessage: (_) {},
        onDeleteMessage: onDeleteMessage,
        onLoadMoreMessages: () => unawaited(controller.loadMore()),
      );
    }

    return Container(
      color: const Color(0xFF211C29),
      child: Column(
        children: [
          Container(
            height: 58,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: const BoxDecoration(
              color: Color(0xFF241F2D),
              border: Border(
                bottom: BorderSide(color: Color(0xFF312A3B), width: 1),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.alternate_email_rounded,
                  color: Color(0xFFCFC4E8),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    peerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFF3EEFF),
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: body),
          MessageInput(
            channelId: conversationId,
            channelName: peerName,
            canSendMessages: connected && controller.messagesError == null,
            hintText: 'Написать @$peerName',
            disabledHintText: connected
                ? 'Не удалось загрузить сообщения'
                : 'Нет соединения',
            onSendMessage: (content, _) => controller.sendMessage(content),
          ),
        ],
      ),
    );
  }
}

// Поиск пользователя по нику (debounce 300 мс). Возвращает выбранного или null.
Future<AppDmUser?> showDmUserSearchDialog({
  required BuildContext context,
  required Future<List<AppDmUser>> Function(String query) search,
}) {
  return showDialog<AppDmUser>(
    context: context,
    builder: (context) => PlumsDialog(
      title: 'Новое сообщение',
      child: DmUserSearch(
        search: search,
        onSelected: (user) => Navigator.of(context).pop(user),
      ),
    ),
  );
}

class DmUserSearch extends StatefulWidget {
  const DmUserSearch({
    super.key,
    required this.search,
    required this.onSelected,
    this.debounce = const Duration(milliseconds: 300),
  });

  final Future<List<AppDmUser>> Function(String query) search;
  final ValueChanged<AppDmUser> onSelected;
  final Duration debounce;

  @override
  State<DmUserSearch> createState() => _DmUserSearchState();
}

class _DmUserSearchState extends State<DmUserSearch> {
  Timer? _debounce;
  int _generation = 0;
  bool _loading = false;
  String? _error;
  String _query = '';
  List<AppDmUser> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    final generation = ++_generation;
    setState(() {
      _query = query;
      _error = null;
      _loading = query.isNotEmpty;
      if (query.isEmpty) _results = [];
    });
    if (query.isEmpty) return;
    _debounce = Timer(widget.debounce, () => _run(query, generation));
  }

  Future<void> _run(String query, int generation) async {
    try {
      final results = await widget.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = describeRequestError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget results;
    if (_loading) {
      results = const Padding(
        padding: EdgeInsets.all(16),
        child: CircularProgressIndicator(color: Color(0xFF8D5CFF)),
      );
    } else if (_error != null) {
      results = _DmStateMessage(
        text: _error!,
        isError: true,
        onRetry: () => _onChanged(_query),
      );
    } else if (_query.isNotEmpty && _results.isEmpty) {
      results = const _DmStateMessage(text: 'Никого не найдено');
    } else {
      results = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final user in _results)
            ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              leading: CircleAvatar(
                backgroundColor: const Color(0xFF8D5CFF),
                child: Text(
                  user.initial,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              title: Text(
                user.username,
                style: const TextStyle(color: Color(0xFFF3EEFF)),
              ),
              onTap: () => widget.onSelected(user),
            ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          autofocus: true,
          onChanged: _onChanged,
          style: const TextStyle(color: Color(0xFFF3EEFF)),
          decoration: InputDecoration(
            hintText: 'Ник пользователя',
            hintStyle: const TextStyle(color: Color(0xFF8F849F)),
            prefixIcon: const Icon(Icons.search, color: Color(0xFF8F849F)),
            filled: true,
            fillColor: const Color(0xFF302A39),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(child: results),
        ),
      ],
    );
  }
}
