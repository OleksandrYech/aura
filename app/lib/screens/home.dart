import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../attach.dart';
import '../call.dart';
import '../client.dart';
import '../lock.dart';
import '../media.dart';
import '../platform_media.dart';
import '../theme.dart';
import '../video.dart';
import '../voice.dart';
import 'group.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _contactsOpened = 0; // новый ключ при каждом открытии вкладки обновляет список

  void _select(int tab) => setState(() {
        if (tab == 1) _contactsOpened++;
        _tab = tab;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [ChatsTab(onNewChat: () => _select(1)), ContactsTab(key: ValueKey(_contactsOpened)), const SettingsTab()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Чаты'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Контакты'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 48});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0]).join().toUpperCase();
    // Цвет зависит от имени, чтобы у собеседника он не менялся.
    final colors = [c.lavender, c.thistle, c.grayPurple, c.warmSand];
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: colors[name.hashCode.abs() % colors.length],
      child: Text(initials,
          style: TextStyle(fontFamily: 'Comfortaa', fontWeight: FontWeight.w700, fontSize: size / 3, color: c.ink)),
    );
  }
}

String formatTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (t.year == yesterday.year && t.month == yesterday.month && t.day == yesterday.day) return 'вчера';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
}

void openChat(BuildContext context, String peer) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(peer: peer)));

