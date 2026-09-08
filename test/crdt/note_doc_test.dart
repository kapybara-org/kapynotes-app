import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';

import 'helpers.dart';

void main() {
  group('local edits', () {
    test('typing, deleting and replacing reproduce the body', () {
      final doc = NoteDoc(replica: 'a');
      expect(type(doc, 'hello'), isNotEmpty);
      expect(doc.view.body, 'hello');

      type(doc, 'hello world');
      expect(doc.text, 'hello world');

      type(doc, 'hello');
      expect(doc.text, 'hello');

      type(doc, 'hexxo');
      expect(doc.text, 'hexxo');
      expect(doc.length, 5);

      type(doc, '');
      expect(doc.text, '');
      expect(doc.nodeCount, greaterThan(0));
    });

    test('nothing changed emits nothing', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'abc');
      final view = doc.view;
      expect(
        doc.reconcile(
          body: 'abc',
          formats: view.formats,
          attachments: view.attachments,
          createdAt: view.createdAt!,
        ),
        isEmpty,
      );
    });

    test('a replacement becomes a delete run then an insert run', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, '1 + 2');
      final ops = type(doc, '1 + 34');
      expect(ops.map((op) => (op as List)[0]), ['d', 'i']);
    });

    test('a fresh doc applying the ops matches', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final log = <Object?>[];
      for (final body in ['h', 'he', 'hel', 'hello', 'hell', 'hello\n1+1']) {
        log.addAll(type(a, body));
      }
      expect(b.apply(log), isTrue);
      expect(b.text, a.text);
      expect(b.view.createdAt, created);
    });

    test('archive and restore state converges between replicas', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'Keep this'));
      final archivedAt = DateTime.utc(2026, 9, 7, 13);

      final archiveOps = a.reconcile(
        body: a.view.body,
        formats: a.view.formats,
        attachments: a.view.attachments,
        createdAt: a.view.createdAt!,
        archivedAt: archivedAt,
        now: archivedAt,
      );
      b.apply(archiveOps);
      expect(b.view.archivedAt, archivedAt);

      final restoredAt = DateTime.utc(2026, 9, 7, 14);
      final restoreOps = b.reconcile(
        body: b.view.body,
        formats: b.view.formats,
        attachments: b.view.attachments,
        createdAt: b.view.createdAt!,
        archivedAt: null,
        now: restoredAt,
      );
      a.apply(restoreOps);
      expect(a.view.archivedAt, isNull);
      expect(b.view.archivedAt, isNull);
    });

    test('deleting a typed word is one op', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'x');
      type(doc, 'x word');
      final ops = type(doc, 'x');
      expect(ops, hasLength(1));
      expect((ops.single as List)[0], 'd');
      expect((ops.single as List)[3], 5);
    });

    test('counters continue above a restored snapshot', () {
      final a = NoteDoc(replica: 'a');
      type(a, 'abc');
      final restored = NoteDoc.fromSnapshot(a.toSnapshot(), replica: 'a');
      final ops = type(restored, 'abcd');
      expect((ops.first as List)[2], 3);
      expect(restored.clock['a'], 3);
    });
  });

  group('interleaving', () {
    test('two words typed at the same spot stay whole', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final fromA = type(a, 'abc');
      final fromB = type(b, 'xyz');
      a.apply(fromB);
      b.apply(fromA);
      expect(a.text, b.text);
      expect(a.text, anyOf('abcxyz', 'xyzabc'));
    });

    test('forward typing char by char does not interleave', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final fromA = [
        for (final body in ['a', 'ab', 'abc']) ...type(a, body),
      ];
      final fromB = [
        for (final body in ['x', 'xy', 'xyz']) ...type(b, body),
      ];
      a.apply(fromB);
      b.apply(fromA);
      expect(a.text, b.text);
      expect(a.text, anyOf('abcxyz', 'xyzabc'));
    });

    test('backward typing char by char does not interleave', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final fromA = [
        for (final body in ['c', 'bc', 'abc']) ...type(a, body),
      ];
      final fromB = [
        for (final body in ['z', 'yz', 'xyz']) ...type(b, body),
      ];
      a.apply(fromB);
      b.apply(fromA);
      expect(a.text, b.text);
      expect(a.text, anyOf('abcxyz', 'xyzabc'));
    });

    test('concurrent lines in the middle of shared text stay whole', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final seed = type(a, '1\n\n4');
      b.apply(seed);
      final fromA = [
        for (final body in ['1\n2\n4', '1\n22\n4']) ...type(a, body),
      ];
      final fromB = [
        for (final body in ['1\n3\n4', '1\n33\n4']) ...type(b, body),
      ];
      a.apply(fromB);
      b.apply(fromA);
      expect(a.text, b.text);
      expect(a.text, anyOf('1\n2233\n4', '1\n3322\n4'));
    });
  });

  group('anchored formats and attachments', () {
    test('bold follows its word when text is inserted above it', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'hello world'));

      final styled = a.reconcile(
        body: 'hello world',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
        now: created,
      );
      expect(styled, hasLength(1));
      final fromB = type(b, 'XXhello world');

      a.apply(fromB);
      b.apply(styled);
      expect(a.text, 'XXhello world');
      expect(a.view.formats, [bold(2, 7)]);
      expect(b.view.formats, [bold(2, 7)]);
    });

    test('a range shrinks when its ends are deleted and drops when empty', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'hello world');
      doc.reconcile(
        body: 'hello world',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
      );

      // The editor rebases its own ranges across each edit; the anchored
      // rendering must agree with it, so no register op is needed.
      List<Object?> edit(String body, List<NoteFormatRange> formats) =>
          doc.reconcile(
            body: body,
            formats: formats,
            attachments: const [],
            createdAt: created,
          );

      var ops = edit('ello world', [bold(0, 4)]);
      expect(ops.map((op) => (op as List)[0]), ['d']);
      expect(doc.view.formats, [bold(0, 4)]);

      ops = edit('ell world', [bold(0, 3)]);
      expect(ops.map((op) => (op as List)[0]), ['d']);
      expect(doc.view.formats, [bold(0, 3)]);

      ops = edit(' world', const []);
      expect(ops.map((op) => (op as List)[0]), ['d']);
      expect(doc.view.formats, isEmpty);
    });

    test('a peer deleting inside a range shrinks it for everyone', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'hello world'));
      final styled = a.reconcile(
        body: 'hello world',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
      );
      final fromB = type(b, 'ho world');
      a.apply(fromB);
      b.apply(styled);
      expect(a.view.formats, [bold(0, 2)]);
      expect(b.view.formats, [bold(0, 2)]);
    });

    test('passing the rendered formats back emits no register op', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'hello world');
      doc.reconcile(
        body: 'hello world',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
      );
      final ops = doc.reconcile(
        body: 'hello world!',
        formats: doc.view.formats,
        attachments: const [],
        createdAt: created,
      );
      expect(ops.map((op) => (op as List)[0]), ['i']);
    });

    test('an attachment keeps its placeholder under concurrent inserts', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      final body = 'pic:${NoteAttachmentRef.placeholder}\nend';
      b.apply(type(a, body));

      final attached = a.reconcile(
        body: body,
        formats: const [],
        attachments: [image(4)],
        createdAt: created,
      );
      final fromB = type(b, 'new line\n$body');

      a.apply(fromB);
      b.apply(attached);
      expect(a.view.attachments.single.offset, 13);
      expect(b.view.attachments.single.offset, 13);
      expect(b.view.attachments.single.hash, 'abc');
      expect(b.view.attachments.single.mime, 'image/png');
    });

    test('deleting the placeholder drops the attachment', () {
      final doc = NoteDoc(replica: 'a');
      final body = 'a${NoteAttachmentRef.placeholder}b';
      type(doc, body);
      doc.reconcile(
        body: body,
        formats: const [],
        attachments: [image(1)],
        createdAt: created,
      );
      expect(doc.view.attachments, hasLength(1));
      type(doc, 'ab');
      expect(doc.view.attachments, isEmpty);
    });

    test('later register set wins regardless of arrival order', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'hello world'));
      final early = a.reconcile(
        body: 'hello world',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
        now: created,
      );
      final late = b.reconcile(
        body: 'hello world',
        formats: [
          NoteFormatRange(start: 6, end: 11, format: NoteFormat.italic),
        ],
        attachments: const [],
        createdAt: created,
        now: created.add(const Duration(seconds: 1)),
      );
      a.apply(late);
      b.apply(early);
      expect(a.view.formats, b.view.formats);
      expect(a.view.formats.single.format, NoteFormat.italic);
    });
  });

  group('caret anchors', () {
    test('survive inserts before and after', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'hello world'));
      final anchor = a.anchorAt(5);

      a.apply(type(b, 'XX hello world'));
      a.apply(type(b, 'XX hello world YY'));
      expect(a.text, 'XX hello world YY');
      expect(a.offsetOf(anchor), 8);
      expect(a.anchorAt(8), anchor);
    });

    test('a whole-text replacement lands the caret after the new text', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      b.apply(type(a, 'hello'));
      final anchor = a.anchorAt(3);
      a.apply(type(b, 'XYZ'));
      expect(a.text, 'XYZ');
      // Every anchored character is gone; the nearest earlier visible one is
      // the end of the replacement, which is where a backspace would leave it.
      expect(a.offsetOf(anchor), 3);
    });

    test('start anchor and out-of-range offsets', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'abc');
      expect(doc.anchorAt(0), Anchor.start);
      expect(doc.offsetOf(Anchor.start), 0);
      expect(doc.offsetOf(doc.anchorAt(99)), 3);
      expect(doc.offsetOf(const Anchor(NodeId('nobody', 7))), 0);
    });

    test('anchors and formats survive a bulk delete', () {
      final doc = NoteDoc(replica: 'a');
      final body = List.generate(100, (i) => 'row $i').join('\n');
      type(doc, body);
      doc.reconcile(
        body: body,
        formats: [bold(body.length - 6, body.length)],
        attachments: const [],
        createdAt: created,
      );
      final anchor = doc.anchorAt(body.length - 3);

      final cut = body.substring(0, 20) + body.substring(body.length - 40);
      final ops = doc.reconcile(
        body: cut,
        formats: [bold(cut.length - 6, cut.length)],
        attachments: const [],
        createdAt: created,
      );
      expect(ops.map((op) => (op as List)[0]), ['d']);
      expect(doc.text, cut);
      expect(doc.offsetOf(anchor), cut.length - 3);
      expect(doc.view.formats, [bold(cut.length - 6, cut.length)]);

      type(doc, '${cut}tail');
      expect(doc.text, '${cut}tail');
      expect(doc.offsetOf(anchor), cut.length - 3);
      expect(doc.anchorAt(cut.length - 3), anchor);
    });

    test('a deleted anchor falls back to the previous visible char', () {
      final doc = NoteDoc(replica: 'a');
      type(doc, 'abcdef');
      final anchor = doc.anchorAt(4);
      type(doc, 'abf');
      expect(doc.offsetOf(anchor), 2);
      type(doc, 'f');
      expect(doc.offsetOf(anchor), 0);
    });
  });

  group('pending parents', () {
    test('a child arriving first waits for its parent', () {
      final a = NoteDoc(replica: 'a');
      final first = type(a, 'ab');
      final second = type(a, 'abc');
      final third = type(a, 'abcd');

      final b = NoteDoc(replica: 'b');
      expect(b.apply(third), isFalse);
      expect(b.pendingCount, 1);
      expect(b.apply(second), isFalse);
      expect(b.pendingCount, 2);
      expect(b.text, '');

      expect(b.apply(first), isTrue);
      expect(b.pendingCount, 0);
      expect(b.text, 'abcd');
    });

    test('a delete arriving before its insert waits too', () {
      final a = NoteDoc(replica: 'a');
      final insert = type(a, 'abc');
      final delete = type(a, 'ac');

      final b = NoteDoc(replica: 'b');
      b.apply(delete);
      expect(b.pendingCount, 1);
      b.apply(insert);
      expect(b.pendingCount, 0);
      expect(b.text, 'ac');
    });

    test('pending ops ride along in a snapshot', () {
      final a = NoteDoc(replica: 'a');
      final first = type(a, 'ab');
      final second = type(a, 'abc');

      final b = NoteDoc(replica: 'b');
      b.apply(second);
      final c = NoteDoc.fromSnapshot(b.toSnapshot(), replica: 'c');
      expect(c.pendingCount, 1);
      c.apply(first);
      expect(c.text, 'abc');
    });
  });

  group('idempotence', () {
    test('the same batch twice and shuffled changes nothing', () {
      final a = NoteDoc(replica: 'a');
      final log = <Object?>[];
      for (final body in ['h', 'he', 'hel', 'hxl', 'hxl\n', 'hxl\n2']) {
        log.addAll(type(a, body));
      }
      log.addAll(
        a.reconcile(
          body: 'hxl\n2',
          formats: [bold(0, 3)],
          attachments: const [],
          createdAt: created,
        ),
      );

      final b = NoteDoc(replica: 'b');
      expect(b.apply(log), isTrue);
      final before = b.toSnapshot();
      expect(b.apply(log), isFalse);
      expect(b.apply(log.reversed.toList()), isFalse);
      expect(b.toSnapshot(), before);
      expect(b.text, a.text);
      expect(b.view.formats, a.view.formats);
    });

    test('merging a snapshot twice is a no-op', () {
      final a = NoteDoc(replica: 'a');
      type(a, 'one\ntwo');
      type(a, 'one\nthree');
      final b = NoteDoc(replica: 'b');
      expect(b.mergeSnapshot(a.toSnapshot()), isTrue);
      expect(b.mergeSnapshot(a.toSnapshot()), isFalse);
      expect(b.text, a.text);
      expect(b.nodeCount, a.nodeCount);
    });
  });

  group('snapshots', () {
    test('round trip preserves nodes, tombstones and registers', () {
      final a = NoteDoc(replica: 'a');
      type(a, 'hello world');
      type(a, 'hello, world');
      type(a, 'hello, wrld');
      a.reconcile(
        body: 'hello, wrld',
        formats: [bold(0, 5)],
        attachments: const [],
        createdAt: created,
      );
      final snapshot = a.toSnapshot();
      final b = NoteDoc.fromSnapshot(snapshot, replica: 'b');
      expect(b.text, a.text);
      expect(b.nodeCount, a.nodeCount);
      expect(b.view.formats, a.view.formats);
      expect(b.view.createdAt, created);
      expect(b.toSnapshot(), snapshot);
    });

    test('typed runs coalesce into one snapshot run', () {
      final a = NoteDoc(replica: 'a');
      for (var i = 1; i <= 5; i++) {
        type(a, 'abcde'.substring(0, i));
      }
      final nodes = a.toSnapshot()['nodes'] as List;
      expect(nodes, hasLength(1));
      expect((nodes.single as List)[5], 'abcde');
    });

    test('rejects an unknown version', () {
      expect(
        () => NoteDoc.fromSnapshot({'v': 99}, replica: 'a'),
        throwsFormatException,
      );
    });
  });
}
