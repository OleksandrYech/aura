// Новые атаки (A33–A35), найденные при перепроверке 2026-10-23. Тот же стенд, что в adversarial_test.dart:
// настоящий AuraClient против поддельного сервера. Красный тест = подтверждённая уязвимость.
@Timeout(Duration(seconds: 30))
// ignore_for_file: depend_on_referenced_packages
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aura/client.dart';
import 'package:aura/media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'adversarial_test.dart' as a;

final class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => '$dir/tmp';
}

Map<String, dynamic> _msg(String id, bool mine, String status, [Map<String, dynamic>? file]) =>
    {'id': id, 'mine': mine, 'text': '', 'time': 1, 'status': status, 'file': ?file};

void main() {
  setUpAll(a.setUpNetwork);

  tearDown(() async {
    await client.logout().timeout(const Duration(seconds: 5), onTimeout: () {});
    await a.fake.server.close(force: true);
  });

  test('A33: посторонний не может отметить моё сообщение другому собеседнику как «прочитано»', () async {
    await a.boot(chats: {
      'den': [_msg('d1', true, 'sent')],
    });
    final eve = a.peerKeys('eve');
    final id = await a.deliver(eve, 'eve', {'receipt': 'read', 'ids': ['d1']});
    await a.acked(id);
    expect(client.chats['den']!.single.status, Status.sent,
        reason: 'eve поставила «прочитано» сообщению, которое Ден не видел');
  });

  test('A34: вложение с чужим id не подменяет содержимое файла в другом чате (кэш по id без ключа)', () async {
    await a.boot();
    final denKey = FileCrypto.newKey(), eveKey = FileCrypto.newKey();
    const id = '0123456789abcdef0123456789abcdef';
    final fake = Uint8List.fromList(utf8.encode('картинка от сервера'));
    // Сервер отдаёт под id фото Дена шифротекст на ключе eve (её подставное сообщение).
    a.fake.files[id] = FileCrypto.encrypt(eveKey, fake);
    final eveFile = {'id': id, 'key': base64.encode(eveKey), 'name': 'a.jpg', 'size': fake.length};
    final denFile = {'id': id, 'key': base64.encode(denKey), 'name': 'a.jpg', 'size': fake.length};
    await a.acked(await a.deliver(a.peerKeys('eve'), 'eve', {'text': '', 'file': eveFile}));
    await a.acked(await a.deliver(a.peerKeys('den'), 'den', {'text': '', 'file': denFile}));
    await client.fileBytes(client.chats['eve']!.single.file!); // открыли чат eve, картинка загрузилась
    Uint8List? shown;
    try {
      shown = await client.fileBytes(client.chats['den']!.single.file!);
    } catch (_) {} // ключ Дена не подходит: правильная реакция — ошибка
    expect(shown == null ? null : utf8.decode(shown), isNot('картинка от сервера'),
        reason: 'в чате Дена показано содержимое, зашифрованное не его ключом');
  });

  test('A35: собеседник удаляет своё сообщение с чужим id файла — стирается моя копия файла из другого чата', () async {
    final dir = Directory.systemTemp.createTempSync('aura_paths');
    PathProviderPlatform.instance = _Paths(dir.path);
    const id = 'fedcba9876543210fedcba9876543210';
    final denFile = {'id': id, 'key': base64.encode(FileCrypto.newKey()), 'name': 'doc.pdf', 'size': 5};
    await a.boot(chats: {
      'den': [_msg('d1', false, 'read', denFile)],
    });
    final local = File('${dir.path}/files/$id.pdf')
      ..createSync(recursive: true)
      ..writeAsStringSync('12345'); // уже скачанная копия документа Дена
    final eve = a.peerKeys('eve');
    final m = await a.deliver(eve, 'eve', {'text': '', 'file': {...denFile, 'key': base64.encode(FileCrypto.newKey())}});
    await a.acked(m);
    await a.acked(await a.deliver(eve, 'eve', {'delete': [m]}));
    await Future<void>.delayed(const Duration(milliseconds: 300)); // удаление идёт в очереди _forgetting
    expect(local.existsSync(), isTrue, reason: 'eve стёрла с устройства файл из чата Дена');
  });
}
