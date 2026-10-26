import 'package:aura/call.dart';
import 'package:aura/client.dart';
import 'package:aura/screens/home.dart';
import 'package:aura/theme.dart';
import 'package:aura/video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Message _msg({String text = '', Map<String, dynamic>? file}) =>
    Message(id: '1', mine: true, text: text, time: 0, status: Status.sent, file: file);

Future<void> _show(WidgetTester tester, Message m) => tester.pumpWidget(MaterialApp(
  theme: buildTheme(Brightness.light),
  home: Scaffold(body: Align(alignment: Alignment.topLeft, child: MessageBubble(m))),
));

void main() {
  const video = {'id': 'f', 'key': 'k', 'name': 'clip.mp4', 'size': 1000, 'video': true};

  testWidgets('видео в пузыре от края до края, без рамки вокруг', (tester) async {
    await _show(tester, _msg(file: video));
    final bubble = tester.getRect(find.byType(MessageBubble));
    final preview = tester.getRect(find.byType(VideoAttachment));
    expect(preview.width, bubbleWidth);
    expect(preview.topLeft, bubble.topLeft);
    expect(preview.bottom, bubble.bottom, reason: 'время лежит на превью, а не под ним');
  });

  testWidgets('подпись к видео идёт под превью', (tester) async {
    await _show(tester, _msg(text: 'смотри', file: video));
    expect(tester.getRect(find.text('смотри')).top, greaterThan(tester.getRect(find.byType(VideoAttachment)).bottom));
  });

  testWidgets('текст в пузыре с отступами и небольшим скруглением', (tester) async {
    await _show(tester, _msg(text: 'привет'));
    final box = tester.widget<Container>(find.descendant(of: find.byType(MessageBubble), matching: find.byType(Container)).first);
    expect((box.decoration as BoxDecoration).borderRadius, BorderRadius.circular(radiusBubble));
    expect(tester.getRect(find.text('привет')).left - tester.getRect(find.byType(MessageBubble)).left, 16);
  });

  test('видео звонка: потолок качества выше 720p, при плохой связи WebRTC снижает и разрешение', () {
    final p = Calls.videoParameters();
    expect(p.degradationPreference, RTCDegradationPreference.BALANCED);
    expect(p.encodings!.single.maxBitrate, greaterThanOrEqualTo(4000000));
  });

  test('видео звонка на Android с программным декодером не выше 720p-битрейта', () {
    expect(Calls.videoParameters(sw: true).encodings!.single.maxBitrate, lessThanOrEqualTo(2500000));
  });
}
