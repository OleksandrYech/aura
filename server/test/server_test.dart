import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      {'device': 1, 'identityKey': 'idDen'},
    ]);
    final b1 = await get('/api/keys/den/1', anna['token']);
    expect(b1['identityKey'], 'idDen');
    expect(b1['signedPreKey'], {'id': 1, 'key': 'spk', 'signature': 'sig'});
    final b2 = await get('/api/keys/den/1', anna['token']);
    expect({b1['preKey']['id'], b2['preKey']['id']}, {1, 2}, reason: 'prekey выдаётся один раз');
    expect((await get('/api/keys/den/1', anna['token']))['preKey'], isNull);

    expect((await post('/api/logout', {}, token: den['token'])).$1, 200);
    expect(await get('/api/devices/den', anna['token']), isEmpty);
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
    Future<HttpClientResponse> send(String method, String path, {List<int>? body, String? auth}) async {
      final req = await HttpClient().openUrl(method, base.resolve(path));
      if (auth != null) req.headers.set('authorization', 'Bearer $auth');
      if (body != null) req
        ..contentLength = body.length
        ..add(body);
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
    expect((await send('POST', '/api/files', body: List.filled(AuraServer.maxFile + 1, 0), auth: token)).statusCode, 413);
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
