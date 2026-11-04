part of 'main.dart';

class AppAttachment {
  const AppAttachment({
    required this.id,
    required this.originalName,
    required this.mimeType,
    required this.sizeBytes,
  });
  final String id;
  final String originalName;
  final String mimeType;
  final int sizeBytes;

  factory AppAttachment.fromJson(Map<String, dynamic> json) => AppAttachment(
    id: json['id'] as String,
    originalName: json['originalName'] as String,
    mimeType: json['mimeType'] as String,
    sizeBytes: json['sizeBytes'] as int,
  );
}

enum AttachmentSendResult { sent, rejected, uncertain }

class ProtectedAttachmentImage extends StatefulWidget {
  const ProtectedAttachmentImage({
    super.key,
    required this.attachment,
    required this.api,
  });
  final AppAttachment attachment;
  final ApiClient api;
  @override
  State<ProtectedAttachmentImage> createState() =>
      _ProtectedAttachmentImageState();
}

class _ProtectedAttachmentImageState extends State<ProtectedAttachmentImage> {
  Uint8List? bytes;
  ImageProvider<Object>? provider;
  bool loading = true;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ProtectedAttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.api != widget.api) {
      if (provider != null) unawaited(provider!.evict());
      bytes = null;
      provider = null;
      loading = true;
      _load();
    }
  }

  Future<void> _load() async {
    final epoch = ++generation;
    try {
      final result = await widget.api.downloadAttachment(widget.attachment.id);
      if (!mounted || epoch != generation) return;
      setState(() {
        bytes = result;
        provider = ResizeImage(
          MemoryImage(result),
          width: 720,
          height: 560,
          policy: ResizeImagePolicy.fit,
        );
        loading = false;
      });
    } catch (_) {
      if (mounted && epoch == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    if (provider != null) unawaited(provider!.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: loading
        ? const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(),
          )
        : provider == null
        ? TextButton(
            onPressed: () {
              setState(() => loading = true);
              _load();
            },
            child: const Text('Не удалось загрузить изображение — повторить'),
          )
        : Semantics(
            label: widget.attachment.originalName,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360, maxHeight: 280),
              child: Image(
                image: provider!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Text('Не удалось открыть изображение'),
              ),
            ),
          ),
  );
}

class _ImageDraft {
  _ImageDraft(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
  late final ImageProvider<Object>? preview = bytes.isEmpty
      ? null
      : ResizeImage(
          MemoryImage(bytes),
          width: 160,
          height: 130,
          policy: ResizeImagePolicy.fit,
        );
  AppAttachment? attachment;
  bool uploading = true;
  bool removing = false;
  String? error;
}

class _ChannelDraft {
  final TextEditingController text = TextEditingController();
  final List<_ImageDraft> images = [];
  String? requestId;
  String? submittedText;
  List<String>? submittedIds;
  bool sending = false;
  bool uncertain = false;
}

// Owned by MainShell, so channel changes or switching to DM do not lose a
// request whose HTTP outcome is unknown.
class ChannelAttachmentDrafts extends ChangeNotifier {
  ChannelAttachmentDrafts(this.api);
  final ApiClient api;
  final Map<String, _ChannelDraft> _drafts = {};
  bool _disposed = false;
  _ChannelDraft _draft(String channelId) =>
      _drafts.putIfAbsent(channelId, _ChannelDraft.new);
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> addFiles(String channelId, List<XFile> files) async {
    final target = _draft(channelId);
    if (files.length + target.images.length > 4) {
      throw StateError('Можно прикрепить не более четырёх изображений');
    }
    for (final file in files) {
      if (_disposed || target.images.length >= 4 || target.uncertain) break;
      try {
        final length = await file.length();
        if (_disposed) return;
        if (length <= 0 || length > 10 * 1024 * 1024) {
          throw StateError('Размер изображения должен быть до 10 МБ');
        }
        final bytes = await file.readAsBytes();
        if (_disposed) return;
        if (bytes.isEmpty || bytes.length > 10 * 1024 * 1024) {
          throw StateError('Размер изображения должен быть до 10 МБ');
        }
        final item = _ImageDraft(file.name, bytes);
        target.images.add(item);
        _changed();
        unawaited(_upload(channelId, target, item));
      } catch (error) {
        if (_disposed) return;
        final item = _ImageDraft(file.name, Uint8List(0))
          ..uploading = false
          ..error = error is StateError
              ? error.message
              : 'Не удалось прочитать файл';
        target.images.add(item);
        _changed();
      }
    }
  }

  Future<void> _upload(
    String channelId,
    _ChannelDraft target,
    _ImageDraft item,
  ) async {
    try {
      final uploaded = await api.uploadAttachment(
        channelId,
        item.name,
        item.bytes,
      );
      if (_disposed || !target.images.contains(item)) {
        try {
          await api.discardAttachment(uploaded.id);
        } catch (_) {}
        return;
      }
      item.attachment = uploaded;
      item.error = null;
    } catch (error) {
      if (!_disposed && target.images.contains(item)) {
        item.error = describeRequestError(error);
      }
    } finally {
      item.uploading = false;
      _changed();
    }
  }

  Future<void> _remove(String channelId, _ImageDraft item) async {
    final target = _draft(channelId);
    if (target.uncertain || target.sending || item.removing) return;
    if (item.attachment != null) {
      item.removing = true;
      _changed();
      try {
        await api.discardAttachment(item.attachment!.id);
      } catch (error) {
        item.removing = false;
        item.error =
            'Не удалось удалить загрузку: ${describeRequestError(error)}';
        _changed();
        return;
      }
    }
    if (item.preview != null) unawaited(item.preview!.evict());
    target.images.remove(item);
    _changed();
  }

