import 'package:flutter/material.dart';

import '../theme.dart';
import 'home.dart';

// ponytail: профиль живёт в памяти до появления сервера (этап 2).
final profileName = ValueNotifier('Анна');
const nickname = '@aura_user';

class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  bool _screenshots = true, _push = true;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(title, style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
        );
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text('Настройки', style: Theme.of(context).textTheme.headlineSmall),
        ),
        ValueListenableBuilder(
          valueListenable: profileName,
          builder: (context, name, _) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: Avatar(name.isEmpty ? 'A' : name[0].toUpperCase(), size: 56),
            title: Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            subtitle: Text('$nickname · Изменить профиль', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ),
        section('ПРИВАТНОСТЬ И БЕЗОПАСНОСТЬ'),
        // Код безопасности, биометрия и E2E появятся на этапе 3.
        SwitchListTile(
          secondary: const Icon(Icons.screenshot_outlined),
          title: const Text('Уведомления о скриншотах'),
          value: _screenshots,
          onChanged: (v) => setState(() => _screenshots = v),
        ),
        section('ВНЕШНИЙ ВИД'),
        ValueListenableBuilder(
          valueListenable: themeMode,
          builder: (context, mode, _) => SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('Тёмная тема'),
            value: mode == ThemeMode.dark,
            onChanged: (v) => themeMode.value = v ? ThemeMode.dark : ThemeMode.light,
          ),
        ),
        section('УВЕДОМЛЕНИЯ'),
        SwitchListTile(
          secondary: const Icon(Icons.notifications_none),
          title: const Text('Push-уведомления'),
          value: _push,
          onChanged: (v) => setState(() => _push = v),
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.beige),
            onPressed: () => Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false),
            child: const Text('Выйти'),
          ),
        ),
      ],
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _name = TextEditingController(text: profileName.value);
  String? _error;
  bool _saved = false;

  void _save() {
    final name = _name.text.trim();
    setState(() {
      _error = name.isEmpty ? 'Введите имя' : null;
      _saved = name.isNotEmpty;
    });
    if (name.isNotEmpty) profileName.value = name;
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final initial = _name.text.trim().isEmpty ? 'A' : _name.text.trim()[0].toUpperCase();
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text('Профиль', style: Theme.of(context).textTheme.titleMedium)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              children: [
                Center(child: Avatar(initial, size: 96)),
                const SizedBox(height: 28),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() => _saved = false),
                  decoration: InputDecoration(labelText: 'Имя', hintText: 'Ваше имя', errorText: _error),
                ),
                const SizedBox(height: 22),
                TextField(
                  enabled: false,
                  controller: TextEditingController(text: nickname),
                  decoration: const InputDecoration(labelText: 'Никнейм'),
                ),
                const SizedBox(height: 32),
                if (_saved)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('Изменения сохранены',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                  ),
                FilledButton(onPressed: _save, child: const Text('Сохранить')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
