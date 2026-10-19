import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'media.dart';
import 'platform_media.dart';
import 'signal.dart';

/// Статус сообщения. Свои: в очереди → отправлено → доставлено → прочитано.
/// Входящие: получено → прочитано (собеседнику ушло подтверждение о прочтении).
/// failed — сервер отклонил сообщение, оно уходит заново только по нажатию. Стоит последним:
/// статусы хранятся по имени, а квитанции сравнивают номер, и failed от них не меняется.
enum Status { pending, sent, delivered, read, failed }

class Message {
  Message({
    required this.id,
    required this.mine,
    required this.text,
    required this.time,
    required this.status,
    this.file,
    this.files,
  });

  final String id, text;
  final bool mine;
  final int time; // мс с эпохи
  Status status;

  /// Вложение: {id, key, name, size} — id файла на сервере и ключ, которым он зашифрован.
  final Map<String, dynamic>? file;

  /// Альбом: несколько фото и видео одним сообщением, каждое в том же виде, что [file].
  final List<Map<String, dynamic>>? files;

  /// Все вложения сообщения.
  List<Map<String, dynamic>> get attachments => [?file, ...?files];

  /// То, что уходит собеседнику внутри зашифрованного сообщения.
  Map<String, dynamic> get content => {'text': text, 'file': ?file, 'files': ?files};

  /// Строка для списка чатов.
  String get preview => text.isNotEmpty
      ? text
      : files != null
      ? 'Альбом: ${files!.length}'
      : file == null
      ? ''
      : file!['voice'] == true
      ? 'Голосовое сообщение'
      : file!['video'] == true
      ? 'Видео'
      : isImage(file!['name'])
      ? 'Фото'
      : '📎 ${file!['name']}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'mine': mine,
    'text': text,
    'time': time,
    'status': status.name,
    'file': ?file,
    'files': ?files,
  };
  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'],
    mine: j['mine'],
    text: j['text'],
    time: j['time'],
    file: j['file'],
    files: (j['files'] as List?)?.cast(),
    // До статусов было поле pending.
    status: j['status'] != null
        ? Status.values.byName(j['status'])
        : j['pending'] == true
        ? Status.pending
        : (j['mine'] ? Status.sent : Status.read),
  );
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Связь с сервером AURA и локальная история переписки.
/// Сообщения шифруются Signal Protocol отдельно для каждого устройства собеседника и для своих
/// других устройств. Сервер хранит шифротекст только до доставки, история живёт на устройстве.
// ponytail: история в SharedPreferences (JSON на собеседника), перейти на базу на устройстве, когда чаты станут длинными.
class AuraClient extends ChangeNotifier {
  AuraClient._();
  static final instance = AuraClient._();

  late SharedPreferences _prefs;
  String? token, nick, name;

  /// Переписка по никнейму собеседника.
  final chats = <String, List<Message>>{};

  /// Отображаемые имена собеседников.
  final names = <String, String>{};

  /// Время последнего прочтения чата.
  final lastRead = <String, int>{};

  /// Удаления, которые ещё не дошли до сервера: {id, peer, ids, everyone, files}.
  final _deletes = <Map<String, dynamic>>[];

  /// Ключи этого устройства; есть, пока выполнен вход.
  SignalKeys? _keys;

  /// Номер этого устройства на сервере.
  int? device;

  /// Известные устройства по никнейму; сбрасываются, когда сервер говорит, что список изменился.
  final _devices = <String, List<int>>{};

  /// Шифрование и расшифровка идут строго по очереди: сессии Signal нельзя менять параллельно.
  Future<void> _queue = Future.value();

  bool connected = false;
  WebSocketChannel? _ws;
  Timer? _retry;
  int _backoff = 1;

  bool get signedIn => token != null;

