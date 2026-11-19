import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:image/image.dart' as img;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/auto_titles.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_test.dart' show MemoryStore;
import 'fake_update_installer.dart';
import 'support/note_driver.dart';
import 'test_fonts.dart';

const _body = '''
Lisbon trip budget

Flights for two
flights = 412 eur
flights to usd

Hotel: 7 nights
nightly = 128 eur
nightly * 7

Food and getting around // rough guess
daily = 55 eur
daily * 7

total
total to usd''';

const _rates = <String, double>{'EUR': 0.861401, 'GBP': 0.738359};
final _goldenNow = DateTime(2026, 9, 1, 15, 38);
final _goldenRatesFetchedAt = DateTime(2026, 9, 2, 12);

/// Renders the whole app at a fixed size for visual review.
///
/// Goldens depend on macOS system fonts (see [loadTestFonts]); regenerate
/// them on macOS with `flutter test --update-goldens`.
late LayoutPrefs goldenPrefs;

/// The notes the image was built from, for the few images that have to change
/// the list after it is on screen.
late NotesStore goldenNotes;
late TagStore goldenTags;

/// The task list, for the images that ask for one with `withTasks`.
late TaskLibrary goldenTasks;

/// A model on the device that is never asked, so Settings shows its row.
class _GoldenTitles implements TitleModel {
  @override
  Future<String?> unavailableReason() async => null;

  @override
  Future<String> name({required String instructions, required String prompt}) =>
      Completer<String>().future;
}

