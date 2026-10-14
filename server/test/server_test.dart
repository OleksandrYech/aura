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

  setUp(() async {
    aura = AuraServer(':memory:');
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

  test('регистрация, вход, поиск и доставка сообщений', () async {
    final (s1, anna) = await post('/api/register', {'nick': 'Anna', 'password': 'secret1', 'name': 'Анна'});
    expect(s1, 200);
    expect(anna['nick'], 'anna');
    expect((await post('/api/register', {'nick': 'anna', 'password': 'secret1'})).$1, 409);
    expect((await post('/api/register', {'nick': 'a!', 'password': 'secret1'})).$1, 400);
    expect((await post('/api/login', {'nick': 'anna', 'password': 'wrong1'})).$1, 401);
    final (_, den) = await post('/api/register', {'nick': 'den_k', 'password': 'secret2'});

    Future<Object?> search(String q) async {
      final req = await HttpClient().getUrl(base.resolve('/api/users?q=$q'));
      req.headers.set('authorization', 'Bearer ${anna['token']}');
      return jsonDecode(await (await req.close()).transform(utf8.decoder).join());
    }

    expect(await search('Den_K'), [
      {'nick': 'den_k', 'name': 'den_k'},
    ]);
    expect(await search('den'), isEmpty); // только точный никнейм
    expect(await search(''), isEmpty);

    // Анна пишет, пока Денис офлайн.
    final (annaWs, annaIn) = await connect(anna['token']);
    annaWs.sink.add(jsonEncode({'type': 'send', 'id': 'm1', 'to': 'den_k', 'text': 'Привет!'}));
    expect(await annaIn.moveNext(), isTrue);
    expect(annaIn.current, {'type': 'sent', 'id': 'm1'});

    // Денис подключается и получает сообщение из очереди.
    final (denWs, denIn) = await connect(den['token']);
    expect(await denIn.moveNext(), isTrue);
    expect(denIn.current['from'], 'anna');
    expect(denIn.current['text'], 'Привет!');
    denWs.sink.add(jsonEncode({'type': 'ack', 'id': 'm1'}));

    // Онлайн-доставка.
    annaWs.sink.add(jsonEncode({'type': 'send', 'id': 'm2', 'to': 'den_k', 'text': 'Ты тут?'}));
    expect(await denIn.moveNext(), isTrue);
    expect(denIn.current['id'], 'm2');
    denWs.sink.add(jsonEncode({'type': 'ack', 'id': 'm2'}));

    await Future.delayed(const Duration(milliseconds: 100));
    expect(aura.db.select('SELECT * FROM messages'), isEmpty, reason: 'подтверждённые сообщения удаляются');
    await annaWs.sink.close();
    await denWs.sink.close();
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
    ws2.sink.add(jsonEncode({'type': 'send', 'id': 1, 'to': [], 'text': null}));
    expect(await it.moveNext(), isTrue);
    expect(it.current['type'], 'error');
    ws2.sink.add('[1,2]');
    while (await it.moveNext()) {}
    expect(ws2.closeCode, 4400);
    expect((await post('/api/login', {'nick': 'mallory', 'password': 'secret1'})).$1, 200);
  });
}