class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key, required this.onNewChat});
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final peers = client.chats.keys.where((p) => client.chats[p]!.isNotEmpty).toList()
          ..sort((a, b) => client.chats[b]!.last.time.compareTo(client.chats[a]!.last.time));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(children: [
                Expanded(child: Text('Чаты', style: Theme.of(context).textTheme.headlineSmall)),
                if (!client.connected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('подключение…', style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
                  ),
                IconButton(
                  tooltip: 'Новая группа',
                  icon: Icon(Icons.group_add_outlined, color: c.ink),
                  onPressed: () => newGroup(context),
                ),
                IconButton(
                  tooltip: 'Новый чат',
                  style: IconButton.styleFrom(backgroundColor: c.lavender),
                  icon: Icon(Icons.add, color: c.ink),
                  onPressed: onNewChat,
                ),
              ]),
            ),
            Expanded(
              child: peers.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('Пока нет чатов. Нажмите +, чтобы найти собеседника.',
                            textAlign: TextAlign.center, style: TextStyle(color: c.ink.withValues(alpha: 0.6))),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: peers.length,
                      itemBuilder: (context, i) {
                        final peer = peers[i];
                        final last = client.chats[peer]!.last;
                        final name = client.title(peer);
                        final author = last.update != null
                            ? ''
                            : last.mine
                            ? 'Вы: '
                            : last.from != null
                            ? '${client.nameOf(last.from!)}: '
                            : '';
                        return ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          leading: Avatar(name),
                          title: Row(children: [
                            Expanded(child: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                            Text(formatTime(last.time), style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
                          ]),
                          subtitle: Text('$author${last.preview}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                          trailing: client.hasUnread(peer) ? CircleAvatar(radius: 4.5, backgroundColor: c.grayPurple) : null,
                          onTap: () => openChat(context, peer),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class ContactsTab extends StatefulWidget {
  const ContactsTab({super.key});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  // Пустой запрос: собеседники из переписки, иначе результат поиска на сервере.
  List<({String nick, String name})>? _found;
  String? _error;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _found = null);
      return;
    }
    try {
      final users = await client.searchUsers(q);
      if (mounted) {
        setState(() {
          _found = users;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final users = _found ??
        [
          for (final n in client.chats.keys)
            if (!AuraClient.isGroup(n)) (nick: n, name: client.names[n] ?? n),
        ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text('Контакты', style: Theme.of(context).textTheme.headlineSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            onChanged: (q) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
            },
            decoration: const InputDecoration(hintText: 'Точный никнейм собеседника', prefixIcon: Icon(Icons.search)),
          ),
        ),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(20), child: Text('⚠ $_error', style: TextStyle(color: c.ink))),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              if (_found?.isEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text('Никого не нашли. Нужен никнейм целиком.', style: TextStyle(color: c.ink.withValues(alpha: 0.6))),
                ),
              for (final u in users)
                ListTile(
                  leading: Avatar(u.name, size: 40),
                  title: Text(u.name),
                  subtitle: Text('@${u.nick}', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
                  onTap: () => openChat(context, u.nick),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.peer});
  final String peer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _draft = TextEditingController();
  int _uploading = 0;

  @override
  void initState() {
    super.initState();
    client.addListener(_markRead);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  @override
  void dispose() {
    client.removeListener(_markRead);
    _ticker?.cancel();
    _recorder?.cancel().whenComplete(_recorder!.dispose);
    super.dispose();
  }

  void _markRead() {
    if (client.hasUnread(widget.peer)) client.markRead(widget.peer);
    // Название, участники и право писать в группе меняются сообщениями.
    if (AuraClient.isGroup(widget.peer) && mounted) setState(() {});
  }

  void _send() {
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    client.send(widget.peer, text);
    _draft.clear();
  }

  VoiceRecorder? _recorder;
  Timer? _ticker;

  Future<void> _record() async {
    final r = VoiceRecorder();
    var ok = false;
    try {
      ok = await AppLock.whilePicking(r.start); // запрос разрешения может свернуть приложение
    } catch (e) {
      debugPrint('AURA: запись: $e');
    }
    if (!mounted) return r.dispose();
    if (!ok) {
      r.dispose();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Нет доступа к микрофону')));
      return;
    }
    setState(() => _recorder = r);
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  Future<void> _stopRecording({required bool send}) async {
    final r = _recorder!;
    _ticker?.cancel();
    setState(() => _recorder = null);
    try {
      if (!send) return await r.cancel();
      final rec = await r.stop();
      if (rec == null || rec.$2 < const Duration(milliseconds: 500)) return;
      setState(() => _uploading++);
      try {
        await client.sendFile(widget.peer, 'voice.wav', rec.$1, extra: {'voice': true, 'duration': rec.$2.inMilliseconds});
      } finally {
        if (mounted) setState(() => _uploading--);
      }
    } catch (e) {
      debugPrint('AURA: голосовое: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Голосовое: ${e is ApiException ? e : 'не удалось отправить'}')));
      }
    } finally {
      r.dispose();
    }
  }

  double? _progress; // null — доля пока неизвестна
  String _stage = 'Отправка';
  String _count = ''; // какой по счёту файл альбома
  (int, int)? _bytes; // отправлено и всего, байт

  String get _status => switch ((_bytes, _progress)) {
    ((final sent, final total), _) => '$_stage$_count ${formatSize(sent)} / ${formatSize(total)}',
    (_, final p?) => '$_stage$_count ${(p * 100).round()}%',
    _ => '$_stage$_count…',
  };

  void _fail(String what, Object e) {
    debugPrint('AURA: вложение $what: $e');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$what: ${e is ApiException ? e : 'не удалось отправить'}'),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(label: 'OK', onPressed: () {}),
    ));
  }

  Future<void> _attach() async {
    final kind = await showAttachMenu(context);
    if (kind == null || !mounted) return;
    if (kind == AttachKind.media && !kIsWeb) {
      final List<AssetEntity>? assets;
      try {
        assets = await AppLock.whilePicking(() => pickFromGallery(context));
      } catch (e) {
        return _fail('Галерея', e);
      }
      if (assets != null) {
        return _sendAlbum([
          for (final a in assets)
            () async {
              final file = (await a.file)!;
              final thumb =
                  a.type == AssetType.video ? await a.thumbnailDataWithSize(const ThumbnailSize.square(240), quality: 70) : null;
              return _uploadMedia(XFile(file.path), thumb: thumb);
            },
        ]);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Нет доступа к галерее, открываю системный выбор'),
        action: SnackBarAction(label: 'Настройки', onPressed: PhotoManager.openSetting),
      ));
    }
    final List<PlatformFile> files;
    try {
      files = await AppLock.whilePicking(() => FilePicker.pickFiles(
        type: kind == AttachKind.media ? FileType.media : FileType.any,
      ));
    } catch (e) {
      return _fail('Выбор файла', e);
    }
    Future<int> length(PlatformFile f) async => await f.length() ?? (await f.readAsBytes()).length;
    if (kind == AttachKind.media) {
      return _sendAlbum([
        for (final f in files) () async => _uploadMedia(f.xFile, open: f.readAsByteStream, length: await length(f)),
      ]);
    }
    for (final f in files) {
      await _upload(f.name, () async {
        final sent = await client.sendStream(widget.peer, f.name, f.readAsByteStream(), await length(f), onProgress: _sendProgress);
        await keepSent(sent, path: f.path);
      });
    }
  }

  /// Фото и видео уходят альбомами до 10 штук, как в Telegram; одно — обычным сообщением.
  /// Альбом отправляется, когда загружены все его файлы; если один не загрузился, остальные стираются с сервера.
  Future<void> _sendAlbum(List<Future<Map<String, dynamic>> Function()> jobs) async {
    for (var i = 0; i < jobs.length; i += 10) {
      final batch = jobs.sublist(i, min(i + 10, jobs.length));
      await _upload(batch.length == 1 ? 'фото или видео' : 'альбом', () async {
        final files = <Map<String, dynamic>>[];
        try {
          for (final (n, job) in batch.indexed) {
            if (mounted && batch.length > 1) setState(() => _count = ' ${n + 1} из ${batch.length}');
            files.add(await job());
          }
        } catch (_) {
          client.discard(files);
          rethrow;
        }
        files.length == 1 ? client.send(widget.peer, '', file: files.single) : client.send(widget.peer, '', files: files);
      });
    }
  }

  Future<void> _upload(String what, Future<void> Function() send) async {
    setState(() => _uploading++);
    try {
      await inBackground(send);
    } catch (e) {
      _fail(what, e);
    } finally {
      if (mounted) setState(() => (_uploading--, _progress = null, _bytes = null, _stage = 'Отправка', _count = ''));
    }
  }

  void _setProgress(double p) {
    if (mounted) setState(() => _progress = p);
    backgroundStatus(_status);
  }

  void _sendProgress(int sent, int total) {
    if (mounted) setState(() => (_bytes = (sent, total), _progress = total == 0 ? null : sent / total));
    backgroundStatus(_status);
  }

  /// Фото и видео перед загрузкой сжимаются, к видео прикладывается превью. Возвращает вложение для сообщения.
  /// Файл читается потоком: видео до 2 ГБ не нужно держать в памяти целиком.
  Future<Map<String, dynamic>> _uploadMedia(XFile file, {Stream<List<int>> Function()? open, int? length, Uint8List? thumb}) async {
    var name = file.name;
    var compressed = false; // file — временный файл сжатия, его можно перенести к себе
    final extra = <String, dynamic>{};
    if (isVideo(name)) {
      extra['video'] = true;
      if (!kIsWeb) {
        try {
          setState(() => _stage = 'Сжатие видео');
          if (await compressVideo(file.path, onProgress: _setProgress) case final small?) {
            (file, name, open, length) = (XFile(small), '${name.substring(0, name.lastIndexOf('.'))}.mp4', null, null);
            compressed = true;
          }
        } catch (e) {
          debugPrint('AURA: сжатие видео: $e'); // отправим оригинал
        }
        if (mounted) setState(() => (_stage = 'Отправка', _progress = 0));
      }
      try {
        // В браузере кадр берётся из уже открытого файла, а не из копии в памяти.
        if (!kIsWeb || file.path.startsWith('blob:')) thumb ??= await videoThumbnail(file);
      } catch (e) {
        debugPrint('AURA: превью видео: $e'); // без превью видео всё равно отправится
      }
      if (thumb != null) extra['thumb'] = base64.encode(thumb);
    }
    length ??= await file.length();
    if (isImage(name) && !name.toLowerCase().endsWith('.gif') && length > 500 << 10 && length <= 64 << 20) {
      try {
        final bytes = await (open?.call() ?? file.openRead()).fold(BytesBuilder(copy: false), (b, c) => b..add(c));
        if (await shrinkImage(bytes.takeBytes()) case final small? when small.length < length) {
          final jpg = '${name.substring(0, name.lastIndexOf('.'))}.jpg';
          final sent = await client.upload(jpg, Stream.value(small), small.length, onProgress: _sendProgress);
          await keepSent(sent, bytes: small);
          return sent;
        }
      } catch (e) {
        debugPrint('AURA: сжатие фото: $e'); // отправим оригинал
      }
    }
    final sent = await client.upload(name, open?.call() ?? file.openRead(), length, extra: extra, onProgress: _sendProgress);
    await keepSent(sent, path: file.path, temporary: compressed);
    return sent;
  }

  /// Повтор не отправленного сообщения. Если у собеседника новый ключ аккаунта, сначала спросить.
  Future<void> _retry(Message m) async {
    if (!client.hasNewDevice(widget.peer)) return client.retry(widget.peer, m);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Код безопасности изменился'),
        content: Text('У ${client.title(widget.peer)} новый ключ аккаунта: так бывает, если собеседник начал заново. '
            'Если вы этого не ждали, сначала сверьте код безопасности: ключ мог подменить кто-то другой.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Отправить всё равно')),
        ],
      ),
    );
    if (ok == true) await client.approveDevices(widget.peer);
  }

  /// Меню сообщения по долгому нажатию: копировать текст и удалить.
  Future<void> _menu(Message m) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (m.text.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Копировать'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
          if (m.mine)
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined),
              title: const Text('Удалить у всех'),
              subtitle: const Text('Пропадёт и у собеседника, файлы удалятся с сервера'),
              onTap: () => Navigator.pop(context, 'all'),
            ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Удалить у меня'),
            subtitle: const Text('На всех ваших устройствах, вместе с файлами'),
            onTap: () => Navigator.pop(context, 'me'),
          ),
        ]),
      ),
    );
    switch (choice) {
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.text));
      case 'all' || 'me':
        client.delete(widget.peer, [m], everyone: choice == 'all');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final group = AuraClient.isGroup(widget.peer);
    final name = client.title(widget.peer);
    // В группе, из которой исключили или откуда вышли, писать нельзя.
    final member = !group || client.members(widget.peer).contains(client.nick);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.cream,
        titleSpacing: 0,
        shape: Border(bottom: BorderSide(color: c.lightGray)),
        title: GestureDetector(
          onTap: group
              ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupScreen(chat: widget.peer)))
              : null,
          child: Row(children: [
            Avatar(name, size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                Text(group ? 'Участники: ${client.members(widget.peer).length}' : '@${widget.peer}',
                    style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.55))),
              ]),
            ),
          ]),
        ),
        actions: [
          if (group)
            IconButton(
              tooltip: 'Участники',
              icon: const Icon(Icons.group_outlined),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GroupScreen(chat: widget.peer))),
            )
          else ...[
            IconButton(
              tooltip: 'Позвонить',
              icon: const Icon(Icons.call_outlined),
              onPressed: () => calls.start(widget.peer),
            ),
            IconButton(
              tooltip: 'Код безопасности',
              icon: const Icon(Icons.verified_user_outlined),
              onPressed: () => showDialog(context: context, builder: (_) => SafetyNumberDialog(peer: widget.peer)),
            ),
          ],
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListenableBuilder(
              listenable: client,
              builder: (context, _) {
                final messages = client.chats[widget.peer] ?? const [];
                return ListView.separated(
                  reverse: true, // новые сообщения снизу и всегда в поле зрения
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final m = messages[messages.length - 1 - i];
                    if (m.update != null) {
                      return Center(
                        child: Text(m.text,
                            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.55))),
                      );
                    }
                    return Align(
                      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                      // Не отправленное сообщение уходит заново по нажатию, долгое нажатие открывает меню.
                      child: GestureDetector(
                        onTap: m.status == Status.failed ? () => _retry(m) : null,
                        onLongPress: () => _menu(m),
                        child: MessageBubble(m),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Смена ключа собеседника: без решения пользователя сообщения не уходят.
          ListenableBuilder(
            listenable: client,
            builder: (context, _) => !client.hasNewDevice(widget.peer)
                ? const SizedBox.shrink()
                : Container(
                    margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    decoration: BoxDecoration(color: c.lavender, borderRadius: BorderRadius.circular(16)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('У ${client.title(widget.peer)} новый ключ безопасности: так бывает, если собеседник '
                          'начал заново. Сообщения не уходят, пока вы не решите. После принятия сверьте код безопасности.'),
                      Wrap(alignment: WrapAlignment.end, children: [
                        TextButton(
                          onPressed: () => client.rejectNewKey(widget.peer),
                          child: const Text('Отклонить'),
                        ),
                        TextButton(
                          onPressed: () => client.approveDevices(widget.peer),
                          child: const Text('Принять'),
                        ),
                      ]),
                    ]),
                  ),
          ),
          if (_uploading > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  _status,
                  style: TextStyle(fontSize: 13, color: c.grayPurple),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(minHeight: 4, value: _progress, borderRadius: BorderRadius.circular(2)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: !member
                ? Text('Вы не участник этой группы', textAlign: TextAlign.center, style: TextStyle(color: c.ink.withValues(alpha: 0.6)))
                : _recorder != null
                ? Row(children: [
                    IconButton(
                      tooltip: 'Отменить запись',
                      icon: Icon(Icons.delete_outline, color: c.ink),
                      onPressed: () => _stopRecording(send: false),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 14),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Запись ${formatDuration(_recorder!.elapsed)}')),
                    IconButton(
                      tooltip: 'Отправить голосовое',
                      style: IconButton.styleFrom(backgroundColor: c.lavender, fixedSize: const Size.square(44)),
                      icon: Icon(Icons.send_outlined, color: c.ink, size: 18),
                      onPressed: () => _stopRecording(send: true),
                    ),
                  ])
                : Row(children: [
              IconButton(
                tooltip: 'Прикрепить файл',
                icon: Icon(Icons.attach_file, color: c.ink),
                onPressed: _attach,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: _draft,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Сообщение…',
                    border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))),
                    enabledBorder:
                        OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))),
                    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Записать голосовое',
                icon: Icon(Icons.mic_none, color: c.ink),
                onPressed: _record,
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Отправить',
                style: IconButton.styleFrom(backgroundColor: c.lavender, fixedSize: const Size.square(44)),
                icon: Icon(Icons.send_outlined, color: c.ink, size: 18),
                onPressed: _send,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Пузырь сообщения. Фото и видео в нём от края до края: скруглены как сам пузырь, без рамки вокруг,
/// а время без подписи лежит прямо на превью.
class MessageBubble extends StatelessWidget {
  const MessageBubble(this.m, {super.key});
  final Message m;

  static const _pad = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final media = m.files != null || (m.file != null && isMedia(m.file!));
    final time = Row(mainAxisSize: MainAxisSize.min, children: [
      Text(formatTime(m.time), style: TextStyle(fontSize: 11, color: c.ink.withValues(alpha: 0.55))),
      if (m.mine) ...[
        const SizedBox(width: 4),
        StatusIcon(m.status),
      ],
    ]);
    final name = m.from == null
        ? null
        : Align(
            alignment: Alignment.centerLeft,
            child: Text(client.nameOf(m.from!),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.grayPurple)),
          );
    final text = m.text.isEmpty
        ? null
        : Align(
            alignment: Alignment.centerLeft,
            // Не SelectableText: выделение перехватило бы нажатия, текст копируется из меню.
            child: Text(m.text, style: const TextStyle(fontSize: 15, height: 1.5)),
          );
    final preview = m.files != null ? Album(m.files!) : m.file != null ? Attachment(m.file!) : null;
    return Container(
      constraints: const BoxConstraints(maxWidth: bubbleWidth),
      padding: media ? null : _pad,
      clipBehavior: media ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: m.mine ? c.lavender : c.thistle,
        borderRadius: BorderRadius.circular(radiusBubble),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
        if (!media) ...[
          ?name,
          ?preview,
          ?text,
          const SizedBox(height: 4),
          time,
        ] else ...[
          if (name != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 6), child: name),
          if (text == null)
            Stack(alignment: Alignment.bottomRight, children: [
              preview!,
              Container(
                margin: const EdgeInsets.all(6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: c.cream.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)),
                child: time,
              ),
            ])
          else ...[
            preview!,
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [text, const SizedBox(height: 4), time]),
            ),
          ],
        ],
      ]),
    );
  }
}

