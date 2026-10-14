import 'package:flutter/material.dart';

import 'client.dart';
import 'lock.dart';
import 'screens/auth.dart';
import 'screens/home.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([client.load(), AppLock.load()]);
  runApp(const AuraApp());
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
        builder: (context, child) => LockGate(child: child!),
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
