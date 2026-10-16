import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:v_video_compressor/v_video_compressor.dart';
import 'package:video_player/video_player.dart';

import 'client.dart';
import 'media.dart';

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
Future<Uint8List?> videoThumbnail(XFile video, {int size = 320}) => FcNativeVideoThumbnail().saveThumbnailToBytes(
  srcFile: video.path,
  width: size,
  height: size,
  format: 'jpeg',
  quality: 70,
);

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

/// Расшифрованное вложение во временном файле: большие видео и файлы не помещаются в память.
Future<File> _download(Map<String, dynamic> file, void Function(double)? onProgress) async {
  final dir = await getTemporaryDirectory();
  final out = File('${dir.path}/aura-${file['id']}-${file['name']}');
  if (await out.exists()) return out;
  final tmp = File('${out.path}.part');
  final sink = tmp.openWrite();
  var done = 0;
  try {
    await for (final p in client.fileParts(file)) {
      sink.add(p);
      done += p.length;
      onProgress?.call(file['size'] == 0 ? 1 : done / file['size']);
    }
    await sink.close();
    return await tmp.rename(out.path);
  } catch (_) {
    await sink.close();
    tmp.delete().ignore();
    rethrow;
  }
}

/// Плеер для вложения-видео: на телефоне оно играется из временного файла.
Future<VideoPlayerController> videoController(Map<String, dynamic> file, {void Function(double)? onProgress}) async =>
    VideoPlayerController.file(await _download(file, onProgress));

/// Сохраняет вложение на устройство. Большие файлы отдаются через «Поделиться»,
/// где можно выбрать «Сохранить в Файлы»: системный диалог сохранения требует держать файл в памяти.
Future<void> saveAttachment(Map<String, dynamic> file, {void Function(double)? onProgress}) async {
  final local = await _download(file, onProgress);
  if (await local.length() <= 256 << 20) {
    await FilePicker.saveFile(fileName: file['name'], bytes: await local.readAsBytes());
  } else {
    await SharePlus.instance.share(ShareParams(files: [XFile(local.path, name: file['name'])]));
  }
}

/// Шифрование частей в отдельном изоляте, чтобы интерфейс не замирал на больших файлах.
Future<Uint8List> encryptPart(Uint8List key, int index, bool last, Uint8List plain) =>
    compute((_) => FileCrypto.encryptPart(key, index, last, plain), null);

Future<Uint8List> decryptPart(Uint8List key, int index, bool last, Uint8List data) async {
  try {
    return await compute((_) => FileCrypto.decryptPart(key, index, last, data), null);
  } catch (_) {
    throw ApiException('Файл повреждён или подменён');
  }
}
