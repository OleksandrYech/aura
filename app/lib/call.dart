import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'client.dart';

enum CallState { idle, calling, ringing, connecting, active }

/// Звонок один на один через WebRTC, голосовой или с видео. Звук и видео шифруются DTLS-SRTP, а предложение и ответ
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

  /// Своя камера включена; камера собеседника включена; своя камера — фронтальная.
  bool video = false, peerVideo = false, front = true;

  /// Android декодирует видео программно (см. [_connect]): с 720p видео с ноутбука на телефоне шло, а после
  /// подъёма до 1080p и 4 Мбит/с пропало. Такому собеседнику шлём не больше 720p, как до подъёма.
  static final _sw = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool _peerSw = false;

  /// Почему не включилась камера: показываем в звонке, иначе кнопка просто молча не срабатывает.
  String? cameraError;

  /// Видео собеседника и своё превью.
  final remote = RTCVideoRenderer(), local = RTCVideoRenderer();

  RTCPeerConnection? _pc;
  MediaStream? _mic, _cam, _peerVideo;

  /// Видеоканал есть в каждом звонке с самого начала: камеру включают и выключают заменой дорожки,
  /// без повторного обмена предложением и ответом.
  RTCRtpSender? _videoSender;
  Map<String, dynamic>? _offer;
  Timer? _timeout;

  /// На вебе звук собеседника играет через рендерер.
  final _audio = RTCVideoRenderer();
  bool _audioReady = false;

  /// Предложение старше этого — пропущенный звонок, а не входящий.
  static const ring = Duration(seconds: 45);

  void init() {
    client.onCall = _onSignal;
    addListener(_sound);
    AppLifecycleListener(onStateChange: (_) => _sound());
    // Гудки как разговор: в трубку у уха, а с громкой связью в динамик. Без этого Android играет их
    // как музыку, всегда в нижний динамик. ponytail: только Android; на iOS контекст плеера общий
    // для всего приложения, и голосовые сообщения тоже ушли бы в трубку.
    if (_phone && defaultTargetPlatform == TargetPlatform.android) {
      _toneQueue = _tone
          .setAudioContext(AudioContext(
            android: const AudioContextAndroid(
              usageType: AndroidUsageType.voiceCommunication,
              contentType: AndroidContentType.speech,
              audioFocus: AndroidAudioFocus.none, // фокус держит WebRTC, иначе гудки замолкнут при его старте
            ),
          ))
          .catchError((Object e) => debugPrint('AURA: звук звонка: $e'));
    }
  }

  /// Свёрнутое приложение на Android звонит уведомлением, а не своей мелодией: Android замораживает
  /// его в фоне, и мелодию, которую плеер крутит по кругу, уже некому остановить.
  bool get _ringHere =>
      kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      switch (WidgetsBinding.instance.lifecycleState) {
        AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
        _ => true,
      };

  final _tone = AudioPlayer();

  /// Входящий на телефоне звонит нативно: на Android мелодией из настроек телефона, на iOS своей
  /// (системная приложениям недоступна), и всегда через динамик, даже с наушниками.
  static const _ringtone = MethodChannel('aura/ring');
  static final _phone =
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  String? _playing;

  /// Гудки, пока ждём ответа, мелодия входящего и короткие сигналы, когда звонок закончился.
  void _sound() {
    final want = switch (state) {
      CallState.calling => 'ringback',
      CallState.ringing when _ringHere => 'ringtone',
      CallState.idle when ended != null => 'end',
      _ => null,
    };
    if (want == _playing) return;
    _playing = want;
    // По очереди: иначе поздний stop может прийти раньше раннего play, и гудки не смолкнут.
    _toneQueue = _toneQueue.then((_) async {
      await _tone.stop();
      if (_phone) await _ringtone.invokeMethod('stop');
      if (want == null || want != _playing) return;
      if (want == 'ringtone' && _phone) return _ringtone.invokeMethod('start');
      await _tone.setReleaseMode(want == 'end' ? ReleaseMode.stop : ReleaseMode.loop);
      await _tone.play(AssetSource('sounds/$want.wav'), volume: want == 'ringback' ? 0.75 : 1);
    }).catchError((Object e) => debugPrint('AURA: звук звонка: $e'));
  }

  Future<void> _toneQueue = Future.value();

  Future<void> start(String to) async {
    if (state != CallState.idle) return;
    _set(CallState.calling, to, '${DateTime.now().microsecondsSinceEpoch}${Random.secure().nextInt(1 << 30)}');
    try {
      final pc = await _connect();
      _videoSender = (await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
      )).sender;
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      client.sendCall(to, {'type': 'offer', 'id': _id, 'sdp': await _gathered(pc), 'sw': _sw});
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
      // Видеоканал создало предложение; без SendRecv своё видео по нему не пойдёт.
      for (final t in await pc.getTransceivers()) {
        if (t.receiver.track?.kind == 'video') {
          await t.setDirection(TransceiverDirection.SendRecv);
          _videoSender = t.sender;
        }
      }
      // На видеозвонок отвечаем с камерой.
      if (_offer!['video'] == true) await _camera(true);
      await pc.setLocalDescription(await pc.createAnswer());
      client.sendCall(peer!, {
        'type': 'answer',
        'id': _id,
        'sdp': await _gathered(pc),
        'device': client.device,
        'video': video,
        'sw': _sw,
      });
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

  Future<void> toggleCamera() async {
    await _camera(!video);
    if (state != CallState.idle) client.sendCall(peer!, {'type': 'video', 'id': _id, 'on': video});
  }

  /// Отладка видео по статистике WebRTC: что уходит и что приходит. Включается долгим нажатием на статус.
  Future<String> videoStats() async {
    final reports = await _pc?.getStats() ?? <StatsReport>[];
    final byId = {for (final r in reports) r.id: r.values};
    String codec(Map v) => '${byId[v['codecId']]?['mimeType'] ?? '?'}'.replaceFirst('video/', '');
    return [
      for (final r in reports)
        if (r.values['kind'] == 'video' && r.type == 'outbound-rtp')
          '→ ${codec(r.values)} ${r.values['frameWidth']}x${r.values['frameHeight']} отправлено ${r.values['framesSent']} '
              '${r.values['framesPerSecond'] ?? 0} к/с ${((r.values['targetBitrate'] ?? 0) as num) ~/ 1000} кбит/с ключевых ${r.values['keyFramesEncoded']} PLI ${r.values['pliCount']} ${r.values['qualityLimitationReason']}'
        else if (r.values['kind'] == 'video' && r.type == 'inbound-rtp')
          '← ${codec(r.values)} ${r.values['frameWidth']}x${r.values['frameHeight']} пришло ${r.values['framesReceived']} '
              'декод ${r.values['framesDecoded']} ${r.values['framesPerSecond'] ?? 0} к/с ключевых ${r.values['keyFramesDecoded']} PLI ${r.values['pliCount']}',
    ].join('\n');
  }

  Future<void> switchCamera() async {
    final t = _cam?.getVideoTracks().firstOrNull;
    if (t == null) return;
    front = await Helper.switchCamera(t);
    notifyListeners();
  }

  /// Камера не нужна, чтобы разговаривать: если её нет или не дали доступ, звонок идёт без видео.
  Future<void> _camera(bool on) async {
    cameraError = null;
    try {
      if (on && _videoSender == null) throw 'нет видеоканала в звонке';
      if (on && _cam == null) {
        final cam = _cam = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {'facingMode': 'user', 'width': _peerSw ? 1280 : 1920, 'height': _peerSw ? 720 : 1080, 'frameRate': 30},
        });
        if (state == CallState.idle) {
          _stopCamera(); // звонок кончился, пока ждали доступ
          return;
        }
        await _videoSender!.replaceTrack(cam.getVideoTracks().first);
        local.srcObject = cam;
        video = true;
        front = true;
      } else if (!on && _cam != null) {
        await _videoSender?.replaceTrack(null);
        _stopCamera();
      }
    } catch (e) {
      debugPrint('AURA: камера: $e');
      cameraError = '$e';
      _stopCamera();
    }
    notifyListeners();
  }

  /// Потолок видео: 1080p, 30 к/с, до [maxVideoBitrate]; собеседнику на Android — 720p и [swVideoBitrate].
  /// Ниже WebRTC опускается сам по оценке канала и загрузке процессора: сначала битрейт, затем разрешение и частота кадров вместе (balanced), а когда связь лучше — обратно.
  static const maxVideoBitrate = 4000000, swVideoBitrate = 2500000;

  static RTCRtpParameters videoParameters({bool sw = false}) => RTCRtpParameters(
    degradationPreference: RTCDegradationPreference.BALANCED,
    encodings: [
      RTCRtpEncoding(maxBitrate: sw ? swVideoBitrate : maxVideoBitrate, maxFramerate: 30, priority: RTCPriorityType.high),
    ],
  );

  /// Параметры кодировщика принимаются только после согласования, поэтому — когда соединение установлено.
  Future<void> _tuneVideo() async {
    try {
      await _videoSender?.setParameters(videoParameters(sw: _peerSw));
    } catch (e) {
      debugPrint('AURA: параметры видео: $e'); // без них остаётся качество WebRTC по умолчанию
    }
  }

  void _stopCamera() {
    _cam?.getTracks().forEach((t) => t.stop());
    _cam?.dispose();
    _cam = null;
    local.srcObject = null;
    video = false;
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
        // Таймер до _set: слушатель может сразу ответить, и accept() должен его отменить.
        _timeout = Timer(ring, () => _finish('Пропущенный звонок'));
        _set(CallState.ringing, from, s['id'], peerVideo: s['video'] == true);
        _peerSw = s['sw'] == true;
      case 'answer' when mine && state == CallState.calling:
        _timeout?.cancel();
        state = CallState.connecting;
        peerVideo = s['video'] == true;
        _peerSw = s['sw'] == true;
        // Камеру включили, пока звонили: она снимает 1080p, а ответил телефон — переоткрываем в 720p.
        if (_peerSw && video) _camera(false).then((_) => _camera(true));
        notifyListeners();
        _pc?.setRemoteDescription(RTCSessionDescription(s['sdp'], 'answer'));
        // Остальные устройства собеседника перестают звонить.
        client.sendCall(from, {'type': 'taken', 'id': _id, 'device': s['device']});
      case 'taken' when mine && state == CallState.ringing && s['device'] != client.device:
        _finish('Ответили на другом устройстве');
      case 'video' when mine:
        peerVideo = s['on'] == true;
        notifyListeners();
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

  void _set(CallState s, String with_, String id, {bool peerVideo = false}) {
    state = s;
    peer = with_;
    _id = id;
    ended = null;
    cameraError = null;
    muted = speaker = false;
    this.peerVideo = peerVideo;
    _peerSw = false;
    since = null;
    notifyListeners();
  }

  Future<RTCPeerConnection> _connect() async {
    if (!_audioReady) {
      // Только программные кодеки видео, до первого обращения к WebRTC. Пустой forceSWCodecList
      // обязателен: без него телефон предлагает и аппаратный H264, а декодировать его потом нечем.
      if (!kIsWeb) await WebRTC.initialize(options: {'forceSWCodec': true, 'forceSWCodecList': []});
      await Future.wait([_audio.initialize(), remote.initialize(), local.initialize()]);
      _audioReady = true;
    }
    _mic = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    // WebRTC по умолчанию начинает с громкой связи; начинаем с трубки, как показывает кнопка «Динамик».
    if (_phone) await Helper.setSpeakerphoneOn(speaker);
    final pc = _pc = await createPeerConnection({'iceServers': await client.iceServers()});
    for (final t in _mic!.getAudioTracks()) {
      await pc.addTrack(t, _mic!);
    }
    pc.onTrack = (e) async {
      if (e.track.kind == 'video') {
        // Видео идёт без потока: собираем свой, чтобы рендерер его показал. На вебе в нём нет звука,
        // иначе голос собеседника играл бы дважды.
        final s = _peerVideo ??= await createLocalMediaStream('peer');
        await s.addTrack(e.track);
        remote.srcObject = s;
      } else if (e.streams.isNotEmpty) {
        _audio.srcObject = e.streams.first;
      }
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected && state == CallState.connecting) {
        state = CallState.active;
        since = DateTime.now();
        _tuneVideo();
        // Видеозвонок держат перед собой, а не у уха.
        if ((video || peerVideo) && !speaker) toggleSpeaker();
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
    _pc?.dispose(); // только dispose возвращает Android обычный режим звука, close оставляет «звонок»
    _pc = null;
    _mic?.getTracks().forEach((t) => t.stop());
    _mic?.dispose();
    _mic = null;
    _stopCamera();
    _videoSender = null;
    _peerVideo?.dispose();
    _peerVideo = null;
    peerVideo = false;
    remote.srcObject = null;
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
