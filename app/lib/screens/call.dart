import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call.dart';
import '../client.dart';
import '../theme.dart';
import 'home.dart';

/// Поверх всего приложения: входящий звонок виден на любом экране.
class CallLayer extends StatelessWidget {
  const CallLayer({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: calls,
    builder: (context, _) => Stack(children: [
      child,
      // Свой Overlay: слой лежит над навигатором, а подсказкам кнопок он нужен.
      if (calls.state != CallState.idle || calls.ended != null)
        Positioned.fill(child: Overlay(initialEntries: [OverlayEntry(builder: (_) => const CallScreen())])),
    ]),
  );
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  // Секундомер разговора.
  late final _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _tick;
    calls.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    calls.removeListener(_changed);
    _tick.cancel();
    super.dispose();
  }

  String get _status {
    if (calls.state == CallState.idle) return calls.ended ?? '';
    if (calls.state == CallState.active && calls.since != null) {
      final d = DateTime.now().difference(calls.since!);
      return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return switch (calls.state) {
      CallState.calling => 'Вызов…',
      CallState.ringing => calls.peerVideo ? 'Входящий видеозвонок' : 'Входящий звонок',
      _ => 'Соединение…',
    };
  }

  Widget _button(IconData icon, String label, VoidCallback? onTap, {Color? color, bool on = false}) {
    final c = AuraColors.of(context);
    final ink = _onVideo ? Colors.white : c.ink;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      IconButton.filled(
        iconSize: 32,
        tooltip: label,
        style: IconButton.styleFrom(
          backgroundColor: color ?? (on ? c.ink : c.lavender),
          foregroundColor: color != null || on ? Colors.white : c.ink,
          fixedSize: const Size(68, 68),
        ),
        onPressed: onTap,
        icon: Icon(icon),
      ),
      const SizedBox(height: 8),
      Text(label, style: TextStyle(fontSize: 13, color: ink.withValues(alpha: 0.7))),
    ]);
  }

  /// Во весь экран видео собеседника, а пока его нет — своё превью.
  RTCVideoRenderer? get _big => calls.state == CallState.idle
      ? null
      : calls.peerVideo && calls.state != CallState.ringing
      ? calls.remote
      : calls.video
      ? calls.local
      : null;

  bool get _onVideo => _big != null;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final name = calls.peer == null ? '' : client.title(calls.peer!);
    final live = calls.state != CallState.idle;
    final big = _big;
    final ink = _onVideo ? Colors.white : c.ink;
    final small = big == calls.remote && calls.video;
    return Material(
      color: big != null ? Colors.black : c.cream,
      child: Stack(
        children: [
          if (big != null)
            Positioned.fill(
              child: RTCVideoView(
                big,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                mirror: big == calls.local && calls.front,
              ),
            ),
          SafeArea(child: _controls(c, name, live, ink)),
          if (small)
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: Container(
                  margin: const EdgeInsets.all(16),
                  width: 110,
                  height: 160,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: Colors.black),
                  child: RTCVideoView(
                    calls.local,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    mirror: calls.front,
                  ),
                ),
              ),
            ),
          if (calls.video && !kIsWeb && live)
            SafeArea(
              child: Align(
                alignment: small ? const Alignment(1, -0.35) : Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: IconButton.filled(
                    tooltip: 'Сменить камеру',
                    style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white),
                    onPressed: calls.switchCamera,
                    icon: const Icon(Icons.cameraswitch_outlined),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _controls(AuraColors c, String name, bool live, Color ink) => Column(
    children: [
      if (_onVideo) ...[
        const SizedBox(height: 24),
        Text(
          name,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: ink),
        ),
        const SizedBox(height: 4),
        Text(_status, style: TextStyle(fontSize: 15, color: ink.withValues(alpha: 0.8))),
        const Spacer(),
      ] else ...[
        const Spacer(),
        Avatar(name, size: 112),
        const SizedBox(height: 24),
        Text(name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Text(_status, style: TextStyle(fontSize: 16, color: c.ink.withValues(alpha: 0.6))),
        const Spacer(flex: 2),
      ],
      if (live)
        Padding(
          padding: const EdgeInsets.only(bottom: 48),
          child: calls.state == CallState.ringing
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _button(Icons.call_end, 'Отклонить', calls.hangup, color: Colors.red.shade600),
                    _button(
                      calls.peerVideo ? Icons.videocam : Icons.call,
                      'Ответить',
                      calls.accept,
                      color: Colors.green.shade600,
                    ),
                  ],
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _button(
                      calls.muted ? Icons.mic_off : Icons.mic_none,
                      'Микрофон',
                      calls.toggleMute,
                      on: calls.muted,
                    ),
                    _button(
                      calls.video ? Icons.videocam : Icons.videocam_off_outlined,
                      'Камера',
                      calls.toggleCamera,
                      on: calls.video,
                    ),
                    _button(Icons.call_end, 'Завершить', calls.hangup, color: Colors.red.shade600),
                    _button(Icons.volume_up_outlined, 'Динамик', calls.toggleSpeaker, on: calls.speaker),
                  ],
                ),
        ),
    ],
  );
}
