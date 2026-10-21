import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';

/// Отправка push через Firebase Cloud Messaging (HTTP v1) от сервисного аккаунта проекта.
/// В push только вид события, без отправителя и текста: устройство просыпается и забирает
/// зашифрованное сообщение у сервера само.
class Fcm {
  Fcm._(this._client, this._project);
  final AuthClient _client;
  final String _project;

  /// [credentials] — JSON ключа сервисного аккаунта Firebase.
  static Future<Fcm> fromJson(String credentials) async {
    final j = jsonDecode(credentials) as Map<String, dynamic>;
    final client = await clientViaServiceAccount(ServiceAccountCredentials.fromJson(j), [
      'https://www.googleapis.com/auth/firebase.messaging',
    ]);
    return Fcm._(client, j['project_id'] as String);
  }

  /// false — токен больше не действует (приложение удалено или переустановлено).
  Future<bool> send(String token, String kind) async {
    final r = await _client.post(
      Uri.parse('https://fcm.googleapis.com/v1/projects/$_project/messages:send'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'message': {
          'token': token,
          'data': {'kind': kind},
          // Звонок и его отмена через 45 секунд уже не нужны, будить позже незачем.
          'android': {'priority': 'HIGH', 'ttl': kind == 'message' ? '86400s' : '45s'},
        },
      }),
    );
    // Остальные отказы (чужой проект, нет прав у ключа) иначе не видны нигде.
    if (r.statusCode != 200) print('push: Firebase ответил ${r.statusCode}: ${r.body}');
    return !(r.statusCode == 404 || (r.statusCode == 400 && r.body.contains('UNREGISTERED')));
  }
}