  Future<void> send(
    String channelId,
    Future<AttachmentSendResult> Function(String, String, String, List<String>)
    callback,
  ) async {
    final target = _draft(channelId);
    if (target.sending ||
        target.images.any(
          (item) => item.uploading || item.removing || item.error != null,
        )) {
      return;
    }
    final text = target.uncertain
        ? target.submittedText!
        : target.text.text.trim();
    final ids = target.uncertain
        ? target.submittedIds!
        : target.images.map((item) => item.attachment!.id).toList();
    if (text.isEmpty && ids.isEmpty) return;
    if (!target.uncertain &&
        (target.requestId == null ||
            target.submittedText != text ||
            !_sameIds(target.submittedIds, ids))) {
      target.requestId = _newClientMessageId();
      target.submittedText = text;
      target.submittedIds = List.of(ids);
    }
    target.sending = true;
    _changed();
    AttachmentSendResult result;
    try {
      result = await callback(channelId, text, target.requestId!, ids);
    } catch (_) {
      result = AttachmentSendResult.uncertain;
    }
    target.sending = false;
    if (_disposed) return;
    if (result == AttachmentSendResult.sent) {
      for (final image in target.images) {
        if (image.preview != null) unawaited(image.preview!.evict());
      }
      target.images.clear();
      target.text.clear();
      target.requestId = null;
      target.submittedText = null;
      target.submittedIds = null;
      target.uncertain = false;
    } else if (result == AttachmentSendResult.uncertain) {
      target.uncertain = ids.isNotEmpty;
    } else {
      target.uncertain = false;
      target.requestId = null;
    }
    _changed();
  }

  bool _sameIds(List<String>? a, List<String> b) =>
      a != null &&
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

  @override
  void dispose() {
    _disposed = true;
    for (final draft in _drafts.values) {
      for (final image in draft.images) {
        if (image.preview != null) unawaited(image.preview!.evict());
      }
      draft.text.dispose();
    }
    super.dispose();
  }
}

class ChannelAttachmentInput extends StatelessWidget {
  const ChannelAttachmentInput({
    super.key,
    required this.channelId,
    required this.channelName,
    required this.canSendMessages,
    this.disabledHintText,
    required this.drafts,
    required this.onSend,
    this.pickFiles,
  });
  final String channelId;
  final String channelName;
  final bool canSendMessages;
  final String? disabledHintText;
  final ChannelAttachmentDrafts drafts;
  final Future<AttachmentSendResult> Function(
    String,
    String,
    String,
    List<String>,
  )
  onSend;
  final Future<List<XFile>> Function()? pickFiles;

  Future<void> _pick(BuildContext context) async {
    try {
      final files =
          await (pickFiles?.call() ??
              openFiles(
                acceptedTypeGroups: [
                  const XTypeGroup(
                    label: 'Images',
                    extensions: ['jpg', 'jpeg', 'png', 'webp'],
                  ),
                ],
              ));
      await drafts.addFiles(channelId, files);
    } catch (error) {
      if (context.mounted) {
        showErrorSnackBar(
          context,
          error is StateError
              ? error.message
              : 'Не удалось выбрать изображение: ${describeRequestError(error)}',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: drafts,
    builder: (context, _) {
      final draft = drafts._draft(channelId);
      final blocked = !canSendMessages || draft.sending;
      final ready = !draft.images.any(
        (item) => item.uploading || item.removing || item.error != null,
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (draft.uncertain)
              const Text(
                'Ответ сервера не получен. Повторите отправку с теми же данными.',
                style: TextStyle(color: Color(0xFFFFC777)),
              ),
            if (draft.images.isNotEmpty)
              Wrap(
                spacing: 8,
                children: [
                  for (final item in draft.images)
                    SizedBox(
                      width: 115,
                      child: Column(
                        children: [
                          if (item.bytes.isNotEmpty)
                            Image(
                              image: item.preview!,
                              width: 80,
                              height: 65,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  const Icon(Icons.broken_image),
                            ),
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (item.uploading || item.removing)
                            const Text('Загрузка...'),
                          if (item.error != null)
                            Text(
                              item.error!,
                              maxLines: 3,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                          IconButton(
                            tooltip: 'Убрать изображение',
                            onPressed: blocked || draft.uncertain
                                ? null
                                : () => unawaited(
                                    drafts._remove(channelId, item),
                                  ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            Container(
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
                    tooltip: 'Прикрепить изображение',
                    onPressed:
                        blocked || draft.uncertain || draft.images.length >= 4
                        ? null
                        : () => _pick(context),
                    icon: const Icon(Icons.add_circle_outline),
                    color: const Color(0xFFBFA7FF),
                  ),
                  Expanded(
                    child: ChatComposerField(
                      controller: draft.text,
                      enabled: canSendMessages,
                      readOnly: draft.sending || draft.uncertain,
                      onSend: () {
                        if (!blocked && ready) {
                          unawaited(drafts.send(channelId, onSend));
                        }
                      },
                      style: const TextStyle(color: Color(0xFFF3EEFF)),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintStyle: const TextStyle(color: Color(0xFF8F849F)),
                        hintText: canSendMessages
                            ? 'Написать в #$channelName'
                            : disabledHintText ?? 'Нет прав писать в этот канал',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: draft.uncertain
                        ? 'Повторить отправку'
                        : 'Отправить',
                    onPressed: blocked || !ready
                        ? null
                        : () => unawaited(drafts.send(channelId, onSend)),
                    color: const Color(0xFFFF7AC8),
                    icon: draft.sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}
