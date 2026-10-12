import 'package:flutter/material.dart';

import '../mock_data.dart';
import '../theme.dart';
import 'settings.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _tab, children: const [ChatsTab(), ContactsTab(), SettingsTab()]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
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
  const Avatar(this.initials, {super.key, this.size = 48, this.color});
  final String initials;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color ?? c.lavender,
      child: Text(initials,
          style: TextStyle(fontFamily: 'Comfortaa', fontWeight: FontWeight.w700, fontSize: size / 3, color: c.ink)),
    );
  }
}

Color avatarColor(AuraColors c, int i) => [c.lavender, c.thistle, c.grayPurple, c.warmSand][i % 4];

class ChatsTab extends StatelessWidget {
  const ChatsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          child: Row(children: [
            Expanded(child: Text('Чаты', style: Theme.of(context).textTheme.headlineSmall)),
            IconButton(
              tooltip: 'Новый чат',
              style: IconButton.styleFrom(backgroundColor: c.lavender),
              icon: Icon(Icons.add, color: c.ink),
              onPressed: () {},
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Поиск',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(radiusMd))),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(radiusMd))),
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: chats.length,
            itemBuilder: (context, i) {
              final chat = chats[i];
              return ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: Avatar(chat.initials, color: avatarColor(c, i)),
                title: Row(children: [
                  Expanded(child: Text(chat.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500))),
                  Text(chat.time, style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.5))),
                ]),
                subtitle: Text(chat.preview,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.6))),
                trailing: chat.unread ? CircleAvatar(radius: 4.5, backgroundColor: c.grayPurple) : null,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: chat, color: avatarColor(c, i)))),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ContactsTab extends StatelessWidget {
  const ContactsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final people = chats.where((ch) => !ch.group).toList();
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
          child: Text('Контакты', style: Theme.of(context).textTheme.headlineSmall),
        ),
        for (final (i, p) in people.indexed)
          ListTile(
            leading: Avatar(p.initials, size: 40, color: avatarColor(c, i)),
            title: Text(p.name),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(chat: p, color: avatarColor(c, i)))),
          ),
      ],
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chat, required this.color});
  final Chat chat;
  final Color color;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messages = sampleMessages();
  final _draft = TextEditingController();

  void _send() {
    final text = _draft.text.trim();
    if (text.isEmpty) return;
    final now = TimeOfDay.now();
    setState(() => _messages.add(Message(text, '${now.hour}:${now.minute.toString().padLeft(2, '0')}', mine: true)));
    _draft.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: c.cream,
        titleSpacing: 0,
        shape: Border(bottom: BorderSide(color: c.lightGray)),
        title: Row(children: [
          Avatar(widget.chat.initials, size: 40, color: widget.color),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.chat.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            Text('в сети', style: TextStyle(fontSize: 12, color: c.ink.withValues(alpha: 0.55))),
          ]),
        ]),
        actions: const [Padding(padding: EdgeInsets.only(right: 16), child: Icon(Icons.lock_outline, size: 18))],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView.separated(
              reverse: true, // новые сообщения снизу и всегда в поле зрения
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final m = _messages[_messages.length - 1 - i];
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
                      Align(alignment: Alignment.centerLeft, child: Text(m.text, style: const TextStyle(fontSize: 15, height: 1.5))),
                      const SizedBox(height: 4),
                      Text(m.time, style: TextStyle(fontSize: 11, color: c.ink.withValues(alpha: 0.55))),
                    ]),
                  ),
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
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Сообщение…',
                    border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(999))),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(999))),
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
