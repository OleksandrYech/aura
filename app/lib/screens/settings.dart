import 'package:flutter/material.dart';

import '../client.dart';
import '../lock.dart';
import '../theme.dart';
import 'home.dart';

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
        ListenableBuilder(
          listenable: client,
          builder: (context, _) => ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            leading: Avatar(client.name ?? '', size: 56),
            title: Text(client.name ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            subtitle: Text('@${client.nick} · Изменить профиль', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
          ),
        ),
        section('ПРИВАТНОСТЬ И БЕЗОПАСНОСТЬ'),
        FutureBuilder(
          future: AppLock.available(),
          builder: (context, snap) => snap.data != true
              ? const SizedBox.shrink()
              : ValueListenableBuilder(
                  valueListenable: AppLock.enabled,
                  builder: (context, on, _) => SwitchListTile(
                    secondary: const Icon(Icons.fingerprint),
                    title: const Text('Блокировка по биометрии'),
                    subtitle: const Text('Отпечаток, лицо или PIN-код телефона при входе в приложение'),
                    value: on,
                    onChanged: AppLock.setEnabled,
                  ),
                ),
        ),
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
            onPressed: client.logout,
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
  final _name = TextEditingController(text: client.name);
  String? _error;
  bool _saved = false, _saving = false;

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _error = name.isEmpty ? 'Введите имя' : null;
      _saved = false;
    });
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await client.updateName(name);
      if (mounted) setState(() => _saved = true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, title: Text('Профиль', style: Theme.of(context).textTheme.titleMedium)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              children: [
                Center(child: Avatar(_name.text, size: 96)),
                const SizedBox(height: 28),
                TextField(
                  controller: _name,
                  onChanged: (_) => setState(() => _saved = false),
                  decoration: InputDecoration(labelText: 'Имя', hintText: 'Ваше имя', errorText: _error),
                ),
                const SizedBox(height: 22),
                TextField(
                  enabled: false,
                  controller: TextEditingController(text: '@${client.nick}'),
                  decoration: const InputDecoration(labelText: 'Никнейм'),
                ),
                const SizedBox(height: 32),
                if (_saved)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text('Изменения сохранены',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                  ),
                FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Сохранение…' : 'Сохранить')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
