import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ai/kapy_ai.dart';
import 'package:kapy_notes/ai/kapy_chat_records.dart';

KapyMessage _message(String text, {List<KapyNoteRef> read = const []}) =>
    KapyMessage(
      id: '0195f0d0-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      role: KapyRole.assistant,
      text: text,
      at: DateTime.utc(2026, 11, 17, 10),
      read: read,
      matching: read.length,
      model: KapyModel.cloud,
    );

const _chatId = '0195f0d0-aaaa-4bbb-8ccc-dddddddddddd';

int _bytes(ChatMessagePart part) =>
    utf8.encode(jsonEncode(part.toPayload())).length;

void main() {
  group('a message as parts', () {
    test('short text is one part carrying everything', () {
      final parts = chatMessageParts(_chatId, _message('Flights.'));
      expect(parts, hasLength(1));
      expect(parts.single.parts, 1);
      expect(parts.single.role, KapyRole.assistant);
      expect(chatMessageOf(parts)!.text, 'Flights.');
    });

    test('an empty answer is still a part', () {
      final parts = chatMessageParts(_chatId, _message(''));
      expect(parts, hasLength(1));
      expect(chatMessageOf(parts)!.text, '');
    });

    test(
      'whatever the text holds, every part fits a record, and they read back whole',
      () {
        final random = Random(7);
        const pieces = [
          'a',
          'é',
          '日本語',
          '😀',
          '\n',
          '"',
          r'\',
          '\t',
          '\u0001',
          ' ',
          'word ',
        ];
        for (var round = 0; round < 40; round++) {
          final text = [
            for (var i = 0; i < random.nextInt(9000); i++)
              pieces[random.nextInt(pieces.length)],
          ].join();
          final parts = chatMessageParts(_chatId, _message(text));
          expect(parts.length, lessThanOrEqualTo(chatMessagePartsMax));
          for (final part in parts) {
            expect(
              _bytes(part),
              lessThanOrEqualTo(chatPayloadMax),
              reason: '$round',
            );
          }
          final back = chatMessageOf(parts)!.text;
          expect(back, text, reason: 'round $round');
          final shuffled = [...parts]..shuffle(random);
          expect(chatMessageOf(shuffled)!.text, text);
        }
      },
    );

    test('a part carries only what its own record needs', () {
      final parts = chatMessageParts(_chatId, _message('z' * 9000));
      expect(parts.length, greaterThan(2));
      expect(parts.first.toPayload(), contains('role'));
      for (final part in parts.skip(1)) {
        expect(part.toPayload().keys, isNot(contains('role')));
        expect(part.toPayload().keys, isNot(contains('read')));
      }
    });

    test(
      'notes it read are cut to a title and dropped from the end rather than crowd out the text',
      () {
        final read = [
          for (var i = 0; i < 30; i++)
            KapyNoteRef(
              noteId: 'n$i',
              title: 'T' * 400,
              edited: DateTime.utc(2026, 11, 1),
            ),
        ];
        final parts = chatMessageParts(
          _chatId,
          _message('Short answer', read: read),
        );
        expect(parts, hasLength(1));
        expect(_bytes(parts.single), lessThanOrEqualTo(chatPayloadMax));
        expect(parts.single.read, isNotEmpty);
        expect(parts.single.read.length, lessThan(30));
        expect(parts.single.read.first.title.length, 100);
        expect(parts.single.read.first.noteId, 'n0');
        expect(parts.single.text, 'Short answer');
      },
    );

    test('a hidden note keeps its id and loses its title', () {
      final read = [
        KapyNoteRef(
          noteId: 'n1',
          title: 'Therapy',
          edited: DateTime.utc(2026, 11, 1),
        ),
        KapyNoteRef(
          noteId: 'n2',
          title: 'Trip',
          edited: DateTime.utc(2026, 11, 1),
        ),
      ];
      final parts = chatMessageParts(
        _chatId,
        _message('x', read: read),
        hidden: (id) => id == 'n1',
      );
      expect(
        [for (final n in parts.single.read) (n.noteId, n.title)],
        [('n1', ''), ('n2', 'Trip')],
      );
    });

    test(
      'text past the most parts is left off, and the parts that remain are whole',
      () {
        final parts = chatMessageParts(_chatId, _message('q' * 300000));
        expect(parts, hasLength(chatMessagePartsMax));
        final text = chatMessageOf(parts)!.text;
        expect(text.length, lessThan(300000));
        expect(text.length, greaterThan(chatMessagePartsMax * 2000));
      },
    );

    test(
      'a message is whole only with every part, from 0, and agreeing on how many',
      () {
        final parts = chatMessageParts(_chatId, _message('w' * 9000));
        expect(chatMessageOf(parts.sublist(1)), isNull);
        expect(chatMessageOf(parts.sublist(0, parts.length - 1)), isNull);
        expect(chatMessageOf(const []), isNull);
      },
    );
  });

  group('reading a payload', () {
    Map<String, Object?> part0() => {
      'kind': 'chatMessage',
      'chatId': _chatId,
      'messageId': '0195f0d0-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      'part': 0,
      'parts': 1,
      'text': 'hi',
      'role': 'user',
      'at': 1,
    };

    test('a good part reads, and a bad one does not', () {
      expect(ChatMessagePart.fromPayload(part0()), isNotNull);
      for (final bad in <Map<String, Object?>>[
        {...part0(), 'role': 'system'},
        {...part0()}..remove('role'),
        {...part0()}..remove('at'),
        {...part0(), 'part': 1},
        {...part0(), 'parts': 0},
        {...part0(), 'parts': chatMessagePartsMax + 1},
        {...part0(), 'text': 4},
        {...part0(), 'chatId': 7},
      ]) {
        expect(ChatMessagePart.fromPayload(bad), isNull, reason: '$bad');
      }
      expect(ChatMessagePart.fromPayload('nope'), isNull);
    });

    test(
      'a chat record keeps what a later build wrote, and merges field by field',
      () {
        final raw = {
          'kind': 'chat',
          'chatId': _chatId,
          'title': {'v': 'Trip', 'at': 5},
          'model': {
            'v': {'kind': 'cloud', 'id': 'cloud', 'label': 'Kapy AI Cloud'},
            'at': 5,
          },
          'createdAt': 1,
          'pinned': true,
        };
        final meta = ChatMeta.fromPayload(raw)!;
        expect(meta.toPayload()['pinned'], isTrue);
        final other = ChatMeta.fromPayload({
          ...raw,
          'title': {'v': 'Kochi', 'at': 9},
        })!;
        expect(meta.merge(other).title.v, 'Kochi');
        expect(other.merge(meta).title.v, 'Kochi');
        expect(
          chatSig(meta.merge(other).toPayload()),
          chatSig(other.merge(meta).toPayload()),
        );
        expect(
          ChatMeta.fromPayload({
            ...raw,
            'title': {'v': '', 'at': 1},
          }),
          isNull,
        );
        expect(ChatMeta.fromPayload({...raw, 'createdAt': 'x'}), isNull);
      },
    );

    test('a title past the most is cut', () {
      final meta = ChatMeta.fromPayload({
        'kind': 'chat',
        'chatId': _chatId,
        'title': {'v': 'x' * 500, 'at': 5},
        'model': {
          'v': {'kind': 'cloud', 'id': 'cloud', 'label': 'Kapy AI Cloud'},
          'at': 5,
        },
        'createdAt': 1,
      })!;
      expect(meta.title.v.length, chatTitleMax);
    });
  });
}
