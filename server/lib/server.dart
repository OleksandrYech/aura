import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _nickRe = RegExp(r'^[a-z0-9_]{3,32}$');
final _random = Random.secure();

typedef Device = ({String nick, int device});

/// Сервер AURA: аккаунты, устройства, публичные ключи и доставка зашифрованных сообщений
/// «сохранить и переслать». Открытого текста сервер не видит: у каждого устройства свои ключи
/// Signal Protocol, отправитель шифрует сообщение отдельно для каждого устройства получателя.
/// Сообщение хранится только пока устройство его не подтвердило, затем удаляется.
/// Файлы клиент шифрует сам случайным ключом и отправляет ключ внутри сообщения: сервер хранит
/// только зашифрованные байты в [files] и удаляет их через [fileDays] дней.
class AuraServer {
  /// [turn] — адрес TURN-сервера (например turn:aura-msg.space:3478) и общий с coturn секрет
  /// (static-auth-secret): звонки, которым не хватило прямого соединения, идут через него.
  /// [push] — отправка push на устройство (см. Fcm); false — токен устарел.
  /// [linkTtl] — сколько живёт конверт привязки (см. [_postLink]).
  AuraServer(String dbPath, {String? files, this.turn, this.push, this.linkTtl = const Duration(minutes: 10)})
    : db = sqlite3.open(dbPath),
      files = Directory(files ?? p.join(p.dirname(dbPath), 'files'))..createSync(recursive: true) {
    db.execute('''
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS users (
        nick TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        next_device INTEGER NOT NULL DEFAULT 1
      ) STRICT;
    ''');
    if (db.select('PRAGMA user_version').first.values.first == 0) {
      // Этап 3: сессии стали устройствами с ключами, очередь с открытым текстом удаляется,
      // всем нужно войти заново.
      db.execute('DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS sessions;');
      if (!db.select('PRAGMA table_info(users)').any((c) => c['name'] == 'next_device')) {
        db.execute('ALTER TABLE users ADD COLUMN next_device INTEGER NOT NULL DEFAULT 1');
      }
    }
    db.execute('''
      PRAGMA user_version = 1;
      CREATE TABLE IF NOT EXISTS devices (
        token_hash TEXT PRIMARY KEY,
        nick TEXT NOT NULL REFERENCES users(nick) ON DELETE CASCADE,
        device INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        registration_id INTEGER,
        identity_key TEXT,
        signed_prekey_id INTEGER,
        signed_prekey TEXT,
        signed_prekey_sig TEXT,
        UNIQUE (nick, device)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS prekeys (
        nick TEXT NOT NULL,
        device INTEGER NOT NULL,
        key_id INTEGER NOT NULL,
        public_key TEXT NOT NULL,
        PRIMARY KEY (nick, device, key_id),
        FOREIGN KEY (nick, device) REFERENCES devices(nick, device) ON DELETE CASCADE
      ) STRICT;
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT NOT NULL,
        sender TEXT NOT NULL,
        sender_device INTEGER NOT NULL,
        recipient TEXT NOT NULL,
        recipient_device INTEGER NOT NULL,
        type INTEGER NOT NULL,
        body TEXT NOT NULL,
        sent_at INTEGER NOT NULL,
        PRIMARY KEY (id, recipient, recipient_device),
        FOREIGN KEY (recipient, recipient_device) REFERENCES devices(nick, device) ON DELETE CASCADE
      ) STRICT;
      CREATE INDEX IF NOT EXISTS messages_recipient ON messages(recipient, recipient_device, sent_at);
      CREATE INDEX IF NOT EXISTS messages_sender ON messages(recipient, recipient_device, sender);
      CREATE TABLE IF NOT EXISTS files (
        id TEXT PRIMARY KEY,
        nick TEXT NOT NULL
      ) STRICT;
    ''');
    if (!db.select('PRAGMA table_info(devices)').any((c) => c['name'] == 'push_token')) {
      db.execute('ALTER TABLE devices ADD COLUMN push_token TEXT');
    }
    if (!db.select('PRAGMA table_info(users)').any((c) => c['name'] == 'identity_key')) {
      // Ключ аккаунта: у старых аккаунтов берём ключ самого старого устройства.
      db.execute('''
        ALTER TABLE users ADD COLUMN identity_key TEXT;
        UPDATE users SET identity_key = (SELECT identity_key FROM devices d
          WHERE d.nick = users.nick AND d.identity_key IS NOT NULL ORDER BY d.device LIMIT 1);
      ''');
    }
  }

  final Database db;
  final Directory files;

  /// Больше за один запрос не принимаем: через Cloudflare всё равно пролезает не больше 100 МБ.
  /// Клиенты шлют части по 8 МБ, 25 МБ остаётся для старых версий, грузивших файл целиком.
  static const maxRequest = 25 << 20;
  static const maxFile = (2 << 30) + (1 << 20); // 2 ГБ плюс запас на заголовки частей
  static const fileDays = 30;

