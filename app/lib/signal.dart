import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Ключи Signal Protocol этого устройства и сессии с собеседниками.
/// Приватные ключи не покидают устройство: на сервер уходят только публичные части.
// Хранится в Keychain/Keystore (AuraClient._saveKeys); в Web — в localStorage, защищённого хранилища там нет.
// ponytail: signed prekey не ротируется, добавить ротацию раз в месяц.
class SignalKeys extends InMemorySignalProtocolStore {
  SignalKeys._(this._identity, this._registrationId, this.nextPreKeyId) : super(_identity, _registrationId);

  final IdentityKeyPair _identity;
  final int _registrationId;
  int nextPreKeyId;

  /// Ключ аккаунта собеседника по нику: у всех его устройств один ключ. Устройство с другим ключом
  /// сервер добавить не может (у него нет приватного ключа аккаунта), а клиент его не принимает.
  final _trusted = <String, IdentityKey>{};

  /// Ключи других устройств собеседника, которым доверяли до одного ключа на аккаунт. Сервер выбрал
  /// ключом аккаунта ключ самого старого из живых устройств, и он может оказаться здесь, а не в [_trusted]:
  /// такой ключ принимается без предупреждения, пользователь ему уже доверял.
  final _formerly = <String, Set<String>>{}; // base64: у IdentityKey hashCode не по содержимому

  static const preKeyBatch = 50;

  /// [identity] — ключ аккаунта, полученный при привязке (см. LinkEnvelope); без него создаётся новый.
  factory SignalKeys.generate([IdentityKeyPair? identity]) {
    final keys = SignalKeys._(identity ?? generateIdentityKeyPair(), generateRegistrationId(false), 1);
    final spk = generateSignedPreKey(keys._identity, 1);
    keys.signedPreKeyStore.store[spk.id] = spk.serialize();
    return keys;
  }

