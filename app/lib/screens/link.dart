import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../client.dart';
import '../theme.dart';

/// Новое устройство аккаунта с ключом: QR и текстовый код для старого устройства.
class LinkScreen extends StatefulWidget {
  const LinkScreen({super.key});

  @override
  State<LinkScreen> createState() => _LinkScreenState();
}

class _LinkScreenState extends State<LinkScreen> {
  late String _code = client.startLinking();

  /// «Начать заново»: новый ключ аккаунта, остальные устройства выходят.
  Future<void> _reset() async {
    final password = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Начать заново?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Аккаунт получит новый ключ. Все остальные ваши устройства выйдут, переписка на них не перенесётся, '
                'а у собеседников изменится код безопасности. Делайте так, только если старых устройств больше нет.',
              ),
              TextField(
                controller: password,
                obscureText: true,
                decoration: InputDecoration(labelText: 'Пароль', errorText: error),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
            TextButton(
              onPressed: () async {
                try {
                  await client.resetAccount(password.text);
                  if (context.mounted) Navigator.pop(context);
                } on ApiException catch (e) {
                  setState(() => error = e.message);
                }
              },
              child: const Text('Начать заново'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final muted = TextStyle(fontSize: 14, color: c.ink.withValues(alpha: 0.6));
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListenableBuilder(
              listenable: client,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 32),
                children: [
                  Text('Привязка устройства', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'На устройстве, где вы уже вошли, откройте Настройки → Устройства → Привязать и отсканируйте код.',
                    style: muted,
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                      child: QrImageView(data: _code, size: 220),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Нет камеры? Скопируйте код и вставьте его там.', style: muted, textAlign: TextAlign.center),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Скопировать код'),
                    onPressed: () => Clipboard.setData(ClipboardData(text: _code)),
                  ),
                  const SizedBox(height: 16),
                  if (client.linkError case final error?) ...[
                    Text('⚠ $error', style: TextStyle(fontSize: 13, color: c.ink)),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => setState(() => _code = client.startLinking()),
                      child: const Text('Новый код'),
                    ),
                  ] else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 12),
                        Flexible(child: Text('Ожидаем другое устройство…', style: muted)),
                      ],
                    ),
                  const SizedBox(height: 24),
                  TextButton(onPressed: _reset, child: const Text('Старых устройств нет: начать заново')),
                  TextButton(onPressed: client.logout, child: const Text('Отмена')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Настройки → Устройства: устройства своего аккаунта, привязка новых и отвязка.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late Future<List<Map<String, dynamic>>> _devices = client.myDevices();

  void _say(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _ask(String title, String text, String yes) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(yes)),
          ],
        ),
      ) ??
      false;

  Future<void> _link() async {
    final how = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Сканировать QR'),
              onTap: () => Navigator.pop(context, true),
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Вставить код'),
              onTap: () => Navigator.pop(context, false),
            ),
          ],
        ),
      ),
    );
    if (how == null || !mounted) return;
    final code = how
        ? await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _ScanScreen()))
        : await _paste();
    if (code == null || !mounted) return;
    try {
      var sent = false;
      await client.linkDevice(code, (name, device) async {
        final label = name.isEmpty ? 'Устройство №$device' : '$name, устройство №$device';
        return sent = await _ask(
          'Привязать устройство?',
          '$label получит ключ вашего аккаунта и будет получать новые сообщения. '
              'Привязывайте только своё устройство, которое сейчас перед вами.',
          'Привязать',
        );
      });
      if (sent && mounted) _say('Ключ отправлен. Новое устройство войдёт через несколько секунд.');
    } on ApiException catch (e) {
      if (mounted) _say(e.message);
    }
    if (mounted) setState(() => _devices = client.myDevices());
  }

  Future<String?> _paste() {
    final text = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Код привязки'),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Код с экрана нового устройства'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Далее')),
        ],
      ),
    );
  }

  static String _title(Map<String, dynamic> d) => d['name'] as String? ?? 'Устройство №${d['device']}';

  /// Где и когда устройство вошло: место примерное, по IP в момент входа.
  static String _details(Map<String, dynamic> d) {
    final at = d['createdAt'] is int ? DateTime.fromMillisecondsSinceEpoch(d['createdAt'] as int) : null;
    String two(int n) => n.toString().padLeft(2, '0');
    return [
      if (d['device'] == client.device) 'Это устройство',
      if (d['place'] case final String place) place,
      if (at != null) 'вход ${two(at.day)}.${two(at.month)}.${at.year}, ${at.hour}:${two(at.minute)}',
    ].join(' · ');
  }

  Future<void> _unlink(Map<String, dynamic> device) async {
    final d = device['device'] as int;
    if (!await _ask('Отвязать «${_title(device)}»?', 'Оно выйдет из аккаунта и перестанет получать сообщения.', 'Отвязать')) {
      return;
    }
    try {
      await client.unlinkDevice(d);
    } on ApiException catch (e) {
      if (mounted) _say(e.message);
    }
    if (mounted) setState(() => _devices = client.myDevices());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(backgroundColor: Colors.transparent, title: Text('Устройства', style: Theme.of(context).textTheme.titleMedium)),
    body: FutureBuilder(
      future: _devices,
      builder: (context, snap) => ListView(
        children: [
          if (snap.hasError) ListTile(title: Text('⚠ ${snap.error}')),
          for (final d in snap.data ?? const <Map<String, dynamic>>[])
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(_title(d)),
              subtitle: _details(d).isEmpty ? null : Text(_details(d)),
              trailing: d['device'] == client.device ? null : TextButton(onPressed: () => _unlink(d), child: const Text('Отвязать')),
            ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: FilledButton(onPressed: _link, child: const Text('Привязать устройство')),
          ),
        ],
      ),
    ),
  );
}

class _ScanScreen extends StatefulWidget {
  const _ScanScreen();

  @override
  State<_ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<_ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Код привязки')),
    body: MobileScanner(
      onDetect: (capture) {
        final code = capture.barcodes.firstOrNull?.rawValue;
        if (code == null || _done) return;
        _done = true;
        Navigator.pop(context, code);
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Камера недоступна. Вернитесь и вставьте код вручную.', textAlign: TextAlign.center),
        ),
      ),
    ),
  );
}