  /// Шифротекст одного сообщения для одного устройства, символов base64: хватает на альбом из 10 видео с превью.
  static const maxMessage = 500000;

  /// Тело JSON-запроса: ключи и списки id занимают десятки КБ (A01).
  static const maxJson = 64 << 10;

  /// Кадр WebSocket до входа и после: сообщение с шифротекстом для 32 устройств (A11).
  static const maxAuthFrame = 4 << 10, maxFrame = 32 * maxMessage + (64 << 10);

  /// Код закрытия WebSocket при слишком большом кадре. Стандартный 1009 библиотека отправить не даёт.
  static const tooBig = 4413;

  /// Сколько ждать {type: auth} от нового соединения (A12).
  static const authTimeout = Duration(seconds: 5);

  /// Очередь одного отправителя к одному устройству, символов: больше не принимаем, пока не заберут (A15).
  static const maxQueue = 10 << 20;

  /// Неудачных входов на ник за [loginWindow], после — 429 (A03).
  static const maxLogins = 5, loginWindow = Duration(minutes: 15);

  /// Push «звонок» от одного отправителя одному получателю, больше — без push (A16).
  static const maxCalls = 3, callWindow = Duration(minutes: 1);

  /// Файлы, которые сейчас догружаются частями, и устройство, которое их грузит.
  // ponytail: в памяти, после перезапуска сервера незаконченную загрузку придётся начать заново.
  final _growing = <String, Device>{};

  /// Недавно законченные загрузки и их устройства: повтор последней части, ответ на которую
  /// не дошёл, должен получить id, а не 404.
  // ponytail: последние 1000 на весь сервер, держать по устройству, если повторы начнут теряться.
  final _finished = <String, Device>{};

  /// Загрузки, для которых клиент сразу назвал итоговый размер: части идут параллельно и каждая
  /// пишется на своё место. Запись держится и после конца загрузки, пока id есть в [_finished].
  final _sized = <String, _Sized>{};

  /// Конверты привязки по новому устройству и новые устройства, которые их ждут.
  // ponytail: в памяти, после перезапуска сервера привязку придётся начать заново.
  final _links = <Device, ({String envelope, Timer expiry})>{};
  final _linkWaiters = <Device, Completer<String?>>{};
  final Duration linkTtl;
  static const maxLink = 16 << 10;
  static const maxPendingLinks = 3;

  /// Открытые WebSocket-соединения по устройству.
  final _online = <Device, WebSocketChannel>{};

  /// События по ключу за окно: неудачные входы и push-звонки.
  // ponytail: в памяти, после перезапуска сервера счётчики обнуляются.
  final _hits = <String, List<int>>{};

  /// Не больше [max] событий по [key] за [window]?
  bool _over(String key, int max, Duration window) {
    final since = _now() - window.inMilliseconds;
    final list = _hits[key]?..removeWhere((t) => t < since);
    if (list != null && list.isEmpty) _hits.remove(key);
    return (list?.length ?? 0) >= max;
  }

  void _hit(String key) {
    // Мусорные ключи (входы в несуществующие ники) не копятся: изредка чистим всё.
    if (_hits.length > 10000) _hits.removeWhere((k, v) => !_over(k, 1, preKeyWindow));
    _hits.putIfAbsent(key, () => []).add(_now());
  }

  Handler get handler {
    final api = Router()
      ..post('/api/register', _register)
      ..post('/api/login', _login)
      ..post('/api/logout', _authed(_logout))
      ..get('/api/users', _authed(_searchUsers))
      ..put('/api/me', _authed(_updateMe))
      ..put('/api/keys', _authed(_putKeys))
      ..get('/api/devices/<nick>', _authed(_devices))
      ..get('/api/ice', _authed(_ice))
      ..put('/api/push', _authed(_putPush))
      ..post('/api/link/<device>', _authed(_postLink))
      ..get('/api/link', _authed(_getLink))
      ..get('/api/keys/<nick>/<device>', _authed(_bundle))
      ..post('/api/files', _authed(_upload))
      ..post('/api/files/<id>', _authed(_append))
      ..get('/api/files/<id>', _authed(_download))
      ..post('/api/unsend', _authed(_unsend))
      ..get('/ws', webSocketHandler(_onSocket, pingInterval: const Duration(seconds: 30)));
    return (req) async {
      try {
        return await api(req);
      } on _TooLarge {
        return _error(413, 'Слишком большой запрос');
      } on TypeError {
        // Поле не того типа ('nick': 123) — ошибка клиента, а не сервера (A02).
        return _error(400, 'Некорректный запрос');
      }
    };
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
    if (name.length > 64) return _error(400, 'Имя длиннее 64 символов');
    final hash = await Isolate.run(() => hashPassword(password));
    // Проверка и вставка без await между ними, поэтому гонки двух регистраций нет.
    if (db.select('SELECT 1 FROM users WHERE nick = ?', [nick]).isNotEmpty) {
      return _error(409, 'Этот никнейм уже занят');
    }
    db.execute('INSERT INTO users (nick, name, password_hash, created_at) VALUES (?, ?, ?, ?)', [
      nick,
      name.isEmpty ? nick : name,
      hash,
      _now(),
    ]);
    return _session(nick);
  }

