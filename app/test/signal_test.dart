import 'dart:convert';

import 'package:aura/signal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Публичная часть ключей так, как её отдаёт сервер в `/api/keys/<nick>/<device>`.
Map<String, dynamic> serverBundle(Map<String, dynamic> published, int device) => {
  'device': device,
  'registrationId': published['registrationId'],
  'identityKey': published['identityKey'],
  'signedPreKey': published['signedPreKey'],
  'preKey': (published['preKeys'] as List).first,
};

void main() {
  test('переписка шифруется, сессия переживает перезапуск, коды безопасности совпадают', () async {
    final anna = SignalKeys.generate();
    var den = SignalKeys.generate();
    final denPublished = den.publicBundle();
    final annaPublished = anna.publicBundle();

    await anna.startSession('den', serverBundle(denPublished, 1));
    final first = await anna.encrypt('den', 1, 'Привет!');
    expect(first['type'], 3, reason: 'первое сообщение несёт установку сессии');
    expect(first['body'], isNot(contains('Привет')));
    expect(await den.decrypt('anna', 1, first['type'], first['body']), 'Привет!');

    // Денис перезапустил приложение: ключи и сессия восстанавливаются из сохранённого.
    den = SignalKeys.fromJson(den.toJson());
    final reply = await den.encrypt('anna', 1, 'Привет, Анна');
    expect(reply['type'], 2);
    expect(await anna.decrypt('den', 1, reply['type'], reply['body']), 'Привет, Анна');
    final again = await anna.encrypt('den', 1, 'Как дела?');
    expect(await den.decrypt('anna', 1, again['type'], again['body']), 'Как дела?');

    // Повтор шифротекста не расшифровывается второй раз.
    await expectLater(den.decrypt('anna', 1, again['type'], again['body']), throwsA(anything));

    final a = annaPublished['identityKey'] as String, d = denPublished['identityKey'] as String;
    final annaSees = SignalKeys.safetyNumber('anna', [a], 'den', [d]);
    expect(annaSees, hasLength(60));
    expect(SignalKeys.safetyNumber('den', [d], 'anna', [a]), annaSees);
    final fake = SignalKeys.generate().publicBundle()['identityKey'] as String;
    expect(SignalKeys.safetyNumber('anna', [a], 'den', [fake]), isNot(annaSees));
  });

  test('подмена ключа на известном адресе отклоняется', () async {
    final anna = SignalKeys.generate();
    final den = SignalKeys.generate().publicBundle();
    await anna.startSession('den', serverBundle(den, 1));
    final impostor = SignalKeys.generate().publicBundle();
    await expectLater(anna.startSession('den', serverBundle(impostor, 1)), throwsA(anything));
  });

  test('старые ключи по адресам сводятся к ключу самого старого устройства', () async {
    final anna = SignalKeys.generate(), den = SignalKeys.generate(), den2 = SignalKeys.generate();
    await anna.startSession('den', serverBundle(den.publicBundle(), 1));
    final other = SignalKeys.fromJson(anna.toJson())..untrust('den');
    await other.startSession('den', serverBundle(den2.publicBundle(), 2));
    // Формат до одного ключа на аккаунт: «ник:устройство» → ключ, у каждого устройства свой.
    final old = jsonDecode(anna.toJson());
    old['sessions']['den:2'] = jsonDecode(other.toJson())['sessions']['den:2'];
    old['trusted'] = {'den:2': den2.identityKey, 'den:1': den.identityKey};
    final migrated = SignalKeys.fromJson(jsonEncode(old));
    expect(migrated.identityOf('den'), den.identityKey);
    expect(migrated.hasSession('den', 1), isTrue);
    expect(migrated.hasSession('den', 2), isFalse, reason: 'сессия с чужим ключом забыта');

    // Устройство 1 вышло, ключом аккаунта на сервере стал ключ устройства 2: ему уже доверяли.
    final restarted = SignalKeys.fromJson(migrated.toJson());
    await restarted.startSession('den', serverBundle(den2.publicBundle(), 2));
    expect(restarted.identityOf('den'), den2.identityKey);
    final impostor = SignalKeys.generate().publicBundle();
    await expectLater(
      SignalKeys.fromJson(migrated.toJson()).startSession('den', serverBundle(impostor, 3)),
      throwsA(anything),
      reason: 'ключ, которому не доверяли, по-прежнему требует подтверждения',
    );
  });

  test('ключ отправителя в группе: шифрует для всех, переживает перезапуск и смену', () async {
    final anna = SignalKeys.generate();
    var den = SignalKeys.generate();
    final key = await anna.senderKey('g', 'anna', 1);
    await den.processSenderKey('g', 'anna', 1, key);
    final first = await anna.groupEncrypt('g', 'anna', 1, 'Всем привет');
    // Повтор того же ключа (например, после перезапуска) не ломает сообщения, отправленные до него.
    await den.processSenderKey('g', 'anna', 1, await anna.senderKey('g', 'anna', 1));
    den = SignalKeys.fromJson(den.toJson());
    expect(await den.groupDecrypt('g', 'anna', 1, first), 'Всем привет');

    // После исключения участника ключ новый: старый ключ его не расшифрует.
    anna.dropSenderKey('g', 'anna', 1);
    await anna.senderKey('g', 'anna', 1);
    final secret = await anna.groupEncrypt('g', 'anna', 1, 'без Дениса');
    await expectLater(den.groupDecrypt('g', 'anna', 1, secret), throwsA(anything));
  });
}
