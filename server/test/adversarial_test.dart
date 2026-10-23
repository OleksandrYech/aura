// Адверсариальные проверки сервера: каждый тест утверждает безопасное поведение.
// Красный тест = подтверждённая уязвимость.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:server/server.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late AuraServer aura;
  late HttpServer http;
  late Uri base;
  final pushed = <(String, String)>[];

  Future<void> start({bool withPush = false}) async {
    aura = AuraServer(
      ':memory:',
      files: Directory.systemTemp.createTempSync('aura').path,
      push: withPush
          ? (token, kind) async {
              pushed.add((token, kind));
              return true;
            }
          : null,
    );
    http = await io.serve(aura.handler, 'localhost', 0);
    base = Uri.parse('http://localhost:${http.port}');
  }

  setUp(() async {
    pushed.clear();
    await start();
  });
  tearDown(() async {
    await http.close(force: true);
    aura.close();
  });

  Future<void> restartWithPush() async {
    await http.close(force: true);
    aura.close();
    await start(withPush: true);
  }

  Future<(int, dynamic)> raw(String method, String path, List<int> body, {String? token, String? range}) async {
    final req = await HttpClient().openUrl(method, base.resolve(path));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (range != null) req.headers.set('range', range);
    req.add(body);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Object? data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      data = text;
    }
    return (res.statusCode, data);
  }

  Future<(int, dynamic)> post(String path, Object body, {String method = 'POST', String? token}) =>
      raw(method, path, utf8.encode(jsonEncode(body)), token: token);

  Future<dynamic> get(String path, String token) async => (await raw('GET', path, [], token: token)).$2;

  Map keys(String identity, {int preKeys = 2, int from = 1}) => {
    'registrationId': 7,
    'identityKey': identity,
    'signedPreKey': {'id': 1, 'key': 'spk', 'signature': 'sig'},
    'preKeys': [
      for (var i = from; i < from + preKeys; i++) {'id': i, 'key': 'pk$i'},
    ],
  };

  Future<Map> user(String nick, {bool withKeys = true}) async {
    final (s, u) = await post('/api/register', {'nick': nick, 'password': 'secret1'});
    expect(s, 200);
    if (withKeys) await post('/api/keys', keys('id_$nick'), method: 'PUT', token: u['token']);
    return u;
  }

  Future<(WebSocketChannel, StreamIterator)> connect(String token) async {
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    final it = StreamIterator(ws.stream.map((e) => jsonDecode(e as String)));
    ws.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    expect(await it.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(it.current['type'], 'ready');
    return (ws, it);
  }

  Map sendMsg(String id, String to, String body, {int device = 1, String? push}) => {
    'type': 'send',
    'id': id,
    'to': to,
    'payloads': [
      {'device': device, 'type': 2, 'body': body},
    ],
    'push': ?push,
  };

  // --- Входные данные HTTP ---

  test('A01: огромное JSON-тело без авторизации отклоняется 413, а не читается в память целиком', () async {
    final big = utf8.encode(jsonEncode({'nick': 'x' * (40 << 20), 'password': 'secret1'}));
    final (status, _) = await raw('POST', '/api/register', big);
    expect(status, 413, reason: 'сервер прочитал ${big.length >> 20} МБ без ограничения и ответил $status');
  });

  test('A02: неверные типы полей дают 400, а не 500', () async {
    final (s1, _) = await post('/api/register', {'nick': 123, 'password': 'secret1'});
    final (s2, _) = await post('/api/login', {'nick': 'anna', 'password': 42});
    final u = await user('anna');
    final (s3, _) = await post('/api/me', {'name': 7}, method: 'PUT', token: u['token']);
    expect([s1, s2, s3], [400, 401, 400]);
  });

  test('A03: перебор пароля ограничивается (429 после серии неудачных входов)', () async {
    await user('victim', withKeys: false);
    final codes = <int>[];
    for (var i = 0; i < 12; i++) {
      codes.add((await post('/api/login', {'nick': 'victim', 'password': 'guess$i'})).$1);
    }
    expect(codes, contains(429), reason: 'все попытки обработаны: $codes');
  });

  test('A04: имя при регистрации ограничено 64 символами, как в PUT /api/me', () async {
    final (s, u) = await post('/api/register', {'nick': 'longname', 'password': 'secret1', 'name': 'Я' * 100000});
    expect(s == 400 || (u['name'] as String).length <= 64, isTrue,
        reason: 'принято имя длиной ${(u['name'] as String).length}');
  });

  test('A05: одноразовые prekey не копятся без предела', () async {
    final u = await user('hoarder', withKeys: false);
    await post('/api/keys', keys('id_h', preKeys: 0), method: 'PUT', token: u['token']);
    var count = 0;
    for (var i = 0; i < 25; i++) {
      final (_, r) = await post('/api/keys', {'preKeys': keys('x', preKeys: 200, from: i * 200)['preKeys']},
          method: 'PUT', token: u['token']);
      count = r['preKeys'] ?? count;
    }
    expect(count, lessThanOrEqualTo(1000), reason: 'на сервере хранится $count prekey одного устройства');
  });

  test('A06: посторонний не может за секунды выбрать все одноразовые prekey жертвы', () async {
    final victim = await user('victim');
    final eve = await user('eve');
    for (var i = 0; i < 10; i++) {
      await get('/api/keys/victim/${victim['device']}', eve['token']);
    }
    final last = await get('/api/keys/victim/${victim['device']}', eve['token']);
    expect(last['preKey'], isNotNull, reason: 'все prekey жертвы израсходованы посторонним');
  });

  test('A07: Range с огромными числами даёт 416, а не 500', () async {
    final u = await user('anna');
    final (_, up) = await raw('POST', '/api/files', List.filled(100, 1), token: u['token']);
    final (s, _) = await raw('GET', '/api/files/${up['id']}', [], token: u['token'], range: 'bytes=99999999999999999999-1');
    expect(s, anyOf(206, 416));
  });

  test('A08: путь с .. в id файла не выходит за каталог файлов', () async {
    final u = await user('anna');
    final codes = [
      (await raw('GET', '/api/files/..%2F..%2Fetc%2Fpasswd', [], token: u['token'])).$1,
      (await raw('POST', '/api/files/..%2Fx?offset=0', [1], token: u['token'])).$1,
      (await raw('GET', '/api/files/%2E%2E', [], token: u['token'])).$1,
    ];
    expect(codes, everyElement(404));
  });

  test('A09: чужой не может удалить мой файл через /api/unsend', () async {
    final anna = await user('anna');
    final eve = await user('eve');
    final (_, up) = await raw('POST', '/api/files', List.filled(10, 2), token: anna['token']);
    await post('/api/unsend', {'files': [up['id']]}, token: eve['token']);
    final (s, _) = await raw('GET', '/api/files/${up['id']}', [], token: anna['token']);
    expect(s, 200);
  });

  test('A10: ключ личности устройства нельзя подменить, выход отзывает токен', () async {
    final anna = await user('anna');
    final (s, _) = await post('/api/keys', keys('id_other'), method: 'PUT', token: anna['token']);
    expect(s, 409);
    await post('/api/logout', {}, token: anna['token']);
    expect((await raw('GET', '/api/ice', [], token: anna['token'])).$1, 401);
  });

  // --- WebSocket ---

  test('A11: огромный кадр WebSocket до авторизации обрывается по размеру (1009), а не парсится', () async {
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    await ws.ready;
    ws.sink.add(jsonEncode({'type': 'auth', 'token': 'A' * (30 << 20)}));
    await ws.stream.drain<void>().timeout(const Duration(seconds: 20), onTimeout: () {});
    expect(ws.closeCode, 1009, reason: 'сервер принял и разобрал 30 МБ от анонима, закрыл с ${ws.closeCode} ${ws.closeReason}');
  });

  test('A12: неавторизованное соединение WebSocket закрывается по тайм-ауту', () async {
    final ws = WebSocketChannel.connect(base.replace(scheme: 'ws', path: '/ws'));
    await ws.ready;
    var closed = false;
    await ws.stream.drain<void>().timeout(const Duration(seconds: 10), onTimeout: () {}).then((_) => closed = ws.closeCode != null);
    await ws.sink.close();
    expect(closed, isTrue, reason: 'анонимное соединение без auth живёт дольше 10 секунд');
  });

  test('A13: глубоко вложенный JSON не роняет сервер', () async {
    final anna = await user('anna');
    final (ws, _) = await connect(anna['token']);
    ws.sink.add('${'[' * 200000}${']' * 200000}');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final (ws2, it2) = await connect(anna['token']);
    ws2.sink.add(jsonEncode({'type': 'ping'}));
    expect(await it2.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(it2.current['type'], 'pong');
    await ws.sink.close();
    await ws2.sink.close();
  });

  test('A14: отправитель не может выдать себя за другого (поле from задаёт сервер)', () async {
    final den = await user('den');
    final eve = await user('eve');
    final (eveWs, eveIn) = await connect(eve['token']);
    eveWs.sink.add(jsonEncode({...sendMsg('m1', 'den', 'c'), 'from': 'anna', 'device': 5}));
    await eveIn.moveNext().timeout(const Duration(seconds: 5));
    final (denWs, denIn) = await connect(den['token']);
    expect(await denIn.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect((denIn.current['from'], denIn.current['device']), ('eve', eve['device']));
    await eveWs.sink.close();
    await denWs.sink.close();
  });

  test('A15: очередь для офлайн-получателя ограничена (не принимает бесконечно по 500 КБ)', () async {
    await user('den');
    final eve = await user('eve');
    final (ws, it) = await connect(eve['token']);
    final body = 'A' * 450000;
    var accepted = 0;
    for (var i = 0; i < 60; i++) {
      ws.sink.add(jsonEncode(sendMsg('m$i', 'den', body)));
      await it.moveNext().timeout(const Duration(seconds: 10));
      if (it.current['type'] == 'sent') accepted++;
    }
    final stored = aura.db.select("SELECT sum(length(body)) AS n FROM messages WHERE recipient = 'den'").first['n'] as int;
    await ws.sink.close();
    expect(accepted, lessThan(60), reason: 'принято $accepted из 60, в очереди ${stored >> 20} МБ для одного получателя');
  });

  test('A16: посторонний не может «звонить» push-ом без ограничения (спам full-screen уведомлением)', () async {
    await restartWithPush();
    final den = await user('den');
    await post('/api/push', {'token': 'den-fcm'}, method: 'PUT', token: den['token']);
    final eve = await user('eve');
    final (ws, it) = await connect(eve['token']);
    for (var i = 0; i < 20; i++) {
      ws.sink.add(jsonEncode(sendMsg('c$i', 'den', 'garbage', push: 'call')));
      await it.moveNext().timeout(const Duration(seconds: 5));
    }
    await ws.sink.close();
    final calls = pushed.where((p) => p.$2 == 'call').length;
    expect(calls, lessThanOrEqualTo(3), reason: 'за секунду ушло $calls push «Входящий звонок» от постороннего с мусором вместо шифротекста');
  });

  test('A17: одинаковый id от разных отправителей не глушит чужое сообщение в очереди', () async {
    final den = await user('den');
    final eve = await user('eve');
    final anna = await user('anna');
    final (eveWs, eveIn) = await connect(eve['token']);
    eveWs.sink.add(jsonEncode(sendMsg('shared-id', 'den', 'from-eve')));
    await eveIn.moveNext().timeout(const Duration(seconds: 5));
    final (annaWs, annaIn) = await connect(anna['token']);
    annaWs.sink.add(jsonEncode(sendMsg('shared-id', 'den', 'from-anna')));
    await annaIn.moveNext().timeout(const Duration(seconds: 5));
    expect(annaIn.current['type'], 'sent', reason: 'анне ответили «sent», будто сообщение принято');
    final (denWs, denIn) = await connect(den['token']);
    final got = <String>[];
    while (await denIn.moveNext().timeout(const Duration(seconds: 2), onTimeout: () => false)) {
      got.add(denIn.current['body']);
    }
    await eveWs.sink.close();
    await annaWs.sink.close();
    await denWs.sink.close();
    expect(got, containsAll(['from-eve', 'from-anna']), reason: 'получатель получил только $got');
  });

  test('A18: сообщение для чужого устройства или лишнего устройства отклоняется', () async {
    await user('den');
    final eve = await user('eve');
    final (ws, it) = await connect(eve['token']);
    ws.sink.add(jsonEncode({
      'type': 'send',
      'id': 'x1',
      'to': 'den',
      'payloads': [
        {'device': 1, 'type': 2, 'body': 'a'},
        {'device': 77, 'type': 2, 'body': 'b'},
      ],
    }));
    await it.moveNext().timeout(const Duration(seconds: 5));
    expect(it.current['error'], 'devices');
    await ws.sink.close();
  });
}
