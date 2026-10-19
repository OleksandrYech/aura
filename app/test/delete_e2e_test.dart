import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aura/client.dart';
import 'package:aura/signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Проверка с настоящим сервером: dart run bin/main.dart в server/ и
/// flutter test test/delete_e2e_test.dart --dart-define=AURA_SERVER=http://localhost:<порт>
const _server = String.fromEnvironment('AURA_SERVER');

/// Второе устройство без приложения: только ключи Signal и сокет.
class _Device {
  _Device(this.nick, this.token, this.device, this.keys);
  final String nick, token;
  final int device;
  final SignalKeys keys;
  late final WebSocketChannel ws;
  late final StreamIterator<dynamic> it;

  static Future<dynamic> call(String method, String path, Object? body, [String? token]) async {
    final req = await HttpClient().openUrl(method, Uri.parse('$_server$path'));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) req.add(utf8.encode(jsonEncode(body)));
    return jsonDecode(await (await req.close()).transform(utf8.decoder).join());
  }

  static Future<_Device> login(String nick, {bool register = false}) async {
    final r = await call('POST', register ? '/api/register' : '/api/login', {'nick': nick, 'password': 'secret1'});
    final d = _Device(nick, r['token'], r['device'], SignalKeys.generate());
    await call('PUT', '/api/keys', d.keys.publicBundle(), d.token);
    d.ws = WebSocketChannel.connect(Uri.parse(_server.replaceFirst('http', 'ws')).replace(path: '/ws'));
    d.it = StreamIterator(d.ws.stream.map((e) => jsonDecode(e as String)));
    d.ws.sink.add(jsonEncode({'type': 'auth', 'token': d.token}));
    return d;
  }

  /// Следующее сообщение, расшифрованное, с подтверждением серверу.
  Future<Map<String, dynamic>> next() async {
    while (await it.moveNext().timeout(const Duration(seconds: 10))) {
      final m = it.current;
      if (m['type'] != 'message') continue;
      ws.sink.add(jsonEncode({'type': 'ack', 'id': m['id']}));
      return {'id': m['id'], ...jsonDecode(await keys.decrypt(m['from'], m['device'], m['ctype'], m['body']))};
    }
    throw StateError('сокет закрыт');
  }
}

void main() {
  test('удаление у всех доходит до собеседника и до своего второго устройства', () async {
    SharedPreferences.setMockInitialValues({});
    await client.load();
    final den = await _Device.login('den', register: true);
    await client.register('anna', 'secret1');
    final web = await _Device.login('anna');
    while (!client.connected) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    client.send('den', 'привет');
    final got = await den.next();
    expect(got['text'], 'привет');
    expect((await web.next())['peer'], 'den');

    client.delete('den', [client.chats['den']!.single], everyone: true);
    expect(await den.next(), {'id': anything, 'delete': [got['id']]});
    expect(await web.next(), {'id': anything, 'delete': [got['id']], 'peer': 'den'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(jsonDecode((await SharedPreferences.getInstance()).getString('chats')!)['deletes'], isEmpty);

    // Обратная сторона: собеседник присылает и удаляет у всех, второе устройство удаляет у себя.
    Future<void> send(_Device from, String to, String id, Map<String, dynamic> content) async {
      final payloads = [];
      for (final d in await _Device.call('GET', '/api/devices/$to', null, from.token) as List) {
        final n = d['device'] as int;
        if (to == from.nick && n == from.device) continue;
        if (!from.keys.hasSession(to, n)) {
          await from.keys.startSession(to, await _Device.call('GET', '/api/keys/$to/$n', null, from.token));
        }
        payloads.add(await from.keys.encrypt(to, n, jsonEncode(content)));
      }
      from.ws.sink.add(jsonEncode({'type': 'send', 'id': id, 'to': to, 'payloads': payloads}));
    }

    Future<void> until(bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(ok(), isTrue);
    }

    await send(den, 'anna', 'r1', {'text': 'от Дена'});
    await send(den, 'anna', 'r2', {'text': 'ещё'});
    await until(() => client.chats['den']?.length == 2);
    await send(den, 'anna', 'd1', {'delete': ['r1']});
    await until(() => client.chats['den']!.length == 1);
    await send(web, 'anna', 'd2', {'delete': ['r2'], 'peer': 'den'});
    await until(() => client.chats['den']!.isEmpty);
  }, skip: _server.isEmpty ? 'нужен локальный сервер, см. комментарий выше' : false);
}
