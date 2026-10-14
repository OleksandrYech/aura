import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../client.dart';
import '../theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget blob(double size, Color color, {double? top, double? left, double? right, double? bottom}) => Positioned(
          top: top,
          left: left,
          right: right,
          bottom: bottom,
          child: ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            child: Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          ),
        );

    return Scaffold(
      body: Stack(
        children: [
          blob(320, dark ? c.lavender : c.warmSand, top: -100, left: -90),
          blob(280, dark ? c.grayPurple : c.lavender, top: 40, right: -110),
          blob(340, c.thistle, bottom: -140, left: -60),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: IconButton(
                  tooltip: 'Переключить тему',
                  style: IconButton.styleFrom(backgroundColor: c.beige),
                  icon: Icon(dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined, color: c.ink),
                  onPressed: () => themeMode.value = dark ? ThemeMode.light : ThemeMode.dark,
                ),
              ),
            ),
          ),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AuraLogo(),
                    const SizedBox(height: 24),
                    Text('aura',
                        style: TextStyle(fontFamily: 'Comfortaa', fontWeight: FontWeight.w700, fontSize: 32, letterSpacing: 1, color: c.ink)),
                    const SizedBox(height: 8),
                    Text('Your messages. Your world.', style: TextStyle(fontSize: 15, color: c.ink.withValues(alpha: 0.7))),
                    const SizedBox(height: 48),
                    FilledButton(onPressed: () => Navigator.pushNamed(context, '/sign-in'), child: const Text('Войти')),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: dark ? c.warmSand : c.beige),
                      onPressed: () => Navigator.pushNamed(context, '/register'),
                      child: const Text('Создать аккаунт'),
                    ),
                    const SizedBox(height: 16),
                    Text('Сообщения защищены сквозным шифрованием',
                        style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Знак AURA: «защищённая сфера» из двух пересекающихся кругов.
class AuraLogo extends StatelessWidget {
  const AuraLogo({super.key, this.size = 96});
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final s = size * 0.625 / 120; // знак 60px в плитке 96px, viewBox 120
    Widget dot(double cx, double cy, double r, Color color) => Positioned(
          left: (cx - r) * s,
          top: (cy - r) * s,
          child: Container(width: 2 * r * s, height: 2 * r * s, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        );
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark ? c.beige : c.lavender,
        borderRadius: BorderRadius.circular(size * 0.27),
      ),
      child: SizedBox.square(
        dimension: 120 * s,
        child: Stack(children: [
          dot(50, 46, 30, AuraColors.light.lavender),
          dot(68, 66, 23, AuraColors.light.thistle),
          dot(58, 56, 8, AuraColors.light.grayPurple),
          dot(40, 37, 6, AuraColors.light.cream.withValues(alpha: 0.6)),
        ]),
      ),
    );
  }
}

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});

  @override
  Widget build(BuildContext context) => const _AuthScreen(register: false);
}

class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});

  @override
  Widget build(BuildContext context) => const _AuthScreen(register: true);
}

class _AuthScreen extends StatefulWidget {
  const _AuthScreen({required this.register});
  final bool register;

  @override
  State<_AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<_AuthScreen> {
  final _server = TextEditingController(text: client.server ?? AuraClient.defaultServer);
  final _nick = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  String? _error;
  bool _loading = false;

  Future<void> _submit() async {
    final nick = _nick.text.trim();
    final error = _server.text.trim().isEmpty
        ? 'Укажите адрес сервера'
        : !widget.register
            ? (nick.isEmpty || _pwd.text.isEmpty ? 'Введите никнейм и пароль' : null)
            : nick.length < 3
                ? 'Никнейм должен быть не короче 3 символов'
                : _pwd.text.length < 6
                    ? 'Пароль должен быть не короче 6 символов'
                    : _pwd.text != _pwd2.text
                        ? 'Пароли не совпадают'
                        : null;
    setState(() => _error = error);
    if (error != null) return;

    setState(() => _loading = true);
    try {
      await (widget.register ? client.register : client.login)(_server.text, nick, _pwd.text);
      // Корневой экран сам переключится на чаты.
      if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    Widget field(String label, TextEditingController ctrl, String hint, {bool obscure = false}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            controller: ctrl,
            obscureText: obscure,
            autocorrect: false,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
        );
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
              children: [
                Text(widget.register ? 'Создать аккаунт' : 'Вход в AURA', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(
                  widget.register ? 'Придумайте никнейм и пароль — без номера телефона и почты.' : 'Введите никнейм и пароль.',
                  style: TextStyle(fontSize: 14, color: c.ink.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 20),
                // В Web адрес подставляется сам: приложение открыто с этого сервера.
                if (!kIsWeb) field('Сервер', _server, 'https://aura.example.com'),
                field('Никнейм', _nick, 'aura_user'),
                field('Пароль', _pwd, widget.register ? 'Минимум 6 символов' : '••••••••', obscure: true),
                if (widget.register) field('Повторите пароль', _pwd2, '••••••••', obscure: true),
                if (_error != null) Text('⚠ $_error', style: TextStyle(fontSize: 13, color: c.ink)),
                TextButton(
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
                  onPressed: () => Navigator.pushReplacementNamed(context, widget.register ? '/sign-in' : '/register'),
                  child: Text(
                    widget.register ? 'Уже есть аккаунт? Войти' : 'Нет аккаунта? Создать',
                    style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6)),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _loading ? null : _submit,
                  child: Text(_loading
                      ? (widget.register ? 'Создание…' : 'Вход…')
                      : (widget.register ? 'Зарегистрироваться' : 'Войти')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
