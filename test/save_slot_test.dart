import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_service.dart' show SyncStatus;
import 'package:kapy_notes/ui/day_strip.dart';
import 'package:kapy_notes/ui/editor/note_header.dart';
import 'package:kapy_notes/ui/page_pane.dart';
import 'package:kapy_notes/ui/page_toolbar.dart';
import 'package:kapy_notes/ui/save_status.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'test_fonts.dart';

class _Saying extends SaveStatus {
  _Saying(this.fixed) : super(ValueNotifier(StoreWrite.written));

  final SavePhase fixed;

  @override
  SavePhase get phase => fixed;
}

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);

  final Directory root;

  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

void main() {
  setUpAll(loadTestFonts);

  test('dispose during a write does not throw', () async {
    final root = await Directory.systemTemp.createTemp('kapy-store-');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePaths(root);
    final store = LocalStore(
      fileName: 'notes.json',
      delay: const Duration(hours: 1),
    );
    await store.load();
    store.put('a', 1);
    final pending = store.flush();
    store.dispose();
    await expectLater(pending, completes);
  });

  test('a failed write retries on its own, with no further put', () async {
    final root = await Directory.systemTemp.createTemp('kapy-store-');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePaths(root);
    final store = LocalStore(
      fileName: 'notes.json',
      retry: const Duration(milliseconds: 80),
    );
    addTearDown(store.dispose);
    await store.load();
    final blocker = await Directory('${root.path}/notes.json.tmp').create();
    store.put('a', 1);
    await store.flush();
    expect(store.writes.value, StoreWrite.failed);
    await blocker.delete();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.writes.value, StoreWrite.written);
  });

  test('a keystroke during a failed write cancels the retry and saves on '
      'the delay', () async {
    final root = await Directory.systemTemp.createTemp('kapy-store-');
    addTearDown(() => root.delete(recursive: true));
    PathProviderPlatform.instance = _FakePaths(root);
    final store = LocalStore(
      fileName: 'notes.json',
      delay: const Duration(milliseconds: 40),
      retry: const Duration(seconds: 30),
    );
    addTearDown(store.dispose);
    await store.load();
    final blocker = await Directory('${root.path}/notes.json.tmp').create();
    store.put('a', 1);
    await store.flush();
    expect(store.writes.value, StoreWrite.failed);
    await blocker.delete();

    store.put('a', 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(store.writes.value, StoreWrite.written);
    expect(store.read<int>('a'), 2);
  });

  testWidgets('Saving and Saved do not move the week, the avatars or the date line', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    final phases = <(SavePhase, SaveNotice?)>[
      (SavePhase.rest, null),
      (SavePhase.saving, null),
      (SavePhase.saved, null),
      (SavePhase.failed, null),
      (SavePhase.rest, syncProblem(SyncStatus.idle, paused: true)),
    ];
    for (final width in [1000.0, 1200.0]) {
      for (final members in [0, 3]) {
        tester.view.physicalSize = Size(width, 300);
        int? days;
        double? avatars;
        for (final (phase, problem) in phases) {
          await tester.pumpWidget(_bar(width, members, phase, problem));
          final dayCount = find
              .byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'day-strip-2026',
                    ),
              )
              .evaluate()
              .length;
          final avatarFinder = find.byKey(const ValueKey('toolbar-members'));
          final avatarX = avatarFinder.evaluate().isEmpty
              ? -1.0
              : tester.getTopLeft(avatarFinder).dx;
          days ??= dayCount;
          avatars ??= avatarX;
          expect(dayCount, days, reason: 'w=$width n=$members $phase');
          expect(avatarX, avatars, reason: 'w=$width n=$members $phase');
          expect(tester.takeException(), isNull);
        }
      }
    }

    tester.view.physicalSize = const Size(800, 240);
    double? progress;
    for (final (phase, problem) in phases) {
      await tester.pumpWidget(_dateLine(phase, problem));
      final progressX = tester.getTopLeft(find.text('1 of 3 done')).dx;
      progress ??= progressX;
      expect(progressX, progress, reason: '$phase');
      expect(tester.takeException(), isNull);
    }
  });
}

Widget _bar(double width, int members, SavePhase phase, SaveNotice? problem) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: SizedBox(
        width: width,
        height: 300,
        child: PagePane(
          divided: true,
          child: PageToolbar(
            path: const PagePath(
              icon: KapyIcons.noteOutlined,
              root: 'My notes',
              levels: [(name: 'Work', folderId: 'work')],
            ),
            days: (compact, place) => DayStrip(
              place: place,
              compact: compact,
              today: DateTime(2026, 11, 19),
              picked: null,
              onPick: (_, _) {},
              notes: const <Note>[],
              displayTime: (at) => at,
              firstWeekday: DateTime.monday,
            ),
            listVisible: true,
            onShowList: () {},
            onOpenFolder: (_, {required behind}) {},
            noteOpen: true,
            save: (status: _Saying(phase), problem: problem),
            members: [
              for (var i = 0; i < members; i++)
                SpaceMember(
                  userId: i == 0 ? 'me' : 'u$i',
                  email: 'u$i@example.com',
                  name: 'User $i',
                  role: SpaceRole.member,
                  joinedAt: DateTime(2026),
                  hasKey: true,
                ),
            ],
            currentUserId: 'me',
            onShare: () {},
            assistant: const SizedBox(key: ValueKey('ai'), width: 32, height: 32),
            onMore: (_, _) {},
          ),
        ),
      ),
    ),
  );
}

Widget _dateLine(SavePhase phase, SaveNotice? problem) {
  return MaterialApp(
    theme: KapyTheme.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 640,
          child: DateLineSaved(
            save: (status: _Saying(phase), problem: problem),
            child: NoteMetaRow(
              edited: DateTime(2026, 11, 19, 8, 55),
              today: DateTime(2026, 11, 19),
              tasks: 3,
              done: 1,
              total: '42',
              tags: const Text('Work'),
            ),
          ),
        ),
      ),
    ),
  );
}
