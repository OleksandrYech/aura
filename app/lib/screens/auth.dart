import 'dart:ui';

import 'package:flutter/material.dart';

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

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _nick = TextEditingController();
  final _pwd = TextEditingController();
  bool _remember = true;
  String? _error;

  void _submit() {
    if (_nick.text.trim().isEmpty || _pwd.text.isEmpty) {
      setState(() => _error = 'Введите никнейм и пароль');
      return;
    }
    // ponytail: без сервера любой вход успешен, настоящая проверка на этапе 2.
    Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return _AuthForm(
      title: 'Вход в AURA',
      subtitle: 'Введите никнейм и пароль.',
      error: _error,
      fields: [
        _field('Никнейм', _nick, 'aura_user', _clearError),
        _field('Пароль', _pwd, '••••••••', _clearError, obscure: true),
        CheckboxListTile(
          value: _remember,
          onChanged: (v) => setState(() => _remember = v!),
          title: const Text('Запомнить меня', style: TextStyle(fontSize: 14)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
        ),
      ],
      switchLabel: 'Нет аккаунта? Создать',
      switchRoute: '/register',
      buttonLabel: 'Войти',
      onSubmit: _submit,
    );
  }

  void _clearError(String _) => setState(() => _error = null);
}

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nick = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  String? _error;

  void _submit() {
    final error = _nick.text.trim().length < 3
        ? 'Никнейм должен быть не короче 3 символов'
        : _pwd.text.length < 6
            ? 'Пароль должен быть не короче 6 символов'
            : _pwd.text != _pwd2.text
                ? 'Пароли не совпадают'
                : null;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    void clearError(String _) => setState(() => _error = null);
    return _AuthForm(
      title: 'Создать аккаунт',
      subtitle: 'Придумайте никнейм и пароль — без номера телефона и почты.',
      error: _error,
      fields: [
        _field('Никнейм', _nick, 'aura_user', clearError),
        _field('Пароль', _pwd, 'Минимум 6 символов', clearError, obscure: true),
        _field('Повторите пароль', _pwd2, '••••••••', clearError, obscure: true),
      ],
      switchLabel: 'Уже есть аккаунт? Войти',
      switchRoute: '/sign-in',
      buttonLabel: 'Зарегистрироваться',
      onSubmit: _submit,
    );
  }
}

Widget _field(String label, TextEditingController c, String hint, ValueChanged<String> onChanged, {bool obscure = false}) =>
    TextField(
      controller: c,
      obscureText: obscure,
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.title,
    required this.subtitle,
    required this.error,
    required this.fields,
    required this.switchLabel,
    required this.switchRoute,
    required this.buttonLabel,
    required this.onSubmit,
  });

  final String title, subtitle, switchLabel, switchRoute, buttonLabel;
  final String? error;
  final List<Widget> fields;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 8, 28, 32),
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(subtitle, style: TextStyle(fontSize: 14, color: c.ink.withValues(alpha: 0.6))),
                const SizedBox(height: 20),
                for (final f in fields) ...[f, const SizedBox(height: 14)],
                if (error != null) Text('⚠ $error', style: TextStyle(fontSize: 13, color: c.ink)),
                TextButton(
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft, padding: EdgeInsets.zero),
                  onPressed: () => Navigator.pushReplacementNamed(context, switchRoute),
                  child: Text(switchLabel, style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: onSubmit, child: Text(buttonLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
