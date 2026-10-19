import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'client.dart';

enum CallState { idle, calling, ringing, connecting, active }

/// Голосовой звонок один на один через WebRTC. Звук шифруется DTLS-SRTP, а предложение и ответ
/// идут зашифрованными сообщениями Signal: подменить их сервер не может.
/// Кандидаты ICE не шлём по одному: ждём, пока соберутся, и кладём их в само предложение и ответ.
class Calls extends ChangeNotifier {
  CallState state = CallState.idle;

  /// Собеседник и id текущего звонка.
  String? peer;
  String? _id;

  /// Почему звонок закончился, для экрана: «Занято», «Нет ответа»…
  String? ended;
  bool muted = false, speaker = false;
  DateTime? since;

  RTCPeerConnection? _pc;
  MediaStream? _mic;
  Map<String, dynamic>? _offer;
  Timer? _timeout;

  /// На вебе звук собеседника играет через рендерер.
  final _audio = RTCVideoRenderer();
  bool _audioReady = false;

  /// Предложение старше этого — пропущенный звонок, а не входящий.
  static const ring = Duration(seconds: 45);

  void init() => client.onCall = _onSignal;

  Future<void> start(String to) async {
    if (state != CallState.idle) return;
    _set(CallState.calling, to, '${DateTime.now().microsecondsSinceEpoch}${Random.secure().nextInt(1 << 30)}');
    try {
      final pc = await _connect();
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      client.sendCall(to, {'type': 'offer', 'id': _id, 'sdp': await _gathered(pc)});
      _timeout = Timer(ring, () => _finish('Нет ответа', notify: true));
    } catch (e) {
      debugPrint('AURA: звонок $to: $e');
      _finish('Нет доступа к микрофону');
    }
  }

  Future<void> accept() async {
    if (state != CallState.ringing) return;
    _timeout?.cancel();
    state = CallState.connecting;
    notifyListeners();
    try {
      final pc = await _connect();
      await pc.setRemoteDescription(RTCSessionDescription(_offer!['sdp'], 'offer'));
      await pc.setLocalDescription(await pc.createAnswer());
      client.sendCall(peer!, {'type': 'answer', 'id': _id, 'sdp': await _gathered(pc), 'device': client.device});
    } catch (e) {
      debugPrint('AURA: ответ на звонок: $e');
      _finish('Нет доступа к микрофону', notify: true);
    }
  }

  /// Сброс, отказ или отмена — собеседник узнаёт об этом сразу.
  void hangup() => _finish(null, notify: true);

  void toggleMute() {
    muted = !muted;
    for (final t in _mic?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !muted;
    }
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    speaker = !speaker;
    if (!kIsWeb) await Helper.setSpeakerphoneOn(speaker);
    notifyListeners();
  }

  void _onSignal(String from, int device, int sentAt, Map<String, dynamic> s) {
    final mine = s['id'] == _id && from == peer;
    switch (s['type']) {
      case 'offer' when DateTime.now().millisecondsSinceEpoch - sentAt < ring.inMilliseconds:
        if (state != CallState.idle) {
          client.sendCall(from, {'type': 'busy', 'id': s['id']});
          return;
        }
        _offer = s;
        _set(CallState.ringing, from, s['id']);
        _timeout = Timer(ring, () => _finish('Пропущенный звонок'));
      case 'answer' when mine && state == CallState.calling:
        _timeout?.cancel();
        state = CallState.connecting;
        notifyListeners();
        _pc?.setRemoteDescription(RTCSessionDescription(s['sdp'], 'answer'));
        // Остальные устройства собеседника перестают звонить.
        client.sendCall(from, {'type': 'taken', 'id': _id, 'device': s['device']});
      case 'taken' when mine && state == CallState.ringing && s['device'] != client.device:
        _finish('Ответили на другом устройстве');
      case 'busy' when mine:
        _finish('Занято');
      case 'end' when mine:
        _finish(switch (state) {
          CallState.ringing => 'Пропущенный звонок',
          CallState.calling => 'Отклонён',
          _ => 'Звонок завершён',
        });
    }
  }

  void _set(CallState s, String with_, String id) {
    state = s;
    peer = with_;
    _id = id;
    ended = null;
    muted = speaker = false;
    since = null;
    notifyListeners();
  }

  Future<RTCPeerConnection> _connect() async {
    if (!_audioReady) {
      await _audio.initialize();
      _audioReady = true;
    }
    _mic = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final pc = _pc = await createPeerConnection({'iceServers': await client.iceServers()});
    for (final t in _mic!.getAudioTracks()) {
      await pc.addTrack(t, _mic!);
    }
    pc.onTrack = (e) {
      if (e.streams.isNotEmpty) _audio.srcObject = e.streams.first;
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && state == CallState.connecting) {
        state = CallState.active;
        since = DateTime.now();
        notifyListeners();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _finish('Не удалось соединиться', notify: true);
      }
    };
    return pc;
  }

  /// Описание сессии со всеми кандидатами ICE; сбор ждём не дольше нескольких секунд.
  Future<String> _gathered(RTCPeerConnection pc) async {
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    if (pc.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await done.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    return (await pc.getLocalDescription())!.sdp!;
  }

  void _finish(String? reason, {bool notify = false}) {
    if (state == CallState.idle) return;
    if (notify) client.sendCall(peer!, {'type': 'end', 'id': _id});
    _timeout?.cancel();
    _pc?.close();
    _pc = null;
    _mic?.getTracks().forEach((t) => t.stop());
    _mic?.dispose();
    _mic = null;
    _audio.srcObject = null;
    _offer = null;
    state = CallState.idle;
    // Причину показываем пару секунд, затем экран звонка закрывается.
    ended = reason ?? 'Звонок завершён';
    Timer(const Duration(seconds: 2), () {
      if (state == CallState.idle) ended = null;
      notifyListeners();
    });
    notifyListeners();
  }
}

final calls = Calls();
