// Адверсариальные проверки клиента: настоящий AuraClient подключается к поддельному (злонамеренному)
// серверу на localhost, а «собеседники» — настоящие SignalKeys. Каждый тест утверждает безопасное
// поведение; красный тест = подтверждённая уязвимость.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aura/client.dart';
import 'package:aura/link.dart';
import 'package:aura/signal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart' show Curve;
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

  /// Свои ответы на «МЕТОД /путь» (тело запроса — строкой); остальное отвечает по умолчанию.
  final routes = <String, FutureOr<Object?> Function(String body)>{};
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
      final body = await utf8.decoder.bind(req).join();
      final seg = req.uri.pathSegments;
      Object? res = {};
      if (routes['${req.method} ${req.uri.path}'] case final route?) res = await route(body);
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
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  setUpAll(_setUpNetwork);

  tearDown(() async {
    await client.logout().timeout(const Duration(seconds: 5), onTimeout: () {});
    await fake.server.close(force: true);
  });

  test('ключи переезжают из SharedPreferences в защищённое хранилище', () async {
    await boot(); // старая версия хранила ключи в SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('signal'), isNull);
    expect(await const FlutterSecureStorage().read(key: 'signal'), isNotNull);
    await client.logout();
    expect(await const FlutterSecureStorage().read(key: 'signal'), isNull, reason: 'выход стирает ключи');
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

  test('A19: новое устройство с ключом аккаунта принимается само, смена ключа — после подтверждения', () async {
    await boot();
    final den = SignalKeys.generate(), denPub = den.publicBundle();
    final den2 = SignalKeys.generate(await den.getIdentityKeyPair()), den2Pub = den2.publicBundle();
    fake.devices['den'] = [
      {'device': 1, 'identityKey': denPub['identityKey']},
    ];
    fake.bundles['den/1'] = bundleOf(denPub, 1);
    client.send('den', 'первое');
    expect(await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['to'] == 'den')), isTrue);
    final before = await client.safetyNumber('den');

    // Ден привязал второе устройство: ключ тот же, подтверждать нечего, код не меняется.
    fake.devices['den']!.add({'device': 2, 'identityKey': den2Pub['identityKey']});
    fake.bundles['den/2'] = bundleOf(den2Pub, 2);
    client.send('den', 'второе');
    final m2 = client.chats['den']!.firstWhere((m) => m.text == 'второе');
    await waitFor(() => fake.frames.any((f) => f['id'] == m2.id));
    fake.push({'type': 'error', 'id': m2.id, 'to': 'den', 'error': 'devices'});
    expect(
      await waitFor(() => fake.frames.any((f) => f['id'] == m2.id && (f['payloads'] as List).any((p) => p['device'] == 2))),
      isTrue,
    );
    final p2 = (fake.frames.lastWhere((f) => f['id'] == m2.id)['payloads'] as List).firstWhere((p) => p['device'] == 2);
    expect(jsonDecode(await den2.decrypt('anna', 1, p2['type'], p2['body']))['text'], 'второе');
    expect(client.hasNewDevice('den'), isFalse);
    expect(await client.safetyNumber('den'), before, reason: 'новое устройство код безопасности не меняет');

    // Ден начал заново: старых устройств нет, у нового другой ключ аккаунта.
    final reset = SignalKeys.generate(), resetPub = reset.publicBundle();
    fake.devices['den'] = [
      {'device': 3, 'identityKey': resetPub['identityKey']},
    ];
    fake.bundles['den/3'] = bundleOf(resetPub, 3);
    client.send('den', 'третье');
    final m3 = client.chats['den']!.firstWhere((m) => m.text == 'третье');
    await waitFor(() => fake.frames.any((f) => f['id'] == m3.id));
    fake.push({'type': 'error', 'id': m3.id, 'to': 'den', 'error': 'devices'});
    expect(await waitFor(() => m3.status == Status.failed), isTrue, reason: 'без подтверждения не отправлено');
    expect(client.hasNewDevice('den'), isTrue);
    expect(client.chats['den']!.any((m) => m.update != null && m.text.contains('Код безопасности')), isTrue);

    client.setVerified('den', true);
    await client.approveDevices('den');
    expect(client.verified, isNot(contains('den')), reason: 'отметка «Сверено» снимается при смене ключа');
    expect(
      await waitFor(() => fake.frames.any((f) => f['id'] == m3.id && (f['payloads'] as List).any((p) => p['device'] == 3))),
      isTrue,
    );
    final p3 = (fake.frames.lastWhere((f) => f['id'] == m3.id)['payloads'] as List).single;
    expect(jsonDecode(await reset.decrypt('anna', 1, p3['type'], p3['body']))['text'], 'третье');
    expect(await client.safetyNumber('den'), isNot(before), reason: 'код безопасности учитывает новый ключ');
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

  test('A19: собеседник сбросил ключ на том же устройстве — после «Принять» переписка идёт в обе стороны', () async {
    await boot();
    final den = peerKeys('den');
    await acked(await deliver(den, 'den', {'text': 'привет'}));
    client.send('den', 'до сброса');
    final m0 = client.chats['den']!.firstWhere((m) => m.text == 'до сброса');
    expect(await waitFor(() => fake.frames.any((f) => f['id'] == m0.id)), isTrue);
    fake.push({'type': 'sent', 'id': m0.id, 'to': 'den'});
    expect(await waitFor(() => m0.status == Status.sent), isTrue);

    // Номер устройства тот же, ключ новый: сервер сообщения по старой сессии принимает.
    final reset = SignalKeys.generate(), resetPub = reset.publicBundle();
    fake.devices['den'] = [
      {'device': 1, 'identityKey': resetPub['identityKey']},
    ];
    fake.bundles['den/1'] = bundleOf(resetPub, 1);
    await acked(await deliver(reset, 'den', {'text': 'я начал заново'}));
    expect(client.hasNewDevice('den'), isTrue);
    expect([for (final m in client.chats['den']!) m.text], isNot(contains('я начал заново')));

    client.send('den', 'пока не принято');
    final m1 = client.chats['den']!.firstWhere((m) => m.text == 'пока не принято');
    expect(await waitFor(() => m1.status == Status.failed), isTrue, reason: 'по старой сессии не уходит');
    expect(fake.frames.any((f) => f['id'] == m1.id), isFalse);

    await client.approveDevices('den');
    expect(await waitFor(() => client.chats['den']!.any((m) => m.text == 'я начал заново')), isTrue,
        reason: 'отложенное входящее читается после принятия');
    for (final m in [m0, m1]) {
      expect(await waitFor(() => fake.frames.where((f) => f['id'] == m.id && f['to'] == 'den').length > (m == m0 ? 1 : 0)), isTrue);
      final p = (fake.frames.lastWhere((f) => f['id'] == m.id && f['to'] == 'den')['payloads'] as List).single;
      expect(jsonDecode(await reset.decrypt('anna', 1, p['type'], p['body']))['text'], m.text);
    }
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


  test('A23: время сообщения не задаётся сервером произвольно (метаданные не связаны с шифротекстом)', () async {
    await boot();
    final eve = peerKeys('eve');
    // Новый клиент кладёт своё время внутрь шифротекста, сервер подставляет 2001 год.
    final id = await deliver(eve, 'eve', {'text': 'сейчас', 'time': DateTime.now().millisecondsSinceEpoch},
        sentAt: DateTime(2001).millisecondsSinceEpoch);
    await acked(id);
    final t = DateTime.fromMillisecondsSinceEpoch(client.chats['eve']!.single.time);
    expect(DateTime.now().difference(t).inDays.abs(), lessThan(1), reason: 'сообщение показано датой $t');
  });

  // --- Злонамеренный собеседник ---


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

  // --- Привязка устройства (план «Один ключ на аккаунт», PR 4) ---

  test('новое устройство получает ключ аккаунта от старого и публикует prekey, подписанные им', () async {
    fake = _Fake();
    await fake.start();
    anna = SignalKeys.generate();
    annaPub = anna.publicBundle();
    SharedPreferences.setMockInitialValues({});
    await client.load();
    final envelope = Completer<String>();
    Map<String, dynamic>? published;
    fake.routes['POST /api/login'] = (_) =>
        {'token': 't2', 'nick': 'anna', 'name': 'Anna', 'device': 2, 'identityKey': annaPub['identityKey']};
    fake.routes['GET /api/link'] = (_) async => {'envelope': await envelope.future};
    fake.routes['PUT /api/keys'] = (body) => published = jsonDecode(body);

    await client.login('anna', 'pw');
    expect(client.needsLink, isTrue);
    expect(client.signedIn, isFalse, reason: 'без ключа аккаунта вход не завершён');
    expect(published, isNull, reason: 'своих ключей личности новое устройство не создаёт');

    final code = jsonDecode(utf8.decode(base64Url.decode(client.startLinking())));
    expect(code, containsPair('device', 2));
    final to = Curve.decodePoint(base64.decode(code['key']), 0);
    envelope.complete(LinkEnvelope.seal(to, await anna.getIdentityKeyPair(), 'anna', 2));

    expect(await waitFor(() => client.signedIn), isTrue);
    expect(published!['identityKey'], annaPub['identityKey']);
    // Собеседник принимает набор ключей: signed prekey подписан ключом аккаунта.
    await SignalKeys.generate().startSession('anna', bundleOf(published!, 2));
  });

  test('конверт с ключом не этого аккаунта не завершает привязку', () async {
    fake = _Fake();
    await fake.start();
    anna = SignalKeys.generate();
    annaPub = anna.publicBundle();
    SharedPreferences.setMockInitialValues({});
    await client.load();
    final envelope = Completer<String>();
    fake.routes['POST /api/login'] = (_) =>
        {'token': 't2', 'nick': 'anna', 'name': 'Anna', 'device': 2, 'identityKey': annaPub['identityKey']};
    fake.routes['GET /api/link'] = (_) async => {'envelope': await envelope.future};

    await client.login('anna', 'pw');
    final code = jsonDecode(utf8.decode(base64Url.decode(client.startLinking())));
    final mallory = await SignalKeys.generate().getIdentityKeyPair();
    envelope.complete(LinkEnvelope.seal(Curve.decodePoint(base64.decode(code['key']), 0), mallory, 'anna', 2));

    expect(await waitFor(() => client.linkError != null), isTrue);
    expect(client.signedIn, isFalse);
  });

  test('начать заново: без старых устройств вход с новым ключом аккаунта', () async {
    fake = _Fake();
    await fake.start();
    anna = SignalKeys.generate();
    annaPub = anna.publicBundle();
    SharedPreferences.setMockInitialValues({});
    await client.load();
    Map<String, dynamic>? published;
    String? password;
    fake.routes['POST /api/login'] = (_) =>
        {'token': 't2', 'nick': 'anna', 'name': 'Anna', 'device': 2, 'identityKey': annaPub['identityKey']};
    fake.routes['POST /api/identity/reset'] = (body) => {'ok': password = jsonDecode(body)['password']};
    fake.routes['PUT /api/keys'] = (body) => published = jsonDecode(body);

    await client.login('anna', 'pw');
    expect(client.needsLink, isTrue);
    await client.resetAccount('pw');
    expect(password, 'pw');
    expect(client.signedIn, isTrue);
    expect(published!['identityKey'], isNot(annaPub['identityKey']), reason: 'новый ключ аккаунта');
  });

  test('старое устройство отправляет конверт по коду из QR своего аккаунта', () async {
    await boot();
    String? sent;
    fake.routes['POST /api/link/2'] = (body) {
      sent = jsonDecode(body)['envelope'];
      return {};
    };
    final mine = Curve.generateKeyPair();
    String code(String nick) => base64Url.encode(
      utf8.encode(jsonEncode({'nick': nick, 'device': 2, 'key': base64.encode(mine.publicKey.serialize())})),
    );

    Future<bool> yes(String name, int device) async => true;
    await expectLater(client.linkDevice(code('eve'), yes), throwsA(isA<ApiException>()), reason: 'чужой аккаунт');
    await expectLater(client.linkDevice('мусор', yes), throwsA(isA<ApiException>()));
    await client.linkDevice(code('anna'), (name, device) async => false);
    expect(sent, isNull, reason: 'без подтверждения конверт не уходит');

    await client.linkDevice(code('anna'), (name, device) async => device == 2);
    final identity = LinkEnvelope.open(sent!, mine, 'anna', 2);
    expect(base64.encode(identity.getPublicKey().serialize()), annaPub['identityKey']);
  });

  test('ответ, пересылка и реакции приходят внутри шифротекста; мусор и чужие реакции не применяются', () async {
    await boot(chats: {
      'den': [
        {'id': 'm1', 'mine': true, 'text': 'привет', 'time': 1, 'status': 'read'},
      ],
    });
    final den = peerKeys('den'), eve = peerKeys('eve');
    await acked(await deliver(den, 'den', {
      'text': 'и тебе',
      'reply': {'id': 'm1', 'from': 'anna', 'text': 'привет'},
      'fwd': 'Олег',
    }));
    final m = client.chats['den']!.last;
    expect(m.reply, {'id': 'm1', 'from': 'anna', 'text': 'привет'});
    expect(m.fwd, 'Олег');

    await acked(await deliver(den, 'den', {'receipt': 'react', 'ids': ['m1'], 'emoji': '🔥'}));
    await acked(await deliver(den, 'den', {'receipt': 'react', 'ids': ['m1'], 'emoji': 'x' * 100}));
    await acked(await deliver(eve, 'eve', {'receipt': 'react', 'ids': ['m1'], 'emoji': '💩'}));
    expect(client.chats['den']!.first.reactions, {'den': '🔥'}, reason: 'длинный мусор и реакция из чужого чата отброшены');
    await acked(await deliver(den, 'den', {'receipt': 'react', 'ids': ['m1'], 'emoji': null}));
    expect(client.chats['den']!.first.reactions, isEmpty);

    await acked(await deliver(den, 'den', {'poll': 'из будущей версии'}));
    expect(client.chats['den'], hasLength(2), reason: 'неизвестный тип не показывается пустым пузырём');
  });

  test('реакция уходит квитанцией, которую старые версии пропускают; пересылка — с теми же вложениями', () async {
    await boot(chats: {
      'den': [
        {'id': 'm1', 'mine': false, 'text': '', 'time': 1, 'status': 'read', 'file': {'id': 'f', 'key': 'k', 'name': 'a.jpg', 'size': 3}},
      ],
    });
    final den = peerKeys('den');
    fake.bundles['den/1'] = bundleOf(den.publicBundle(), 1);
    final m = client.chats['den']!.single;
    client.react('den', m, '👍');
    expect(m.reactions, {'anna': '👍'});
    expect(await waitFor(() => fake.frames.any((f) => f['type'] == 'send' && f['to'] == 'den')), isTrue);
    final p = (fake.frames.firstWhere((f) => f['type'] == 'send' && f['to'] == 'den')['payloads'] as List).single;
    final content = jsonDecode(await den.decrypt('anna', 1, p['type'], p['body']));
    expect(content, containsPair('receipt', 'react'));
    expect(content, isNot(contains('text')), reason: 'без text старая версия не создаст сообщение');

    client.forward('den', [m], 'den');
    final f = client.chats['den']!.last;
    expect(f.fwd, 'den');
    expect(f.file, {'id': 'f', 'key': 'k', 'name': 'a.jpg', 'size': 3});
    expect(identical(f.file, m.file), isFalse);
  });
}
