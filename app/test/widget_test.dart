import 'package:aura/client.dart';
import 'package:aura/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('регистрация проверяет поля до обращения к серверу', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await client.load();
    await tester.pumpWidget(const AuraApp());
    await tester.tap(find.text('Создать аккаунт'));
    await tester.pumpAndSettle();

    Future<void> submit() async {
      await tester.tap(find.text('Зарегистрироваться'));
      await tester.pump();
    }

    final field = find.byType(TextField);
    await tester.enterText(field.at(0), 'aura.example.com');
    await submit();
    expect(find.textContaining('не короче 3'), findsOneWidget);

    await tester.enterText(field.at(1), 'anna');
    await tester.enterText(field.at(2), 'secret1');
    await tester.enterText(field.at(3), 'secret2');
    await submit();
    expect(find.textContaining('не совпадают'), findsOneWidget);
  });
}
