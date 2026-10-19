import 'dart:async';

import 'package:flutter/material.dart';

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
      CallState.ringing => 'Входящий звонок',
      _ => 'Соединение…',
    };
  }

  Widget _button(IconData icon, String label, VoidCallback? onTap, {Color? color, bool on = false}) {
    final c = AuraColors.of(context);
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
      Text(label, style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.7))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final name = calls.peer == null ? '' : client.title(calls.peer!);
    final live = calls.state != CallState.idle;
    return Material(
      color: c.cream,
      child: SafeArea(
        child: Column(children: [
          const Spacer(),
          Avatar(name, size: 112),
          const SizedBox(height: 24),
          Text(name, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(_status, style: TextStyle(fontSize: 16, color: c.ink.withValues(alpha: 0.6))),
          const Spacer(flex: 2),
          if (live)
            Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: calls.state == CallState.ringing
                  ? Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      _button(Icons.call_end, 'Отклонить', calls.hangup, color: Colors.red.shade600),
                      _button(Icons.call, 'Ответить', calls.accept, color: Colors.green.shade600),
                    ])
                  : Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      _button(calls.muted ? Icons.mic_off : Icons.mic_none, 'Микрофон', calls.toggleMute,
                          on: calls.muted),
                      _button(Icons.call_end, 'Завершить', calls.hangup, color: Colors.red.shade600),
                      _button(Icons.volume_up_outlined, 'Динамик', calls.toggleSpeaker, on: calls.speaker),
                    ]),
            ),
        ]),
      ),
    );
  }
}
