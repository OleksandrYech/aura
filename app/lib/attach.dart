import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'theme.dart';

enum AttachKind { media, file }

/// Меню скрепки: фото и видео из галереи или любой файл через проводник.
Future<AttachKind?> showAttachMenu(BuildContext context) => showModalBottomSheet<AttachKind>(
  context: context,
  builder: (context) => SafeArea(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        leading: const Icon(Icons.photo_library_outlined),
        title: const Text('Фото и видео'),
        onTap: () => Navigator.pop(context, AttachKind.media),
      ),
      ListTile(
        leading: const Icon(Icons.insert_drive_file_outlined),
        title: const Text('Файл'),
        subtitle: const Text('Отправится как есть, без сжатия'),
        onTap: () => Navigator.pop(context, AttachKind.file),
      ),
    ]),
  ),
);

/// Галерея телефона: сетка превью, можно выбрать несколько фото и видео.
/// Возвращает выбранное в порядке выбора, пустой список при отмене и null, если доступа к галерее нет.
Future<List<AssetEntity>?> pickFromGallery(BuildContext context) async {
  final permission = await PhotoManager.requestPermissionExtend();
  if (!permission.hasAccess) return null;
  final albums = await PhotoManager.getAssetPathList(onlyAll: true, type: RequestType.common);
  if (!context.mounted) return const [];
  if (albums.isEmpty) return const [];
  final picked = await showModalBottomSheet<List<AssetEntity>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _Gallery(albums.first, limited: permission == PermissionState.limited),
  );
  return picked ?? const [];
}

class _Gallery extends StatefulWidget {
  const _Gallery(this.album, {required this.limited});
  final AssetPathEntity album;
  final bool limited;

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  static const _page = 60;
  final _assets = <AssetEntity>[];
  final _thumbs = <String, Future<Uint8List?>>{};
  final _selected = <AssetEntity>[];
  bool _loading = false, _done = false;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_loading || _done) return;
    _loading = true;
    final next = await widget.album.getAssetListPaged(page: _assets.length ~/ _page, size: _page);
    if (!mounted) return;
    setState(() {
      _assets.addAll(next);
      _done = next.length < _page;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(children: [
            Expanded(
              child: Text(
                _selected.isEmpty ? 'Выберите фото или видео' : 'Выбрано: ${_selected.length}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
            if (widget.limited)
              TextButton(
                onPressed: () async {
                  await PhotoManager.presentLimited();
                  if (context.mounted) Navigator.pop(context); // список изменился, проще открыть заново
                },
                child: const Text('Доступ'),
              ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)), // в теме кнопки на всю ширину
              onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, _selected),
              child: const Text('Отправить'),
            ),
          ]),
        ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 600) _more();
              return false;
            },
            child: GridView.builder(
              controller: scroll,
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _assets.length,
              itemBuilder: (context, i) {
                final a = _assets[i];
                final order = _selected.indexOf(a);
                final video = a.type == AssetType.video;
                return Semantics(
                  button: true,
                  selected: order >= 0,
                  label: video ? 'Видео ${_duration(a.videoDuration)}' : 'Фото',
                  child: GestureDetector(
                    onTap: () => setState(() => order >= 0 ? _selected.remove(a) : _selected.add(a)),
                    child: Stack(fit: StackFit.expand, children: [
                      FutureBuilder(
                        future: _thumbs[a.id] ??= a.thumbnailDataWithSize(const ThumbnailSize.square(240)),
                        builder: (_, snap) => snap.data == null
                            ? ColoredBox(color: c.lightGray)
                            : Image.memory(snap.data!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                      if (order >= 0) ColoredBox(color: Colors.black.withValues(alpha: 0.25)),
                      if (video)
                        Positioned(
                          left: 6,
                          bottom: 4,
                          child: Text(
                            '▶ ${_duration(a.videoDuration)}',
                            style: const TextStyle(color: Colors.white, fontSize: 12, shadows: [Shadow(blurRadius: 4)]),
                          ),
                        ),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Container(
                          width: 24,
                          height: 24,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: order >= 0 ? c.ink : Colors.black26,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                          child: order >= 0
                              ? Text('${order + 1}', style: TextStyle(color: c.cream, fontSize: 12))
                              : null,
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
        ),
      ]),
    );
  }

  static String _duration(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
