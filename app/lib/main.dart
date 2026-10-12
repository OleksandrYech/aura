import 'package:flutter/material.dart';

import 'screens/auth.dart';
import 'screens/home.dart';
import 'theme.dart';

void main() => runApp(const AuraApp());

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
        routes: {
          '/': (_) => const WelcomeScreen(),
          '/sign-in': (_) => const SignInScreen(),
          '/register': (_) => const RegisterScreen(),
          '/home': (_) => const HomeScreen(),
        },
      ),
    );
  }
}
