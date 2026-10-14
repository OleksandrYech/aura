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
}
