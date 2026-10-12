import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class Message {
  Message({required this.id, required this.mine, required this.text, required this.time, this.pending = false});

  final String id, text;
  final bool mine;
  final int time; // мс с эпохи
  bool pending;

  Map<String, dynamic> toJson() => {'id': id, 'mine': mine, 'text': text, 'time': time, 'pending': pending};
  factory Message.fromJson(Map<String, dynamic> j) =>
      Message(id: j['id'], mine: j['mine'], text: j['text'], time: j['time'], pending: j['pending'] ?? false);
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Связь с сервером AURA и локальная история переписки.
/// Сервер хранит сообщение только до доставки, история живёт на устройстве.
// ponytail: история в SharedPreferences (JSON на собеседника), перейти на базу на устройстве, когда чаты станут длинными.
class AuraClient extends ChangeNotifier {
  AuraClient._();
  static final instance = AuraClient._();

  late SharedPreferences _prefs;
  String? server, token, nick, name;

  /// Переписка по никнейму собеседника.
  final chats = <String, List<Message>>{};

  /// Отображаемые имена собеседников.
  final names = <String, String>{};

  /// Время последнего прочтения чата.
  final lastRead = <String, int>{};

  bool connected = false;
  WebSocketChannel? _ws;
  Timer? _retry;
  int _backoff = 1;

  bool get signedIn => token != null;

  /// Адрес сервера по умолчанию: в Web это сайт, с которого открыто приложение.
  static String get defaultServer => kIsWeb ? Uri.base.origin : '';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    server = _prefs.getString('server');
    token = _prefs.getString('token');
    nick = _prefs.getString('nick');
    name = _prefs.getString('name');
    final raw = _prefs.getString('chats');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (j['chats'] as Map<String, dynamic>).entries) {
        chats[key] = [for (final m in value as List) Message.fromJson(m)];
      }
      names.addAll((j['names'] as Map<String, dynamic>).cast());
      lastRead.addAll((j['lastRead'] as Map<String, dynamic>).cast());
    }
    if (signedIn) _connect();
  }

  // --- Аккаунт ---

  Future<void> register(String server, String nick, String password) =>
      _auth(server, '/api/register', {'nick': nick, 'password': password});

  Future<void> login(String server, String nick, String password) =>
      _auth(server, '/api/login', {'nick': nick, 'password': password});

  Future<void> _auth(String server, String path, Map body) async {
    server = server.trim().replaceAll(RegExp(r'/+$'), '');
    if (!server.startsWith('http')) server = 'https://$server';
    final res = await _request('POST', Uri.parse('$server$path'), body);
    this.server = server;
    token = res['token'];
    nick = res['nick'];
    name = res['name'];
    await _prefs.setString('server', server);
    await _prefs.setString('token', token!);
    await _prefs.setString('nick', nick!);
    await _prefs.setString('name', name!);
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

  Future<void> logout() async {
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    await ws?.sink.close();
    token = nick = name = null;
    connected = false;
    chats.clear();
    names.clear();
    lastRead.clear();
    // Адрес сервера оставляем, чтобы не вводить его заново.
    for (final k in ['token', 'nick', 'name', 'chats']) {
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
    final m = Message(id: _newId(), mine: true, text: text, time: DateTime.now().millisecondsSinceEpoch, pending: true);
    chats.putIfAbsent(to, () => []).add(m);
    _save();
    _wsSend({'type': 'send', 'id': m.id, 'to': to, 'text': text});
  }

  void markRead(String peer) {
    lastRead[peer] = DateTime.now().millisecondsSinceEpoch;
    _save();
  }

  bool hasUnread(String peer) {
    final last = chats[peer]?.lastOrNull;
    return last != null && !last.mine && last.time > (lastRead[peer] ?? 0);
  }

  void _connect() {
    _retry?.cancel();
    final ws = WebSocketChannel.connect(Uri.parse(server!.replaceFirst('http', 'ws')).replace(path: '/ws'));
    _ws = ws;
    ws.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    ws.stream.listen(
      (raw) => _onMessage(jsonDecode(raw as String)),
      onDone: () => _onClosed(ws),
      onError: (_) {},
    );
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
        // Переотправляем то, что не дошло до сервера; сервер отбрасывает дубли по id.
        for (final MapEntry(key: to, value: list) in chats.entries) {
          for (final m in list.where((m) => m.pending)) {
            _wsSend({'type': 'send', 'id': m.id, 'to': to, 'text': m.text});
          }
        }
      case 'sent':
        for (final list in chats.values) {
          for (final m in list.where((m) => m.id == msg['id'])) {
            m.pending = false;
          }
        }
        _save();
      case 'message':
        final list = chats.putIfAbsent(msg['from'], () => []);
        if (!list.any((m) => m.id == msg['id'])) {
          list.add(Message(id: msg['id'], mine: false, text: msg['text'], time: msg['sentAt']));
          _save();
        }
        _wsSend({'type': 'ack', 'id': msg['id']});
    }
    notifyListeners();
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