  Future<Response> _login(Request req) async {
    final body = await _json(req);
    // Не строка — просто неверный вход, а не 400: ответ не должен отличаться от обычной ошибки.
    final nick = (body['nick'] is String ? body['nick'] as String : '').trim().toLowerCase();
    // Перебор пароля: после серии ошибок ник закрыт на время, даже для верного пароля.
    // ponytail: только по нику, поэтому злоумышленник может так закрыть чужой ник на 15 минут; добавить счёт по IP за прокси.
    if (_over('login:$nick', maxLogins, loginWindow)) return _error(429, 'Слишком много попыток, попробуйте позже');
    final row = db.select('SELECT password_hash FROM users WHERE nick = ?', [nick]).firstOrNull;
    final password = body['password'] is String ? body['password'] as String : '';
    final stored = row?['password_hash'] as String?;
    // Хеширование в отдельном изоляте, чтобы не тормозить доставку сообщений.
    if (stored == null || !await Isolate.run(() => verifyPassword(password, stored))) {
      _hit('login:$nick');
      return _error(401, 'Неверный никнейм или пароль');
    }
    _hits.remove('login:$nick');
    return _session(nick);
  }

  /// Найти можно только по точному никнейму: список всех пользователей не раскрывается.
  Response _searchUsers(Request req, Device me) {
    final q = (req.url.queryParameters['q'] ?? '').trim().toLowerCase();
    final rows = db.select('SELECT nick, name FROM users WHERE nick = ? AND nick != ?', [q, me.nick]);
    return _ok([
      for (final r in rows) {'nick': r['nick'], 'name': r['name']},
    ]);
  }

  Future<Response> _updateMe(Request req, Device me) async {
    final name = ((await _json(req))['name'] as String? ?? '').trim();
    if (name.isEmpty || name.length > 64) return _error(400, 'Введите имя');
    db.execute('UPDATE users SET name = ? WHERE nick = ?', [name, me.nick]);
    return _ok({'nick': me.nick, 'name': name});
  }

  /// Каждый вход создаёт новое устройство. Номера устройств не повторяются,
  /// поэтому ключ на одном адресе «ник:устройство» никогда не меняется.
  Response _session(String nick) {
    final token = base64Url.encode(List.generate(32, (_) => _random.nextInt(256)));
    final user = db.select(
      'UPDATE users SET next_device = next_device + 1 WHERE nick = ? RETURNING name, identity_key, next_device - 1 AS device',
      [nick],
    ).first;
    db.execute('INSERT INTO devices (token_hash, nick, device, created_at) VALUES (?, ?, ?, ?)', [
      _sha(token),
      nick,
      user['device'],
      _now(),
    ]);
    return _ok({
      'token': token,
      'nick': nick,
      'name': user['name'],
      'device': user['device'],
      'identityKey': user['identity_key'],
    });
  }

  Response _logout(Request req, Device me) {
    _online.remove(me)?.sink.close(4401, 'logout');
    db.execute('DELETE FROM devices WHERE nick = ? AND device = ?', [me.nick, me.device]);
    return _ok({});
  }

  // --- Ключи Signal Protocol (только публичные части) ---

