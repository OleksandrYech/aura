import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/auth.dart';
import 'theme.dart';

/// Блокировка приложения биометрией (отпечаток, лицо) или PIN-кодом устройства.
class AppLock {
  static final _auth = LocalAuthentication();

  /// Включена ли блокировка (настройка этого устройства).
  static final enabled = ValueNotifier(false);

  static Future<void> load() async => enabled.value = (await SharedPreferences.getInstance()).getBool('lock') ?? false;

  /// В браузере блокировки нет; на телефоне нужна настроенная блокировка экрана.
  static Future<bool> available() async => !kIsWeb && await _auth.isDeviceSupported();

  static Future<bool> unlock() async {
    try {
      return await _auth.authenticate(localizedReason: 'Разблокируйте AURA', persistAcrossBackgrounding: true);
    } catch (e) {
      debugPrint('AURA: биометрия: $e'); // нет датчика, блокировка по попыткам и т.п.
      return false;
    }
  }

  /// Включение требует подтверждения, чтобы не запереть себя на устройстве без биометрии.
  static Future<bool> setEnabled(bool value) async {
    if (value && !await unlock()) return false;
    enabled.value = value;
    await (await SharedPreferences.getInstance()).setBool('lock', value);
    return true;
  }
}

/// Закрывает приложение экраном блокировки при запуске и после ухода в фон.
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late bool _locked = AppLock.enabled.value;
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Только уход в фон: системный диалог биометрии делает приложение лишь inactive.
    if (state == AppLifecycleState.hidden && AppLock.enabled.value && !_unlocking) {
      setState(() => _locked = true);
    } else if (state == AppLifecycleState.resumed && _locked) {
      _unlock();
    }
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    _unlocking = true;
    final ok = await AppLock.unlock();
    _unlocking = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Stack(
      children: [
        // Содержимое остаётся живым (открытый чат не теряется), но не рисуется под замком.
        Offstage(offstage: _locked, child: widget.child),
        if (_locked)
          Positioned.fill(
            child: Material(
              color: c.cream,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const AuraLogo(),
                    const SizedBox(height: 24),
                    Text('AURA заблокирована', style: TextStyle(fontSize: 17, color: c.ink)),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _unlock,
                      icon: const Icon(Icons.fingerprint),
                      label: const Text('Разблокировать'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