Future<void> pumpForGolden(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  bool withNote = true,
  bool blankNote = false,
  bool withImages = false,
  bool withUpdates = false,
  bool updateAvailable = false,

  /// The pending release already downloaded, so the notes list offers
  /// "Update and restart". Implies [updateAvailable].
  bool updateReady = false,
  bool firstRun = false,
  bool sidebarVisible = true,
  bool withPinnedNote = false,

  /// Drawings in the store, the newest pinned, for the Drawings space.
  bool withDrawings = false,
  bool cards = true,

  /// Tasks on the rail, read from the notes' checklist lines.
  bool withTasks = false,

  /// Which build the image is of.
  ///
  /// Sizes in this app resolve from [AppPlatform.hasPointer], not from the
  /// window, so a phone-sized window on a Mac still renders every control at
  /// desktop density. Without this a "phone" golden documents a narrow desktop
  /// window and nothing about the phone.
  TargetPlatform? platform,
}) async {
  if (platform != null) {
    AppPlatform.debugTargetPlatformOverride = platform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  }
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

  final store = MemoryStore();
  // These images document the app in use rather than the moment it is
  // installed; the welcome goldens below ask for that moment by name.
  if (!firstRun) store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  store.data['rates.v1'] = RateSnapshot(
    base: 'USD',
    date: '01 Sep 2026',
    fetchedAt: _goldenRatesFetchedAt,
    rates: _rates,
  ).toJson();

  UpdateChecker? updates;
  if (updateReady) {
    withUpdates = true;
    updateAvailable = true;
  }
  if (withUpdates) {
    // A checked, current app: the state the pane is in almost all the time,
    // and the only one whose copy does not move with the calendar.
    store.data['updates.v1'] = {
      'available': updateAvailable
          ? {
              'version': '1.2.0',
              'build': 12,
              'notesUrl': 'https://kapynotes.com/changelog/1.2.0',
            }
          : null,
      'checkedAt': DateTime.now().toIso8601String(),
    };
    // The list of releases too, and fresh, so the image is of the pane with
    // its changelog rather than of the pane failing to read one — and so the
    // golden never depends on the network.
    store.data['changelog.v1'] = {
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': [
        if (updateAvailable)
          {
            'version': '1.2.0',
            'date': '2026-09-04',
            'summary': 'A faster, calmer update for the tools you use most.',
            'highlights': [
              'Clearer controls and more readable supporting text.',
              'Faster startup and smoother note editing.',
              'A shorter update summary that is easy to scan.',
            ],
            'changes': [
              'The complete explanation remains available in release history.',
            ],
          },
        {
          'version': '1.1.0',
          'date': '2026-09-03',
          'summary': 'The first release that can update itself.',
          'changes': [
            'Kapy Notes checks for new releases once a day and offers them in '
                'the corner. Nothing downloads until you ask.',
            'Tab nests list items, and the footer buttons do it on touch.',
          ],
        },
        {
          'version': '1.0.0',
          'date': '2026-09-02',
          'summary': 'The first public build, for macOS and Windows.',
          'changes': ['A notebook that does the math.'],
        },
      ],
    };
    updates = UpdateChecker(
      store,
      client: MockClient((_) async => throw StateError('no network here')),
      packageInfo: PackageInfo(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.1.0',
        buildNumber: '11',
      ),
      installer: updateReady
          ? (FakeUpdateInstaller()
              ..onDisk = const StagedUpdate(version: '1.2.0', build: 12))
          : null,
    );
    // Picks the download up the way a launch does. Nothing is due, so the
    // only thing this reaches is the installer's record of it.
    if (updateReady) await updates.checkIfDue();
  }

  final notes = NotesStore(
    store,
    now: () => _goldenNow,
    blobs: withImages ? _imageStore : null,
  );
  final prefs = LayoutPrefs(store);
  goldenPrefs = prefs;
  goldenNotes = notes;
  goldenTags = TagStore(store);
  await goldenTags.load();
  final rates = RatesRepository(store);
  final shortcuts = ShortcutPrefs(store)..load();
  final tasks = withTasks
      ? goldenTasks = TaskLibrary(
          notes: notes,
          store: store,
          storage: MemoryDocStorage(),
          now: () => _goldenNow,
        )
      : null;

  await notes.load();
  await tasks?.load();
  prefs.load();
  // These images document the app in use, where the notes list has been
  // opened at least once. A new install starts with it closed, which is what
  // the first-launch images ask for.
  if (prefs.sidebarVisible != sidebarVisible) prefs.toggleSidebar();
  prefs.noteCards = cards;
  if (withDrawings) _seedDrawings(notes);
  if (withNote) {
    final note = notes.create();
    if (withImages) {
      notes.updateDocument(note.id, _imageBody, const [], _imageAttachments());
    } else if (!blankNote) {
      notes.updateBody(note.id, _body);
    }
    if (withPinnedNote) {
      notes.togglePinned(note.id);
      notes.create(body: 'Today\nFollow up on the launch checklist');
    }
  }
  // Publish the cached rates without going near the network.
  rates.loadCache();

  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      updates: updates,
      tags: goldenTags,
      tasks: tasks,
      titleModel: _GoldenTitles(),
    ),
  );
  if (withImages) {
    await _warmVisibleNoteImages(tester);
    // Existing Image states still point at the fake-zone streams evicted
    // above. Re-resolve them against the now-warm target-sized cache entries.
    unawaited(tester.binding.reassembleApplication());
    await tester.pump();
  }
  // The mark is decoded at the size it is drawn, which is a cache entry of
  // its own: warming the asset itself leaves the first image to draw it
  // without one, and so an image that depends on which test ran before.
  await tester.runAsync(
    () => Future.wait([
      for (final image in tester.widgetList<Image>(find.byType(Image)))
        if (image.image case ResizeImage(
          imageProvider: AssetImage(assetName: AppLogo.assetPath),
        ))
          precacheImage(image.image, tester.element(find.byWidget(image))),
    ]),
  );
  await tester.pumpAndSettle();
}

