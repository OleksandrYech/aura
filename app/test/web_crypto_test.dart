import 'dart:typed_data';

import 'package:aura/client.dart';
import 'package:aura/media.dart';
import 'package:aura/platform_media.dart';
import 'package:flutter_test/flutter_test.dart';

// На телефоне части шифрует BoringSSL (webcrypto), в браузере WebCrypto, у старых клиентов pointycastle.
// В браузере: flutter test --platform chrome test/web_crypto_test.dart.
void main() {
  test('системный AES-GCM и pointycastle понимают части друг друга', () async {
    final key = FileCrypto.newKey(), plain = Uint8List.fromList(List.generate(100000, (i) => i % 251));
    final fresh = await encryptPart(key, 2, true, plain);
    expect(fresh.length, plain.length + 28);
    expect(FileCrypto.decryptPart(key, 2, true, fresh), plain);
    expect(await decryptPart(key, 0, false, FileCrypto.encryptPart(key, 0, false, plain)), plain);
    expect(FileCrypto.decryptPart(key, 0, true, await encryptPart(key, 0, true, Uint8List(0))), isEmpty);
    expect(await decryptPart(key, 0, true, FileCrypto.encryptPart(key, 0, true, Uint8List(0))), isEmpty);
  });

  test('подменённая часть не расшифровывается', () async {
    final key = FileCrypto.newKey(), plain = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final enc = FileCrypto.encryptPart(key, 3, false, plain);
    final broken = throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Файл повреждён или подменён'));
    await expectLater(decryptPart(key, 4, false, enc), broken, reason: 'переставленная часть');
    await expectLater(decryptPart(key, 3, true, enc), broken, reason: 'обрезанный файл');
    await expectLater(decryptPart(FileCrypto.newKey(), 3, false, enc), broken, reason: 'чужой ключ');
    await expectLater(decryptPart(key, 3, false, Uint8List.fromList(enc)..[500] ^= 1), broken);
    await expectLater(decryptPart(key, 3, false, Uint8List.fromList(enc)..[enc.length - 1] ^= 1), broken, reason: 'тег');
    await expectLater(decryptPart(key, 3, false, Uint8List.sublistView(enc, 0, 20)), broken, reason: 'короче тега');
  });
}
