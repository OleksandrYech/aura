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
  final _player = AudioPlayer();
  late final List<StreamSubscription> _subs;
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  bool _loaded = false, _loading = false;
  String? _error;

  Duration get _duration => Duration(milliseconds: widget.file['duration'] ?? 0);

  @override
  void initState() {
    super.initState();
    _subs = [
      _player.onPlayerStateChanged.listen((s) => setState(() => _state = s)),
      _player.onPositionChanged.listen((p) => setState(() => _position = p)),
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

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) return _player.pause();
    if (!_loaded) {
      setState(() => _loading = true);
      try {
        await _player.setSourceBytes(await client.fileBytes(widget.file), mimeType: 'audio/wav');
        _loaded = true;
      } catch (e) {
        setState(() => _error = e is ApiException ? '$e' : 'Не удалось воспроизвести');
        return;
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }
    await _player.resume();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final playing = _state == PlayerState.playing;
    final total = _duration.inMilliseconds;
    final shown = playing || _state == PlayerState.paused ? _position : _duration;
    return SizedBox(
      width: 200,
      child: Row(
        children: [
          IconButton(
            tooltip: playing ? 'Пауза' : 'Слушать',
            onPressed: _loading ? null : _toggle,
            icon: _loading
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: c.ink),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: total == 0 || _state == PlayerState.stopped || _state == PlayerState.completed
                      ? 0
                      : (_position.inMilliseconds / total).clamp(0, 1),
                  minHeight: 3,
                  borderRadius: BorderRadius.circular(2),
                  color: c.ink.withValues(alpha: 0.7),
                  backgroundColor: c.ink.withValues(alpha: 0.15),
                ),
                const SizedBox(height: 4),
                Text(
                  _error ?? formatDuration(shown),
                  style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
