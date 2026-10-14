import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Ключи Signal Protocol этого устройства и сессии с собеседниками.
/// Приватные ключи не покидают устройство: на сервер уходят только публичные части.
// ponytail: хранится в SharedPreferences, перейти на защищённое хранилище ОС (Keychain/Keystore) вместе с биометрией.
// ponytail: signed prekey не ротируется, добавить ротацию раз в месяц.
class SignalKeys extends InMemorySignalProtocolStore {
  SignalKeys._(this._identity, this._registrationId, this.nextPreKeyId) : super(_identity, _registrationId);

  final IdentityKeyPair _identity;
  final int _registrationId;
  int nextPreKeyId;

  /// Ключи собеседников по адресу «ник:устройство». Адрес на сервере не переиспользуется,
  /// поэтому другой ключ на известном адресе означает подмену, и такая сессия не устанавливается.
  final _trusted = <SignalProtocolAddress, IdentityKey>{};

  static const preKeyBatch = 50;

  factory SignalKeys.generate() {
    final keys = SignalKeys._(generateIdentityKeyPair(), generateRegistrationId(false), 1);
    final spk = generateSignedPreKey(keys._identity, 1);
    keys.signedPreKeyStore.store[spk.id] = spk.serialize();
    return keys;
  }

  /// Все публичные ключи для первой публикации на сервере.
  Map<String, dynamic> publicBundle() {
    final spk = SignedPreKeyRecord.fromSerialized(signedPreKeyStore.store.values.single);
    return {
      'registrationId': _registrationId,
      'identityKey': _b64(_identity.getPublicKey().serialize()),
      'signedPreKey': {
        'id': spk.id,
        'key': _b64(spk.getKeyPair().publicKey.serialize()),
        'signature': _b64(spk.signature),
      },
      'preKeys': newPreKeys(),
    };
  }

  /// Новая пачка одноразовых prekey: приватные части остаются здесь, публичные уходят на сервер.
  List<Map<String, dynamic>> newPreKeys() {
    final batch = generatePreKeys(nextPreKeyId, preKeyBatch);
    nextPreKeyId += preKeyBatch;
    for (final p in batch) {
      preKeyStore.store[p.id] = p.serialize();
    }
    return [
      for (final p in batch) {'id': p.id, 'key': _b64(p.getKeyPair().publicKey.serialize())},
    ];
  }

  // --- Шифрование ---

  bool hasSession(String nick, int device) => sessionStore.sessions.containsKey(SignalProtocolAddress(nick, device));

  /// X3DH по набору ключей с сервера: {device, registrationId, identityKey, signedPreKey, preKey?}.
  Future<void> startSession(String nick, Map<String, dynamic> b) {
    final spk = b['signedPreKey'], pk = b['preKey'];
    return SessionBuilder.fromSignalStore(this, SignalProtocolAddress(nick, b['device'])).processPreKeyBundle(
      PreKeyBundle(
        b['registrationId'],
        b['device'],
        pk?['id'],
        pk == null ? null : Curve.decodePoint(_bytes(pk['key']), 0),
        spk['id'],
        Curve.decodePoint(_bytes(spk['key']), 0),
        _bytes(spk['signature']),
        IdentityKey.fromBytes(_bytes(b['identityKey']), 0),
      ),
    );
  }

  /// Шифротекст для одного устройства: {device, type, body}.
  Future<Map<String, dynamic>> encrypt(String nick, int device, String plaintext) async {
    final c = await SessionCipher.fromStore(this, SignalProtocolAddress(nick, device)).encrypt(utf8.encode(plaintext));
    return {'device': device, 'type': c.getType(), 'body': _b64(c.serialize())};
  }

  Future<String> decrypt(String nick, int device, int type, String body) async {
    final cipher = SessionCipher.fromStore(this, SignalProtocolAddress(nick, device));
    final bytes = _bytes(body);
    final plain = type == CiphertextMessage.prekeyType
        ? await cipher.decrypt(PreKeySignalMessage(bytes))
        : await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
    return utf8.decode(plain);
  }

  /// Код безопасности из 60 цифр: одинаковый у обоих собеседников, пока никто не подменил ключи.
  /// Ключи — все устройства каждого аккаунта (base64, как их отдаёт сервер).
  static String safetyNumber(String me, List<String> myKeys, String peer, List<String> peerKeys) {
    List<IdentityKey> ids(List<String> keys) => [for (final k in keys) IdentityKey.fromBytes(_bytes(k), 0)];
    return NumericFingerprintGenerator(5200)
        .createListFor(2, utf8.encode(me), ids(myKeys), utf8.encode(peer), ids(peerKeys))
        .displayableFingerprint
        .getDisplayText();
  }

  // --- Доверие к ключам собеседников ---

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    final known = _trusted[address];
    return identityKey != null && (known == null || known == identityKey);
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null || _trusted[address] == identityKey) return false;
    _trusted[address] = identityKey;
    return true;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async => _trusted[address];

  // --- Сохранение ---

  static String _addr(SignalProtocolAddress a) => '${a.getName()}:${a.getDeviceId()}';
  static SignalProtocolAddress _parseAddr(String s) {
    final i = s.lastIndexOf(':');
    return SignalProtocolAddress(s.substring(0, i), int.parse(s.substring(i + 1)));
  }

  String toJson() => jsonEncode({
    'identity': _b64(_identity.serialize()),
    'registrationId': _registrationId,
    'nextPreKeyId': nextPreKeyId,
    'preKeys': {for (final e in preKeyStore.store.entries) '${e.key}': _b64(e.value)},
    'signedPreKeys': {for (final e in signedPreKeyStore.store.entries) '${e.key}': _b64(e.value)},
    'sessions': {for (final e in sessionStore.sessions.entries) _addr(e.key): _b64(e.value)},
    'trusted': {for (final e in _trusted.entries) _addr(e.key): _b64(e.value.serialize())},
  });

  factory SignalKeys.fromJson(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final keys = SignalKeys._(
      IdentityKeyPair.fromSerialized(_bytes(j['identity'])),
      j['registrationId'],
      j['nextPreKeyId'],
    );
    for (final MapEntry(:key, :value) in (j['preKeys'] as Map<String, dynamic>).entries) {
      keys.preKeyStore.store[int.parse(key)] = _bytes(value);
    }
    for (final MapEntry(:key, :value) in (j['signedPreKeys'] as Map<String, dynamic>).entries) {
      keys.signedPreKeyStore.store[int.parse(key)] = _bytes(value);
    }
    for (final MapEntry(:key, :value) in (j['sessions'] as Map<String, dynamic>).entries) {
      keys.sessionStore.sessions[_parseAddr(key)] = _bytes(value);
    }
    for (final MapEntry(:key, :value) in (j['trusted'] as Map<String, dynamic>).entries) {
      keys._trusted[_parseAddr(key)] = IdentityKey.fromBytes(_bytes(value), 0);
    }
    return keys;
  }
}

String _b64(List<int> b) => base64.encode(b);
Uint8List _bytes(Object? s) => base64.decode(s as String);