  /// Адрес сервера: в Web это сайт, с которого открыто приложение, в мобильных — постоянный домен.
  static final server = kIsWeb ? Uri.base.origin : 'https://web.aura-msg.space';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    token = _prefs.getString('token');
    nick = _prefs.getString('nick');
    name = _prefs.getString('name');
    device = _prefs.getInt('device');
    final keys = _prefs.getString('signal');
    if (keys != null) _keys = SignalKeys.fromJson(keys);
    final raw = _prefs.getString('chats');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (j['chats'] as Map<String, dynamic>).entries) {
        chats[key] = [for (final m in value as List) Message.fromJson(m)];
      }
      names.addAll((j['names'] as Map<String, dynamic>).cast());
      lastRead.addAll((j['lastRead'] as Map<String, dynamic>).cast());
      _deletes.addAll((j['deletes'] as List? ?? []).cast());
    }
    if (signedIn && _keys != null) {
      _connect();
    } else if (signedIn) {
      await logout(); // вход сделан до шифрования: нужно войти заново
    }
  }

  // --- Аккаунт ---

  Future<void> register(String nick, String password) =>
      _auth('/api/register', {'nick': nick, 'password': password});

  Future<void> login(String nick, String password) =>
      _auth('/api/login', {'nick': nick, 'password': password});

  Future<void> _auth(String path, Map body) async {
    final res = await _request('POST', _api(path), body);
    token = res['token'];
    // Каждый вход — новое устройство со своими ключами. Публикуем их до того, как считать вход выполненным.
    final keys = SignalKeys.generate();
    try {
      await _request('PUT', _api('/api/keys'), keys.publicBundle());
    } catch (_) {
      token = null;
      rethrow;
    }
    _keys = keys;
    nick = res['nick'];
    name = res['name'];
    device = res['device'];
    await _prefs.setString('token', token!);
    await _prefs.setString('nick', nick!);
    await _prefs.setString('name', name!);
    await _prefs.setInt('device', device!);
    await _saveKeys();
    notifyListeners();
    _connect();
  }

  Future<void> updateName(String newName) async {
    final res = await _request('PUT', _api('/api/me'), {'name': newName});
    name = res['name'];
    await _prefs.setString('name', name!);
    notifyListeners();
  }

  Future<List<({String nick, String name})>> searchUsers(String q) async {
    final res = await _request('GET', _api('/api/users', {'q': q}), null) as List;
    final users = [for (final u in res) (nick: u['nick'] as String, name: u['name'] as String)];
    for (final u in users) {
      names[u.nick] = u.name;
    }
    return users;
  }

  /// Код безопасности с собеседником: сверьте его при встрече или по другому каналу.
  Future<String> safetyNumber(String peer) async {
    Future<List<String>> keys(String n) async => [
      for (final d in await _request('GET', _api('/api/devices/$n'), null) as List) d['identityKey'] as String,
    ];
    return SignalKeys.safetyNumber(nick!, await keys(nick!), peer, await keys(peer));
  }

  Future<void> logout() async {
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    await ws?.sink.close();
    // Сервер удаляет устройство и его ключи; если связи нет, просто забываем их здесь.
    if (token != null) _request('POST', _api('/api/logout'), {}).ignore();
    token = nick = name = device = _keys = null;
    connected = false;
    chats.clear();
    _files.clear();
    names.clear();
    lastRead.clear();
    _deletes.clear();
    _devices.clear();
    // Адрес сервера оставляем, чтобы не вводить его заново.
    for (final k in ['token', 'nick', 'name', 'device', 'signal', 'chats', 'localFiles']) {
      await _prefs.remove(k);
    }
    await clearLocalFiles();
    notifyListeners();
  }

  Uri _api(String path, [Map<String, String>? query]) => Uri.parse('$server$path').replace(queryParameters: query);

  Future<dynamic> _request(String method, Uri url, Object? body) async {
    final http.Response res;
    try {
      final req = http.Request(method, url)
        ..headers['content-type'] = 'application/json'
        ..headers.addAll({if (token != null) 'authorization': 'Bearer $token'});
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await req.send()).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException('Нет связи с сервером');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) throw ApiException(data is Map ? data['error'] ?? 'Ошибка сервера' : 'Ошибка сервера');
    return data;
  }

  // --- Сообщения ---

  void send(String to, String text, {Map<String, dynamic>? file, List<Map<String, dynamic>>? files}) {
    final m = Message(
      id: _newId(),
      mine: true,
      text: text,
      time: DateTime.now().millisecondsSinceEpoch,
      status: Status.pending,
      file: file,
      files: files,
    );
    chats.putIfAbsent(to, () => []).add(m);
    _save();
    _deliver(to, m);
  }

  static const maxFile = 2 << 30;

  /// Файл шифруется и грузится частями по 8 МБ: так не нужно держать его целиком в памяти,
  /// а каждый запрос проходит через Cloudflare, который режет тела больше 100 МБ.
  /// Размер части при отправке. Небольшие части быстрее повторить на мобильной сети;
  /// получатель берёт размер из сообщения, поэтому файлы с частями по 8 МБ тоже читаются.
  static const part = 2 << 20;

  /// Небольшие вложения держим в памяти до выхода, чтобы не качать их повторно.
  static const _cacheLimit = 32 << 20;

  Future<void> sendFile(String to, String name, Uint8List bytes, {Map<String, dynamic> extra = const {}}) =>
      sendStream(to, name, Stream.value(bytes), bytes.length, extra: extra);

  /// Сколько частей файла грузится и скачивается одновременно, как в Telegram.
  static const _parallel = 4;

  /// Загружает файл ([upload]) и отправляет сообщение с ним. Возвращает вложение из сообщения,
  /// чтобы сохранить файл на устройстве.
  Future<Map<String, dynamic>> sendStream(
    String to,
    String name,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic> extra = const {},
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = await upload(name, data, length, extra: extra, onProgress: onProgress);
    send(to, '', file: file);
    return file;
  }

  /// Шифрует файл новым ключом и загружает частями. Возвращает вложение для сообщения: id и ключ.
  /// Первая часть создаёт загрузку, остальные идут до [_parallel] одновременно.
  Future<Map<String, dynamic>> upload(
    String name,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic> extra = const {},
    void Function(int sent, int total)? onProgress,
  }) async {
    if (length > maxFile) throw ApiException('Файл больше 2 ГБ');
    final key = FileCrypto.newKey();
    final parts = max(1, (length + part - 1) ~/ part);
    final keep = length <= _cacheLimit ? BytesBuilder(copy: false) : null;
    final size = length + parts * 28; // у каждой части nonce и тег GCM
    String? id;
    var i = 0, sent = 0;
    // Части в пути, вместе с шифрованием: оно тоже идёт в нескольких изолятах сразу.
    // Упавшая часть остаётся в наборе, и следующее ожидание бросит её ошибку.
    // ponytail: после ошибки остальные части догружаются впустую, отменять их, если это станет заметно.
    final running = <Future<void>>{};
    await for (final chunk in rechunk(data, part)) {
      if (i == parts) throw ApiException('Файл изменился во время отправки');
      keep?.add(chunk);
      final index = i++;
      var last = 0; // байт этой части в прогрессе: при повторе часть идёт сначала
      void progress(int n) {
        final m = min(n, chunk.length);
        sent += m - last;
        last = m;
        onProgress?.call(sent, length);
      }
      final body = encryptPart(key, index, index == parts - 1, chunk);
      if (id == null) {
        id = await _uploadPart(null, size, await body, onSent: progress);
      } else {
        final f = body.then((b) => _uploadPart(id, index * (part + 28), b, onSent: progress));
        running.add(f);
        f.then((_) => running.remove(f), onError: (_) {});
        while (running.length >= _parallel) {
          await Future.any(running);
        }
      }
    }
    await Future.wait(running.toList());
    if (i != parts) throw ApiException('Файл изменился во время отправки');
    if (keep != null) _files[id!] = Future.value(keep.takeBytes());
    return {'id': id, 'key': base64.encode(key), 'name': name, 'size': length, 'chunk': part, ...extra};
  }

  /// Стирает с сервера загруженные, но так и не отправленные файлы, например начало альбома, который не ушёл.
  Future<void> discard(List<Map<String, dynamic>> files) async {
    try {
      await _request('POST', _api('/api/unsend'), {
        'files': [for (final f in files) f['id']],
      });
    } catch (e) {
      debugPrint('AURA: удаление загрузок: $e'); // удалятся по сроку
    }
    for (final f in files) {
      _forget(f);
    }
  }

  void _forget(Map<String, dynamic> file) {
    _files.remove(file['id']);
    forgetFile(file);
  }

  // --- Удаление ---

  /// Удаляет сообщения у себя, вместе с другими своими устройствами, или у всех (только свои сообщения).
  /// Вложения стираются с устройства, а при удалении у всех — и с сервера, и у собеседника.
  /// Удаление дойдёт и после потери связи: оно ждёт в [_deletes], как неотправленное сообщение.
  void delete(String peer, List<Message> list, {bool everyone = false}) {
    assert(!everyone || list.every((m) => m.mine));
    final ids = [for (final m in list) m.id];
    final d = {
      'id': _newId(),
      'peer': peer,
      'ids': ids,
      'everyone': everyone,
      if (everyone) 'files': [for (final m in list) for (final f in m.attachments) f['id']],
    };
    _remove(peer, ids.toSet());
    _deletes.add(d);
    _save();
    _sendDelete(d);
  }

  /// [fromPeer] — удаление пришло от собеседника: он может убрать только свои сообщения.
  void _remove(String peer, Set<Object?> ids, {bool fromPeer = false}) {
    chats[peer]?.removeWhere((m) {
      if (!ids.contains(m.id) || (fromPeer && m.mine)) return false;
      m.attachments.forEach(_forget);
      return true;
    });
  }

  void _sendDelete(Map<String, dynamic> d) => _serial(() async {
    if (!connected || !_deletes.contains(d)) return;
    final String peer = d['peer'], id = d['id'];
    final everyone = d['everyone'] == true;
    // Сначала сервер стирает файлы и ещё не доставленные копии, потом уходят уведомления.
    if (everyone) await _request('POST', _api('/api/unsend'), {'ids': d['ids'], 'files': d['files']});
    final toPeer = everyone && await _sendCopy(peer, id, {'delete': d['ids']});
    final toMine = await _sendCopy(nick!, id, {'delete': d['ids'], 'peer': peer});
    // Ждём подтверждения сервера ('sent'), если было кому отправлять.
    if (!(everyone ? toPeer : toMine)) _dropDelete(id);
  });

  void _dropDelete(Object? id) {
    final before = _deletes.length;
    _deletes.removeWhere((d) => d['id'] == id);
    if (_deletes.length != before) _save();
  }

  /// Без [id] создаёт загрузку размером [at] байт (итог всех зашифрованных частей),
  /// с [id] — пишет часть на место [at].
  Future<String> _uploadPart(String? id, int at, Uint8List body, {void Function(int sent)? onSent}) async {
    final url = _api(id == null ? '/api/files' : '/api/files/$id', {(id == null ? 'size' : 'offset'): '$at'});
    for (var attempt = 1;; attempt++) {
      final http.Response res;
      final req = _Upload(url, body, onSent)
        ..headers.addAll({'content-type': 'application/octet-stream', 'authorization': 'Bearer $token'});
      try {
        res = await http.Response.fromStream(await req.send());
      } catch (e) {
        debugPrint('AURA: загрузка части, попытка $attempt: $e');
        if (attempt == _attempts) throw ApiException('Нет связи с сервером');
        await Future<void>.delayed(Duration(seconds: 2 << attempt)); // повтор безопасен: сервер сверяет offset
        continue;
      } finally {
        req.timer.cancel(); // иначе запрос с телом жил бы в памяти до срабатывания таймера
      }
      if (res.statusCode >= 500 && attempt < _attempts) {
        await Future<void>.delayed(Duration(seconds: 2 << attempt)); // прокси или сервер на миг недоступны
        continue;
      }
      final Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        throw ApiException('Сервер не принял файл (${res.statusCode})'); // например, страница ошибки прокси
      }
      if (data is! Map || res.statusCode != 200) {
        throw ApiException(data is Map ? data['error'] ?? 'Ошибка сервера' : 'Ошибка сервера');
      }
      return data['id'];
    }
  }

  /// Сколько раз пробовать часть файла: при смене Wi-Fi на мобильную сеть связь пропадает на десятки секунд.
  static const _attempts = 6;

  /// Расшифрованные вложения этого запуска приложения.
  // ponytail: только в памяти, сохранять на устройство, когда понадобится просмотр без сети.
  final _files = <String, Future<Uint8List>>{};

  /// Скачивает и расшифровывает вложение целиком. Для больших файлов есть [fileParts].
  Future<Uint8List> fileBytes(Map<String, dynamic> file) {
    final String id = file['id'];
    if (_files[id] case final cached?) return cached;
    final bytes = () async {
      final all = BytesBuilder(copy: false);
      await for (final p in fileParts(file)) {
        all.add(p);
      }
      return all.takeBytes();
    }();
    if ((file['size'] ?? 0) <= _cacheLimit) {
      _files[id] = bytes;
      bytes.then((_) {}, onError: (_) {
        _files.remove(id); // после ошибки попробуем скачать заново
      });
    }
    return bytes;
  }

  /// Расшифрованное вложение по частям, по мере скачивания.
  Stream<Uint8List> fileParts(Map<String, dynamic> file) async* {
    final key = base64.decode(file['key']);
    final int? chunk = file['chunk'];
    if (chunk == null) {
      final data = await _downloadPart(file['id']); // файлы старых версий, одним куском
      try {
        yield FileCrypto.decrypt(key, data);
      } catch (_) {
        throw ApiException('Файл повреждён или подменён');
      }
      return;
    }
    final int size = file['size'];
    final parts = max(1, (size + chunk - 1) ~/ chunk);
    Future<Uint8List> fetch(int i) async {
      final start = i * (chunk + 28), length = min(chunk, size - i * chunk) + 28;
      final data = await _downloadPart(file['id'], 'bytes=$start-${start + length - 1}');
      if (data.length != length) throw ApiException('Файл на сервере повреждён');
      return decryptPart(key, i, i == parts - 1, data);
    }

    // До [_parallel] частей качаются одновременно, отдаются по порядку.
    final ahead = <Future<Uint8List>>[];
    for (var next = 0; next < parts || ahead.isNotEmpty;) {
      while (next < parts && ahead.length < _parallel) {
        final f = fetch(next++);
        f.ignore(); // ошибку получит await ниже, а не необработанной в зоне
        ahead.add(f);
      }
      yield await ahead.removeAt(0);
    }
  }

  Future<Uint8List> _downloadPart(String id, [String? range]) async {
    for (var attempt = 1;; attempt++) {
      final http.Response res;
      try {
        res = await http
            .get(_api('/api/files/$id'), headers: {'authorization': 'Bearer $token', 'range': ?range})
            .timeout(const Duration(minutes: 3));
      } catch (e) {
        debugPrint('AURA: скачивание части, попытка $attempt: $e');
        if (attempt == _attempts) throw ApiException('Нет связи с сервером');
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      if (res.statusCode >= 500 && attempt < _attempts) {
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      if (res.statusCode == 404) throw ApiException('Файл удалён с сервера');
      if (res.statusCode != (range == null ? 200 : 206)) throw ApiException('Ошибка сервера');
      return res.bodyBytes;
    }
  }

  void markRead(String peer) {
    lastRead[peer] = DateTime.now().millisecondsSinceEpoch;
    final unread = [
      for (final m in chats[peer] ?? <Message>[])
        if (!m.mine && m.status != Status.read) m..status = Status.read,
    ];
    if (unread.isNotEmpty) _sendReceipt(peer, Status.read, [for (final m in unread) m.id]);
    _save();
  }

  /// Подтверждения «доставлено» и «прочитано» идут собеседнику тем же зашифрованным путём, что и сообщения.
  // ponytail: прочтение на одном своём устройстве не отмечается на других, синхронизировать при необходимости.
  void _sendReceipt(String peer, Status status, List<String> ids) => _serial(() async {
    await _sendCopy(peer, _newId(), {'receipt': status.name, 'ids': ids});
  });

  bool hasUnread(String peer) {
    final last = chats[peer]?.lastOrNull;
    return last != null && !last.mine && last.time > (lastRead[peer] ?? 0);
  }

  Future<void> _serial(Future<void> Function() job) => _queue = _queue.then((_) => job()).catchError((Object e) {
    debugPrint('AURA: $e');
  });

  /// Повторная отправка сообщения, которое сервер не принял.
  void retry(String to, Message m) {
    m.status = Status.pending;
    _save();
    _deliver(to, m);
  }

  /// Превью видео больше этого (символов base64) в сообщение не кладём.
  static const maxThumb = 40 << 10;

  /// Сообщение длиннее этого (символов JSON) после шифрования не пройдёт на сервер (до 500000 символов base64).
  static const maxContent = 350000;

  /// Собеседнику, а затем копия на свои другие устройства, чтобы переписка была видна везде.
  Future<void> _deliver(String to, Message m) => _serial(() async {
    // Старые версии клали крупное превью, и такие сообщения застревали в очереди: шлём без него.
    // В большом альбоме превью убираем с конца, пока сообщение не влезет.
    final thumbs = m.attachments.where((f) => f['thumb'] is String).toList();
    for (final f in thumbs.where((f) => f['thumb'].length > maxThumb).toList()) {
      thumbs.remove(f..remove('thumb'));
      _save();
    }
    while (thumbs.isNotEmpty && jsonEncode(m.content).length > maxContent) {
      thumbs.removeLast().remove('thumb');
      _save();
    }
    if (await _sendCopy(to, m.id, m.content)) await _sendCopy(nick!, m.id, {...m.content, 'peer': to});
  });

  /// Шифрует сообщение для каждого устройства [target]. false — если устройств пока нет.
  Future<bool> _sendCopy(String target, String id, Map<String, dynamic> content) async {
    if (!connected || _keys == null) return false;
    final keys = _keys!;
    final devices = _devices[target] ??= [
      for (final d in await _request('GET', _api('/api/devices/$target'), null) as List)
        if (target != nick || d['device'] != device) d['device'] as int,
    ];
    if (devices.isEmpty) return false;
    final payloads = [];
    for (final d in devices) {
      if (!keys.hasSession(target, d)) {
        await keys.startSession(target, await _request('GET', _api('/api/keys/$target/$d'), null));
      }
      payloads.add(await keys.encrypt(target, d, jsonEncode(content)));
    }
    await _saveKeys();
    _wsSend({'type': 'send', 'id': id, 'to': target, 'payloads': payloads});
    return true;
  }

  Future<void> _receive(Map<String, dynamic> msg) async {
    final String id = msg['id'], from = msg['from'];
    // Дубль (повторная доставка) не расшифровываем второй раз.
    if (!chats.values.any((l) => l.any((m) => m.id == id)) && _keys != null) {
      var peer = from;
      String text;
      Map<String, dynamic>? content, file;
      List<Map<String, dynamic>>? files;
      try {
        content = jsonDecode(await _keys!.decrypt(from, msg['device'], msg['ctype'], msg['body']));
        text = content!['text'] ?? '';
        file = content['file'];
        files = (content['files'] as List?)?.cast();
        if (from == nick) peer = content['peer']; // копия своего сообщения с другого устройства
      } catch (e) {
        debugPrint('AURA: не расшифровано $id от $from: $e');
        text = '⚠ Не удалось расшифровать сообщение';
      }
      await _saveKeys();
      if (content?['receipt'] case final String receipt) {
        _onReceipt(from, Status.values.byName(receipt), (content!['ids'] as List).cast());
      } else if (content?['delete'] case final List ids) {
        _remove(peer, ids.toSet(), fromPeer: from != nick);
      } else {
        final mine = from == nick;
        chats
            .putIfAbsent(peer, () => [])
            .add(
              Message(
                id: id,
                mine: mine,
                text: text,
                time: msg['sentAt'],
                status: mine ? Status.sent : Status.delivered,
                file: file,
                files: files,
              ),
            );
        if (!mine) _sendReceipt(from, Status.delivered, [id]);
      }
      _save();
    }
    _wsSend({'type': 'ack', 'id': id});
  }

  void _connect() {
    _retry?.cancel();
    final ws = WebSocketChannel.connect(Uri.parse(server.replaceFirst('http', 'ws')).replace(path: '/ws'));
    _ws = ws;
    ws.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    ws.stream.listen((raw) => _onMessage(jsonDecode(raw as String)), onDone: () => _onClosed(ws), onError: (_) {});
  }

  /// Статус только растёт: позднее «доставлено» не отменяет «прочитано».
  void _onReceipt(String peer, Status status, List<String> ids) {
    for (final m in chats[peer] ?? <Message>[]) {
      if (m.mine && ids.contains(m.id) && m.status.index < status.index) m.status = status;
    }
  }

  void _onClosed(WebSocketChannel ws) {
    if (_ws != ws) return; // выход из аккаунта или уже переподключились
    connected = false;
    notifyListeners();
    if (ws.closeCode == 4401) {
      logout(); // сессия больше не действует
      return;
    }
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = min(_backoff * 2, 30);
  }

  void _onMessage(Map<String, dynamic> msg) {
    switch (msg['type']) {
      case 'ready':
        connected = true;
        _backoff = 1;
        if ((msg['preKeys'] as int) < SignalKeys.preKeyBatch ~/ 2) _refillPreKeys();
        // Переотправляем то, что не дошло до сервера; сервер отбрасывает дубли по id.
        for (final MapEntry(key: to, value: list) in chats.entries) {
          for (final m in list.where((m) => m.status == Status.pending)) {
            _deliver(to, m);
          }
        }
        _deletes.toList().forEach(_sendDelete);
      case 'sent' when _deletes.any((d) => d['id'] == msg['id']):
        // Удаление у всех готово, когда дошло до собеседника, у себя — когда до своих устройств.
        if (_deletes.any((d) => d['id'] == msg['id'] && (d['everyone'] == true) == (msg['to'] != nick))) {
          _dropDelete(msg['id']);
        }
      case 'sent' when msg['to'] != nick:
        for (final list in chats.values) {
          for (final m in list.where((m) => m.id == msg['id'] && m.status == Status.pending)) {
            m.status = Status.sent;
          }
        }
        _save();
      case 'error' when msg['error'] == 'devices':
        // У получателя появилось или пропало устройство: берём новый список и шифруем заново.
        final String to = msg['to'];
        _devices.remove(to);
        _deletes.where((d) => d['id'] == msg['id']).toList().forEach(_sendDelete);
        for (final MapEntry(key: peer, value: list) in chats.entries) {
          for (final m in list.where((m) => m.id == msg['id'])) {
            if (to == nick) {
              _serial(() async => await _sendCopy(nick!, m.id, {...m.content, 'peer': peer}));
            } else {
              _deliver(peer, m);
            }
          }
        }
      case 'error' when _deletes.any((d) => d['id'] == msg['id']):
        _dropDelete(msg['id']); // сервер не принял уведомление об удалении, повторять бесполезно
      case 'error' when msg['id'] != null && msg['to'] != nick:
        // Сервер отклонил сообщение: «не отправлено», заново по нажатию. Копии на свои устройства не в счёт.
        for (final list in chats.values) {
          for (final m in list.where((m) => m.id == msg['id'] && m.status == Status.pending)) {
            m.status = Status.failed;
          }
        }
        _save();
      case 'message':
        _serial(() => _receive(msg));
    }
    notifyListeners();
  }

  /// Одноразовые prekey расходуются собеседниками, когда те начинают с нами переписку.
  void _refillPreKeys() => _serial(() async {
    final keys = _keys!;
    final preKeys = keys.newPreKeys();
    await _saveKeys(); // сначала сохраняем приватные части, потом публикуем
    await _request('PUT', _api('/api/keys'), {'preKeys': preKeys});
  });

  Future<void> _saveKeys() async {
    if (_keys != null) await _prefs.setString('signal', _keys!.toJson());
  }

  void _wsSend(Map<String, dynamic> msg) {
    if (connected || msg['type'] == 'auth') _ws?.sink.add(jsonEncode(msg));
  }

  void _save() {
    _prefs.setString('chats', jsonEncode({'chats': chats, 'names': names, 'lastRead': lastRead, 'deletes': _deletes}));
    notifyListeners();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final client = AuraClient.instance;

/// Тело запроса кусками по 64 КБ: сокет забирает их по мере отправки, так виден прогресс внутри части.
/// В браузере тело всё равно собирается целиком, там прогресс идёт по частям.
/// Запрос целиком, с отправкой тела, обрывается через 3 минуты: на зависшей сети повтор начнётся,
/// а оборванный запрос не дойдёт до сервера позже повтора.
class _Upload extends http.BaseRequest with http.Abortable {
  _Upload(Uri url, this.body, this.onSent) : super('POST', url) {
    contentLength = body.length;
    timer = Timer(const Duration(minutes: 3), _abort.complete);
  }

  final Uint8List body;
  final void Function(int sent)? onSent;

  final _abort = Completer<void>();
  late final Timer timer;

  @override
  Future<void> get abortTrigger => _abort.future;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(() async* {
      for (var i = 0; i < body.length; i += 64 << 10) {
        final end = min(i + (64 << 10), body.length);
        yield Uint8List.sublistView(body, i, end);
        onSent?.call(end);
      }
    }());
  }
}
