import 'dart:io';

import 'package:flutter/rendering.dart' show RenderAnimatedOpacity;
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/sync/sync_service.dart' show SyncStatus;
import 'package:kapy_notes/ui/save_status.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

void main() {
  final label = find.byType(SaveStatusLabel);
  Finder says(String text) =>
      find.descendant(of: label, matching: find.text(text));

  Widget harness(SaveState state) => MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: Center(
        child: SaveStatusLabel(state, style: const TextStyle(fontSize: 12)),
      ),
    ),
  );

  /// Builds the label over a real store's writes, as the page has it, and
  /// takes it down before the status goes.
  Future<(LocalStore, SaveStatus)> pumpStatus(
    WidgetTester tester, {
    SaveNotice? problem,
  }) async {
    final store = LocalStore(fileName: 'unused.json');
    final status = SaveStatus(store.writes);
    addTearDown(() {
      status.dispose();
      store.dispose();
    });
    await tester.pumpWidget(harness((status: status, problem: problem)));
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return (store, status);
  }

  /// What the label says now, or null when it says nothing.
  String? shown(WidgetTester tester) {
    final texts = find.descendant(of: label, matching: find.byType(Text));
    return texts.evaluate().isEmpty ? null : tester.widget<Text>(texts).data;
  }

  double opacity(WidgetTester tester) => tester
      .renderObject<RenderAnimatedOpacity>(
        find.descendant(of: label, matching: find.byType(AnimatedOpacity)),
      )
      .opacity
      .value;

  testWidgets('at rest it says nothing, and a write nobody typed, such as '
      'a note from another device, says nothing either', (tester) async {
    final (store, _) = await pumpStatus(tester);
    expect(shown(tester), isNull);

    store.put('notes', 'from another device');
    await tester.pump();
    expect(store.writes.value, StoreWrite.pending);
    expect(shown(tester), isNull);
    await tester.pump(const Duration(seconds: 5));
    expect(store.writes.value, StoreWrite.written);
    expect(shown(tester), isNull);
  });

  testWidgets('an edit says "Saving…" at once, "Saved" once it settles, for '
      'two seconds, then fades over 300 ms and goes', (tester) async {
    final (store, status) = await pumpStatus(tester);
    store.put('notes', 'a');
    status.edited();
    await tester.pump();
    expect(shown(tester), 'Saving…');

    // Written after 250 ms, but "Saving…" holds until a second has passed
    // with no edit.
    await tester.pump(const Duration(milliseconds: 300));
    expect(store.writes.value, StoreWrite.written);
    expect(shown(tester), 'Saving…');
    await tester.pump(const Duration(milliseconds: 700));
    expect(shown(tester), 'Saved');
    expect(opacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 1990));
    expect(shown(tester), 'Saved');
    expect(opacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 10));
    expect(status.phase, SavePhase.fading);
    await tester.pump(const Duration(milliseconds: 150));
    expect(shown(tester), 'Saved');
    expect(opacity(tester), inExclusiveRange(0, 1));

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(status.phase, SavePhase.rest);
    expect(shown(tester), isNull);
  });

  testWidgets('steady typing reads as one save: "Saving…" the whole time, '
      'then "Saved" once, never flipping between words', (tester) async {
    final (store, status) = await pumpStatus(tester);
    final seen = <String?>[];
    void look() {
      final now = shown(tester);
      if (seen.isEmpty || seen.last != now) seen.add(now);
    }

    look();
    var written = 0;
    store.writes.addListener(() {
      if (store.writes.value == StoreWrite.written) written++;
    });
    // Eight words of five keystrokes 150 ms apart, with a 450 ms pause after
    // each word: long enough for the store to write between words.
    for (var word = 0; word < 8; word++) {
      for (var key = 0; key < 5; key++) {
        store.put('notes', 'word $word key $key');
        status.edited();
        for (var tick = 0; tick < 15; tick++) {
          await tester.pump(const Duration(milliseconds: 10));
          look();
        }
      }
      for (var tick = 0; tick < 30; tick++) {
        await tester.pump(const Duration(milliseconds: 10));
        look();
      }
    }
    expect(written, greaterThanOrEqualTo(8));
    expect(seen, [null, 'Saving…']);

    for (var tick = 0; tick < 400; tick++) {
      await tester.pump(const Duration(milliseconds: 10));
      look();
    }
    expect(seen, [null, 'Saving…', 'Saved', null]);
  });

  testWidgets('an edit while "Saved" shows goes straight back to '
      '"Saving…"', (tester) async {
    final (store, status) = await pumpStatus(tester);
    store.put('notes', 'a');
    status.edited();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(shown(tester), 'Saved');

    store.put('notes', 'ab');
    status.edited();
    await tester.pump();
    expect(shown(tester), 'Saving…');
    expect(opacity(tester), 1);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets("a write the disk refuses says \"Couldn't save\" until a retry "
      'lands, then "Saved"', (tester) async {
    final writes = ValueNotifier(StoreWrite.written);
    final status = SaveStatus(writes);
    addTearDown(status.dispose);
    await tester.pumpWidget(harness((status: status, problem: null)));
    addTearDown(() => tester.pumpWidget(const SizedBox()));

    status.edited();
    writes.value = StoreWrite.pending;
    await tester.pump();
    writes.value = StoreWrite.failed;
    await tester.pump();
    expect(shown(tester), "Couldn't save");
    expect(
      find.byTooltip(
        "Couldn't save on this device. It tries again in a few seconds.",
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: label,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is KapyIcon && widget.icon == KapyIcons.cloudOffRounded,
        ),
      ),
      findsOneWidget,
    );

    await tester.pump(const Duration(minutes: 1));
    status.edited();
    await tester.pump(const Duration(seconds: 5));
    expect(shown(tester), "Couldn't save");

    writes.value = StoreWrite.written;
    await tester.pump();
    expect(shown(tester), 'Saved');
    await tester.pump(const Duration(milliseconds: 2400));
    expect(shown(tester), isNull);
  });

  group('a problem in the way of sync stays until it clears', () {
    final cases = <String, (SaveNotice?, String, String)>{
      'offline': (
        syncProblem(SyncStatus.offline),
        'Offline',
        'Saved on this device. It syncs once you are back online.',
      ),
      'paused for want of Pro': (
        syncProblem(SyncStatus.idle, paused: true),
        'Sync paused',
        'Saved on this device. Upgrade to Pro to sync it again.',
      ),
      'signed out by the server': (
        syncProblem(null, signInAgain: true),
        'Signed out',
        'Saved on this device. Sign in again to keep syncing.',
      ),
      'a passphrase reset elsewhere': (
        syncProblem(SyncStatus.keysChanged),
        'Not syncing',
        'Saved on this device. It syncs once you enter your new passphrase.',
      ),
      'locked': (
        syncProblem(SyncStatus.locked),
        'Not syncing',
        'Saved on this device. It syncs once you unlock your notes in '
            'Account & sync.',
      ),
      'outdated': (
        syncProblem(SyncStatus.outdated),
        'Not syncing',
        'Saved on this device. It syncs once you update Kapy Notes.',
      ),
      'sync failed': (
        syncProblem(SyncStatus.failed),
        'Sync failed',
        'Saved on this device. Account & sync says what went wrong.',
      ),
    };
    for (final MapEntry(key: name, value: (problem, words, tooltip))
        in cases.entries) {
      testWidgets(name, (tester) async {
        expect(problem, isNotNull);
        final (store, status) = await pumpStatus(tester, problem: problem);
        expect(shown(tester), words);
        expect(find.byTooltip(tooltip), findsOneWidget);
        expect(
          find.descendant(
            of: label,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is KapyIcon &&
                  widget.icon == KapyIcons.cloudOffRounded,
            ),
          ),
          findsOneWidget,
        );

        // Typing and the save after it never cover it, and it never fades.
        store.put('notes', 'a');
        status.edited();
        for (var second = 0; second < 10; second++) {
          await tester.pump(const Duration(seconds: 1));
          expect(shown(tester), words);
          expect(opacity(tester), 1);
        }
      });
    }

    test('nothing is in the way while sync is idle, syncing, or checking a '
        'sign-in it will retry', () {
      for (final status in [
        null,
        SyncStatus.idle,
        SyncStatus.syncing,
        SyncStatus.signedOut,
      ]) {
        expect(syncProblem(status), isNull, reason: '$status');
      }
    });

    test('offline outranks paused, and a session the server ended outranks '
        'both', () {
      expect(syncProblem(SyncStatus.offline, paused: true)?.label, 'Offline');
      expect(
        syncProblem(SyncStatus.offline, paused: true, signInAgain: true)?.label,
        'Signed out',
      );
    });
  });

  testWidgets('a screen reader hears each change', (tester) async {
    final semantics = tester.ensureSemantics();
    final (store, status) = await pumpStatus(tester);
    store.put('notes', 'a');
    status.edited();
    await tester.pump();
    expect(
      tester.getSemantics(says('Saving…')),
      isSemantics(label: 'Saving…', isLiveRegion: true),
    );
    await tester.pump(const Duration(milliseconds: 1100));
    expect(
      tester.getSemantics(says('Saved')),
      isSemantics(label: 'Saved', isLiveRegion: true),
    );
    // Fading, it is not said again.
    await tester.pump(const Duration(milliseconds: 2050));
    expect(find.bySemanticsLabel('Saved'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    semantics.dispose();
  });

  group('the store says where its writes are', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('kapy-store-');
      PathProviderPlatform.instance = _FakePaths(root);
    });
    tearDown(() => root.delete(recursive: true));

    test('pending until written, failed while the disk refuses, and written '
        'again once a retry lands', () async {
      final store = LocalStore(
        fileName: 'notes.json',
        retry: const Duration(milliseconds: 50),
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.writes.value, StoreWrite.written);

      store.put('a', 1);
      expect(store.writes.value, StoreWrite.pending);
      await store.flush();
      expect(store.writes.value, StoreWrite.written);

      // A directory where the write's temporary file goes makes it fail.
      final blocker = await Directory('${root.path}/notes.json.tmp').create();
      store.put('a', 2);
      await store.flush();
      expect(store.writes.value, StoreWrite.failed);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(store.writes.value, StoreWrite.failed);

      // Another change while it fails leaves it failed, not pending.
      store.put('a', 3);
      expect(store.writes.value, StoreWrite.failed);

      await blocker.delete();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(store.writes.value, StoreWrite.written);
      expect(
        await File('${root.path}/notes.json').readAsString(),
        contains('"a":3'),
      );
    });
  });
}
