import 'package:aura/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('регистрация проверяет поля и пускает в чаты', (tester) async {
    await tester.pumpWidget(const AuraApp());
    await tester.tap(find.text('Создать аккаунт'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Зарегистрироваться'));
    await tester.pump();
    expect(find.textContaining('не короче 3'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'anna');
    await tester.enterText(fields.at(1), 'secret1');
    await tester.enterText(fields.at(2), 'secret2');
    await tester.tap(find.text('Зарегистрироваться'));
    await tester.pump();
    expect(find.textContaining('не совпадают'), findsOneWidget);

    await tester.enterText(fields.at(2), 'secret1');
    await tester.tap(find.text('Зарегистрироваться'));
    await tester.pumpAndSettle();
    expect(find.text('Анна Морозова'), findsOneWidget);

    await tester.tap(find.text('Анна Морозова'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Сообщение…'), 'Тест');
    await tester.tap(find.byTooltip('Отправить'));
    await tester.pump();
    expect(find.text('Тест'), findsOneWidget);
  });
}
