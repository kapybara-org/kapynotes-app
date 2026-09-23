import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/crdt/crdt.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_drawing.dart';

import '../crdt/helpers.dart';

DrawElement stroke(String id, {int z = 0, double x = 0}) => DrawElement(
  id: id,
  kind: DrawKind.pen,
  points: [x, 0, x + 10.04, 5, x + 20, 10],
  z: z,
);

DrawElement box(String id, {int z = 0, int? color}) => DrawElement(
  id: id,
  kind: DrawKind.rect,
  points: const [0, 0, 40, 30],
  z: z,
  color: color,
  width: 4,
);

/// Reconciles [drawing] into [doc], keeping the text and side tables.
List<Object?> draw(NoteDoc doc, NoteDrawing? drawing, {int at = 0}) {
  final view = doc.view;
  return doc.reconcile(
    body: view.body,
    formats: view.formats,
    attachments: view.attachments,
    drawing: drawing,
    createdAt: view.createdAt ?? created,
    now: created.add(Duration(milliseconds: at)),
  );
}

void main() {
  group('NoteDrawing', () {
    test('round-trips through JSON, rounding coordinates to a tenth', () {
      final drawing = NoteDrawing([
        stroke('a'),
        box('b', z: 1, color: 0xFFE03131),
        DrawElement(
          id: 'c',
          kind: DrawKind.text,
          points: const [5, 6],
          z: 2,
          text: 'hello',
          fontSize: 24,
        ),
      ]);
      final back = NoteDrawing.fromJson(
        jsonDecode(jsonEncode(drawing.toJson())),
      )!;
      expect(back, drawing);
      expect(back.byId('a')!.points[2], closeTo(10.0, 1e-9));
      expect(back.byId('c')!.text, 'hello');
      expect(back.byId('b')!.color, 0xFFE03131);
    });

    test('stacks by z, then by id', () {
      final drawing = NoteDrawing([
        stroke('b', z: 1),
        stroke('a', z: 1),
        stroke('c'),
      ]);
      expect(drawing.elements.map((e) => e.id), ['c', 'a', 'b']);
      expect(drawing.nextZ, 2);
    });

    test('skips elements of kinds this build does not know', () {
      final back = NoteDrawing.fromJson({
        'elements': [
          {
            'id': 'x',
            'k': 'hexagon',
            'p': [0, 0, 1, 1],
            'z': 0,
          },
          {
            'id': 'y',
            'k': 'line',
            'p': [0, 0, 1, 1],
            'z': 0,
          },
        ],
      })!;
      expect(back.elements.map((e) => e.id), ['y']);
    });
  });

  group('Note', () {
    test('a drawing is titled by its body, or "Drawing"', () {
      final at = DateTime(2026, 9, 23);
      final blank = Note(
        id: 'n',
        body: '',
        drawing: NoteDrawing.empty,
        createdAt: at,
        updatedAt: at,
      );
      expect(blank.title, 'Drawing');
      expect(blank.isEmpty, isTrue);
      expect(blank.copyWith(body: 'Floor plan').title, 'Floor plan');

      final drawn = blank.copyWith(drawing: NoteDrawing([stroke('a')]));
      expect(drawn.isEmpty, isFalse);

      final back = Note.fromJson(jsonDecode(jsonEncode(drawn.toJson())))!;
      expect(back.drawing, drawn.drawing);
      expect(back.markSynced(at).drawing, drawn.drawing);
      expect(back.copyWith(drawing: null).isDrawing, isFalse);
    });

    test('a written note stays byte-identical on disk', () {
      final at = DateTime(2026, 9, 23);
      final note = Note(id: 'n', body: 'hi', createdAt: at, updatedAt: at);
      expect(note.toJson().containsKey('drawing'), isFalse);
      expect(Note.fromJson(note.toJson())!.drawing, isNull);
    });
  });

  group('NoteDoc', () {
    test('a text note renders no drawing and emits no drawing ops', () {
      final doc = NoteDoc(replica: 'a');
      final ops = type(doc, 'hello');
      expect(doc.view.drawing, isNull);
      expect(
        ops.where((op) => (op as List)[0] == 'r' && op[1] != 'created'),
        isEmpty,
      );
    });

    test('an element is one register, and only a change writes it', () {
      final doc = NoteDoc(replica: 'a');
      draw(doc, NoteDrawing.empty);
      expect(doc.view.drawing, NoteDrawing.empty);

      final ops = draw(doc, NoteDrawing([stroke('s1')]), at: 1);
      expect(ops, hasLength(1));
      expect((ops.single as List)[1], 'e:s1');
      expect(draw(doc, doc.view.drawing, at: 2), isEmpty);

      final moved = draw(
        doc,
        NoteDrawing([stroke('s1', x: 50), box('b1')]),
        at: 3,
      );
      expect(moved.map((op) => (op as List)[1]).toSet(), {'e:s1', 'e:b1'});

      final erased = draw(doc, NoteDrawing([box('b1')]), at: 4);
      expect(erased.single, containsAllInOrder(['r', 'e:s1', null]));
      expect(doc.view.drawing!.elements.map((e) => e.id), ['b1']);
    });

    test('two devices drawing at once keep both strokes', () {
      final a = NoteDoc(replica: 'a');
      final b = NoteDoc(replica: 'b');
      broadcast([a, b], a, draw(a, NoteDrawing.empty));

      final fromA = draw(a, NoteDrawing([stroke('from-a')]), at: 1);
      final fromB = draw(b, NoteDrawing([box('from-b')]), at: 1);
      broadcast([a, b], a, fromA);
      broadcast([a, b], b, fromB);

      expect(a.view.drawing, b.view.drawing);
      expect(a.view.drawing!.elements.map((e) => e.id).toSet(), {
        'from-a',
        'from-b',
      });
    });

    test('a drawing survives a snapshot, and a doc that only types', () {
      final a = NoteDoc(replica: 'a');
      draw(a, NoteDrawing([stroke('s1'), box('b1', z: 1)]));
      final restored = NoteDoc.fromSnapshot(
        jsonDecode(jsonEncode(a.toSnapshot())) as Map<String, Object?>,
        replica: 'c',
      );
      expect(restored.view.drawing, a.view.drawing);

      // What a build from before drawings does: reconcile text, formats and
      // attachments, and never mention the canvas.
      final old = NoteDoc.fromSnapshot(a.toSnapshot(), replica: 'old');
      final view = old.view;
      final ops = old.reconcile(
        body: 'Floor plan',
        formats: view.formats,
        attachments: view.attachments,
        drawing: view.drawing,
        createdAt: view.createdAt ?? created,
        now: created,
      );
      a.apply(ops);
      expect(a.view.body, 'Floor plan');
      expect(a.view.drawing!.elements, hasLength(2));
    });

    test('switching back to writing clears the flag', () {
      final doc = NoteDoc(replica: 'a');
      draw(doc, NoteDrawing.empty);
      draw(doc, null, at: 1);
      expect(doc.view.drawing, isNull);
    });
  });
}
