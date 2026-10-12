import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _nickRe = RegExp(r'^[a-z0-9_]{3,32}$');
final _random = Random.secure();

/// Сервер AURA: аккаунты, сессии и доставка сообщений «сохранить и переслать».
/// Сообщение хранится только пока получатель его не подтвердил, затем удаляется.
class AuraServer {
  AuraServer(String dbPath) : db = sqlite3.open(dbPath) {
    db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS users (
        nick TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        nick TEXT NOT NULL REFERENCES users(nick) ON DELETE CASCADE,
        created_at INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        sender TEXT NOT NULL REFERENCES users(nick) ON DELETE CASCADE,
        recipient TEXT NOT NULL REFERENCES users(nick) ON DELETE CASCADE,
        body TEXT NOT NULL,
        sent_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS messages_recipient ON messages(recipient, sent_at);
    ''');
  }

  final Database db;

  /// Открытые WebSocket-соединения по никнейму (несколько устройств на аккаунт).
  final _online = <String, Set<WebSocketChannel>>{};

  Handler get handler {
    final api = Router()
      ..post('/api/register', _register)
      ..post('/api/login', _login)
      ..get('/api/users', _authed(_searchUsers))
      ..put('/api/me', _authed(_updateMe))
      ..get('/ws', webSocketHandler(_onSocket, pingInterval: const Duration(seconds: 30)));
    return api.call;
  }

  void close() => db.close();

  // --- HTTP ---

  Future<Response> _register(Request req) async {
    final body = await _json(req);
    final nick = (body['nick'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';
    final name = (body['name'] as String? ?? '').trim();
    if (!_nickRe.hasMatch(nick)) return _error(400, 'Никнейм: 3–32 символа, латиница, цифры и _');
    if (password.length < 6) return _error(400, 'Пароль должен быть не короче 6 символов');
    final hash = await Isolate.run(() => hashPassword(password));
    // Проверка и вставка без await между ними, поэтому гонки двух регистраций нет.
    if (db.select('SELECT 1 FROM users WHERE nick = ?', [nick]).isNotEmpty) {
      return _error(409, 'Этот никнейм уже занят');
    }
    db.execute('INSERT INTO users VALUES (?, ?, ?, ?)', [nick, name.isEmpty ? nick : name, hash, _now()]);
    return _session(nick);
  }

  Future<Response> _login(Request req) async {
    final body = await _json(req);
    final nick = (body['nick'] as String? ?? '').trim().toLowerCase();
    final row = db.select('SELECT password_hash FROM users WHERE nick = ?', [nick]).firstOrNull;
    final password = body['password'] as String? ?? '';
    final stored = row?['password_hash'] as String?;
    // Хеширование в отдельном изоляте, чтобы не тормозить доставку сообщений.
    // ponytail: нет ограничения попыток входа, добавить при открытой регистрации.
    if (stored == null || !await Isolate.run(() => verifyPassword(password, stored))) {
      return _error(401, 'Неверный никнейм или пароль');
    }
    return _session(nick);
  }

  Response _searchUsers(Request req, String me) {
    final q = (req.url.queryParameters['q'] ?? '').trim().toLowerCase();
    // Экранируем % и _ — в никнеймах _ обычный символ.
    final pattern = '%${q.replaceAllMapped(RegExp(r'[%_\\]'), (m) => '\\${m[0]}')}%';
    final rows = db.select(
      r"SELECT nick, name FROM users WHERE nick != ? AND (nick LIKE ? ESCAPE '\' OR name LIKE ? ESCAPE '\') ORDER BY nick LIMIT 50",
      [me, pattern, pattern],
    );
    return _ok([
      for (final r in rows) {'nick': r['nick'], 'name': r['name']},
    ]);
  }

  Future<Response> _updateMe(Request req, String me) async {
    final name = ((await _json(req))['name'] as String? ?? '').trim();
    if (name.isEmpty || name.length > 64) return _error(400, 'Введите имя');
    db.execute('UPDATE users SET name = ? WHERE nick = ?', [name, me]);
    return _ok({'nick': me, 'name': name});
  }

  Response _session(String nick) {
    final token = base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));
    db.execute('INSERT INTO sessions VALUES (?, ?, ?)', [_sha(token), nick, _now()]);
    final name = db.select('SELECT name FROM users WHERE nick = ?', [nick]).first['name'];
    return _ok({'token': token, 'nick': nick, 'name': name});
  }

  String? _userFor(String? token) => token == null
      ? null
      : db.select('SELECT nick FROM sessions WHERE token_hash = ?', [_sha(token)]).firstOrNull?['nick'] as String?;

  Handler _authed(FutureOr<Response> Function(Request, String nick) h) => (req) {
    final auth = req.headers['authorization'];
    final nick = _userFor(auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null);
    return nick == null ? _error(401, 'Нужно войти') : h(req, nick);
  };

  // --- WebSocket ---
  // Клиент → сервер: {type: auth, token}, {type: send, id, to, text}, {type: ack, id}
  // Сервер → клиент: {type: ready}, {type: sent, id}, {type: message, id, from, text, sentAt}, {type: error, id?, error}

  void _onSocket(WebSocketChannel ws, String? _) {
    String? me;
    ws.stream.listen(
      (raw) {
        final Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (_) {
          ws.sink.close(4400, 'bad json');
          return;
        }
        if (me == null) {
          final token = msg['token'];
          me = msg['type'] == 'auth' && token is String ? _userFor(token) : null;
          if (me == null) {
            ws.sink.close(4401, 'unauthorized');
            return;
          }
          _online.putIfAbsent(me!, () => {}).add(ws);
          ws.sink.add(jsonEncode({'type': 'ready'}));
          _flush(me!, ws);
          return;
        }
        switch (msg['type']) {
          case 'send':
            _send(me!, ws, msg);
          case 'ack' when msg['id'] is String:
            db.execute('DELETE FROM messages WHERE id = ? AND recipient = ?', [msg['id'], me]);
        }
      },
      onDone: () {
        if (me == null) return;
        _online[me]?.remove(ws);
        if (_online[me]?.isEmpty ?? false) _online.remove(me);
      },
    );
  }

  void _send(String me, WebSocketChannel ws, Map<String, dynamic> msg) {
    final id = msg['id'], to = msg['to'], text = msg['text'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        to is! String ||
        text is! String ||
        text.isEmpty ||
        text.length > 64000) {
      return ws.sink.add(jsonEncode({'type': 'error', 'id': id, 'error': 'Некорректное сообщение'}));
    }
    if (db.select('SELECT 1 FROM users WHERE nick = ?', [to]).isEmpty) {
      return ws.sink.add(jsonEncode({'type': 'error', 'id': id, 'error': 'Пользователь не найден'}));
    }
    final sentAt = _now();
    // Повтор того же id (переотправка после обрыва связи) не создаёт дубль.
    db.execute('INSERT OR IGNORE INTO messages VALUES (?, ?, ?, ?, ?)', [id, me, to, text, sentAt]);
    ws.sink.add(jsonEncode({'type': 'sent', 'id': id}));
    final out = jsonEncode({'type': 'message', 'id': id, 'from': me, 'text': text, 'sentAt': sentAt});
    for (final s in _online[to] ?? const <WebSocketChannel>{}) {
      s.sink.add(out);
    }
  }

  void _flush(String me, WebSocketChannel ws) {
    final rows = db.select('SELECT id, sender, body, sent_at FROM messages WHERE recipient = ? ORDER BY sent_at', [me]);
    for (final r in rows) {
      ws.sink.add(
        jsonEncode({'type': 'message', 'id': r['id'], 'from': r['sender'], 'text': r['body'], 'sentAt': r['sent_at']}),
      );
    }
  }
}

// --- Пароли: PBKDF2-HMAC-SHA256 ---

const _iterations = 210000;

String hashPassword(String password) {
  final salt = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
  return '$_iterations:${base64.encode(salt)}:${base64.encode(_pbkdf2(password, salt, _iterations))}';
}

bool verifyPassword(String password, String stored) {
  final [iter, salt, hash] = stored.split(':');
  final expected = base64.decode(hash);
  final actual = _pbkdf2(password, base64.decode(salt), int.parse(iter));
  var diff = 0; // сравнение за постоянное время
  for (var i = 0; i < expected.length; i++) {
    diff |= expected[i] ^ actual[i];
  }
  return diff == 0;
}

List<int> _pbkdf2(String password, List<int> salt, int iterations) {
  // Один блок: длина ключа = 32 байта = выход SHA-256.
  final hmac = Hmac(sha256, utf8.encode(password));
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = List<int>.of(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

// --- Утилиты ---

String _sha(String s) => sha256.convert(utf8.encode(s)).toString();
int _now() => DateTime.now().millisecondsSinceEpoch;

Future<Map<String, dynamic>> _json(Request req) async {
  try {
    return jsonDecode(await req.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

Response _ok(Object body) => Response.ok(jsonEncode(body), headers: {'content-type': 'application/json'});
Response _error(int status, String message) =>
    Response(status, body: jsonEncode({'error': message}), headers: {'content-type': 'application/json'});
