import 'dart:io';

import 'package:server/server.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';

/// AURA_DB — файл базы (по умолчанию aura.db), AURA_FILES — папка зашифрованных файлов
/// (по умолчанию files рядом с базой), AURA_WEB — папка Web-сборки, PORT — порт (8080),
/// AURA_TURN_URL и AURA_TURN_SECRET — TURN-сервер для звонков (необязательно).
Future<void> main() async {
  final env = Platform.environment;
  final turnUrl = env['AURA_TURN_URL'], turnSecret = env['AURA_TURN_SECRET'];
  final aura = AuraServer(
    env['AURA_DB'] ?? 'aura.db',
    files: env['AURA_FILES'],
    turn: (turnUrl ?? '').isNotEmpty && (turnSecret ?? '').isNotEmpty ? (url: turnUrl!, secret: turnSecret!) : null,
  );
  final webDir = env['AURA_WEB'];

  var handler = aura.handler;
  if (webDir != null && Directory(webDir).existsSync()) {
    // no-cache: браузер и Cloudflare сверяются с сервером, поэтому после обновления сразу видна новая версия.
    final web = const Pipeline()
        .addMiddleware(
          (inner) => (req) async => (await inner(req)).change(headers: {'cache-control': 'no-cache'}),
        )
        .addHandler(createStaticHandler(webDir, defaultDocument: 'index.html'));
    handler = Cascade().add(aura.handler).add(web).handler;
  }

  final port = int.parse(env['PORT'] ?? '8080');
  final server = await io.serve(
    const Pipeline().addMiddleware(logRequests()).addHandler(handler),
    InternetAddress.anyIPv4,
    port,
  );
  print('AURA server on :${server.port}');

  ProcessSignal.sigterm.watch().listen((_) async {
    await server.close();
    aura.close();
    exit(0);
  });
}
