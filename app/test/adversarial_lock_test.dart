// Адверсариальные проверки блокировки приложения (lock.dart). Красный тест = обход блокировки.
@Timeout(Duration(seconds: 20))
library;

import 'dart:async';

import 'package:aura/lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  void goHidden(WidgetTester t) {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }

  void goResumed(WidgetTester t) {
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  }

  testWidgets('A31: уход в фон во время выбора файла не оставляет приложение незапертым', (tester) async {
    AppLock.enabled.value = false;
    await tester.pumpWidget(MaterialApp(builder: (context, child) => LockGate(child: child!), home: const Text('чаты')));
    AppLock.enabled.value = true;
    // Пользователь открыл системный выбор файла, затем свернул всё и оставил телефон.
    final picker = Completer<void>();
    final picking = AppLock.whilePicking(() => picker.future);
    goHidden(tester);
    await tester.pump();
    // Посторонний возвращается в приложение: выбор файла отменён «Назад».
    picker.complete();
    await picking;
    goResumed(tester);
    await tester.pump();
    expect(find.text('AURA заблокирована'), findsOneWidget, reason: 'после выбора файла приложение открыто без биометрии');
    expect(find.text('чаты'), findsNothing);
  });

  testWidgets('A32: под замком ввод с клавиатуры не попадает в открытый чат', (tester) async {
    AppLock.enabled.value = false;
    final text = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => LockGate(child: child!),
      home: Scaffold(body: TextField(controller: text, autofocus: true)),
    ));
    await tester.pump();
    AppLock.enabled.value = true;
    goHidden(tester);
    await tester.pump();
    expect(find.text('AURA заблокирована'), findsOneWidget);
    // Поле чата осталось в дереве (Offstage) и с фокусом: подключённый ввод продолжает в него писать.
    tester.testTextInput.enterText('введено под замком');
    await tester.pump();
    expect(text.text, isEmpty, reason: 'в скрытое под замком поле попал текст «${text.text}»');
  });
}