/// Five drawings, the first pinned: boxes, an arrow, a scribble and a word,
/// in the swatches the colour popover offers.
void _seedDrawings(NotesStore notes) {
  const titles = [
    'Q4 goals map',
    'App wireframe',
    'Onboarding flow',
    'Living room',
    'Garden plan',
  ];
  for (final (seed, title) in titles.indexed) {
    var z = 0;
    DrawElement element(
      DrawKind kind,
      List<double> points, {
      int? color,
      double width = 3,
      String text = '',
    }) => DrawElement(
      id: '$seed-$z',
      kind: kind,
      points: points,
      z: z++,
      color: color,
      width: width,
      text: text,
    );
    final note = notes.create();
    notes.setDrawingMode(note.id, drawing: true);
    notes.updateDrawing(
      note.id,
      NoteDrawing([
        element(DrawKind.rect, [40, 40, 260, 160]),
        element(DrawKind.ellipse, [320, 60, 460, 170], color: 0xFF6F8F52),
        element(DrawKind.arrow, [260, 100, 320, 110]),
        element(DrawKind.text, [60, 80], text: seed.isEven ? 'Idea' : 'Herbs'),
        element(
          DrawKind.pen,
          [
            for (var i = 0; i < 30; i++) ...[
              60.0 + i * 12,
              240 + (i % 5) * 8.0,
            ],
          ],
          color: 0xFF3F8796,
          width: 4,
        ),
        if (seed.isOdd)
          element(DrawKind.ellipse, [120, 260, 220, 330], color: 0xFFD0663B),
      ]),
      title: title,
    );
    if (seed == titles.length - 1) notes.togglePinned(note.id);
  }
}

/// Opens Drawings from the rail, and [open] from its list when given.
Future<void> _openDrawings(WidgetTester tester, {String? open}) async {
  await tester.tap(find.byKey(const ValueKey('rail-drawings')));
  await tester.pumpAndSettle();
  if (open == null) return;
  await tester.tap(find.text(open).first);
  await tester.pumpAndSettle();
}

/// Resolves the exact size-aware keys the first frame requested. File I/O only
/// advances under `runAsync` in a widget test; the real app has no fake clock.
Future<void> _warmVisibleNoteImages(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is Image && widget.image is NoteImageProvider,
  );
  final pending = <(NoteImageProvider, ImageConfiguration)>[];
  for (var index = 0; index < finder.evaluate().length; index++) {
    final current = finder.at(index);
    final image = tester.widget<Image>(current);
    final size = image.width == null || image.height == null
        ? null
        : Size(image.width!, image.height!);
    pending.add((
      image.image as NoteImageProvider,
      createLocalImageConfiguration(tester.element(current), size: size),
    ));
  }
  await tester.runAsync(() async {
    for (final (provider, configuration) in pending) {
      // The first build starts this key in the fake-async zone. Replace that
      // pending entry, then resolve it wholly on the real event loop.
      await provider.evict(configuration: configuration);
      await _warmNoteImage(provider, configuration);
    }
  });
}

Future<void> _warmNoteImage(
  NoteImageProvider provider,
  ImageConfiguration configuration,
) {
  final completer = Completer<void>();
  final stream = provider.resolve(configuration);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
    onError: (error, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Opens settings through the affordance the current layout owns: the rail's
/// gear beside a wide window's notes list. Phones keep settings in the notes
/// drawer so the editor footer can stay focused on input.
Future<void> tapSettings(WidgetTester tester) async {
  final gear = find.byKey(const ValueKey('rail-settings'));
  if (gear.evaluate().isNotEmpty) {
    await tester.tap(gear);
    return;
  }
  final sidebar = find.byKey(const ValueKey('sidebar-settings'));
  final showNotes = find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip && (widget.message ?? '').startsWith('Show notes'),
  );
  if (showNotes.evaluate().isNotEmpty) {
    await tester.tap(showNotes);
    await tester.pumpAndSettle();
  }
  await tester.tap(sidebar.first);
}

/// Pictures for the image golden, written once outside any test body: real
/// file I/O inside `testWidgets` never completes.
late Directory _imageDir;
late BlobStore _imageStore;
late List<String> _imageHashes;

/// Flat-coloured rectangles rather than photographs, so the golden is about
/// the layout — where a picture sits, how wide it is, what it does to the
/// lines around it — and not about a JPEG decoder's rounding.
Uint8List _swatch(int width, int height, img.ColorRgb8 colour) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: colour);
  img.fillRect(
    image,
    x1: 0,
    y1: height - height ~/ 4,
    x2: width,
    y2: height,
    color: img.ColorRgb8(
      (colour.r * 0.7).round(),
      (colour.g * 0.7).round(),
      (colour.b * 0.7).round(),
    ),
  );
  return Uint8List.fromList(img.encodePng(image, level: 1));
}

