import 'dart:async';
import 'dart:js_interop';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

import 'media.dart';

/// Браузер сам декодирует картинку и сжимает её через canvas, это быстрее, чем на Dart.
Future<Uint8List?> shrinkImage(Uint8List bytes, {int max = 2048, int quality = 85}) async {
  final bitmap = await web.window.createImageBitmap(web.Blob([bytes.toJS].toJS)).toDart;
  return _jpeg(bitmap, bitmap.width, bitmap.height, max, quality);
}

/// Кадр из начала видео: браузер проигрывает его в невидимом элементе и рисует кадр на canvas.
Future<Uint8List?> videoThumbnail(Uint8List bytes, String name, {int size = 320}) async {
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: videoMime(name))));
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
    web.URL.revokeObjectURL(url);
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

/// Плеер для расшифрованного видео: в браузере оно играется по blob-адресу.
Future<VideoPlayerController> videoController(Uint8List bytes, String id, String name) async {
  final url = web.URL.createObjectURL(web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: videoMime(name))));
  return VideoPlayerController.networkUrl(Uri.parse(url));
}
