import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:v_video_compressor/v_video_compressor.dart';
import 'package:video_player/video_player.dart';

/// Уменьшает фото до [max] пикселей по большей стороне и пережимает в JPEG.
Future<Uint8List?> shrinkImage(Uint8List bytes, {int max = 2048, int quality = 85}) =>
    compute((b) {
      final decoded = img.decodeImage(b);
      if (decoded == null) return null;
      var image = img.bakeOrientation(decoded);
      if (image.width > max || image.height > max) {
        image = image.width >= image.height ? img.copyResize(image, width: max) : img.copyResize(image, height: max);
      }
      return img.encodeJpg(image, quality: quality);
    }, bytes);

/// Кадр из начала видео в JPEG не больше [size] пикселей.
Future<Uint8List?> videoThumbnail(Uint8List bytes, String name, {int size = 320}) async {
  final src = File('${(await getTemporaryDirectory()).path}/thumb-${DateTime.now().microsecondsSinceEpoch}-$name');
  try {
    await src.writeAsBytes(bytes);
    return await FcNativeVideoThumbnail().saveThumbnailToBytes(
      srcFile: src.path,
      width: size,
      height: size,
      format: 'jpeg',
      quality: 70,
    );
  } finally {
    src.delete().ignore();
  }
}

/// Плеер для расшифрованного видео: на телефоне оно играется из временного файла.
Future<VideoPlayerController> videoController(Uint8List bytes, String id, String name) async {
  final file = File('${(await getTemporaryDirectory()).path}/video-$id-$name');
  if (!await file.exists()) await file.writeAsBytes(bytes);
  return VideoPlayerController.file(file);
}

/// Пережимает видео как Signal в стандартном качестве: H.264 720p, 2 Мбит/с
/// (1,5 Мбит/с для роликов длиннее 10 минут), звук AAC 128 кбит/с, без метаданных вроде геолокации.
/// Возвращает путь к сжатому файлу или null, если сжать не вышло.
Future<String?> compressVideo(String path, {void Function(double progress)? onProgress}) async {
  final compressor = VVideoCompressor();
  final info = await compressor.getVideoInfo(path);
  final long = (info?.durationMillis ?? 0) > 10 * 60 * 1000;
  final result = await compressor.compressVideo(
    path,
    VVideoCompressionConfig(
      quality: VVideoCompressQuality.medium,
      includeMetadata: false,
      copyMetadata: false,
      advanced: VVideoAdvancedConfig(
        videoBitrate: long ? 1500000 : 2000000,
        audioBitrate: 128000,
        videoCodec: VVideoCodec.h264,
        audioCodec: VAudioCodec.aac,
      ),
    ),
    onProgress: onProgress,
  );
  return result?.compressedFilePath;
}
