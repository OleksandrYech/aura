import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../theme.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  int _contactsOpened = 0; // новый ключ при каждом открытии вкладки обновляет список

  void _select(int tab) => setState(() {
        if (tab == 1) _contactsOpened++;
        _tab = tab;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [ChatsTab(onNewChat: () => _select(1)), ContactsTab(key: ValueKey(_contactsOpened)), const SettingsTab()],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Чаты'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Контакты'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Настройки'),
        ],
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 48});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0]).join().toUpperCase();
    // Цвет зависит от имени, чтобы у собеседника он не менялся.
    final colors = [c.lavender, c.thistle, c.grayPurple, c.warmSand];
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: colors[name.hashCode.abs() % colors.length],
      child: Text(initials,
          style: TextStyle(fontFamily: 'Comfortaa', fontWeight: FontWeight.w700, fontSize: size / 3, color: c.ink)),
    );
  }
}

String formatTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (t.year == yesterday.year && t.month == yesterday.month && t.day == yesterday.day) return 'вчера';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
}

void openChat(BuildContext context, String peer) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(peer: peer)));

class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key, required this.onNewChat});
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final peers = client.chats.keys.where((p) => client.chats[p]!.isNotEmpty).toList()
          ..sort((a, b) => client.chats[b]!.last.time.compareTo(client.chats[a]!.last.time));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              child: Row(children: [
                Expanded(child: Text('Чаты', style: Theme.of(context).textTheme.headlineSmall)),
                if (!client.connected)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text('подключение…', style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
                  ),
                IconButton(
                  tooltip: 'Новый чат',
                  style: IconButton.styleFrom(backgroundColor: c.lavender),
                  icon: Icon(Icons.add, color: c.ink),
                  onPressed: onNewChat,
                ),
              ]),
            ),
            Expanded(
              child: peers.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('Пока нет чатов. Нажмите +, чтобы найти собеседника.',
                            textAlign: TextAlign.center, style: TextStyle(color: c.ink.withValues(alpha: 0.6))),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: peers.length,
                      itemBuilder: (context, i) {
                        final peer = peers[i];
                        final last = client.chats[peer]!.last;
                        final name = client.names[peer] ?? peer;
                        return ListTile(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          leading: Avatar(name),
                          title: Row(children: [
                            Expanded(child: Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                            Text(formatTime(last.time), style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
                          ]),
                          subtitle: Text('${last.mine ? 'Вы: ' : ''}${last.text}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                          trailing: client.hasUnread(peer) ? CircleAvatar(radius: 4.5, backgroundColor: c.grayPurple) : null,
                          onTap: () => openChat(context, peer),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class ContactsTab extends StatefulWidget {
  const ContactsTab({super.key});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  List<({String nick, String name})> _users = [];
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String q) async {
    try {
      final users = await client.searchUsers(q);
      if (mounted) {
        setState(() {
          _users = users;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Text('Контакты', style: Theme.of(context).textTheme.headlineSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            onChanged: (q) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
            },
            decoration: const InputDecoration(hintText: 'Поиск по никнейму или имени', prefixIcon: Icon(Icons.search)),
          ),
        ),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(20), child: Text('⚠ $_error', style: TextStyle(color: c.ink))),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _search(''),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final u in _users)
                  ListTile(
                    leading: Avatar(u.name, size: 40),
                    title: Text(u.name),
                    subtitle: Text('@${u.nick}', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
                    onTap: () => openChat(context, u.nick),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.peer});
  final String peer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _draft = TextEditingController();

  @override
  void initState() {
    super.initState();
    client.addListener(_markRead);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
  }

  @override
  void dispose() {
    client.removeListener(_markRead);
    super.dispose();
  }

  void _markRead() {
    if (client.hasUnread(widget.peer)) client.markRead(widget.peer);
  }

  void _send() {
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    client.send(widget.peer, text);
    _draft.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final name = client.names[widget.peer] ?? widget.peer;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.cream,
        titleSpacing: 0,
        shape: Border(bottom: BorderSide(color: c.lightGray)),
        title: Row(children: [
          Avatar(name, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              Text('@${widget.peer}', style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.55))),
            ]),
          ),
        ]),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListenableBuilder(
              listenable: client,
              builder: (context, _) {
                final messages = client.chats[widget.peer] ?? const [];
                return ListView.separated(
                  reverse: true, // новые сообщения снизу и всегда в поле зрения
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) {
                    final m = messages[messages.length - 1 - i];
                    return Align(
                      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: m.mine ? c.lavender : c.thistle,
                          borderRadius: BorderRadius.circular(radiusLg),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: SelectableText(m.text, style: const TextStyle(fontSize: 15, height: 1.5)),
                          ),
                          const SizedBox(height: 4),
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(formatTime(m.time), style: TextStyle(fontSize: 11, color: c.ink.withValues(alpha: 0.55))),
                            if (m.mine) ...[
                              const SizedBox(width: 4),
                              Icon(m.pending ? Icons.schedule : Icons.done,
                                  size: 12,
                                  color: c.ink.withValues(alpha: 0.55),
                                  semanticLabel: m.pending ? 'не отправлено' : 'отправлено'),
                            ],
                          ]),
                        ]),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _draft,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Сообщение…',
                    border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))),
                    enabledBorder:
                        OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(24))),
                    contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Отправить',
                style: IconButton.styleFrom(backgroundColor: c.lavender, fixedSize: const Size.square(44)),
                icon: Icon(Icons.send_outlined, color: c.ink, size: 18),
                onPressed: _send,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
