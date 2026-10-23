import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart'
    show Curve, DuplicateMessageException, ECKeyPair, ECPublicKey, UntrustedIdentityException;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'link.dart';
import 'media.dart';
import 'platform_media.dart';
import 'signal.dart';

/// Статус сообщения. Свои: в очереди → отправлено → доставлено → прочитано.
/// Входящие: получено → прочитано (собеседнику ушло подтверждение о прочтении).
/// failed — сервер отклонил сообщение, оно уходит заново только по нажатию. Стоит последним:
/// статусы хранятся по имени, а квитанции сравнивают номер, и failed от них не меняется.
enum Status { pending, sent, delivered, read, failed }

class Message {
  Message({
    required this.id,
    required this.mine,
    required this.text,
    required this.time,
    required this.status,
    this.file,
    this.files,
    this.from,
    this.update,
  });

  final String id, text;

  /// Автор входящего сообщения в группе.
  final String? from;

  /// Изменение группы (создание, состав, админы, название). Такое сообщение показывается строкой по центру.
  final Map<String, dynamic>? update;
  final bool mine;
  final int time; // мс с эпохи
  Status status;

  /// Вложение: {id, key, name, size} — id файла на сервере и ключ, которым он зашифрован.
  final Map<String, dynamic>? file;

  /// Альбом: несколько фото и видео одним сообщением, каждое в том же виде, что [file].
  final List<Map<String, dynamic>>? files;

  /// Все вложения сообщения.
  List<Map<String, dynamic>> get attachments => [?file, ...?files];

  /// То, что уходит собеседнику внутри зашифрованного сообщения.
  Map<String, dynamic> get content => {'text': text, 'file': ?file, 'files': ?files, 'groupUpdate': ?update};

  /// Строка для списка чатов.
  String get preview => text.isNotEmpty
      ? text
      : files != null
      ? 'Альбом: ${files!.length}'
      : file == null
      ? ''
      : file!['voice'] == true
      ? 'Голосовое сообщение'
      : file!['video'] == true
      ? 'Видео'
      : isImage(file!['name'])
      ? 'Фото'
      : '📎 ${file!['name']}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'mine': mine,
    'text': text,
    'time': time,
    'status': status.name,
    'file': ?file,
    'files': ?files,
    'from': ?from,
    'update': ?update,
  };
  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: j['id'],
    mine: j['mine'],
    text: j['text'],
    time: j['time'],
    file: j['file'],
    files: (j['files'] as List?)?.cast(),
    from: j['from'],
    update: j['update'],
    // До статусов было поле pending.
    status: j['status'] != null
        ? Status.values.byName(j['status'])
        : j['pending'] == true
        ? Status.pending
        : (j['mine'] ? Status.sent : Status.read),
  );
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Связь с сервером AURA и локальная история переписки.
/// Сообщения шифруются Signal Protocol отдельно для каждого устройства собеседника и для своих
/// других устройств. Сервер хранит шифротекст только до доставки, история живёт на устройстве.
// ponytail: история в SharedPreferences (JSON на собеседника), перейти на базу на устройстве, когда чаты станут длинными.
class AuraClient extends ChangeNotifier {
  AuraClient._();
  static final instance = AuraClient._();

  late SharedPreferences _prefs;
  String? token, nick, name;

  /// Переписка по никнейму собеседника.
  final chats = <String, List<Message>>{};

  /// Отображаемые имена собеседников.
  final names = <String, String>{};

  /// Группы по ключу чата ('#' и id): {name, members, admins, v}. Состав знают только устройства участников:
  /// сообщение группы шифруется попарно для каждого участника, сервер видит обычные личные сообщения.
  /// Менять группу могут админы, участник может только выйти. v растёт с каждым изменением, старое не применяется.
  // ponytail: одновременные правки двух админов — побеждает пришедшая первой, вторая теряется; сливать, если начнёт мешать.
  final groups = <String, Map<String, dynamic>>{};

  static bool isGroup(String chat) => chat.startsWith('#');

  List<String> members(String chat) => [...?(groups[chat]?['members'] as List?)?.cast<String>()];
  List<String> admins(String chat) => [...?(groups[chat]?['admins'] as List?)?.cast<String>()];

  /// Название чата: группы или собеседника.
  String title(String chat) =>
      isGroup(chat) ? (groups[chat]?['name'] as String?) ?? 'Группа' : names[chat] ?? chat;

  String nameOf(String nick) => nick == this.nick ? 'Вы' : names[nick] ?? nick;

  /// Время последнего прочтения чата.
  final lastRead = <String, int>{};

  /// Удаления, которые ещё не дошли до сервера: {id, peer, ids, everyone, files, wait}.
  /// wait — кому уведомление ушло и ждёт подтверждения сервера: собеседнику и (или) себе.
  final _deletes = <Map<String, dynamic>>[];

  /// id недавно удалённых сообщений: повторная доставка (ответ ack не дошёл) не вернёт их в чат.
  // ponytail: последние 1000, держать дольше, если удалённое начнёт возвращаться.
  final _gone = <String>{};

  /// Ключи этого устройства; есть, пока выполнен вход.
  SignalKeys? _keys;

  /// Номер этого устройства на сервере.
  int? device;

  /// Известные устройства по никнейму; сбрасываются, когда сервер говорит, что список изменился.
  final _devices = <String, List<int>>{};

  /// Шифрование и расшифровка идут строго по очереди: сессии Signal нельзя менять параллельно.
  Future<void> _queue = Future.value();

  bool connected = false;
  WebSocketChannel? _ws;
  Timer? _retry;
  int _backoff = 1;

  bool get signedIn => token != null && _keys != null;

  /// Вход по паролю выполнен, но у аккаунта уже есть ключ: устройство ждёт привязки ([startLinking]).
  bool get needsLink => token != null && _keys == null;

  /// Ключ аккаунта, который сервер отдал при входе; конверт привязки обязан нести именно его.
  String? _accountKey;

  /// Почему привязка не удалась; null, пока всё идёт по плану.
  String? linkError;
  int _linkRun = 0;

