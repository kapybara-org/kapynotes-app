import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/editor_workspace.dart';
import 'package:kapy_notes/data/local_store.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'editor-workspace-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _notes = ['alpha', 'bravo', 'charlie', 'delta'];

EditorWorkspace _opened(
  String first, {
  LocalStore? store,
  List<String> available = _notes,
}) =>
    EditorWorkspace(store ?? _MemoryStore())
      ..load(availableNoteIds: available, openingNoteId: first);

/// Three panes, alpha to charlie, the last one focused.
EditorWorkspace _threeOpen({LocalStore? store}) =>
    _opened('alpha', store: store)
      ..drop('bravo', 0, PaneDropZone.right)
      ..drop('charlie', 1, PaneDropZone.right);

List<String?> _notesIn(EditorWorkspace workspace) => [
  for (final pane in workspace.panes) pane.noteId,
];

void _expectEven(EditorWorkspace workspace) {
  for (final weight in workspace.weights) {
    expect(weight, closeTo(1 / workspace.paneCount, 1e-9));
  }
}

void main() {
  test('a note opens in the focused pane, and one already open is focused', () {
    final workspace = _opened('alpha');
    expect(_notesIn(workspace), ['alpha']);

    workspace.open('bravo');
    expect(_notesIn(workspace), [
      'bravo',
    ], reason: 'a pane holds one note, so nothing piles up behind it');

    workspace.openToSide('charlie');
    expect(_notesIn(workspace), ['bravo', 'charlie']);
    expect(workspace.activePane, 1);

    expect(workspace.open('bravo'), isTrue);
    expect(_notesIn(workspace), [
      'bravo',
      'charlie',
    ], reason: 'a note is never open twice');
    expect(workspace.activePane, 0);
    expect(workspace.open('bravo'), isFalse);
  });

  test('splitting opens an empty pane beside the focused one, up to three', () {
    final workspace = _opened('alpha');
    expect(workspace.split(), isTrue);
    expect(_notesIn(workspace), ['alpha', null]);
    expect(workspace.activePane, 1);
    expect(workspace.selectedNoteId, isNull);
    expect(workspace.canSplit, isFalse, reason: 'not beside an empty pane');
    expect(workspace.split(), isFalse);

    workspace.open('bravo');
    expect(_notesIn(workspace), ['alpha', 'bravo']);
    expect(workspace.weights, [0.5, 0.5]);

    workspace
      ..activate(0)
      ..split()
      ..open('charlie');
    expect(_notesIn(workspace), ['alpha', 'charlie', 'bravo']);
    _expectEven(workspace);
    expect(workspace.canSplit, isFalse);
    expect(workspace.split(), isFalse);
  });

  test(
    'open to the side fills an empty pane, adds one, then uses a neighbour',
    () {
      final workspace = _opened('alpha')
        ..split()
        ..activate(0);

      workspace.openToSide('bravo');
      expect(_notesIn(workspace), ['alpha', 'bravo']);

      workspace.openToSide('charlie');
      expect(_notesIn(workspace), ['alpha', 'bravo', 'charlie']);
      expect(workspace.activePane, 2);

      workspace.openToSide('delta');
      expect(
        _notesIn(workspace),
        ['alpha', 'delta', 'charlie'],
        reason: 'the last pane has nothing to its right, so its left takes it',
      );
      expect(workspace.activePane, 1);
    },
  );

  group('dropping a note', () {
    test('beside a pane opens a new one there, and the row shares out', () {
      final workspace = _opened('alpha');
      expect(
        workspace.planDrop('bravo', 0, PaneDropZone.right),
        const PaneDropPlan(PaneDropAction.insert, PaneDropZone.right),
      );

      workspace.drop('bravo', 0, PaneDropZone.right);
      expect(_notesIn(workspace), ['alpha', 'bravo']);

      workspace.drop('charlie', 0, PaneDropZone.left);
      expect(_notesIn(workspace), ['charlie', 'alpha', 'bravo']);
      expect(workspace.activePane, 0);
      _expectEven(workspace);
    });

    test('with three open, an edge means the pane itself', () {
      final workspace = _threeOpen();
      expect(
        workspace.planDrop('delta', 1, PaneDropZone.left),
        const PaneDropPlan(PaneDropAction.replace, PaneDropZone.center),
      );

      workspace.drop('delta', 1, PaneDropZone.left);
      expect(_notesIn(workspace), ['alpha', 'delta', 'charlie']);
      expect(workspace.activePane, 1);
    });

    test('a note already open swaps, moves, or moves into an empty pane', () {
      final workspace = _threeOpen();

      expect(
        workspace.planDrop('charlie', 0, PaneDropZone.center)?.action,
        PaneDropAction.swap,
      );
      workspace.drop('charlie', 0, PaneDropZone.center);
      expect(_notesIn(workspace), ['charlie', 'bravo', 'alpha']);

      workspace.drop('alpha', 0, PaneDropZone.left);
      expect(_notesIn(workspace), ['alpha', 'charlie', 'bravo']);
      expect(workspace.activePane, 0);

      workspace
        ..close(2)
        ..activate(1)
        ..split();
      expect(_notesIn(workspace), ['alpha', 'charlie', null]);
      expect(
        workspace.planDrop('alpha', 2, PaneDropZone.center)?.action,
        PaneDropAction.move,
      );
      workspace.drop('alpha', 2, PaneDropZone.center);
      expect(_notesIn(workspace), ['charlie', 'alpha']);
      expect(workspace.selectedNoteId, 'alpha');
    });

    test('is refused where it would leave the panes as they are', () {
      final workspace = _opened('alpha')..drop('bravo', 0, PaneDropZone.right);

      expect(workspace.planDrop('alpha', 0, PaneDropZone.center), isNull);
      expect(workspace.planDrop('alpha', 0, PaneDropZone.right), isNull);
      expect(
        workspace.planDrop('alpha', 1, PaneDropZone.left),
        isNull,
        reason: 'it is already on the left of that pane',
      );
      expect(
        workspace.planDrop('alpha', 1, PaneDropZone.right)?.action,
        PaneDropAction.move,
      );
      expect(workspace.drop('alpha', 0, PaneDropZone.center), isFalse);
    });
  });

  test('closing a pane shares its room out and hands the focus on', () {
    final workspace = _threeOpen()..weights = [0.5, 0.3, 0.2];

    workspace.activate(1);
    expect(workspace.close(1), isTrue);
    expect(_notesIn(workspace), ['alpha', 'charlie']);
    expect(workspace.weights, [0.5, 0.5]);
    expect(workspace.selectedNoteId, 'alpha');

    workspace.close(0);
    expect(_notesIn(workspace), ['charlie']);
    expect(workspace.weights, [1.0]);
    expect(
      workspace.close(0),
      isFalse,
      reason: 'there is always a pane to write in',
    );
  });

  test('a preview session switches every note from one stable pane layout', () {
    final store = _MemoryStore();
    final workspace = _opened('alpha', store: store)
      ..openToSide('bravo')
      ..activate(0);
    final preview = workspace.beginPreviewSession();

    expect(preview.preview('bravo'), isTrue);
    expect(_notesIn(workspace), ['alpha', 'bravo']);
    expect(workspace.activePane, 1);

    expect(preview.displacedBy('charlie'), 'alpha');
    expect(preview.preview('charlie'), isTrue);
    expect(_notesIn(workspace), ['charlie', 'bravo']);
    expect(workspace.activePane, 0);
    expect((store.data[EditorWorkspace.storeKey] as Map)['panes'], [
      'alpha',
      'bravo',
    ], reason: 'a transient preview is not the restorable workspace yet');

    expect(preview.preview('alpha'), isTrue);
    expect(_notesIn(workspace), ['alpha', 'bravo']);
    expect(workspace.activePane, 0);

    expect(preview.preview('charlie'), isTrue);
    expect(preview.commit(), isTrue);
    expect(preview.isActive, isFalse);
    expect(_notesIn(workspace), ['charlie', 'bravo']);
    expect((store.data[EditorWorkspace.storeKey] as Map)['panes'], [
      'charlie',
      'bravo',
    ]);
  });

  test('canceling a preview restores notes, focus, and widths', () {
    final workspace = _opened('alpha')
      ..openToSide('bravo')
      ..weights = [0.6, 0.4]
      ..activate(0);
    final preview = workspace.beginPreviewSession();

    preview.preview('charlie');
    expect(_notesIn(workspace), ['charlie', 'bravo']);
    expect(preview.cancel(), isTrue);

    expect(_notesIn(workspace), ['alpha', 'bravo']);
    expect(workspace.activePane, 0);
    expect(workspace.weights, [0.6, 0.4]);
    expect(preview.preview('delta'), isFalse);
  });

  test('a three-pane preview only replaces its original active pane', () {
    final workspace = _threeOpen()..activate(1);
    final preview = workspace.beginPreviewSession();

    preview.preview('alpha');
    expect(_notesIn(workspace), ['alpha', 'bravo', 'charlie']);
    expect(workspace.activePane, 0);

    preview.preview('delta');
    expect(_notesIn(workspace), ['alpha', 'delta', 'charlie']);
    expect(workspace.activePane, 1);
    preview.commit();
  });

  test(
    'a note that goes away closes its pane, and the last one falls back',
    () {
      final workspace = _threeOpen();

      workspace.reconcile(['alpha', 'charlie', 'delta']);
      expect(_notesIn(workspace), ['alpha', 'charlie']);
      expect(workspace.selectedNoteId, 'charlie');

      workspace.reconcile(['delta'], fallbackId: 'delta');
      expect(_notesIn(workspace), ['delta']);
    },
  );

  test('an empty pane is left waiting when other notes change', () {
    final workspace = _opened('alpha')..split();

    workspace.reconcile(_notes, fallbackId: 'bravo');
    expect(_notesIn(workspace), ['alpha', null]);
  });

  test('panes, focus and widths survive a restart', () {
    final store = _MemoryStore();
    _threeOpen(store: store)
      ..weights = [0.2, 0.3, 0.5]
      ..activate(1);

    final restored = _opened('bravo', store: store);
    expect(_notesIn(restored), ['alpha', 'bravo', 'charlie']);
    expect(restored.activePane, 1);
    for (final (index, weight) in [0.2, 0.3, 0.5].indexed) {
      expect(restored.weights[index], closeTo(weight, 1e-9));
    }

    final startingElsewhere = _opened('delta', store: store);
    expect(_notesIn(startingElsewhere), [
      'alpha',
      'delta',
      'charlie',
    ], reason: 'the startup note takes the focused pane');
  });

  test('a restart drops empty panes and notes that are gone', () {
    final store = _MemoryStore();
    _threeOpen(store: store)
      ..close(2)
      ..activate(0)
      ..split();

    final restored = _opened(
      'alpha',
      store: store,
      available: ['alpha', 'charlie'],
    );
    expect(_notesIn(restored), ['alpha']);
    expect(restored.weights, [1.0]);
  });
}
