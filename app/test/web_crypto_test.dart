@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:aura/media.dart';
import 'package:aura/platform_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WebCrypto и pointycastle понимают части друг друга', () async {
    final key = FileCrypto.newKey(), plain = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final web = await encryptPart(key, 2, true, plain);
    expect(FileCrypto.decryptPart(key, 2, true, web), plain);
    final dart = FileCrypto.encryptPart(key, 0, false, plain);
    expect(await decryptPart(key, 0, false, dart), plain);
  });
}
