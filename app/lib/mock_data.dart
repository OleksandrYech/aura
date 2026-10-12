// ponytail: тестовые данные этапа 1, заменяются сервером на этапе 2.

class Chat {
  const Chat(this.name, this.preview, this.time, {this.unread = false, this.group = false});
  final String name, preview, time;
  final bool unread, group;

  String get initials => name.split(' ').take(2).map((w) => w[0]).join().toUpperCase();
}

class Message {
  Message(this.text, this.time, {required this.mine});
  final String text, time;
  final bool mine;
}

const chats = [
  Chat('Анна Морозова', 'Привет! Как дела?', '12:04', unread: true),
  Chat('Денис Ковалёв', 'Отправил файлы, посмотри', '11:20'),
  Chat('Семейная группа', 'Мама: хорошо, завтра увидимся', 'вчера', unread: true, group: true),
  Chat('Олег Литвин', 'Спасибо за помощь', 'вчера'),
];

List<Message> sampleMessages() => [
      Message('Привет! Как дела?', '12:02', mine: false),
      Message('Привет, все хорошо, спасибо! А у тебя как?', '12:03', mine: true),
      Message('Тоже неплохо. Встретимся завтра?', '12:04', mine: false),
      Message('Да, конечно', '12:04', mine: true),
    ];
