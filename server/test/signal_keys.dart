import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Настоящие ключи для тестов: сервер проверяет подпись signed prekey.
/// Метка ('idDen') всегда даёт один и тот же ключ личности.
final _pairs = <String, IdentityKeyPair>{};

IdentityKeyPair _pair(String label) => _pairs.putIfAbsent(label, generateIdentityKeyPair);

/// Публичный ключ личности по метке, base64.
String id(String label) => base64.encode(_pair(label).getPublicKey().serialize());

/// Signed prekey, подписанный ключом личности с меткой [label].
Map<String, dynamic> signedPreKey(String label) {
  final spk = generateSignedPreKey(_pair(label), 1);
  return {
    'id': 1,
    'key': base64.encode(spk.getKeyPair().publicKey.serialize()),
    'signature': base64.encode(spk.signature),
  };
}
