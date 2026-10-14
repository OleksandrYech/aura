import 'package:aura/lock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app() => MaterialApp(builder: (context, child) => LockGate(child: child!), home: const Text('чаты'));

  testWidgets('без блокировки приложение открыто', (tester) async {
    AppLock.enabled.value = false;
    await tester.pumpWidget(app());
    expect(find.text('чаты'), findsOneWidget);
    expect(find.text('AURA заблокирована'), findsNothing);
  });

  testWidgets('с блокировкой содержимое скрыто, пока не разблокировали', (tester) async {
    AppLock.enabled.value = true;
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('AURA заблокирована'), findsOneWidget);
    expect(find.text('чаты'), findsNothing, reason: 'неудачная биометрия не открывает приложение');
  });

  testWidgets('уход в фон запирает приложение', (tester) async {
    AppLock.enabled.value = false;
    await tester.pumpWidget(app());
    AppLock.enabled.value = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(find.text('AURA заблокирована'), findsOneWidget);
    expect(find.text('чаты'), findsNothing);
  });
}
