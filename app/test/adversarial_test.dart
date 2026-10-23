// Адверсариальные проверки клиента: настоящий AuraClient подключается к поддельному (злонамеренному)
// серверу на localhost, а «собеседники» — настоящие SignalKeys. Каждый тест утверждает безопасное
// поведение; красный тест = подтверждённая уязвимость.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aura/client.dart';
import 'package:aura/signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _proxyPort = 0, _tlsPort = 0;
late SecurityContext _serverTls;

/// Клиент ходит на https://web.aura-msg.space через прокси из окружения (https_proxy). Любое TCP-соединение
/// клиента уводим на свой «прокси», а туннель — на поддельный TLS-сервер с сертификатом на web.aura-msg.space,
/// которому тест доверяет.
final class _Redirect extends IOOverrides {
  @override
  Future<ConnectionTask<Socket>> socketStartConnect(host, int port, {sourceAddress, int sourcePort = 0}) =>
      super.socketStartConnect(InternetAddress.loopbackIPv4, _proxyPort, sourceAddress: sourceAddress, sourcePort: sourcePort);
}

final class _ViaProxy extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) => 'PROXY 127.0.0.1:$_proxyPort';
}

Future<void> _setUpNetwork() async {
  final dir = Directory.systemTemp.createTempSync('aura_tls');
  final r = await Process.run('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=web.aura-msg.space',
    '-addext', 'subjectAltName=DNS:web.aura-msg.space', '-keyout', '${dir.path}/k.pem', '-out', '${dir.path}/c.pem',
  ]);
  if (r.exitCode != 0) throw StateError('openssl: ${r.stderr}');
  final cert = File('${dir.path}/c.pem').readAsBytesSync(), key = File('${dir.path}/k.pem').readAsBytesSync();
  SecurityContext.defaultContext.setTrustedCertificatesBytes(cert);
  _serverTls = SecurityContext()
    ..useCertificateChainBytes(cert)
    ..usePrivateKeyBytes(key);
  final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  _proxyPort = proxy.port;
  proxy.listen((c) {
    c.done.ignore(); // обрывы после конца теста не важны
    final buf = <int>[];
    Socket? up;
    late StreamSubscription<List<int>> sub;
    sub = c.listen((data) async {
      if (up != null) return up!.add(data);
      buf.addAll(data);
      final head = latin1.decode(buf, allowInvalid: true), end = head.indexOf('\r\n\r\n');
      if (end < 0) return;
      sub.pause();
      try {
        final u = up = await Socket.connect(InternetAddress.loopbackIPv4, _tlsPort);
        u.done.ignore();
        u.listen(c.add, onDone: c.destroy, onError: (_) => c.destroy());
        c.add(latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
        if (buf.length > end + 4) u.add(buf.sublist(end + 4));
        sub.resume();
      } catch (_) {
        c.destroy(); // поддельный сервер уже закрыт
      }
    }, onDone: () => up?.destroy(), onError: (_) => up?.destroy());
  });
  IOOverrides.global = _Redirect();
  HttpOverrides.global = _ViaProxy(); // без https_proxy в окружении (CI) клиент тоже идёт через CONNECT
}

class _Fake {
  late HttpServer server;
  WebSocket? ws;
  final frames = <Map<String, dynamic>>[];
  final devices = <String, List<Map<String, dynamic>>>{};
  final bundles = <String, Map<String, dynamic>>{};
  final ready = Completer<void>();

  Future<void> start() async {
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, _serverTls);
    _tlsPort = server.port;
    server.listen((req) async {
      if (req.uri.path == '/ws') {
        final s = ws = await WebSocketTransformer.upgrade(req);
        s.listen((raw) {
          final m = jsonDecode(raw as String) as Map<String, dynamic>;
          if (m['type'] == 'auth') {
            s.add(jsonEncode({'type': 'ready', 'device': 1, 'preKeys': 100}));
            if (!ready.isCompleted) ready.complete();
          } else {
            frames.add(m);
          }
        });
        return;
      }
      await utf8.decoder.bind(req).join();
      final seg = req.uri.pathSegments;
      Object? res = {};
      if (seg.length == 3 && seg[1] == 'devices') res = devices[seg[2]] ?? [];
      if (seg.length == 4 && seg[1] == 'keys') res = bundles['${seg[2]}/${seg[3]}'];
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(res));
      await req.response.close();
    });
  }

  void push(Map<String, dynamic> m) => ws!.add(jsonEncode(m));
}