/// Вложение в пузыре: фото показываем сразу, остальные файлы сохраняются по нажатию.
/// Байты скачиваются с сервера и расшифровываются на устройстве.
class Attachment extends StatelessWidget {
  const Attachment(this.file, {super.key});
  final Map<String, dynamic> file;

  @override
  Widget build(BuildContext context) {
    final String name = file['name'];
    if (file['voice'] == true) return VoicePlayer(file);
    if (file['video'] == true) return VideoAttachment(file);
    if (!isImage(name)) return Padding(padding: const EdgeInsets.only(bottom: 6), child: FileAttachment(file));
    return FutureBuilder(
      future: client.fileBytes(file),
      builder: (context, snap) {
        if (snap.data case final bytes?) {
          return GestureDetector(
            onTap: () => showImage(context, file, bytes),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: previewMaxHeight),
              child: Image.memory(bytes, width: bubbleWidth, fit: BoxFit.cover, semanticLabel: name),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: snap.connectionState != ConnectionState.done
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Flexible(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis)),
                ])
              : FileAttachment(file, error: snap.error),
        );
      },
    );
  }
}

/// Фото на весь экран, целиком и без скругления, с увеличением и сохранением.
void showImage(BuildContext context, Map<String, dynamic> file, Uint8List bytes) => showDialog(
  context: context,
  builder: (context) => Dialog.fullscreen(
    backgroundColor: Colors.black,
    child: Stack(children: [
      Positioned.fill(child: InteractiveViewer(maxScale: 8, child: Image.memory(bytes, fit: BoxFit.contain))),
      SafeArea(
        child: Row(children: [
          IconButton(
            tooltip: 'Закрыть',
            color: Colors.white,
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Сохранить',
            color: Colors.white,
            icon: const Icon(Icons.download_outlined),
            onPressed: () => FilePicker.saveFile(fileName: file['name'], bytes: bytes),
          ),
        ]),
      ),
    ]),
  ),
);

