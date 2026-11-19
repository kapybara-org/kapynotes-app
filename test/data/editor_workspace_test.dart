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

/// Any day will do: the workspace only compares them.
const _today = 20411;

EditorWorkspace _opened(
  String first, {
  LocalStore? store,
  List<String> available = _notes,
}) =>
    EditorWorkspace(store ?? _MemoryStore())
      ..load(availableNoteIds: available, today: _today, openingNoteId: first);

EditorWorkspace _restored(LocalStore store, {int today = _today}) =>
    EditorWorkspace(store)..load(availableNoteIds: _notes, today: today);

/// Three panes, alpha to charlie, the last one focused.
EditorWorkspace _threeOpen({LocalStore? store}) =>
    _opened('alpha', store: store)
      ..drop('bravo', 0, PaneDropZone.right)
      ..drop('charlie', 1, PaneDropZone.right);

List<String?> _notesIn(EditorWorkspace workspace) => [
  for (final pane in workspace.panes) pane.noteId,
];

/// Each tab's notes, left to right, in the order the row shows the tabs.
List<List<String>> _tabsOf(EditorWorkspace workspace) => [
  for (final tab in workspace.tabs) tab.noteIds,
];

/// The note each tab goes by, most recently used first.
List<String> _recent(EditorWorkspace workspace) => [
  for (final tab in workspace.recentTabs) tab.noteId,
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
    expect(_tabsOf(startingElsewhere), [
      ['alpha', 'bravo', 'charlie'],
      ['delta'],
    ], reason: 'the startup note opens in a tab of its own');
    expect(startingElsewhere.selectedNoteId, 'delta');
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
  group('tabs', () {
    test(
      'a note opens in a new tab behind the one in front, and only once',
      () {
        final workspace = _opened('alpha');
        expect(workspace.openInNewTab('bravo'), isTrue);
        expect(_tabsOf(workspace), [
          ['alpha'],
          ['bravo'],
        ]);
        expect(workspace.selectedNoteId, 'alpha');
        expect(workspace.openInNewTab('bravo'), isFalse);
        expect(workspace.openInNewTab('alpha'), isFalse);

        expect(workspace.open('bravo'), isTrue);
        expect(
          workspace.frontTabIndex,
          1,
          reason: 'a note open in another tab comes forward there',
        );
        expect(_tabsOf(workspace), [
          ['alpha'],
          ['bravo'],
        ]);
      },
    );

    test('a plain open replaces the note in front, and no other', () {
      final workspace = _opened('alpha')
        ..openInNewTab('bravo')
        ..open('charlie');
      expect(_tabsOf(workspace), [
        ['charlie'],
        ['bravo'],
      ]);
      expect(workspace.selectedNoteId, 'charlie');
    });

    test('Back and Forward walk the notes in the order they were shown', () {
      final workspace = _opened('alpha')
        ..open('bravo')
        ..openInNewTab('charlie')
        ..activateTab(1);

      expect(workspace.back(), isTrue);
      expect(workspace.selectedNoteId, 'bravo');
      expect(
        workspace.frontTabIndex,
        0,
        reason: 'a note with a tab is shown in it',
      );

      expect(workspace.back(), isTrue);
      expect(workspace.selectedNoteId, 'alpha');
      expect(_tabsOf(workspace), [
        ['alpha'],
        ['charlie'],
      ], reason: 'one without comes back in the tab in front');
      expect(workspace.canGoBack, isFalse);

      expect(workspace.forward(), isTrue);
      expect(workspace.selectedNoteId, 'bravo');

      workspace.open('delta');
      expect(
        workspace.canGoForward,
        isFalse,
        reason: 'opening a note ends the walk where it stood',
      );
      expect(workspace.back(), isTrue);
      expect(workspace.selectedNoteId, 'bravo');
    });

    test('closing the tab in front hands it to the tab used before', () {
      final workspace = _opened('alpha')
        ..openInNewTab('bravo')
        ..openInNewTab('charlie')
        ..activateTab(2)
        ..activateTab(1);

      expect(workspace.closeTab(1), isTrue);
      expect(_tabsOf(workspace), [
        ['alpha'],
        ['charlie'],
      ]);
      expect(workspace.selectedNoteId, 'charlie');

      expect(workspace.closeTab(0), isTrue);
      expect(
        workspace.selectedNoteId,
        'charlie',
        reason: 'a tab behind closes without moving anything',
      );

      expect(workspace.closeTab(0), isTrue);
      expect(workspace.tabs, isEmpty);
      expect(workspace.panes, isEmpty);
      expect(workspace.selectedNoteId, isNull);
      expect(workspace.recentlyClosed, [
        ['charlie'],
        ['alpha'],
        ['bravo'],
      ]);
      expect(workspace.closeTab(0), isFalse);
    });

    test('closed tabs reopen, the last first, side by side as they were', () {
      final workspace = _opened('alpha')
        ..openToSide('bravo')
        ..openInNewTab('charlie')
        ..closeTab(0);
      expect(workspace.recentlyClosed, [
        ['alpha', 'bravo'],
      ]);
      expect(workspace.selectedNoteId, 'charlie');

      expect(workspace.reopen(), 'alpha');
      expect(_notesIn(workspace), ['alpha', 'bravo']);
      expect(_tabsOf(workspace), [
        ['charlie'],
        ['alpha', 'bravo'],
      ]);
      expect(workspace.reopen(), isNull);
    });

    test('a closed note opened again is no longer among the closed ones', () {
      final workspace = _opened('alpha')
        ..openInNewTab('bravo')
        ..closeTab(1);
      expect(workspace.recentlyClosed, [
        ['bravo'],
      ]);

      workspace.openInNewTab('bravo');
      expect(workspace.recentlyClosed, isEmpty);
      expect(workspace.reopen(), isNull);
    });

    test(
      'Close other tabs keeps the last twenty, most recently used first',
      () {
        final ids = [for (var index = 0; index < 25; index++) 'note-$index'];
        final workspace = _opened(ids.first, available: ids);
        for (final id in ids.skip(1)) {
          workspace
            ..openInNewTab(id)
            ..activateTab(workspace.tabs.length - 1);
        }

        workspace.closeOthers(workspace.frontTabIndex);
        expect(_tabsOf(workspace), [
          [ids.last],
        ]);
        expect(
          workspace.recentlyClosed,
          hasLength(EditorWorkspace.closedLimit),
        );
        expect(workspace.recentlyClosed.first, [ids[23]]);
        expect(workspace.recentlyClosed.last, [ids[4]]);
      },
    );

    test('a held-key switch counts only the note it ends on', () {
      final store = _MemoryStore();
      final workspace = _opened('alpha', store: store)
        ..openInNewTab('bravo')
        ..openInNewTab('charlie');
      expect(_recent(workspace), ['alpha', 'charlie', 'bravo']);

      final session = workspace.beginPreviewSession();
      expect(session.displacedBy('delta'), {'alpha'});
      expect(session.preview('delta'), isTrue);
      expect(_tabsOf(workspace), [
        ['delta'],
        ['bravo'],
        ['charlie'],
      ]);
      expect(session.displacedBy('charlie'), {'delta'});
      expect(session.preview('charlie'), isTrue);
      expect(_tabsOf(workspace), [
        ['alpha'],
        ['bravo'],
        ['charlie'],
      ], reason: 'a step starts from how the walk found the tabs');
      expect(workspace.selectedNoteId, 'charlie');
      expect(session.displacedBy('charlie'), isEmpty);
      expect(session.displacedBy('bravo'), {'charlie'});
      expect(session.preview('bravo'), isTrue);
      expect(_recent(workspace), ['alpha', 'charlie', 'bravo']);
      expect(
        (store.data[EditorWorkspace.storeKey] as Map)['tab'],
        0,
        reason: 'a step is not written down',
      );

      expect(session.commit(), isTrue);
      expect(session.isActive, isFalse);
      expect(_recent(workspace), ['bravo', 'alpha', 'charlie']);
      expect((store.data[EditorWorkspace.storeKey] as Map)['tab'], 1);
    });

    test('cancelling a held-key switch puts every tab back', () {
      final workspace = _opened('alpha')..openInNewTab('bravo');
      final session = workspace.beginPreviewSession()..preview('charlie');
      expect(workspace.selectedNoteId, 'charlie');

      expect(session.cancel(), isTrue);
      expect(_tabsOf(workspace), [
        ['alpha'],
        ['bravo'],
      ]);
      expect(workspace.selectedNoteId, 'alpha');
      expect(session.preview('bravo'), isFalse);
    });

    test('notes open to the side share one tab, which keeps them', () {
      final workspace = _opened('alpha')..openToSide('bravo');
      expect(_tabsOf(workspace), [
        ['alpha', 'bravo'],
      ]);

      workspace
        ..openInNewTab('charlie')
        ..activateTab(1);
      expect(_notesIn(workspace), ['charlie']);

      workspace.activateTab(0);
      expect(_notesIn(workspace), ['alpha', 'bravo']);
      expect(workspace.activePane, 1);
    });

    test('a note moves beside the one in front from the tab it was in', () {
      final workspace = _opened('alpha')
        ..openInNewTab('bravo')
        ..openToSide('bravo');
      expect(_tabsOf(workspace), [
        ['alpha', 'bravo'],
      ], reason: 'a tab left with nothing closes');
      expect(workspace.recentlyClosed, isEmpty);
    });

    test('closing the pane of a tab\'s last note closes the tab', () {
      final workspace = _opened('alpha')
        ..openInNewTab('bravo')
        ..split();

      expect(workspace.close(0), isTrue);
      expect(_tabsOf(workspace), [
        ['bravo'],
      ]);
      expect(workspace.recentlyClosed, [
        ['alpha'],
      ]);
    });

    test('notes that go away leave the tabs, the closed ones and Back', () {
      final workspace = _opened('alpha')
        ..open('bravo')
        ..openToSide('charlie')
        ..openInNewTab('delta')
        ..closeTab(1);

      workspace.reconcile(['alpha', 'bravo']);
      expect(_tabsOf(workspace), [
        ['bravo'],
      ]);
      expect(workspace.recentlyClosed, isEmpty);
      expect(workspace.back(), isTrue);
      expect(workspace.selectedNoteId, 'alpha');
    });

    test('an empty row takes the fallback, or else the first note', () {
      final workspace = _opened('alpha')..closeTab(0);

      expect(workspace.reconcile(_notes, fallbackId: 'bravo'), isTrue);
      expect(_tabsOf(workspace), [
        ['bravo'],
      ]);

      workspace.closeTab(0);
      expect(workspace.reconcile(_notes, fallbackId: 'gone'), isTrue);
      expect(_tabsOf(workspace), [
        ['alpha'],
      ]);

      workspace
        ..closeTab(0)
        ..reconcile(const <String>[]);
      expect(workspace.tabs, isEmpty);
    });

    test('tabs, their panes and the closed ones survive a restart', () {
      final store = _MemoryStore();
      _opened('alpha', store: store)
        ..openToSide('bravo')
        ..openInNewTab('charlie')
        ..openInNewTab('delta')
        ..closeTab(2)
        ..activateTab(1)
        ..draft = 'charlie';

      final restored = _restored(store);
      expect(_tabsOf(restored), [
        ['alpha', 'bravo'],
        ['charlie'],
      ]);
      expect(restored.selectedNoteId, 'charlie');
      expect(_recent(restored), ['charlie', 'bravo']);
      expect(restored.recentlyClosed, [
        ['delta'],
      ]);
      expect(restored.draft, 'charlie');
      expect(restored.rollOver(_today), isNull);

      restored.activateTab(0);
      expect(restored.activePane, 1);
      restored.closeTab(1);
      expect(restored.draft, isNull, reason: 'the draft went with its tab');
    });

    test('a new day closes the tabs into Recently closed', () {
      final store = _MemoryStore();
      final workspace = _opened('alpha', store: store)
        ..openToSide('bravo')
        ..openInNewTab('charlie')
        ..activateTab(1);
      expect(workspace.rollOver(_today), isNull);

      expect(workspace.rollOver(_today + 1), ['charlie', 'alpha', 'bravo']);
      expect(workspace.tabs, isEmpty);
      expect(workspace.panes, isEmpty);
      expect(workspace.canGoBack, isFalse);
      expect(workspace.recentlyClosed, [
        ['charlie'],
        ['alpha', 'bravo'],
      ]);
      expect(workspace.rollOver(_today + 1), isNull);

      final restored = _restored(store, today: _today + 1);
      expect(_tabsOf(restored), [
        ['alpha'],
      ], reason: 'a fresh row starts somewhere');
      expect(restored.recentlyClosed, [
        ['charlie'],
        ['bravo'],
      ]);
      expect(restored.rollOver(_today + 1), isNull);
    });

    test('a file from before tabs is one tab, for today', () {
      final store = _MemoryStore()
        ..data[EditorWorkspace.storeKey] = {
          'panes': ['bravo', 'alpha'],
          'weights': [0.5, 0.5],
          'active': 'alpha',
        };

      final restored = _restored(store);
      expect(_tabsOf(restored), [
        ['bravo', 'alpha'],
      ]);
      expect(restored.selectedNoteId, 'alpha');
      expect(restored.rollOver(_today), isNull);
    });
  });
}
