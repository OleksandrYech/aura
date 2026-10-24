// Новые адверсариальные проверки клиента (B-серия): настоящий AuraClient против поддельного
// злонамеренного сервера. Каждый тест утверждает безопасное поведение; красный тест = уязвимость.
// Сетевой каркас скопирован из adversarial_test.dart (приватные члены оттуда не импортируются).
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aura/client.dart';
import 'package:aura/media.dart';
import 'package:aura/signal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

int _proxyPort = 0, _tlsPort = 0;
late SecurityContext _serverTls;

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
    c.done.ignore();
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
        c.destroy();
      }
    }, onDone: () => up?.destroy(), onError: (_) => up?.destroy());
  });
  IOOverrides.global = _Redirect();
  HttpOverrides.global = _ViaProxy();
}

class _Fake {
  late HttpServer server;
  WebSocket? ws;
  final frames = <Map<String, dynamic>>[];
  final devices = <String, List<Map<String, dynamic>>>{};
  final bundles = <String, Map<String, dynamic>>{};

  /// Сырые байты файлов по id (ответ на GET /api/files/<id>): сервер хранит шифротекст.
  final fileBytes = <String, Uint8List>{};
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
      final seg = req.uri.pathSegments;
      // Скачивание файла: отдаём сырые байты (не JSON), как настоящий сервер.
      if (req.method == 'GET' && seg.length == 3 && seg[1] == 'files' && fileBytes.containsKey(seg[2])) {
        req.response
          ..headers.contentType = ContentType.binary
          ..add(fileBytes[seg[2]]!);
        await req.response.close();
        return;
      }
      final body = await utf8.decoder.bind(req).join();
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

late _Fake fake;
late SignalKeys anna;
late Map<String, dynamic> annaPub;
var _nextPreKey = 0, _nextId = 0;

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

  test('B1: участник-не-админ не может назначить админом другого участника, «выходя» из группы', () async {
    // Группа: админ den; eve и mallory — обычные участники. anna наблюдает.
    await boot(groups: {
      '#g1': {'name': 'G', 'members': ['anna', 'den', 'eve', 'mallory'], 'admins': ['den'], 'v': 1},
    });
    final eve = peerKeys('eve');
    // eve убирает только себя (состав-минус-eve проходит проверку «участник может только выйти»),
    // но тем же сообщением повышает mallory до админа.
    final id = await deliver(eve, 'eve', {
      'text': '',
      'group': 'g1',
      'groupUpdate': {
        'name': 'G',
        'members': ['anna', 'den', 'mallory'],
        'admins': ['den', 'mallory'],
        'v': 2,
        'was': ['anna', 'den', 'eve', 'mallory'],
      },
    });
    await acked(id);
    expect(client.admins('#g1'), isNot(contains('mallory')),
        reason: 'не-админ eve единолично сделал mallory админом — обход модели прав группы');
  });

  test('B2: вложение расшифровывается своим ключом, а не берётся из кэша по одному id', () async {
    await boot();
    // Злонамеренный сервер выдал двум загрузкам один и тот же id: байты на сервере — от Евы.
    final eveKey = FileCrypto.newKey();
    final evePlain = utf8.encode('подделка от Евы');
    fake.fileBytes['F'] = FileCrypto.encrypt(eveKey, Uint8List.fromList(evePlain));
    final eveFile = {'id': 'F', 'key': base64.encode(eveKey), 'name': 'eve.jpg', 'size': evePlain.length};

    // Сообщение Евы: anna открывает её «фото», клиент кэширует расшифровку по id F.
    final got1 = await client.fileBytes(eveFile);
    expect(utf8.decode(got1), 'подделка от Евы');

    // Сообщение Дена ссылается на тот же id F, но своим ключом (сервер переиспользовал id).
    // Правильно: скачать F и расшифровать ключом Дена → провал GCM → ошибка «подменён».
    final denKey = FileCrypto.newKey();
    final denFile = {'id': 'F', 'key': base64.encode(denKey), 'name': 'den.jpg', 'size': 7};
    Object? shown;
    try {
      shown = utf8.decode(await client.fileBytes(denFile));
    } catch (_) {
      shown = null; // отказ — безопасно
    }
    expect(shown, isNot('подделка от Евы'),
        reason: 'кэш по одному id: вложение Евы показано как вложение Дена, ключ Дена не проверен');
  });
}
