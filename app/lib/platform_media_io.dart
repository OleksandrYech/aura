import 'dart:convert';
import 'dart:io';

import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:v_video_compressor/v_video_compressor.dart';
import 'package:video_player/video_player.dart';
import 'package:webcrypto/webcrypto.dart';

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
Future<Uint8List?> videoThumbnail(XFile video, {int size = 240}) => FcNativeVideoThumbnail().saveThumbnailToBytes(
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

/// Папка расшифрованных вложений: свои отправленные и уже скачанные. Удаляется при выходе.
Future<Directory> _localDir() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/files').create(recursive: true);

/// Имя локальной копии: id и расширение (по нему iOS узнаёт видео), без лишних символов из сообщения.
String _localName(Map<String, dynamic> file) {
  final ext = RegExp(r'\.[A-Za-z0-9]{1,8}$').firstMatch(file['name'] as String)?[0] ?? '';
  return '${(file['id'] as String).replaceAll(RegExp(r'[^0-9a-f]'), '')}$ext';
}

Future<bool> _complete(File f, Map<String, dynamic> file) async => await f.exists() && await f.length() == file['size'];

/// Пути к отправленным оригиналам по id вложения: их не копируем, а читаем на месте.
/// Собеседнику путь не уходит, он только в настройках этого устройства.
// ponytail: записи не чистятся до выхода из аккаунта, удалять по сроку файлов на сервере, если их станет много.
Future<Map<String, dynamic>> _originals(SharedPreferences prefs) async =>
    jsonDecode(prefs.getString('localFiles') ?? '{}') as Map<String, dynamic>;

/// Отправленный файл остаётся на устройстве, чтобы своё видео не качать заново.
/// [bytes] — фото, сжатое в памяти; [path] и [temporary] — временный файл сжатия, его переносим;
/// просто [path] — оригинал, запоминаем путь к нему. Файл во временной папке приложения тоже копия
/// (её сделали выбор файла, галерея iOS или сжатие): переносим к себе, чтобы при удалении сообщения
/// не осталось лишней копии.
Future<void> keepSent(Map<String, dynamic> file, {String? path, Uint8List? bytes, bool temporary = false}) async {
  try {
    final out = File('${(await _localDir()).path}/${_localName(file)}');
    if (path != null && !temporary) {
      final real = File(path).resolveSymbolicLinksSync(); // на iOS /var — ссылка на /private/var
      temporary = [await getTemporaryDirectory(), Directory.systemTemp]
          .any((d) => d.existsSync() && real.startsWith('${d.resolveSymbolicLinksSync()}/'));
    }
    if (bytes != null) {
      await out.writeAsBytes(bytes, flush: true);
    } else if (path != null && temporary) {
      try {
        await File(path).rename(out.path);
      } on FileSystemException {
        await File(path).copy(out.path); // другой раздел диска
        await File(path).delete();
      }
    } else if (path != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('localFiles', jsonEncode({...await _originals(prefs), file['id']: path}));
    }
  } catch (e) {
    debugPrint('AURA: копия отправленного файла: $e'); // не страшно, файл скачается с сервера
  }
}

/// Стирает с устройства расшифрованную копию вложения и забывает путь к отправленному оригиналу.
/// Сам оригинал в галерее не трогаем: это файл пользователя, а не мессенджера.
Future<void> forgetFile(Map<String, dynamic> file) async {
  try {
    final out = File('${(await _localDir()).path}/${_localName(file)}');
    for (final f in [out, File('${out.path}.part')]) {
      if (await f.exists()) await f.delete();
    }
    final prefs = await SharedPreferences.getInstance();
    final originals = await _originals(prefs);
    if (originals.remove(file['id']) != null) await prefs.setString('localFiles', jsonEncode(originals));
  } catch (e) {
    debugPrint('AURA: удаление вложения: $e');
  }
}

/// Удаляет локальные копии вложений при выходе из аккаунта. Оригиналы в галерее не трогаем.
Future<void> clearLocalFiles() async {
  try {
    await (await _localDir()).delete(recursive: true);
  } catch (e) {
    debugPrint('AURA: удаление вложений: $e');
  }
}

/// Расшифрованное вложение в файле: большие видео и файлы не помещаются в память.
/// Сначала ищем свою копию или отправленный оригинал, иначе скачиваем в ту же папку.
Future<File> _download(Map<String, dynamic> file, void Function(double)? onProgress) async {
  final out = File('${(await _localDir()).path}/${_localName(file)}');
  if (await _complete(out, file)) return out;
  if ((await _originals(await SharedPreferences.getInstance()))[file['id']] case final String path
      when await _complete(File(path), file)) {
    return File(path);
  }
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

/// Части файла шифрует BoringSSL через FFI (пакет webcrypto) с аппаратным AES процессора:
/// AES на чистом Dart на телефоне выдаёт меньше 1 МБ/с и был главным тормозом отправки и скачивания.
/// Формат тот же, что у [FileCrypto.encryptPart] и WebCrypto в браузере.
/// Часть в 2 МБ шифруется за миллисекунды, поэтому прямо в главном изоляте, без копирования в compute.
Future<Uint8List> encryptPart(Uint8List key, int index, bool last, Uint8List plain) async {
  final nonce = FileCrypto.nonce();
  final out = await (await AesGcmSecretKey.importRawKey(key))
      .encryptBytes(plain, nonce, additionalData: FileCrypto.partTag(index, last));
  return Uint8List(12 + out.length)
    ..setAll(0, nonce)
    ..setAll(12, out);
}

Future<Uint8List> decryptPart(Uint8List key, int index, bool last, Uint8List data) async {
  try {
    return await (await AesGcmSecretKey.importRawKey(key)).decryptBytes(
      Uint8List.sublistView(data, 12),
      Uint8List.sublistView(data, 0, 12),
      additionalData: FileCrypto.partTag(index, last),
    );
  } catch (_) {
    throw ApiException('Файл повреждён или подменён');
  }
}

var _jobs = 0;
var _shown = DateTime(0);

/// На Android отправка идёт под службой переднего плана с уведомлением: система не останавливает
/// приложение, пока файл грузится, даже если свернуть его или выключить экран.
// ponytail: на iOS фоновой загрузки нет, нужна фоновая URLSession; добавить, если понадобится.
Future<T> inBackground<T>(Future<T> Function() job) async {
  if (Platform.isAndroid && _jobs++ == 0) {
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission(); // без разрешения служба работает, но без уведомления
      }
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(channelId: 'upload', channelName: 'Отправка файлов'),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
        foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), allowWifiLock: true),
      );
      await FlutterForegroundTask.startService(notificationTitle: 'AURA', notificationText: 'Отправка файла');
    } catch (e) {
      debugPrint('AURA: фоновая служба: $e'); // отправка всё равно пойдёт, пока приложение открыто
    }
  }
  try {
    return await job();
  } finally {
    if (Platform.isAndroid && --_jobs == 0) await FlutterForegroundTask.stopService();
  }
}

/// Текст уведомления фоновой отправки, не чаще раза в секунду.
void backgroundStatus(String text) {
  if (_jobs == 0 || DateTime.now().difference(_shown).inSeconds < 1) return;
  _shown = DateTime.now();
  FlutterForegroundTask.updateService(notificationText: text);
}