Map<String, dynamic> bundleOf(Map<String, dynamic> pub, int device, [int preKey = 0]) => {
  'device': device,
  'registrationId': pub['registrationId'],
  'identityKey': pub['identityKey'],
  'signedPreKey': pub['signedPreKey'],
  'preKey': (pub['preKeys'] as List)[preKey],
};

Future<bool> waitFor(bool Function() cond, [Duration t = const Duration(seconds: 5)]) async {
  final end = DateTime.now().add(t);
  while (DateTime.now().isBefore(end)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return cond();
}

// ignore: library_private_types_in_public_api
late _Fake fake;
late SignalKeys anna;
late Map<String, dynamic> annaPub;
var _nextPreKey = 0, _nextId = 0;

/// Вход «anna:1» с готовыми ключами и (необязательно) историей/группами.
Future<void> boot({Map<String, dynamic>? groups, Map<String, dynamic>? chats}) async {
  fake = _Fake();
  await fake.start();
  anna = SignalKeys.generate();
  annaPub = anna.publicBundle();
  _nextPreKey = 0;
  fake.devices['anna'] = [
    {'device': 1, 'identityKey': annaPub['identityKey']},
  ];
  SharedPreferences.setMockInitialValues({
    'token': 't',
    'nick': 'anna',
    'name': 'Anna',
    'device': 1,
    'signal': anna.toJson(),
    'chats': jsonEncode({'chats': chats ?? {}, 'names': {}, 'lastRead': {}, 'groups': groups ?? {}}),
  });
  await client.load();
  await fake.ready.future.timeout(const Duration(seconds: 5),
      onTimeout: () => throw StateError('клиент не дошёл до поддельного сервера'));
  expect(await waitFor(() => client.connected), isTrue);
}

/// Собеседник [from] (настоящий Signal) отправляет anna зашифрованное [content].
Future<String> deliver(SignalKeys peer, String from, Map<String, dynamic> content, {String? id, int? sentAt}) async {
  if (!peer.hasSession('anna', 1)) await peer.startSession('anna', bundleOf(annaPub, 1, _nextPreKey++));
  final c = await peer.encrypt('anna', 1, jsonEncode(content));
  final mid = id ?? 'srv${_nextId++}';
  fake.push({
    'type': 'message',
    'id': mid,
    'from': from,
    'device': 1,
    'ctype': c['type'],
    'body': c['body'],
    'sentAt': sentAt ?? DateTime.now().millisecondsSinceEpoch,
  });
  return mid;
}

Future<bool> acked(String id) => waitFor(() => fake.frames.any((f) => f['type'] == 'ack' && f['id'] == id));

SignalKeys peerKeys(String nick) {
  final k = SignalKeys.generate();
  fake.devices[nick] = [
    {'device': 1, 'identityKey': k.publicBundle()['identityKey']},
  ];
  return k;
}

void main() {
  setUpAll(_setUpNetwork);

  tearDown(() async {
    await client.logout().timeout(const Duration(seconds: 5), onTimeout: () {});
    await fake.server.close(force: true);
  });

  // --- Подмена ключей злонамеренным сервером ---

  test('A19: сервер добавляет «призрачное» устройство собеседнику — клиент не шифрует ему молча', () async {
    await boot();
    final den = SignalKeys.generate(), denPub = den.publicBundle();
    final ghost = SignalKeys.generate(), ghostPub = ghost.publicBundle();
    fake.devices['den'] = [
      {'device': 1, 'identityKey': denPub['identityKey']},
    ];
    fake.bundles['den/1'] = bundleOf(denPub, 1);
    client.send('den', 'первое');
    expect(await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['to'] == 'den')), isTrue);

    // Сервер «находит» у Дена новое устройство со своим ключом.
    fake.devices['den']!.add({'device': 99, 'identityKey': ghostPub['identityKey']});
    fake.bundles['den/99'] = bundleOf(ghostPub, 99);
    fake.frames.clear();
    client.send('den', 'пароль от сейфа 1234');
    final id = client.chats['den']!.last.id;
    await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['id'] == id));
    fake.push({'type': 'error', 'id': id, 'to': 'den', 'error': 'devices'});
    String? stolen;
    await waitFor(() => fake.frames.any((f) => f['id'] == id && (f['payloads'] as List).any((p) => p['device'] == 99)));
    for (final f in fake.frames.where((f) => f['id'] == id)) {
      for (final p in f['payloads'] as List) {
        if (p['device'] == 99) stolen = await ghost.decrypt('anna', 1, p['type'], p['body']);
      }
    }
    expect(stolen, isNull, reason: 'сервер прочитал сообщение через призрачное устройство: $stolen');
  });

  test('A19: после подтверждения нового устройства сообщение уходит и на него', () async {
    await boot();
    final den = SignalKeys.generate(), denPub = den.publicBundle();
    final den2 = SignalKeys.generate(), den2Pub = den2.publicBundle();
    fake.devices['den'] = [
      {'device': 1, 'identityKey': denPub['identityKey']},
    ];
    fake.bundles['den/1'] = bundleOf(denPub, 1);
    client.send('den', 'первое');
    expect(await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['to'] == 'den')), isTrue);

    fake.devices['den']!.add({'device': 2, 'identityKey': den2Pub['identityKey']});
    fake.bundles['den/2'] = bundleOf(den2Pub, 2);
    client.send('den', 'второе');
    final m = client.chats['den']!.firstWhere((m) => m.text == 'второе');
    await waitFor(() => fake.frames.any((f) => f['id'] == m.id));
    fake.push({'type': 'error', 'id': m.id, 'to': 'den', 'error': 'devices'});
    expect(await waitFor(() => m.status == Status.failed), isTrue, reason: 'без подтверждения не отправлено');
    expect(client.hasNewDevice('den'), isTrue);
    expect(client.chats['den']!.any((m) => m.update != null && m.text.contains('новое устройство')), isTrue);

    final before = await client.safetyNumber('den');
    await client.approveDevices('den');
    expect(
      await waitFor(() => fake.frames.any((f) => f['id'] == m.id && (f['payloads'] as List).any((p) => p['device'] == 2))),
      isTrue,
    );
    final p = (fake.frames.lastWhere((f) => f['id'] == m.id)['payloads'] as List).firstWhere((p) => p['device'] == 2);
    expect(jsonDecode(await den2.decrypt('anna', 1, p['type'], p['body']))['text'], 'второе');
    expect(await client.safetyNumber('den'), isNot(before), reason: 'код учитывает подтверждённое устройство');
  });

  test('A19: сервер не может подсунуть новое устройство знакомого собеседника входящим сообщением', () async {
    await boot();
    final den = peerKeys('den');
    await acked(await deliver(den, 'den', {'text': 'привет'}));
    final ghost = SignalKeys.generate();
    await ghost.startSession('anna', bundleOf(annaPub, 1, _nextPreKey++));
    final c = await ghost.encrypt('anna', 1, jsonEncode({'text': 'это я, Ден', 'sender': 'den', 'senderDevice': 7}));
    fake.push({'type': 'message', 'id': 'g1', 'from': 'den', 'device': 7, 'ctype': c['type'], 'body': c['body'], 'sentAt': 1});
    await acked('g1');
    expect([for (final m in client.chats['den']!) m.text], isNot(contains('это я, Ден')));
    expect(client.hasNewDevice('den'), isTrue);
  });

  test('A20: код безопасности отражает ключ, на который реально шифруются сообщения', () async {
    await boot();
    final den = SignalKeys.generate(), denPub = den.publicBundle();
    final mitm = SignalKeys.generate(), mitmPub = mitm.publicBundle();
    // /api/devices показывает настоящий ключ Дена, а /api/keys отдаёт набор ключей MITM.
    fake.devices['den'] = [
      {'device': 1, 'identityKey': denPub['identityKey']},
    ];
    fake.bundles['den/1'] = bundleOf(mitmPub, 1);
    client.send('den', 'секрет');
    expect(await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['to'] == 'den')), isTrue);
    final p = (fake.frames.firstWhere((f) => f['to'] == 'den')['payloads'] as List).single;
    final read = await mitm.decrypt('anna', 1, p['type'], p['body']);
    final shown = await client.safetyNumber('den');
    final genuine = SignalKeys.safetyNumber('anna', [annaPub['identityKey']], 'den', [denPub['identityKey']]);
    expect(shown, isNot(genuine),
        reason: 'MITM прочитал «$read», а код безопасности совпадает с настоящим — сверка ничего не покажет');
  });

  test('A21: сервер не может приписать чужой шифротекст другому отправителю', () async {
    await boot();
    final den = peerKeys('den');
    await den.startSession('anna', bundleOf(annaPub, 1, _nextPreKey++));
    // Новый клиент Дена пишет отправителя внутрь шифротекста.
    final c = await den.encrypt('anna', 1, jsonEncode({'text': 'секрет Дена', 'sender': 'den', 'senderDevice': 1}));
    fake.push({'type': 'message', 'id': 'x1', 'from': 'eve', 'device': 1, 'ctype': c['type'], 'body': c['body'], 'sentAt': 1});
    await acked('x1');
    expect([for (final m in client.chats['eve'] ?? <Message>[]) m.text], isNot(contains('секрет Дена')));
  });

  test('A22: повтор (replay) старого шифротекста сервером не добавляет сообщений в чат', () async {
    await boot();
    final eve = peerKeys('eve');
    await eve.startSession('anna', bundleOf(annaPub, 1, _nextPreKey++));
    final c = await eve.encrypt('anna', 1, jsonEncode({'text': 'привет'}));
    Map<String, dynamic> frame(String id) =>
        {'type': 'message', 'id': id, 'from': 'eve', 'device': 1, 'ctype': c['type'], 'body': c['body'], 'sentAt': 1};
    fake.push(frame('r1'));
    await acked('r1');
    for (var i = 0; i < 5; i++) {
      fake.push(frame('replay$i'));
      await acked('replay$i');
    }
    expect([for (final m in client.chats['eve']!) m.text], ['привет'],
        reason: 'сервер повторами наполняет чат мусором');
  });


  test('A24: неизвестный статус квитанции не ломает обработку: сообщение подтверждается (ack)', () async {
    await boot();
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {'receipt': 'pwned', 'ids': []});
    expect(await acked(id), isTrue, reason: 'исключение вне try: ack не ушёл, сервер будет доставлять это вечно');
  });


  test('A25: вложение с не-строковым name не роняет список чатов (preview)', () async {
    await boot();
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {
      'text': '',
      'file': {'id': 'abc', 'key': 'AAAA', 'name': 42, 'size': 1},
    });
    await acked(id);
    final m = client.chats['eve']?.lastOrNull;
    expect(m == null || (() {
      try {
        m.preview;
        return true;
      } catch (e) {
        printOnFailure('preview: $e');
        return false;
      }
    })(), isTrue, reason: 'Message.preview бросает исключение: экран чатов не строится, сообщение сохранено навсегда');
  });


  // A23 добавится вместе с исправлениями этапа 4.

  test('A26: участник без прав админа не может изменить состав и админов группы', () async {
    await boot(groups: {
      '#g1': {'name': 'G', 'members': ['anna', 'den', 'eve'], 'admins': ['den'], 'v': 1},
    });
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {
      'text': '',
      'group': 'g1',
      'groupUpdate': {'name': 'G', 'members': ['anna', 'den', 'eve', 'mallory'], 'admins': ['den', 'eve'], 'v': 2, 'was': ['anna', 'den', 'eve']},
    });
    await acked(id);
    expect(client.admins('#g1'), ['den']);
    expect(client.members('#g1'), ['anna', 'den', 'eve']);
  });

  test('A27: посторонний не может переписать описание известной группы через senderKey/state', () async {
    await boot(groups: {
      '#g1': {'name': 'G', 'members': ['anna', 'den'], 'admins': ['den'], 'v': 1},
    });
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {
      'group': 'g1',
      'senderKey': await eve.senderKey('g1', 'eve', 1),
      'state': {'name': 'pwned', 'members': ['anna', 'eve'], 'admins': ['eve'], 'v': 99},
    });
    await acked(id);
    expect(client.groups['#g1']!['name'], 'G');
    expect(client.admins('#g1'), ['den']);
  });

  test('A28: исключённый участник не может писать в группу', () async {
    await boot(groups: {
      '#g1': {'name': 'G', 'members': ['anna', 'den'], 'admins': ['den'], 'v': 3},
    });
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {'text': 'я всё ещё тут', 'group': 'g1'});
    await acked(id);
    expect([for (final m in client.chats['#g1'] ?? <Message>[]) m.text], isNot(contains('я всё ещё тут')));
  });

  test('A29: собеседник не может удалить чужие сообщения или мои', () async {
    Map<String, dynamic> msg(String id, bool mine, String text) =>
        {'id': id, 'mine': mine, 'text': text, 'time': 1, 'status': 'read'};
    await boot(chats: {
      'den': [msg('d1', false, 'от Дена')],
      'eve': [msg('e1', true, 'моё')],
    });
    final eve = peerKeys('eve');
    final id = await deliver(eve, 'eve', {'delete': ['d1', 'e1']});
    await acked(id);
    expect(client.chats['den']!.map((m) => m.id), ['d1']);
    expect(client.chats['eve']!.map((m) => m.id), ['e1']);
  });

  // --- Криптография ---

  test('A30: набор ключей с поддельной подписью signed prekey отклоняется', () async {
    final a = SignalKeys.generate();
    final pub = SignalKeys.generate().publicBundle();
    final other = SignalKeys.generate().publicBundle();
    final forged = {...bundleOf(pub, 1), 'signedPreKey': {...pub['signedPreKey'], 'signature': other['signedPreKey']['signature']}};
    await expectLater(a.startSession('x', forged), throwsA(anything));
  });
}
