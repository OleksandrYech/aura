import 'dart:convert';

import 'package:aura/client.dart';
import 'package:aura/screens/home.dart';
import 'package:aura/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('меню у сообщения: реакция, ответ с цитатой и выбор нескольких', (tester) async {
    Map<String, dynamic> msg(String id, String text) => {'id': id, 'mine': false, 'text': text, 'time': 1, 'status': 'read'};
    SharedPreferences.setMockInitialValues({
      'nick': 'anna',
      'chats': jsonEncode({
        'chats': {'den': [msg('m1', 'привет'), msg('m2', 'как дела')]},
        'names': {'den': 'Ден'},
        'lastRead': {},
      }),
    });
    await client.load();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const ChatScreen(peer: 'den')));

    await tester.longPress(find.text('привет'));
    await tester.pumpAndSettle();
    expect(find.text('Ответить'), findsOneWidget);
    await tester.tap(find.text('🔥'));
    await tester.pumpAndSettle();
    expect(client.chats['den']!.first.reactions, {'anna': '🔥'});
    expect(find.text('🔥'), findsOneWidget, reason: 'реакция под сообщением');

    await tester.longPress(find.text('привет'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ответить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'хорошо');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    final sent = client.chats['den']!.last;
    expect(sent.reply, {'id': 'm1', 'from': 'den', 'text': 'привет'});
    expect(find.byType(Quote), findsOneWidget, reason: 'цитата в пузыре, панель ответа закрыта');

    await tester.longPress(find.text('как дела'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('хорошо'), warnIfMissed: false); // при выборе нажатие ловит вся строка
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('У всех'), findsNothing, reason: 'среди выбранных есть чужое');
    await tester.tap(find.text('У меня'));
    await tester.pumpAndSettle();
    expect(client.chats['den']!.map((m) => m.text), ['привет']);
    expect(find.text('Выбрано: 2'), findsNothing);
  });
}
