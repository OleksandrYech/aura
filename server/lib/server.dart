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
  AuraServer(String dbPath, {String? files})
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
      CREATE TABLE IF NOT EXISTS files (
        id TEXT PRIMARY KEY,
        nick TEXT NOT NULL
      ) STRICT;
    ''');
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

  /// Открытые WebSocket-соединения по устройству.
  final _online = <Device, WebSocketChannel>{};

  Handler get handler {
    final api = Router()
      ..post('/api/register', _register)
      ..post('/api/login', _login)
      ..post('/api/logout', _authed(_logout))
      ..get('/api/users', _authed(_searchUsers))
      ..put('/api/me', _authed(_updateMe))
      ..put('/api/keys', _authed(_putKeys))
      ..get('/api/devices/<nick>', _authed(_devices))
      ..get('/api/keys/<nick>/<device>', _authed(_bundle))
      ..post('/api/files', _authed(_upload))
      ..post('/api/files/<id>', _authed(_append))
      ..get('/api/files/<id>', _authed(_download))
      ..post('/api/unsend', _authed(_unsend))
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
      'UPDATE users SET next_device = next_device + 1 WHERE nick = ? RETURNING name, next_device - 1 AS device',
      [nick],
    ).first;
    db.execute('INSERT INTO devices (token_hash, nick, device, created_at) VALUES (?, ?, ?, ?)', [
      _sha(token),
      nick,
      user['device'],
      _now(),
    ]);
    return _ok({'token': token, 'nick': nick, 'name': user['name'], 'device': user['device']});
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

  Response _devices(Request req, Device me, String nick) => _ok([
    for (final r in _readyDevices(nick.toLowerCase())) {'device': r['device'], 'identityKey': r['identity_key']},
  ]);

  /// Набор ключей для X3DH. Одноразовый prekey выдаётся один раз и удаляется.
  Response _bundle(Request req, Device me, String nick, String device) {
    final d = db.select(
      'SELECT * FROM devices WHERE nick = ? AND device = ? AND identity_key IS NOT NULL AND signed_prekey IS NOT NULL',
      [nick.toLowerCase(), int.tryParse(device)],
    ).firstOrNull;
    if (d == null) return _error(404, 'Устройство не найдено');
    final pk = db.select(
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
    final start = int.parse(range[1]!), end = min(int.parse(range[2]!), size - 1);
    if (start > end) return Response(416, headers: {'content-range': 'bytes */$size'});
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
  // Клиент → сервер: {type: auth, token}, {type: send, id, to, payloads: [{device, type, body}]}, {type: ack, id}
  // Сервер → клиент: {type: ready, device, preKeys}, {type: sent, id, to},
  //   {type: message, id, from, device, ctype, body, sentAt}, {type: error, id?, to?, error}
  // body — шифротекст Signal (base64), ctype — его тип (2 обычное, 3 с установкой сессии).
  // error: devices — список устройств получателя изменился, нужно запросить его заново.

  void _onSocket(WebSocketChannel ws, String? _) {
    Device? me;
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
          final d = msg['type'] == 'auth' ? _deviceFor(msg['token']) : null;
          if (d == null) {
            ws.sink.close(4401, 'unauthorized');
            return;
          }
          me = d;
          _online.remove(d)?.sink.close(); // то же устройство переподключилось
          _online[d] = ws;
          ws.sink.add(jsonEncode({'type': 'ready', 'device': d.device, 'preKeys': _preKeyCount(d)}));
          _flush(d, ws);
          return;
        }
        switch (msg['type']) {
          case 'send':
            _send(me!, ws, msg);
          case 'ack' when msg['id'] is String:
            db.execute('DELETE FROM messages WHERE id = ? AND recipient = ? AND recipient_device = ?', [
              msg['id'],
              me!.nick,
              me!.device,
            ]);
        }
      },
      onDone: () {
        if (me != null && _online[me] == ws) _online.remove(me);
      },
    );
  }

  void _send(Device me, WebSocketChannel ws, Map<String, dynamic> msg) {
    final id = msg['id'], to = msg['to'], payloads = msg['payloads'];
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
              (p['type'] != 2 && p['type'] != 3) ||
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
      _online[(nick: to, device: p['device'] as int)]?.sink.add(
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

Future<Map<String, dynamic>> _json(Request req) async {
  try {
    return jsonDecode(await req.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return {};
  }
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
