part of 'main.dart';

final profileImageUpdates = ValueNotifier<Map<String, String?>>({});
final profileImageRevisions = <String, int>{};
final _profileImagePath = RegExp(r'^/profile-images/[0-9a-fA-F-]{36}/content$');
String? _activeProfileUserId;
int _profileSessionEpoch = 0;

void applyProfileImageUpdate(Map<String, dynamic> event) {
  final user = event['userId'];
  final server = event['serverId'];
  final url = event['url'];
  final revision = event['revision'];
  if ((user is! String && server is! String) ||
      (url != null && url is! String) || revision is! int || revision < 0) {
    return;
  }
  final key = user is String ? 'user:$user' : 'server:$server';
  if (revision <= (profileImageRevisions[key] ?? -1)) return;
  profileImageRevisions[key] = revision;
  profileImageUpdates.value = {...profileImageUpdates.value, key: url as String?};
}

void syncProfileImages(List<AppServer> servers, List<AppServerMember> members, AppUser? me) {
  for (final server in servers) {
    applyProfileImageUpdate({'serverId': server.id, 'url': server.iconUrl, 'revision': server.profileImageRevision});
  }
  for (final member in members) {
    applyProfileImageUpdate({'userId': member.userId, 'url': member.user.avatarUrl, 'revision': member.user.profileImageRevision});
  }
  if (me != null) applyProfileImageUpdate({'userId': me.id, 'url': me.avatarUrl, 'revision': me.profileImageRevision});
}

class ProfileImage extends StatelessWidget {
  const ProfileImage({super.key, required this.entityKey, required this.url, required this.size, required this.child, this.revision = 0});
  final String entityKey;
  final String? url;
  final int revision;
  final double size;
  final Widget child;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, String?>>(
    valueListenable: profileImageUpdates,
    builder: (context, updates, _) {
      final path = updates.containsKey(entityKey) && (profileImageRevisions[entityKey] ?? -1) >= revision ? updates[entityKey] : url;
      if (path == null || !_profileImagePath.hasMatch(path)) return child;
      return _ProtectedProfileImage(key: ValueKey(path), path: path, size: size, fallback: child);
    },
  );
}

class _ProtectedProfileImage extends StatefulWidget {
  const _ProtectedProfileImage({super.key, required this.path, required this.size, required this.fallback});
  final String path;
  final double size;
  final Widget fallback;
  @override
  State<_ProtectedProfileImage> createState() => _ProtectedProfileImageState();
}

class _ProtectedProfileImageState extends State<_ProtectedProfileImage> {
  Uint8List? bytes;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final response = await apiClient.dio.get<List<int>>(widget.path,
        options: Options(headers: {'Authorization': 'Bearer ${apiClient.accessToken}'}, responseType: ResponseType.bytes));
      if (mounted && response.data != null) setState(() => bytes = Uint8List.fromList(response.data!));
    } catch (_) { /* Keep fallback on offline/access errors. */ }
  }
  @override
  Widget build(BuildContext context) => bytes == null ? widget.fallback : ClipRRect(
    borderRadius: BorderRadius.circular(widget.size / 3),
    child: Image.memory(bytes!, width: widget.size, height: widget.size, fit: BoxFit.cover,
      cacheWidth: (widget.size * 3).round(), cacheHeight: (widget.size * 3).round(),
      errorBuilder: (_, _, _) => widget.fallback),
  );
}

Future<void> changeProfileImage(BuildContext context, {required bool isServer, String? serverId, bool remove = false}) async {
  final actor = _activeProfileUserId;
  final sessionEpoch = _profileSessionEpoch;
  final path = isServer ? '/servers/$serverId/icon' : '/users/me/avatar';
  try {
    if (remove) {
      final response = await apiClient.dio.delete(path, options: apiClient.authOptions);
      if (actor != _activeProfileUserId || sessionEpoch != _profileSessionEpoch) return;
      if (response.data['revision'] is! int) throw StateError('Некорректный ответ сервера');
      applyProfileImageUpdate({if (isServer) 'serverId': serverId else 'userId': actor, 'url': null, 'revision': response.data['revision']});
    } else {
      final file = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'Изображения', extensions: ['jpg', 'jpeg', 'png', 'webp'])]);
      if (file == null) return;
      if (await file.length() > 10 * 1024 * 1024) throw StateError('Максимальный размер изображения — 10 МиБ');
      final bytes = await file.readAsBytes();
      if (bytes.length > 10 * 1024 * 1024) throw StateError('Максимальный размер изображения — 10 МиБ');
      if (actor != _activeProfileUserId || sessionEpoch != _profileSessionEpoch) return;
      final response = await apiClient.dio.post(path,
        data: FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: file.name)}),
        options: apiClient.authOptions);
      final url = response.data['url'];
      if (actor != _activeProfileUserId || sessionEpoch != _profileSessionEpoch) return;
      if (response.data['revision'] is! int || url is! String || !_profileImagePath.hasMatch(url)) throw StateError('Некорректный ответ сервера');
      applyProfileImageUpdate({if (isServer) 'serverId': serverId else 'userId': actor, 'url': url, 'revision': response.data['revision']});
    }
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Изображение обновлено')));
  } catch (error) {
    if (context.mounted) showErrorSnackBar(context, 'Не удалось обновить изображение: ${describeRequestError(error)}');
  }
}