  /// {registrationId, identityKey, signedPreKey: {id, key, signature}, preKeys: [{id, key}]}.
  /// Ключ личности задаётся один раз, остальное можно обновлять и пополнять.
  Future<Response> _putKeys(Request req, Device me) async {
    final body = await _json(req);
    final identity = body['identityKey'], reg = body['registrationId'], spk = body['signedPreKey'];
    final preKeys = body['preKeys'] ?? [];
    bool key(Object? k) => k is String && k.isNotEmpty && k.length <= 200;
    if ((identity != null && !key(identity)) ||
        (identity != null && reg is! int) ||
        (spk != null && (spk is! Map || spk['id'] is! int || !key(spk['key']) || !key(spk['signature']))) ||
        preKeys is! List ||
        preKeys.length > 200 ||
        preKeys.any((p) => p is! Map || p['id'] is! int || !key(p['key']))) {
      return _error(400, 'Некорректные ключи');
    }
    if (_preKeyCount(me) + preKeys.length > maxPreKeys) return _error(400, 'Слишком много одноразовых ключей');
    final current = db.select('SELECT identity_key FROM devices WHERE nick = ? AND device = ?', [
      me.nick,
      me.device,
    ]).first;
    if (identity != null) {
      if (current['identity_key'] != null && current['identity_key'] != identity) {
        return _error(409, 'Ключ устройства уже задан');
      }
      db.execute('UPDATE devices SET identity_key = ?, registration_id = ? WHERE nick = ? AND device = ?', [
        identity,
        reg,
        me.nick,
        me.device,
      ]);
      // Первое устройство с ключом задаёт ключ аккаунта. Проверок пока нет (план: PR 6).
      db.execute('UPDATE users SET identity_key = ? WHERE nick = ? AND identity_key IS NULL', [identity, me.nick]);
    }
    if (spk is Map) {
      db.execute(
        'UPDATE devices SET signed_prekey_id = ?, signed_prekey = ?, signed_prekey_sig = ? WHERE nick = ? AND device = ?',
        [spk['id'], spk['key'], spk['signature'], me.nick, me.device],
      );
    }
    for (final p in preKeys) {
      db.execute('INSERT OR REPLACE INTO prekeys VALUES (?, ?, ?, ?)', [me.nick, me.device, p['id'], p['key']]);
    }
    return _ok({'preKeys': _preKeyCount(me)});
  }

  int _preKeyCount(Device d) =>
      db.select('SELECT count(*) AS n FROM prekeys WHERE nick = ? AND device = ?', [d.nick, d.device]).first['n']
          as int;

  /// Устройства собеседника, готовые принимать сообщения (с ключами).
  List<Row> _readyDevices(String nick) => db.select(
    'SELECT device, identity_key FROM devices WHERE nick = ? AND identity_key IS NOT NULL AND signed_prekey IS NOT NULL ORDER BY device',
    [nick],
  );

  final ({String url, String secret})? turn;

  final Future<bool> Function(String token, String kind)? push;

  /// {token}: токен Firebase этого устройства, null — не будить.
  Future<Response> _putPush(Request req, Device me) async {
    final token = (await _json(req))['token'];
    if (token != null && (token is! String || token.isEmpty || token.length > 4096)) {
      return _error(400, 'Некорректный токен');
    }
    db.execute('UPDATE devices SET push_token = ? WHERE nick = ? AND device = ?', [token, me.nick, me.device]);
    return _ok({});
  }

  /// Будит устройство через push. Ошибки сети не мешают доставке: сообщение ждёт в очереди.
  void _wake(Device d, String kind) {
    final push = this.push;
    if (push == null) return;
    final token = db.select('SELECT push_token FROM devices WHERE nick = ? AND device = ?', [d.nick, d.device])
        .firstOrNull?['push_token'];
    if (token is! String) return;
    push(token, kind).then((ok) {
      if (!ok) db.execute('UPDATE devices SET push_token = NULL WHERE push_token = ?', [token]);
    }, onError: (Object e) => print('push ${d.nick}:${d.device}: $e'));
  }

  /// Серверы для установки звонка. Пароль TURN временный (схема TURN REST API у coturn):
  /// имя — срок действия и ник, пароль — HMAC-SHA1 имени на общем секрете.
  Response _ice(Request req, Device me) {
    final turn = this.turn;
    final user = '${DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000}:${me.nick}';
    return _ok([
      {'urls': 'stun:stun.l.google.com:19302'},
      if (turn != null)
        {
          'urls': turn.url,
          'username': user,
          'credential': base64.encode(Hmac(sha1, utf8.encode(turn.secret)).convert(utf8.encode(user)).bytes),
        },
    ]);
  }

  /// accountKey — ключ аккаунта, одинаковый во всех записях: список остаётся списком для старых клиентов.
  Response _devices(Request req, Device me, String nick) {
    final account = db.select('SELECT identity_key FROM users WHERE nick = ?', [nick.toLowerCase()]).firstOrNull;
    return _ok([
      for (final r in _readyDevices(nick.toLowerCase()))
        {'device': r['device'], 'identityKey': r['identity_key'], 'accountKey': account?['identity_key']},
    ]);
  }

  /// Одноразовых prekey на устройство: клиент держит пачку в 50, запас на пополнения (A05).
  static const maxPreKeys = 1000;

  /// Одноразовый prekey одному собеседнику для одного устройства — не чаще раза в [preKeyWindow] (A06).
  static const preKeyWindow = Duration(hours: 1);

