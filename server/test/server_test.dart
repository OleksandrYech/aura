import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:server/server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'signal_keys.dart';
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
    'identityKey': id(identity),
    'signedPreKey': signedPreKey(identity),
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
      {'nick': 'den_k', 'name': 'den_k', 'handle': 'den_k'},
    ]);
    expect(await get('/api/users?q=@den_k', anna['token']), hasLength(1), reason: 'с @ тоже');
    expect(await get('/api/users?q=den', anna['token']), isEmpty); // только точный никнейм
    expect(await get('/api/users?q=den_k_', anna['token']), isEmpty);
    expect(await get('/api/users?q=', anna['token']), isEmpty);
  });

  test('смена никнейма: id остаётся, ищут по новому, занятые и прежние id не даются', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1', 'name': 'Анна'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    Future<(int, dynamic)> rename(Map t, String handle) =>
        post('/api/me', {'name': 'Анна', 'handle': handle}, method: 'PUT', token: t['token']);

    expect((await rename(anna, 'den')).$1, 409, reason: 'чужой никнейм');
    expect((await rename(anna, 'A!')).$1, 400);
    final (s, me) = await rename(anna, 'Anna_New');
    expect(s, 200);
    expect(me, {'nick': 'anna', 'name': 'Анна', 'handle': 'anna_new'});
    expect(await get('/api/users?q=anna', den['token']), isEmpty, reason: 'по прежнему не находят');
    expect(await get('/api/users?q=anna_new', den['token']), [
      {'nick': 'anna', 'name': 'Анна', 'handle': 'anna_new'},
    ]);
    // Прежний никнейм — id аккаунта: его не взять ни при регистрации, ни сменой.
    expect((await post('/api/register', {'nick': 'anna', 'password': 'secret3'})).$1, 409);
    expect((await post('/api/register', {'nick': 'anna_new', 'password': 'secret3'})).$1, 409);
    expect((await post('/api/me', {'name': 'Ден', 'handle': 'anna'}, method: 'PUT', token: den['token'])).$1, 409);
    expect((await rename(anna, 'anna')).$1, 200, reason: 'свой id можно вернуть');
    await rename(anna, 'anna_new');
    // Старые версии шлют только имя: никнейм не трогается.
    expect((await post('/api/me', {'name': 'Аня'}, method: 'PUT', token: anna['token'])).$2['handle'], 'anna_new');

    // Вход по новому и по прежнему никнейму — в тот же аккаунт.
    for (final n in ['anna_new', 'anna']) {
      final (st, again) = await post('/api/login', {'nick': n, 'password': 'secret1'});
      expect(st, 200);
      expect(again, containsPair('nick', 'anna'));
      expect(again, containsPair('handle', 'anna_new'));
    }

    // Получатель видит нынешние имя и никнейм отправителя в конверте; свои устройства — при подключении.
    final a = (await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$2;
    await post('/api/keys', keys('A'), method: 'PUT', token: a['token']);
    await post('/api/keys', keys('D'), method: 'PUT', token: den['token']);
    final (aws, ait) = await connect(a['token']);
    expect(ait.current, containsPair('handle', 'anna_new'));
    final (dws, dit) = await connect(den['token']);
    aws.sink.add(jsonEncode({
      'type': 'send',
      'id': 'm1',
      'to': 'den',
      'payloads': [{'device': den['device'], 'type': 3, 'body': 'c'}],
    }));
    expect(await dit.moveNext(), isTrue);
    expect(dit.current, containsPair('from', 'anna'));
    expect(dit.current, containsPair('handle', 'anna_new'));
    expect(dit.current, containsPair('name', 'Аня'));
    await dws.sink.close();
    final (dws2, dit2) = await connect(den['token']); // из очереди — тоже
    expect(await dit2.moveNext(), isTrue);
    expect(dit2.current, containsPair('handle', 'anna_new'));
    await dws2.sink.close();
    await aws.sink.close();
  });

  test('старая база: никнейм равен id', () async {
    final path = '${Directory.systemTemp.createTempSync('aura').path}/old.db';
    sqlite3.open(path)
      ..execute('''
        CREATE TABLE users (nick TEXT PRIMARY KEY, name TEXT NOT NULL, password_hash TEXT NOT NULL,
          created_at INTEGER NOT NULL, next_device INTEGER NOT NULL DEFAULT 1) STRICT;
        PRAGMA user_version = 1;
      ''')
      ..execute('INSERT INTO users (nick, name, password_hash, created_at) VALUES (?, ?, ?, 0)', ['olga', 'Ольга', hashPassword('secret1')])
      ..close();
    AuraServer(path).close();
    final db = sqlite3.open(path);
    expect(db.select('SELECT handle FROM users').single['handle'], 'olga');
    db.close();
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
      {'device': 1, 'identityKey': id('idDen'), 'accountKey': id('idDen')},
    ]);
    final b1 = await get('/api/keys/den/1', anna['token']);
    expect(b1['identityKey'], id('idDen'));
    expect(b1['signedPreKey'], containsPair('id', 1));
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
    expect(den2['identityKey'], id('idDen'), reason: 'вход отдаёт ключ аккаунта');
    expect((await post('/api/keys', keys('idDen2'), method: 'PUT', token: den2['token'])).$1, 409,
        reason: 'свой ключ на втором устройстве не принимается');
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den2['token']);
    expect(await get('/api/devices/den', anna['token']), [
      {'device': 1, 'identityKey': id('idDen'), 'accountKey': id('idDen')},
      {'device': 2, 'identityKey': id('idDen'), 'accountKey': id('idDen')},
    ]);
    await post('/api/logout', {}, token: den['token']);
    final (_, den3) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    expect(den3['identityKey'], id('idDen'), reason: 'выход устройства ключ аккаунта не сбрасывает');
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

  test('миграция: устройства со своим ключом удаляются при запуске сервера', () async {
    final dir = await Directory.systemTemp.createTemp();
    final path = '${dir.path}/v2.db';
    final old = AuraServer(path);
    old.db.execute("INSERT INTO users (nick, name, password_hash, created_at, identity_key) VALUES ('anna', 'a', 'x', 0, 'a1')");
    for (final (device, key) in [(1, 'a1'), (2, 'a2'), (3, null), (4, 'a1')]) {
      old.db.execute('INSERT INTO devices (token_hash, nick, device, created_at, identity_key) VALUES (?, ?, ?, 0, ?)', [
        'anna$device',
        'anna',
        device,
        key,
      ]);
    }
    old.db.execute('UPDATE users SET identity_key = ? WHERE nick = ?', ['a1', 'anna']);
    old.close();
    final upgraded = AuraServer(path);
    expect(upgraded.db.select('SELECT device FROM devices ORDER BY device').map((r) => r['device']), [1, 3, 4],
        reason: 'устройство 2 со своим ключом удалено, без ключа (ждёт привязки) осталось');
    upgraded.close();
    await dir.delete(recursive: true);
  });

  test('не больше 10 устройств; неактивное 90 дней устройство выходит', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    for (var i = 1; i < AuraServer.maxDevices; i++) {
      expect((await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$1, 200);
    }
    expect((await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$1, 403);

    expect((await post('/api/me', {'name': 'A'}, method: 'PUT', token: anna['token'])).$1, 200);
    final old = DateTime.now().subtract(AuraServer.deviceTtl + const Duration(days: 1)).millisecondsSinceEpoch;
    aura.db.execute('UPDATE devices SET seen_at = ? WHERE device = 1', [old]);
    expect((await post('/api/me', {'name': 'A'}, method: 'PUT', token: anna['token'])).$1, 401);
    expect((await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$1, 200, reason: 'место освободилось');
  });

  test('вход убирает непривязанные и давно неактивные устройства, не дожидаясь их токена', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    await post('/api/keys', keys('idAnna'), method: 'PUT', token: anna['token']);
    for (var i = 1; i < AuraServer.maxDevices; i++) {
      await post('/api/login', {'nick': 'anna', 'password': 'secret1'}); // привязка брошена
    }
    expect((await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$1, 403, reason: 'свежие ждут привязки');

    final ago = DateTime.now().subtract(AuraServer.unlinkedTtl + const Duration(minutes: 1)).millisecondsSinceEpoch;
    aura.db.execute('UPDATE devices SET created_at = ?', [ago]);
    expect((await post('/api/login', {'nick': 'anna', 'password': 'secret1'})).$1, 200);
    int count() => aura.db.select('SELECT count(*) AS n FROM devices').first['n'] as int;
    expect(count(), 2, reason: 'осталось устройство с ключом и новый вход');

    final old = DateTime.now().subtract(AuraServer.deviceTtl + const Duration(days: 1)).millisecondsSinceEpoch;
    aura.db.execute('UPDATE devices SET seen_at = ? WHERE device = 1', [old]);
    await post('/api/login', {'nick': 'anna', 'password': 'secret1'});
    expect(aura.db.select('SELECT 1 FROM devices WHERE device = 1'), isEmpty, reason: 'неактивное 90 дней');
  });

  test('привязка: конверт от своего старого устройства новому, один, живёт ограниченное время', () async {
    await http.close(force: true);
    aura.close();
    final files = Directory.systemTemp.createTempSync('aura').path;
    aura = AuraServer(':memory:', files: files, linkTtl: const Duration(milliseconds: 300));
    http = await io.serve(aura.handler, 'localhost', 0);
    base = Uri.parse('http://localhost:${http.port}');
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    final (_, den2) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    final (_, eve) = await post('/api/register', {'nick': 'eve', 'password': 'secret3'});
    await post('/api/keys', keys('idEve'), method: 'PUT', token: eve['token']);
    final (_, eve2) = await post('/api/login', {'nick': 'eve', 'password': 'secret3'});
    expect(den2['device'], 2);
    expect(eve2['device'], 2);
    Future<int> link(Map who, int device, [Object envelope = 'e']) async =>
        (await post('/api/link/$device', {'envelope': envelope}, token: who['token'])).$1;
    Future<(int, dynamic)> fetch(Map who) async {
      final req = await HttpClient().getUrl(base.resolve('/api/link'));
      req.headers.set('authorization', 'Bearer ${who['token']}');
      final res = await req.close();
      return (res.statusCode, jsonDecode(await res.transform(utf8.decoder).join()));
    }

    expect(await link(den2, 1), 403, reason: 'без ключа привязывать нельзя');
    expect(await link(den, 1), 403, reason: 'устройство с ключом не новое');
    expect(await link(den, 9), 403, reason: 'устройства нет');
    expect(await link(den, 2, 'x' * (AuraServer.maxLink + 1)), 400);
    expect(await link(den, 2, 7), 400);

    final waiting = fetch(den2);
    await Future.delayed(const Duration(milliseconds: 50));
    expect(await link(den, 2, 'e1'), 200);
    expect((await waiting).$2, {'envelope': 'e1'}, reason: 'ожидающее устройство получает конверт сразу');

    expect(await link(eve, 2, 'e2'), 200, reason: 'eve:2 — устройство Евы, а не Дена');
    expect(await link(den, 2, 'e3'), 200);
    expect(await link(den, 2, 'e4'), 409, reason: 'второй конверт');
    expect((await fetch(den2)).$2, {'envelope': 'e3'});
    expect((await fetch(eve2)).$2, {'envelope': 'e2'});

    expect(await link(den, 2, 'e5'), 200);
    await Future.delayed(const Duration(milliseconds: 400));
    expect((await fetch(den2)).$1, 404, reason: 'конверт истёк');

    for (var i = 0; i < AuraServer.maxPendingLinks; i++) {
      await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    }
    for (var d = 2; d < 2 + AuraServer.maxPendingLinks; d++) {
      expect(await link(den, d), 200);
    }
    expect(await link(den, 2 + AuraServer.maxPendingLinks), 429, reason: 'не больше трёх ожидающих конвертов на аккаунт');
  });

  test('отвязка: удалить можно только устройство своего аккаунта', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    final (_, den2) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den2['token']);
    final (_, den3) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    expect((await post('/api/devices/2', {}, method: 'DELETE', token: den3['token'])).$1, 403, reason: 'без ключа нельзя');
    await post('/api/keys', keys('idAnna'), method: 'PUT', token: anna['token']);
    expect((await post('/api/devices/2', {}, method: 'DELETE', token: anna['token'])).$1, 200);
    expect(await get('/api/devices/den', anna['token']), hasLength(2), reason: 'anna удаляет только своё устройство 2');
    expect((await post('/api/devices/2', {}, method: 'DELETE', token: den['token'])).$1, 200);
    expect(await get('/api/devices/den', anna['token']), hasLength(1));
    expect((await post('/api/me', {'name': 'Den'}, method: 'PUT', token: den2['token'])).$1, 401);
  });

  test('начать заново: только с паролем, старые устройства выходят, ключ аккаунта задаётся заново', () async {
    final (_, anna) = await post('/api/register', {'nick': 'anna', 'password': 'secret1'});
    final (_, den) = await post('/api/register', {'nick': 'den', 'password': 'secret2'});
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den['token']);
    final (oldWs, _) = await connect(den['token']);
    final (_, fresh) = await post('/api/login', {'nick': 'den', 'password': 'secret2'});
    Future<int> reset(String password) async =>
        (await post('/api/identity/reset', {'password': password}, token: fresh['token'])).$1;

    expect(await reset('wrong'), 401);
    expect((await post('/api/keys', keys('idNew'), method: 'PUT', token: fresh['token'])).$1, 409);
    expect(await reset('secret2'), 200);
    await oldWs.sink.done;
    expect(oldWs.closeCode, 4401, reason: 'старое устройство выходит');
    expect((await post('/api/me', {'name': 'D'}, method: 'PUT', token: den['token'])).$1, 401);
    expect((await post('/api/keys', keys('idNew'), method: 'PUT', token: fresh['token'])).$1, 200);
    expect(await get('/api/devices/den', anna['token']), [
      {'device': 2, 'identityKey': id('idNew'), 'accountKey': id('idNew')},
    ]);

    for (var i = 0; i < AuraServer.maxLogins; i++) {
      await reset('wrong');
    }
    expect(await reset('secret2'), 429, reason: 'перебор пароля через сброс ограничен');
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
    await post('/api/keys', keys('idDen'), method: 'PUT', token: den2['token']);
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
    await post('/api/keys', keys('idAnna'), method: 'PUT', token: anna2['token']);
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
