import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'client.dart';
import 'media.dart';

/// Браузер сам декодирует картинку и сжимает её через canvas, это быстрее, чем на Dart.
Future<Uint8List?> shrinkImage(Uint8List bytes, {int max = 2048, int quality = 85}) async {
  final bitmap = await web.window.createImageBitmap(web.Blob([bytes.toJS].toJS)).toDart;
  return _jpeg(bitmap, bitmap.width, bitmap.height, max, quality);
}

/// Кадр из начала видео: браузер проигрывает его в невидимом элементе и рисует кадр на canvas.
Future<Uint8List?> videoThumbnail(XFile file, {int size = 320}) async {
  final own = !file.path.startsWith('blob:');
  final url = own
      ? web.URL.createObjectURL(web.Blob([(await file.readAsBytes()).toJS].toJS, web.BlobPropertyBag(type: videoMime(file.name))))
      : file.path;
  final video = web.HTMLVideoElement()
    ..muted = true
    ..preload = 'auto'
    ..src = url;
  try {
    await video.onLoadedData.first.timeout(const Duration(seconds: 10));
    video.currentTime = min(0.5, video.duration / 2);
    await video.onSeeked.first.timeout(const Duration(seconds: 10));
    return await _jpeg(video, video.videoWidth, video.videoHeight, size, 70);
  } catch (e) {
    debugPrint('AURA: превью видео: $e');
    return null;
  } finally {
    video.src = '';
    if (own) web.URL.revokeObjectURL(url);
  }
}

Future<Uint8List?> _jpeg(web.CanvasImageSource source, int width, int height, int max, int quality) async {
  if (width == 0 || height == 0) return null;
  final scale = min(1.0, max / (width > height ? width : height));
  final canvas = web.HTMLCanvasElement()
    ..width = (width * scale).round()
    ..height = (height * scale).round();
  canvas.context2D
    ..fillStyle = 'white'.toJS // прозрачный PNG в JPEG иначе станет чёрным
    ..fillRect(0, 0, canvas.width, canvas.height)
    ..drawImage(source, 0, 0, canvas.width, canvas.height);
  final done = Completer<web.Blob?>();
  canvas.toBlob(((web.Blob? b) => done.complete(b)).toJS, 'image/jpeg', (quality / 100).toJS);
  final blob = await done.future;
  if (blob == null) return null;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}

/// В браузере перекодировать видео нечем, оно уходит как есть.
// ponytail: сжатие в браузере через WebCodecs, если будут слать много видео с компьютера.
Future<String?> compressVideo(String path, {void Function(double progress)? onProgress}) async => null;

/// Вложение как blob: браузер сам держит большие blob-ы на диске, а не в памяти вкладки.
final _blobs = <String, Future<String>>{};

Future<String> _blobUrl(Map<String, dynamic> file, String type, void Function(double)? onProgress) {
  final String id = file['id'];
  if (_blobs[id] case final cached?) return cached;
  final url = () async {
    final parts = <JSUint8Array>[];
    var done = 0;
    await for (final p in client.fileParts(file)) {
      parts.add(p.toJS);
      done += p.length;
      onProgress?.call(file['size'] == 0 ? 1 : done / file['size']);
    }
    return web.URL.createObjectURL(web.Blob(parts.toJS, web.BlobPropertyBag(type: type)));
  }();
  _blobs[id] = url;
  url.then((_) {}, onError: (_) {
    _blobs.remove(id); // после ошибки попробуем скачать заново
  });
  return url;
}

/// Плеер для вложения-видео: в браузере оно играется по blob-адресу.
Future<VideoPlayerController> videoController(Map<String, dynamic> file, {void Function(double)? onProgress}) async =>
    VideoPlayerController.networkUrl(Uri.parse(await _blobUrl(file, videoMime(file['name']), onProgress)));

/// Сохраняет вложение через обычную загрузку браузера.
Future<void> saveAttachment(Map<String, dynamic> file, {void Function(double)? onProgress}) async {
  final url = await _blobUrl(file, 'application/octet-stream', onProgress);
  (web.HTMLAnchorElement()
        ..href = url
        ..download = file['name'])
      .click();
}

/// Части файла шифрует сам браузер через WebCrypto: на Dart в браузере AES в десятки раз медленнее.
Future<Uint8List> encryptPart(Uint8List key, int index, bool last, Uint8List plain) async {
  final nonce = FileCrypto.nonce();
  final out = await _gcm(true, key, nonce, FileCrypto.partTag(index, last), plain);
  return Uint8List(12 + out.length)
    ..setAll(0, nonce)
    ..setAll(12, out);
}

Future<Uint8List> decryptPart(Uint8List key, int index, bool last, Uint8List data) async {
  try {
    return await _gcm(false, key, Uint8List.sublistView(data, 0, 12), FileCrypto.partTag(index, last),
        Uint8List.sublistView(data, 12));
  } catch (_) {
    throw ApiException('Файл повреждён или подменён');
  }
}

Future<Uint8List> _gcm(bool encrypt, Uint8List key, Uint8List nonce, Uint8List aad, Uint8List data) async {
  final subtle = web.window.crypto.subtle;
  final k = await subtle
      .importKey('raw', key.toJS, 'AES-GCM'.toJS, false, [(encrypt ? 'encrypt' : 'decrypt').toJS].toJS)
      .toDart;
  final params = JSObject()
    ..setProperty('name'.toJS, 'AES-GCM'.toJS)
    ..setProperty('iv'.toJS, nonce.toJS)
    ..setProperty('additionalData'.toJS, aad.toJS)
    ..setProperty('tagLength'.toJS, 128.toJS);
  final out = await (encrypt ? subtle.encrypt(params, k, data.toJS) : subtle.decrypt(params, k, data.toJS)).toDart;
  return (out as JSArrayBuffer).toDart.asUint8List();
}

/// Освобождает blob вложения: браузер стирает его из памяти и с диска.
Future<void> forgetFile(Map<String, dynamic> file) async {
  if (_blobs.remove(file['id']) case final url?) {
    try {
      web.URL.revokeObjectURL(await url);
    } catch (_) {} // не скачалось — освобождать нечего
  }
}

/// В браузере вложения живут в blob-ах до закрытия вкладки, на диск их не сохраняем.
Future<void> keepSent(Map<String, dynamic> file, {String? path, Uint8List? bytes, bool temporary = false}) async {}

Future<void> clearLocalFiles() async {}

/// Вкладка браузера грузит и в фоне, пока открыта.
Future<T> inBackground<T>(Future<T> Function() job) => job();

void backgroundStatus(String text) {}
