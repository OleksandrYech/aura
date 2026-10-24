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

  /// Часть большого файла. Номер части и признак последней входят в проверяемые данные GCM,
  /// поэтому сервер не может переставить части местами или незаметно обрезать файл.
  static Uint8List encryptPart(Uint8List key, int index, bool last, Uint8List plain) {
    final nonce = _random(12);
    final out = _cipher(true, key, nonce, partTag(index, last)).process(plain);
    return Uint8List(12 + out.length)
      ..setAll(0, nonce)
      ..setAll(12, out);
  }

  static Uint8List decryptPart(Uint8List key, int index, bool last, Uint8List data) =>
      _cipher(false, key, Uint8List.sublistView(data, 0, 12), partTag(index, last))
          .process(Uint8List.sublistView(data, 12));

  /// Те же части умеет шифровать WebCrypto в браузере (см. platform_media_web.dart), формат совпадает.
  static Uint8List nonce() => _random(12);

  static Uint8List partTag(int index, bool last) => (ByteData(5)
        ..setUint32(0, index)
        ..setUint8(4, last ? 1 : 0))
      .buffer
      .asUint8List();

  static GCMBlockCipher _cipher(bool encrypt, Uint8List key, Uint8List nonce, [Uint8List? aad]) =>
      GCMBlockCipher(AESEngine())..init(encrypt, AEADParameters(KeyParameter(key), 128, nonce, aad ?? Uint8List(0)));

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

const imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

/// Режет поток байт на куски ровно по [size] (последний короче). Пустой поток даёт один пустой кусок.
Stream<Uint8List> rechunk(Stream<List<int>> source, int size) async* {
  final buf = BytesBuilder(copy: false);
  var any = false;
  await for (final chunk in source) {
    buf.add(chunk);
    while (buf.length >= size) {
      final all = buf.takeBytes();
      any = true;
      yield Uint8List.sublistView(all, 0, size);
      if (all.length > size) buf.add(Uint8List.sublistView(all, size));
    }
  }
  if (buf.isNotEmpty || !any) yield buf.takeBytes();
}

String _ext(String name) => name.split('.').last.toLowerCase();

bool isImage(String name) => imageExtensions.contains(_ext(name));

/// Фото или видео: в пузыре показывается превью, а не строка файла.
bool isMedia(Map<String, dynamic> file) => file['voice'] != true && (file['video'] == true || isImage(file['name']));

const _videoMimes = {'mp4': 'video/mp4', 'm4v': 'video/mp4', 'mov': 'video/quicktime', 'webm': 'video/webm'};

/// Видео, которые умеют играть браузер, Android и iOS.
bool isVideo(String name) => _videoMimes.containsKey(_ext(name));

String videoMime(String name) => _videoMimes[_ext(name)] ?? 'video/mp4';

String formatSize(int bytes) => bytes < 1024
    ? '$bytes Б'
    : bytes < 1 << 20
    ? '${(bytes / 1024).toStringAsFixed(0)} КБ'
    : bytes < 1 << 30
    ? '${(bytes / (1 << 20)).toStringAsFixed(1)} МБ'
    : '${(bytes / (1 << 30)).toStringAsFixed(2)} ГБ';
