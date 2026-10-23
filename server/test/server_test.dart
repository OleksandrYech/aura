import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late AuraServer aura;
  late HttpServer http;
  late Uri base;

  setUp(() async {
    aura = AuraServer(':memory:', files: Directory.systemTemp.createTempSync('aura').path);
    http = await io.serve(aura.handler, 'localhost', 0);
    base = Uri.parse('http://localhost:${http.port}');
  });
  tearDown(() async {
    await http.close(force: true);
    aura.close();
  });

  Future<(int, dynamic)> post(String path, Map body, {String method = 'POST', String? token}) async {
    final req = await HttpClient().openUrl(method, base.resolve(path));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    req.add(utf8.encode(jsonEncode(body)));
    final res = await req.close();
    return (res.statusCode, jsonDecode(await res.transform(utf8.decoder).join()));
  }

  Future<(WebSocketChannel, StreamIterator)> connect(String token) async {
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    final it = StreamIterator(ws.stream.map((e) => jsonDecode(e as String)));
    ws.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    expect(await it.moveNext(), isTrue);
    expect(it.current['type'], 'ready');
    return (ws, it);
  }

  test('пароль проверяется', () {
    final h = hashPassword('secret1');
    expect(verifyPassword('secret1', h), isTrue);
    expect(verifyPassword('secret2', h), isFalse);
  });

  Future<dynamic> get(String path, String token) async {
    final req = await HttpClient().getUrl(base.resolve(path));
    req.headers.set('authorization', 'Bearer $token');
    return jsonDecode(await (await req.close()).transform(utf8.decoder).join());
  }

  Map keys(String identity, {int preKeys = 2}) => {
    'registrationId': 7,
    'identityKey': identity,
    'signedPreKey': {'id': 1, 'key': 'spk', 'signature': 'sig'},
    'preKeys': [
      for (var i = 1; i <= preKeys; i++) {'id': i, 'key': 'pk$i'},
    ],
  };

  test('регистрация, вход и поиск', () async {
    final (s1, anna) = await post('/api/register', {'nick': 'Anna', 'password': 'secret1', 'name': 'Анна'});
    expect(s1, 200);
    expect(anna['nick'], 'anna');
    expect(anna['device'], 1);
    expect((await post('/api/register', {'nick': 'anna', 'password': 'secret1'})).$1, 409);
    expect((await post('/api/register', {'nick': 'a!', 'password': 'secret1'})).$1, 400);
    expect((await post('/api/login', {'nick': 'anna', 'password': 'wrong1'})).$1, 401);
    final (_, again) = await post('/api/login', {'nick': 'anna', 'password': 'secret1'});
    expect(again['device'], 2, reason: 'каждый вход — новое устройство');
    await post('/api/register', {'nick': 'den_k', 'password': 'secret2'});

    expect(await get('/api/users?q=Den_K', anna['token']), [
      {'nick': 'den_k', 'name': 'den_k'},
    ]);
    expect(await get('/api/users?q=den', anna['token']), isEmpty); // только точный никнейм
    expect(await get('/api/users?q=', anna['token']), isEmpty);
  });

  test('серверы для звонка: STUN, а TURN с временным паролем, если задан', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    expect(await get('/api/ice', anna['token']), [
      {'urls': 'stun:stun.l.google.com:19302'},
    ]);
    await http.close(force: true);
    aura.close();
    final files = Directory.systemTemp.createTempSync('aura').path;
    aura = AuraServer(':memory:', files: files, turn: (url: 'turn:t:3478', secret: 's'));
    http = await io.serve(aura.handler, 'localhost', 0);
    base = Uri.parse('http://localhost:${http.port}');
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret1'});
    final turn = (await get('/api/ice', den['token']) as List).last;
    expect(turn['urls'], 'turn:t:3478');
    expect(turn['username'], endsWith(':den'));
    // Так же пароль считает coturn с use-auth-secret.
    final hmac = Hmac(sha1, utf8.encode('s')).convert(utf8.encode(turn['username']));
    expect(turn['credential'], base64.encode(hmac.bytes));
  });

  test('push будит получателя, даже на связи; устаревший токен забывается', () async {
    final pushed = <(String, String)>[];
    await http.close(force: true);
    aura.close();
    aura = AuraServer(':memory:', files: Directory.systemTemp.createTempSync('aura').path, push: (token, kind) async {
      pushed.add((token, kind));
      return token != 'old';
    });
    http = await io.serve(aura.handler, 'localhost', 0);
    base = Uri.parse('http://localhost:${http.port}');
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idAnna'), method: 'PUT', token: anna['token']);
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    expect((await post('/api/push', {'token': 7}, method: 'PUT', token: den['token'])).$1, 400);
    await post('/api/push', {'token': 'den1'}, method: 'PUT', token: den['token']);

    final (annaWs, annaIn) = await connect(anna['token']);
    Future<void> send(String id, [String? push]) async {
      annaWs.sink.add(jsonEncode({
        'type': 'send',
        'id': id,
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 2, 'body': 'c'},
        ],
        'push': ?push,
      }));
      expect(await annaIn.moveNext(), isTrue);
    }

    await send('m1', 'call');
    await send('r1'); // подтверждения и служебное не будят
    await send('e1', 'end'); // звонок отменён: уведомление о нём гаснет
    expect(pushed, [('den1', 'call'), ('den1', 'end')]);

    annaWs.sink.add(jsonEncode({'type': 'ping'}));
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'pong'});

    final (denWs, _) = await connect(den['token']);
    await send('m2', 'message');
    expect(pushed.last, ('den1', 'message'), reason: 'свёрнутое приложение заморожено, хоть и на связи');
    await denWs.sink.close();
    await Future.delayed(const Duration(milliseconds: 100));

    await post('/api/push', {'token': 'old'}, method: 'PUT', token: den['token']);
    await send('m3', 'message');
    await Future.delayed(const Duration(milliseconds: 50));
    expect(pushed.last, ('old', 'message'));
    expect(aura.db.select('SELECT push_token FROM devices WHERE nick = ?', ['den']).first['push_token'], isNull);
    await annaWs.sink.close();
  });

  test('ключи: публикация, выдача и одноразовые prekey', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    expect(await get('/api/devices/den', anna['token']), isEmpty, reason: 'без ключей устройство не видно');

    final (s, res) = await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    expect(s, 200);
    expect(res['preKeys'], 2);
    expect(
      (await post('/api/keys', keys('other'), method: 'PUT', token: den['token'])).$1,
      409,
      reason: 'ключ личности не подменить',
    );
    expect((await post('/api/keys', {'preKeys': 'x'}, method: 'PUT', token: den['token'])).$1, 400);

    expect(await get('/api/devices/den', anna['token']), [
      {'device': 1, 'identityKey': 'idDen', 'accountKey': 'idDen'},
    ]);
    final b1 = await get('/api/keys/den/1', anna['token']);
    expect(b1['identityKey'], 'idDen');
    expect(b1['signedPreKey'], {'id': 1, 'key': 'spk', 'signature': 'sig'});
    expect((await get('/api/keys/den/1', anna['token']))['preKey'], isNull, reason: 'тому же собеседнику — раз в час');
    final (_, eve) = await post('/api/register', {'nick': 'eve', 'password': 'secret3'});
    final b2 = await get('/api/keys/den/1', eve['token']);
    expect({b1['preKey']['id'], b2['preKey']['id']}, {1, 2}, reason: 'prekey выдаётся один раз');
    final (_, mallory) = await post('/api/register', {'nick': 'mallory', 'password': 'secret4'});
    expect((await get('/api/keys/den/1', mallory['token']))['preKey'], isNull, reason: 'ключи кончились');

    expect((await post('/api/logout', {}, token: den['token'])).$1, 200);
    expect(await get('/api/devices/den', anna['token']), isEmpty);
  });

  test('ключ аккаунта задаёт первое устройство с ключом', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    expect(den['identityKey'], isNull);
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    final (_, den2) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    expect(den2['identityKey'], 'idDen', reason: 'вход отдаёт ключ аккаунта');
    await post('/api/keys', keys('idDen2'), method: 'PUT', token: den2['token']);
    expect(await get('/api/devices/den', anna['token']), [
      {'device': 1, 'identityKey': 'idDen', 'accountKey': 'idDen'},
      {'device': 2, 'identityKey': 'idDen2', 'accountKey': 'idDen'},
    ], reason: 'второе устройство ключ аккаунта не меняет');
    await post('/api/logout', {}, token: den['token']);
    final (_, den3) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    expect(den3['identityKey'], 'idDen', reason: 'выход устройства ключ аккаунта не сбрасывает');
  });

  test('старая база: ключ аккаунта берётся у самого старого устройства', () async {
    final dir = await Directory.systemTemp.createTemp();
    final path = '${dir.path}/v1.db';
    final old = AuraServer(path);
    old.db.execute('ALTER TABLE users DROP COLUMN identity_key');
    for (final (nick, device, key) in [('anna', 3, 'a3'), ('anna', 2, 'a2'), ('anna', 4, null), ('den', 1, null)]) {
      old.db.execute('INSERT OR IGNORE INTO users (nick, name, password_hash, created_at) VALUES (?, ?, ?, 0)', [
        nick,
        nick,
        'x',
      ]);
      old.db.execute('INSERT INTO devices (token_hash, nick, device, created_at, identity_key) VALUES (?, ?, ?, 0, ?)', [
        '$nick$device',
        nick,
        device,
        key,
      ]);
    }
    old.close();
    final upgraded = AuraServer(path);
    expect(upgraded.db.select('SELECT identity_key FROM users ORDER BY nick').map((r) => r['identity_key']), [
      'a2',
      null,
    ]);
    upgraded.close();
    await dir.delete(recursive: true);
  });

  test('доставка шифротекста на каждое устройство', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    final (_, den2) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idAnna'), method: 'PUT', token: anna['token']);
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);

    // Анна пишет, пока Денис офлайн. Второе устройство Дениса без ключей и не учитывается.
    final (annaWs, annaIn) = await connect(anna['token']);
    annaWs.sink.add(
      jsonEncode({
        'type': 'send',
        'id': 'm1',
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 3, 'body': 'c1'},
          {'device': 5, 'type': 2, 'body': 'x'},
        ],
      }),
    );
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current['error'], 'devices', reason: 'лишнее устройство');

    // Появилось второе устройство: отправка по старому списку отклоняется.
    await post('/api/keys', keys('idDen2'), method: 'PUT', token: den2['token']);
    annaWs.sink.add(
      jsonEncode({
        'type': 'send',
        'id': 'm1',
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 3, 'body': 'c1'},
        ],
      }),
    );
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'error', 'id': 'm1', 'to': 'den', 'error': 'devices'});

    annaWs.sink.add(
      jsonEncode({
        'type': 'send',
        'id': 'm1',
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 3, 'body': 'c1'},
          {'device': 2, 'type': 3, 'body': 'c2'},
        ],
      }),
    );
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'sent', 'id': 'm1', 'to': 'den'});
    expect(aura.db.select('SELECT body FROM messages').map((r) => r['body']), unorderedEquals(['c1', 'c2']));

    // Каждое устройство Дениса получает свой шифротекст.
    final (denWs, denIn) = await connect(den['token']);
    expect(await denIn.moveNext(), isTrue);
    expect(denIn.current, containsPair('body', 'c1'));
    expect(denIn.current, containsPair('from', 'anna'));
    expect(denIn.current, containsPair('device', 1));
    expect(denIn.current, containsPair('ctype', 3));
    denWs.sink.add(jsonEncode({'type': 'ack', 'id': 'm1'}));
    await Future.delayed(const Duration(milliseconds: 100));
    expect(aura.db.select('SELECT recipient_device FROM messages').map((r) => r['recipient_device']), [2]);

    // Онлайн-доставка.
    annaWs.sink.add(
      jsonEncode({
        'type': 'send',
        'id': 'm2',
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 2, 'body': 'd1'},
          {'device': 2, 'type': 2, 'body': 'd2'},
        ],
      }),
    );
    expect(await denIn.moveNext(), isTrue);
    expect(denIn.current['body'], 'd1');

    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'sent', 'id': 'm2', 'to': 'den'});

    // Копия себе на другие устройства: своё устройство в списке не нужно.
    final (_, anna2) = await post('/api/login', {'nick': 'anna', 'password': 'secret1'});
    await post('/api/keys', keys('idAnna2'), method: 'PUT', token: anna2['token']);
    annaWs.sink.add(
      jsonEncode({
        'type': 'send',
        'id': 'm2',
        'to': 'anna',
        'payloads': [
          {'device': 2, 'type': 3, 'body': 's'},
        ],
      }),
    );
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'sent', 'id': 'm2', 'to': 'anna'});
    await annaWs.sink.close();
    await denWs.sink.close();
  });

  test('старая база: очередь с открытым текстом удаляется, аккаунты остаются', () async {
    final dir = await Directory.systemTemp.createTemp();
    final path = '${dir.path}/old.db';
    sqlite3.open(path)
      ..execute('''
        CREATE TABLE users (nick TEXT PRIMARY KEY, name TEXT NOT NULL, password_hash TEXT NOT NULL, created_at INTEGER NOT NULL) STRICT;
        CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, nick TEXT NOT NULL, created_at INTEGER NOT NULL) STRICT;
        CREATE TABLE messages (id TEXT PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL, body TEXT NOT NULL, sent_at INTEGER NOT NULL) STRICT;
      ''')
      ..execute('INSERT INTO users VALUES (?, ?, ?, 0)', ['anna', 'Анна', hashPassword('secret1')])
      ..execute("INSERT INTO messages VALUES ('m', 'anna', 'anna', 'открытый текст', 0)")
      ..close();
    final upgraded = AuraServer(path);
    expect(upgraded.db.select("SELECT * FROM messages"), isEmpty);
    expect(upgraded.db.select("SELECT name FROM users").single['name'], 'Анна');
    upgraded.close();
    AuraServer(path).close(); // повторный запуск ничего не ломает
    await dir.delete(recursive: true);
  });

  test('файлы: загрузка, выдача, ограничения', () async {
    final (_, reg) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final String token = reg['token'];
    Future<HttpClientResponse> send(String method, String path, {List<int>? body, String? auth, String? range}) async {
      final req = await HttpClient().openUrl(method, base.resolve(path));
      if (auth != null) req.headers.set('authorization', 'Bearer $auth');
      if (range != null) req.headers.set('range', range);
      if (body != null) {
        req
          ..contentLength = body.length
          ..add(body);
      }
      return req.close();
    }

    final bytes = List.generate(1000, (i) => i % 256);
    expect((await send('POST', '/api/files', body: bytes)).statusCode, 401);
    final up = await send('POST', '/api/files', body: bytes, auth: token);
    expect(up.statusCode, 200);
    final String id = jsonDecode(await up.transform(utf8.decoder).join())['id'];
    final down = await send('GET', '/api/files/$id', auth: token);
    expect(await down.fold<List<int>>([], (a, b) => a..addAll(b)), bytes);
    expect((await send('GET', '/api/files/../aura.db', auth: token)).statusCode, 404);
    expect((await send('GET', '/api/files/${'0' * 32}', auth: token)).statusCode, 404);
    expect((await send('POST', '/api/files', body: List.filled(AuraServer.maxRequest + 1, 0), auth: token)).statusCode, 413);

    // Большой файл: первая часть создаёт файл, следующие дописываются по offset, скачивается кусками.
    Future<List<int>> read(HttpClientResponse r) => r.fold<List<int>>([], (a, b) => a..addAll(b));
    final first = await send('POST', '/api/files?more=1', body: bytes, auth: token);
    final String big = jsonDecode(await first.transform(utf8.decoder).join())['id'];
    final (_, other) = await post('/api/register', {'nick': 'oleg', 'password': 'secret1'});
    expect((await send('POST', '/api/files/$big?offset=1000&more=1', body: bytes, auth: other['token'])).statusCode, 404,
        reason: 'дописывать может только тот, кто начал загрузку');
    expect((await send('POST', '/api/files/$big?offset=5&more=1', body: bytes, auth: token)).statusCode, 409);
    expect((await send('POST', '/api/files/$big?offset=1000&more=1', body: bytes, auth: token)).statusCode, 200);
    expect((await send('POST', '/api/files/$big?offset=1000&more=1', body: bytes, auth: token)).statusCode, 200,
        reason: 'повтор той же части после оборванного ответа');
    expect((await send('POST', '/api/files/$big?offset=2000', body: bytes.take(10).toList(), auth: token)).statusCode, 200);
    final second = jsonDecode(await (await send('POST', '/api/files?more=1', body: bytes, auth: token)).transform(utf8.decoder).join())['id'];
    expect((await send('POST', '/api/files/$second?offset=1000', body: bytes, auth: token)).statusCode, 200);
    expect((await send('POST', '/api/files/$big?offset=2000', body: bytes.take(10).toList(), auth: token)).statusCode, 200,
        reason: 'повтор последней части после оборванного ответа, даже если между ними закончилась другая загрузка');
    expect((await send('POST', '/api/files/$big?offset=2010', body: bytes, auth: token)).statusCode, 404,
        reason: 'после последней части файл закрыт');
    final whole = await read(await send('GET', '/api/files/$big', auth: token));
    expect(whole, [...bytes, ...bytes, ...bytes.take(10)]);
    final part = await send('GET', '/api/files/$big', auth: token, range: 'bytes=1000-1999');
    expect(part.statusCode, 206);
    expect(await read(part), bytes);
    final tail = await send('GET', '/api/files/$big', auth: token, range: 'bytes=2000-9999');
    expect(await read(tail), bytes.take(10).toList());

    // Размер известен заранее: части идут в любом порядке и одновременно.
    expect((await send('POST', '/api/files?size=999', body: bytes, auth: token)).statusCode, 400);
    expect((await send('POST', '/api/files?size=${AuraServer.maxFile + 1}', body: bytes, auth: token)).statusCode, 400);
    final par = jsonDecode(await (await send('POST', '/api/files?size=3010', body: bytes, auth: token)).transform(utf8.decoder).join())['id'];
    final codes = await Future.wait([
      send('POST', '/api/files/$par?offset=2000', body: bytes.take(10).toList(), auth: token),
      send('POST', '/api/files/$par?offset=1000', body: bytes, auth: token),
      send('POST', '/api/files/$par?offset=2000', body: bytes.take(10).toList(), auth: token), // повтор одновременно
    ].map((r) async => (await r).statusCode));
    expect(codes, [200, 200, 200]);
    expect((await send('POST', '/api/files/$par?offset=1500', body: bytes, auth: token)).statusCode, 409,
        reason: 'части не перекрываются');
    expect((await send('GET', '/api/files/$par', auth: token, range: 'bytes=2000-2009')).statusCode, 206);
    expect((await send('POST', '/api/files/$par?offset=1010', body: bytes, auth: token)).statusCode, 409,
        reason: 'не за пределы размера и не поверх другой части');
    expect((await send('POST', '/api/files/$par?offset=2500', body: bytes, auth: token)).statusCode, 409);
    expect((await send('POST', '/api/files/$par?offset=2010', body: bytes, auth: token)).statusCode, 200);
    expect((await send('POST', '/api/files/$par?offset=1000', body: bytes, auth: token)).statusCode, 200,
        reason: 'повтор любой части после конца загрузки');
    expect((await send('POST', '/api/files/$par?offset=500', body: bytes.take(10).toList(), auth: token)).statusCode, 404,
        reason: 'файл закрыт');
    expect(await read(await send('GET', '/api/files/$par', auth: token)), [...bytes, ...bytes, ...bytes.take(10), ...bytes]);
    final small = jsonDecode(await (await send('POST', '/api/files?size=1000', body: bytes, auth: token)).transform(utf8.decoder).join())['id'];
    expect((await send('POST', '/api/files/$small?offset=0', body: bytes, auth: token)).statusCode, 200,
        reason: 'файл из одной части закрыт сразу, повтор подтверждается');
    expect(await read(await send('GET', '/api/files/$small', auth: token)), bytes);
  });

  test('удаление у всех: очередь и файлы отправителя', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    Future<String> upload(String token) async {
      final req = await HttpClient().postUrl(base.resolve('/api/files'));
      req.headers.set('authorization', 'Bearer $token');
      req.add([1, 2, 3]);
      return jsonDecode(await (await req.close()).transform(utf8.decoder).join())['id'];
    }

    final mine = await upload(anna['token']), theirs = await upload(den['token']);
    final (annaWs, annaIn) = await connect(anna['token']);
    for (final id in ['m1', 'm2']) {
      annaWs.sink.add(jsonEncode({
        'type': 'send',
        'id': id,
        'to': 'den',
        'payloads': [
          {'device': 1, 'type': 3, 'body': id},
        ],
      }));
      expect(await annaIn.moveNext(), isTrue);
    }
    expect((await post('/api/unsend', {'ids': 'x'}, token: anna['token'])).$1, 400);
    expect((await post('/api/unsend', {'ids': ['m1'], 'files': [mine]}, token: den['token'])).$1, 200);
    expect(aura.db.select('SELECT id FROM messages'), hasLength(2), reason: 'чужие сообщения не удаляются');
    expect(File('${aura.files.path}/$mine').existsSync(), isTrue, reason: 'и чужие файлы тоже');

    expect((await post('/api/unsend', {'ids': ['m1'], 'files': [mine, theirs]}, token: anna['token'])).$1, 200);
    expect(aura.db.select('SELECT id FROM messages').map((r) => r['id']), ['m2']);
    expect(File('${aura.files.path}/$mine').existsSync(), isFalse);
    expect(File('${aura.files.path}/$theirs').existsSync(), isTrue);
    expect((await post('/api/unsend', {'ids': ['m1'], 'files': [mine]}, token: anna['token'])).$1, 200, reason: 'повтор');
    await annaWs.sink.close();
  });

  test('без токена сокет закрывается', () async {
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    ws.sink.add(jsonEncode({'type': 'auth', 'token': 'nope'}));
    await ws.stream.drain();
    expect(ws.closeCode, 4401);
  });

  test('мусор от клиента не роняет сервер', () async {
    final (_, u) = await post('/api/register', {'nick': 'mallory', 'password': 'secret1'});
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    ws.sink.add(jsonEncode({'type': 'auth', 'token': 42}));
    await ws.stream.drain();
    expect(ws.closeCode, 4401);
    final (ws2, it) = await connect(u['token']);
    ws2.sink.add(jsonEncode({'type': 'ack', 'id': 7}));
    ws2.sink.add(jsonEncode({'type': 'send', 'id': 1, 'to': [], 'payloads': null}));
    expect(await it.moveNext(), isTrue);
    expect(it.current['type'], 'error');
    ws2.sink.add('[1,2]');
    while (await it.moveNext()) {}
    expect(ws2.closeCode, 4400);
    expect((await post('/api/login', {'nick': 'mallory', 'password': 'secret1'})).$1, 200);
  });
}
