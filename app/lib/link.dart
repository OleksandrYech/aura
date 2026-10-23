import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:pointycastle/export.dart' show HKDFKeyDerivator, HkdfParameters, SHA256Digest;

import 'media.dart';

/// Конверт привязки: старое устройство передаёт новому ключ личности аккаунта.
/// Новое устройство показывает в QR временный публичный ключ X25519, старое делает свой временный
/// ключ, и из общего секрета (HKDF-SHA256) получается ключ AES-GCM. Сервер только пересылает
/// конверт и прочитать его не может: временный ключ нового устройства шёл с экрана на камеру.
/// Ник и номер устройства-получателя лежат внутри и проверяются при вскрытии.
class LinkEnvelope {
  static const _info = 'AURA link v1';

  /// Старое устройство: конверт для нового устройства [device] аккаунта [nick].
  static String seal(ECPublicKey to, IdentityKeyPair identity, String nick, int device) {
    final mine = Curve.generateKeyPair();
    final from = mine.publicKey.serialize();
    final plain = utf8.encode(
      jsonEncode({'identity': base64.encode(identity.serialize()), 'nick': nick, 'device': device}),
    );
    final sealed = FileCrypto.encryptPart(
      _key(Curve.calculateAgreement(to, mine.privateKey), from, to),
      0,
      true,
      plain,
    );
    return jsonEncode({'from': base64.encode(from), 'sealed': base64.encode(sealed)});
  }

  /// Новое устройство: ключ аккаунта из конверта. Бросает [FormatException], если конверт
  /// повреждён, зашифрован не для [mine] или выписан другому аккаунту либо устройству.
  static IdentityKeyPair open(String envelope, ECKeyPair mine, String nick, int device) {
    try {
      final e = jsonDecode(envelope) as Map;
      final from = Curve.decodePoint(base64.decode(e['from'] as String), 0);
      final key = _key(Curve.calculateAgreement(from, mine.privateKey), from.serialize(), mine.publicKey);
      final inner = jsonDecode(utf8.decode(FileCrypto.decryptPart(key, 0, true, base64.decode(e['sealed'] as String))));
      if (inner['nick'] != nick || inner['device'] != device) throw const FormatException('чужой конверт');
      return IdentityKeyPair.fromSerialized(base64.decode(inner['identity'] as String));
    } catch (_) {
      throw const FormatException('Конверт привязки повреждён или не для этого устройства');
    }
  }

  /// Ключ AES из общего секрета; соль — оба временных ключа, чтобы ключ был у каждой пары свой.
  static Uint8List _key(Uint8List shared, Uint8List from, ECPublicKey to) {
    final salt = Uint8List.fromList([...from, ...to.serialize()]);
    final hkdf = HKDFKeyDerivator(SHA256Digest())..init(HkdfParameters(shared, 32, salt, utf8.encode(_info)));
    final out = Uint8List(32);
    hkdf.deriveKey(null, 0, out, 0);
    return out;
  }
}
