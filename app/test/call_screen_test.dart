import 'package:aura/call.dart';
import 'package:aura/screens/call.dart';
import 'package:aura/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('экран завершённого звонка по центру, а не в левом верхнем углу', (tester) async {
    calls
      ..peer = 'anna'
      ..ended = 'Звонок завершён';
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const CallScreen()));
    final screen = tester.getRect(find.byType(CallScreen));
    expect(tester.getCenter(find.text('Звонок завершён')).dx, screen.center.dx);
    expect(tester.getCenter(find.text('anna')).dy, greaterThan(screen.height / 4));
    await tester.pumpWidget(const SizedBox()); // секундомер экрана останавливается
  });
}