  /// Набор ключей для X3DH. Одноразовый prekey выдаётся один раз и удаляется.
  /// Повторный запрос того же собеседника получает набор без него: X3DH работает и так,
  /// а посторонний не может быстро израсходовать все одноразовые ключи жертвы.
  Response _bundle(Request req, Device me, String nick, String device) {
    final d = db.select(
      'SELECT * FROM devices WHERE nick = ? AND device = ? AND identity_key IS NOT NULL AND signed_prekey IS NOT NULL',
      [nick.toLowerCase(), int.tryParse(device)],
    ).firstOrNull;
    if (d == null) return _error(404, 'Устройство не найдено');
    final asked = 'prekey:${me.nick}>${d['nick']}:${d['device']}';
    final fresh = !_over(asked, 1, preKeyWindow);
    if (fresh) _hit(asked);
    final pk = !fresh ? null : db.select(
      'DELETE FROM prekeys WHERE rowid = (SELECT rowid FROM prekeys WHERE nick = ? AND device = ? LIMIT 1) RETURNING key_id, public_key',
      [d['nick'], d['device']],
    ).firstOrNull;
    return _ok({
      'device': d['device'],
      'registrationId': d['registration_id'],
      'identityKey': d['identity_key'],
      'signedPreKey': {'id': d['signed_prekey_id'], 'key': d['signed_prekey'], 'signature': d['signed_prekey_sig']},
      'preKey': pk == null ? null : {'id': pk['key_id'], 'key': pk['public_key']},
    });
  }

  // --- Привязка устройства ---

  /// {envelope}: старое устройство с ключом передаёт конверт привязки (зашифрованный ключ аккаунта)
  /// новому устройству [device] своего аккаунта, у которого ключа ещё нет. Сервер только пересылает его.
  Future<Response> _postLink(Request req, Device me, String device) async {
    final to = (nick: me.nick, device: int.tryParse(device) ?? 0);
    final envelope = (await _json(req))['envelope'];
    if (envelope is! String || envelope.isEmpty || envelope.length > maxLink) {
      return _error(400, 'Некорректный конверт');
    }
    Row? row(Device d) =>
        db.select('SELECT identity_key FROM devices WHERE nick = ? AND device = ?', [d.nick, d.device]).firstOrNull;
    final target = row(to);
    if (target == null || target['identity_key'] != null || row(me)?['identity_key'] == null) {
      return _error(403, 'Привязать можно только новое устройство своего аккаунта');
    }
    if (_links.containsKey(to)) return _error(409, 'Конверт уже отправлен');
    if (_links.keys.where((d) => d.nick == me.nick).length >= maxPendingLinks) {
      return _error(429, 'Слишком много ожидающих привязок');
    }
    if (_linkWaiters.remove(to) case final waiter?) {
      waiter.complete(envelope);
    } else {
      _links[to] = (envelope: envelope, expiry: Timer(linkTtl, () => _links.remove(to)));
    }
    return _ok({});
  }

  /// Новое устройство забирает свой конверт, ожидая его до 25 секунд (не дольше [linkTtl]).
  Future<Response> _getLink(Request req, Device me) async {
    if (_links.remove(me) case final ready?) {
      ready.expiry.cancel();
      return _ok({'envelope': ready.envelope});
    }
    const most = Duration(seconds: 25);
    final waiter = _linkWaiters.putIfAbsent(me, Completer.new);
    final envelope = await waiter.future.timeout(linkTtl < most ? linkTtl : most, onTimeout: () => null);
    if (_linkWaiters[me] == waiter) _linkWaiters.remove(me);
    return envelope == null ? _error(404, 'Конверта нет') : _ok({'envelope': envelope});
  }

  Device? _deviceFor(Object? token) {
    if (token is! String) return null;
    final r = db.select('SELECT nick, device FROM devices WHERE token_hash = ?', [_sha(token)]).firstOrNull;
    return r == null ? null : (nick: r['nick'] as String, device: r['device'] as int);
  }

  Handler _authed(Function h) => (req) {
    final auth = req.headers['authorization'];
    final me = _deviceFor(auth != null && auth.startsWith('Bearer ') ? auth.substring(7) : null);
    if (me == null) return _error(401, 'Нужно войти');
    // Параметры пути (<nick>, <device>) идут следом за устройством.
    return Function.apply(h, [req, me, ...req.params.values]) as FutureOr<Response>;
  };

  // --- Файлы ---

  Future<Response> _upload(Request req, Device me) async {
    final body = await _body(req);
    if (body == null) return _error(413, 'Часть файла больше ${maxRequest >> 20} МБ');
    if (body.isEmpty) return _error(400, 'Пустой файл');
    final size = req.url.queryParameters['size'];
    final total = size == null ? null : int.tryParse(size);
    if (size != null && (total == null || total < body.length || total > maxFile)) {
      return _error(400, 'Неверный размер файла');
    }
    final id = List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await File(p.join(files.path, id)).writeAsBytes(body);
    db.execute('INSERT INTO files VALUES (?, ?)', [id, me.nick]);
    if (total != null) {
      _sized[id] = _Sized(total)
        ..parts[0] = (length: body.length, written: Future.value())
        ..written = body.length;
      if (total == body.length) {
        _finish(id, me);
      } else {
        _growing[id] = me;
      }
    } else if (req.url.queryParameters['more'] == '1') {
      _growing[id] = me;
    }
    _pruneFiles();
    return _ok({'id': id});
  }