/// A note that reads the way the feature is meant to: a line of writing, one
/// picture across the column, more writing, then three that became a row.
const String _imageBody =
    'Kitchen renovation\n'
    'Quote came in at 4200 eur\n'
    '\n'
    '\u{FFFC}\n'
    '\n'
    'Tiles we shortlisted\n'
    '\u{FFFC}\u{FFFC}\u{FFFC}\n'
    '\n'
    '4200 eur to usd';

List<NoteAttachmentRef> _imageAttachments() {
  final anchors = <int>[];
  for (var i = 0; i < _imageBody.length; i++) {
    if (_imageBody.codeUnitAt(i) == 0xFFFC) anchors.add(i);
  }
  const sizes = [(960, 600), (600, 600), (600, 600), (600, 600)];
  return [
    for (var i = 0; i < anchors.length; i++)
      NoteImageRef(
        offset: anchors[i],
        hash: _imageHashes[i],
        key: Uint8List(32),
        mime: 'image/png',
        width: sizes[i].$1,
        height: sizes[i].$2,
        bytes: 4096,
      ),
  ];
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    _imageDir = await Directory.systemTemp.createTemp('kapy-golden-images');
    _imageStore = BlobStore(directory: _imageDir);
    _imageHashes = [
      await _imageStore.put(_swatch(960, 600, img.ColorRgb8(86, 132, 196))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(206, 128, 92))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(104, 168, 128))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(158, 130, 198))),
    ];
  });

  tearDownAll(() async {
    if (await _imageDir.exists()) await _imageDir.delete(recursive: true);
  });

  testWidgets('desktop dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark.png'),
    );
  });

  // The one click an update asks for, in the title bar once the release is
  // downloaded.
  testWidgets('desktop dark, update ready to install', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      updateReady: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_update_ready.png'),
    );
  });

  testWidgets('desktop dark note actions', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final note = goldenNotes.notes.single;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byKey(ValueKey(note.id)).first),
    );
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('note-actions-${note.id}')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_note_actions.png'),
    );
  });

  testWidgets('desktop dark editor context menu', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final editor = find.descendant(
      of: find.byType(NoteEditor),
      matching: noteField,
    );
    final bounds = tester.getRect(editor);
    await tester.tapAt(
      Offset(bounds.left + 36, bounds.bottom - 32),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_editor_context_menu.png'),
    );
  });

  testWidgets('desktop dark pinned on top', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    // The pin is the only toolbar control with an on state, and the filled
    // icon behind a selected surface is the whole signal that the window is
    // now floating.
    goldenPrefs.toggleAlwaysOnTop();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_pinned.png'),
    );
  });

  /// The archive with something in it, which is the only place a note can be
  /// thrown away for good. Two images: the resting state, and picking.
  Future<void> fillAndOpenArchive(WidgetTester tester) async {
    final notes = goldenNotes;
    for (final body in [
      'Old receipts\nCoffee: 12.40',
      'Trip ideas\nLisbon in April',
    ]) {
      notes.create(body: body);
    }
    await tester.pumpAndSettle();
    for (final note in [...notes.notes]) {
      notes.archive(note.id);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-archive')));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop dark archive', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await fillAndOpenArchive(tester);
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_archive.png'),
    );
  });

  testWidgets('desktop dark archive, picking notes', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await fillAndOpenArchive(tester);
    await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('archive-check-all')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_archive_selecting.png'),
    );
  });

  testWidgets('desktop dark pinned note section', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withPinnedNote: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_note_pinned.png'),
    );
  });

  testWidgets('Tasks leaves Keep on top to Settings and its shortcut', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(1000, 640),
      brightness: Brightness.dark,
      withTasks: true,
    );
    await tester.tap(find.byKey(const ValueKey('rail-tasks')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').startsWith('Keep on top'),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('page-more')), findsNothing);
  });

  testWidgets('desktop dark narrow, results at line ends', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(600, 630),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_narrow_results.png'),
    );
  });

  testWidgets('desktop dark narrow, notes list over the page', (tester) async {
    // The window a new install opens at, too narrow for the list beside the
    // page: the rail and the page stay, and the list opens over the page.
    await pumpForGolden(
      tester,
      size: LayoutPrefs.defaultWindowSize,
      brightness: Brightness.dark,
    );
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').startsWith('Show notes'),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_narrow_list.png'),
    );
  });

  testWidgets('desktop dark compact header hover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('page-more'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_header_hover.png'),
    );
  });

  testWidgets('desktop light', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light.png'),
    );
  });

  testWidgets('first launch, desktop dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      // Everything a new install actually is: no notes of its own, no list
      // opened yet, and the welcome note in front of both.
      withNote: false,
      firstRun: true,
      sidebarVisible: false,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_desktop_dark.png'),
    );
  });

  testWidgets('first launch, phone light', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.light,
      platform: TargetPlatform.iOS,
      withNote: false,
      firstRun: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_phone_light.png'),
    );
  });

  testWidgets('first launch, phone dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
      withNote: false,
      firstRun: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_phone_dark.png'),
    );
  });

  testWidgets('desktop dark empty state', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_empty.png'),
    );
  });

  testWidgets('desktop dark drawings', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: true,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings.png'),
    );
  });

  testWidgets('desktop light drawings with the colour popover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.light,
      withNote: false,
      withDrawings: true,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await tester.tap(find.byKey(const ValueKey('draw-style')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light_drawings_style.png'),
    );
  });

  testWidgets('desktop dark drawings list', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: true,
      cards: false,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings_list.png'),
    );
  });

  testWidgets('desktop dark drawings, none yet and none open', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
    );
    await _openDrawings(tester);
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings_empty.png'),
    );
  });

  // The pinned cards Paper's 5TS-0 draws: a checklist under a title too
  // long for one line, See all at the heading's end, and amounts in mono.
  testWidgets('desktop dark tags', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    final work = goldenTags.create('Work')!;
    final money = goldenTags.create('Money')!;
    final travel = goldenTags.create('Travel')!;
    for (final (body, tags) in [
      ('Groceries\nMilk, eggs', <Tag>[]),
      ('land\n₹75,60,000', [money]),
      ('Trip budget\n₹28,000', [travel, money]),
      ('Reading list\nThree books', <Tag>[]),
      ('SnowSEO Issues\n☑ Crawl\n☐ Fix titles', [work]),
    ]) {
      final note = goldenNotes.create(body: body);
      goldenTags.setTags(note.id, [for (final tag in tags) tag.id]);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tag-filter-${work.id}')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_tags.png'),
    );
  });

  testWidgets('desktop dark pinned cards', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    for (final (index, body) in [
      'Groceries\nMilk, eggs',
      'land\n₹75,60,000',
      'car issues\n₹18,400',
      'Ideas\nA quieter dock',
      'Goals - Oct 2026\nShip the redesign',
      'Todos\nRenew domain, gym',
      'Reading list\nThree books',
      'SnowSEO Issues backlog\n☑ Crawl\n☐ Fix titles\n☐ Sitemap',
    ].indexed) {
      final note = goldenNotes.create(body: body);
      if (index > 2) goldenNotes.togglePinned(note.id);
    }
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_pinned_cards.png'),
    );
  });

  testWidgets('desktop dark note with images', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 780),
      brightness: Brightness.dark,
      withImages: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_images.png'),
    );
  });

  testWidgets('desktop dark blank note sample', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      blankNote: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_blank_note.png'),
    );
  });

  testWidgets('desktop dark selection bubble', (tester) async {
    // With the list put away, so the whole note fits the page and the word
    // to select is on screen rather than scrolled above it.
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      sidebarVisible: false,
    );
    final note = NoteDriver(
      tester,
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    final targetStart = _body.indexOf('Hotel');
    final wordBox = note
        .boxesFor(
          TextSelection(
            baseOffset: targetStart,
            extentOffset: targetStart + 'Hotel'.length,
          ),
        )
        .first;
    final start = note.toGlobal(
      Offset(wordBox.left + 1, (wordBox.top + wordBox.bottom) / 2),
    );
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.down(start);
    await tester.pump();
    await mouse.up();
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(note.value.selection.isCollapsed, isFalse);
    final bubble = tester.getRect(
      find.byKey(const ValueKey('selection-bubble')),
    );
    expect(bubble.top, greaterThanOrEqualTo(0));
    expect(bubble.right, lessThanOrEqualTo(760));
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_selection_bubble.png'),
    );
  });

  testWidgets('desktop dark, sidebar collapsed', (tester) async {
    // The page starts a margin in from the rail, as in Paper's window with
    // the list hidden.
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    goldenPrefs.toggleSidebar();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_collapsed.png'),
    );
  });

  testWidgets('desktop dark settings', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings.png'),
    );
  });

  testWidgets('Windows desktop dark settings stays comfortably readable', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      platform: TargetPlatform.windows,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_windows_dark_settings.png'),
    );
  });

  testWidgets('Windows pending update stays concise and readable', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      platform: TargetPlatform.windows,
      withUpdates: true,
      updateAvailable: true,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_windows_dark_update.png'),
    );
  });

  // The bottom of the Notes pane, where number format and the rates credit
  // sit.
  testWidgets('desktop dark settings, notes scrolled', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-notes')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('rate-attribution')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_notes_end.png'),
    );
  });

  testWidgets('desktop dark settings, shortcuts', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-shortcuts')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_shortcuts.png'),
    );
  });

  testWidgets('desktop dark settings, about', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withUpdates: true,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-about')));
    await tester.pumpAndSettle();
    expect(
      find.text('The version you have, updates and what changed'),
      findsOneWidget,
      reason: 'the tap reached About, so the golden shows its pane',
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_about.png'),
    );
  });

  testWidgets('desktop light settings, appearance', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-appearance')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light_settings_appearance.png'),
    );
  });

  testWidgets('phone editor', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_editor.png'),
    );
  });

  testWidgets('phone settings', (tester) async {
    // A touch screen gets the sheet: a list of categories, one pushed at a
    // time. Declared, because these run on a desktop host.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_settings.png'),
    );
  });

  testWidgets('phone settings, a category opened', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-appearance')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_settings_appearance.png'),
    );
  });

  testWidgets('phone notes drawer', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_drawer.png'),
    );
  });

  testWidgets('phone note actions', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
    await tester.pumpAndSettle();
    final note = goldenNotes.notes.single;
    await tester.tap(find.byKey(ValueKey('note-actions-${note.id}')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_note_actions.png'),
    );
  });

  group('⌘K menu', () {
    /// The trip notes p-7-0 searches: two notes, two tasks in one of them, a
    /// drawing, and one more in Archive. Pumped at Paper's 1440 × 900.
    Future<void> pumpTrip(WidgetTester tester, Brightness brightness) async {
      await pumpForGolden(
        tester,
        size: const Size(1440, 900),
        brightness: brightness,
        withTasks: true,
      );
      final notes = goldenNotes;
      notes.archive(notes.create(body: 'Sintra in 2024\nThe palace queue').id);
      notes.create(
        body: 'Goals - Oct 2026\nSee Sintra and Cascais before December',
      );
      final drawing = notes.create();
      notes.setDrawingMode(drawing.id, drawing: true);
      notes.updateDrawing(
        drawing.id,
        NoteDrawing.empty,
        title: 'Sintra day route',
      );
      notes.create(
        body:
            'Trip budget\nGo to Sintra on a weekday. The weekend queues are '
            'brutal.\n☐ Book the Sintra train tickets\n'
            '☐ Ask Ana which Sintra palace to skip',
      );
      await tester.runAsync(goldenTasks.reconcileNow);
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester, [String text = '']) async {
      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      if (text.isEmpty) return;
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        text,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('before typing, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester);
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark.png'),
      );
    });

    testWidgets('while typing, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester, 'sintra');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_typing.png'),
      );
    });

    testWidgets('a setting, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester, 'text size');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_settings.png'),
      );
    });

    testWidgets('while typing, light', (tester) async {
      await pumpTrip(tester, Brightness.light);
      await openMenu(tester, 'sintra');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_light_typing.png'),
      );
    });

    /// Work, Money and Travel on the trip notes, as SOW-0 lists them.
    Future<void> tagTrip(WidgetTester tester) async {
      final work = goldenTags.create('Work')!;
      final money = goldenTags.create('Money')!;
      final travel = goldenTags.create('Travel')!;
      for (final (title, tags) in [
        ('Trip budget', [travel, money]),
        ('Goals - Oct 2026', [work]),
      ]) {
        final note = goldenNotes.notes.firstWhere(
          (note) => note.title == title,
        );
        goldenTags.setTags(note.id, [for (final tag in tags) tag.id]);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('# filters by tag, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await tagTrip(tester);
      await openMenu(tester, '#');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_hash.png'),
      );
    });

    testWidgets('Tag note…, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await tagTrip(tester);
      await openMenu(tester, 'tag');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_tag_note.png'),
      );
    });
  });

  group('phone filter sheet', () {
    Future<void> openSheet(WidgetTester tester, Brightness brightness) async {
      await pumpForGolden(
        tester,
        size: const Size(390, 760),
        brightness: brightness,
        platform: TargetPlatform.iOS,
        withNote: false,
      );
      final work = goldenTags.create('Work')!;
      final money = goldenTags.create('Money')!;
      final travel = goldenTags.create('Travel')!;
      goldenTags.create('Ideas');
      for (final (body, tags) in [
        ('SnowSEO Issues\nAutomate Backlink Outreach', [work]),
        ('SnowAnalytic Design\nMoodboard, palette, first', [work, money]),
        ('Trip budget\n₹28,000', [travel, money]),
        ('Todos\nRenew domain, gym', <Tag>[]),
      ]) {
        final note = goldenNotes.create(body: body);
        goldenTags.setTags(note.id, [for (final tag in tags) tag.id]);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-notes-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
      await tester.pumpAndSettle();
    }

    for (final (name, brightness) in [
      ('dark', Brightness.dark),
      ('light', Brightness.light),
    ]) {
      testWidgets('Show, Media and Tags, $name', (tester) async {
        await openSheet(tester, brightness);
        await expectLater(
          find.byType(KapyNotesApp),
          matchesGoldenFile('goldens/phone_filter_$name.png'),
        );
      });
    }

    testWidgets('the Tags page, dark', (tester) async {
      await openSheet(tester, Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('notes-filter-tags')));
      await tester.pumpAndSettle();
      for (final tag in ['Work', 'Travel']) {
        await tester.tap(
          find.byKey(ValueKey('tag-filter-${goldenTags.named(tag)!.id}')),
        );
        await tester.pumpAndSettle();
      }
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/phone_filter_tags_dark.png'),
      );
    });
  });

  // The largest phone the app ships to, and the one where desktop-scale chrome
  // was most obviously wrong: a 40pt footer of 17px glyphs reads as a toolbar
  // belonging to some other, smaller application. Held at the full 932pt so
  // the bars are judged against the screen they actually sit on.
  testWidgets('phone editor at iPhone Pro Max size', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(430, 932),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_editor_large.png'),
    );
  });

  // The formatting bar on a phone's keyboard. The golden has no keyboard to
  // draw, so the room it takes is left empty under the bar.
  for (final (name, brightness, platform, keyboard, list) in [
    ('iphone_dark', Brightness.dark, TargetPlatform.iOS, 336.0, false),
    ('iphone_light', Brightness.light, TargetPlatform.iOS, 336.0, false),
    ('android_dark', Brightness.dark, TargetPlatform.android, 300.0, false),
    ('iphone_dark_list', Brightness.dark, TargetPlatform.iOS, 336.0, true),
  ]) {
    testWidgets('phone formatting bar, $name', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(390, 844),
        brightness: brightness,
        platform: platform,
      );
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      if (list) {
        tester.widget<NoteField>(find.byType(NoteField)).controller.selection =
            TextSelection.collapsed(offset: _body.indexOf('Hotel'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('format-bullets')));
        await tester.pumpAndSettle();
      }
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/phone_format_bar_$name.png'),
      );
    });
  }
}
