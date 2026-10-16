import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'client.dart';
import 'media.dart';
import 'platform_media.dart';
import 'theme.dart';

/// Видео в пузыре: превью, присланное вместе с сообщением, само видео скачивается по нажатию.
class VideoAttachment extends StatelessWidget {
  const VideoAttachment(this.file, {super.key});
  final Map<String, dynamic> file;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final thumb = file['thumb'] is String ? base64.decode(file['thumb']) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        label: 'Видео ${file['name']}, ${formatSize(file['size'])}',
        child: GestureDetector(
          onTap: () => showDialog(context: context, builder: (_) => VideoDialog(file)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radiusMd),
            child: Stack(alignment: Alignment.center, children: [
              thumb != null
                  ? Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true)
                  : Container(width: 220, height: 124, color: c.ink.withValues(alpha: 0.85)),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
              ),
              Positioned(
                left: 8,
                bottom: 6,
                child: Text(
                  formatSize(file['size']),
                  style: const TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 4)]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Просмотр видео: скачивает, расшифровывает и проигрывает с перемоткой.
class VideoDialog extends StatefulWidget {
  const VideoDialog(this.file, {super.key});
  final Map<String, dynamic> file;

  @override
  State<VideoDialog> createState() => _VideoDialogState();
}

class _VideoDialogState extends State<VideoDialog> {
  VideoPlayerController? _video;
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final bytes = _bytes = await client.fileBytes(widget.file);
      final video = await videoController(bytes, widget.file['id'], widget.file['name']);
      await video.initialize();
      if (!mounted) {
        await video.dispose();
        return;
      }
      setState(() => _video = video..addListener(() => setState(() {})));
      await video.play();
    } catch (e) {
      debugPrint('AURA: видео: $e');
      if (mounted) setState(() => _error = e is ApiException ? '$e' : 'Не удалось открыть видео');
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(12),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          IconButton(
            tooltip: 'Закрыть',
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          if (_bytes != null)
            IconButton(
              tooltip: 'Сохранить',
              icon: const Icon(Icons.download_outlined, color: Colors.white),
              onPressed: () => FilePicker.saveFile(fileName: widget.file['name'], bytes: _bytes!),
            ),
        ]),
        if (video == null)
          Padding(
            padding: const EdgeInsets.all(48),
            child: _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.white))
                : const CircularProgressIndicator(color: Colors.white),
          )
        else ...[
          Flexible(
            child: GestureDetector(
              onTap: () => video.value.isPlaying ? video.pause() : video.play(),
              child: AspectRatio(aspectRatio: video.value.aspectRatio, child: VideoPlayer(video)),
            ),
          ),
          Row(children: [
            IconButton(
              tooltip: video.value.isPlaying ? 'Пауза' : 'Смотреть',
              icon: Icon(video.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
              onPressed: () => video.value.isPlaying ? video.pause() : video.play(),
            ),
            Expanded(
              child: VideoProgressIndicator(
                video,
                allowScrubbing: true, // перемотка нажатием и перетаскиванием
                colors: const VideoProgressColors(
                  playedColor: Colors.white,
                  bufferedColor: Colors.white38,
                  backgroundColor: Colors.white12,
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                '${_time(video.value.position)} / ${_time(video.value.duration)}',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  static String _time(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
