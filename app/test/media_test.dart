import 'dart:typed_data';

import 'package:aura/media.dart';
import 'package:aura/platform_media.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

  test('большое фото уменьшается до 2048 по большей стороне и становится JPEG', () async {
    final png = img.encodePng(img.Image(width: 4000, height: 3000)..clear(img.ColorRgb8(200, 120, 40)));
    final small = (await shrinkImage(png))!;
    final out = img.decodeJpg(small)!;
    expect((out.width, out.height), (2048, 1536));
    expect(isVideo('clip.MP4'), isTrue);
    expect(isVideo('photo.jpg'), isFalse);
  });

  test('части файла: номер и признак последней проверяются', () {
    final key = FileCrypto.newKey();
    final plain = Uint8List.fromList(List.generate(1000, (i) => i % 251));
    final enc = FileCrypto.encryptPart(key, 3, false, plain);
    expect(FileCrypto.decryptPart(key, 3, false, enc), plain);
    expect(() => FileCrypto.decryptPart(key, 4, false, enc), throwsA(anything), reason: 'переставленная часть');
    expect(() => FileCrypto.decryptPart(key, 3, true, enc), throwsA(anything), reason: 'обрезанный файл');
  });

  test('поток режется на части нужного размера', () async {
    Future<List<int>> sizes(List<List<int>> input, int size) async =>
        [await for (final c in rechunk(Stream.fromIterable(input), size)) c.length];
    expect(await sizes([List.filled(25, 1)], 10), [10, 10, 5]);
    expect(await sizes([List.filled(3, 1), List.filled(9, 1), List.filled(8, 1)], 10), [10, 10]);
    expect(await sizes([], 10), [0]);
    final joined = [await for (final c in rechunk(Stream.fromIterable([List.generate(7, (i) => i), List.generate(7, (i) => 7 + i)]), 5)) ...c];
    expect(joined, List.generate(14, (i) => i));
  });
}
