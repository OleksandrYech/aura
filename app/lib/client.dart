import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'signal.dart';

/// Статус сообщения. Свои: в очереди → отправлено → доставлено → прочитано.
/// Входящие: получено → прочитано (собеседнику ушло подтверждение о прочтении).
enum Status { pending, sent, delivered, read }

class Message {
  Message({required this.id, required this.mine, required this.text, required this.time, required this.status});

  final String id, text;
  final bool mine;
  final int time; // мс с эпохи
  Status status;

  Map<String, dynamic> toJson() => {'id': id, 'mine': mine, 'text': text, 'time': time, 'status': status.name};
  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'],
    mine: j['mine'],
    text: j['text'],
    time: j['time'],
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
    names.clear();
    lastRead.clear();
    _devices.clear();
    // Адрес сервера оставляем, чтобы не вводить его заново.
    for (final k in ['token', 'nick', 'name', 'device', 'signal', 'chats']) {
      await _prefs.remove(k);
    }
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

  void send(String to, String text) {
    final m = Message(id: _newId(), mine: true, text: text, time: DateTime.now().millisecondsSinceEpoch, status: Status.pending);
    chats.putIfAbsent(to, () => []).add(m);
    _save();
    _deliver(to, m);
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

  /// Собеседнику, а затем копия на свои другие устройства, чтобы переписка была видна везде.
  Future<void> _deliver(String to, Message m) => _serial(() async {
    if (await _sendCopy(to, m.id, {'text': m.text})) await _sendCopy(nick!, m.id, {'text': m.text, 'peer': to});
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
      Map<String, dynamic>? content;
      try {
        content = jsonDecode(await _keys!.decrypt(from, msg['device'], msg['ctype'], msg['body']));
        text = content!['text'] ?? '';
        if (from == nick) peer = content['peer']; // копия своего сообщения с другого устройства
      } catch (e) {
        debugPrint('AURA: не расшифровано $id от $from: $e');
        text = '⚠ Не удалось расшифровать сообщение';
      }
      await _saveKeys();
      if (content?['receipt'] case final String receipt) {
        _onReceipt(from, Status.values.byName(receipt), (content!['ids'] as List).cast());
      } else {
        final mine = from == nick;
        chats
            .putIfAbsent(peer, () => [])
            .add(Message(id: id, mine: mine, text: text, time: msg['sentAt'], status: mine ? Status.sent : Status.delivered));
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
        for (final MapEntry(key: peer, value: list) in chats.entries) {
          for (final m in list.where((m) => m.id == msg['id'])) {
            if (to == nick) {
              _serial(() async => await _sendCopy(nick!, m.id, {'text': m.text, 'peer': peer}));
            } else {
              _deliver(peer, m);
            }
          }
        }
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
    _prefs.setString('chats', jsonEncode({'chats': chats, 'names': names, 'lastRead': lastRead}));
    notifyListeners();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final client = AuraClient.instance;
