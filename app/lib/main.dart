import 'package:flutter/material.dart';

import 'call.dart';
import 'client.dart';
import 'lock.dart';
import 'push.dart';
import 'screens/auth.dart';
import 'screens/call.dart';
import 'screens/home.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([client.load(), AppLock.load()]);
  calls.init();
  _notifications();
  runApp(const AuraApp());
}

/// Пока приложение открыто, уведомления не нужны; в фоне соединение ещё живо какое-то время,
/// и сообщения со звонками приходят по нему, а не через push.
void _notifications() {
  bool background() => WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;
  var ringing = false;
  client.onIncoming = () {
    if (background()) notify('message');
  };
  calls.addListener(() {
    if (calls.state == CallState.ringing && !ringing && background()) notify('call');
    if (ringing && calls.state != CallState.ringing) cancelCallNote();
    ringing = calls.state == CallState.ringing;
  });
  onCallAction = (action) {
    if (calls.state != CallState.ringing) return;
    action == 'answer' ? calls.accept() : calls.hangup();
  };
  AppLifecycleListener(onResume: cancelNotes);
  initPush(client.setPushToken);
}

class AuraApp extends StatelessWidget {
  const AuraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'AURA',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        builder: (context, child) => LockGate(child: CallLayer(child: child!)),
        // Корневой экран следует за состоянием входа: вход и выход переключают его сами.
        home: ListenableBuilder(
          listenable: client,
          builder: (context, _) => client.signedIn ? const HomeScreen() : const WelcomeScreen(),
        ),
        routes: {
          '/sign-in': (_) => const SignInScreen(),
          '/register': (_) => const RegisterScreen(),
        },
      ),
    );
  }
}
