import 'dart:isolate';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Проект Firebase: CI подставляет его из переменных репозитория (см. README). Без них push выключены.
const _options = FirebaseOptions(
  apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
  appId: String.fromEnvironment('FIREBASE_APP_ID'),
  messagingSenderId: String.fromEnvironment('FIREBASE_SENDER_ID'),
  projectId: String.fromEnvironment('FIREBASE_PROJECT_ID'),
);

// ponytail: только Android; iOS ждёт аккаунта Apple, веб — Web Push.
bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

final _notes = FlutterLocalNotificationsPlugin();
const _callId = 1, _messageId = 2;

/// Кнопка в уведомлении о звонке: 'answer' или 'decline'. Работает, пока приложение живо;
/// из убитого приложения «Отклонить» только гасит уведомление.
void Function(String action)? onCallAction;

const _actionPort = 'aura_call_action';

/// «Отклонить» не открывает приложение, и плагин отдаёт её отдельному isolate: пересылаем основному.
@pragma('vm:entry-point')
void _backgroundAction(NotificationResponse r) {
  if (r.actionId != null) IsolateNameServer.lookupPortByName(_actionPort)?.send(r.actionId);
}

/// Один раз на isolate: основной, фоновый push и фоновая кнопка у каждого свой.
final _ready = _notes.initialize(
  settings: const InitializationSettings(android: AndroidInitializationSettings('ic_notification')),
  onDidReceiveNotificationResponse: (r) {
    if (r.actionId != null) onCallAction?.call(r.actionId!);
  },
  onDidReceiveBackgroundNotificationResponse: _backgroundAction,
);

/// Основной isolate принимает кнопки звонка. Возвращает кнопку, которой приложение запустили, если так.
Future<String?> initCallActions() async {
  if (!_android) return null;
  final port = ReceivePort()..listen((a) => onCallAction?.call(a as String));
  IsolateNameServer.removePortNameMapping(_actionPort);
  IsolateNameServer.registerPortWithName(port.sendPort, _actionPort);
  try {
    await _ready;
    return (await _notes.getNotificationAppLaunchDetails())?.notificationResponse?.actionId;
  } catch (e) {
    debugPrint('AURA: уведомления: $e');
    return null;
  }
}

/// Уведомление о входящем звонке или сообщении. В push только вид события: от кого и что,
/// приложение узнает, когда откроется и заберёт зашифрованное сообщение.
Future<void> notify(String kind) async {
  if (!_android) return;
  try {
    await _show(kind);
  } catch (e) {
    debugPrint('AURA: уведомление: $e');
  }
}

Future<void> _show(String kind) async {
  await _ready;
  if (kind == 'call') {
    await _notes.show(
      id: _callId,
      title: 'AURA',
      body: 'Входящий звонок',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'calls',
          'Звонки',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.call,
          fullScreenIntent: true,
          ongoing: true,
          sound: const RawResourceAndroidNotificationSound('aura_ring'),
          additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: мелодия повторяется
          timeoutAfter: 45000, // дольше звонок не ждёт
          actions: const [
            AndroidNotificationAction('decline', 'Отклонить'),
            AndroidNotificationAction('answer', 'Ответить', showsUserInterface: true),
          ],
        ),
      ),
    );
  } else {
    await _notes.show(
      id: _messageId,
      title: 'AURA',
      body: 'Новое сообщение',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails('messages', 'Сообщения', importance: Importance.high, priority: Priority.high),
      ),
    );
  }
}

Future<void> cancelCallNote() async {
  if (_android) await _notes.cancel(id: _callId);
}

Future<void> cancelNotes() async {
  if (_android) await _notes.cancelAll();
}

@pragma('vm:entry-point')
Future<void> _background(RemoteMessage m) async {
  await Firebase.initializeApp(options: _options);
  await notify(m.data['kind'] ?? 'message');
}

/// Включает push и отдаёт токен устройства в [register] сейчас и при каждой смене.
Future<void> initPush(void Function(String token) register) async {
  if (!_android || _options.apiKey.isEmpty) return;
  try {
    await Firebase.initializeApp(options: _options);
    FirebaseMessaging.onBackgroundMessage(_background);
    await FirebaseMessaging.instance.requestPermission();
    // Регистрационный токен FCM, его принимает HTTP v1 API на сервере; новый API с FID пока не трогаем.
    // ignore: deprecated_member_use
    FirebaseMessaging.instance.onTokenRefresh.listen(register);
    // ignore: deprecated_member_use
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) register(token);
  } catch (e) {
    debugPrint('AURA: push: $e');
  }
}
