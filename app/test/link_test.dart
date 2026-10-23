import 'package:aura/link.dart';
import 'package:aura/signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  final identity = generateIdentityKeyPair();
  final broken = throwsA(isA<FormatException>());

  test('новое устройство получает ключ аккаунта из конверта', () async {
    final mine = Curve.generateKeyPair();
    final opened = LinkEnvelope.open(LinkEnvelope.seal(mine.publicKey, identity, 'den', 3), mine, 'den', 3);
    expect(opened.serialize(), identity.serialize());
    final keys = SignalKeys.generate(opened);
    expect(keys.publicBundle()['identityKey'], SignalKeys.generate(identity).publicBundle()['identityKey']);
    expect(await keys.getIdentityKeyPair(), opened);
  });

  test('чужим ключом, после порчи или для другого адресата конверт не вскрыть', () {
    final mine = Curve.generateKeyPair();
    final envelope = LinkEnvelope.seal(mine.publicKey, identity, 'den', 3);
    expect(() => LinkEnvelope.open(envelope, Curve.generateKeyPair(), 'den', 3), broken, reason: 'чужой ключ');
    expect(() => LinkEnvelope.open(envelope, mine, 'eve', 3), broken, reason: 'другой аккаунт');
    expect(() => LinkEnvelope.open(envelope, mine, 'den', 4), broken, reason: 'другое устройство');
    final flipped = envelope.replaceRange(
      envelope.length - 6,
      envelope.length - 5,
      envelope[envelope.length - 6] == 'A' ? 'B' : 'A',
    );
    expect(() => LinkEnvelope.open(flipped, mine, 'den', 3), broken, reason: 'испорченный шифротекст');
    expect(() => LinkEnvelope.open('{}', mine, 'den', 3), broken, reason: 'мусор');
  });
}
