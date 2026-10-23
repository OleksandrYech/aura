import 'package:aura/client.dart';
import 'package:aura/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
    expect(find.text('Сервер'), findsNothing, reason: 'адрес сервера зашит в приложение');
    await submit();
    expect(find.textContaining('не короче 3'), findsOneWidget);

    await tester.enterText(field.at(0), 'anna');
    await tester.enterText(field.at(1), 'secret1');
    await tester.enterText(field.at(2), 'secret2');
    await submit();
    expect(find.textContaining('не совпадают'), findsOneWidget);
  });

  testWidgets('вход на аккаунт с ключом показывает QR и код привязки', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await client.load();
    // Состояние после входа по паролю на аккаунт, у которого уже есть ключ (см. AuraClient.login).
    client
      ..token = 't'
      ..nick = 'anna'
      ..device = 2;
    tester.view.physicalSize = const Size(2400, 4800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const AuraApp());
    expect(client.needsLink, isTrue);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('Скопировать код'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200))); // выход доходит до конца
    await tester.pump(const Duration(seconds: 2)); // ожидание конверта видит выход и завершается
    expect(find.text('Войти'), findsOneWidget);
  });
}