/// Альбом в пузыре: плитки по две в ряд, при нечётном числе первая на всю ширину.
class Album extends StatelessWidget {
  const Album(this.files, {super.key});
  final List<Map<String, dynamic>> files;

  static const _gap = 2.0, _side = (bubbleWidth - _gap) / 2; // две плитки с зазором — вся ширина пузыря

  @override
  Widget build(BuildContext context) => Wrap(spacing: _gap, runSpacing: _gap, children: [
    for (final (i, f) in files.indexed)
      SizedBox(width: i == 0 && files.length.isOdd ? bubbleWidth : _side, height: _side, child: _Tile(f)),
  ]);
}

/// Плитка альбома: у видео превью из сообщения, фото скачивается и показывается сразу.
class _Tile extends StatelessWidget {
  const _Tile(this.file);
  final Map<String, dynamic> file;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    if (file['video'] == true) {
      final thumb = file['thumb'] is String ? base64.decode(file['thumb']) : null;
      return Semantics(
        button: true,
        label: 'Видео ${file['name']}, ${formatSize(file['size'])}',
        child: GestureDetector(
          onTap: () => showDialog(context: context, builder: (_) => VideoDialog(file)),
          child: Stack(fit: StackFit.expand, children: [
            thumb != null
                ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                : ColoredBox(color: c.ink.withValues(alpha: 0.85)),
            const Center(child: Icon(Icons.play_circle_outline, color: Colors.white, size: 36)),
          ]),
        ),
      );
    }
    if (!isImage(file['name'])) return ColoredBox(color: c.lightGray, child: Center(child: FileAttachment(file)));
    return FutureBuilder(
      future: client.fileBytes(file),
      builder: (context, snap) => switch (snap.data) {
        final bytes? => GestureDetector(
          onTap: () => showImage(context, file, bytes),
          child: Image.memory(bytes, fit: BoxFit.cover, semanticLabel: file['name']),
        ),
        _ => ColoredBox(
          color: c.lightGray,
          child: Center(
            child: snap.hasError
                ? Icon(Icons.error_outline, color: c.ink)
                : const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      },
    );
  }
}

/// Файл в пузыре: по нажатию скачивается, расшифровывается и сохраняется на устройство.
class FileAttachment extends StatefulWidget {
  const FileAttachment(this.file, {super.key, this.error});
  final Map<String, dynamic> file;
  final Object? error;

