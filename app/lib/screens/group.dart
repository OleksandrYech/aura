import 'dart:async';

import 'package:flutter/material.dart';

import '../client.dart';
import '../theme.dart';
import 'home.dart';

/// Выбор людей: собеседники из переписки и найденные по точному никнейму.
class PeoplePicker extends StatefulWidget {
  const PeoplePicker({super.key, required this.title, required this.action, this.exclude = const {}, this.withName = false});
  final String title, action;
  final Set<String> exclude;

  /// Для новой группы: поле названия над списком.
  final bool withName;

  @override
  State<PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<PeoplePicker> {
  final _name = TextEditingController();
  final _picked = <String>{};
  final _found = <String>[];
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) return;
    try {
      final users = await client.searchUsers(q.trim().toLowerCase());
      if (mounted) setState(() => _found.addAll(users.map((u) => u.nick).where((n) => !_found.contains(n))));
    } on ApiException catch (_) {}
  }

  bool get _ready => _picked.isNotEmpty && (!widget.withName || _name.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    final people = {
      ..._found,
      for (final chat in client.chats.keys)
        if (!AuraClient.isGroup(chat)) chat,
    }.where((n) => n != client.nick && !widget.exclude.contains(n)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _ready ? () => Navigator.pop(context, (name: _name.text.trim(), people: _picked.toList())) : null,
            child: Text(widget.action),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.withName) ...[
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 64,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Название группы'),
          ),
          const SizedBox(height: 8),
        ],
        TextField(
          onChanged: (q) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), () => _search(q));
          },
          decoration: const InputDecoration(hintText: 'Найти по точному никнейму', prefixIcon: Icon(Icons.search)),
        ),
        const SizedBox(height: 8),
        if (people.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('Найдите человека по никнейму.', style: TextStyle(color: c.ink.withValues(alpha: 0.6))),
          ),
        for (final n in people)
          CheckboxListTile(
            value: _picked.contains(n),
            onChanged: (v) => setState(() => v! ? _picked.add(n) : _picked.remove(n)),
            secondary: Avatar(client.nameOf(n), nick: n, size: 40),
            title: Text(client.nameOf(n)),
            subtitle: Text('@$n', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
          ),
      ]),
    );
  }
}

Future<({String name, List<String> people})?> pickPeople(
  BuildContext context, {
  required String title,
  required String action,
  Set<String> exclude = const {},
  bool withName = false,
}) => Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => PeoplePicker(title: title, action: action, exclude: exclude, withName: withName)),
);

Future<void> newGroup(BuildContext context) async {
  final r = await pickPeople(context, title: 'Новая группа', action: 'Создать', withName: true);
  if (r == null || !context.mounted) return;
  openChat(context, client.createGroup(r.name, r.people));
}

/// Участники группы. Админ меняет название, добавляет и исключает участников, назначает админов.
class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.chat});
  final String chat;

  Future<void> _rename(BuildContext context) async {
    final field = TextEditingController(text: client.title(chat));
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Название группы'),
        content: TextField(controller: field, autofocus: true, maxLength: 64),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: const Text('Сохранить')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && name != client.title(chat)) client.renameGroup(chat, name);
  }

  Future<void> _member(BuildContext context, String who) async {
    final admin = client.admins(chat).contains(who);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(admin ? Icons.remove_moderator_outlined : Icons.add_moderator_outlined),
            title: Text(admin ? 'Снять админа' : 'Сделать админом'),
            onTap: () => Navigator.pop(context, 'admin'),
          ),
          ListTile(
            leading: const Icon(Icons.person_remove_outlined),
            title: const Text('Исключить из группы'),
            onTap: () => Navigator.pop(context, 'remove'),
          ),
        ]),
      ),
    );
    switch (choice) {
      case 'admin':
        client.setAdmin(chat, who, !admin);
      case 'remove':
        client.removeMember(chat, who);
    }
  }

  Future<void> _leave(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из группы?'),
        content: const Text('Новые сообщения группы перестанут приходить. Переписка останется на устройстве.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Выйти')),
        ],
      ),
    );
    if (ok == true) client.leaveGroup(chat);
  }

  @override
  Widget build(BuildContext context) {
    final c = AuraColors.of(context);
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        final members = client.members(chat), admins = client.admins(chat);
        final member = members.contains(client.nick), admin = admins.contains(client.nick);
        return Scaffold(
          appBar: AppBar(title: Text(client.title(chat))),
          body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
            if (admin)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Изменить название'),
                onTap: () => _rename(context),
              ),
            if (admin)
              ListTile(
                leading: const Icon(Icons.person_add_alt_outlined),
                title: const Text('Добавить участников'),
                onTap: () async {
                  final r = await pickPeople(context, title: 'Добавить в группу', action: 'Добавить', exclude: members.toSet());
                  if (r != null) client.addMembers(chat, r.people);
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Участники: ${members.length}', style: TextStyle(color: c.ink.withValues(alpha: 0.6))),
            ),
            for (final m in members)
              ListTile(
                leading: Avatar(client.nameOf(m), nick: m, size: 40),
                title: Text(client.nameOf(m)),
                subtitle: Text('@$m', style: TextStyle(fontSize: 13, color: c.ink.withValues(alpha: 0.55))),
                trailing: admins.contains(m) ? Text('админ', style: TextStyle(fontSize: 12, color: c.grayPurple)) : null,
                onTap: admin && m != client.nick ? () => _member(context, m) : null,
              ),
            if (member)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Выйти из группы'),
                onTap: () => _leave(context),
              ),
          ]),
        );
      },
    );
  }
}
