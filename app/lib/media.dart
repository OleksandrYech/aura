import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Шифрование вложений: у каждого файла свой случайный ключ AES-256-GCM. Сервер получает только
/// зашифрованные байты, а ключ уходит собеседнику внутри сообщения Signal.
/// Формат: 12 байт nonce, затем шифротекст с тегом GCM (16 байт).
class FileCrypto {
  static Uint8List newKey() => _random(32);

  static Uint8List encrypt(Uint8List key, Uint8List plain) {
    final nonce = _random(12);
    final out = _cipher(true, key, nonce).process(plain);
    return Uint8List(12 + out.length)
      ..setAll(0, nonce)
      ..setAll(12, out);
  }

  /// Бросает исключение, если байты повреждены или ключ не тот.
  static Uint8List decrypt(Uint8List key, Uint8List data) =>
      _cipher(false, key, Uint8List.sublistView(data, 0, 12)).process(Uint8List.sublistView(data, 12));

  static GCMBlockCipher _cipher(bool encrypt, Uint8List key, Uint8List nonce) =>
      GCMBlockCipher(AESEngine())..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

const imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

bool isImage(String name) => imageExtensions.contains(name.split('.').last.toLowerCase());

String formatSize(int bytes) => bytes < 1024
    ? '$bytes Б'
    : bytes < 1 << 20
    ? '${(bytes / 1024).toStringAsFixed(0)} КБ'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ';