  /// Все публичные ключи для первой публикации на сервере.
  Map<String, dynamic> publicBundle() {
    final spk = SignedPreKeyRecord.fromSerialized(signedPreKeyStore.store.values.single);
    return {
      'registrationId': _registrationId,
      'identityKey': identityKey,
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
  /// Ключи — ключи аккаунтов (base64, как их отдаёт сервер).
  static String safetyNumber(String me, List<String> myKeys, String peer, List<String> peerKeys) {
    List<IdentityKey> ids(List<String> keys) => [for (final k in keys) IdentityKey.fromBytes(_bytes(k), 0)];
    return NumericFingerprintGenerator(5200)
        .createListFor(2, utf8.encode(me), ids(myKeys), utf8.encode(peer), ids(peerKeys))
        .displayableFingerprint
        .getDisplayText();
  }

  // --- Группы: ключи отправителя (sender keys) ---
  // У каждого устройства в каждой группе свой ключ отправителя. Он раздаётся участникам попарными
  // сессиями, а сообщение в группу шифруется им один раз для всех.

  /// Тип зашифрованного ключом отправителя сообщения в группу (у попарных — 2 и 3).
  static const groupType = CiphertextMessage.senderKeyType;

  /// Записи ключей отправителей по SenderKeyName.serialize().
  final senderKeys = <String, Uint8List>{};
  late final _senderKeyStore = _SenderKeyStore(senderKeys);

  static SenderKeyName _senderKeyName(String group, String nick, int device) =>
      SenderKeyName(group, SignalProtocolAddress(nick, device));

  /// Свой ключ отправителя в группе для раздачи участникам; создаётся при первом вызове.
  Future<String> senderKey(String group, String me, int device) async =>
      _b64((await GroupSessionBuilder(_senderKeyStore).create(_senderKeyName(group, me, device))).serialize());

  /// Ключ, который уже есть, не принимаем повторно: иначе он перекроет текущую цепочку,
  /// и сообщения, отправленные до повтора, не расшифруются.
  Future<void> processSenderKey(String group, String nick, int device, String key) async {
    final name = _senderKeyName(group, nick, device);
    final skdm = SenderKeyDistributionMessageWrapper.fromSerialized(_bytes(key));
    try {
      (await _senderKeyStore.loadSenderKey(name)).getSenderKeyStateById(skdm.id);
      return;
    } on InvalidKeyIdException catch (_) {}
    await GroupSessionBuilder(_senderKeyStore).process(name, skdm);
  }

  /// Новый ключ отправителя при следующей отправке: исключённый участник не прочтёт новые сообщения.
  void dropSenderKey(String group, String me, int device) =>
      senderKeys.remove(_senderKeyName(group, me, device).serialize());

  Future<String> groupEncrypt(String group, String me, int device, String plaintext) async =>
      _b64(await GroupCipher(_senderKeyStore, _senderKeyName(group, me, device)).encrypt(utf8.encode(plaintext)));

  Future<String> groupDecrypt(String group, String nick, int device, String body) async =>
      utf8.decode(await GroupCipher(_senderKeyStore, _senderKeyName(group, nick, device)).decrypt(_bytes(body)));

  // --- Доверие к ключам собеседников ---

  /// Устройство с ключом не аккаунта не принимается, пока пользователь не подтвердит смену ключа
  /// ([untrust]): иначе сервер может молча добавить собеседнику своё устройство и читать переписку (A19).
  /// Ключ нового собеседника принимается на доверии, его проверяет сверка кода безопасности.
  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address, IdentityKey? identityKey, Direction direction) async {
    if (identityKey == null) return false;
    final known = _trusted[address.getName()];
    return known == null || known == identityKey || (_formerly[address.getName()]?.contains(_b64(identityKey.serialize())) ?? false);
  }

  /// Ключ аккаунта, которому доверяем, или null, если сессий с ним ещё не было.
  String? identityOf(String nick) {
    final key = _trusted[nick];
    return key == null ? null : _b64(key.serialize());
  }

  String get identityKey => _b64(_identity.getPublicKey().serialize());

  /// Свои устройства принимаются только с ключом аккаунта.
  void trustOwn(String nick) {
    if (_trusted[nick] == _identity.getPublicKey()) return;
    untrust(nick);
    _trusted[nick] = _identity.getPublicKey();
  }

  /// Пользователь подтвердил смену ключа собеседника: забываем старый ключ и сессии с ним.
  void untrust(String nick) {
    _trusted.remove(nick);
    _formerly.remove(nick);
    sessionStore.sessions.removeWhere((a, _) => a.getName() == nick);
  }

  /// Забыть сессию: расшифрованное оказалось чужим (A21). Ключ — если он пришёл с этой сессией.
  void forget(String nick, int device) {
    sessionStore.sessions.remove(SignalProtocolAddress(nick, device));
    if (!sessionStore.sessions.keys.any((a) => a.getName() == nick)) _trusted.remove(nick);
  }

  @override
  Future<bool> saveIdentity(SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null || _trusted[address.getName()] == identityKey) return false;
    _trusted[address.getName()] = identityKey;
    _formerly.remove(address.getName());
    return true;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async => _trusted[address.getName()];

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
    'trusted': {for (final e in _trusted.entries) e.key: _b64(e.value.serialize())},
    'formerly': {for (final e in _formerly.entries) e.key: [...e.value]},
    'senderKeys': {for (final e in senderKeys.entries) e.key: _b64(e.value)},
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
    // До одного ключа на аккаунт ключи хранились по адресу «ник:устройство». Ключом аккаунта
    // остаётся ключ самого старого устройства (как на сервере), сессии с другими ключами забываются.
    final old = <SignalProtocolAddress, IdentityKey>{};
    for (final MapEntry(:key, :value) in (j['trusted'] as Map<String, dynamic>).entries) {
      final k = IdentityKey.fromBytes(_bytes(value), 0);
      key.contains(':') ? old[_parseAddr(key)] = k : keys._trusted[key] = k;
    }
    for (final a in old.keys.toList()..sort((a, b) => a.getDeviceId() - b.getDeviceId())) {
      keys._trusted.putIfAbsent(a.getName(), () => old[a]!);
    }
    old.forEach((a, k) {
      if (keys._trusted[a.getName()] == k) return;
      keys.sessionStore.sessions.remove(a);
      keys._formerly.putIfAbsent(a.getName(), () => {}).add(_b64(k.serialize()));
    });
    for (final MapEntry(:key, :value) in (j['formerly'] as Map<String, dynamic>? ?? {}).entries) {
      keys._formerly[key] = {...(value as List).cast<String>()};
    }
    for (final MapEntry(:key, :value) in (j['senderKeys'] as Map<String, dynamic>? ?? {}).entries) {
      keys.senderKeys[key] = _bytes(value);
    }
    return keys;
  }
}

String _b64(List<int> b) => base64.encode(b);
Uint8List _bytes(Object? s) => base64.decode(s as String);

class _SenderKeyStore extends SenderKeyStore {
  _SenderKeyStore(this._records);
  final Map<String, Uint8List> _records;

  @override
  Future<SenderKeyRecord> loadSenderKey(SenderKeyName name) async {
    final r = _records[name.serialize()];
    return r == null ? SenderKeyRecord() : SenderKeyRecord.fromSerialized(r);
  }

  @override
  Future<void> storeSenderKey(SenderKeyName name, SenderKeyRecord record) async =>
      _records[name.serialize()] = record.serialize();
}
