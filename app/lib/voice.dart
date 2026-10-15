import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'client.dart';
import 'theme.dart';

/// Запись голосового сообщения. WAV 16 кГц моно одинаково пишется и играется в браузере, на Android и iOS.
// ponytail: WAV ~2 МБ в минуту, перейти на AAC/Opus, когда понадобятся длинные голосовые.
class VoiceRecorder {
  final _rec = AudioRecorder();
  DateTime? _started;

  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final path = kIsWeb ? '' : '${(await getTemporaryDirectory()).path}/voice.wav';
    await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);
    _started = DateTime.now();
    return true;
  }

  Duration get elapsed => _started == null ? Duration.zero : DateTime.now().difference(_started!);

  /// Байты записи и длительность; null, если записи не было.
  Future<(Uint8List, Duration)?> stop() async {
    final duration = elapsed;
    _started = null;
    final path = await _rec.stop();
    if (path == null) return null;
    return (await XFile(path).readAsBytes(), duration);
  }

  Future<void> cancel() async {
    _started = null;
    await _rec.cancel();
  }

  void dispose() => _rec.dispose();
}

String formatDuration(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Проигрыватель голосового в пузыре: скачивает и расшифровывает при первом нажатии.
class VoicePlayer extends StatefulWidget {
  const VoicePlayer(this.file, {super.key});
  final Map<String, dynamic> file;

  @override
  State<VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<VoicePlayer> {
  final _player = AudioPlayer()..setReleaseMode(ReleaseMode.stop); // после конца можно слушать снова
  late final List<StreamSubscription> _subs;
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  late Duration _duration = Duration(milliseconds: widget.file['duration'] ?? 0);
  double? _dragging; // доля, пока палец двигает ползунок
  bool _loaded = false, _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs = [
      _player.onPlayerStateChanged.listen((s) => setState(() => _state = s)),
      _player.onPositionChanged.listen((p) => setState(() => _position = p)),
      _player.onDurationChanged.listen((d) => setState(() => _duration = d)),
      _player.onPlayerComplete.listen((_) => setState(() => _position = Duration.zero)),
    ];
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  /// Воспроизводим из файла: в браузере blob-адрес, на телефоне временный .wav.
  /// Так звук идёт самым обычным путём плеера, без data:-адресов и потоков из памяти.
  Future<bool> _load() async {
    if (_loaded) return true;
    setState(() => _loading = true);
    try {
      final bytes = await client.fileBytes(widget.file);
      if (kIsWeb) {
        await _player.setSource(UrlSource(XFile.fromData(bytes, mimeType: 'audio/wav').path, mimeType: 'audio/wav'));
      } else {
        final path = '${(await getTemporaryDirectory()).path}/voice-${widget.file['id']}.wav';
        await XFile.fromData(bytes).saveTo(path);
        await _player.setSource(DeviceFileSource(path, mimeType: 'audio/wav'));
      }
      return _loaded = true;
    } catch (e) {
      debugPrint('AURA: голосовое: $e');
      if (mounted) setState(() => _error = e is ApiException ? '$e' : 'Не удалось воспроизвести');
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) return _player.pause();
    if (await _load()) await _player.resume();
  }

  Future<void> _seek(double fraction) async {
    setState(() => _dragging = null);
    if (!await _load()) return;
    final to = _duration * fraction;
    setState(() => _position = to);
    await _player.seek(to);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final playing = _state == PlayerState.playing;
    final total = _duration.inMilliseconds;
    final fraction = _dragging ?? (total == 0 ? 0.0 : (_position.inMilliseconds / total).clamp(0.0, 1.0));
    final started = playing || _position > Duration.zero || _dragging != null;
    return SizedBox(
      width: 220,
      child: Row(children: [
        IconButton(
          tooltip: playing ? 'Пауза' : 'Слушать',
          onPressed: _loading ? null : _toggle,
          icon: _loading
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: c.ink),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: c.ink.withValues(alpha: 0.7),
                inactiveTrackColor: c.ink.withValues(alpha: 0.15),
                thumbColor: c.ink,
              ),
              child: Slider(
                semanticFormatterCallback: (v) => formatDuration(_duration * v),
                value: fraction,
                onChanged: total == 0 ? null : (v) => setState(() => _dragging = v),
                onChangeEnd: total == 0 ? null : _seek,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _error ?? formatDuration(started ? _duration * fraction : _duration),
              style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.6)),
            ),
          ]),
        ),
      ]),
    );
  }
}
