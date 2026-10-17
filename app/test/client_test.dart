import 'dart:async';
import 'dart:typed_data';

import 'package:aura/client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('файл грузится и скачивается частями до 4 одновременно, по порядку', () async {
    SharedPreferences.setMockInitialValues({});
    await client.load();
    Uint8List? stored;
    // Части держатся, пока в пути не окажутся 4 сразу: без параллельности тест упрётся в тайм-аут.
    var running = 0, peak = 0, gate = Completer<void>();
    final server = MockClient((req) async {
      final q = req.url.queryParameters;
      if (req.method == 'POST' && req.url.path == '/api/files') {
        stored = Uint8List(int.parse(q['size']!))..setAll(0, req.bodyBytes);
        return http.Response('{"id": "f"}', 200);
      }
      peak = ++running > peak ? running : peak;
      if (running == 4 && !gate.isCompleted) gate.complete();
      await gate.future.timeout(const Duration(seconds: 20), onTimeout: () {});
      running--;
      if (req.method == 'POST') {
        stored!.setAll(int.parse(q['offset']!), req.bodyBytes);
        return http.Response('{"id": "f"}', 200);
      }
      final [start, end] = req.headers['range']!.substring(6).split('-').map(int.parse).toList();
      return http.Response.bytes(stored!.sublist(start, end + 1), 206);
    });
    final data = Uint8List.fromList(List.generate(4 * AuraClient.part + 1000, (i) => i * 7 % 251));
    final sent = <int>[];
    final file = await http.runWithClient(
      () => client.sendStream('oleg', 'big.bin', Stream.value(data), data.length, onProgress: (n, _) => sent.add(n)),
      () => server,
    );
    expect(peak, 4, reason: 'первая часть одна, потом 4 одновременно, не больше');
    expect(sent.last, data.length);
    expect(stored!.length, data.length + 5 * 28);

    (peak, gate) = (0, Completer<void>());
    final parts = await http.runWithClient(() => client.fileParts({...file}).toList(), () => server);
    expect(peak, 4);
    expect(parts.expand((p) => p).toList(), data);
  });
}
