import 'dart:typed_data';

import 'package:aura/media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('файл расшифровывается своим ключом и не расшифровывается чужим или повреждённый', () {
    final plain = Uint8List.fromList(List.generate(100000, (i) => i % 251));
    final key = FileCrypto.newKey();
    final enc = FileCrypto.encrypt(key, plain);
    expect(enc.length, plain.length + 12 + 16);
    expect(FileCrypto.decrypt(key, enc), plain);
    expect(FileCrypto.encrypt(key, plain), isNot(enc), reason: 'каждый раз новый nonce');
    expect(() => FileCrypto.decrypt(FileCrypto.newKey(), enc), throwsA(anything));
    enc[500] ^= 1;
    expect(() => FileCrypto.decrypt(key, enc), throwsA(anything));
  });
}