  /// Дописывает следующую часть. offset — сколько байт клиент уже загрузил: так повтор
  /// после оборванного ответа не задвоит часть, а пропуск части не останется незамеченным.
  /// Если размер назван при создании загрузки, части принимаются в любом порядке (см. [_place]).
  Future<Response> _append(Request req, Device me, String id) async {
    final done = _finished[id] == me;
    if (_growing[id] != me && !done) return _error(404, 'Загрузка не найдена, начните заново');
    final f = File(p.join(files.path, id));
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '');
    final body = await _body(req);
    if (body == null) return _error(413, 'Часть файла больше ${maxRequest >> 20} МБ');
    if (_sized[id] case final up?) return _place(id, me, f, up, offset, body, done);
    final length = f.lengthSync();
    if (offset == null || (offset != length && offset + body.length != length)) {
      return _error(409, 'Части файла пришли не по порядку');
    }
    if (done) {
      // Закрытый файл не дописываем, только подтверждаем повтор последней части.
      return offset == length ? _error(404, 'Загрузка не найдена, начните заново') : _ok({'id': id});
    }
    if (offset + body.length > maxFile) return _error(413, 'Файл больше 2 ГБ');
    if (offset == length) await f.writeAsBytes(body, mode: FileMode.append, flush: true);
    if (req.url.queryParameters['more'] != '1') _finish(id, me);
    return _ok({'id': id});
  }

  /// Часть загрузки с известным размером: пишется на своё место. Повтор той же части безопасен,
  /// перекрытие с другой частью или выход за размер отклоняются. Загрузка закрывается,
  /// когда части покрыли весь размер.
  Future<Response> _place(String id, Device me, File f, _Sized up, int? offset, Uint8List body, bool done) async {
    if (offset == null || offset < 0 || body.isEmpty || offset + body.length > up.size) {
      return _error(409, 'Часть файла не на своём месте');
    }
    if (up.parts[offset] case final same?) {
      if (same.length != body.length) return _error(409, 'Части файла перекрываются');
      await same.written; // повтор пришёл, пока первая копия ещё пишется
      return _ok({'id': id});
    }
    if (done) return _error(404, 'Загрузка не найдена, начните заново');
    final before = up.parts.lastKeyBefore(offset), after = up.parts.firstKeyAfter(offset);
    if ((before != null && before + up.parts[before]!.length > offset) ||
        (after != null && offset + body.length > after)) {
      return _error(409, 'Части файла перекрываются');
    }
    // Место занимаем до записи: параллельный запрос с той же частью дождётся её, а не запишет второй раз.
    final written = () async {
      final raf = await f.open(mode: FileMode.append); // append не обрезает файл, позицию задаём сами
      try {
        await raf.setPosition(offset);
        await raf.writeFrom(body);
        await raf.flush();
      } finally {
        await raf.close();
      }
    }();
    up.parts[offset] = (length: body.length, written: written);
    try {
      await written;
    } catch (_) {
      up.parts.remove(offset); // повтор запишет часть заново
      rethrow;
    }
    up.written += body.length;
    if (up.written == up.size) _finish(id, me);
    return _ok({'id': id});
  }

  void _finish(String id, Device me) {
    _growing.remove(id);
    _finished[id] = me;
    if (_finished.length > 1000) {
      final old = _finished.keys.first;
      _finished.remove(old);
      _sized.remove(old);
    }
  }

  Future<Uint8List?> _body(Request req) async {
    if ((req.contentLength ?? 0) > maxRequest) return null;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      bytes.add(chunk);
      if (bytes.length > maxRequest) return null;
    }
    return bytes.takeBytes();
  }

  /// Отдаёт файл целиком или кусок из заголовка Range: клиент качает большие файлы частями.
  Response _download(Request req, Device me, String id) {
    final f = File(p.join(files.path, id));
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) || !f.existsSync()) return _error(404, 'Файл не найден или уже удалён');
    final size = f.lengthSync();
    final range = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(req.headers['range'] ?? '');
    if (range == null) {
      return Response.ok(f.openRead(), headers: {'content-type': 'application/octet-stream', 'content-length': '$size'});
    }
    // Числа длиннее int64 не разбираются: это тоже недопустимый диапазон (A07).
    final start = int.tryParse(range[1]!), last = int.tryParse(range[2]!);
    if (start == null || last == null || start > min(last, size - 1)) {
      return Response(416, headers: {'content-range': 'bytes */$size'});
    }
    final end = min(last, size - 1);
    return Response(206, body: f.openRead(start, end + 1), headers: {
      'content-type': 'application/octet-stream',
      'content-length': '${end - start + 1}',
      'content-range': 'bytes $start-$end/$size',
    });
  }

  void _pruneFiles() {
    final old = DateTime.now().subtract(const Duration(days: fileDays));
    for (final f in files.listSync().whereType<File>()) {
      if (f.statSync().modified.isBefore(old)) _deleteFile(p.basename(f.path));
    }
  }

  void _deleteFile(String id) {
    final f = File(p.join(files.path, id));
    if (f.existsSync()) f.deleteSync();
    db.execute('DELETE FROM files WHERE id = ?', [id]);
    _growing.remove(id);
    _finished.remove(id);
    _sized.remove(id);
  }

  /// Удаление у всех: {ids, files}. Убирает ещё не доставленные копии своих сообщений из очереди
  /// и свои файлы с диска. Уведомление собеседнику клиент шлёт отдельно, обычным сообщением.
  /// Повтор безопасен: уже удалённое просто пропускается.
  Future<Response> _unsend(Request req, Device me) async {
    final body = await _json(req);
    final ids = body['ids'] ?? [], fileIds = body['files'] ?? [];
    if (ids is! List ||
        fileIds is! List ||
        ids.length > 100 ||
        fileIds.length > 100 ||
        ids.any((i) => i is! String) ||
        fileIds.any((i) => i is! String)) {
      return _error(400, 'Некорректный запрос');
    }
    for (final id in ids) {
      db.execute('DELETE FROM messages WHERE id = ? AND sender = ?', [id, me.nick]);
    }
    for (final id in fileIds) {
      // Чужой файл или файл, загруженный до учёта владельцев, не трогаем: он удалится по сроку.
      if (db.select('SELECT 1 FROM files WHERE id = ? AND nick = ?', [id, me.nick]).isNotEmpty) _deleteFile(id);
    }
    return _ok({});
  }

  // --- WebSocket ---
  // Клиент → сервер: {type: auth, token}, {type: send, id, to, payloads: [{device, type, body}], push?}, {type: ack, id}
  // push: message, call или end (звонок отменён) — разбудить устройства получателя.
  // {type: ping} → {type: pong}: клиент проверяет, живо ли соединение.
  // Сервер → клиент: {type: ready, device, preKeys}, {type: sent, id, to},
  //   {type: message, id, from, device, ctype, body, sentAt}, {type: error, id?, to?, error}
  // body — шифротекст Signal (base64), ctype — его тип (2 обычное, 3 с установкой сессии).
  // error: devices — список устройств получателя изменился, нужно запросить его заново.

  void _onSocket(WebSocketChannel ws, String? _) {
    Device? me;
    // Не 4401: по нему клиент выходит из аккаунта, а медленная сеть — не повод.
    final auth = Timer(authTimeout, () => ws.sink.close(4408, 'auth timeout'));
    ws.stream.listen(
      (raw) {
        // ponytail: кадр уже прочитан в память библиотекой, полный лимит — на прокси перед сервером.
        if (raw is! String || raw.length > (me == null ? maxAuthFrame : maxFrame)) {
          ws.sink.close(tooBig, 'too big');
          return;
        }
        final Map<String, dynamic> msg;
        try {
          msg = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          ws.sink.close(4400, 'bad json');
          return;
        }
        if (me == null) {
          final d = msg['type'] == 'auth' ? _deviceFor(msg['token']) : null;
          if (d == null) {
            ws.sink.close(4401, 'unauthorized');
            return;
          }
          me = d;
          auth.cancel();
          _online.remove(d)?.sink.close(); // то же устройство переподключилось
          _online[d] = ws;
          ws.sink.add(jsonEncode({'type': 'ready', 'device': d.device, 'preKeys': _preKeyCount(d)}));
          _flush(d, ws);
          return;
        }
        switch (msg['type']) {
          case 'send':
            _send(me!, ws, msg);
          case 'ping':
            ws.sink.add(jsonEncode({'type': 'pong'}));
          case 'ack' when msg['id'] is String:
            db.execute('DELETE FROM messages WHERE id = ? AND recipient = ? AND recipient_device = ?', [
              msg['id'],
              me!.nick,
              me!.device,
            ]);
        }
      },
      onDone: () {
        auth.cancel();
        if (me != null && _online[me] == ws) _online.remove(me);
      },
    );
  }

  void _send(Device me, WebSocketChannel ws, Map<String, dynamic> msg) {
    final id = msg['id'], to = msg['to'], payloads = msg['payloads'], wake = msg['push'];
    void error(String e) => ws.sink.add(jsonEncode({'type': 'error', 'id': id, 'to': to, 'error': e}));
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        to is! String ||
        payloads is! List ||
        payloads.any(
          (p) =>
              p is! Map ||
              p['device'] is! int ||
              (!const [2, 3, 4].contains(p['type'])) ||
              p['body'] is! String ||
              (p['body'] as String).length > maxMessage,
        )) {
      return error('Некорректное сообщение');
    }
    // Шифротекст должен быть ровно для каждого готового устройства получателя (кроме самого отправителя).
    final expected = {for (final r in _readyDevices(to)) r['device'] as int}
      ..removeWhere((d) => to == me.nick && d == me.device);
    final given = {for (final p in payloads) p['device'] as int};
    if (expected.isEmpty) return error('Собеседник ещё не вошёл ни на одном устройстве');
    if (given.length != payloads.length || !given.containsAll(expected) || !expected.containsAll(given)) {
      return error('devices');
    }
    // Очередь от этого отправителя к устройству получателя ограничена: иначе посторонний забьёт диск.
    for (final p in payloads) {
      final queued = db.select(
        'SELECT coalesce(sum(length(body)), 0) AS n FROM messages WHERE recipient = ? AND recipient_device = ? AND sender = ?',
        [to, p['device'], me.nick],
      ).first['n'] as int;
      if (queued + (p['body'] as String).length > maxQueue) return error('quota');
    }
    // Звонок будит полноэкранным уведомлением: от одного собеседника не чаще [maxCalls] в [callWindow].
    var ring = wake;
    if (wake == 'call') {
      if (_over('call:${me.nick}>$to', maxCalls, callWindow)) {
        ring = null;
      } else {
        _hit('call:${me.nick}>$to');
      }
    }
    // Чужой id в очереди получателя: INSERT OR IGNORE молча потерял бы сообщение, а отправитель
    // увидел бы «отправлено» (A17). Отвечаем ошибкой, клиент покажет «не отправлено».
    for (final p in payloads) {
      final other = db.select(
        'SELECT sender FROM messages WHERE id = ? AND recipient = ? AND recipient_device = ?',
        [id, to, p['device']],
      ).firstOrNull?['sender'];
      if (other != null && other != me.nick) return error('id');
    }
    final sentAt = _now();
    for (final p in payloads) {
      // Повтор того же id (переотправка после обрыва связи) не создаёт дубль.
      db.execute('INSERT OR IGNORE INTO messages VALUES (?, ?, ?, ?, ?, ?, ?, ?)', [
        id,
        me.nick,
        me.device,
        to,
        p['device'],
        p['type'],
        p['body'],
        sentAt,
      ]);
      final d = (nick: to, device: p['device'] as int);
      // Будим и тех, кто на связи: свёрнутое приложение Android замораживает, и соединение
      // ещё живо, а сообщение не обрабатывается. Открытое на экране приложение push не показывает.
      if (ring == 'message' || ring == 'call' || ring == 'end') _wake(d, ring);
      _online[d]?.sink.add(
        jsonEncode({
          'type': 'message',
          'id': id,
          'from': me.nick,
          'device': me.device,
          'ctype': p['type'],
          'body': p['body'],
          'sentAt': sentAt,
        }),
      );
    }
    ws.sink.add(jsonEncode({'type': 'sent', 'id': id, 'to': to}));
  }

  void _flush(Device me, WebSocketChannel ws) {
    final rows = db.select(
      'SELECT id, sender, sender_device, type, body, sent_at FROM messages WHERE recipient = ? AND recipient_device = ? ORDER BY sent_at',
      [me.nick, me.device],
    );
    for (final r in rows) {
      ws.sink.add(
        jsonEncode({
          'type': 'message',
          'id': r['id'],
          'from': r['sender'],
          'device': r['sender_device'],
          'ctype': r['type'],
          'body': r['body'],
          'sentAt': r['sent_at'],
        }),
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

/// Тело JSON-запроса; больше [AuraServer.maxJson] — исключение, обработчик отвечает 413.
/// Лишнее дочитывается и выбрасывается, а не хранится: иначе клиент не получит ответ из-за оборванной записи.
// ponytail: бесконечное тело держит соединение, пока его не оборвёт прокси (у Cloudflare 100 МБ).
Future<Map<String, dynamic>> _json(Request req) async {
  final bytes = BytesBuilder(copy: false);
  var size = 0;
  await for (final chunk in req.read()) {
    size += chunk.length;
    if (size <= AuraServer.maxJson) bytes.add(chunk);
  }
  if (size > AuraServer.maxJson) throw const _TooLarge();
  try {
    return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
}

class _TooLarge implements Exception {
  const _TooLarge();
}

/// Загрузка с известным размером: какие части (по offset) уже пришли и сколько байт записано.
class _Sized {
  _Sized(this.size);
  final int size;
  final parts = SplayTreeMap<int, ({int length, Future<void> written})>();
  var written = 0;
}

Response _ok(Object body) => Response.ok(jsonEncode(body), headers: {'content-type': 'application/json'});
Response _error(int status, String message) =>
    Response(status, body: jsonEncode({'error': message}), headers: {'content-type': 'application/json'});