  @override
  State<FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<FileAttachment> {
  double? _progress;
  late Object? _error = widget.error;

  Future<void> _save() async {
    setState(() => (_progress = 0, _error = null));
    try {
      await saveAttachment(widget.file, onProgress: (p) => mounted ? setState(() => _progress = p) : null);
    } catch (e) {
      debugPrint('AURA: сохранение файла: $e');
      if (mounted) setState(() => _error = e is ApiException ? e : 'Не удалось сохранить');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final String name = widget.file['name'];
    final busy = _progress != null;
    return InkWell(
      borderRadius: BorderRadius.circular(radiusMd),
      onTap: busy ? null : _save,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        busy
            ? SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2, value: _progress))
            : Icon(_error != null ? Icons.error_outline : Icons.insert_drive_file_outlined, color: c.ink),
        const SizedBox(width: 10),
        Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
            Text(
              _error != null
                  ? '$_error'
                  : busy
                  ? 'Скачано ${(_progress! * 100).round()}% из ${formatSize(widget.file['size'])}'
                  : formatSize(widget.file['size']),
              style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.6)),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Код безопасности: если у вас и собеседника он одинаковый, переписку никто не подменил.
class SafetyNumberDialog extends StatelessWidget {
  const SafetyNumberDialog({super.key, required this.peer});
  final String peer;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return AlertDialog(
      backgroundColor: c.cream,
      title: const Text('Код безопасности'),
      content: FutureBuilder(
        future: client.safetyNumber(peer),
        builder: (context, snap) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snap.hasData)
              SelectableText(
                // 12 групп по 5 цифр, по 4 в строке.
                [
                  for (var i = 0; i < 60; i += 20)
                    [for (var j = i; j < i + 20; j += 5) snap.data!.substring(j, j + 5)].join('  '),
                ].join('\n'),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 17, height: 1.6, letterSpacing: 1),
              )
            else if (snap.hasError)
              Text('⚠ ${snap.error}')
            else
              const Center(child: CircularProgressIndicator()),
            const SizedBox(height: 16),
            Text(
              'Сравните этот код с кодом у @$peer при встрече или по звонку. Если цифры совпадают, '
              'сообщения между вами никто не может прочитать или подменить. Код меняется, только если кто-то '
              'из вас начал заново: новые устройства его не меняют.',
              style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.7)),
            ),
            if (snap.hasData)
              ListenableBuilder(
                listenable: client,
                builder: (context, _) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Сверено'),
                  subtitle: const Text('Сбросится, если ключ собеседника изменится'),
                  value: client.verified.contains(peer),
                  onChanged: (v) => client.setVerified(peer, v ?? false),
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
    );
  }
}

/// Одна галочка — отправлено, две — доставлено, две цветные — прочитано, красный значок — не отправлено.
class StatusIcon extends StatelessWidget {
  const StatusIcon(this.status, {super.key});
  final Status status;

  @override
  Widget build(BuildContext context) {
    final dim = AuraColors.of(context).ink.withValues(alpha: 0.55);
    // В палитре нет цвета, заметного на лавандовом пузыре, поэтому для «прочитано» свой акцент.
    final read = Theme.of(context).brightness == Brightness.dark ? const Color(0xFFB8AEFF) : const Color(0xFF6A5ACD);
    final (icon, color, label) = switch (status) {
      Status.pending => (Icons.schedule, dim, 'в очереди'),
      Status.failed => (Icons.error_outline, Colors.redAccent, 'не отправлено, нажмите, чтобы повторить'),
      Status.sent => (Icons.done, dim, 'отправлено'),
      Status.delivered => (Icons.done_all, dim, 'доставлено'),
      Status.read => (Icons.done_all, read, 'прочитано'),
    };
    return Icon(icon, size: 16, color: color, semanticLabel: label);
  }
}
