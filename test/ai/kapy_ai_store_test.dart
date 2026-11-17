import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_ai_store.dart';

import 'ai_fakes.dart';

void main() {
  const apple = KapyModel(
    kind: KapyModelKind.device,
    id: 'apple',
    label: 'Apple Intelligence',
  );

  test('settings default to on, with nothing agreed to', () {
    final store = KapyAiStore(MemoryStore());
    expect(store.enabled, isTrue);
    expect(store.defaultModel, isNull);
    expect(store.cloudConsent, isFalse);
    expect(store.hasAccountConsent(KapyAccountKind.codex), isFalse);
    expect(store.isToolAllowed(KapyAccountKind.codex), isTrue);
  });

  test('settings round trip through the JSON store', () {
    final local = MemoryStore();
    KapyAiStore(local)
      ..enabled = false
      ..defaultModel = apple
      ..cloudConsent = true
      ..giveAccountConsent(KapyAccountKind.openRouter)
      ..giveAccountConsent(KapyAccountKind.openRouter)
      ..allowTool(KapyAccountKind.claudeCode, false);
    final reread = KapyAiStore(
      MemoryStore()..data.addAll(jsonDecode(jsonEncode(local.data))),
    );
    expect(reread.enabled, isFalse);
    expect(reread.defaultModel, apple);
    expect(reread.cloudConsent, isTrue);
    expect(reread.hasAccountConsent(KapyAccountKind.openRouter), isTrue);
    expect(reread.hasAccountConsent(KapyAccountKind.codex), isFalse);
    expect(reread.isToolAllowed(KapyAccountKind.claudeCode), isFalse);
    expect(reread.isToolAllowed(KapyAccountKind.codex), isTrue);
    reread.allowTool(KapyAccountKind.claudeCode, true);
    expect(reread.isToolAllowed(KapyAccountKind.claudeCode), isTrue);
  });

  test('a chat is plain JSON that reads back the same', () {
    final chat = KapyChat(
      id: 'c1',
      title: 'Trip',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      model: apple,
      messages: [
        KapyMessage(
          id: 'm1',
          role: KapyRole.user,
          text: 'Lisbon?',
          at: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        KapyMessage(
          id: 'm2',
          role: KapyRole.assistant,
          text: 'Friday.',
          at: DateTime.fromMillisecondsSinceEpoch(2000),
          read: [
            KapyNoteRef(
              noteId: 'n1',
              title: 'Trip',
              edited: DateTime.fromMillisecondsSinceEpoch(500),
            ),
          ],
          matching: 4,
          model: apple,
        ),
      ],
    );
    final back = chatFromJson(jsonDecode(jsonEncode(chatToJson(chat))))!;
    expect(chatToJson(back), chatToJson(chat));
    expect(back.messages.last.read.single.noteId, 'n1');
    expect(back.messages.last.matching, 4);
  });

  test(
    'when the title and the model were set read back, and default to creation',
    () {
      final chat = KapyChat(
        id: 'c1',
        title: 'Trip',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(5000),
        model: apple,
        titleAt: DateTime.fromMillisecondsSinceEpoch(3000),
        modelAt: DateTime.fromMillisecondsSinceEpoch(4000),
      );
      final back = chatFromJson(jsonDecode(jsonEncode(chatToJson(chat))))!;
      expect(back.titleAt.millisecondsSinceEpoch, 3000);
      expect(back.modelAt.millisecondsSinceEpoch, 4000);

      final before = chatToJson(chat)
        ..remove('titleAt')
        ..remove('modelAt');
      final old = chatFromJson(before)!;
      expect(old.titleAt, old.createdAt);
      expect(old.modelAt, old.createdAt);
    },
  );

  test('chats are newest first and deletions are remembered with when', () {
    final store = KapyAiStore(MemoryStore());
    KapyChat chat(String id, int at) => KapyChat(
      id: id,
      title: id,
      createdAt: DateTime.fromMillisecondsSinceEpoch(at),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      model: apple,
    );
    store.writeChats(
      [chat('old', 1), chat('new', 9)],
      {'gone': DateTime.fromMillisecondsSinceEpoch(5)},
    );
    expect(store.readChats().map((c) => c.id), ['new', 'old']);
    expect(store.readDeleted()['gone']!.millisecondsSinceEpoch, 5);
    store.clearChats({'gone': DateTime.fromMillisecondsSinceEpoch(5)});
    expect(store.readChats(), isEmpty);
  });

  test('corrupt records are skipped, not fatal', () {
    final local = MemoryStore()
      ..data['kapyAi.chats.v1'] = {
        'chats': [
          'nope',
          {'id': 1},
          {
            'id': 'ok',
            'title': 't',
            'createdAt': 0,
            'updatedAt': 0,
            'model': apple.toJson(),
            'messages': [
              {'id': 'x'},
              7,
            ],
          },
        ],
        'deleted': {'a': 'not a time'},
      }
      ..data['kapyAi.v1'] = {'defaultModel': 'garbage'};
    final store = KapyAiStore(local);
    expect(store.readChats().single.messages, isEmpty);
    expect(store.readDeleted(), isEmpty);
    expect(store.defaultModel, isNull);
  });

  test('no secret field exists in the chat or settings records', () {
    final local = MemoryStore();
    KapyAiStore(local)
      ..cloudConsent = true
      ..writeChats(const [], const {});
    final text = jsonEncode(local.data).toLowerCase();
    for (final word in ['key', 'token', 'secret', 'password']) {
      expect(text, isNot(contains(word)));
    }
  });
}