  /// Адрес сервера: в Web это сайт, с которого открыто приложение, в мобильных — постоянный домен.
  static final server = kIsWeb ? Uri.base.origin : 'https://web.aura-msg.space';

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    token = _prefs.getString('token');
    nick = _prefs.getString('nick');
    name = _prefs.getString('name');
    device = _prefs.getInt('device');
    final keys = _prefs.getString('signal');
    if (keys != null) _keys = SignalKeys.fromJson(keys)..allowed.addAll([?nick]);
    final raw = _prefs.getString('chats');
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in (j['chats'] as Map<String, dynamic>).entries) {
        chats[key] = [for (final m in value as List) Message.fromJson(m)];
      }
      names.addAll((j['names'] as Map<String, dynamic>).cast());
      lastRead.addAll((j['lastRead'] as Map<String, dynamic>).cast());
      _deletes.addAll((j['deletes'] as List? ?? []).cast());
      _gone.addAll((j['gone'] as List? ?? []).cast());
      groups.addAll((j['groups'] as Map<String, dynamic>? ?? {}).cast());
    }
    if (signedIn) {
      _connect();
    } else if (token != null) {
      await logout(); // вход сделан до шифрования: нужно войти заново
    }
  }

  // --- Аккаунт ---

  Future<void> register(String nick, String password) =>
      _auth('/api/register', {'nick': nick, 'password': password});

  /// [link] — на аккаунт с ключом войти привязкой ([startLinking]), а не со своим новым ключом.
  // ponytail: false по умолчанию, пока нет экранов привязки (PR 5); с PR 6–7 привязка обязательна.
  Future<void> login(String nick, String password, {bool link = false}) =>
      _auth('/api/login', {'nick': nick, 'password': password}, link: link);

  Future<void> _auth(String path, Map body, {bool link = false}) async {
    final res = await _request('POST', _api(path), body);
    token = res['token'];
    nick = res['nick'];
    name = res['name'];
    device = res['device'];
    _accountKey = res['identityKey'];
    linkError = null;
    // Каждый вход — новое устройство. Ключ аккаунта создаёт только первое, остальные получают его привязкой.
    if (link && _accountKey != null) return notifyListeners();
    await _signIn(SignalKeys.generate());
  }

  /// Публикуем ключи устройства и только после этого считаем вход выполненным.
  Future<void> _signIn(SignalKeys keys) async {
    try {
      await _request('PUT', _api('/api/keys'), keys.publicBundle());
    } catch (_) {
      token = null;
      rethrow;
    }
    _keys = keys;
    keys.allowed.add(nick!); // свои новые устройства — входы на этом же аккаунте
    await _prefs.setString('token', token!);
    await _prefs.setString('nick', nick!);
    await _prefs.setString('name', name!);
    await _prefs.setInt('device', device!);
    await _saveKeys();
    notifyListeners();
    _connect();
  }

  /// Новое устройство: код для QR (временный публичный ключ, ник, номер устройства) и ожидание
  /// конверта от старого устройства в фоне. Удачная привязка завершается входом ([signedIn]),
  /// неудачная — [linkError]. Повторный вызов начинает заново с новым ключом.
  String startLinking() {
    final mine = Curve.generateKeyPair(), run = ++_linkRun;
    linkError = null;
    _awaitLink(mine, run);
    return base64Url.encode(
      utf8.encode(jsonEncode({'nick': nick, 'device': device, 'key': base64.encode(mine.publicKey.serialize())})),
    );
  }

  Future<void> _awaitLink(ECKeyPair mine, int run) async {
    bool current() => run == _linkRun && needsLink;
    while (current()) {
      final Map res;
      try {
        res = await _request('GET', _api('/api/link'), null);
      } on ApiException {
        // Конверта пока нет (сервер ждал 25 секунд) или нет связи.
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      if (!current()) return;
      try {
        final keys = SignalKeys.generate(LinkEnvelope.open('${res['envelope']}', mine, nick!, device!));
        if (keys.identityKey != _accountKey) throw const FormatException('ключ не аккаунта');
        return await _signIn(keys);
      } on FormatException {
        linkError = 'Конверт привязки не подходит. Начните привязку заново.';
      } on ApiException catch (e) {
        linkError = e.message;
      }
      return notifyListeners();
    }
  }

  /// Старое устройство: отправить ключ аккаунта новому устройству по коду из его QR.
  Future<void> linkDevice(String code) async {
    final ({String? nick, int device, ECPublicKey key}) c;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(code.trim()))) as Map;
      c = (nick: j['nick'] as String?, device: j['device'] as int, key: Curve.decodePoint(base64.decode(j['key']), 0));
    } catch (_) {
      throw ApiException('Неверный код привязки');
    }
    if (c.nick != nick) throw ApiException('Код от другого аккаунта');
    final identity = await _keys!.getIdentityKeyPair();
    await _request('POST', _api('/api/link/${c.device}'), {
      'envelope': LinkEnvelope.seal(c.key, identity, nick!, c.device),
    });
  }

  Future<void> updateName(String newName) async {
    final res = await _request('PUT', _api('/api/me'), {'name': newName});
    name = res['name'];
    await _prefs.setString('name', name!);
    notifyListeners();
  }

  Future<List<({String nick, String name})>> searchUsers(String q) async {
    final res = await _request('GET', _api('/api/users', {'q': q}), null) as List;
    final users = [for (final u in res) (nick: u['nick'] as String, name: u['name'] as String)];
    for (final u in users) {
      names[u.nick] = u.name;
    }
    return users;
  }

  /// Код безопасности с собеседником: сверьте его при встрече или по другому каналу.
  /// Считается по ключам, на которые реально шифруются сообщения (из сессий), а не по списку
  /// с сервера: иначе сервер покажет настоящие ключи, а сессии построит на свои (A20).
  /// Неподтверждённые новые устройства собеседника в код не входят: им ничего не шифруется.
  Future<String> safetyNumber(String peer) async {
    final keys = _keys!;
    Future<List<String>> ids(String n) async {
      _devices.remove(n);
      return [
        if (n == nick) keys.identityKey,
        for (final d in await _devicesOf(n))
          if (await _session(n, d)) keys.identityOf(n, d)!,
      ];
    }

    final mine = await ids(nick!), theirs = await ids(peer);
    await _saveKeys();
    return SignalKeys.safetyNumber(nick!, mine, peer, theirs);
  }

  /// Сессия с устройством, при необходимости по набору ключей с сервера.
  /// false — это новое устройство знакомого собеседника, и пользователь его не подтвердил.
  Future<bool> _session(String target, int d) async {
    if (_keys!.hasSession(target, d)) return true;
    try {
      await _keys!.startSession(target, await _request('GET', _api('/api/keys/$target/$d'), null));
      return true;
    } on UntrustedIdentityException {
      return false;
    }
  }

  /// Собеседники, у которых появилось неподтверждённое устройство (см. [approveDevices]).
  final _newDevices = <String>{};

  bool hasNewDevice(String peer) => _newDevices.contains(peer);

  /// У собеседника новое устройство: сообщение не уходит, пока пользователь не подтвердит.
  void _onNewDevice(String peer, String? id) {
    for (final m in chats[peer] ?? <Message>[]) {
      if (m.id == id && m.status == Status.pending) m.status = Status.failed;
    }
    if (_newDevices.add(peer)) {
      chats
          .putIfAbsent(peer, () => [])
          .add(
            Message(
              id: _newId(),
              mine: false,
              text: 'У ${nameOf(peer)} новое устройство, код безопасности изменился. '
                  'Сообщения на него не отправляются, пока вы не подтвердите.',
              time: DateTime.now().millisecondsSinceEpoch,
              status: Status.read,
              update: const {'note': true},
            ),
          );
    }
    _save();
    notifyListeners();
  }

  /// Пользователь подтвердил новые устройства собеседника: им доверяем и шлём заново не отправленное.
  Future<void> approveDevices(String peer) async {
    _devices.remove(peer);
    for (final d in await _devicesOf(peer)) {
      _keys!.allowed.add('$peer:$d');
    }
    _newDevices.remove(peer);
    for (final m in [...?chats[peer]].where((m) => m.mine && m.status == Status.failed)) {
      retry(peer, m);
    }
  }

  Future<void> logout() async {
    _retry?.cancel();
    final ws = _ws;
    _ws = null;
    await ws?.sink.close();
    // Сервер удаляет устройство и его ключи; если связи нет, просто забываем их здесь.
    if (token != null) _request('POST', _api('/api/logout'), {}).ignore();
    token = nick = name = device = _keys = _accountKey = linkError = null;
    connected = false;
    chats.clear();
    _files.clear();
    names.clear();
    lastRead.clear();
    _deletes.clear();
    _gone.clear();
    _devices.clear();
    _skSent.clear();
    _newDevices.clear();
    groups.clear();
    // Адрес сервера оставляем, чтобы не вводить его заново.
    for (final k in ['token', 'nick', 'name', 'device', 'signal', 'chats', 'localFiles']) {
      await _prefs.remove(k);
    }
    await clearLocalFiles();
    notifyListeners();
  }

  Uri _api(String path, [Map<String, String>? query]) => Uri.parse('$server$path').replace(queryParameters: query);

  Future<dynamic> _request(String method, Uri url, Object? body) async {
    final http.Response res;
    try {
      final req = http.Request(method, url)
        ..headers['content-type'] = 'application/json'
        ..headers.addAll({if (token != null) 'authorization': 'Bearer $token'});
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await req.send()).timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException('Нет связи с сервером');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) throw ApiException(data is Map ? data['error'] ?? 'Ошибка сервера' : 'Ошибка сервера');
    return data;
  }

  // --- Сообщения ---

  void send(String to, String text, {Map<String, dynamic>? file, List<Map<String, dynamic>>? files}) {
    final m = Message(
      id: _newId(),
      mine: true,
      text: text,
      time: DateTime.now().millisecondsSinceEpoch,
      status: Status.pending,
      file: file,
      files: files,
    );
    chats.putIfAbsent(to, () => []).add(m);
    _save();
    _deliver(to, m);
  }

  // --- Группы ---

  /// Создаёт группу, где этот пользователь — админ. Возвращает ключ чата.
  String createGroup(String name, List<String> members) {
    final chat = '#${_newId()}';
    _changeGroup(chat, {'name': name, 'members': [nick!, ...members.where((m) => m != nick)], 'admins': [nick!]});
    return chat;
  }

  void renameGroup(String chat, String name) => _changeGroup(chat, {...groups[chat]!, 'name': name});

  void addMembers(String chat, List<String> add) =>
      _changeGroup(chat, {...groups[chat]!, 'members': {...members(chat), ...add}.toList()});

  void removeMember(String chat, String who) => _changeGroup(chat, {
    ...groups[chat]!,
    'members': members(chat)..remove(who),
    'admins': admins(chat)..remove(who),
  });

  void setAdmin(String chat, String who, bool admin) => _changeGroup(chat, {
    ...groups[chat]!,
    'admins': admin ? {...admins(chat), who}.toList() : (admins(chat)..remove(who)),
  });

  /// Выход из группы. Последний админ перед выходом передаёт права следующему участнику.
  void leaveGroup(String chat) {
    final rest = members(chat)..remove(nick);
    var admins = this.admins(chat)..remove(nick);
    if (admins.isEmpty && rest.isNotEmpty) admins = [rest.first];
    _changeGroup(chat, {...groups[chat]!, 'members': rest, 'admins': admins});
  }

  /// Изменение группы уходит как сообщение: применяется сразу, а дойдёт до участников,
  /// в том числе удалённых, и после потери связи — как любое неотправленное сообщение.
  void _changeGroup(String chat, Map<String, dynamic> next) {
    final old = groups[chat];
    final update = {
      ...next,
      'v': (old?['v'] as int? ?? 0) + 1,
      'was': members(chat), // кого ещё уведомить: исключённые тоже узнают, что их убрали
      // Имена участников, которые знает автор: у остальных вместо них были бы никнеймы.
      'names': {for (final m in next['members'] as List) if (names[m] != null) m: names[m]},
    };
    final m = Message(
      id: _newId(),
      mine: true,
      text: _describe(nick!, old, update),
      time: DateTime.now().millisecondsSinceEpoch,
      status: Status.pending,
      update: update,
    );
    _applyGroup(chat, update);
    chats.putIfAbsent(chat, () => []).add(m);
    _save();
    _deliver(chat, m);
  }

  /// Кто-то ушёл из группы: свой ключ отправителя меняем, чтобы ушедший не читал новые сообщения.
  void _applyGroup(String chat, Map<String, dynamic> u) {
    groups[chat] = {'name': u['name'], 'members': u['members'], 'admins': u['admins'], 'v': u['v']};
    if (((u['was'] as List?) ?? []).any((m) => !(u['members'] as List).contains(m))) {
      _keys?.dropSenderKey(chat.substring(1), nick!, device!);
      _skSent.remove(chat);
    }
  }

  /// Устройства ('ник:устройство'), которым уже роздан свой ключ отправителя в группе.
  final _skSent = <String, Set<String>>{};

  /// Можно ли принять изменение группы от [from]: от админа, от создателя новой группы
  /// или когда участник только убирает себя.
  bool _allowed(String chat, String from, Map<String, dynamic> u) {
    final old = groups[chat];
    final members = (u['members'] as List).cast<String>(), admins = (u['admins'] as List).cast<String>();
    if (old == null) return admins.contains(from) && members.contains(from);
    if (u['v'] is! int || u['v'] <= old['v']) return false;
    if (from == nick || this.admins(chat).contains(from)) return true;
    final rest = this.members(chat)..remove(from);
    return u['name'] == old['name'] &&
        members.toSet().containsAll(rest) && rest.toSet().containsAll(members) &&
        admins.every((a) => rest.contains(a)) &&
        // Админы те же, а если уходит единственный админ, он может назначить нового.
        (admins.toSet().containsAll(this.admins(chat)..remove(from)) || (this.admins(chat)..remove(from)).isEmpty);
  }

  /// Строка о том, что изменилось в группе.
  String _describe(String from, Map<String, dynamic>? old, Map<String, dynamic> u) {
    final who = nameOf(from);
    if (old == null) return '$who: создана группа «${u['name']}»';
    String list(Iterable<Object?> nicks) => nicks.map((n) => n == nick ? 'вы' : nameOf(n as String)).join(', ');
    final was = (old['members'] as List).toSet(), now = (u['members'] as List).toSet();
    final wasAdmins = (old['admins'] as List).toSet(), nowAdmins = (u['admins'] as List).toSet();
    return [
      if (u['name'] != old['name']) '$who: новое название «${u['name']}»',
      if (now.difference(was).isNotEmpty) '$who: добавлены ${list(now.difference(was))}',
      if (was.difference(now).length == 1 && !now.contains(from) && was.contains(from)) '$who: выход из группы'
      else if (was.difference(now).isNotEmpty) '$who: исключены ${list(was.difference(now))}',
      if (nowAdmins.difference(wasAdmins).isNotEmpty) 'Админы: + ${list(nowAdmins.difference(wasAdmins))}',
      if (wasAdmins.difference(nowAdmins).intersection(now).isNotEmpty)
        'Админы: − ${list(wasAdmins.difference(nowAdmins).intersection(now))}',
    ].join('\n');
  }

  /// Что уходит [to] из чата [chat]: в группе — с её id, своим устройствам в личном чате — с собеседником.
  Map<String, dynamic> _contentFor(String chat, Map<String, dynamic> content, String to) => isGroup(chat)
      ? {...content, 'group': chat.substring(1)}
      : to == nick
      ? {...content, 'peer': chat}
      : content;

  /// Кому уходит сообщение чата, кроме своих устройств.
  List<String> _recipients(String chat, [Map<String, dynamic>? update]) => isGroup(chat)
      ? {...members(chat), ...?(update?['was'] as List?)?.cast<String>(), ...?(update?['members'] as List?)?.cast<String>()}
            .where((m) => m != nick)
            .toList()
      : [chat];

  static const maxFile = 2 << 30;

  /// Файл шифруется и грузится частями по 8 МБ: так не нужно держать его целиком в памяти,
  /// а каждый запрос проходит через Cloudflare, который режет тела больше 100 МБ.
  /// Размер части при отправке. Небольшие части быстрее повторить на мобильной сети;
  /// получатель берёт размер из сообщения, поэтому файлы с частями по 8 МБ тоже читаются.
  static const part = 2 << 20;

  /// Небольшие вложения держим в памяти до выхода, чтобы не качать их повторно.
  static const _cacheLimit = 32 << 20;

  Future<void> sendFile(String to, String name, Uint8List bytes, {Map<String, dynamic> extra = const {}}) =>
      sendStream(to, name, Stream.value(bytes), bytes.length, extra: extra);

  /// Сколько частей файла грузится и скачивается одновременно, как в Telegram.
  static const _parallel = 4;

  /// Загружает файл ([upload]) и отправляет сообщение с ним. Возвращает вложение из сообщения,
  /// чтобы сохранить файл на устройстве.
  Future<Map<String, dynamic>> sendStream(
    String to,
    String name,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic> extra = const {},
    void Function(int sent, int total)? onProgress,
  }) async {
    final file = await upload(name, data, length, extra: extra, onProgress: onProgress);
    send(to, '', file: file);
    return file;
  }

  /// Шифрует файл новым ключом и загружает частями. Возвращает вложение для сообщения: id и ключ.
  /// Первая часть создаёт загрузку, остальные идут до [_parallel] одновременно.
  Future<Map<String, dynamic>> upload(
    String name,
    Stream<List<int>> data,
    int length, {
    Map<String, dynamic> extra = const {},
    void Function(int sent, int total)? onProgress,
  }) async {
    if (length > maxFile) throw ApiException('Файл больше 2 ГБ');
    final key = FileCrypto.newKey();
    final parts = max(1, (length + part - 1) ~/ part);
    final keep = length <= _cacheLimit ? BytesBuilder(copy: false) : null;
    final size = length + parts * 28; // у каждой части nonce и тег GCM
    String? id;
    var i = 0, sent = 0;
    // Части в пути, вместе с шифрованием: оно тоже идёт в нескольких изолятах сразу.
    // Упавшая часть остаётся в наборе, и следующее ожидание бросит её ошибку.
    // ponytail: после ошибки остальные части догружаются впустую, отменять их, если это станет заметно.
    final running = <Future<void>>{};
    await for (final chunk in rechunk(data, part)) {
      if (i == parts) throw ApiException('Файл изменился во время отправки');
      keep?.add(chunk);
      final index = i++;
      var last = 0; // байт этой части в прогрессе: при повторе часть идёт сначала
      void progress(int n) {
        final m = min(n, chunk.length);
        sent += m - last;
        last = m;
        onProgress?.call(sent, length);
      }
      final body = encryptPart(key, index, index == parts - 1, chunk);
      if (id == null) {
        id = await _uploadPart(null, size, await body, onSent: progress);
      } else {
        final f = body.then((b) => _uploadPart(id, index * (part + 28), b, onSent: progress));
        running.add(f);
        f.then((_) => running.remove(f), onError: (_) {});
        while (running.length >= _parallel) {
          await Future.any(running);
        }
      }
    }
    await Future.wait(running.toList());
    if (i != parts) throw ApiException('Файл изменился во время отправки');
    if (keep != null) _files[id!] = Future.value(keep.takeBytes());
    return {'id': id, 'key': base64.encode(key), 'name': name, 'size': length, 'chunk': part, ...extra};
  }

  /// Стирает с сервера загруженные, но так и не отправленные файлы, например начало альбома, который не ушёл.
  Future<void> discard(List<Map<String, dynamic>> files) async {
    try {
      await _request('POST', _api('/api/unsend'), {
        'files': [for (final f in files) f['id']],
      });
    } catch (e) {
      debugPrint('AURA: удаление загрузок: $e'); // удалятся по сроку
    }
    for (final f in files) {
      _forget(f);
    }
  }

  /// Файлы забываются по очереди: каждый переписывает общий список путей к оригиналам.
  Future<void> _forgetting = Future.value();

  void _forget(Map<String, dynamic> file) {
    _files.remove(file['id']);
    _forgetting = _forgetting.then((_) => forgetFile(file));
  }

  // --- Удаление ---

  /// Удаляет сообщения у себя, вместе с другими своими устройствами, или у всех (только свои сообщения).
  /// Вложения стираются с устройства, а при удалении у всех — и с сервера, и у собеседника.
  /// Удаление дойдёт и после потери связи: оно ждёт в [_deletes], как неотправленное сообщение.
  void delete(String peer, List<Message> list, {bool everyone = false}) {
    assert(!everyone || list.every((m) => m.mine));
    final ids = [for (final m in list) m.id];
    final d = {
      'id': _newId(),
      'peer': peer,
      'ids': ids,
      'everyone': everyone,
      if (everyone) 'files': [for (final m in list) for (final f in m.attachments) f['id']],
    };
    _remove(peer, ids.toSet());
    _deletes.add(d);
    _save();
    _sendDelete(d);
  }

  /// [fromPeer] — удаление пришло от собеседника: он может убрать только свои сообщения.
  /// [by] — удаление пришло от собеседника или участника группы: он может убрать только свои сообщения.
  void _remove(String peer, Set<Object?> ids, {String? by}) {
    chats[peer]?.removeWhere((m) {
      if (!ids.contains(m.id) || (by != null && (m.mine || (m.from != null && m.from != by)))) return false;
      m.attachments.forEach(_forget);
      _gone.add(m.id);
      return true;
    });
    while (_gone.length > 1000) {
      _gone.remove(_gone.first);
    }
  }

  void _sendDelete(Map<String, dynamic> d) => _serial(() async {
    if (!connected || !_deletes.contains(d)) return;
    final String peer = d['peer'], id = d['id'];
    final everyone = d['everyone'] == true;
    // Сначала сервер стирает файлы и ещё не доставленные копии, потом уходят уведомления.
    if (everyone) await _request('POST', _api('/api/unsend'), {'ids': d['ids'], 'files': d['files']});
    // Ждём подтверждения сервера ('sent') по каждой копии; список готов до отправки, ответ может прийти сразу.
    final to = everyone ? _recipients(peer) : <String>[];
    final wait = d['wait'] = [...to, nick];
    for (final t in [...to, nick!]) {
      if (!await _sendCopy(t, id, _contentFor(peer, {'delete': d['ids']}, t))) wait.remove(t);
    }
    _delivered(id, null);
  });

  /// Сервер принял (или отклонил, тогда повторять бесполезно) уведомление об удалении для [to].
  /// Когда ждать больше некого, удаление закончено.
  void _delivered(Object? id, String? to) {
    for (final d in _deletes.where((d) => d['id'] == id && d['wait'] is List).toList()) {
      (d['wait'] as List).remove(to);
      if ((d['wait'] as List).isEmpty) _deletes.remove(d);
    }
    _save();
  }

  /// Без [id] создаёт загрузку размером [at] байт (итог всех зашифрованных частей),
  /// с [id] — пишет часть на место [at].
  Future<String> _uploadPart(String? id, int at, Uint8List body, {void Function(int sent)? onSent}) async {
    final url = _api(id == null ? '/api/files' : '/api/files/$id', {(id == null ? 'size' : 'offset'): '$at'});
    for (var attempt = 1;; attempt++) {
      final http.Response res;
      final req = _Upload(url, body, onSent)
        ..headers.addAll({'content-type': 'application/octet-stream', 'authorization': 'Bearer $token'});
      try {
        res = await http.Response.fromStream(await req.send());
      } catch (e) {
        debugPrint('AURA: загрузка части, попытка $attempt: $e');
        if (attempt == _attempts) throw ApiException('Нет связи с сервером');
        await Future<void>.delayed(Duration(seconds: 2 << attempt)); // повтор безопасен: сервер сверяет offset
        continue;
      } finally {
        req.timer.cancel(); // иначе запрос с телом жил бы в памяти до срабатывания таймера
      }
      if (res.statusCode >= 500 && attempt < _attempts) {
        await Future<void>.delayed(Duration(seconds: 2 << attempt)); // прокси или сервер на миг недоступны
        continue;
      }
      final Object? data;
      try {
        data = jsonDecode(utf8.decode(res.bodyBytes));
      } catch (_) {
        throw ApiException('Сервер не принял файл (${res.statusCode})'); // например, страница ошибки прокси
      }
      if (data is! Map || res.statusCode != 200) {
        throw ApiException(data is Map ? data['error'] ?? 'Ошибка сервера' : 'Ошибка сервера');
      }
      return data['id'];
    }
  }

  /// Сколько раз пробовать часть файла: при смене Wi-Fi на мобильную сеть связь пропадает на десятки секунд.
  static const _attempts = 6;

  /// Расшифрованные вложения этого запуска приложения.
  // ponytail: только в памяти, сохранять на устройство, когда понадобится просмотр без сети.
  final _files = <String, Future<Uint8List>>{};

  /// Скачивает и расшифровывает вложение целиком. Для больших файлов есть [fileParts].
  Future<Uint8List> fileBytes(Map<String, dynamic> file) {
    final String id = file['id'];
    if (_files[id] case final cached?) return cached;
    final bytes = () async {
      final all = BytesBuilder(copy: false);
      await for (final p in fileParts(file)) {
        all.add(p);
      }
      return all.takeBytes();
    }();
    if ((file['size'] ?? 0) <= _cacheLimit) {
      _files[id] = bytes;
      bytes.then((_) {}, onError: (_) {
        _files.remove(id); // после ошибки попробуем скачать заново
      });
    }
    return bytes;
  }

  /// Расшифрованное вложение по частям, по мере скачивания.
  Stream<Uint8List> fileParts(Map<String, dynamic> file) async* {
    final key = base64.decode(file['key']);
    final int? chunk = file['chunk'];
    if (chunk == null) {
      final data = await _downloadPart(file['id']); // файлы старых версий, одним куском
      try {
        yield FileCrypto.decrypt(key, data);
      } catch (_) {
        throw ApiException('Файл повреждён или подменён');
      }
      return;
    }
    final int size = file['size'];
    final parts = max(1, (size + chunk - 1) ~/ chunk);
    Future<Uint8List> fetch(int i) async {
      final start = i * (chunk + 28), length = min(chunk, size - i * chunk) + 28;
      final data = await _downloadPart(file['id'], 'bytes=$start-${start + length - 1}');
      if (data.length != length) throw ApiException('Файл на сервере повреждён');
      return decryptPart(key, i, i == parts - 1, data);
    }

    // До [_parallel] частей качаются одновременно, отдаются по порядку.
    final ahead = <Future<Uint8List>>[];
    for (var next = 0; next < parts || ahead.isNotEmpty;) {
      while (next < parts && ahead.length < _parallel) {
        final f = fetch(next++);
        f.ignore(); // ошибку получит await ниже, а не необработанной в зоне
        ahead.add(f);
      }
      yield await ahead.removeAt(0);
    }
  }

  Future<Uint8List> _downloadPart(String id, [String? range]) async {
    for (var attempt = 1;; attempt++) {
      final http.Response res;
      try {
        res = await http
            .get(_api('/api/files/$id'), headers: {'authorization': 'Bearer $token', 'range': ?range})
            .timeout(const Duration(minutes: 3));
      } catch (e) {
        debugPrint('AURA: скачивание части, попытка $attempt: $e');
        if (attempt == _attempts) throw ApiException('Нет связи с сервером');
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      if (res.statusCode >= 500 && attempt < _attempts) {
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
        continue;
      }
      if (res.statusCode == 404) throw ApiException('Файл удалён с сервера');
      if (res.statusCode != (range == null ? 200 : 206)) throw ApiException('Ошибка сервера');
      return res.bodyBytes;
    }
  }

  void markRead(String peer) {
    lastRead[peer] = DateTime.now().millisecondsSinceEpoch;
    final unread = [
      for (final m in chats[peer] ?? <Message>[])
        if (!m.mine && m.status != Status.read) m..status = Status.read,
    ];
    // В группе подтверждение уходит автору каждого сообщения.
    for (final from in {for (final m in unread) m.from ?? peer}) {
      _sendReceipt(from, Status.read, [for (final m in unread) if ((m.from ?? peer) == from) m.id]);
    }
    _save();
  }

  /// Подтверждения «доставлено» и «прочитано» идут собеседнику тем же зашифрованным путём, что и сообщения.
  // ponytail: прочтение на одном своём устройстве не отмечается на других, синхронизировать при необходимости.
  void _sendReceipt(String peer, Status status, List<String> ids) => _serial(() async {
    await _sendCopy(peer, _newId(), {'receipt': status.name, 'ids': ids});
  });

  bool hasUnread(String peer) {
    final last = chats[peer]?.lastOrNull;
    return last != null && !last.mine && last.time > (lastRead[peer] ?? 0);
  }

  Future<void> _serial(Future<void> Function() job) => _queue = _queue.then((_) => job()).catchError((Object e) {
    debugPrint('AURA: $e');
  });

  /// Повторная отправка сообщения, которое сервер не принял.
  void retry(String to, Message m) {
    m.status = Status.pending;
    _save();
    _deliver(to, m);
  }

  /// Превью видео больше этого (символов base64) в сообщение не кладём.
  static const maxThumb = 40 << 10;

  /// Сообщение длиннее этого (символов JSON) после шифрования не пройдёт на сервер (до 500000 символов base64).
  static const maxContent = 350000;

  /// Собеседнику, а затем копия на свои другие устройства, чтобы переписка была видна везде.
  Future<void> _deliver(String to, Message m) => _serial(() async {
    // Старые версии клали крупное превью, и такие сообщения застревали в очереди: шлём без него.
    // В большом альбоме превью убираем с конца, пока сообщение не влезет.
    final thumbs = m.attachments.where((f) => f['thumb'] is String).toList();
    for (final f in thumbs.where((f) => f['thumb'].length > maxThumb).toList()) {
      thumbs.remove(f..remove('thumb'));
      _save();
    }
    while (thumbs.isNotEmpty && jsonEncode(m.content).length > maxContent) {
      thumbs.removeLast().remove('thumb');
      _save();
    }
    if (isGroup(to) && m.update == null) {
      await _sendGroup(to, m);
    } else if (isGroup(to)) {
      // Изменения группы идут попарно: их получают и исключённые, у которых нет нового ключа.
      // Участник без устройств или с ошибкой не мешает доставке остальным.
      for (final r in _recipients(to, m.update)) {
        try {
          await _sendCopy(r, m.id, _contentFor(to, m.content, r));
        } catch (e) {
          debugPrint('AURA: в группу для $r: $e');
        }
      }
      await _sendCopy(nick!, m.id, _contentFor(to, m.content, nick!));
    } else if (await _sendCopy(to, m.id, m.content)) {
      await _sendCopy(nick!, m.id, {...m.content, 'peer': to});
    }
  });

  Future<List<int>> _devicesOf(String target) async => _devices[target] ??= [
    for (final d in await _request('GET', _api('/api/devices/$target'), null) as List)
      if (target != nick || d['device'] != device) d['device'] as int,
  ];

  /// Сообщение в группу шифруется один раз своим ключом отправителя. Тем, у кого ключа ещё нет,
  /// он сначала уходит попарной сессией.
  Future<void> _sendGroup(String chat, Message m, [List<String>? only]) async {
    if (!connected || _keys == null) return;
    final keys = _keys!, gid = chat.substring(1);
    final key = await keys.senderKey(gid, nick!, device!);
    final body = '$gid:${await keys.groupEncrypt(gid, nick!, device!, jsonEncode(_signed(_contentFor(chat, m.content, ''))))}';
    await _saveKeys();
    for (final r in only ?? [..._recipients(chat), nick!]) {
      try {
        final devices = await _devicesOf(r);
        if (devices.isEmpty) continue;
        await _sendKey(chat, r, key, devices);
        _wsSend({
          'type': 'send',
          'id': m.id,
          'to': r,
          'payloads': [for (final d in devices) {'device': d, 'type': SignalKeys.groupType, 'body': body}],
          'push': ?(r == nick ? null : 'message'),
        });
      } catch (e) {
        debugPrint('AURA: в группу для $r: $e');
      }
    }
  }

  /// Свой ключ отправителя тем устройствам [r], которым он ещё не уходил.
  /// С ключом уходит и описание группы: новое устройство участника иначе не узнает её состав.
  Future<void> _sendKey(String chat, String r, String key, List<int> devices) async {
    final sent = _skSent.putIfAbsent(chat, () => {});
    if (devices.every((d) => sent.contains('$r:$d'))) return;
    // Не ушёл (новое неподтверждённое устройство) — не отмечаем, иначе ключ не уйдёт и после подтверждения.
    if (await _sendCopy(r, _newId(), {'group': chat.substring(1), 'senderKey': key, 'state': groups[chat]})) {
      sent.addAll(devices.map((d) => '$r:$d'));
    }
  }

  /// Отправитель и время внутри шифротекста: получатель сверяет отправителя с конвертом сервера (A21)
  /// и показывает время отправителя, а не сервера (A23).
  Map<String, dynamic> _signed(Map<String, dynamic> content) => {
    ...content,
    'sender': nick,
    'senderDevice': device,
    'time': DateTime.now().millisecondsSinceEpoch,
  };

  /// Шифрует сообщение для каждого устройства [target]. false — если устройств пока нет
  /// или среди них новое неподтверждённое.
  Future<bool> _sendCopy(String target, String id, Map<String, dynamic> content) async {
    if (!connected || _keys == null) return false;
    final keys = _keys!;
    final devices = await _devicesOf(target);
    if (devices.isEmpty) return false;
    final payloads = [];
    for (final d in devices) {
      if (!await _session(target, d)) {
        _onNewDevice(target, id);
        return false;
      }
      payloads.add(await keys.encrypt(target, d, jsonEncode(_signed(content))));
    }
    await _saveKeys();
    _wsSend({'type': 'send', 'id': id, 'to': target, 'payloads': payloads, 'push': ?_pushKind(target, content)});
    return true;
  }

  /// Новое входящее сообщение в переписке: приложение в фоне показывает уведомление.
  void Function()? onIncoming;

  /// Токен Firebase этого устройства: по нему сервер будит приложение, когда соединения нет.
  String? _pushToken;

  void setPushToken(String token) {
    _pushToken = token;
    if (connected) _sendPushToken();
  }

  void _sendPushToken() =>
      _request('PUT', _api('/api/push'), {'token': _pushToken}).catchError((Object e) => debugPrint('AURA: push-токен: $e'));

  /// Будить ли получателя push: ради сообщений переписки и звонка, не своих устройств.
  /// end — звонок отменили или ответили на другом устройстве: закрытое приложение гасит уведомление.
  String? _pushKind(String target, Map<String, dynamic> content) => target == nick
      ? null
      : switch ((content['call'] as Map?)?['type']) {
          'offer' => 'call',
          'end' || 'taken' => 'end',
          _ => content.containsKey('text') ? 'message' : null,
        };

  /// Сигналы звонка (предложение, ответ, сброс) идут зашифрованными сообщениями, но в переписку не попадают.
  void Function(String from, int device, int sentAt, Map<String, dynamic> signal)? onCall;

  void sendCall(String to, Map<String, dynamic> signal) => _serial(() async {
    await _sendCopy(to, _newId(), {'call': signal});
  });

  /// STUN и TURN для звонка.
  Future<List<Map<String, dynamic>>> iceServers() async =>
      (await _request('GET', _api('/api/ice'), null) as List).cast();

  /// Подтверждение (ack) уходит всегда: иначе любое исключение при разборе оставит
  /// сообщение в очереди сервера, и оно будет приходить вечно (A24).
  Future<void> _receive(Map<String, dynamic> msg) async {
    try {
      await _handle(msg);
    } finally {
      _wsSend({'type': 'ack', 'id': msg['id']});
    }
  }

  Future<void> _handle(Map<String, dynamic> msg) async {
    final String id = msg['id'], from = msg['from'];
    // Дубль (повторная доставка) не расшифровываем второй раз.
    if (!_gone.contains(id) && !chats.values.any((l) => l.any((m) => m.id == id)) && _keys != null) {
      var peer = from;
      String text;
      Map<String, dynamic>? content, file, update;
      List<Map<String, dynamic>>? files;
      final int fromDevice = msg['device'];
      final hadSession = _keys!.hasSession(from, fromDevice);
      var drop = false;
      try {
        if (msg['ctype'] == SignalKeys.groupType) {
          final String body = msg['body'];
          final gid = body.substring(0, body.indexOf(':'));
          content = {
            ...jsonDecode(await _keys!.groupDecrypt(gid, from, msg['device'], body.substring(gid.length + 1))),
            'group': gid,
          };
        } else {
          content = jsonDecode(await _keys!.decrypt(from, msg['device'], msg['ctype'], msg['body']));
        }
        // Сервер не может приписать сообщение другому отправителю. Старые клиенты поля не присылают.
        if (content!.containsKey('sender') &&
            (content['sender'] != from || content['senderDevice'] != fromDevice)) {
          if (!hadSession) _keys!.forget(from, fromDevice);
          throw const _Forged();
        }
        text = content['text'] is String ? content['text'] : '';
        file = content['file'];
        files = (content['files'] as List?)?.cast();
        // Вложение с полями не того типа сломало бы список чатов и скачивание (A25).
        if ((file != null && !_validFile(file)) || (files != null && !files.every(_validFile))) {
          text = '⚠ Некорректное вложение';
          file = files = null;
        }
        update = content['groupUpdate'];
        if (content['group'] case final String g) {
          peer = '#$g';
        } else if (from == nick) {
          peer = content['peer']; // копия своего сообщения с другого устройства
        }
      } on _Forged {
        debugPrint('AURA: $id от $from: отправитель внутри не совпадает с конвертом');
        drop = true;
        text = '';
      } on DuplicateMessageException {
        // Повтор уже расшифрованного шифротекста под новым id: сервер или сбой сети, не показываем (A22).
        drop = true;
        text = '';
      } on UntrustedIdentityException {
        _onNewDevice(from, null);
        drop = true;
        text = '';
      } catch (e) {
        debugPrint('AURA: не расшифровано $id от $from: $e');
        text = '⚠ Не удалось расшифровать сообщение';
        // Нет ключа отправителя (устройство новое или пропустило раздачу): просим его заново,
        // а сбой показываем в группе, а не в личном чате.
        final String body = msg['body'];
        if (msg['ctype'] == SignalKeys.groupType && body.contains(':')) {
          final gid = body.substring(0, body.indexOf(':'));
          peer = '#$gid';
          try {
            await _sendCopy(from, _newId(), {'group': gid, 'needKey': true});
          } catch (err) {
            debugPrint('AURA: запрос ключа у $from: $err');
          }
        }
      }
      await _saveKeys();
      final group = isGroup(peer);
      if (drop) {
        // отброшено выше
      } else if (content?['senderKey'] case final String key) {
        try {
          await _keys!.processSenderKey(content!['group'], from, msg['device'], key);
          await _saveKeys();
          // Описание группы берём от своего устройства или, если группа незнакома, от её участника.
          if (content['state'] case final Map s
              when (from == nick && (s['v'] as int) > (groups[peer]?['v'] as int? ?? 0)) ||
                  (groups[peer] == null && (s['members'] as List).contains(from) && (s['members'] as List).contains(nick))) {
            groups[peer] = s.cast();
          }
        } catch (e) {
          debugPrint('AURA: ключ отправителя от $from: $e');
        }
      } else if (content?['needKey'] == true) {
        if (group && members(peer).contains(from) && members(peer).contains(nick)) {
          _skSent[peer]?.removeWhere((s) => s.startsWith('$from:'));
          _serial(() async {
            final gid = peer.substring(1);
            await _sendKey(peer, from, await _keys!.senderKey(gid, nick!, device!), await _devicesOf(from));
            await _saveKeys();
          });
        }
      } else if (content?['call'] case final Map signal) {
        onCall?.call(from, msg['device'], msg['sentAt'], signal.cast());
      } else if (content?['receipt'] case final String receipt) {
        // Неизвестный статус (новая версия или мусор) пропускаем.
        if (Status.values.asNameMap()[receipt] case final status?) _onReceipt(status, (content!['ids'] as List).cast());
      } else if (content?['delete'] case final List ids) {
        _remove(peer, ids.toSet(), by: from == nick ? null : from);
      } else if (update != null && (!group || !_allowed(peer, from, update))) {
        debugPrint('AURA: изменение группы $peer от $from отклонено');
      } else if (group && update == null && from != nick && groups[peer] != null && !members(peer).contains(from)) {
        debugPrint('AURA: $from не участник $peer'); // неизвестную группу принимаем: её описание может прийти позже
      } else {
        final mine = from == nick;
        if (update != null) {
          text = _describe(from, groups[peer], update);
          _applyGroup(peer, update);
          for (final MapEntry(:key, :value) in (update['names'] as Map? ?? {}).entries) {
            names.putIfAbsent(key, () => value);
          }
        }
        chats
            .putIfAbsent(peer, () => [])
            .add(
              Message(
                id: id,
                mine: mine,
                text: text,
                // Время сервера — только для старых клиентов; из будущего не бывает.
                time: min(content?['time'] is int ? content!['time'] : msg['sentAt'], DateTime.now().millisecondsSinceEpoch),
                status: mine ? Status.sent : Status.delivered,
                file: file,
                files: files,
                from: group && !mine ? from : null,
                update: update,
              ),
            );
        if (!mine) {
          _sendReceipt(from, Status.delivered, [id]);
          onIncoming?.call();
        }
      }
      _save();
    }
  }

  Timer? _probe;

  /// Проверить соединение сейчас, не дожидаясь паузы между попытками: в фоне оно могло
  /// умереть незаметно и выглядеть живым. Нет ответа на ping за 5 секунд — подключаемся заново.
  void checkConnection() {
    if (!signedIn || _keys == null) return;
    if (!connected) {
      if (_retry?.isActive ?? false) _connect();
      return;
    }
    if (_probe?.isActive ?? false) return;
    _wsSend({'type': 'ping'});
    _probe = Timer(const Duration(seconds: 5), () {
      final dead = _ws;
      connected = false;
      _connect(); // старое соединение закроется позже, _onClosed его уже не учтёт
      dead?.sink.close();
      notifyListeners();
    });
  }

  void _connect() {
    _retry?.cancel();
    _probe?.cancel();
    final ws = WebSocketChannel.connect(Uri.parse(server.replaceFirst('http', 'ws')).replace(path: '/ws'));
    _ws = ws;
    ws.sink.add(jsonEncode({'type': 'auth', 'token': token}));
    ws.stream.listen((raw) => _onMessage(jsonDecode(raw as String)), onDone: () => _onClosed(ws), onError: (_) {});
  }

  /// Статус только растёт: позднее «доставлено» не отменяет «прочитано».
  /// В группе статус показывает первого, кто получил или прочитал.
  // ponytail: без списка «кто прочитал»; добавить, если понадобится.
  void _onReceipt(Status status, List<String> ids) {
    for (final list in chats.values) {
      for (final m in list) {
        if (m.mine && ids.contains(m.id) && m.status.index < status.index) m.status = status;
      }
    }
  }

  void _onClosed(WebSocketChannel ws) {
    if (_ws != ws) return; // выход из аккаунта или уже переподключились
    connected = false;
    notifyListeners();
    if (ws.closeCode == 4401) {
      logout(); // сессия больше не действует
      return;
    }
    _retry = Timer(Duration(seconds: _backoff), _connect);
    _backoff = min(_backoff * 2, 30);
  }

  void _onMessage(Map<String, dynamic> msg) {
    _probe?.cancel(); // соединение живо
    switch (msg['type']) {
      case 'ready':
        connected = true;
        _backoff = 1;
        if ((msg['preKeys'] as int) < SignalKeys.preKeyBatch ~/ 2) _refillPreKeys();
        if (_pushToken != null) _sendPushToken();
        // Переотправляем то, что не дошло до сервера; сервер отбрасывает дубли по id.
        for (final MapEntry(key: to, value: list) in chats.entries) {
          for (final m in list.where((m) => m.status == Status.pending)) {
            _deliver(to, m);
          }
        }
        _deletes.toList().forEach(_sendDelete);
      case 'sent' when _deletes.any((d) => d['id'] == msg['id']):
        _delivered(msg['id'], msg['to']);
      case 'sent' when msg['to'] != nick:
        for (final list in chats.values) {
          for (final m in list.where((m) => m.id == msg['id'] && m.status == Status.pending)) {
            m.status = Status.sent;
          }
        }
        _save();
      case 'error' when msg['error'] == 'devices':
        // У получателя появилось или пропало устройство: берём новый список и шифруем заново.
        final String to = msg['to'];
        _devices.remove(to);
        _deletes.where((d) => d['id'] == msg['id']).toList().forEach(_sendDelete);
        for (final MapEntry(key: peer, value: list) in chats.entries) {
          for (final m in list.where((m) => m.id == msg['id'])) {
            _serial(() async => isGroup(peer) && m.update == null
                ? await _sendGroup(peer, m, [to])
                : await _sendCopy(to, m.id, _contentFor(peer, m.content, to)));
          }
        }
      case 'error' when _deletes.any((d) => d['id'] == msg['id']):
        _delivered(msg['id'], msg['to']); // сервер не принял уведомление, повторять бесполезно
      case 'error' when msg['id'] != null && msg['to'] != nick:
        // Сервер отклонил сообщение: «не отправлено», заново по нажатию. Копии на свои устройства не в счёт.
        for (final list in chats.values) {
          for (final m in list.where((m) => m.id == msg['id'] && m.status == Status.pending)) {
            m.status = Status.failed;
          }
        }
        _save();
      case 'message':
        _serial(() => _receive(msg));
    }
    notifyListeners();
  }

  /// Одноразовые prekey расходуются собеседниками, когда те начинают с нами переписку.
  void _refillPreKeys() => _serial(() async {
    final keys = _keys!;
    final preKeys = keys.newPreKeys();
    await _saveKeys(); // сначала сохраняем приватные части, потом публикуем
    await _request('PUT', _api('/api/keys'), {'preKeys': preKeys});
  });

  Future<void> _saveKeys() async {
    if (_keys != null) await _prefs.setString('signal', _keys!.toJson());
  }

  void _wsSend(Map<String, dynamic> msg) {
    if (connected || msg['type'] == 'auth') _ws?.sink.add(jsonEncode(msg));
  }

  void _save() {
    _prefs.setString('chats', jsonEncode({'chats': chats, 'names': names, 'lastRead': lastRead, 'deletes': _deletes, 'gone': [..._gone], 'groups': groups}));
    notifyListeners();
  }

  static String _newId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final client = AuraClient.instance;

/// Тело запроса кусками по 64 КБ: сокет забирает их по мере отправки, так виден прогресс внутри части.
/// В браузере тело всё равно собирается целиком, там прогресс идёт по частям.
/// Запрос целиком, с отправкой тела, обрывается через 3 минуты: на зависшей сети повтор начнётся,
/// а оборванный запрос не дойдёт до сервера позже повтора.
class _Upload extends http.BaseRequest with http.Abortable {
  _Upload(Uri url, this.body, this.onSent) : super('POST', url) {
    contentLength = body.length;
    timer = Timer(const Duration(minutes: 3), _abort.complete);
  }

  final Uint8List body;
  final void Function(int sent)? onSent;

  final _abort = Completer<void>();
  late final Timer timer;

  @override
  Future<void> get abortTrigger => _abort.future;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(() async* {
      for (var i = 0; i < body.length; i += 64 << 10) {
        final end = min(i + (64 << 10), body.length);
        yield Uint8List.sublistView(body, i, end);
        onSent?.call(end);
      }
    }());
  }
}

/// Вложение от собеседника: {id, key, name, size, chunk?, thumb?} нужных типов.
bool _validFile(Object? f) =>
    f is Map &&
    f['id'] is String &&
    f['key'] is String &&
    f['name'] is String &&
    f['size'] is int &&
    f['size'] >= 0 &&
    (f['chunk'] == null || (f['chunk'] is int && f['chunk'] > 0)) &&
    (f['thumb'] == null || f['thumb'] is String);

/// Отправитель внутри шифротекста не совпадает с конвертом сервера.
class _Forged implements Exception {
  const _Forged();
}
